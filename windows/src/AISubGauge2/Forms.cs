using AISubGauge.Core;
using System.Drawing.Drawing2D;

namespace AISubGauge.UI;

public abstract class RoundedForm : Form
{
    protected readonly AppContext App;
    private readonly Size logicalSize;
    protected Palette P => App.Palette;
    protected Texts T => App.Text;
    protected float UiScale => DeviceDpi / 96f;
    protected RoundedForm(AppContext app, Size logicalSize)
    {
        App = app; this.logicalSize = logicalSize; AutoScaleMode = AutoScaleMode.None;
        ClientSize = new Size((int)(logicalSize.Width * UiScale), (int)(logicalSize.Height * UiScale)); FormBorderStyle = FormBorderStyle.None; DoubleBuffered = true;
        ShowInTaskbar = false; KeyPreview = true; StartPosition = FormStartPosition.Manual;
        KeyDown += (_, e) => { if (e.KeyCode == Keys.Escape) { Hide(); e.Handled = true; } };
        MouseDown += (_, e) => { if (e.Button == MouseButtons.Left && e.Y < 45 * UiScale) { Native.ReleaseCapture(); Native.SendMessage(Handle, 0xA1, (IntPtr)2, IntPtr.Zero); } };
    }
    protected override void OnResize(EventArgs e)
    {
        base.OnResize(e); if (Width < 2 || Height < 2) return;
        using var path = UiPaint.Round(new(0, 0, Width, Height), 26 * UiScale); var previous = Region; Region = new Region(path); previous?.Dispose();
    }
    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e); e.Graphics.Clear(P.Background); e.Graphics.ScaleTransform(UiScale, UiScale); e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using var border = UiPaint.Round(new(0.5f, 0.5f, ClientSize.Width / UiScale - 1, ClientSize.Height / UiScale - 1), 26);
        using var pen = new Pen(P.Border); e.Graphics.DrawPath(pen, border);
        Draw(e.Graphics);
    }
    protected abstract void Draw(Graphics g);
    protected void Place(Control control, int x, int y, int width, int height) => control.Bounds = new((int)(x * UiScale), (int)(y * UiScale), (int)(width * UiScale), (int)(height * UiScale));
    protected PillButton Button(string key, int x, int y, int w, Action action, bool primary = false)
    {
        var button = new PillButton { Text = T[key], AccessibleName = T[key], Palette = P, Primary = primary, BackColor = P.Background };
        Place(button, x, y, w, 30); button.Click += (_, _) => action(); Controls.Add(button); return button;
    }
    public abstract void RefreshView();
    protected override void OnDpiChanged(DpiChangedEventArgs e) { base.OnDpiChanged(e); ClientSize = new Size((int)(logicalSize.Width * UiScale), (int)(logicalSize.Height * UiScale)); RefreshView(); }
    protected void ClearControls() { foreach (Control control in Controls.Cast<Control>().ToArray()) control.Dispose(); Controls.Clear(); }
    protected override void OnFormClosing(FormClosingEventArgs e) { if (e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); } base.OnFormClosing(e); }
}
public sealed class PanelForm : RoundedForm
{
    private readonly ToolTip tips = new();
    public PanelForm(AppContext app) : base(app, new(480, 338))
    {
        TopMost = true; Deactivate += (_, _) => { if (!App.Capturing) Hide(); };
        RefreshView();
        MouseMove += (_, e) =>
        {
            int index = ((int)(e.Y / UiScale) - 65) / 72;
            var data = App.VisibleSnapshots;
            string value = index >= 0 && index < data.Count && e.Y / UiScale >= 65 ?
                T["FiveHour"] + ": " + T.Reset(data[index].FiveHour.Reset, App.Clock.Now) + "\n" +
                T["Weekly"] + ": " + T.Reset(data[index].Weekly.Reset, App.Clock.Now) : "";
            if (tips.GetToolTip(this) != value) tips.SetToolTip(this, value);
        };
    }
    public void OpenNearTray()
    {
        var area = Screen.FromPoint(Cursor.Position).WorkingArea;
        Location = new(area.Right - Width - 12, area.Bottom - Height - 12); Show(); Activate();
    }
    public override void RefreshView()
    {
        ClearControls(); Text = T["AppTitle"]; AccessibleName = T["Remaining"];
        Button("Refresh", 230, 294, 74, () => _ = App.RefreshAsync()); Button("Settings", 310, 294, 74, App.OpenSettings); Button("Exit", 390, 294, 74, App.Quit);
        Invalidate();
    }
    protected override void Draw(Graphics g)
    {
        UiPaint.Text(g, T["AppTitle"], new(20, 13, 200, 24), P.Text, 15, true);
        UiPaint.Text(g, T["Remaining"] + (App.Demo ? " · " + T["Demo"] : ""), new(20, 37, 240, 18), P.Secondary, 11);
        UiPaint.Text(g, T["Windows"], new(300, 23, 160, 22), P.Secondary, 11, alignment: StringAlignment.Far);
        var data = App.VisibleSnapshots;
        if (data.Count == 0) UiPaint.Text(g, T["Empty"], new(20, 106, 440, 100), P.Secondary, 12);
        else
        {
            UiPaint.Box(g, new(12, 65, 456, data.Count * 72), P.Card, 20, P.Border);
            for (int i = 0; i < data.Count; i++)
            {
                var item = data[i]; int y = 65 + i * 72;
                if (i > 0) { using var pen = new Pen(P.Border); g.DrawLine(pen, 78, y, 454, y); }
                RingIcon.Draw(g, new(23, y + 12, 48, 48), item.Vendor, item.FiveHour.Percent ?? item.Weekly.Percent, P.Dark);
                UiPaint.NameAndPlan(g, T.Name(item.Vendor), T.PlanName(item.Plan), 83, y + 8,
                    item.Vendor == Vendor.Codex && Executables.UnsignedCodexInUse ? 185 : 258, P);
                bool restart = item.Fault == Fault.VerifierUnresponsive;
                UiPaint.Text(g, CodexRowPresentation.PanelStatus(T, item, App.Clock.Now),
                    restart ? new(83, y + 30, 371, 38) : new(83, y + 34, 174, 23), P.Secondary, 10.5f, wrap: restart);
                if (item.Vendor == Vendor.Codex && Executables.UnsignedCodexInUse)
                    CodexRowPresentation.DrawBadge(g, T, P, 189, y + 8);
                if (!restart) { RowBar(g, item.FiveHour, 268, y + 12); RowBar(g, item.Weekly, 268, y + 37); }
            }
        }
        UiPaint.Text(g, App.Refreshing ? T["Refreshing"] : T.Updated(App.Updated), new(20, 294, 205, 30), P.Secondary, 10.5f);
    }
    private void RowBar(Graphics g, Window window, int x, int y)
    {
        UiPaint.Bar(g, new(x, y + 3, 128, 7), window.Percent, P);
        UiPaint.Text(g, Presentation.Percent(window.Percent), new(x + 132, y - 3, 47, 18), P.Secondary, 11, alignment: StringAlignment.Far);
        UiPaint.Text(g, T.Reset(window.Reset, App.Clock.Now), new(x, y + 11, 179, 14), P.Secondary, 8.5f);
    }
    protected override void Dispose(bool disposing) { if (disposing) tips.Dispose(); base.Dispose(disposing); }
}
public sealed class SettingsForm : RoundedForm
{
    public bool GeneralPage { get; private set; }
    public SettingsForm(AppContext app) : base(app, new(800, 480)) { ShowInTaskbar = true; RefreshView(); }
    public void SelectPage(bool general) { GeneralPage = general; RefreshView(); }
    public override void RefreshView()
    {
        ClearControls(); Text = T["AppTitle"] + " · " + T["Settings"];
        Button("Subscriptions", 22, 72, 154, () => SelectPage(false), !GeneralPage).BackColor = P.Sidebar;
        Button("General", 22, 112, 154, () => SelectPage(true), GeneralPage).BackColor = P.Sidebar;
        Button("Close", 706, 20, 74, Hide);
        if (!GeneralPage)
        {
            AddToggle(120, App.Settings.ShowTrayPercentage, "ShowTrayPercentage", value => App.Change(s => s.ShowTrayPercentage = value));
            for (int i = 0; i < 3; i++)
            {
                int index = i;
                var toggle = new Toggle { Checked = App.Settings.TrayEnabled[i], Palette = P, BackColor = P.Card, AccessibleName = T.Name((Vendor)i) + " " + T["TrayShow"] };
                Place(toggle, 718, 192 + i * 76, 38, 23);
                toggle.CheckedChanged += (_, _) => App.Change(s => s.TrayEnabled[index] = toggle.Checked);
                Controls.Add(toggle);
            }
            Button("RefreshNow", 220, 421, 120, () => _ = App.RefreshAsync());
        }
        else
        {
            Combo(128, [T["FollowSystem"], T["Chinese"], T["English"]], (int)App.Settings.Language, i => App.Change(s => s.Language = (Language)i), T["Language"]);
            Combo(197, [T["FollowSystem"], T["Light"], T["Dark"]], (int)App.Settings.Theme, i => App.Change(s => s.Theme = (Theme)i), T["Theme"]);
            AddToggle(272, App.Settings.AlwaysShow, "AlwaysShow", value => App.Change(s => s.AlwaysShow = value));
            AddToggle(338, App.Settings.Autostart, "Autostart", value => App.Change(s => s.Autostart = value));
            AddToggle(408, App.Settings.AllowUnsignedCodexNpm, "AllowUnsignedCodexNpm", value => App.Change(s => s.AllowUnsignedCodexNpm = value));
        }
        Invalidate();
    }
    private void Combo(int y, string[] choices, int selected, Action<int> action, string accessible)
    {
        var combo = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, BackColor = P.Card, ForeColor = P.Text, Font = new Font("Microsoft YaHei UI", 10), AccessibleName = accessible };
        combo.Items.AddRange(choices); combo.SelectedIndex = selected; Place(combo, 547, y, 207, 32);
        combo.SelectedIndexChanged += (_, _) => action(combo.SelectedIndex); Controls.Add(combo);
    }
    private void AddToggle(int y, bool selected, string key, Action<bool> action)
    {
        bool error = key == "Autostart" && App.AutostartFailed;
        var toggle = new Toggle { Checked = selected, Error = error, Palette = P, BackColor = P.Card, AccessibleName = T[key], AccessibleDescription = error ? T["AutostartFailed"] : T[key] };
        Place(toggle, 716, y, 38, 23); toggle.CheckedChanged += (_, _) => action(toggle.Checked); Controls.Add(toggle);
    }
    protected override void Draw(Graphics g)
    {
        UiPaint.Box(g, new(8, 8, 186, 464), P.Sidebar, 22, P.Border);
        UiPaint.Text(g, T["AppTitle"], new(23, 24, 160, 25), P.Text, 15, true);
        UiPaint.Text(g, "2.0.0", new(24, 430, 150, 22), P.Secondary, 11);
        UiPaint.Text(g, T[GeneralPage ? "General" : "Subscriptions"], new(220, 27, 460, 32), P.Text, 20, true);
        UiPaint.Text(g, T[GeneralPage ? "GeneralDescription" : "SubsDescription"], new(220, 68, 550, 23), P.Secondary, 11);
        if (GeneralPage)
        {
            UiPaint.Box(g, new(220, 108, 554, 350), P.Card, 14, P.Border);
            UiPaint.Text(g, T["Language"], new(238, 125, 280, 30), P.Text, 13);
            UiPaint.Text(g, T["Theme"], new(238, 194, 280, 30), P.Text, 13);
            UiPaint.Text(g, T["AlwaysShow"], new(238, 267, 450, 30), P.Text, 13);
            UiPaint.Text(g, T["AlwaysHint"], new(238, 301, 514, 24), P.Secondary, 10.5f);
            UiPaint.Text(g, T["Autostart"], new(238, 332, 450, 30), P.Text, 13);
            UiPaint.Text(g, T[App.AutostartFailed ? "AutostartFailed" : "AutostartHint"], new(238, 366, 514, 24), App.AutostartFailed ? ColorTranslator.FromHtml(Presentation.Color(10, P.Dark)) : P.Secondary, 10.5f);
            UiPaint.Text(g, T["AllowUnsignedCodexNpm"], new(238, 402, 470, 30), P.Text, 11);
        }
        else
        {
            UiPaint.Box(g, new(220, 108, 554, 48), P.Card, 14, P.Border);
            UiPaint.Text(g, T["ShowTrayPercentage"], new(238, 117, 460, 30), P.Text, 13);
            UiPaint.Box(g, new(220, 168, 554, 228), P.Card, 14, P.Border);
            for (int i = 0; i < 3; i++)
            {
                var item = App.Snapshots[i]; int y = 168 + i * 76;
                if (i > 0) { using var pen = new Pen(P.Border); g.DrawLine(pen, 234, y, 760, y); }
                Logos.Draw(g, item.Vendor, P.Dark, new Rectangle(238, y + 23, 28, 28));
                UiPaint.NameAndPlan(g, T.Name(item.Vendor), T.PlanName(item.Plan), 281, y + 12,
                    item.Vendor == Vendor.Codex && Executables.UnsignedCodexInUse ? 512 : 600, P);
                bool restart = item.Fault == Fault.VerifierUnresponsive;
                UiPaint.Text(g, CodexRowPresentation.SettingsStatus(T, item),
                    restart ? new(281, y + 34, 327, 40) : new(281, y + 38, 327, 23),
                    item.Fault == Fault.None ? P.Secondary : ColorTranslator.FromHtml(Presentation.Color(10, P.Dark)), 11, wrap: restart);
                if (item.Vendor == Vendor.Codex && Executables.UnsignedCodexInUse)
                    CodexRowPresentation.DrawBadge(g, T, P, 520, y + 12);
                if (!restart && Executables.CustomPathInUse(item.Vendor))
                    UiPaint.Text(g, T[item.Vendor == Vendor.Codex ? "CustomCodexPath" : "CustomGrokPath"], new(281, y + 59, 327, 15), P.Secondary, 9);
                UiPaint.Text(g, T["TrayShow"], new(615, y + 23, 92, 26), P.Secondary, 11, alignment: StringAlignment.Far);
            }
            UiPaint.Text(g, App.Refreshing ? T["Refreshing"] : T.Updated(App.Updated), new(360, 421, 414, 30), P.Secondary, 11, alignment: StringAlignment.Far);
            if (App.Demo) UiPaint.Text(g, T["Demo"], new(220, 454, 554, 22), P.Secondary, 11);
        }
    }
}
internal static class CodexRowPresentation
{
    internal static string PanelStatus(Texts text, Snapshot item, DateTimeOffset now) => item.Fault == Fault.None
        ? text.Reset(item.FiveHour.Reset ?? item.Weekly.Reset, now) : text.Error(item.Fault);
    internal static string SettingsStatus(Texts text, Snapshot item) => text.Status(item);
    internal static string Badge(Texts text, bool unsigned) => unsigned ? text["Unsigned"] : "";
    internal static void DrawBadge(Graphics g, Texts text, Palette palette, int x, int y)
    {
        var color = ColorTranslator.FromHtml(Presentation.Color(25, palette.Dark));
        UiPaint.Box(g, new(x, y, 68, 21), palette.Card, 5, color);
        UiPaint.Text(g, Badge(text, true), new(x + 3, y, 62, 21), color, 8.5f, alignment: StringAlignment.Center);
    }
}
internal static partial class Native
{
    [System.Runtime.InteropServices.DllImport("user32.dll")] internal static extern bool ReleaseCapture();
    [System.Runtime.InteropServices.DllImport("user32.dll")] internal static extern IntPtr SendMessage(IntPtr window, uint message, IntPtr wparam, IntPtr lparam);
}


