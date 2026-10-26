using AISubGauge.Core;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace AISubGauge.UI;

public sealed class Palette(bool dark)
{
    public bool Dark { get; } = dark;
    public Color Background => ColorTranslator.FromHtml(Dark ? "#1E1E22" : "#F4F4F7");
    public Color Card => ColorTranslator.FromHtml(Dark ? "#303034" : "#FFFFFF");
    public Color Sidebar => ColorTranslator.FromHtml(Dark ? "#18181E" : "#E9E9EF");
    public Color Text => Dark ? Color.White : Color.Black;
    public Color Secondary => Dark ? Color.FromArgb(175, 175, 185) : Color.FromArgb(101, 101, 107);
    public Color Border => Dark ? Color.FromArgb(65, 65, 72) : Color.FromArgb(219, 219, 224);
    public Color Track => Dark ? Color.FromArgb(72, 72, 78) : Color.FromArgb(228, 228, 233);
    public Color Accent => ColorTranslator.FromHtml(Dark ? "#0A84FF" : "#007AFF");
}
public static class UiPaint
{
    public static GraphicsPath Round(RectangleF rect, float radius)
    {
        float d = Math.Min(radius * 2, Math.Min(rect.Width, rect.Height));
        var p = new GraphicsPath();
        if (d <= 0) { p.AddRectangle(rect); return p; }
        p.AddArc(rect.X, rect.Y, d, d, 180, 90); p.AddArc(rect.Right - d, rect.Y, d, d, 270, 90);
        p.AddArc(rect.Right - d, rect.Bottom - d, d, d, 0, 90); p.AddArc(rect.X, rect.Bottom - d, d, d, 90, 90); p.CloseFigure(); return p;
    }
    public static void Box(Graphics g, RectangleF r, Color fill, float radius = 14, Color? border = null)
    {
        using var path = Round(r, radius); using var brush = new SolidBrush(fill); g.FillPath(brush, path);
        if (border is Color color) { using var pen = new Pen(color, 0.75f); g.DrawPath(pen, path); }
    }
    public static void Text(Graphics g, string value, RectangleF rect, Color color, float pixels = 13, bool bold = false, StringAlignment alignment = StringAlignment.Near, bool wrap = false)
    {
        using var font = new Font("Microsoft YaHei UI", pixels, bold ? FontStyle.Bold : FontStyle.Regular, GraphicsUnit.Pixel);
        using var brush = new SolidBrush(color);
        using var format = new StringFormat { Alignment = alignment, LineAlignment = StringAlignment.Center, Trimming = StringTrimming.EllipsisCharacter, FormatFlags = wrap ? 0 : StringFormatFlags.NoWrap };
        g.DrawString(value, font, brush, rect, format);
    }
    public static void Bar(Graphics g, RectangleF rect, double? percent, Palette p)
    {
        Box(g, rect, p.Track, rect.Height / 2);
        if (percent is > 0) Box(g, new(rect.X, rect.Y, rect.Width * (float)Math.Clamp(percent.Value / 100, 0, 1), rect.Height), ColorTranslator.FromHtml(Presentation.Color(percent, p.Dark)), rect.Height / 2);
    }
    public static void NameAndPlan(Graphics g, string name, string plan, float x, float y, float right, Palette p)
    {
        using var nameFont = new Font("Microsoft YaHei UI", 13, FontStyle.Bold, GraphicsUnit.Pixel);
        using var planFont = new Font("Microsoft YaHei UI", 10, FontStyle.Regular, GraphicsUnit.Pixel);
        float nameWidth = g.MeasureString(name, nameFont).Width;
        float badgeX = x + nameWidth + 6;
        float badgeWidth = Math.Min(g.MeasureString(plan, planFont).Width + 10, right - badgeX);
        Text(g, name, new(x, y, nameWidth, 24), p.Text, 13, true);
        if (badgeWidth <= 10) return;
        Box(g, new(badgeX, y + 3, badgeWidth, 20), p.Track, 10);
        Text(g, plan, new(badgeX + 5, y + 3, badgeWidth - 10, 20), p.Secondary, 10);
    }
}
public static class Logos
{
    private static readonly Dictionary<(Vendor, bool, int), Bitmap> Cache = [];
    public static Bitmap Get(Vendor vendor, bool dark, int size = 128)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(size);
        if (Cache.TryGetValue((vendor, dark, size), out var cached)) return cached;
        var assembly = typeof(Logos).Assembly;
        var suffix = vendor switch { Vendor.Codex => "openai-512.png", Vendor.Claude => "claude-512.png", _ => "grok-512.png" };
        using var stream = assembly.GetManifestResourceStream(assembly.GetManifestResourceNames().Single(n => n.EndsWith(suffix, StringComparison.Ordinal)))!;
        using var original = new Bitmap(stream);
        var bitmap = size == original.Width && size == original.Height
            ? original.Clone(new Rectangle(0, 0, size, size), PixelFormat.Format32bppArgb)
            : new Bitmap(size, size, PixelFormat.Format32bppArgb);
        // Every size is downsampled directly from the reviewed 512px alpha mask.
        if (size != original.Width || size != original.Height)
        {
            using var graphics = Graphics.FromImage(bitmap);
            using var attributes = new ImageAttributes();
            graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
            graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
            graphics.CompositingQuality = CompositingQuality.HighQuality;
            attributes.SetWrapMode(WrapMode.TileFlipXY);
            graphics.DrawImage(original, new Rectangle(0, 0, size, size), 0, 0, original.Width, original.Height, GraphicsUnit.Pixel, attributes);
        }
        for (int y = 0; y < size; y++) for (int x = 0; x < size; x++)
            bitmap.SetPixel(x, y, Color.FromArgb(bitmap.GetPixel(x, y).A, dark ? Color.White : Color.Black));
        Cache.Add((vendor, dark, size), bitmap); return bitmap;
    }
    public static void Draw(Graphics g, Vendor vendor, bool dark, RectangleF bounds)
    {
        var state = g.Save();
        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        g.CompositingQuality = CompositingQuality.HighQuality;
        using var attributes = new ImageAttributes();
        attributes.SetWrapMode(WrapMode.TileFlipXY);
        using var transform = g.Transform;
        var elements = transform.Elements;
        int size = Math.Max(1, (int)Math.Ceiling(Math.Max(bounds.Width * Math.Abs(elements[0]), bounds.Height * Math.Abs(elements[3]))));
        var source = Get(vendor, dark, size);
        g.DrawImage(source, new[] { new PointF(bounds.Left, bounds.Top), new PointF(bounds.Right, bounds.Top), new PointF(bounds.Left, bounds.Bottom) },
            new RectangleF(0, 0, source.Width, source.Height), GraphicsUnit.Pixel, attributes);
        g.Restore(state);
    }
    public static void DisposeAll() { foreach (var image in Cache.Values) image.Dispose(); Cache.Clear(); }

    public static void DrawTray(Graphics g, Vendor vendor, bool dark, Rectangle bounds)
        => g.DrawImageUnscaled(Get(vendor, dark, bounds.Width), bounds.Location);
}
public static class RingIcon
{
    public static TrayIconLayout GetTrayLayout(double? percent, int size, bool showPercentage = false)
        => MacTrayRenderer.GetLayout(percent, size, showPercentage);

    public static Bitmap TrayBitmap(Vendor vendor, double? percent, bool dark, int size,
        bool showPercentage = false, TrayRenderMode mode = TrayRenderMode.Native)
        => MacTrayRenderer.Render(vendor, percent, dark, size, showPercentage, mode);
    public static void Draw(Graphics g, RectangleF bounds, Vendor vendor, double? percent, bool dark)
    {
        var state = g.Save(); g.TranslateTransform(bounds.X, bounds.Y); g.ScaleTransform(bounds.Width / 64, bounds.Height / 64);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using var track = new Pen(dark ? Color.FromArgb(100, 100, 108) : Color.FromArgb(178, 178, 184), 6) { StartCap = LineCap.Round, EndCap = LineCap.Round };
        using var fill = new Pen(ColorTranslator.FromHtml(Presentation.Color(percent, dark)), 6) { StartCap = LineCap.Round, EndCap = LineCap.Round };
        // Menubar-v9: bottom opening, top number cut-out, centered monochrome brand.
        var arcState = g.Save(); g.ExcludeClip(new Rectangle(16, 0, 32, 17));
        g.DrawArc(track, 6, 7, 52, 52, 55, -290);
        if (percent is > 0) g.DrawArc(fill, 6, 7, 52, 52, 55, -290 * (float)Math.Clamp(percent.Value / 100, 0, 1));
        g.Restore(arcState);
        Logos.Draw(g, vendor, dark, new RectangleF(20, 24, 24, 24));
        UiPaint.Text(g, Presentation.Percent(percent).Replace("%", ""), new(8, -1, 48, 21), dark ? Color.White : Color.Black, 21, true, StringAlignment.Center);
        g.Restore(state);
    }
    public static Bitmap Bitmap(Vendor vendor, double? percent, bool dark, int size = 32)
    {
        var result = new Bitmap(size, size, PixelFormat.Format32bppArgb); using var g = Graphics.FromImage(result); g.Clear(Color.Transparent);
        Draw(g, new(0, 0, size, size), vendor, percent, dark); return result;
    }
    public static Icon Icon(Bitmap bitmap)
    {
        var handle = bitmap.GetHicon(); try { using var temporary = System.Drawing.Icon.FromHandle(handle); return (Icon)temporary.Clone(); } finally { DestroyIcon(handle); }
    }
    [DllImport("user32.dll")] private static extern bool DestroyIcon(IntPtr icon);
}
internal static class TrayIconMetrics
{
    internal static int SmallIconSize()
        => Read().Size;
    internal static (uint Dpi, int Size) Read()
    {
        var taskbar = FindWindow("Shell_TrayWnd", null);
        uint dpi = taskbar == IntPtr.Zero ? GetDpiForSystem() : GetDpiForWindow(taskbar);
        dpi = dpi == 0 ? 96u : dpi;
        return (dpi, SmallIconSize(dpi, GetSystemMetricsForDpi));
    }
    internal static int SmallIconSize(uint dpi, Func<int, uint, int> metric)
    {
        dpi = dpi == 0 ? 96u : dpi;
        int size = metric(49 /* SM_CXSMICON */, dpi);
        return size > 0 ? size : Math.Max(16, (int)Math.Round(16d * dpi / 96));
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr FindWindow(string name, string? title);
    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(IntPtr window);
    [DllImport("user32.dll")] private static extern uint GetDpiForSystem();
    [DllImport("user32.dll")] private static extern int GetSystemMetricsForDpi(int index, uint dpi);
}
public sealed class PillButton : Button
{
    public Palette Palette { get; set; } = new(false);
    public bool Primary { get; set; }
    public PillButton() { FlatStyle = FlatStyle.Flat; FlatAppearance.BorderSize = 0; Cursor = Cursors.Hand; SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true); }
    protected override void OnPaintBackground(PaintEventArgs e) => e.Graphics.Clear(BackColor);
    protected override void OnPaint(PaintEventArgs e)
    {
        e.Graphics.Clear(BackColor);
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        UiPaint.Box(e.Graphics, new(1, 1, Width - 2, Height - 2), Primary ? Palette.Accent : Palette.Card, Height / 2, Palette.Border);
        UiPaint.Text(e.Graphics, Text, new(3, 0, Width - 6, Height), Primary ? Color.White : Palette.Text, 12 * DeviceDpi / 96f, alignment: StringAlignment.Center);
        if (Focused && ShowFocusCues) { using var path = UiPaint.Round(new(2, 2, Width - 4, Height - 4), Height / 2); using var pen = new Pen(Palette.Accent); e.Graphics.DrawPath(pen, path); }
    }
}
public sealed class Toggle : CheckBox
{
    public bool Error { get; set; }
    public Palette Palette { get; set; } = new(false);
    public Toggle() { Appearance = Appearance.Button; FlatStyle = FlatStyle.Flat; Cursor = Cursors.Hand; SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true); }
    protected override void OnPaintBackground(PaintEventArgs e) => e.Graphics.Clear(BackColor);
    protected override void OnPaint(PaintEventArgs e)
    {
        e.Graphics.Clear(BackColor);
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        UiPaint.Box(e.Graphics, new(1, 1, Width - 2, Height - 2), Error ? ColorTranslator.FromHtml(Presentation.Color(10, Palette.Dark)) : Checked ? ColorTranslator.FromHtml(Presentation.Color(100, Palette.Dark)) : Palette.Track, Height / 2);
        using var white = new SolidBrush(Color.White); float diameter = Height - 6;
        e.Graphics.FillEllipse(white, Checked ? Width - diameter - 3 : 3, 3, diameter, diameter);
        if (Focused && ShowFocusCues) { using var path = UiPaint.Round(new(1, 1, Width - 2, Height - 2), Height / 2); using var pen = new Pen(Palette.Accent); e.Graphics.DrawPath(pen, path); }
    }
}


