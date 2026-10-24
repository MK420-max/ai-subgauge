using System.Globalization;

namespace AISubGauge.Core;

public enum Vendor { Codex, Claude, Grok }
public enum Fault { None, SignIn, Network, InvalidData, RefreshFailed, Timeout, CacheExpired, NotAvailable, VerificationFailed, VerifierUnresponsive }
public enum Plan { Unknown, Plus, Pro, Max, SuperGrok, SuperGrokHeavy, Team, Enterprise, Free }
public enum Language { System, Chinese, English }
public enum Theme { System, Light, Dark }
public interface IClock { DateTimeOffset Now { get; } }
public sealed class SystemClock : IClock { public DateTimeOffset Now => DateTimeOffset.UtcNow; }

public sealed record Window(double? Remaining = null, DateTimeOffset? Reset = null)
{
    public double? Percent => Remaining is double n && double.IsFinite(n) ? Math.Clamp(n, 0, 100) : null;
}
public sealed record Snapshot(Vendor Vendor, Plan Plan, Window FiveHour, Window Weekly, DateTimeOffset Updated, Fault Fault = Fault.None)
{
    public static Snapshot Failure(Vendor vendor, Fault fault, IClock clock) => new(vendor, Plan.Unknown, new(), new(), clock.Now, fault);
    public static Snapshot Demo(Vendor vendor, IClock clock) => vendor switch
    {
        Vendor.Codex => new(vendor, Plan.Plus, new(72, clock.Now.AddHours(3)), new(58, clock.Now.AddDays(4)), clock.Now),
        Vendor.Claude => new(vendor, Plan.Pro, new(35, clock.Now.AddHours(2)), new(61, clock.Now.AddDays(3)), clock.Now),
        _ => new(vendor, Plan.SuperGrok, new(8, clock.Now.AddHours(1)), new(22, clock.Now.AddDays(5)), clock.Now)
    };
}
public static class Presentation
{
    public static string Color(double? percent, bool dark) => percent is null ? (dark ? "#636366" : "#AEAEB2") :
        percent >= 50 ? (dark ? "#30D158" : "#34C759") : percent >= 20 ? (dark ? "#FF9F0A" : "#FF9500") : (dark ? "#FF453A" : "#FF3B30");
    public static string Percent(double? value) => value is double n && double.IsFinite(n) ? Math.Clamp(n, 0, 100).ToString("0", CultureInfo.InvariantCulture) + "%" : "—";
    public static Plan ParsePlan(string? value) => value?.Replace("_", "").Replace("-", "").Replace(" ", "").ToLowerInvariant() switch
    {
        "plus" or "chatgptplus" => Plan.Plus, "pro" or "claudepro" or "chatgptpro" => Plan.Pro,
        "max" or "claudemax" => Plan.Max, "supergrok" => Plan.SuperGrok, "supergrokheavy" => Plan.SuperGrokHeavy,
        "team" => Plan.Team, "enterprise" => Plan.Enterprise, "free" => Plan.Free, _ => Plan.Unknown
    };
    public static bool IsDark(Theme choice, bool systemLight) => choice == Theme.Dark || (choice == Theme.System && !systemLight);
    public static string ResolveLanguage(Language choice, CultureInfo system) => choice == Language.Chinese ||
        (choice == Language.System && system.Name.StartsWith("zh", StringComparison.OrdinalIgnoreCase)) ? "zh-CN" : "en";
}

public sealed class Settings
{
    public Language Language { get; set; }
    public Theme Theme { get; set; }
    public bool AlwaysShow { get; set; }
    public bool ShowTrayPercentage { get; set; } = false;
    public bool AllowUnsignedCodexNpm { get; set; }
    public bool Autostart { get; set; } = true;
    public bool[] TrayEnabled { get; set; } = [true, true, true];
}

public sealed class RunningGate(IClock clock)
{
    // Edit these lists to support additional native executable names. No command-line inspection.
    public static readonly IReadOnlyDictionary<Vendor, string[]> ProcessNames = new Dictionary<Vendor, string[]>
    {
        [Vendor.Codex] = ["codex", "Codex"], [Vendor.Claude] = ["claude", "Claude"],
        [Vendor.Grok] = ["grok", "Grok Bot", "grok-bot", "grokbot"]
    };
    private readonly Dictionary<Vendor, DateTimeOffset> stopped = [];
    private readonly HashSet<Vendor> runningBefore = [];
    public bool Visible(Vendor vendor, bool running, bool always)
    {
        if (running) { runningBefore.Add(vendor); stopped.Remove(vendor); }
        else if (runningBefore.Remove(vendor)) stopped[vendor] = clock.Now;
        return always || running || (stopped.TryGetValue(vendor, out var end) && clock.Now - end < TimeSpan.FromSeconds(30));
    }
}
