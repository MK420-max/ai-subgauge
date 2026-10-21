using System;
using System.Globalization;
using AISubGauge.Providers;

namespace AISubGauge.UI;

internal static class QuotaText
{
    public static string Percent(double? value) => value is double number && double.IsFinite(number) && number is >= 0 and <= 100
        ? number.ToString("0", CultureInfo.InvariantCulture) + "%" : I18n.Get("common.unknown");
    public static string Date(DateTimeOffset value) => value.ToLocalTime().ToString(I18n.Get("format.dateTime"), I18n.Culture);
    public static string Reset(DateTimeOffset? time) => I18n.Get("panel.resetPrefix") + (time is DateTimeOffset reset ? Date(reset) : I18n.Get("common.notProvided"));
    public static string PanelReset(DateTimeOffset? time, DateTimeOffset now)
    {
        if (time is not DateTimeOffset reset) return I18n.Get("panel.resetUnknown");
        if (reset <= now) return I18n.Get("panel.resetDue");
        int minutes = Math.Max(1, (int)Math.Ceiling((reset - now).TotalMinutes));
        if (minutes >= 1440) return I18n.Get("panel.resetDaysHours", minutes / 1440, minutes % 1440 / 60);
        if (minutes >= 60) return I18n.Get("panel.resetHoursMinutes", minutes / 60, minutes % 60);
        return I18n.Get("panel.resetMinutes", minutes);
    }
    public static string Error(string error) => error.StartsWith(GrokCliRefresh.FailurePrefix, StringComparison.Ordinal)
        ? error : I18n.Get("error.refreshPrefix") + error;

    public static string Tooltip(string name, QuotaSnapshot? snapshot)
    {
        if (snapshot is null) return name + I18n.Get("windows.refreshing");
        // Put the failure before the reset time so the 127-character tray limit preserves its cause.
        string text = I18n.Get("menu.0.1.remaining", name, Percent(snapshot.RemainingPercent)) + (snapshot.IsDemo ? I18n.Get("windows.demoSuffix") : "") +
            (snapshot.Error is not null ? "\n" + Error(snapshot.Error) : "") + "\n" + Reset(snapshot.MainWindow?.ResetsAt);
        return text.Length <= 127 ? text : text[..126] + "…";
    }
}
