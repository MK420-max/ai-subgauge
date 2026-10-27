using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;
using System.Globalization;

namespace AISubGauge.Core;

public interface IProvider { Vendor Vendor { get; } Task<Snapshot> FetchAsync(CancellationToken cancellation = default); }
public interface ICredentialSource { Task<Credential?> ReadAsync(Vendor vendor, CancellationToken cancellation); }
public interface IGrokRefresh { Task<Credential> RefreshAsync(Credential expected, CancellationToken cancellation); }
public interface IGrokCache { Task<Snapshot> ReadAsync(CancellationToken cancellation); }

public static class Json
{
    public static JsonElement Get(JsonElement root, string name)
    {
        if (root.ValueKind != JsonValueKind.Object) return default;
        foreach (var property in root.EnumerateObject())
            if (property.Name.Replace("_", "").Equals(name.Replace("_", ""), StringComparison.OrdinalIgnoreCase)) return property.Value;
        return default;
    }
    public static string? String(JsonElement root, string name) => Get(root, name) is var x && x.ValueKind == JsonValueKind.String ? x.GetString() : null;
    public static double? Number(JsonElement root, string name)
    {
        var x = Get(root, name);
        if (x.ValueKind == JsonValueKind.Number && x.TryGetDouble(out var n) && double.IsFinite(n)) return n;
        if (x.ValueKind == JsonValueKind.String && double.TryParse(x.GetString(), NumberStyles.Float, CultureInfo.InvariantCulture, out n) && double.IsFinite(n)) return n;
        return null;
    }
    public static DateTimeOffset? Date(JsonElement root, string name)
    {
        try
        {
            if (Number(root, name) is double number) return Math.Abs(number) >= 1e12 ? DateTimeOffset.FromUnixTimeMilliseconds((long)number) : DateTimeOffset.FromUnixTimeSeconds((long)number);
            return DateTimeOffset.TryParse(String(root, name), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var result) ? result : null;
        }
        catch { return null; }
    }
    public static Window Usage(JsonElement root, string name, string percent = "utilization", string reset = "resets_at")
    {
        var window = Get(root, name);
        double? used = Number(window, percent);
        if (used < 0) throw new SafeFailure(Fault.InvalidData);
        return new(used is double n ? Math.Clamp(100 - n, 0, 100) : null, Date(window, reset));
    }
    public static async Task<JsonDocument> ReadAsync(Stream stream, CancellationToken cancellation)
    {
        using var data = new MemoryStream();
        var buffer = new byte[8192];
        while (true)
        {
            int count = await stream.ReadAsync(buffer, cancellation).ConfigureAwait(false);
            if (count == 0) break;
            if (data.Length + count > 1048576) throw new SafeFailure(Fault.InvalidData);
            data.Write(buffer, 0, count);
        }
        return JsonDocument.Parse(data.ToArray());
    }
}
public abstract class ProviderBase(IClock clock, SafeLog log) : IProvider
{
    public abstract Vendor Vendor { get; }
    protected IClock Clock { get; } = clock;
    protected SafeLog Log { get; } = log;
    protected abstract Task<Snapshot> FetchCoreAsync(CancellationToken cancellation);
    protected virtual Snapshot OnResult(Snapshot snapshot, SafeFailure? failure) => snapshot;
    public async Task<Snapshot> FetchAsync(CancellationToken cancellation = default)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        timeout.CancelAfter(TimeSpan.FromSeconds(45));
        try
        {
            var result = await FetchCoreAsync(timeout.Token).ConfigureAwait(false);
            if (result.FiveHour.Percent is null && result.Weekly.Percent is null && result.Fault == Fault.None) throw new SafeFailure(Fault.InvalidData);
            Log.Write(Vendor, result.Fault);
            return OnResult(result, null);
        }
        catch (Exception error)
        {
            var failure = SafeFailure.Classify(error, FailureStage.UsageRpc);
            Log.Write(Vendor, failure.Fault, failure.Stage!.Value, failure.HttpStatus, failure.Verification);
            return OnResult(Snapshot.Failure(Vendor, failure.Fault, Clock), failure);
        }
    }
}
public sealed class SubscriptionProvider : ProviderBase, IDisposable
{
    private readonly HttpClient client;
    private readonly ICredentialSource source;
    private readonly IGrokRefresh? refresh;
    private readonly IGrokCache? cache;
    private readonly Redactor redactor;
    private Credential? renewed;
    private Credential? renewalSource;
    private Credential? observed;
    private DateTimeOffset? activeExpiry;
    private Snapshot? lastGood;
    private readonly GrokLastGoodStore? lastGoodStore;
    public GrokRefreshPolicy RefreshPolicy { get; }
    public DateTimeOffset NextBackgroundRefresh { get; private set; } = DateTimeOffset.MaxValue;
    public override Vendor Vendor { get; }
    public SubscriptionProvider(Vendor vendor, ICredentialSource source, IClock clock, Redactor redactor, SafeLog log,
        HttpMessageHandler? handler = null, IGrokRefresh? refresh = null, IGrokCache? cache = null,
        GrokLastGoodStore? lastGoodStore = null, Func<double>? jitter = null) : base(clock, log)
    {
        if (vendor == Vendor.Codex) throw new ArgumentException("Use the Codex RPC provider.");
        Vendor = vendor; this.source = source; this.refresh = refresh; this.cache = cache; this.redactor = redactor;
        RefreshPolicy = new(clock, jitter); this.lastGoodStore = lastGoodStore;
        if (vendor == Vendor.Grok) lastGood = lastGoodStore?.Load();
        client = new HttpClient(handler ?? new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false, UseDefaultCredentials = false }) { Timeout = TimeSpan.FromSeconds(20) };
    }
    protected override async Task<Snapshot> FetchCoreAsync(CancellationToken cancellation)
    {
        var stage = FailureStage.ReadCredentials;
        try
        {
            var credential = await source.ReadAsync(Vendor, cancellation).ConfigureAwait(false);
            if (credential is null)
            {
                if (Vendor == Vendor.Grok && cache is not null)
                {
                    stage = FailureStage.Cache;
                    var cached = await cache.ReadAsync(cancellation).ConfigureAwait(false);
                    if (cached.Fault != Fault.None) throw new SafeFailure(cached.Fault);
                    if (cached.FiveHour.Percent is null && cached.Weekly.Percent is null) throw new SafeFailure(Fault.InvalidData);
                    return cached;
                }
                throw new SafeFailure(Fault.SignInRequired);
            }
            credential.Protect(redactor);
            if (Vendor == Vendor.Grok && (observed is null || observed.Token != credential.Token ||
                observed.Expires != credential.Expires || observed.UserId != credential.UserId || observed.ClientId != credential.ClientId))
            {
                RefreshPolicy.Reset(); observed = credential;
            }
            if (renewed is not null && credential.Token == renewalSource?.Token && renewed.UserId == credential.UserId && renewed.ClientId == credential.ClientId && renewed.Expires > Clock.Now && renewed.Expires > credential.Expires) credential = renewed;
            activeExpiry = credential.Expires;
            if (Vendor == Vendor.Grok) RefreshPolicy.ThrowIfWaiting();
            bool didRefresh = false;
            if (Vendor == Vendor.Grok && credential.Expires <= Clock.Now.AddMinutes(30))
            {
                credential = await Renew(credential, cancellation).ConfigureAwait(false); didRefresh = true;
            }
            for (int attempt = 0; attempt < 2; attempt++)
            {
                stage = Vendor == Vendor.Grok ? FailureStage.BillingHttp : FailureStage.UsageHttp;
                string endpoint = Vendor == Vendor.Claude ? "https://api.anthropic.com/api/oauth/usage" : "https://cli-chat-proxy.grok.com/v1/billing?format=credits";
                using var request = new HttpRequestMessage(HttpMethod.Get, endpoint);
                request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", credential.Token);
                request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
                if (Vendor == Vendor.Claude) request.Headers.Add("anthropic-beta", "oauth-2025-04-20");
                else { request.Headers.Add("X-XAI-Token-Auth", "xai-grok-cli"); request.Headers.Add("x-userid", credential.UserId); }
                using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellation).ConfigureAwait(false);
                if (response.StatusCode == HttpStatusCode.Unauthorized && Vendor == Vendor.Grok && !didRefresh)
                {
                    Log.Write(Vendor, Fault.SignIn, stage, (int)response.StatusCode);
                    credential = await Renew(credential, cancellation).ConfigureAwait(false); didRefresh = true; continue;
                }
                if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden) throw new SafeFailure(Fault.SignIn, httpStatus: (int)response.StatusCode);
                if (!response.IsSuccessStatusCode) throw new SafeFailure(Fault.Network, httpStatus: (int)response.StatusCode);
                using var stream = await response.Content.ReadAsStreamAsync(cancellation).ConfigureAwait(false);
                stage = FailureStage.Parse;
                using var document = await Json.ReadAsync(stream, cancellation).ConfigureAwait(false);
                var result = Parse(document.RootElement, credential.Plan);
                if (result.FiveHour.Percent is null && result.Weekly.Percent is null) throw new SafeFailure(Fault.InvalidData);
                if (Vendor == Vendor.Grok)
                {
                    var proactive = credential.Expires?.AddMinutes(-30) ?? Clock.Now.AddMinutes(5);
                    // A CLI may return a still-valid token without extending its lifetime. Do not spin.
                    NextBackgroundRefresh = proactive <= Clock.Now
                        ? (credential.Expires is { } expires && expires < Clock.Now.AddMinutes(5) ? expires : Clock.Now.AddMinutes(5))
                        : proactive;
                }
                return result;
            }
            throw new SafeFailure(Fault.RefreshFailed, stage: FailureStage.RefreshRpc);
        }
        catch (Exception error) { throw SafeFailure.Classify(error, stage); }
    }
    protected override Snapshot OnResult(Snapshot snapshot, SafeFailure? failure)
    {
        if (Vendor != Vendor.Grok) return snapshot;
        if (failure is null && snapshot.Fault == Fault.None)
        {
            lastGood = snapshot; lastGoodStore?.Save(snapshot); return snapshot;
        }
        // Definitive auth failures stop automatic retries until a changed credential is observed.
        if (failure?.Fault == Fault.SignIn) RefreshPolicy.Stop(failure);
        if (RefreshPolicy.LastFailure is not null) NextBackgroundRefresh = RefreshPolicy.NextAttempt;
        else NextBackgroundRefresh = Clock.Now.AddMinutes(5);
        bool verification = snapshot.Fault == Fault.GrokVerificationFailed &&
            failure?.Verification?.Status is not (VerificationStatus.VerifierBusy or VerificationStatus.VerifierTimeout);
        var state = verification ? GrokState.VerificationFailed :
            snapshot.Fault is Fault.SignIn or Fault.RefreshFailed || RefreshPolicy.Failures >= GrokRefreshPolicy.SignInThreshold ||
            (RefreshPolicy.LastFailure is not null && activeExpiry <= Clock.Now)
                ? GrokState.SignInExpired : GrokState.Retrying;
        return (lastGood ?? snapshot) with { Fault = snapshot.Fault, Stale = lastGood is not null, GrokState = state };
    }
    private async Task<Credential> Renew(Credential expected, CancellationToken cancellation)
    {
        try
        {
            if (refresh is null) throw new SafeFailure(Fault.RefreshFailed);
            var result = await refresh.RefreshAsync(expected, cancellation).ConfigureAwait(false);
            result.Protect(redactor);
            if (result.UserId != expected.UserId || result.ClientId != expected.ClientId) throw new SafeFailure(Fault.SignIn);
            if (result.Expires is null || result.Expires <= Clock.Now) throw new SafeFailure(Fault.RefreshFailed);
            renewalSource = expected; renewed = result; activeExpiry = result.Expires; RefreshPolicy.Reset(); return result;
        }
        catch (Exception error)
        {
            var failure = SafeFailure.Classify(error, error is HttpRequestException ? FailureStage.RefreshHttp : FailureStage.RefreshRpc, Fault.Network);
            RefreshPolicy.Failed(failure);
            throw failure;
        }
    }
    private Snapshot Parse(JsonElement root, Plan plan)
    {
        var apiPlan = Presentation.ParsePlan(Json.String(root, "subscription_tier"));
        if (apiPlan != Plan.Unknown) plan = apiPlan;
        if (Vendor == Vendor.Claude) return new(Vendor, plan, Json.Usage(root, "five_hour"), Json.Usage(root, "seven_day"), Clock.Now);
        var config = Json.Get(root, "config");
        if (config.ValueKind != JsonValueKind.Object) throw new SafeFailure(Fault.InvalidData);
        var five = Json.Usage(root, "five_hour");
        var week = Json.Usage(root, "seven_day");
        var period = Json.Get(config, "currentPeriod");
        if (Json.String(period, "type") == "USAGE_PERIOD_TYPE_WEEKLY" && Json.Number(config, "creditUsagePercent") is double used && used >= 0)
            week = new(Math.Clamp(100 - used, 0, 100), Json.Date(period, "end"));
        return new(Vendor, plan, five, week, Clock.Now);
    }
    public void Dispose() => client.Dispose();
}
