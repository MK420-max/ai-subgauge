using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace AISubGauge.Providers;

public sealed class DemoProvider : IQuotaProvider
{
    private readonly IQuotaProvider _source;

    public DemoProvider(IQuotaProvider source) => _source = source;
    public string Id => _source.Id;
    public string DisplayName => _source.DisplayName;
    public string LogoResource => _source.LogoResource;
    public bool IsSignedInLocally() => _source.IsSignedInLocally();

    public Task<QuotaSnapshot> FetchAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult(Create(_source));
    }

    public static QuotaSnapshot Create(IQuotaProvider source, string? safeError = null)
    {
        DateTimeOffset now = DateTimeOffset.Now;
        bool codex = source.Id == "codex";
        var windows = source.Id == "grok" ? new List<QuotaWindow>
        {
            new() { Id = "demo.grok.weekly", Title = I18n.Get("quota.weekly"), RemainingPercent = 55, ResetsAt = now.AddDays(4) }
        } : new List<QuotaWindow>
        {
            new() { Id = "demo.five_hour", Title = I18n.Get("quota.fiveHours"), RemainingPercent = codex ? 72 : 40, ResetsAt = now.AddHours(codex ? 3 : 8) },
            new() { Id = "demo.seven_day", Title = I18n.Get("quota.weekly"), RemainingPercent = codex ? 86 : 64, ResetsAt = now.AddDays(4) }
        };
        if (source.Id == "claude")
        {
            windows.Add(new QuotaWindow { Id = "demo.opus", Title = I18n.Get("usage.opus.weekly"), RemainingPercent = 57, ResetsAt = now.AddDays(4) });
            windows.Add(new QuotaWindow { Id = "demo.sonnet", Title = I18n.Get("usage.sonnet.weekly"), RemainingPercent = 78, ResetsAt = now.AddDays(4) });
        }
        if (source.Id == "gemini")
            windows = new List<QuotaWindow>
            {
                new() { Id = "demo.pro", Title = I18n.Get("windows.model.pro"), RemainingPercent = 40, ResetsAt = now.AddHours(8) },
                new() { Id = "demo.flash", Title = I18n.Get("windows.model.flash"), RemainingPercent = 85, ResetsAt = now.AddHours(8) },
                new() { Id = "demo.flash_lite", Title = I18n.Get("windows.model.flashLite"), RemainingPercent = 92, ResetsAt = now.AddHours(8) }
            };
        if (source.Id == "copilot")
            windows = new List<QuotaWindow>
            {
                new() { Id = "demo.premium", Title = I18n.Get("windows.premium.requests"), RemainingPercent = 64, ResetsAt = now.AddDays(12) },
                new() { Id = "demo.chat", Title = I18n.Get("windows.chat.unlimited"), RemainingPercent = 100, ResetsAt = now.AddDays(12) }
            };
        return new QuotaSnapshot { Provider = source, Plan = I18n.Get("windows.demo.plan"), Windows = windows, IsDemo = true, Error = safeError };
    }
}
