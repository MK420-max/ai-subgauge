using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using AISubGauge.Providers;

namespace AISubGauge;

public sealed class QuotaService : IAsyncDisposable
{
    private readonly IReadOnlyList<IQuotaProvider> _providers;
    private readonly bool _demo;
    private readonly Func<IQuotaProvider, bool> _isVisible;
    private readonly AppSettings _settings;
    private readonly CancellationTokenSource _lifetime = new();
    private readonly System.Windows.Forms.Timer _timer = new() { Interval = 5 * 60 * 1000 };
    private Task _refreshTask = Task.CompletedTask;
    private bool _stopped;

    internal QuotaService(IReadOnlyList<IQuotaProvider> providers, bool demo, Func<IQuotaProvider, bool> isVisible, AppSettings settings)
    {
        _providers = providers;
        _demo = demo;
        _isVisible = isVisible;
        _settings = settings;
        _timer.Tick += async (_, _) => await RefreshAsync();
    }

    public IReadOnlyList<QuotaSnapshot> Snapshots { get; private set; } = Array.Empty<QuotaSnapshot>();
    public event EventHandler? Updated;

    // Call on the WinForms UI thread; events then return to that same thread.
    public Task StartAsync()
    {
        _timer.Start();
        return RefreshAsync();
    }

    public Task RefreshAsync()
    {
        if (_stopped)
            return Task.CompletedTask;
        if (!_refreshTask.IsCompleted)
            return _refreshTask;
        _refreshTask = RefreshCoreAsync();
        return _refreshTask;
    }

    public async Task RefreshSelectionAsync()
    {
        await _refreshTask;
        await RefreshAsync();
    }

    private async Task RefreshCoreAsync()
    {
        try
        {
            QuotaSnapshot[] results = await Task.WhenAll(_providers.Where(_isVisible).Select(ReadInBackground));
            if (_stopped)
                return;
            Snapshots = results;
            Updated?.Invoke(this, EventArgs.Empty);
        }
        catch (OperationCanceledException) when (_lifetime.IsCancellationRequested) { }
    }

    private Task<QuotaSnapshot> ReadInBackground(IQuotaProvider provider)
    {
        // Snapshot consent on the UI thread; workers never race a mutable settings dictionary.
        bool consent = _settings.HasConsent(provider.Id);
        return Task.Run(() => ReadProviderAsync(provider, _demo, _lifetime.Token, consent), _lifetime.Token);
    }

    internal static async Task<QuotaSnapshot> ReadProviderAsync(IQuotaProvider provider, bool demo, CancellationToken cancellationToken, bool consent)
    {
        if (demo)
            return await new DemoProvider(provider).FetchAsync(cancellationToken).ConfigureAwait(false);
        if (!consent)
            return QuotaSnapshot.Failure(provider, I18n.Get("windows.reading.local.login.information.has.not.been.allowed"));
        try
        {
            if (!provider.IsSignedInLocally())
                return QuotaSnapshot.Failure(provider, I18n.Get(provider is CodexProvider ?
                    "windows.codex.is.not.signed.in.sign.in.to.the.codex" : "windows.not.signed.in.locally"));
            QuotaSnapshot snapshot = await provider.FetchAsync(cancellationToken).ConfigureAwait(false);
            return snapshot.Error is not null || snapshot.Windows.Count == 0
                ? DemoProvider.Create(provider, snapshot.Error ?? I18n.Get("windows.no.usable.quota.windows.returned"))
                : snapshot;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
        catch (Exception) { return DemoProvider.Create(provider, I18n.Get("windows.could.not.read.quota")); }
    }

    public async ValueTask DisposeAsync()
    {
        if (_stopped)
            return;
        _stopped = true;
        _timer.Stop();
        _timer.Dispose();
        _lifetime.Cancel();
        try { await _refreshTask; }
        finally { _lifetime.Dispose(); }
    }
}
