using System.Text.Json;

namespace AISubGauge.Core;

// Shared by the background scheduler and manual fetches. No delays hold a provider/UI thread.
public sealed class GrokRefreshPolicy(IClock clock, Func<double>? jitter = null)
{
    public const int SignInThreshold = 6;
    private static readonly int[] Seconds = [30, 60, 120, 300, 600, 900];
    public int Failures { get; private set; }
    public DateTimeOffset NextAttempt { get; private set; } = DateTimeOffset.MinValue;
    public SafeFailure? LastFailure { get; private set; }
    public void Reset() { Failures = 0; LastFailure = null; NextAttempt = DateTimeOffset.MinValue; }
    public void Stop(SafeFailure failure) { LastFailure = failure; NextAttempt = DateTimeOffset.MaxValue; }
    public void ThrowIfWaiting()
    {
        if (LastFailure is not null && clock.Now < NextAttempt) throw LastFailure;
    }
    public void Failed(SafeFailure failure)
    {
        Failures = Math.Min(Failures + 1, SignInThreshold);
        LastFailure = failure;
        bool transient = failure.Fault is Fault.Network or Fault.Timeout or Fault.VerifierUnresponsive or Fault.RefreshFailed ||
            failure.Verification?.Status is VerificationStatus.VerifierBusy or VerificationStatus.VerifierTimeout;
        if (failure.Fault == Fault.SignIn) { Stop(failure); return; }
        // A repaired/reinstalled CLI must be discoverable without changing credentials or restarting.
        if (!transient) { NextAttempt = clock.Now.AddMinutes(15); return; }
        double sample = Math.Clamp((jitter ?? Random.Shared.NextDouble)(), 0, 1);
        if (!double.IsFinite(sample)) sample = .5;
        // Positive jitter (0..20%), with a hard 15 minute cap.
        double seconds = Math.Min(900, Seconds[Failures - 1] * (1 + .2 * sample));
        NextAttempt = clock.Now.AddSeconds(seconds);
    }
}

// Persist only quota windows and the observation time. No account identifiers or credential data.
public sealed class GrokLastGoodStore(string directory, SafeLog log)
{
    private sealed record SavedWindow(double? Percent, DateTimeOffset? ResetAt);
    private sealed record Saved(SavedWindow FiveHour, SavedWindow Weekly, DateTimeOffset FetchedAt);
    public Snapshot? Load()
    {
        try
        {
            string path = Path.Combine(directory, "last-good.json");
            LocalPathSafety.RejectReparsePoints(path);
            using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            if (file.Length > 4096) throw new InvalidDataException();
            var saved = JsonSerializer.Deserialize<Saved>(file);
            if (saved is null || saved.FiveHour is null || saved.Weekly is null || saved.FetchedAt == default ||
                !Valid(saved.FiveHour.Percent) || !Valid(saved.Weekly.Percent) ||
                (saved.FiveHour.Percent is null && saved.Weekly.Percent is null)) throw new InvalidDataException();
            return new(Vendor.Grok, Plan.Unknown, new(saved.FiveHour.Percent, saved.FiveHour.ResetAt),
                new(saved.Weekly.Percent, saved.Weekly.ResetAt), saved.FetchedAt);
        }
        catch (FileNotFoundException) { return null; }
        catch (DirectoryNotFoundException) { return null; }
        catch { log.Write(LocalStatus.LastGoodReadFailed); return null; }
    }
    private static bool Valid(double? value) => value is null || (double.IsFinite(value.Value) && value is >= 0 and <= 100);
    public void Save(Snapshot snapshot)
    {
        if (snapshot.Vendor != Vendor.Grok || snapshot.Fault != Fault.None || snapshot.Stale ||
            (snapshot.FiveHour.Percent is null && snapshot.Weekly.Percent is null)) return;
        try
        {
            string path = Path.Combine(directory, "last-good.json");
            LocalPathSafety.RejectReparsePoints(path);
            Directory.CreateDirectory(directory);
            string temporary = Path.Combine(directory, "last-good." + Guid.NewGuid().ToString("N") + ".tmp");
            using (var file = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                JsonSerializer.Serialize(file, new Saved(new(snapshot.FiveHour.Percent, snapshot.FiveHour.Reset),
                    new(snapshot.Weekly.Percent, snapshot.Weekly.Reset), snapshot.Updated));
                file.Flush(true);
            }
            LocalPathSafety.RejectReparsePoints(path);
            if (File.Exists(path)) File.Replace(temporary, path, null);
            else File.Move(temporary, path);
        }
        catch { log.Write(LocalStatus.LastGoodWriteFailed); }
    }
}
