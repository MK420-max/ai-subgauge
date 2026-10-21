using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace AISubGauge.Providers;

public sealed class GeminiProvider : HttpQuotaProvider
{
    public override string Id => "gemini";
    public override string DisplayName => I18n.Get("provider.gemini");
    public override string LogoResource => "WindowsQuotaTray.assets.logos.gemini.png";
    private static string CredentialPath => CredentialFiles.GeminiPath;
    public override bool IsSignedInLocally() => LocalFiles.Exists(CredentialPath);

    protected override async Task<QuotaSnapshot> FetchCoreAsync(HttpClient client, CancellationToken cancellationToken)
    {
        using JsonDocument credential = await ReadCredentialAsync(CredentialPath, cancellationToken).ConfigureAwait(false);
        string token = QuotaJson.String(credential.RootElement, "access_token")
            ?? throw new QuotaReadException(I18n.Get("windows.gemini.credentials.have.no.access.token.run.gemini.to.sign"));
        DateTimeOffset expiry = QuotaJson.Milliseconds(credential.RootElement, "expiry_date")
            ?? throw new QuotaReadException(I18n.Get("windows.gemini.credentials.have.no.expiry.run.gemini.to.refresh.your"));
        if (expiry <= DateTimeOffset.UtcNow)
            throw new QuotaReadException(I18n.Get("windows.run.gemini.to.refresh.your.login"));

        using var loadRequest = Request(HttpMethod.Post, "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist", token,
            new { metadata = new { ideType = "GEMINI_CLI", pluginType = "GEMINI" } });
        using JsonDocument load = await SendAsync(client, loadRequest, cancellationToken).ConfigureAwait(false);
        JsonElement root = load.RootElement;
        if (QuotaJson.TryProperty(root, "ineligibleTiers", out JsonElement tiers) && tiers.ValueKind == JsonValueKind.Array)
            foreach (JsonElement tier in tiers.EnumerateArray())
                if (QuotaJson.String(tier, "reasonCode") == "UNSUPPORTED_CLIENT")
                    throw new QuotaReadException(I18n.Get("windows.google.discontinued.gemini.cli.oauth.for.personal.ai.pro.ultra"));

        string? project = QuotaJson.String(root, "cloudaicompanionProject");
        if (project is null && QuotaJson.TryProperty(root, "cloudaicompanionProject", out JsonElement projectObject))
            project = QuotaJson.String(projectObject, "id");
        QuotaJson.TryProperty(root, "paidTier", out JsonElement paid);
        QuotaJson.TryProperty(root, "currentTier", out JsonElement current);
        string plan = QuotaJson.String(paid, "name") ?? QuotaJson.String(current, "id") ?? I18n.Get("windows.unknown.plan");
        object body = string.IsNullOrWhiteSpace(project) ? new { } : new { project };
        using var quotaRequest = Request(HttpMethod.Post, "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota", token, body);
        using JsonDocument quota = await SendAsync(client, quotaRequest, cancellationToken).ConfigureAwait(false);
        var groups = new Dictionary<string, QuotaWindow>(StringComparer.Ordinal);
        if (QuotaJson.TryProperty(quota.RootElement, "buckets", out JsonElement buckets) && buckets.ValueKind == JsonValueKind.Array)
        {
            foreach (JsonElement bucket in buckets.EnumerateArray())
            {
                string model = (QuotaJson.String(bucket, "modelId") ?? "").ToLowerInvariant();
                string? group = model.Contains("flash-lite", StringComparison.Ordinal) || model.Contains("flash_lite", StringComparison.Ordinal)
                    ? "Flash Lite" : model.Contains("flash", StringComparison.Ordinal) ? "Flash" : model.Contains("pro", StringComparison.Ordinal) ? "Pro" : null;
                if (group is null || !QuotaJson.TryNumber(bucket, "remainingFraction", out double fraction) || fraction < 0 || fraction > 1)
                    continue;
                if (!groups.TryGetValue(group, out QuotaWindow? previous) || previous.RemainingPercent is not double lowest || fraction * 100 < lowest)
                    groups[group] = new QuotaWindow { Id = group, Title = group, RemainingPercent = fraction * 100,
                        ResetsAt = QuotaJson.ResetTime(bucket, "resetTime") };
            }
        }
        var windows = new List<QuotaWindow>();
        foreach (string group in new[] { "Pro", "Flash", "Flash Lite" })
            if (groups.TryGetValue(group, out QuotaWindow? window)) windows.Add(window);
        return new QuotaSnapshot { Provider = this, Plan = plan, Windows = windows };
    }
}
