using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace AISubGauge.Providers;

public sealed class CodexProvider : IQuotaProvider
{
    // Intentionally rooted until app exit: uncertain cleanup must never release native handles or locks.
    private static readonly List<(CodexCliProcess Process, LocalFiles.CodexCredentialLock? Credential)> FailedCleanups = new();
    internal static bool CodexCleanupFault { get { lock (FailedCleanups) return FailedCleanups.Count != 0; } }
    internal static string CleanupFaultMessage => I18n.Get("windows.codex.cleanupFailed");

    // Tests dispose their synthetic resources before clearing the process-wide fault.
    internal static void ResetCleanupFaultForTest() { lock (FailedCleanups) FailedCleanups.Clear(); }

    public string Id => "codex";
    public string DisplayName => I18n.Get("provider.codex");
    public string LogoResource => "WindowsQuotaTray.assets.logos.openai.png";

    public bool IsSignedInLocally()
    {
        // Retain the entry's visibility and avoid reopening credentials after a cleanup fault.
        return CodexCleanupFault || ValidateLocalCredential();
    }

    private static bool ValidateLocalCredential()
    {
        using LocalFiles.CodexCredentialLock? credential = OpenLocalCredential();
        return credential is not null && credential.HasCredential;
    }

    private static LocalFiles.CodexCredentialLock? OpenLocalCredential()
    {
        try
        {
            return LocalFiles.OpenCodexCredential(CredentialFiles.CodexPath, 1_048_576);
        }
        catch (FileNotFoundException) { return null; }
        catch (DirectoryNotFoundException) { return null; }
    }

    public Task<QuotaSnapshot> FetchAsync(CancellationToken cancellationToken) => FetchCoreAsync(cancellationToken);

    // Tests supply an unsigned subprocess fixture; production always uses discovery and Authenticode.
    internal Task<QuotaSnapshot> FetchForTestAsync(ProcessStartInfo startInfo, CancellationToken cancellationToken,
        TimeSpan? cleanupTimeout = null, Func<CodexCliProcess, Task>? beforeCleanup = null,
        Action<Task>? cleanupDeferred = null) =>
        FetchCoreAsync(cancellationToken, startInfo, cleanupTimeout, beforeCleanup, cleanupDeferred);

    private async Task<QuotaSnapshot> FetchCoreAsync(CancellationToken cancellationToken, ProcessStartInfo? testStartInfo = null,
        TimeSpan? cleanupTimeout = null, Func<CodexCliProcess, Task>? beforeCleanup = null,
        Action<Task>? cleanupDeferred = null)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(20));
        CodexCliProcess? process = null;
        Task? stderrTask = null;
        LocalFiles.CodexCredentialLock? credential = null;
        QuotaSnapshot result;
        try
        {
            timeout.Token.ThrowIfCancellationRequested();
            if (CodexCleanupFault) throw new QuotaReadException(CleanupFaultMessage);
            // Never let the CLI create a credential with inherited permissions, even with an API key.
            credential = OpenLocalCredential();
            if (credential is null || !credential.HasCredential)
                throw new QuotaReadException(I18n.Get("windows.codex.is.not.signed.in.sign.in.to.the.codex"));
            string? executable = testStartInfo is null ? FindExecutable() ??
                throw new QuotaReadException(I18n.Get("windows.codex.cli.not.found.install.it.or.set.codex.exe")) : null;
            using FileStream? executableFile = executable is null ? null : LocalFiles.OpenRead(executable, long.MaxValue);
            if (executableFile is not null) Authenticode.ValidateCodex(executable!, executableFile);
            lock (FailedCleanups)
            {
                if (CodexCleanupFault) throw new QuotaReadException(CleanupFaultMessage);
                process = new CodexCliProcess();
                process.Start(testStartInfo ?? CreateStartInfo(executable!));
            }

            // Drain stderr without retaining or exposing its contents.
            stderrTask = DrainErrorAsync(process.StandardError, timeout.Token);
            var output = new RpcOutput(process.StandardOutput);

            await SendAsync(process, new
            {
                id = 1,
                method = "initialize",
                @params = new { clientInfo = new { name = "ai_subgauge", title = "AI SubGauge", version = "1.2.0" } }
            }, timeout.Token).ConfigureAwait(false);
            await ReadResultAsync(output, 1, timeout.Token).ConfigureAwait(false);
            await SendAsync(process, new { method = "initialized", @params = new { } }, timeout.Token).ConfigureAwait(false);
            await SendAsync(process, new { id = 2, method = "account/read", @params = new { refreshToken = false } }, timeout.Token).ConfigureAwait(false);
            JsonElement accountResult = await ReadResultAsync(output, 2, timeout.Token).ConfigureAwait(false);
            if (!QuotaJson.TryProperty(accountResult, "account", out JsonElement account) || account.ValueKind == JsonValueKind.Null)
                throw new QuotaReadException(I18n.Get("windows.codex.is.not.signed.in.sign.in.to.the.codex"));
            if (QuotaJson.String(account, "type") != "chatgpt")
                throw new QuotaReadException(I18n.Get("windows.codex.is.not.signed.in.with.chatgpt.subscription.quota.cannot"));

            string plan = QuotaJson.String(account, "planType") ?? I18n.Get("windows.unknown.plan");
            await SendAsync(process, new { id = 3, method = "account/rateLimits/read" }, timeout.Token).ConfigureAwait(false);
            JsonElement limitsResult = await ReadResultAsync(output, 3, timeout.Token).ConfigureAwait(false);
            List<QuotaWindow> windows = ParseWindows(limitsResult);
            if (windows.Count == 0)
                throw new QuotaReadException(I18n.Get("windows.codex.returned.no.usable.quota.windows"));

            result = new QuotaSnapshot { Provider = this, Plan = plan, Windows = windows };
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            result = QuotaSnapshot.Failure(this, I18n.Get("windows.reading.codex.quota.timed.out.20.seconds"));
        }
        catch (OperationCanceledException) { throw; }
        catch (QuotaReadException error) { result = QuotaSnapshot.Failure(this, error.Message); }
        catch (JsonException) { result = QuotaSnapshot.Failure(this, I18n.Get("windows.codex.returned.data.in.an.invalid.format")); }
        catch (Exception) { result = QuotaSnapshot.Failure(this, I18n.Get("windows.could.not.start.or.communicate.with.the.codex.cli")); }
        finally
        {
            timeout.Cancel();
            try
            {
                if (process is not null)
                {
                    Task cleanup = StopCliAsync(process, beforeCleanup);
                    try
                    {
                        await cleanup.WaitAsync(cleanupTimeout ?? TimeSpan.FromSeconds(2)).ConfigureAwait(false);
                    }
                    catch (Exception)
                    {
                        // Transfer the job, stdio and all locks together; a root exit is insufficient.
                        CodexCliProcess running = process;
                        LocalFiles.CodexCredentialLock? retainedCredential = credential;
                        credential = null;
                        process = null;
                        result = QuotaSnapshot.Failure(this, CredentialAccess.UnsafeMessage);
                        Task deferred = ReleaseCredentialAfterExitAsync(running, retainedCredential, cleanup);
                        cleanupDeferred?.Invoke(deferred);
                    }
                    finally { process?.Dispose(); }
                }
                if (stderrTask is not null)
                {
                    try { await stderrTask.WaitAsync(TimeSpan.FromSeconds(1)).ConfigureAwait(false); }
                    catch (TimeoutException) { }
                }
            }
            finally { credential?.Dispose(); }
        }
        return result;
    }

    private static async Task StopCliAsync(CodexCliProcess process, Func<CodexCliProcess, Task>? beforeCleanup)
    {
        if (beforeCleanup is not null) await beforeCleanup(process).ConfigureAwait(false);
        await process.TerminateAndWaitAsync(TimeSpan.FromSeconds(2)).ConfigureAwait(false);
    }

    internal static async Task ReleaseCredentialAfterExitAsync(CodexCliProcess process, LocalFiles.CodexCredentialLock? credential,
        Task? pendingCleanup = null, Func<Task>? waitForExit = null, TimeSpan? retryTimeout = null,
        Func<TimeSpan>? clock = null, Func<TimeSpan, Task>? delay = null,
        Func<TimeSpan, Task>? terminateAndWait = null)
    {
        bool terminated = false;
        try
        {
            // Observe the foreground task before retrying, so it cannot race disposal after a timeout.
            try
            {
                if (pendingCleanup is not null) await pendingCleanup.ConfigureAwait(false);
                if (waitForExit is not null) await waitForExit().ConfigureAwait(false);
            }
            catch (Exception) { } // A failed wait still requires job termination and an empty-job query.

            var timer = Stopwatch.StartNew();
            clock ??= () => timer.Elapsed;
            delay ??= duration => Task.Delay(duration);
            terminateAndWait ??= process.TerminateAndWaitAsync;
            TimeSpan deadline = clock() + (retryTimeout ?? TimeSpan.FromMinutes(5));
            while (true)
            {
                TimeSpan remaining = deadline - clock();
                if (remaining <= TimeSpan.Zero) break;
                try
                {
                    await terminateAndWait(remaining < TimeSpan.FromSeconds(2) ? remaining : TimeSpan.FromSeconds(2)).ConfigureAwait(false);
                    terminated = true;
                    break;
                }
                catch (Exception)
                {
                    remaining = deadline - clock();
                    if (remaining <= TimeSpan.Zero) break;
                    await delay(remaining < TimeSpan.FromSeconds(1) ? remaining : TimeSpan.FromSeconds(1)).ConfigureAwait(false);
                }
            }
        }
        finally
        {
            if (terminated)
            {
                try { credential?.Dispose(); }
                finally { process.Dispose(); }
            }
            else
            {
                // Do not dispose on expiry. Static ownership also prevents SafeHandle finalization.
                lock (FailedCleanups) FailedCleanups.Add((process, credential));
            }
        }
    }

    internal static string? FindExecutable()
    {
        string? configured = Environment.GetEnvironmentVariable("CODEX_EXE");
        QuotaReadException? rejected = null;
        foreach (string candidate in FindCandidates(configured,
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData)))
        {
            try
            {
                string? trusted = TrustedExecutable(candidate);
                if (trusted is not null) return trusted;
            }
            catch (QuotaReadException error) { rejected = error; }
        }
        if (rejected is not null) throw rejected;
        if (!string.IsNullOrWhiteSpace(configured))
            throw new QuotaReadException(I18n.Get("windows.codex.trustedExeRequired"));
        return null;
    }

    internal static IEnumerable<string> FindCandidates(string? configured, string localAppData, string appData)
    {
        if (!string.IsNullOrWhiteSpace(configured))
        {
            yield return Environment.ExpandEnvironmentVariables(configured.Trim().Trim('"'));
            yield break; // An explicit override must pass the same signature gate; never fall back.
        }
        foreach (string root in new[] { Path.Combine(localAppData, "OpenAI", "Codex", "bin"),
            Path.Combine(appData, "npm", "node_modules", "@openai", "codex") })
        {
            string[] candidates;
            try
            {
                string fullRoot = LocalFiles.FullPath(root);
                candidates = Directory.Exists(fullRoot) ? Directory.EnumerateFiles(fullRoot, "codex.exe",
                    new EnumerationOptions { RecurseSubdirectories = true, AttributesToSkip = FileAttributes.ReparsePoint })
                    .OrderByDescending(File.GetLastWriteTimeUtc).ToArray() : Array.Empty<string>();
            }
            catch (Exception) { candidates = Array.Empty<string>(); }
            foreach (string candidate in candidates) yield return candidate;
        }
    }

    internal static Authenticode.SignatureResult[] InspectSigners()
    {
        var results = new List<Authenticode.SignatureResult>();
        foreach (string candidate in FindCandidates(Environment.GetEnvironmentVariable("CODEX_EXE"),
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData)))
        {
            try
            {
                string path = LocalFiles.FullPath(candidate);
                if (!Path.GetExtension(path).Equals(".exe", StringComparison.OrdinalIgnoreCase))
                    throw new IOException();
                using FileStream file = LocalFiles.OpenRead(path, long.MaxValue);
                results.Add(Authenticode.Inspect(path, file, Authenticode.CodexPublishers));
            }
            catch (Exception) { results.Add(new Authenticode.SignatureResult("UnreadableExecutable", null)); }
        }
        if (results.Count == 0) results.Add(new Authenticode.SignatureResult("NotFound", null));
        return results.ToArray();
    }

    private static string? TrustedExecutable(string path)
    {
        try
        {
            string fullPath = LocalFiles.FullPath(path);
            if (!Path.GetExtension(fullPath).Equals(".exe", StringComparison.OrdinalIgnoreCase)) return null;
            using FileStream file = LocalFiles.OpenRead(fullPath, long.MaxValue);
            try { Authenticode.ValidateCodex(fullPath, file); }
            catch (Exception) { throw new QuotaReadException(I18n.Get("windows.codex.signatureRequired")); }
            return fullPath;
        }
        catch (QuotaReadException) { throw; }
        catch (Exception) { return null; }
    }

    private static IEnumerable<string> AbsolutePathDirectories()
    {
        foreach (string entry in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator))
        {
            string? directory = null;
            try { directory = LocalFiles.FullPath(Environment.ExpandEnvironmentVariables(entry.Trim().Trim('"'))); }
            catch (Exception) { }
            if (directory is not null) yield return directory;
        }
    }

    private static ProcessStartInfo CreateStartInfo(string executable)
    {
        var info = new ProcessStartInfo
        {
            FileName = executable,
            WorkingDirectory = Path.GetDirectoryName(executable)!,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardInputEncoding = new UTF8Encoding(false),
            StandardOutputEncoding = new UTF8Encoding(false),
            StandardErrorEncoding = new UTF8Encoding(false)
        };
        foreach (string argument in new[] { "app-server", "--listen", "stdio://", "-c", "analytics.enabled=false" })
            info.ArgumentList.Add(argument);

        info.Environment.Clear();
        foreach (string name in new[]
        {
            "SystemRoot", "windir", "TEMP", "TMP", "USERPROFILE", "HOME", "LOCALAPPDATA", "APPDATA",
            "CODEX_HOME", "PROCESSOR_ARCHITECTURE", "PROCESSOR_ARCHITEW6432", "ComSpec", "PATHEXT"
        })
        {
            string? value = Environment.GetEnvironmentVariable(name);
            if (!string.IsNullOrWhiteSpace(value))
                info.Environment[name] = name == "CODEX_HOME" ? LocalFiles.FullPath(value) : value;
        }
        info.Environment["PATH"] = string.Join(Path.PathSeparator.ToString(), AbsolutePathDirectories().Distinct(StringComparer.OrdinalIgnoreCase));
        return info;
    }

    private static async Task DrainErrorAsync(Stream stream, CancellationToken cancellationToken)
    {
        try
        {
            byte[] buffer = new byte[4096];
            while (await stream.ReadAsync(buffer.AsMemory(), cancellationToken).ConfigureAwait(false) != 0) { }
        }
        catch (OperationCanceledException) { }
        catch (IOException) { }
        catch (ObjectDisposedException) { }
    }

    private static async Task SendAsync(CodexCliProcess process, object message, CancellationToken cancellationToken)
    {
        string json = JsonSerializer.Serialize(message);
        await process.StandardInput.WriteLineAsync(json.AsMemory(), cancellationToken).ConfigureAwait(false);
        await process.StandardInput.FlushAsync(cancellationToken).ConfigureAwait(false);
    }

    private static async Task<JsonElement> ReadResultAsync(RpcOutput output, int expectedId, CancellationToken cancellationToken)
    {
        while (true)
        {
            string? line = await output.ReadLineAsync(cancellationToken).ConfigureAwait(false);
            if (line is null)
                throw new QuotaReadException(I18n.Get("windows.the.codex.cli.closed.communication.early"));

            JsonDocument document;
            try { document = JsonDocument.Parse(line); }
            catch (JsonException) { continue; } // Ignore non-RPC startup lines as well as notifications.
            using (document)
            {
                JsonElement root = document.RootElement;
                if (!QuotaJson.TryProperty(root, "id", out JsonElement id) ||
                    id.ValueKind != JsonValueKind.Number || !id.TryGetInt32(out int number) || number != expectedId)
                    continue;
                if (QuotaJson.TryProperty(root, "error", out JsonElement error) && error.ValueKind != JsonValueKind.Null)
                    throw new QuotaReadException(I18n.Get("windows.codex.rejected.the.quota.request.check.the.cli.sign.in"));
                if (!QuotaJson.TryProperty(root, "result", out JsonElement result))
                    throw new QuotaReadException(I18n.Get("windows.codex.returned.data.in.an.invalid.format"));
                return result.Clone(); // The document is disposed before the caller receives the result.
            }
        }
    }

    private sealed class RpcOutput
    {
        private const int MaxLineBytes = 1_048_576;
        private const int MaxTotalBytes = 4_194_304;
        private readonly Stream _stream;
        private readonly byte[] _buffer = new byte[8192];
        private int _offset, _count, _total;

        public RpcOutput(Stream stream) => _stream = stream;

        public async Task<string?> ReadLineAsync(CancellationToken cancellationToken)
        {
            using var line = new MemoryStream();
            while (true)
            {
                if (_offset == _count)
                {
                    _count = await _stream.ReadAsync(_buffer.AsMemory(0, Math.Min(_buffer.Length, MaxTotalBytes + 1 - _total)), cancellationToken).ConfigureAwait(false);
                    _offset = 0;
                    _total += _count;
                    if (_total > MaxTotalBytes) throw new QuotaReadException(I18n.Get("windows.codex.stdout.exceeded.the.total.limit.4.mib"));
                    if (_count == 0)
                        return line.Length == 0 ? null : Decode(line);
                }
                int newline = Array.IndexOf(_buffer, (byte)'\n', _offset, _count - _offset);
                int take = (newline < 0 ? _count : newline) - _offset;
                if (line.Length + take > MaxLineBytes) throw new QuotaReadException(I18n.Get("windows.a.codex.stdout.line.exceeded.the.limit.1.mib"));
                line.Write(_buffer, _offset, take);
                _offset += take;
                if (newline >= 0)
                {
                    _offset++;
                    return Decode(line);
                }
            }
        }

        private static string Decode(MemoryStream line) => new UTF8Encoding(false, true)
            .GetString(line.GetBuffer(), 0, (int)line.Length).TrimEnd('\r');
    }

    private static List<QuotaWindow> ParseWindows(JsonElement result)
    {
        var windows = new List<QuotaWindow>();
        if (QuotaJson.TryProperty(result, "rateLimitsByLimitId", out JsonElement buckets) && buckets.ValueKind == JsonValueKind.Object)
        {
            foreach (JsonProperty bucket in buckets.EnumerateObject())
                AddBucket(windows, bucket.Name, bucket.Value);
        }
        if (windows.Count == 0 && QuotaJson.TryProperty(result, "rateLimits", out JsonElement single))
            AddBucket(windows, "codex", single);
        return windows;
    }

    private static void AddBucket(List<QuotaWindow> windows, string key, JsonElement bucket)
    {
        foreach (string kind in new[] { "primary", "secondary" })
        {
            if (!QuotaJson.TryProperty(bucket, kind, out JsonElement window) ||
                !QuotaJson.TryNumber(window, "usedPercent", out double used))
                continue;
            QuotaJson.TryNumber(window, "windowDurationMins", out double minutes);
            string title = minutes switch
            {
                300 => I18n.Get("quota.fiveHours"),
                10080 => I18n.Get("quota.weekly"),
                > 0 => I18n.Get("usage.0.minutes", minutes.ToString("0.#", CultureInfo.InvariantCulture)),
                _ => kind == "primary" ? I18n.Get("windows.primary.window") : I18n.Get("windows.secondary.window")
            };
            windows.Add(new QuotaWindow
            {
                Id = $"{key}.{kind}",
                Title = key == "codex" ? title : $"{key} · {title}",
                RemainingPercent = 100 - used,
                ResetsAt = QuotaJson.ResetTime(window, "resetsAt")
            });
        }
    }
}
