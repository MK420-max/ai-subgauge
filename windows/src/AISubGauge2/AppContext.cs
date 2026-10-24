using AISubGauge.Core;
using Microsoft.Win32;
using System.Diagnostics;
using System.Globalization;

namespace AISubGauge.UI;

public sealed class Options
{
    public string? ScreenshotDirectory { get; private set; }
    public bool Demo { get; private set; }
    public bool Autostart { get; private set; }
    public Theme Theme { get; private set; } = Theme.System;
    public Language Language { get; private set; } = Language.System;
    public static Options Parse(string[] args)
    {
        var result = new Options(); var seen = new HashSet<string>();
        for (int i = 0; i < args.Length; i++)
        {
            string arg = args[i]; if (!seen.Add(arg)) throw new ArgumentException("Invalid command-line options.");
            string Next() => ++i < args.Length ? args[i] : throw new ArgumentException("Invalid command-line options.");
            switch (arg)
            {
                case "--screenshot": result.ScreenshotDirectory = Path.GetFullPath(Next()); break;
                case "--theme": result.Theme = Next() switch { "light" => Theme.Light, "dark" => Theme.Dark, _ => throw new ArgumentException("Invalid command-line options.") }; break;
                case "--lang": result.Language = Next() switch { "zh" => Language.Chinese, "en" => Language.English, _ => throw new ArgumentException("Invalid command-line options.") }; break;
                case "--demo": result.Demo = true; break;
                case "--autostart": result.Autostart = true; break;
                default: throw new ArgumentException("Invalid command-line options.");
            }
        }
        if (result.ScreenshotDirectory is not null && (result.Theme == Theme.System || result.Language == Language.System)) throw new ArgumentException("Invalid command-line options.");
        return result;
    }
}
public sealed class AppContext : ApplicationContext
{
    public IClock Clock { get; } = new SystemClock();
    public Settings Settings { get; }
    public Texts Text { get; private set; }
    public Palette Palette { get; private set; }
    public bool Demo => options.Demo;
    public bool Capturing => options.ScreenshotDirectory is not null;
    public bool Refreshing { get; private set; }
    public DateTimeOffset? Updated { get; private set; }
    public Snapshot[] Snapshots { get; private set; }
    public IReadOnlyList<Snapshot> VisibleSnapshots => Snapshots.Where(s => visible[(int)s.Vendor]).ToArray();
    private readonly Options options;
    private readonly SettingsStore store;
    private readonly RunningGate gate;
    private readonly bool[] visible = [false, false, false];
    private readonly NotifyIcon[] icons = new NotifyIcon[3];
    internal IReadOnlyList<NotifyIcon> NotificationIcons => icons;
    private readonly System.Windows.Forms.Timer refreshTimer = new() { Interval = 300000 };
    private readonly System.Windows.Forms.Timer runningTimer = new() { Interval = 2000 };
    private readonly CancellationTokenSource lifetime = new();
    private readonly List<IProvider> providers = [];
    private readonly Form dispatcher = new();
    private readonly PanelForm panel;
    private readonly SettingsForm settingsForm;
    private readonly EventWaitHandle activation;
    private readonly RegisteredWaitHandle activationWait;
    private bool disposed;
    private readonly AutostartState autostart;
    public bool AutostartFailed => autostart.Failed;
    internal bool TimersRunning => refreshTimer.Enabled && runningTimer.Enabled;
    internal SettingsForm SettingsWindow => settingsForm;
    public AppContext(Options options) : this(options, null) { }
    // Tests inject a registry in demo mode: no credentials, network or real registry writes.
    internal AppContext(Options options, IRunRegistry? registry, SafeLog? startupLog = null, SettingsStore? settingsStore = null)
    {
        autostart = new(registry ?? new RunRegistry(), startupLog ?? new SafeLog(new Redactor()));
        this.options = options; store = settingsStore ?? new(SettingsStore.DefaultDirectory, Capturing || Demo);
        Settings = Capturing || Demo ? new Settings() : store.Load();
        if (Capturing) Settings.AlwaysShow = true;
        if (options.Theme != Theme.System) Settings.Theme = options.Theme;
        if (options.Language != Language.System) Settings.Language = options.Language;
        Text = new(Presentation.ResolveLanguage(Settings.Language, CultureInfo.CurrentUICulture));
        Palette = new(Presentation.IsDark(Settings.Theme, SystemAppearance.Light()));
        gate = new(Clock); Snapshots = Enum.GetValues<Vendor>().Select(v => Snapshot.Failure(v, Fault.NotAvailable, Clock)).ToArray();
        _ = dispatcher.Handle;
        if (!Demo)
        {
            var redactor = new Redactor(); var log = new SafeLog(redactor); var credentials = new CredentialFiles(Clock);
            providers.Add(new CodexProvider(Clock, log, allowUnsignedNpm: () => Settings.AllowUnsignedCodexNpm));
            providers.Add(new SubscriptionProvider(Vendor.Claude, credentials, Clock, redactor, log));
            providers.Add(new SubscriptionProvider(Vendor.Grok, credentials, Clock, redactor, log, refresh: new GrokCliRefresh(credentials, Clock, log: log), cache: new GrokBotCache(Clock)));
        }
        panel = new(this); settingsForm = new(this);
        for (int i = 0; i < icons.Length; i++)
        {
            icons[i] = new NotifyIcon(); icons[i].MouseClick += (_, e) => { if (e.Button == MouseButtons.Left) panel.OpenNearTray(); };
        }
        activation = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\AISubGauge2.Activate");
        activationWait = ThreadPool.RegisterWaitForSingleObject(activation, (_, _) => Dispatch(OpenSettings), null, Timeout.Infinite, false);
        SystemEvents.UserPreferenceChanged += PreferencesChanged;
        refreshTimer.Tick += async (_, _) => await RefreshAsync(); runningTimer.Tick += (_, _) =>
        {
            UpdateVisibility(); panel.Invalidate();
            if (renderedTrayMetrics != TrayIconMetrics.Read() || renderedTrayDark != TrayDark) UpdateIcons();
        };
        UpdateMenus(); UpdateVisibility(); UpdateIcons();
        dispatcher.BeginInvoke(async () =>
        {
            try
            {
                if (!Capturing && (!Demo || registry is not null))
                {
                    autostart.Apply(Settings.Autostart, Environment.ProcessPath!);
                    settingsForm.RefreshView();
                }
                if (!Capturing && !options.Autostart) OpenSettings();
                await RefreshAsync();
                if (Capturing) { await Capture.RunAsync(this, panel, settingsForm, options); Quit(); }
                else { refreshTimer.Start(); runningTimer.Start(); }
            }
            catch (Exception error)
            {
                Environment.ExitCode = 1;
                if (Capturing) { Capture.WriteFailure(options, error); Quit(); }
                else MessageBox.Show(Text["StartupFailed"], Text["AppTitle"], MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        });
    }
    private void Dispatch(Action action) { if (!disposed && !dispatcher.IsDisposed) try { dispatcher.BeginInvoke(action); } catch (InvalidOperationException) { } }
    private void PreferencesChanged(object sender, UserPreferenceChangedEventArgs e) => Dispatch(RefreshAppearance);
    private void RefreshAppearance()
    {
        Text = new(Presentation.ResolveLanguage(Settings.Language, CultureInfo.CurrentUICulture)); Palette = new(Presentation.IsDark(Settings.Theme, SystemAppearance.Light()));
        panel.RefreshView(); settingsForm.RefreshView(); UpdateMenus(); UpdateIcons();
    }
    public void Change(Action<Settings> change)
    {
        // Defer rebuilding controls until the originating click/selection event has returned.
        Dispatch(() =>
        {
            var old = System.Text.Json.JsonSerializer.Deserialize<Settings>(System.Text.Json.JsonSerializer.Serialize(Settings))!;
            change(Settings);
            try
            {
                store.Save(Settings);
                if (!Capturing && !Demo && old.Autostart != Settings.Autostart)
                    autostart.Apply(Settings.Autostart, Environment.ProcessPath!);
            }
            catch
            {
                Settings.AllowUnsignedCodexNpm = old.AllowUnsignedCodexNpm;
                Settings.ShowTrayPercentage = old.ShowTrayPercentage;
                Settings.Language = old.Language; Settings.Theme = old.Theme; Settings.AlwaysShow = old.AlwaysShow; Settings.TrayEnabled = old.TrayEnabled; Settings.Autostart = old.Autostart;
                MessageBox.Show(Text["SaveFailed"], Text["AppTitle"], MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
            UpdateVisibility(); RefreshAppearance();
            if (old.AllowUnsignedCodexNpm != Settings.AllowUnsignedCodexNpm) _ = RefreshAsync();
        });
    }
    public async Task RefreshAsync()
    {
        if (Refreshing || disposed) return; Refreshing = true; panel.Invalidate(); settingsForm.Invalidate();
        try
        {
            var results = Demo ? Enum.GetValues<Vendor>().Select(v => Snapshot.Demo(v, Clock)).ToArray() : await Task.WhenAll(providers.Select(p => p.FetchAsync(lifetime.Token)));
            if (disposed) return;
            Snapshots = results; Updated = Clock.Now; UpdateVisibility(); UpdateIcons();
        }
        finally { Refreshing = false; if (!disposed) { panel.Invalidate(); settingsForm.Invalidate(); } }
    }
    private void UpdateVisibility()
    {
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        if (!Capturing && !Settings.AlwaysShow)
        {
            foreach (var process in Process.GetProcesses())
            {
                using (process) try { if (!RpcSession.ActiveProcessIds.ContainsKey(process.Id)) names.Add(process.ProcessName); } catch { }
            }
        }
        for (int i = 0; i < 3; i++)
        {
            var vendor = (Vendor)i;
            visible[i] = gate.Visible(vendor, RunningGate.ProcessNames[vendor].Any(names.Contains), Capturing || Settings.AlwaysShow);
            icons[i].Visible = (Capturing || Settings.TrayEnabled[i]) && visible[i];
        }
    }
    public bool TrayDark => !SystemAppearance.Light(true);
    public int TrayIconSize { get; private set; }
    private bool renderedTrayDark;
    private (uint Dpi, int Size) renderedTrayMetrics;
    internal TrayIconFamily[] TrayIconFamilies { get; } = new TrayIconFamily[3];
    private void UpdateIcons()
    {
        renderedTrayMetrics = TrayIconMetrics.Read(); TrayIconSize = renderedTrayMetrics.Size;
        bool dark = TrayDark; renderedTrayDark = dark;
        for (int i = 0; i < 3; i++)
        {
            var snapshot = Snapshots[i];
            var family = new TrayIconFamily(snapshot.Vendor, snapshot.FiveHour.Percent ?? snapshot.Weekly.Percent, dark, Settings.ShowTrayPercentage);
            var replacement = family.CreateIcon(TrayIconSize);
            var old = icons[i].Icon; icons[i].Icon = replacement; old?.Dispose();
            TrayIconFamilies[i] = family;
            string tooltip = Text.Name(snapshot.Vendor) + " · " + Text.Status(snapshot);
            icons[i].Text = tooltip.Length > 63 ? tooltip[..63] : tooltip;
        }
    }
    private void UpdateMenus()
    {
        foreach (var icon in icons)
        {
            var old = icon.ContextMenuStrip; var menu = new ContextMenuStrip { BackColor = Palette.Card, ForeColor = Palette.Text };
            menu.Items.Add(Text["Refresh"], null, async (_, _) => await RefreshAsync());
            menu.Items.Add(Text["Settings"], null, (_, _) => OpenSettings()); menu.Items.Add(Text["Exit"], null, (_, _) => Quit());
            icon.ContextMenuStrip = menu; old?.Dispose();
        }
    }
    public void OpenSettings()
    {
        panel.Hide(); if (!settingsForm.Visible) { var area = Screen.FromPoint(Cursor.Position).WorkingArea; settingsForm.Location = new(area.Left + (area.Width - settingsForm.Width) / 2, area.Top + (area.Height - settingsForm.Height) / 2); }
        settingsForm.Show(); settingsForm.Activate();
    }
    public void Quit() { Dispose(); ExitThread(); }
    protected override void Dispose(bool disposing)
    {
        if (disposing && !disposed)
        {
            disposed = true; lifetime.Cancel(); SystemEvents.UserPreferenceChanged -= PreferencesChanged;
            activationWait.Unregister(null); activation.Dispose(); refreshTimer.Dispose(); runningTimer.Dispose();
            foreach (var icon in icons) { icon.Visible = false; var image = icon.Icon; var menu = icon.ContextMenuStrip; icon.Dispose(); image?.Dispose(); menu?.Dispose(); }
            panel.Dispose(); settingsForm.Dispose(); dispatcher.Dispose();
            foreach (var provider in providers.OfType<IDisposable>()) provider.Dispose();
            lifetime.Dispose(); Logos.DisposeAll();
        }
        base.Dispose(disposing);
    }
}

