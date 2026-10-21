using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.Linq;
using System.Windows.Forms;
using AISubGauge.Providers;

namespace AISubGauge.UI;

internal sealed class DetailsPanel : Form
{
    private readonly LogoCatalog _logos;
    private readonly Icon _windowIcon = AppBrand.WindowIcon();
    private readonly Font _name = new("Segoe UI", 16, FontStyle.Bold, GraphicsUnit.Pixel);
    private readonly Font _value = new("Segoe UI", 14, FontStyle.Bold, GraphicsUnit.Pixel);
    private readonly Font _small = new("Segoe UI", 11, FontStyle.Regular, GraphicsUnit.Pixel);
    private readonly Font _note = new("Segoe UI", 9, FontStyle.Regular, GraphicsUnit.Pixel);
    private readonly PanelButton _settings = new() { Text = I18n.Get("panel.settings") };
    private readonly PanelButton _refresh = new() { Text = I18n.Get("panel.refresh") };
    private readonly ToolTip _tooltip = new() { OwnerDraw = true };
    private IReadOnlyList<QuotaSnapshot> _snapshots = Array.Empty<QuotaSnapshot>();
    private DateTimeOffset? _previewNow;
    private float ScaleFactor => DeviceDpi / 96f;
    private int ContentHeight => 116 + Math.Max(1, _snapshots.Count) * 78;
    public event Action? SettingsRequested;
    public event Action? RefreshRequested;
    public bool RefreshEnabled { set => _refresh.Enabled = value; }

    public DetailsPanel(LogoCatalog logos)
    {
        _logos = logos;
        Text = I18n.Get("app.name");
        Icon = _windowIcon;
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        ShowInTaskbar = false;
        TopMost = true;
        AutoScaleMode = AutoScaleMode.None;
        DoubleBuffered = true;
        AutoScroll = true;
        _settings.Click += (_, _) => SettingsRequested?.Invoke();
        _refresh.Click += (_, _) => RefreshRequested?.Invoke();
        Controls.AddRange(new Control[] { _settings, _refresh });
        _tooltip.Draw += (_, e) =>
        {
            using var fill = new SolidBrush(AppTheme.Color("surface"));
            using var border = new Pen(AppTheme.Color("border"));
            e.Graphics.FillRectangle(fill, e.Bounds);
            e.Graphics.DrawRectangle(border, 0, 0, e.Bounds.Width - 1, e.Bounds.Height - 1);
            TextRenderer.DrawText(e.Graphics, e.ToolTipText, _small, Rectangle.Inflate(e.Bounds, -4, -3), UiStyle.Text,
                TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix);
        };
        MouseMove += (_, e) =>
        {
            int row = (int)((e.Y - AutoScrollPosition.Y) / ScaleFactor - 53) / 78;
            string text = e.Y - AutoScrollPosition.Y >= U(53) && row >= 0 && row < _snapshots.Count
                ? Subtitle(_snapshots[row]) ?? "" : "";
            if (_tooltip.GetToolTip(this) != text) _tooltip.SetToolTip(this, text);
        };
        Deactivate += (_, _) => Hide();
        AppTheme.Changed += ApplyTheme;
        ApplyTheme();
    }

    private int U(float value) => (int)Math.Round(value * ScaleFactor);
    private static int Order(QuotaSnapshot snapshot) => snapshot.Provider.Id switch
    { "codex" => 0, "grok" => 1, "claude" => 2, _ => 3 };

    public void SetData(IReadOnlyList<QuotaSnapshot> snapshots, DateTimeOffset? previewNow = null)
    {
        _snapshots = snapshots.OrderBy(Order).ToArray();
        _previewNow = previewNow;
        UpdateSize();
        if (Visible) PositionNearTray(Screen.FromControl(this));
        Invalidate();
    }

    private void ApplyTheme()
    {
        BackColor = UiStyle.Background;
        ForeColor = UiStyle.Text;
        _settings.Invalidate();
        _refresh.Invalidate();
        Invalidate();
    }

    private void UpdateSize()
    {
        Rectangle area = Screen.FromControl(this).WorkingArea;
        Point scroll = AutoScrollPosition;
        AutoScrollPosition = Point.Empty;
        ClientSize = new Size(Math.Min(U(440), Math.Max(U(240), area.Width - U(16))),
            Math.Min(U(ContentHeight), Math.Max(U(120), area.Height - U(16))));
        AutoScrollMinSize = new Size(0, U(ContentHeight));
        int width = ClientSize.Width - (VerticalScroll.Visible ? SystemInformation.VerticalScrollBarWidth : 0);
        int buttonWidth = (width - U(42)) / 2;
        _settings.Bounds = new Rectangle(U(16), U(ContentHeight - 50), buttonWidth, U(38));
        _refresh.Bounds = new Rectangle(U(26) + buttonWidth, U(ContentHeight - 50), buttonWidth, U(38));
        AutoScrollPosition = new Point(-scroll.X, -scroll.Y);
        UpdateRegion();
    }

    private void UpdateRegion()
    {
        if (ClientSize.Width == 0 || ClientSize.Height == 0) return;
        using GraphicsPath path = UiStyle.RoundedRectangle(new Rectangle(Point.Empty, ClientSize), U(18));
        Region? previous = Region;
        Region = new Region(path);
        previous?.Dispose();
    }

    public void ShowNearTray(Screen screen)
    {
        UpdateSize();
        PositionNearTray(screen);
        Show();
        UpdateSize();
        PositionNearTray(screen);
        AutoScrollPosition = Point.Empty;
        Activate();
    }

    private void PositionNearTray(Screen screen)
    {
        Rectangle area = screen.WorkingArea;
        Location = new Point(Math.Max(area.Left, area.Right - Width - U(8)), Math.Max(area.Top, area.Bottom - Height - U(8)));
    }
    protected override void OnDpiChanged(DpiChangedEventArgs e) { base.OnDpiChanged(e); UpdateSize(); Invalidate(); }
    protected override void OnScroll(ScrollEventArgs e) { base.OnScroll(e); Invalidate(); }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        GraphicsState state = e.Graphics.Save();
        e.Graphics.TranslateTransform(0, AutoScrollPosition.Y);
        e.Graphics.ScaleTransform(ScaleFactor, ScaleFactor);
        float width = (ClientSize.Width - (VerticalScroll.Visible ? SystemInformation.VerticalScrollBarWidth : 0)) / ScaleFactor;
        PaintContent(e.Graphics, width, drawButtons: false);
        e.Graphics.Restore(state);
    }

    private void PaintContent(Graphics g, float width, bool drawButtons)
    {
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
        g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
        var bounds = new RectangleF(0, 0, width, ContentHeight);
        using GraphicsPath shape = UiStyle.RoundedRectangle(bounds, 18);
        GraphicsState state = g.Save();
        g.SetClip(shape, CombineMode.Intersect);
        Color[] colors = ThemeCatalog.Shared.Gradient(AppTheme.Current);
        using (var gradient = new LinearGradientBrush(new PointF(0, 0), new PointF(width, ContentHeight), colors[0], colors[^1]))
        {
            // SwiftUI's topLeading -> bottomTrailing gradient projects onto this diagonal.
            gradient.InterpolationColors = new ColorBlend { Colors = colors,
                Positions = colors.Select((_, index) => index / (float)(colors.Length - 1)).ToArray() };
            g.FillRectangle(gradient, bounds);
        }
        using (var glass = new SolidBrush(AppTheme.Color("glassOverlay"))) g.FillRectangle(glass, bounds);
        GraphicsState waveState = g.Save();
        g.TranslateTransform(width * 1.45f, ContentHeight * 1.3f);
        g.RotateTransform(35);
        Color waveColor = AppTheme.Color("wave");
        var ellipse = new RectangleF(-width * .9f, -ContentHeight, width * 1.8f, ContentHeight * 2);
        // Layer low-opacity ellipses to soften the same broad wave used by the Mac panel.
        using (var waveFill = new SolidBrush(Color.FromArgb(Math.Max(1, waveColor.A / 8), waveColor)))
        {
            for (int layer = 0; layer < 8; layer++)
            {
                RectangleF blurred = ellipse;
                blurred.Inflate(layer * 6 - 24, layer * 6 - 24);
                g.FillEllipse(waveFill, blurred);
            }
        }
        using (var wave = new Pen(waveColor)) g.DrawEllipse(wave, ellipse);
        g.Restore(waveState);
        g.DrawImage(AppBrand.Logo(_logos), new RectangleF(18, 14, 24, 24));
        Draw(g, I18n.Get("app.name"), _name, UiStyle.Text, new RectangleF(51, 14, width - 69, 24));
        Divider(g, width, 52);
        float y = 53;
        DateTimeOffset now = _previewNow ?? DateTimeOffset.Now;
        foreach (QuotaSnapshot snapshot in _snapshots)
        {
            DrawRow(g, snapshot, width, y, now);
            y += 78;
            Divider(g, width, y - 1);
        }
        if (_snapshots.Count == 0)
        {
            Draw(g, I18n.Get("idle.title"), _small, UiStyle.Muted, new RectangleF(18, y, width - 36, 77));
            Divider(g, width, y + 77);
        }
        if (drawButtons)
        {
            float buttonWidth = (width - 42) / 2;
            PanelButton.DrawButton(g, new RectangleF(16, ContentHeight - 50, buttonWidth, 38), _settings.Text, true, false, false);
            PanelButton.DrawButton(g, new RectangleF(26 + buttonWidth, ContentHeight - 50, buttonWidth, 38), _refresh.Text, _refresh.Enabled, false, false);
        }
        g.Restore(state);
        using var border = new Pen(AppTheme.Color("panelBorder"));
        using GraphicsPath outline = UiStyle.RoundedRectangle(new RectangleF(.5f, .5f, width - 1, ContentHeight - 1), 18);
        g.DrawPath(border, outline);
    }

    private void DrawRow(Graphics g, QuotaSnapshot snapshot, float width, float y, DateTimeOffset now)
    {
        using (GraphicsPath square = UiStyle.RoundedRectangle(new RectangleF(18, y + 20, 38, 38), 10))
        using (var fill = new SolidBrush(UiStyle.Card)) g.FillPath(fill, square);
        string resource = snapshot.Provider.Id switch
        {
            "grok" => "WindowsQuotaTray.assets.logos.grok.png",
            "codex" => "WindowsQuotaTray.assets.logos.openai.png",
            _ => snapshot.Provider.LogoResource
        };
        Bitmap logo = _logos.Get(resource);
        using (var tint = new ImageAttributes())
        {
            if (snapshot.Provider.Id is "codex" or "grok")
                tint.SetColorMatrix(new ColorMatrix { Matrix00 = 0, Matrix11 = 0, Matrix22 = 0,
                    Matrix40 = UiStyle.Text.R / 255f, Matrix41 = UiStyle.Text.G / 255f, Matrix42 = UiStyle.Text.B / 255f });
            g.DrawImage(logo, new Rectangle(22, (int)y + 24, 30, 30), 0, 0, logo.Width, logo.Height, GraphicsUnit.Pixel, tint);
        }
        string? subtitle = Subtitle(snapshot);
        float top = y + (subtitle is null ? 22 : 13);
        float barWidth = Math.Max(20, width - 230);
        Draw(g, snapshot.Provider.Id == "grok" ? I18n.Get("panel.provider.grok") : snapshot.Provider.DisplayName,
            _name, UiStyle.Text, new RectangleF(68, top, barWidth, 21));
        var track = new RectangleF(68, top + 26, barWidth, 7);
        using (GraphicsPath path = UiStyle.RoundedRectangle(track, 3.5f))
        using (var fill = new SolidBrush(AppTheme.Color("barTrack"))) g.FillPath(fill, path);
        if (snapshot.RemainingPercent is double remaining && remaining > 0)
        {
            using GraphicsPath path = UiStyle.RoundedRectangle(new RectangleF(track.X, track.Y, (float)(track.Width * remaining / 100), 7), 3.5f);
            using var fill = new SolidBrush(UiStyle.QuotaColor(remaining));
            g.FillPath(fill, path);
        }
        if (subtitle is not null)
            Draw(g, subtitle, _note, AppTheme.Color(snapshot.Error is not null ? "error" :
                snapshot.IsDemo || snapshot.IsStale ? "demo" : "textSecondary"), new RectangleF(68, top + 38, barWidth, 13));
        string quota = snapshot.RemainingPercent is double percent
            ? I18n.Get("panel.quotaLeft", QuotaText.Percent(percent)) : I18n.Get("common.unknown");
        Draw(g, quota, _value, UiStyle.Text,
            new RectangleF(width - 150, y + 20, 132, 20), right: true);
        Draw(g, QuotaText.PanelReset(snapshot.MainWindow?.ResetsAt, now), _small, UiStyle.Muted,
            new RectangleF(width - 150, y + 42, 132, 16), right: true);
    }

    private static string? Subtitle(QuotaSnapshot snapshot)
    {
        if (snapshot.Error is not null)
            return (snapshot.IsDemo ? I18n.Get("demo.label") + " · " : "") + QuotaText.Error(snapshot.Error);
        if (snapshot.IsDemo) return I18n.Get("demo.label");
        if (snapshot.IsStale) return I18n.Get("panel.cache.expired");
        return snapshot.Info;
    }

    private static void Divider(Graphics g, float width, float y)
    { using var brush = new SolidBrush(AppTheme.Color("divider")); g.FillRectangle(brush, 0, y, width, 1); }

    internal Bitmap RenderFullContent()
    {
        // Exports use Mac's 1x logical size regardless of the Windows monitor's DPI or height.
        var bitmap = new Bitmap(440, ContentHeight, PixelFormat.Format32bppArgb);
        using Graphics graphics = Graphics.FromImage(bitmap);
        graphics.Clear(Color.Transparent);
        PaintContent(graphics, 440, drawButtons: true);
        return bitmap;
    }

    private static void Draw(Graphics g, string text, Font font, Color color, RectangleF bounds, bool right = false)
    {
        using var brush = new SolidBrush(color);
        using var format = new StringFormat { Alignment = right ? StringAlignment.Far : StringAlignment.Near,
            LineAlignment = StringAlignment.Center, FormatFlags = StringFormatFlags.NoWrap, Trimming = StringTrimming.EllipsisCharacter };
        g.DrawString(text, font, brush, bounds, format);
    }

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    { if (keyData == Keys.Escape) { Hide(); return true; } return base.ProcessCmdKey(ref msg, keyData); }
    protected override void OnFormClosing(FormClosingEventArgs e)
    { if (e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); } base.OnFormClosing(e); }
    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            AppTheme.Changed -= ApplyTheme;
            _name.Dispose(); _value.Dispose(); _small.Dispose(); _note.Dispose(); _tooltip.Dispose();
            Icon = null;
            _windowIcon.Dispose();
        }
        base.Dispose(disposing);
    }
}

internal sealed class PanelButton : Button
{
    private bool _pressed;
    public PanelButton()
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
            ControlStyles.SupportsTransparentBackColor, true);
        BackColor = Color.Transparent;
        FlatStyle = FlatStyle.Flat;
        FlatAppearance.BorderSize = 0;
        UseVisualStyleBackColor = false;
    }
    protected override void OnMouseDown(MouseEventArgs e) { _pressed = true; base.OnMouseDown(e); Invalidate(); }
    protected override void OnMouseUp(MouseEventArgs e) { _pressed = false; base.OnMouseUp(e); Invalidate(); }
    protected override void OnMouseLeave(EventArgs e) { _pressed = false; base.OnMouseLeave(e); Invalidate(); }
    protected override void OnPaint(PaintEventArgs e)
    {
        GraphicsState state = e.Graphics.Save();
        float scale = DeviceDpi / 96f;
        e.Graphics.ScaleTransform(scale, scale);
        DrawButton(e.Graphics, new RectangleF(0, 0, Width / scale, Height / scale), Text, Enabled, _pressed, Focused);
        e.Graphics.Restore(state);
    }
    internal static void DrawButton(Graphics g, RectangleF bounds, string text, bool enabled, bool pressed, bool focused)
    {
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
        bounds.Inflate(-.5f, -.5f);
        using GraphicsPath path = UiStyle.RoundedRectangle(bounds, 12);
        using var fill = new SolidBrush(AppTheme.Color(pressed ? "buttonBorder" : "buttonFill"));
        using var border = new Pen(AppTheme.Color(focused ? "accent" : "buttonBorder"));
        g.FillPath(fill, path); g.DrawPath(border, path);
        using var font = new Font("Segoe UI", 14, FontStyle.Bold, GraphicsUnit.Pixel);
        using var brush = new SolidBrush(enabled ? UiStyle.Text : UiStyle.Muted);
        using var format = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
        g.DrawString(text, font, brush, bounds, format);
    }
}
