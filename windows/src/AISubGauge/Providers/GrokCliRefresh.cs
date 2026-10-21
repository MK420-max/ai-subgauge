using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace AISubGauge.Providers;

internal static class GrokCliRefresh
{
    internal static string FailurePrefix => I18n.Get("windows.grok.token.renewal.failed");
    internal static readonly string[] EnvironmentAllowlist =
    {
        "SystemRoot", "windir", "TEMP", "TMP", "USERPROFILE", "HOME", "LOCALAPPDATA", "APPDATA",
        "PATH", "GROK_HOME", "GROK_AUTH_PATH", "ComSpec", "PATHEXT", "PROCESSOR_ARCHITECTURE"
    };

    internal static string FindExecutable() => Environment.GetEnvironmentVariable("GROK_CLI_PATH") is string configured &&
        !string.IsNullOrWhiteSpace(configured) ? configured :
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".grok", "bin", "grok.exe");

    internal static FileStream OpenExecutable(string path)
    {
        try
        {
            string full = LocalFiles.FullPath(path);
            if (!Path.GetExtension(full).Equals(".exe", StringComparison.OrdinalIgnoreCase))
                throw new QuotaReadException(I18n.Get("windows.the.grok.cli.must.be.a.trusted.absolute.local.exe"));
            return LocalFiles.OpenRead(full, long.MaxValue); // Keep the image locked until the process is stopped.
        }
        catch (QuotaReadException) { throw; }
        catch (FileNotFoundException) { throw new QuotaReadException(I18n.Get("windows.grok.cli.not.found.install.the.official.client.or.check")); }
        catch (DirectoryNotFoundException) { throw new QuotaReadException(I18n.Get("windows.grok.cli.not.found.install.the.official.client.or.check")); }
        catch (Exception) { throw new QuotaReadException(I18n.Get("windows.the.grok.cli.path.is.unsafe.or.inaccessible.execution.refused")); }
    }

    internal static ProcessStartInfo CreateStartInfo(string executable, string folder, string authPath)
    {
        var info = new ProcessStartInfo
        {
            FileName = executable, WorkingDirectory = folder, UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            StandardInputEncoding = new UTF8Encoding(false), StandardOutputEncoding = new UTF8Encoding(false)
        };
        info.ArgumentList.Add("agent");
        info.ArgumentList.Add("stdio");
        info.Environment.Clear();
        foreach (string name in EnvironmentAllowlist)
        {
            string? value = Environment.GetEnvironmentVariable(name);
            if (value is not null) info.Environment[name] = value;
        }
        info.Environment["GROK_HOME"] = folder;
        info.Environment["GROK_AUTH_PATH"] = authPath;
        info.Environment["GROK_LOG_FILE"] = "NUL";
        info.Environment["RUST_LOG"] = "off";
        info.Environment["GROK_TELEMETRY_ENABLED"] = "0";
        info.Environment["GROK_EXTERNAL_OTEL"] = "0";
        return info;
    }

    public static Task<GrokProvider.Credential> RefreshAsync(string authPath, GrokProvider.Credential expected,
        CancellationToken cancellationToken) => RefreshCoreAsync(FindExecutable(), authPath, expected, null, cancellationToken);

    private static async Task<GrokProvider.Credential> RefreshCoreAsync(string executable, string authPath,
        GrokProvider.Credential expected, string? selfTestHome, CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(20));
        string folder = selfTestHome ?? Path.Combine(Path.GetTempPath(), "aisubgauge-grok-refresh-" + Guid.NewGuid().ToString("N"));
        Process? process = null;
        FileStream? image = null;
        Task drain = Task.CompletedTask;
        bool started = false;
        try
        {
            if (!expected.CanRefresh) throw new QuotaReadException(I18n.Get("windows.the.current.login.method.cannot.be.renewed.sign.in.again"));
            GrokProvider.Credential? current = await GrokProvider.ReadCredentialAsync(authPath, timeout.Token).ConfigureAwait(false);
            if (current is null || !current.CanRefresh || current.UserId != expected.UserId || current.ClientId != expected.ClientId)
                throw new QuotaReadException(I18n.Get("windows.the.signed.in.account.changed.confirm.the.account.in.the"));
            image = OpenExecutable(executable);
            if (selfTestHome is null) Authenticode.Validate(executable, image);
            if (selfTestHome is null) CredentialAccess.CreatePrivateDirectory(folder);
            timeout.Token.ThrowIfCancellationRequested();
            process = new Process { StartInfo = CreateStartInfo(executable, folder, authPath) };
            started = process.Start();
            if (!started) throw new QuotaReadException(I18n.Get("windows.could.not.start.the.official.cli"));
            drain = process.StandardError.BaseStream.CopyToAsync(Stream.Null, timeout.Token);
            var reader = new AcpReader(process.StandardOutput.BaseStream);
            await RequestAsync(process, reader, 1, "initialize", new { protocolVersion = 1, clientCapabilities = new { } }, timeout.Token).ConfigureAwait(false);
            await RequestAsync(process, reader, 2, "_x.ai/auth/getBearerToken", new { }, timeout.Token).ConfigureAwait(false);
            await StopAsync(process).ConfigureAwait(false);
            // Deliberately ignore the returned bearer; only the official CLI writes auth.json.
            CredentialAccess.CheckAfterRefresh(authPath);
            GrokProvider.Credential? refreshed = await GrokProvider.ReadCredentialAsync(authPath, timeout.Token).ConfigureAwait(false);
            if (refreshed is null || refreshed.ExpiresAt <= DateTimeOffset.UtcNow.AddSeconds(15) ||
                refreshed.UserId != expected.UserId || refreshed.ClientId != expected.ClientId)
                throw new QuotaReadException(I18n.Get("windows.renewal.did.not.return.a.valid.login.for.the.same"));
            return refreshed;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
        catch (OperationCanceledException) { throw new QuotaReadException(FailurePrefix + I18n.Get("windows.the.official.cli.timed.out.20.seconds")); }
        catch (QuotaReadException error) { throw new QuotaReadException(FailurePrefix + error.Message); }
        catch (Exception) { throw new QuotaReadException(FailurePrefix + I18n.Get("windows.official.cli.startup.communication.or.credential.validation.failed")); }
        finally
        {
            timeout.Cancel();
            if (process is not null)
            {
                if (started)
                {
                    await StopAsync(process).ConfigureAwait(false);
                    // A failed CLI may still have replaced the file or widened its permissions.
                    // Recheck even after protocol failure; never read its bytes on this path.
                    try { CredentialAccess.CheckAfterRefresh(authPath); }
                    catch (Exception) { } // The failed operation remains failed; never reveal OS/CLI exception text.
                }
                try { await drain.WaitAsync(TimeSpan.FromSeconds(1)).ConfigureAwait(false); }
                catch (Exception) { }
                process.Dispose();
            }
            image?.Dispose();
            // Retain the private working directory; never delete a user file during renewal.
        }
    }

    internal sealed record SelfTestResult(bool success, string? error);

    // Signature bypass is reachable only through this isolated synthetic-credential test path.
    internal static async Task<SelfTestResult> SelfTestAsync(string executable, string mode = "success",
        CancellationToken cancellationToken = default)
    {
        string home = Path.Combine(Path.GetTempPath(), "aisubgauge-selftest-" + Guid.NewGuid().ToString("N"));
        try
        {
            // Create with a protected owner-only DACL, before any synthetic file is written;
            // %TEMP% may explicitly grant other local users/groups Modify permission.
            CredentialAccess.CreatePrivateDirectory(home);
            string path = Path.Combine(home, "auth.json");
            File.WriteAllText(Path.Combine(home, "test-mode"), mode);
            // This fixture never contains or copies a real user's login information.
            File.WriteAllText(path, JsonSerializer.Serialize(new System.Collections.Generic.Dictionary<string, object>
            {
                ["https://auth.x.ai::test-client"] = new
                {
                    auth_mode = "oidc", oidc_issuer = "https://auth.x.ai", oidc_client_id = "test-client",
                    user_id = "test-user", key = "expired-fixture-token", refresh_token = "synthetic-refresh-token", create_time = DateTimeOffset.UtcNow.AddDays(-31).ToString("O"),
                    expires_at = DateTimeOffset.UtcNow.AddHours(-1).ToString("O")
                }
            }));
            GrokProvider.Credential expected = await GrokProvider.ReadCredentialAsync(path, cancellationToken).ConfigureAwait(false)
                ?? throw new QuotaReadException(I18n.Get("windows.invalid.test.credentials"));
            await RefreshCoreAsync(executable, path, expected, home, cancellationToken).ConfigureAwait(false);
            return new SelfTestResult(true, null);
        }
        catch (OperationCanceledException) { return new SelfTestResult(false, FailurePrefix + I18n.Get("windows.test.cancelled")); }
        catch (QuotaReadException error) { return new SelfTestResult(false, error.Message); }
        catch (Exception) { return new SelfTestResult(false, FailurePrefix + I18n.Get("windows.invalid.test.setup.or.cli")); }
    }

    private static async Task StopAsync(Process process)
    {
        try { if (!process.HasExited) process.Kill(entireProcessTree: true); }
        catch (Exception) { }
        try { await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(2)).ConfigureAwait(false); }
        catch (Exception) { }
    }

    private static async Task RequestAsync(Process process, AcpReader reader, int id, string method, object parameters, CancellationToken cancellationToken)
    {
        string line = JsonSerializer.Serialize(new { jsonrpc = "2.0", id, method, @params = parameters });
        await process.StandardInput.WriteLineAsync(line.AsMemory(), cancellationToken).ConfigureAwait(false);
        await process.StandardInput.FlushAsync(cancellationToken).ConfigureAwait(false);
        await reader.ReadResultAsync(id, cancellationToken).ConfigureAwait(false);
    }

    private sealed class AcpReader
    {
        private readonly Stream _stream;
        private readonly byte[] _buffer = new byte[GrokProvider.MaxBytes + 1];
        private int _length;
        private int _total;

        public AcpReader(Stream stream) => _stream = stream;

        public async Task ReadResultAsync(int expectedId, CancellationToken cancellationToken)
        {
            while (true)
            {
                cancellationToken.ThrowIfCancellationRequested();
                int end = Array.IndexOf(_buffer, (byte)'\n', 0, _length);
                if (end >= 0)
                {
                    bool matched = false;
                    try
                    {
                        using JsonDocument document = JsonDocument.Parse(_buffer.AsMemory(0, end));
                        JsonElement root = document.RootElement;
                        matched = QuotaJson.TryProperty(root, "id", out JsonElement id) && id.ValueKind == JsonValueKind.Number &&
                            id.TryGetInt32(out int number) && number == expectedId;
                        if (matched && (QuotaJson.TryProperty(root, "error", out _) || !QuotaJson.TryProperty(root, "result", out _)))
                            throw new QuotaReadException(I18n.Get("windows.official.grok.cli.automatic.renewal.failed.sign.in.again"));
                    }
                    catch (JsonException) { } // Ignore startup text and unrelated notifications.
                    _length -= end + 1;
                    Array.Copy(_buffer, end + 1, _buffer, 0, _length);
                    if (matched) return;
                    continue;
                }
                int count = await _stream.ReadAsync(_buffer.AsMemory(_length, Math.Min(8192, _buffer.Length - _length)), cancellationToken).ConfigureAwait(false);
                if (count == 0) throw new QuotaReadException(I18n.Get("windows.the.official.grok.cli.renewal.endpoint.closed.early"));
                _length += count;
                _total += count;
                if (_total > GrokProvider.MaxBytes)
                    throw new QuotaReadException(I18n.Get("windows.the.official.grok.cli.renewal.response.exceeded.the.size.limit"));
            }
        }
    }
}
