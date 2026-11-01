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
    public string Error(Vendor vendor, Fault fault) => Presentation.SignInExpired(fault)
        ? Format("SignInExpired", vendor.ToString()) : vendor == Vendor.Grok && fault == Fault.VerifierUnresponsive
            ? this["GrokVerifierRetrying"] : Error(fault);
    public string Reset(DateTimeOffset? reset, DateTimeOffset now)
    {
        if (reset is null) return this["ResetUnknown"];
        var remaining = reset.Value - now;
        if (remaining <= TimeSpan.Zero) return this["ResetNow"];
        if (remaining.TotalHours >= 1) return Math.Ceiling(remaining.TotalHours) == 1 ? this["ResetHour"] : Format("ResetHours", Math.Ceiling(remaining.TotalHours));
        return Math.Ceiling(remaining.TotalMinutes) <= 1 ? this["ResetMinute"] : Format("ResetMinutes", Math.Ceiling(remaining.TotalMinutes));
    }
    public string Updated(DateTimeOffset? value) => value is null ? this["NotUpdated"] : Format("Updated", value.Value.LocalDateTime.ToString("t", Culture));
    public string FailureReason(Snapshot snapshot) => snapshot.GrokState == GrokState.VerificationFailed ? this["GrokVerificationShort"] :
        Presentation.CanSignInAgain(snapshot) ? this["GrokSignInExpired"] : Error(snapshot.Vendor, snapshot.Fault);
    public string StaleValue(Snapshot snapshot) => Format("StaleValue",
        Presentation.Percent(snapshot.FiveHour.Percent ?? snapshot.Weekly.Percent), snapshot.Updated.LocalDateTime.ToString("HH:mm", Culture));
    public string Status(Snapshot snapshot) => snapshot.Fault != Fault.None
        ? FailureReason(snapshot) + (snapshot.Stale ? " · " + StaleValue(snapshot) : "") :
        Format("Connected", Presentation.Percent(snapshot.FiveHour.Percent ?? snapshot.Weekly.Percent));
    public string TrayStatus(Snapshot snapshot)
    {
        string value = (snapshot.Vendor == Vendor.Grok ? "Grok" : Name(snapshot.Vendor)) + " · " + Status(snapshot);
        // Modern NOTIFYICONDATA supports 127 characters plus the terminating NUL.
        return value.Length <= 127 ? value : value[..127];
    }
}

