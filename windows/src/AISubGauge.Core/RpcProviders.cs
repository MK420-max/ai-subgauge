using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace AISubGauge.Core;

public static class RefreshCleanup
{
    public static void TryDelete(string directory, SafeLog log, Action<string>? delete = null, Action<int>? sleep = null)
    {
        Action<string> remove = delete ?? (path => Directory.Delete(path, true));
        bool managed = delete is null;
        if (managed && !Directory.Exists(directory)) return;
        for (int attempt = 1; attempt <= 3; ++attempt)
        {
            try { remove(directory); return; }
            catch (Exception error)
            {
                if (managed && !Directory.Exists(directory)) return;
                if (error is not (IOException or UnauthorizedAccessException) || attempt == 3)
                {
                    log.Write(LocalStatus.RefreshCleanupFailed);
                    return;
                }
                Action<int> delay = sleep ?? (milliseconds => System.Threading.Thread.Sleep(milliseconds));
                delay(100);
            }
        }
    }
}

public interface IRpcSession : IAsyncDisposable { Task<JsonElement> CallAsync(int id, string method, object? parameters, CancellationToken cancellation); Task NotifyAsync(string method, CancellationToken cancellation); }
public sealed class RpcSession : IRpcSession
{
    public static readonly System.Collections.Concurrent.ConcurrentDictionary<int, byte> ActiveProcessIds = new();
    private readonly Process process;
    private readonly Task drain;
    private readonly CancellationTokenSource lifetime = new();
    private int total;
    public RpcSession(string executable, IEnumerable<string> arguments, string? directory = null, IDictionary<string, string>? environment = null)
    {
        using var executableFile = LocalFiles.OpenRead(executable, long.MaxValue);
        var info = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            WorkingDirectory = directory ?? Path.GetDirectoryName(executable)!, StandardInputEncoding = new UTF8Encoding(false) };
        foreach (string argument in arguments) info.ArgumentList.Add(argument);
        info.Environment.Clear();
        foreach (string key in new[] { "SystemRoot", "WINDIR", "COMSPEC", "PATH", "PATHEXT", "USERPROFILE", "HOMEDRIVE", "HOMEPATH", "TEMP", "TMP", "APPDATA", "LOCALAPPDATA", "ProgramData", "ProgramFiles", "ProgramFiles(x86)", "CODEX_HOME" })
            if (Environment.GetEnvironmentVariable(key) is string value) info.Environment[key] = value;
        if (environment is not null) foreach (var pair in environment) info.Environment[pair.Key] = pair.Value;
        process = new Process { StartInfo = info };
        if (!process.Start()) { process.Dispose(); throw new SafeFailure(Fault.Network); }
        ActiveProcessIds.TryAdd(process.Id, 0);
        drain = process.StandardError.BaseStream.CopyToAsync(Stream.Null, lifetime.Token);
    }
    private async Task Send(object value, CancellationToken cancellation)
    {
        await process.StandardInput.WriteLineAsync(JsonSerializer.Serialize(value).AsMemory(), cancellation).ConfigureAwait(false);
        await process.StandardInput.FlushAsync(cancellation).ConfigureAwait(false);
    }
    public Task NotifyAsync(string method, CancellationToken cancellation) => Send(new { jsonrpc = "2.0", method }, cancellation);
    public async Task<JsonElement> CallAsync(int id, string method, object? parameters, CancellationToken cancellation)
    {
        await Send(new { jsonrpc = "2.0", id, method, @params = parameters }, cancellation).ConfigureAwait(false);
        while (true)
        {
            string line = await ReadLine(cancellation).ConfigureAwait(false);
            JsonDocument document;
            try { document = JsonDocument.Parse(line); } catch (JsonException) { continue; }
            using (document)
            {
                var root = document.RootElement;
                if (Json.Number(root, "id") != id) continue;
                if (Json.Get(root, "error").ValueKind is not (JsonValueKind.Undefined or JsonValueKind.Null)) throw RpcError(Json.Get(root, "error"));
                var result = Json.Get(root, "result");
                if (result.ValueKind == JsonValueKind.Undefined) throw new SafeFailure(Fault.InvalidData);
                return result.Clone();
            }
        }
    }
    internal static SafeFailure RpcError(JsonElement error)
    {
        var data = Json.Get(error, "data");
        double? number = Json.Number(data, "statusCode") ?? Json.Number(data, "status") ?? Json.Number(error, "code");
        int? status = number is >= 100 and <= 599 && number == Math.Truncate(number.Value) ? (int)number.Value : null;
        // Match explicit auth codes/messages, never a substring in an arbitrary server error.
        bool unauthenticated = new[] { Json.String(error, "code"), Json.String(data, "code"),
            Json.String(data, "type"), Json.String(data, "status"), Json.String(data, "error"), Json.String(error, "message") }
            .Any(value => value?.ToLowerInvariant() is "unauthenticated" or "unauthorized" or "invalid_grant" or "invalid_token");
        return new(status is 401 or 403 || unauthenticated ? Fault.SignIn : Fault.Network, httpStatus: status);
    }
    private async Task<string> ReadLine(CancellationToken cancellation)
    {
        using var line = new MemoryStream(); var one = new byte[1];
        while (true)
        {
            if (await process.StandardOutput.BaseStream.ReadAsync(one, cancellation).ConfigureAwait(false) == 0) throw new SafeFailure(Fault.InvalidData);
            if (++total > 4194304 || line.Length > 1048576) throw new SafeFailure(Fault.InvalidData);
            if (one[0] == 10) return Encoding.UTF8.GetString(line.ToArray());
            line.WriteByte(one[0]);
        }
    }
    public async ValueTask DisposeAsync()
    {
        lifetime.Cancel();
        try { if (!process.HasExited) process.Kill(true); } catch { }
        try { await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(2)).ConfigureAwait(false); } catch { }
        try { await drain.WaitAsync(TimeSpan.FromSeconds(2)).ConfigureAwait(false); } catch { }
        ActiveProcessIds.TryRemove(process.Id, out _); process.Dispose(); lifetime.Dispose();
    }
}
public sealed class CodexProvider(IClock clock, SafeLog log, Func<IRpcSession>? factory = null,
    Func<bool>? allowUnsignedNpm = null, Func<Task<VerifiedExecutable>>? resolve = null) : ProviderBase(clock, log)
{
    public override Vendor Vendor => Vendor.Codex;
    protected override async Task<Snapshot> FetchCoreAsync(CancellationToken cancellation)
    {
        using var executable = factory is null ? await (resolve?.Invoke() ?? Executables.OpenAsync("codex", allowUnsignedNpm?.Invoke() ?? false)).ConfigureAwait(false) : null;
        await using var rpc = factory?.Invoke() ?? new RpcSession(executable!.Path, ["app-server", "--listen", "stdio://", "-c", "analytics.enabled=false"]);
        await rpc.CallAsync(1, "initialize", new { clientInfo = new { name = "aisubgauge2", version = "2.0.0" } }, cancellation).ConfigureAwait(false);
        await rpc.NotifyAsync("initialized", cancellation).ConfigureAwait(false);
        var account = Json.Get(await rpc.CallAsync(2, "account/read", new { refreshToken = false }, cancellation).ConfigureAwait(false), "account");
        if (Json.String(account, "type") != "chatgpt") throw new SafeFailure(Fault.SignInRequired);
        var plan = Presentation.ParsePlan(Json.String(account, "planType"));
        var result = await rpc.CallAsync(3, "account/rateLimits/read", null, cancellation).ConfigureAwait(false);
        var bucket = Json.Get(Json.Get(result, "rateLimitsByLimitId"), "codex");
        if (bucket.ValueKind != JsonValueKind.Object) bucket = Json.Get(result, "rateLimits");
        Window five = new(), week = new();
        foreach (string kind in new[] { "primary", "secondary" })
        {
            var window = Json.Get(bucket, kind);
            var minutes = Json.Number(window, "windowDurationMins");
            if (minutes == 300) five = Json.Usage(bucket, kind, "usedPercent", "resetsAt");
            if (minutes == 10080) week = Json.Usage(bucket, kind, "usedPercent", "resetsAt");
        }
        return new(Vendor, plan, five, week, Clock.Now);
    }
}
public sealed class GrokCliRefresh(ICredentialSource source, IClock clock, Func<Credential, IRpcSession>? factory = null, SafeLog? log = null, string? scratchRoot = null) : IGrokRefresh
{
    public async Task<Credential> RefreshAsync(Credential expected, CancellationToken cancellation)
    {
        string? directory = null;
        try
        {
            if (factory is null || scratchRoot is not null)
            {
                directory = Path.Combine(scratchRoot ?? Path.Combine(SettingsStore.DefaultDirectory, "refresh"), Guid.NewGuid().ToString("N"));
                Directory.CreateDirectory(directory);
            }
            IRpcSession session;
            if (factory is not null) session = factory(expected);
            else
            {
                // Keep CLI scratch state within the new app's directory; never touch 1.x settings.
                var current = await SafeFailure.AtAsync(FailureStage.ReadCredentials, () => source.ReadAsync(Vendor.Grok, cancellation)).ConfigureAwait(false);
                if (current is null) throw new SafeFailure(Fault.RefreshFailed);
                if (current.UserId != expected.UserId || current.ClientId != expected.ClientId) throw new SafeFailure(Fault.SignIn);
                using var executable = await Executables.OpenAsync("grok").ConfigureAwait(false);
                session = new RpcSession(executable.Path, ["agent", "stdio"], directory!, new Dictionary<string, string>
                {
                    ["GROK_HOME"] = directory!, ["GROK_AUTH_PATH"] = CredentialFiles.GrokPath,
                    ["GROK_OAUTH2_CLIENT_ID"] = expected.ClientId, ["GROK_OAUTH2_ISSUER"] = "https://auth.x.ai",
                    ["GROK_TELEMETRY_ENABLED"] = "0", ["GROK_EXTERNAL_OTEL"] = "0", ["GROK_LOG_FILE"] = "NUL", ["RUST_LOG"] = "off"
                });
            }
            await using (session)
            {
                await session.CallAsync(1, "initialize", new { protocolVersion = 1, clientCapabilities = new { } }, cancellation).ConfigureAwait(false);
                // Discard the RPC bearer; the official CLI owns credential rotation and persistence.
                await session.CallAsync(2, "_x.ai/auth/getBearerToken", new { }, cancellation).ConfigureAwait(false);
            }
            var refreshed = await SafeFailure.AtAsync(FailureStage.ReadCredentials, () => source.ReadAfterRefreshAsync(cancellation)).ConfigureAwait(false);
            if (refreshed is not null && (refreshed.UserId != expected.UserId || refreshed.ClientId != expected.ClientId))
                throw new SafeFailure(Fault.SignIn);
            // A successful RPC can precede the CLI's credential write. Keep retrying
            // missing/stale expiry; only an explicit authentication rejection stops retries.
            if (refreshed is null || refreshed.Expires is null || refreshed.Expires <= clock.Now) throw new SafeFailure(Fault.RefreshFailed);
            return refreshed;
        }
        catch (Exception error)
        {
            var stage = error is HttpRequestException || error is SafeFailure { HttpStatus: not null }
                ? FailureStage.RefreshHttp : FailureStage.RefreshRpc;
            throw SafeFailure.Classify(error, stage, Fault.Network);
        }
        finally
        {
            // This exact newly-created GUID folder is the only recursive deletion target.
            if (directory is not null) RefreshCleanup.TryDelete(directory, log ?? new SafeLog(new Redactor()));
        }
    }
}

