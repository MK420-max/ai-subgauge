using System.Globalization;
using System.Resources;

namespace AISubGauge.Core;

public sealed class Texts(string language)
{
    private static readonly ResourceManager Resources = new("AISubGauge.Core.Strings", typeof(Texts).Assembly);
    public CultureInfo Culture { get; } = CultureInfo.GetCultureInfo(language);
    public string this[string key] => Resources.GetString(key, Culture) ?? throw new InvalidOperationException("Missing UI resource.");
    public string Format(string key, params object[] args) => string.Format(Culture, this[key], args);
    public string Name(Vendor vendor) => this[vendor.ToString()];
    public string PlanName(Plan plan) => this["Plan" + plan];
    public string Error(Fault fault) => this["Fault" + fault];
    public string Reset(DateTimeOffset? reset, DateTimeOffset now)
    {
        if (reset is null) return this["ResetUnknown"];
        var remaining = reset.Value - now;
        if (remaining <= TimeSpan.Zero) return this["ResetNow"];
        if (remaining.TotalHours >= 1) return Math.Ceiling(remaining.TotalHours) == 1 ? this["ResetHour"] : Format("ResetHours", Math.Ceiling(remaining.TotalHours));
        return Math.Ceiling(remaining.TotalMinutes) <= 1 ? this["ResetMinute"] : Format("ResetMinutes", Math.Ceiling(remaining.TotalMinutes));
    }
    public string Updated(DateTimeOffset? value) => value is null ? this["NotUpdated"] : Format("Updated", value.Value.LocalDateTime.ToString("t", Culture));
    public string Status(Snapshot snapshot) => snapshot.Fault != Fault.None ? Error(snapshot.Fault) :
        Format("Connected", Presentation.Percent(snapshot.FiveHour.Percent ?? snapshot.Weekly.Percent));
}

