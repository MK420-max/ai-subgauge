using System;
using System.Collections.Generic;
using System.Drawing;
using System.Linq;
using Microsoft.Win32;
using System.Threading.Tasks;
using System.Windows.Forms;
using AISubGauge.Providers;
using AISubGauge.UI;

namespace AISubGauge;

internal sealed class TrayApplicationContext : ApplicationContext
{
    private readonly AppOptions _options;
    private readonly AppSettings _settings;
    private readonly IReadOnlyList<IQuotaProvider> _providers = ProviderRegistry.CreateEnabled();
    private readonly LogoCatalog _logos = new();
    private readonly QuotaService _service;
    private readonly DetailsPanel _panel;
    private readonly ContextMenuStrip _menu = new();
    private readonly ToolStripMenuItem _refreshItem = new(I18n.Get("menu.refreshAll"));
    private readonly ToolStripMenuItem _consentItem = new(I18n.Get("windows.local.login.consent"));
    private readonly ToolStripMenuItem _autoStartItem = new(I18n.Get("menu.launchAtLogin")) { CheckOnClick = false };
    private readonly ToolStripMenuItem _visibilityItem = new(I18n.Get("settings.providers"));
    private readonly ToolStripMenuItem _alwaysShowItem = new(I18n.Get("settings.alwaysShowAll"));
    private readonly ToolStripMenuItem _languageItem = new(I18n.Get("settings.language"));
    private readonly ToolStripMenuItem _themeItem = new(I18n.Get("settings.theme"));
    private readonly Dictionary<string, ToolStripMenuItem> _providerItems = new(StringComparer.Ordinal);
    private readonly Dictionary<string, NotifyIcon> _trays = new(StringComparer.Ordinal);
    private readonly Dictionary<string, Icon> _icons = new(StringComparer.Ordinal);
    private readonly Timer _iconSizeTimer = new() { Interval = 2000 };
    private readonly Timer _runningTimer = new() { Interval = RunningProcesses.PollIntervalMilliseconds };
    private readonly RunningProcesses _runningProcesses = new();
    private readonly RunningVisibility _runningVisibility = new();
    private IReadOnlySet<string> _running = new HashSet<string>();
    private readonly NotifyIcon _idleTray;
    private Icon? _idleIcon;
    private bool? _idleDark;
    private int _iconSize;
    private bool _exiting;
    private bool _disposed;

    public TrayApplicationContext(AppOptions options)
    {
        _options = options;
        _settings = options.Demo ? AppSettings.ForDemo() : AppSettings.Load();
        // Quota refresh remains on its five-minute schedule; running detection only filters display.
        _service = new QuotaService(_providers, options.Demo, IsSelected, _settings);
        _panel = new DetailsPanel(_logos);
        _panel.SettingsRequested += () => _menu.Show(Cursor.Position);
        _panel.RefreshRequested += async () => await RefreshAsync();
        _idleTray = new NotifyIcon { ContextMenuStrip = _menu, Text = I18n.Get("windows.idle.tooltip") };
        _idleTray.MouseClick += (_, e) =>
        {
            if (e.Button == MouseButtons.Left && !_exiting) _menu.Show(Cursor.Position);
        };
        _alwaysShowItem.Checked = _settings.AlwaysShowAll;
        _alwaysShowItem.ToolTipText = I18n.Get("settings.running.help");
        _alwaysShowItem.Click += (_, _) =>
        {
            _settings.AlwaysShowAll = !_settings.AlwaysShowAll;
            _alwaysShowItem.Checked = _settings.AlwaysShowAll;
            if (!_settings.Save()) UiMessage.Show(I18n.Get("windows.settings.saveFailed"), I18n.Get("app.name"));
            UpdateTrayIcons();
            UpdatePanel();
        };
        foreach (var choice in new[] { ("system", I18n.Get("settings.language.system")), ("en", I18n.Get("settings.language.en")), ("zh-Hans", I18n.Get("settings.language.zhHans")) })
        {
            var language = new ToolStripMenuItem(choice.Item2) { Checked = _settings.Language == choice.Item1 };
            language.Click += (_, _) =>
            {
                _settings.Language = choice.Item1;
                foreach (ToolStripMenuItem item in _languageItem.DropDownItems) item.Checked = item == language;
                UiMessage.Show(_settings.Save() ? I18n.Get("settings.language.restart") : I18n.Get("windows.settings.saveFailed"), I18n.Get("app.name"));
            };
            _languageItem.DropDownItems.Add(language);
        }
        foreach (var choice in new[] { ("system", I18n.Get("settings.theme.system")), ("light", I18n.Get("settings.theme.light")), ("dark", I18n.Get("settings.theme.dark")) })
        {
            var theme = new ToolStripMenuItem(choice.Item2) { Checked = _settings.Theme == choice.Item1 };
            theme.Click += (_, _) =>
            {
                _settings.Theme = choice.Item1;
                foreach (ToolStripMenuItem item in _themeItem.DropDownItems) item.Checked = item == theme;
                AppTheme.Initialize(_settings.Theme);
                if (!_settings.Save()) UiMessage.Show(I18n.Get("windows.settings.saveFailed"), I18n.Get("app.name"));
            };
            _themeItem.DropDownItems.Add(theme);
        }
        if (!options.Demo) AutoStart.Initialize(_settings);
        _autoStartItem.Checked = _settings.LaunchAtLogin ?? true;
        _autoStartItem.Click += (_, _) =>
        {
            try
            {
                bool enabled = !_autoStartItem.Checked;
                using RegistryKey key = Registry.CurrentUser.CreateSubKey(AutoStart.RunPath);
                new AutoStart(key).Apply(enabled, Environment.ProcessPath ?? throw new InvalidOperationException());
                _settings.LaunchAtLogin = enabled;
                if (!_settings.Save()) throw new InvalidOperationException();
                _autoStartItem.Checked = enabled;
            }
            catch (Exception) { UiMessage.Show(I18n.Get("windows.could.not.change.launch.at.login.check.registry.permissions"), I18n.Get("app.name")); }
        };
        var diagnostics = new ToolStripMenuItem(I18n.Get("menu.diagnostics"));
        diagnostics.Click += (_, _) =>
        {
            using var preview = new DiagnosticsPreview(Diagnostics.Create(_service.Snapshots));
            preview.ShowDialog();
        };
        _refreshItem.Click += async (_, _) => await RefreshAsync();
        foreach (IQuotaProvider provider in _providers)
        {
            var item = new ToolStripMenuItem { CheckOnClick = false };
            item.Click += async (_, _) =>
            {
                _settings.ProviderVisibility[provider.Id] = !IsSelected(provider);
                if (!_settings.Save())
                    UiMessage.Show(I18n.Get("windows.visibility.changed.for.this.session.but.settings.could.not.be"), I18n.Get("app.name"),
                        MessageBoxButtons.OK);
                UpdateTrayIcons();
                UpdatePanel();
                // Finish a refresh already in flight before applying the new provider selection.
                await _service.RefreshSelectionAsync();
            };
            var consent = new ToolStripMenuItem(I18n.Get("windows.consent.allowReading", provider.DisplayName)) { CheckOnClick = false };
            consent.Click += async (_, _) =>
            {
                if (_settings.HasConsent(provider.Id)) _settings.ProviderConsent[provider.Id] = false;
                else AskConsent(provider);
                _settings.Save();
                await _service.RefreshSelectionAsync();
            };
            _consentItem.DropDownItems.Add(consent);
            _providerItems.Add(provider.Id, item);
            _visibilityItem.DropDownItems.Add(item);
            _trays.Add(provider.Id, CreateTray());
        }
        _visibilityItem.Enabled = !options.Demo;
        _visibilityItem.ToolTipText = options.Demo ? I18n.Get("windows.demo.mode.always.shows.all.seven.providers") : I18n.Get("windows.providers.in.gray.can.still.be.selected");
        var exitItem = new ToolStripMenuItem(I18n.Get("windows.quit"));
        exitItem.Click += async (_, _) => await ExitAsync();
        _consentItem.Enabled = !options.Demo;
        _autoStartItem.Enabled = !options.Demo;
        _menu.Items.AddRange(new ToolStripItem[] { _refreshItem, _visibilityItem, _alwaysShowItem, _languageItem, _themeItem, _consentItem, _autoStartItem, diagnostics, exitItem });
        _menu.Opening += (_, _) => UpdateProviderMenu();
        AppTheme.Changed += OnThemeChanged;
        ThemedUi.ApplyMenu(_menu);
        PollRunning();
        _runningTimer.Tick += (_, _) => PollRunning();
        _runningTimer.Start();
        _iconSizeTimer.Tick += (_, _) =>
        {
            if (!_exiting) AppTheme.Refresh();
            if (!_exiting && TrayIconRenderer.CurrentSize() != _iconSize)
                UpdateTrayIcons();
        };
        _iconSizeTimer.Start();
        _service.Updated += OnUpdated;
        Application.Idle += OnStartup;
    }

    private bool IsSelected(IQuotaProvider provider) =>
        _settings.IsVisible(provider.Id, _options.Demo || ProviderRegistry.IsSignedInLocally(provider), _options.Demo);

    private ProviderDisplay Display() => RunningVisibility.Select(_providers.Where(IsSelected).Select(provider => provider.Id),
        _running, _settings.AlwaysShowAll || _options.Demo);

    private void PollRunning()
    {
        if (_exiting) return;
        _running = _runningVisibility.Update(DateTimeOffset.UtcNow, _runningProcesses.Detect());
        UpdateTrayIcons();
        UpdatePanel();
    }

    private NotifyIcon CreateTray()
    {
        var tray = new NotifyIcon { ContextMenuStrip = _menu };
        tray.MouseClick += (_, e) =>
        {
            if (e.Button == MouseButtons.Left && !_exiting)
                _panel.ShowNearTray(Screen.FromPoint(Cursor.Position));
        };
        return tray;
    }

    private void UpdateProviderMenu()
    {
        for (int index = 0; index < _providers.Count; index++)
        {
            IQuotaProvider provider = _providers[index];
            ((ToolStripMenuItem)_consentItem.DropDownItems[index]).Checked = _settings.HasConsent(provider.Id);
            bool signedIn = _options.Demo || ProviderRegistry.IsSignedInLocally(provider);
            ToolStripMenuItem item = _providerItems[provider.Id];
            item.Text = provider.DisplayName + (signedIn ? "" : I18n.Get("windows.not.signed.in.locally.2"));
            if (!_options.Demo && provider is CodexProvider && CodexProvider.CodexCleanupFault)
                item.Text = provider.DisplayName + " · " + CodexProvider.CleanupFaultMessage;
            item.ForeColor = signedIn ? UiStyle.Text : UiStyle.Muted;
            // Do not disable: the user may explicitly show an unsigned provider.
            item.Checked = IsSelected(provider);
        }
    }

    public int ExitCode { get; private set; }

    private async void OnStartup(object? sender, EventArgs e)
    {
        Application.Idle -= OnStartup;
        try
        {
            await RefreshAsync(start: true);
        }
        catch (Exception)
        {
            ExitCode = 1;
            UiMessage.Show(I18n.Get("windows.could.not.initialize.the.interface"), I18n.Get("app.name"), MessageBoxButtons.OK);
            await ExitAsync();
        }
    }

    private bool PromptForConsent()
    {
        if (_options.Demo) return false;
        bool changed = false;
        foreach (IQuotaProvider provider in _providers)
            if (_settings.NeedsConsent(provider.Id) && ProviderRegistry.IsSignedInLocally(provider))
            { AskConsent(provider); changed = true; }
        return changed;
    }

    private void AskConsent(IQuotaProvider provider)
    {
        _settings.ProviderConsent[provider.Id] = UiMessage.Show(
            I18n.Get("consent.question", provider.DisplayName), I18n.Get("app.name"),
            MessageBoxButtons.YesNo) == DialogResult.Yes;
        if (!_settings.Save()) UiMessage.Show(I18n.Get("windows.consent.changed.for.this.session.but.settings.could.not.be"), I18n.Get("app.name"));
    }

    private async Task RefreshAsync(bool start = false)
    {
        if (_exiting) return;
        PromptForConsent();
        _refreshItem.Enabled = false;
        _panel.RefreshEnabled = false;
        try
        {
            if (start) await _service.StartAsync(); else await _service.RefreshAsync();
        }
        finally
        {
            if (!_exiting && !_disposed) { _refreshItem.Enabled = true; _panel.RefreshEnabled = true; }
        }
    }

    private IReadOnlyList<QuotaSnapshot> VisibleSnapshots()
    {
        ProviderDisplay display = Display();
        return DisplaySnapshots().Where(snapshot => display.Providers.Contains(snapshot.Provider.Id)).ToArray();
    }
    // Cleanup faults arise in the background; show them without waiting for the next quota refresh.
    private IReadOnlyList<QuotaSnapshot> DisplaySnapshots() => _service.Snapshots.Select(snapshot =>
        !_options.Demo && snapshot.Provider is CodexProvider && CodexProvider.CodexCleanupFault
            ? QuotaSnapshot.Failure(snapshot.Provider, CodexProvider.CleanupFaultMessage) : snapshot).ToArray();

    private void UpdatePanel() => _panel.SetData(VisibleSnapshots());

    private void OnThemeChanged()
    {
        if (_exiting) return;
        ThemedUi.ApplyMenu(_menu);
        UpdateTrayIcons();
    }

    private async void OnUpdated(object? sender, EventArgs e)
    {
        if (_exiting) return;
        UpdateTrayIcons();
        UpdatePanel();
        if (PromptForConsent()) await _service.RefreshSelectionAsync();
    }

    private void UpdateTrayIcons()
    {
        _iconSize = TrayIconRenderer.CurrentSize();
        ProviderDisplay display = Display();
        IReadOnlyList<QuotaSnapshot> snapshots = DisplaySnapshots();
        foreach (IQuotaProvider provider in _providers)
        {
            NotifyIcon tray = _trays[provider.Id];
            bool visible = display.Providers.Contains(provider.Id);
            if (!visible) { tray.Visible = false; continue; }
            QuotaSnapshot? snapshot = snapshots.FirstOrDefault(item => item.Provider.Id == provider.Id);
            Icon replacement = TrayIconRenderer.CreateIcon(_logos, provider.LogoResource, snapshot, _iconSize);
            tray.Icon = replacement;
            if (_icons.TryGetValue(provider.Id, out Icon? previous)) previous.Dispose();
            _icons[provider.Id] = replacement;
            tray.Text = QuotaText.Tooltip(provider.DisplayName, snapshot);
            tray.Visible = true;
        }
        if (display.ShowIdle)
        {
            if (_idleIcon is null || _idleIcon.Width != _iconSize || _idleDark != AppTheme.TaskbarDark)
            {
                Icon replacement = TrayIconRenderer.CreateIdleIcon(_iconSize);
                _idleTray.Icon = replacement;
                _idleIcon?.Dispose();
                _idleIcon = replacement;
                _idleDark = AppTheme.TaskbarDark;
            }
            _idleTray.Visible = true;
        }
        else _idleTray.Visible = false;
        UpdateProviderMenu();
    }

    private async Task ExitAsync()
    {
        if (_exiting) return;
        _exiting = true;
        Application.Idle -= OnStartup;
        _menu.Enabled = false;
        _iconSizeTimer.Stop();
        _runningTimer.Stop();
        _idleTray.Visible = false;
        foreach (NotifyIcon tray in _trays.Values) tray.Visible = false;
        _panel.Hide();
        try { await _service.DisposeAsync(); }
        finally { ExitThread(); }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing && !_disposed)
        {
            _disposed = true;
            AppTheme.Changed -= OnThemeChanged;
            Application.Idle -= OnStartup;
            _service.Updated -= OnUpdated;
            _iconSizeTimer.Dispose();
            _runningTimer.Dispose();
            _idleTray.Visible = false;
            _idleTray.Dispose();
            _idleIcon?.Dispose();
            foreach (NotifyIcon tray in _trays.Values) { tray.Visible = false; tray.Dispose(); }
            foreach (Icon icon in _icons.Values) icon.Dispose();
            _menu.Dispose();
            _panel.Dispose();
            _logos.Dispose();
        }
        base.Dispose(disposing);
    }
}
