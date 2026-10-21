using System;
using System.Globalization;
using System.Text.Json;

namespace AISubGauge.Providers;

internal static class QuotaJson
{
    public static bool TryProperty(JsonElement element, string name, out JsonElement value)
    {
        value = default;
        if (element.ValueKind != JsonValueKind.Object)
            return false;
        if (element.TryGetProperty(name, out value))
            return true;
        // The same quota endpoints ship both snake_case and camelCase fields.
        string normalized = name.Replace("_", "", StringComparison.Ordinal);
        foreach (JsonProperty property in element.EnumerateObject())
        {
            if (property.Name.Replace("_", "", StringComparison.Ordinal).Equals(normalized, StringComparison.OrdinalIgnoreCase))
            {
                value = property.Value;
                return true;
            }
        }
        return false;
    }

    public static string? String(JsonElement element, string name) =>
        TryProperty(element, name, out JsonElement value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    public static bool TryNumber(JsonElement element, string name, out double number)
    {
        number = 0;
        return TryProperty(element, name, out JsonElement value) &&
               ((value.ValueKind == JsonValueKind.Number && value.TryGetDouble(out number)) ||
                (value.ValueKind == JsonValueKind.String && double.TryParse(value.GetString(),
                    NumberStyles.Float, CultureInfo.InvariantCulture, out number))) && double.IsFinite(number);
    }

    public static DateTimeOffset? ResetTime(JsonElement element, string name)
    {
        if (!TryProperty(element, name, out JsonElement value))
            return null;

        long seconds;
        if ((value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out seconds)) ||
            (value.ValueKind == JsonValueKind.String && long.TryParse(value.GetString(),
                NumberStyles.Integer, CultureInfo.InvariantCulture, out seconds)))
        {
            try { return Math.Abs((double)seconds) >= 1_000_000_000_000d
                ? DateTimeOffset.FromUnixTimeMilliseconds(seconds) : DateTimeOffset.FromUnixTimeSeconds(seconds); }
            catch (ArgumentOutOfRangeException) { return null; }
        }

        if (value.ValueKind == JsonValueKind.String && DateTimeOffset.TryParse(value.GetString(),
                CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out DateTimeOffset parsed))
            return parsed;

        return null;
    }

    public static DateTimeOffset? Milliseconds(JsonElement element, string name)
    {
        if (!TryNumber(element, name, out double value) || value < -62_135_596_800_000d || value > 253_402_300_799_999d)
            return null;
        return DateTimeOffset.FromUnixTimeMilliseconds((long)value);
    }

    public static double? Remaining(JsonElement element)
    {
        if (!TryNumber(element, "limit", out double limit) || limit <= 0)
            return null;
        if (TryNumber(element, "remaining", out double remaining) && remaining >= 0)
            return Math.Clamp(remaining / limit * 100, 0, 100);
        return TryNumber(element, "used", out double used) && used >= 0
            ? Math.Clamp(100 - used / limit * 100, 0, 100) : null;
    }

    public static string DurationTitle(double duration, string? unit)
    {
        if (!double.IsFinite(duration) || duration <= 0) return I18n.Get("windows.quota.window");
        if (unit?.ToUpperInvariant() is "MONTH" or "MONTHS" or "TIME_UNIT_MONTH")
            return duration.ToString("0.#", CultureInfo.InvariantCulture) + I18n.Get("windows.months");
        double minutes = unit?.ToUpperInvariant() switch
        {
            "TIME_UNIT_SECOND" or "SECONDS" or "SECOND" => duration / 60,
            "TIME_UNIT_MINUTE" or "MINUTES" or "MINUTE" => duration,
            "TIME_UNIT_HOUR" or "HOURS" or "HOUR" => duration * 60,
            "TIME_UNIT_DAY" or "DAYS" or "DAY" => duration * 1440,
            "TIME_UNIT_WEEK" or "WEEKS" or "WEEK" => duration * 10080,
            _ => 0
        };
        return minutes switch
        {
            300 => I18n.Get("quota.fiveHours"),
            10080 => I18n.Get("quota.weekly"),
            > 0 when minutes % 1440 == 0 => (minutes / 1440).ToString("0.#", CultureInfo.InvariantCulture) + I18n.Get("windows.days"),
            > 0 when minutes % 60 == 0 => (minutes / 60).ToString("0.#", CultureInfo.InvariantCulture) + I18n.Get("windows.hours"),
            > 0 => minutes.ToString("0.#", CultureInfo.InvariantCulture) + I18n.Get("windows.minutes"),
            _ => I18n.Get("windows.quota.window")
        };
    }
}
