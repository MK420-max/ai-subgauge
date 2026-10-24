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
public sealed class SafeLog(Redactor redactor, Action<string>? sink = null)
{
    public void Write(Vendor vendor, Fault fault) => sink?.Invoke(redactor.Clean($"{vendor}: {fault}"));
    public void Write(LocalStatus status)
    {
        // Diagnostics must never interrupt startup or cleanup, even if the sink fails.
        try { if (sink is null) System.Diagnostics.Trace.WriteLine(status.ToString()); else sink(status.ToString()); } catch { }
    }
}
public enum LocalStatus { AutostartFailed, RefreshCleanupFailed, VerifierBusyRepeated }
public sealed class SafeFailure(Fault fault, ExecutableVerification? verification = null) : Exception("Subscription request failed.")
{
    public Fault Fault { get; } = fault;
    public ExecutableVerification? Verification { get; } = verification;
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
