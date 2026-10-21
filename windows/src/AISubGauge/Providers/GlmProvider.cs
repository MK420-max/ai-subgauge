using System;
using System.Collections.Generic;
using System.Globalization;
using System.Net.Http;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace AISubGauge.Providers;

public sealed class GlmProvider : HttpQuotaProvider
{
    public override string Id => "glm";
    public override string DisplayName => I18n.Get("provider.glm");
    public override string LogoResource => "WindowsQuotaTray.assets.logos.zhipu.png";
    public override bool IsSignedInLocally() => EnvironmentToken("Z_AI_API_KEY", "ZHIPU_API_KEY", "BIGMODEL_API_KEY", "ZHIPUAI_API_KEY", "GLM_API_KEY") is not null;

    protected override async Task<QuotaSnapshot> FetchCoreAsync(HttpClient client, CancellationToken cancellationToken)
    {
        string? global = EnvironmentToken("Z_AI_API_KEY");
        string token = global ?? EnvironmentToken("ZHIPU_API_KEY", "BIGMODEL_API_KEY", "ZHIPUAI_API_KEY", "GLM_API_KEY")
            ?? throw new QuotaReadException(I18n.Get("windows.no.glm.coding.plan.api.key.found"));
        // Never try a key against the other region, even after an authentication failure.
        string endpoint = global is not null ? "https://api.z.ai/api/monitor/usage/quota/limit"
            : "https://open.bigmodel.cn/api/monitor/usage/quota/limit";
        using var request = Request(HttpMethod.Get, endpoint, token);
        using JsonDocument document = await SendAsync(client, request, cancellationToken).ConfigureAwait(false);
        JsonElement root = document.RootElement;
        if ((QuotaJson.TryProperty(root, "success", out JsonElement success) && success.ValueKind == JsonValueKind.False) ||
            (QuotaJson.TryNumber(root, "code", out double code) && code is not (0 or 200)))
            throw new QuotaReadException(I18n.Get("windows.the.official.glm.api.did.not.return.success.check.coding"));
        QuotaJson.TryProperty(root, "data", out JsonElement data);
        var windows = new List<QuotaWindow>();
        if (QuotaJson.TryProperty(data, "limits", out JsonElement limits) && limits.ValueKind == JsonValueKind.Array)
        {
            int index = 0;
            foreach (JsonElement limit in limits.EnumerateArray())
            {
                string? type = QuotaJson.String(limit, "type");
                if (type is not ("TOKENS_LIMIT" or "CREDIT_LIMIT" or "TIME_LIMIT")) continue;
                double? remaining = Remaining(limit);
                if (remaining is null) continue;
                string title = type switch { "TOKENS_LIMIT" => I18n.Get("windows.token.quota"), "CREDIT_LIMIT" => I18n.Get("windows.credit.quota"), _ => I18n.Get("windows.requests") };
                string duration = Duration(limit);
                windows.Add(new QuotaWindow { Id = type + "." + (index++).ToString(CultureInfo.InvariantCulture),
                    Title = duration == I18n.Get("windows.quota.window") ? title : duration + " · " + title,
                    RemainingPercent = remaining, ResetsAt = QuotaJson.Milliseconds(limit, "nextResetTime") });
            }
        }
        string plan = QuotaJson.String(data, "planName") ?? QuotaJson.String(data, "packageName") ??
            QuotaJson.String(data, "level") ?? I18n.Get("windows.plan.glm");
        return new QuotaSnapshot { Provider = this, Plan = plan, Windows = windows };
    }

    private static double? Remaining(JsonElement limit)
    {
        if (QuotaJson.TryNumber(limit, "percentage", out double used) && used >= 0)
            return Math.Clamp(100 - used, 0, 100);
        if (!QuotaJson.TryNumber(limit, "usage", out double total) || total <= 0) return null;
        if (QuotaJson.TryNumber(limit, "remaining", out double remaining) && remaining >= 0)
            return Math.Clamp(remaining / total * 100, 0, 100);
        return QuotaJson.TryNumber(limit, "currentValue", out double current) && current >= 0
            ? Math.Clamp(100 - current / total * 100, 0, 100) : null;
    }

    private static string Duration(JsonElement limit)
    {
        JsonElement duration = QuotaJson.TryProperty(limit, "duration", out JsonElement nested) && nested.ValueKind == JsonValueKind.Object ? nested : limit;
        if (QuotaJson.TryProperty(limit, "window", out JsonElement window) && window.ValueKind == JsonValueKind.Object)
            duration = window;
        double amount;
        if (!QuotaJson.TryNumber(duration, "duration", out amount) && !QuotaJson.TryNumber(duration, "number", out amount))
            return I18n.Get("windows.quota.window");
        string? unit = QuotaJson.String(duration, "timeUnit") ?? QuotaJson.String(duration, "unit");
        if (QuotaJson.TryNumber(duration, "unit", out double numericUnit))
        {
            unit = numericUnit switch { 3 => "HOUR", 5 => "MONTH", 6 => "WEEK", _ => null };
            if (unit is null)
                return I18n.Get("windows.glm.windowUnit", amount.ToString("0.#", CultureInfo.InvariantCulture), numericUnit.ToString("0.#", CultureInfo.InvariantCulture));
        }
        return QuotaJson.DurationTitle(amount, unit);
    }
}
