using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace AISubGauge.Providers;

public sealed class GrokProvider : IQuotaProvider
{
    internal const int MaxBytes = 1_048_576;
    private static readonly Uri Endpoint = new("https://cli-chat-proxy.grok.com/v1/billing?format=credits");
    public string Id => "grok";
    public string DisplayName => I18n.Get("provider.grok");
    internal static bool HasPrivateLogo =>
#if PRIVATE_GROK_LOGO
        true;
#else
        false;
#endif
    public string LogoResource => HasPrivateLogo ? "WindowsQuotaTray.assets.logos.grokbot-head.png"
        : "WindowsQuotaTray.assets.logos.grok.png";

    public bool IsSignedInLocally()
    {
        return LocalFiles.Exists(CredentialPath()) || GrokBotCache.IsSignedInLocally();
    }

    // Do not use a record here: its generated ToString would include the bearer.
    internal sealed class Credential
    {
        public required string Token { get; init; }
        public required string UserId { get; init; }
        public required string ClientId { get; init; }
        public required bool CanRefresh { get; init; }
        public required DateTimeOffset ExpiresAt { get; init; }
    }

    public async Task<QuotaSnapshot> FetchAsync(CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        try
        {
            string authPath = CredentialPath();
            Credential? credential = await ReadCredentialAsync(authPath, cancellationToken).ConfigureAwait(false);
            // As on Mac, a configured but broken official account must not silently switch accounts.
            if (credential is null)
                return await GrokBotCache.ReadAsync(this, timeout.Token).ConfigureAwait(false);
            if (credential.ExpiresAt <= DateTimeOffset.UtcNow.AddSeconds(15))
                credential = await GrokCliRefresh.RefreshAsync(authPath, credential, cancellationToken).ConfigureAwait(false);
            timeout.CancelAfter(TimeSpan.FromSeconds(20));
            return await FetchBillingAsync(credential, timeout.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return QuotaSnapshot.Failure(this, I18n.Get("windows.reading.grok.quota.timed.out.refresh.later"));
        }
        catch (OperationCanceledException) { throw; }
        catch (QuotaReadException error) { return QuotaSnapshot.Failure(this, error.Message); }
        catch (JsonException) { return QuotaSnapshot.Failure(this, I18n.Get("windows.the.grok.login.file.or.quota.data.has.an.invalid")); }
        catch (HttpRequestException) { return QuotaSnapshot.Failure(this, I18n.Get("windows.could.not.connect.to.the.official.grok.usage.service")); }
        catch (Exception) { return QuotaSnapshot.Failure(this, I18n.Get("windows.could.not.read.grok.credentials.permissions.or.quota.check.sign")); }
    }

    private async Task<QuotaSnapshot> FetchBillingAsync(Credential credential, CancellationToken cancellationToken)
    {
        using var handler = new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false, UseDefaultCredentials = false };
        using var client = new HttpClient(handler) { Timeout = Timeout.InfiniteTimeSpan };
        for (int attempt = 0; ; attempt++)
        {
            using var requestTimeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            requestTimeout.CancelAfter(TimeSpan.FromSeconds(15));
            using var request = new HttpRequestMessage(HttpMethod.Get, Endpoint);
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", credential.Token);
            request.Headers.Add("X-XAI-Token-Auth", "xai-grok-cli");
            request.Headers.Add("x-userid", credential.UserId);
            request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
            request.Headers.CacheControl = new CacheControlHeaderValue { NoCache = true, NoStore = true };
            using HttpResponseMessage response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, requestTimeout.Token).ConfigureAwait(false);
            if (response.RequestMessage?.RequestUri != Endpoint)
                throw new QuotaReadException(I18n.Get("windows.the.grok.usage.service.returned.an.unexpected.address"));
            if (response.StatusCode is HttpStatusCode.BadGateway or HttpStatusCode.ServiceUnavailable or HttpStatusCode.GatewayTimeout)
            {
                if (attempt == 0)
                {
                    response.Dispose();
                    await Task.Delay(500, cancellationToken).ConfigureAwait(false);
                    continue;
                }
                throw new QuotaReadException(I18n.Get("windows.the.official.grok.usage.service.is.temporarily.unavailable.automatic.retries"));
            }
            if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
                throw new QuotaReadException(I18n.Get("windows.the.grok.login.expired.or.lacks.read.access.sign.in"));
            if (response.StatusCode != HttpStatusCode.OK)
                throw new QuotaReadException(I18n.Get("windows.the.official.grok.usage.service.returned.an.error.or.redirect"));
            using Stream stream = await response.Content.ReadAsStreamAsync(requestTimeout.Token).ConfigureAwait(false);
            byte[] bytes = await ReadBoundedAsync(stream, MaxBytes, requestTimeout.Token).ConfigureAwait(false);
            using JsonDocument document = JsonDocument.Parse(bytes);
            return ParseBilling(document.RootElement);
        }
    }

    private QuotaSnapshot ParseBilling(JsonElement root)
    {
        if (!QuotaJson.TryProperty(root, "config", out JsonElement config) || config.ValueKind != JsonValueKind.Object)
            throw new QuotaReadException(I18n.Get("windows.official.grok.quota.data.has.an.invalid.format"));
        double? remaining = null;
        if (HasValue(config, "creditUsagePercent", out _))
        {
            if (!QuotaJson.TryNumber(config, "creditUsagePercent", out double used) || used < 0)
                throw new QuotaReadException(I18n.Get("windows.the.official.grok.quota.percentage.is.invalid"));
            remaining = Math.Clamp(100 - used, 0, 100);
        }
        QuotaJson.TryProperty(config, "currentPeriod", out JsonElement period);
        string title = QuotaJson.String(period, "type") switch
        {
            "USAGE_PERIOD_TYPE_WEEKLY" => I18n.Get("quota.weekly"),
            "USAGE_PERIOD_TYPE_MONTHLY" => I18n.Get("quota.monthly"),
            _ => I18n.Get("error.account.quota")
        };
        DateTimeOffset? reset = null;
        if (HasValue(period, "end", out JsonElement end))
            reset = IsoDate(end.ValueKind == JsonValueKind.String ? end.GetString() : null)
                ?? throw new QuotaReadException(I18n.Get("windows.the.official.grok.quota.reset.time.is.invalid"));
        string balance = "";
        if (HasValue(config, "prepaidBalance", out JsonElement prepaid))
        {
            if (prepaid.ValueKind != JsonValueKind.Object)
                throw new QuotaReadException(I18n.Get("windows.the.official.grok.prepaid.balance.has.an.invalid.format"));
            double cents = 0; // Proto3 omits val when the balance is exactly zero.
            if (QuotaJson.TryProperty(prepaid, "val", out _) &&
                (!QuotaJson.TryNumber(prepaid, "val", out cents) || cents < 0 || Math.Truncate(cents) != cents || cents > 9_007_199_254_740_991d))
                throw new QuotaReadException(I18n.Get("windows.the.official.grok.prepaid.balance.has.an.invalid.format"));
            balance = I18n.Get("windows.prepaid.balance.us") + (cents / 100).ToString("F2", CultureInfo.InvariantCulture);
        }
        bool unified = QuotaJson.TryProperty(config, "isUnifiedBillingUser", out JsonElement flag) && flag.ValueKind == JsonValueKind.True;
        return new QuotaSnapshot
        {
            Provider = this,
            Plan = QuotaJson.String(root, "subscription_tier") ?? I18n.Get("windows.subscription.plan.name.not.provided.by.api"),
            Info = I18n.Get("error.grok.build.official.account.usage.api") + balance + "\n" +
                (unified ? I18n.Get("windows.shared.account.quota.specific.model.settings.were.not.provided") : I18n.Get("windows.build.account.quota.the.service.has.not.confirmed.shared.quota")),
            Windows = new List<QuotaWindow> { new() { Id = "grok-build.included", Title = title, RemainingPercent = remaining, ResetsAt = reset } }
        };
    }

    private static string CredentialPath()
    {
        string? path = Environment.GetEnvironmentVariable("GROK_AUTH_PATH");
        return LocalFiles.FullPath(string.IsNullOrWhiteSpace(path) ? CredentialFiles.GrokPath : path);
    }

    internal static async Task<Credential?> ReadCredentialAsync(string path, CancellationToken cancellationToken)
    {
        FileStream opened;
        try { opened = LocalFiles.OpenRead(path, MaxBytes); }
        catch (FileNotFoundException) { return null; }
        catch (DirectoryNotFoundException) { return null; }
        await using FileStream file = opened;
        CredentialAccess.Validate(file, grok: true);
        byte[] bytes = await ReadBoundedAsync(file, MaxBytes, cancellationToken).ConfigureAwait(false);
        using JsonDocument document = JsonDocument.Parse(bytes);
        if (document.RootElement.ValueKind != JsonValueKind.Object)
            throw new QuotaReadException(I18n.Get("windows.the.grok.login.file.format.is.unsupported"));
        Credential? selected = null;
        DateTimeOffset now = DateTimeOffset.UtcNow;
        foreach (JsonProperty scope in document.RootElement.EnumerateObject())
        {
            JsonElement value = scope.Value;
            if (value.ValueKind != JsonValueKind.Object)
                throw new QuotaReadException(I18n.Get("windows.the.grok.login.file.format.is.unsupported"));
            string? mode = QuotaJson.String(value, "auth_mode");
            string? issuer = QuotaJson.String(value, "oidc_issuer");
            if (mode is not ("oidc" or "external") || issuer is not ("https://auth.x.ai" or "https://auth.x.ai/"))
                continue;
            string? client = QuotaJson.String(value, "oidc_client_id");
            string? token = QuotaJson.String(value, "key");
            string? user = QuotaJson.String(value, "user_id");
            DateTimeOffset? created = IsoDate(QuotaJson.String(value, "create_time"));
            if (string.IsNullOrEmpty(client) || scope.Name != "https://auth.x.ai::" + client ||
                !ValidHeader(token, 32768) || !ValidHeader(user, 256) || created is null || created.Value > now.AddMinutes(5))
                throw new QuotaReadException(I18n.Get("windows.official.grok.login.fields.are.incomplete.or.invalid.sign.in"));
            DateTimeOffset expires = HasValue(value, "expires_at", out JsonElement expiry)
                ? IsoDate(expiry.ValueKind == JsonValueKind.String ? expiry.GetString() : null)
                    ?? throw new QuotaReadException(I18n.Get("windows.the.grok.login.expiry.has.an.invalid.format"))
                : created.Value.AddDays(30);
            var candidate = new Credential
            {
                Token = token!, UserId = user!, ClientId = client!, CanRefresh = mode == "oidc" && ValidHeader(QuotaJson.String(value, "refresh_token"), 32768), ExpiresAt = expires
            };
            if (selected is not null && selected.UserId != candidate.UserId)
                throw new QuotaReadException(I18n.Get("windows.the.grok.login.contains.multiple.accounts.confirm.the.current.account"));
            if (selected is null || candidate.ExpiresAt > selected.ExpiresAt)
                selected = candidate;
        }
        return selected;
    }

    private static bool ValidHeader(string? value, int maximum)
    {
        if (string.IsNullOrEmpty(value) || value.Length > maximum) return false;
        foreach (char character in value)
            if (character < 0x21 || character > 0x7e) return false;
        return true;
    }

    internal static bool HasValue(JsonElement value, string name, out JsonElement result) =>
        QuotaJson.TryProperty(value, name, out result) && result.ValueKind != JsonValueKind.Null;

    internal static DateTimeOffset? IsoDate(string? text) => text is not null &&
        Regex.IsMatch(text, @"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$", RegexOptions.CultureInvariant) &&
        DateTimeOffset.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.None, out DateTimeOffset date) ? date : null;

    internal static async Task<byte[]> ReadBoundedAsync(Stream stream, int maximum, CancellationToken cancellationToken)
    {
        using var data = new MemoryStream();
        byte[] buffer = new byte[8192];
        while (true)
        {
            int count = await stream.ReadAsync(buffer.AsMemory(0, (int)Math.Min(buffer.Length, maximum + 1 - data.Length)), cancellationToken).ConfigureAwait(false);
            if (count == 0) return data.ToArray();
            data.Write(buffer, 0, count);
            if (data.Length > maximum)
                throw new QuotaReadException(I18n.Get("windows.returned.data.or.a.local.file.exceeded.the.size.limit"));
        }
    }
}
