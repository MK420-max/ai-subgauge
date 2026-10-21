using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace AISubGauge.Providers;

public interface IQuotaProvider
{
    string Id { get; }
    string DisplayName { get; }
    string LogoResource { get; }
    bool IsSignedInLocally();
    Task<QuotaSnapshot> FetchAsync(CancellationToken cancellationToken);
}

public sealed class QuotaSnapshot
{
    public required IQuotaProvider Provider { get; init; }
    public string Plan { get; init; } = I18n.Get("windows.unknown.plan");
    public List<QuotaWindow> Windows { get; init; } = new();
    public bool IsDemo { get; init; }
    public bool IsStale { get; init; }
    public string? Error { get; init; }
    public string? Info { get; init; }
    public DateTime UpdatedAt { get; init; } = DateTime.Now;

    // Reset time in compact views belongs to the window with the least quota.
    public QuotaWindow? MainWindow => Windows.OrderBy(window => window.RemainingPercent ?? double.PositiveInfinity).FirstOrDefault();
    public double? RemainingPercent => MainWindow?.RemainingPercent;

    public static QuotaSnapshot Failure(IQuotaProvider provider, string safeError) => new()
    {
        Provider = provider,
        Error = safeError
    };
}

public sealed class QuotaWindow
{
    private double? _remainingPercent;

    public required string Id { get; init; }
    public required string Title { get; init; }
    public double? RemainingPercent
    {
        get => _remainingPercent;
        init => _remainingPercent = value is double number && double.IsFinite(number) ? Math.Clamp(number, 0, 100) : null;
    }
    public DateTimeOffset? ResetsAt { get; init; }
}

// Only fixed, application-authored messages may cross the provider/UI boundary.
internal sealed class QuotaReadException : Exception
{
    public QuotaReadException(string safeMessage) : base(safeMessage) { }
}
