using System;
using System.Collections.Generic;
using System.Globalization;
using System.Net.Http;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace AISubGauge.Providers;

public sealed class KimiProvider : HttpQuotaProvider
{
    public override string Id => "kimi";
    public override string DisplayName => I18n.Get("provider.kimi");
    public override string LogoResource => "WindowsQuotaTray.assets.logos.kimi.png";
    private static string CredentialPath => CredentialFiles.KimiPath;
    public override bool IsSignedInLocally() => EnvironmentToken("KIMI_CODE_API_KEY") is not null || LocalFiles.Exists(CredentialPath);

    protected override async Task<QuotaSnapshot> FetchCoreAsync(HttpClient client, CancellationToken cancellationToken)
    {
        string token = EnvironmentToken("KIMI_CODE_API_KEY") ?? await ReadTokenAsync(cancellationToken).ConfigureAwait(false);
        using var request = Request(HttpMethod.Get, "https://api.kimi.com/coding/v1/usages", token);
        using JsonDocument document = await SendAsync(client, request, cancellationToken).ConfigureAwait(false);
        JsonElement root = document.RootElement;
        if (QuotaJson.TryProperty(root, "data", out JsonElement data) && data.ValueKind == JsonValueKind.Object)
            root = data;
        var windows = new List<QuotaWindow>();
        if (QuotaJson.TryProperty(root, "usage", out JsonElement weekly))
            AddWindow(windows, weekly, "weekly", I18n.Get("quota.weekly"));
        if (QuotaJson.TryProperty(root, "limits", out JsonElement limits) && limits.ValueKind == JsonValueKind.Array)
        {
            int index = 0;
            foreach (JsonElement limit in limits.EnumerateArray())
            {
                QuotaJson.TryProperty(limit, "window", out JsonElement window);
                QuotaJson.TryNumber(window, "duration", out double duration);
                string title = QuotaJson.DurationTitle(duration, QuotaJson.String(window, "timeUnit"));
                JsonElement usage = QuotaJson.TryProperty(limit, "usage", out JsonElement nested) && nested.ValueKind == JsonValueKind.Object
                    ? nested : QuotaJson.TryProperty(limit, "detail", out JsonElement detail) && detail.ValueKind == JsonValueKind.Object ? detail : limit;
                AddWindow(windows, usage, "limit." + (index++).ToString(CultureInfo.InvariantCulture), title);
            }
        }
        return new QuotaSnapshot { Provider = this, Plan = QuotaJson.String(root, "planName") ?? I18n.Get("provider.kimi"), Windows = windows };
    }

    private static void AddWindow(List<QuotaWindow> windows, JsonElement usage, string id, string title)
    {
        if (QuotaJson.Remaining(usage) is double remaining)
            windows.Add(new QuotaWindow { Id = id, Title = title, RemainingPercent = remaining, ResetsAt = QuotaJson.ResetTime(usage, "resetTime") });
    }

    private static async Task<string> ReadTokenAsync(CancellationToken cancellationToken)
    {
        using JsonDocument document = await ReadCredentialAsync(CredentialPath, cancellationToken).ConfigureAwait(false);
        JsonElement root = document.RootElement;
        foreach (string key in new[] { "expires_at", "expires_at_ms", "expiresAtMs", "expires", "expiry_date", "expiration_time" })
        {
            if (!QuotaJson.TryProperty(root, key, out JsonElement value) || value.ValueKind == JsonValueKind.Null) continue;
            DateTimeOffset expiry = key is "expires_at_ms" or "expiresAtMs" or "expiry_date"
                ? QuotaJson.Milliseconds(root, key) ?? throw new QuotaReadException(I18n.Get("windows.the.kimi.login.expiry.is.invalid.run.kimi.to.refresh"))
                : QuotaJson.ResetTime(root, key) ?? throw new QuotaReadException(I18n.Get("windows.the.kimi.login.expiry.is.invalid.run.kimi.to.refresh"));
            if (expiry <= DateTimeOffset.UtcNow)
                throw new QuotaReadException(I18n.Get("windows.the.kimi.login.expired.run.kimi.to.refresh.it"));
        }
        return QuotaJson.String(root, "access_token") ?? throw new QuotaReadException(I18n.Get("windows.kimi.credentials.have.no.access.token.run.kimi.to.sign"));
    }
}
