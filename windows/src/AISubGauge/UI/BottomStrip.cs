using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using AISubGauge.Providers;

namespace AISubGauge.UI;

internal sealed class BottomStrip : Form
{
    private const int WsExToolWindow = 0x00000080;
    private const int WsExNoActivate = 0x08000000;
    private const int WmNcLButtonDown = 0x00A1;
    private const int HtCaption = 2;
    private readonly LogoCatalog _logos;
    private readonly Font _font = new("Segoe UI", 9, FontStyle.Bold);
    private IReadOnlyList<QuotaSnapshot> _snapshots = Array.Empty<QuotaSnapshot>();

    public BottomStrip(LogoCatalog logos, AppSettings settings)
    {
        _logos = logos;
        Text = I18n.Get("windows.quota.strip");
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        TopMost = true;
        ShowInTaskbar = false;
        AutoScaleMode = AutoScaleMode.None;
        BackColor = Color.FromArgb(30, 35, 44);
        Opacity = 0.92;
        DoubleBuffered = true;
        Cursor = Cursors.SizeAll;
        ClientSize = new Size(U(290), U(28));
        Rectangle area = (Screen.PrimaryScreen ?? Screen.AllScreens[0]).WorkingArea;
        Location = settings.StripX is int x && settings.StripY is int y
            ? new Point(x, y)
            : new Point(area.Left + 8, area.Bottom - Height - 4);
        KeepOnScreen();
        UpdateShape();
    }

    protected override bool ShowWithoutActivation => true;
    protected override CreateParams CreateParams
    {
        get
        {
            CreateParams parameters = base.CreateParams;
            parameters.ExStyle |= WsExToolWindow | WsExNoActivate;
            return parameters;
        }
    }

    private int U(float value) => (int)Math.Round(value * DeviceDpi / 96f);
    private int TextWidth(string text) => TextRenderer.MeasureText(text, _font, Size.Empty,
        TextFormatFlags.SingleLine | TextFormatFlags.NoPadding).Width;

    public void SetData(IReadOnlyList<QuotaSnapshot> snapshots)
    {
        _snapshots = snapshots.Where(snapshot => snapshot.Provider.Id is "codex" or "grok").ToArray();
        UpdateSize();
        Invalidate();
    }

    private void UpdateSize()
    {
        int width = U(20);
        if (_snapshots.Count == 0)
            width += TextWidth(I18n.Get("menu.refreshing"));
        foreach (QuotaSnapshot snapshot in _snapshots)
            width += U(22) + TextWidth(snapshot.Provider.DisplayName + " ") + TextWidth(QuotaText.Percent(snapshot.RemainingPercent));
        width += Math.Max(0, _snapshots.Count - 1) * (TextWidth(" · ") + U(4));
        if (_snapshots.Any(snapshot => snapshot.IsDemo))
            width += U(12) + TextWidth(I18n.Get("demo.label"));
        ClientSize = new Size(width, U(28));
        KeepOnScreen();
        UpdateShape();
    }

    public void KeepOnScreen()
    {
        Rectangle area = Screen.FromRectangle(Bounds).WorkingArea;
        Location = new Point(Math.Clamp(Left, area.Left, Math.Max(area.Left, area.Right - Width)),
            Math.Clamp(Top, area.Top, Math.Max(area.Top, area.Bottom - Height)));
    }

    private void UpdateShape()
    {
        if (ClientSize.Width <= 0 || ClientSize.Height <= 0)
            return;
        using GraphicsPath path = UiStyle.RoundedRectangle(new RectangleF(0, 0, Width, Height), U(7));
        Region? previous = Region;
        Region = new Region(path);
        previous?.Dispose();
    }

    protected override void OnDpiChanged(DpiChangedEventArgs e)
    {
        base.OnDpiChanged(e);
        UpdateSize();
        Invalidate();
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);
        if (e.Button != MouseButtons.Left)
            return;
        ReleaseCapture();
        SendMessage(Handle, WmNcLButtonDown, new IntPtr(HtCaption), IntPtr.Zero);
        KeepOnScreen();
        DragFinished?.Invoke(this, EventArgs.Empty);
    }

    public event EventHandler? DragFinished;

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        Graphics graphics = e.Graphics;
        graphics.SmoothingMode = SmoothingMode.AntiAlias;
        int x = U(10);
        if (_snapshots.Count == 0)
            DrawSegment(graphics, I18n.Get("menu.refreshing"), Color.Gainsboro, ref x);
        for (int index = 0; index < _snapshots.Count; index++)
        {
            if (index > 0)
            {
                DrawSegment(graphics, " · ", Color.FromArgb(150, 159, 174), ref x);
                x += U(4);
            }
            QuotaSnapshot snapshot = _snapshots[index];
            // White backing keeps the supplied black brand marks legible on the dark strip.
            var logoBounds = new Rectangle(x, (Height - U(16)) / 2, U(16), U(16));
            using (var white = new SolidBrush(Color.White))
                graphics.FillRectangle(white, logoBounds);
            graphics.DrawImage(_logos.Get(snapshot.Provider.LogoResource), logoBounds);
            x += U(22);
            DrawSegment(graphics, snapshot.Provider.DisplayName + " ", Color.FromArgb(238, 241, 247), ref x);
            DrawSegment(graphics, QuotaText.Percent(snapshot.RemainingPercent), UiStyle.QuotaColor(snapshot.RemainingPercent), ref x);
        }
        if (_snapshots.Any(snapshot => snapshot.IsDemo))
        {
            x += U(12);
            DrawSegment(graphics, I18n.Get("demo.label"), Color.FromArgb(255, 174, 83), ref x);
        }
    }

    private void DrawSegment(Graphics graphics, string text, Color color, ref int x)
    {
        int width = TextWidth(text);
        TextRenderer.DrawText(graphics, text, _font, new Rectangle(x, 0, width, Height), color,
            TextFormatFlags.SingleLine | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
        x += width;
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) _font.Dispose();
        base.Dispose(disposing);
    }

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ReleaseCapture();

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    private static extern IntPtr SendMessage(IntPtr window, int message, IntPtr wParam, IntPtr lParam);
}
