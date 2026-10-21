using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace AISubGauge.Providers;

public sealed class CopilotProvider : HttpQuotaProvider
{
    public override string Id => "copilot";
    public override string DisplayName => I18n.Get("provider.copilot");
    public override string LogoResource => "WindowsQuotaTray.assets.logos.githubcopilot.png";
    private static string CredentialPath(string name) => CredentialFiles.CopilotPath(name);
    public override bool IsSignedInLocally() => EnvironmentToken("COPILOT_GITHUB_TOKEN") is not null ||
        LocalFiles.Exists(CredentialPath("apps.json")) || LocalFiles.Exists(CredentialPath("hosts.json"));

    protected override async Task<QuotaSnapshot> FetchCoreAsync(HttpClient client, CancellationToken cancellationToken)
    {
        string token = EnvironmentToken("COPILOT_GITHUB_TOKEN") ?? await ReadTokenAsync(cancellationToken).ConfigureAwait(false);
        using var request = Request(HttpMethod.Get, "https://api.github.com/copilot_internal/user", token);
        request.Headers.Authorization = new AuthenticationHeaderValue("token", token);
        request.Headers.Add("Editor-Version", "vscode/1.96.2");
        request.Headers.Add("Editor-Plugin-Version", "copilot-chat/0.26.7");
        request.Headers.UserAgent.ParseAdd("GitHubCopilotChat/0.26.7");
        request.Headers.Add("X-Github-Api-Version", "2025-04-01");
        using JsonDocument document = await SendAsync(client, request, cancellationToken).ConfigureAwait(false);
        JsonElement root = document.RootElement;
        DateTimeOffset? reset = QuotaJson.ResetTime(root, "quota_reset_date") ?? QuotaJson.ResetTime(root, "quota_reset_date_utc");
        var windows = new List<QuotaWindow>();
        if (QuotaJson.TryProperty(root, "quota_snapshots", out JsonElement quotas))
        {
            foreach ((string key, string title) in new[] { ("premium_interactions", I18n.Get("windows.premium.requests")), ("chat", I18n.Get("windows.chat")) })
            {
                if (!QuotaJson.TryProperty(quotas, key, out JsonElement quota)) continue;
                bool unlimited = QuotaJson.TryProperty(quota, "unlimited", out JsonElement flag) && flag.ValueKind == JsonValueKind.True;
                double? percent = unlimited ? 100 : QuotaJson.TryNumber(quota, "percent_remaining", out double remaining) ? remaining : null;
                if (percent is not null)
                    windows.Add(new QuotaWindow { Id = key, Title = title + (unlimited ? I18n.Get("windows.unlimited") : ""), RemainingPercent = percent, ResetsAt = reset });
            }
        }
        return new QuotaSnapshot { Provider = this, Plan = QuotaJson.String(root, "copilot_plan") ?? I18n.Get("windows.unknown.plan"), Windows = windows };
    }

    private static async Task<string> ReadTokenAsync(CancellationToken cancellationToken)
    {
        foreach (string name in new[] { "apps.json", "hosts.json" })
        {
            string path = CredentialPath(name);
            if (!LocalFiles.Exists(path)) continue;
            using JsonDocument document = await ReadCredentialAsync(path, cancellationToken).ConfigureAwait(false);
            if (document.RootElement.ValueKind != JsonValueKind.Object) continue;
            foreach (JsonProperty host in document.RootElement.EnumerateObject())
                if ((host.Name.Equals("github.com", StringComparison.OrdinalIgnoreCase) || host.Name.StartsWith("github.com:", StringComparison.OrdinalIgnoreCase)) &&
                    QuotaJson.String(host.Value, "oauth_token") is string token && !string.IsNullOrWhiteSpace(token))
                    return token;
        }
        throw new QuotaReadException(I18n.Get("windows.no.github.copilot.oauth.token.found.sign.in.again.in"));
    }
}
