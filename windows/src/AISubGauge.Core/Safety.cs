using System.Text.RegularExpressions;

namespace AISubGauge.Core;

public sealed class Redactor
{
    private readonly HashSet<string> secrets = new(StringComparer.Ordinal);
    private readonly object sync = new();
    public void Register(string? value) { if (!string.IsNullOrEmpty(value)) lock (sync) secrets.Add(value); }
    public string Clean(string? input)
    {
        var text = input ?? "";
        lock (sync) foreach (var secret in secrets.OrderByDescending(x => x.Length)) text = text.Replace(secret, "[REDACTED]", StringComparison.Ordinal);
        text = Regex.Replace(text, @"(?i)(?:bearer\s+|sk-)[A-Za-z0-9._~+/=-]+", "[REDACTED]");
        text = Regex.Replace(text, @"[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}", "[REDACTED]");
        return Regex.Replace(text, "(?i)([\"']?(?:access_token|refresh_token|token|cookie|authorization|api_key|key)[\"']?\\s*[:=]\\s*)(?:[\"'][^\"']*[\"']|[^\\s,;]+)", "$1[REDACTED]");
    }
}
// Only enumerated events enter production logs. Never pass exception messages or HTTP bodies.
public sealed class SafeLog(Redactor redactor, Action<string>? sink = null, string? directory = null)
{
    private static readonly object FileSync = new();
    public const int MaxBytes = 1024 * 1024;
    public static string DefaultDirectory => Path.Combine(SettingsStore.DefaultDirectory, "logs");
    public void Write(Vendor vendor, Fault fault, FailureStage stage = FailureStage.UsageRpc, int? httpStatus = null)
    {
        if (fault == Fault.None) return;
        // All fields are closed enums or bounded numbers; no exception text, credentials or paths.
        try
        {
            string line = $"{DateTimeOffset.UtcNow:O} vendor={vendor} stage={StageName(stage)} fault={fault}" +
                (httpStatus is >= 100 and <= 599 ? $" http={httpStatus}" : "");
            Emit(redactor.Clean(line));
        }
        catch { }
    }
    private static string StageName(FailureStage stage) => stage switch
    {
        FailureStage.ReadCredentials => "read-credentials", FailureStage.RefreshRpc => "refresh-rpc",
        FailureStage.RefreshHttp => "refresh-http", FailureStage.BillingHttp => "billing-http",
        FailureStage.UsageHttp => "usage-http", FailureStage.Parse => "parse", FailureStage.Cache => "cache",
        FailureStage.SignInLaunch => "sign-in-launch", _ => "usage-rpc"
    };
    private void Emit(string line)
    {
        // A broken observer must not prevent file logging (or escape into a provider).
        try { sink?.Invoke(line); } catch { }
        if (directory is null) return; // Tests and non-app consumers opt in explicitly.
        try
        {
            lock (FileSync)
            {
                Directory.CreateDirectory(directory);
                string path = Path.Combine(directory, "app.log");
                if (File.Exists(path) && new FileInfo(path).Length > MaxBytes)
                    File.Move(path, Path.Combine(directory, "app.1.log"), true);
                File.AppendAllText(path, line + Environment.NewLine, new System.Text.UTF8Encoding(false));
            }
        }
        catch { }
    }
    public void Write(LocalStatus status)
    {
        // Diagnostics must never interrupt startup or cleanup, even if the sink fails.
        try { if (sink is null) System.Diagnostics.Trace.WriteLine(status.ToString()); else sink(status.ToString()); } catch { }
    }
}
public enum LocalStatus { AutostartFailed, RefreshCleanupFailed, VerifierBusyRepeated }
public enum FailureStage { ReadCredentials, RefreshRpc, RefreshHttp, BillingHttp, UsageHttp, UsageRpc, Parse, Cache, SignInLaunch }
public sealed class SafeFailure(Fault fault, ExecutableVerification? verification = null,
    FailureStage? stage = null, int? httpStatus = null) : Exception("Subscription request failed.")
{
    public Fault Fault { get; } = fault;
    public ExecutableVerification? Verification { get; } = verification;
    public FailureStage? Stage { get; } = stage;
    public int? HttpStatus { get; } = httpStatus;
    public static SafeFailure Classify(Exception error, FailureStage stage, Fault fallback = Fault.InvalidData)
    {
        if (error is SafeFailure safe)
        {
            var kind = safe.HttpStatus is 401 or 403 ? Fault.SignIn : safe.Fault;
            if (kind == Fault.InvalidData && fallback == Fault.RefreshFailed) kind = Fault.RefreshFailed;
            return new(kind, safe.Verification, safe.Stage ?? stage, safe.HttpStatus);
        }
        int? status = error is HttpRequestException http && http.StatusCode is { } code ? (int)code : null;
        return new(status is 401 or 403 ? Fault.SignIn : error switch
        {
            HttpRequestException => Fault.Network, OperationCanceledException => Fault.Timeout,
            FileNotFoundException or DirectoryNotFoundException => Fault.SignIn, _ => fallback
        }, stage: stage, httpStatus: status);
    }
    public static async Task<T> AtAsync<T>(FailureStage stage, Func<Task<T>> action)
    {
        try { return await action().ConfigureAwait(false); }
        catch (Exception error) { throw Classify(error, stage); }
    }
}
// Intentionally not a record: neither ToString nor serialization should reveal credentials.
public sealed class Credential(string token, string userId = "", string clientId = "", DateTimeOffset? expires = null, Plan plan = Plan.Unknown)
{
    internal string Token { get; } = token;
    internal string UserId { get; } = userId;
    internal string ClientId { get; } = clientId;
    public DateTimeOffset? Expires { get; } = expires;
    public Plan Plan { get; } = plan;
    public override string ToString() => "Credential [REDACTED]";
    internal void Protect(Redactor redactor) { redactor.Register(Token); redactor.Register(UserId); redactor.Register(ClientId); }
}
