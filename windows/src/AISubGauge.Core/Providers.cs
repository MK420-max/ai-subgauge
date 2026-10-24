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
    protected abstract Task<Snapshot> FetchCoreAsync(CancellationToken cancellation);
    public async Task<Snapshot> FetchAsync(CancellationToken cancellation = default)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        timeout.CancelAfter(TimeSpan.FromSeconds(45));
        Fault fault;
        try
        {
            var result = await FetchCoreAsync(timeout.Token).ConfigureAwait(false);
            if (result.FiveHour.Percent is null && result.Weekly.Percent is null && result.Fault == Fault.None) throw new SafeFailure(Fault.InvalidData);
            log.Write(Vendor, result.Fault);
            return result;
        }
        catch (SafeFailure error) { fault = error.Fault; }
        catch (OperationCanceledException) { fault = Fault.Timeout; }
        catch (HttpRequestException) { fault = Fault.Network; }
        catch (FileNotFoundException) { fault = Fault.SignIn; }
        catch (DirectoryNotFoundException) { fault = Fault.SignIn; }
        catch { fault = Fault.InvalidData; }
        log.Write(Vendor, fault);
        return Snapshot.Failure(Vendor, fault, Clock);
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
    public override Vendor Vendor { get; }
    public SubscriptionProvider(Vendor vendor, ICredentialSource source, IClock clock, Redactor redactor, SafeLog log,
        HttpMessageHandler? handler = null, IGrokRefresh? refresh = null, IGrokCache? cache = null) : base(clock, log)
    {
        if (vendor == Vendor.Codex) throw new ArgumentException("Use the Codex RPC provider.");
        Vendor = vendor; this.source = source; this.refresh = refresh; this.cache = cache; this.redactor = redactor;
        client = new HttpClient(handler ?? new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false, UseDefaultCredentials = false }) { Timeout = TimeSpan.FromSeconds(20) };
    }
    protected override async Task<Snapshot> FetchCoreAsync(CancellationToken cancellation)
    {
        var credential = await source.ReadAsync(Vendor, cancellation).ConfigureAwait(false);
        if (credential is null)
        {
            if (Vendor == Vendor.Grok && cache is not null) return await cache.ReadAsync(cancellation).ConfigureAwait(false);
            throw new SafeFailure(Fault.SignIn);
        }
        credential.Protect(redactor);
        if (renewed is not null && renewed.UserId == credential.UserId && renewed.ClientId == credential.ClientId && renewed.Expires > Clock.Now && renewed.Expires > credential.Expires) credential = renewed;
        bool didRefresh = false;
        if (Vendor == Vendor.Grok && credential.Expires <= Clock.Now)
        {
            credential = await Renew(credential, cancellation).ConfigureAwait(false); didRefresh = true;
        }
        for (int attempt = 0; attempt < 2; attempt++)
        {
            string endpoint = Vendor == Vendor.Claude ? "https://api.anthropic.com/api/oauth/usage" : "https://cli-chat-proxy.grok.com/v1/billing?format=credits";
            using var request = new HttpRequestMessage(HttpMethod.Get, endpoint);
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", credential.Token);
            request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
            if (Vendor == Vendor.Claude) request.Headers.Add("anthropic-beta", "oauth-2025-04-20");
            else { request.Headers.Add("X-XAI-Token-Auth", "xai-grok-cli"); request.Headers.Add("x-userid", credential.UserId); }
            using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellation).ConfigureAwait(false);
            if (response.StatusCode == HttpStatusCode.Unauthorized && Vendor == Vendor.Grok && !didRefresh)
            {
                credential = await Renew(credential, cancellation).ConfigureAwait(false); didRefresh = true; continue;
            }
            if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden) throw new SafeFailure(Fault.SignIn);
            if (!response.IsSuccessStatusCode) throw new SafeFailure(Fault.Network);
            using var stream = await response.Content.ReadAsStreamAsync(cancellation).ConfigureAwait(false);
            using var document = await Json.ReadAsync(stream, cancellation).ConfigureAwait(false);
            return Parse(document.RootElement, credential.Plan);
        }
        throw new SafeFailure(Fault.RefreshFailed);
    }
    private async Task<Credential> Renew(Credential expected, CancellationToken cancellation)
    {
        try
        {
            if (refresh is null) throw new SafeFailure(Fault.RefreshFailed);
            var result = await refresh.RefreshAsync(expected, cancellation).ConfigureAwait(false);
            result.Protect(redactor);
            if (result.UserId != expected.UserId || result.ClientId != expected.ClientId || result.Expires is null || result.Expires <= Clock.Now) throw new SafeFailure(Fault.RefreshFailed);
            renewed = result; return result;
        }
        catch { throw new SafeFailure(Fault.RefreshFailed); }
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
