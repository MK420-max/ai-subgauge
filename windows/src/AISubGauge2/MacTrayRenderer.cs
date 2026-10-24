using AISubGauge.Core;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Globalization;
using System.Runtime.InteropServices;

namespace AISubGauge.UI;

// Mac menubar-v9 composition in 22 units: bottom opening, heavy arc-top digits
// and a transparent cutout. The thinner Windows ring leaves room for the brand.
public static class MenuArcMetrics
{
    public const float SegmentSize = 22, Scale = SegmentSize / 18;
    public const float LineWidth = SegmentSize * .065f, Radius = (SegmentSize - LineWidth) / 2;
    public const float ArcStart = 55.5f, ArcSweep = 291;
    public const float DigitInkRatio = .32f;
    public const float DigitKerning = -.3f * Scale;
    public const float DigitCutoutPadding = .9f * Scale, DigitCutoutCornerRatio = .3f;
    public const float DigitKnockoutPadding = .35f, LogoClearance = .5f;
    public const float TrackOpacity = .3f;
    // Device-pixel AA margin, independent of DPI. Digits sit inside the top cutout.
    public const float OuterMargin = .25f;
}

public enum TrayRenderMode { Native, Reference }

public readonly record struct TrayIconLayout(RectangleF RingBounds, float RingStroke,
    RectangleF NumberBounds, Rectangle LogoBounds, float NumberOutlineWidth,
    RectangleF DigitCutout, float Baseline, float FontSize,
    float LogoClearance = MenuArcMetrics.LogoClearance);

internal static class MacTrayRenderer
{
    internal static string DigitFontName { get; } = ChooseFont();
    private static string ChooseFont()
    {
        using var fonts = new System.Drawing.Text.InstalledFontCollection();
        var families = fonts.Families;
        try { return families.Any(f => f.Name == "Segoe UI Black") ? "Segoe UI Black" : "Segoe UI"; }
        finally { foreach (var family in families) family.Dispose(); }
    }

    internal static TrayIconLayout GetLayout(double? percent, int size, bool showPercentage)
    {
        using var digits = NumberPath(percent, size, showPercentage, out var layout);
        return layout;
    }

    private static double? Quota(double? value)
        => value is double n && double.IsFinite(n) ? Math.Clamp(n, 0, 100) : null;

    private static float PixelScale(int size) => (size - 2 * MenuArcMetrics.OuterMargin) / MenuArcMetrics.SegmentSize;

    // Native base sizes, enlarged below for both percentage modes. The circular
    // containment mask keeps every ink pixel clear of the ring and bottom opening.
    private static int LogoSide(int size) => size switch
    {
        16 => 12, 20 => 15, 24 => 18, 32 => 26, 40 => 32, 48 => 39, 64 => 51,
        _ => (int)MathF.Round(size * .80f)
    };

    private static RectangleF RingBounds(int size)
    {
        float px = PixelScale(size), diameter = MenuArcMetrics.SegmentSize * px, stroke = MenuArcMetrics.LineWidth * px;
        return new((size - diameter + stroke) / 2, (size - diameter + stroke) / 2,
            diameter - stroke, diameter - stroke);
    }

    private static GraphicsPath NumberPath(double? value, int size, bool showPercentage, out TrayIconLayout layout)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(size, 16);
        double? quota = Quota(value);
        bool hasNumber = showPercentage && quota.HasValue;
        float px = PixelScale(size), diameter = MenuArcMetrics.SegmentSize * px;
        float stroke = MenuArcMetrics.LineWidth * px;
        int side = LogoSide(size);
        // Use the larger ring-only logo in both modes; digits overlay it.
        side = (int)MathF.Round(side * 1.08f);
        var ring = RingBounds(size);
        float centerY = ring.Top + ring.Height / 2;
        var logo = new Rectangle((int)MathF.Round((size - side) / 2f), (int)MathF.Round(centerY - side / 2f), side, side);
        var digits = new GraphicsPath();
        layout = new(ring, stroke, RectangleF.Empty, logo, MenuArcMetrics.DigitKnockoutPadding * px,
            RectangleF.Empty, 0, 0);
        if (!hasNumber) return digits;

        using var family = new FontFamily(DigitFontName);
        FontStyle style = DigitFontName == "Segoe UI Black" ? FontStyle.Regular : FontStyle.Bold;
        using var format = (StringFormat)StringFormat.GenericTypographic.Clone();
        format.FormatFlags |= StringFormatFlags.NoWrap;
        string text = Math.Round(quota!.Value, MidpointRounding.AwayFromZero).ToString(CultureInfo.InvariantCulture);
        // Match INK height, not the font em size. Snap cap height and baseline to
        // device pixels; measuring at a large em avoids GDI+'s small-em rounding.
        const float measureEm = 100;
        using var probe = new GraphicsPath();
        probe.AddString(text, family, (int)style, measureEm, PointF.Empty, format);
        var cap = probe.GetBounds();
        float inkHeight = MathF.Round(MenuArcMetrics.DigitInkRatio * diameter);
        float fontSize = measureEm * inkHeight / cap.Height;
        float glyphScale = fontSize / measureEm;
        // Lay out tabular digits explicitly; GDI+ does not expose CoreText's feature settings.
        using var font = new Font(family, measureEm, style, GraphicsUnit.Pixel);
        using var measure = new Bitmap(1, 1);
        using var graphics = Graphics.FromImage(measure);
        float advance = graphics.MeasureString("0", font, PointF.Empty, format).Width;
        for (int i = 0; i < text.Length; i++)
            digits.AddString(text[i].ToString(), family, (int)style, measureEm,
                new PointF(i * (advance + MenuArcMetrics.DigitKerning * px / glyphScale), 0), format);
        using (var scale = new Matrix()) { scale.Scale(glyphScale, glyphScale); digits.Transform(scale); }
        var ink = digits.GetBounds();
        // Normalize each label's actual ink (flat-topped 4 is shorter than curved 8)
        // to the same pixel cap height, retaining tabular advances within the label.
        float baseline = inkHeight + 1;
        using var position = new Matrix();
        float x = size / 2f - (ink.Left + ink.Right) / 2;
        if (size <= 20) x = MathF.Round(x + ink.Left) - ink.Left;
        position.Translate(x, baseline - ink.Bottom);
        digits.Transform(position);
        ink = digits.GetBounds();
        float width = ink.Width + 2 * MenuArcMetrics.DigitCutoutPadding * px;
        var cutout = new RectangleF((size - width) / 2, (ink.Top + ink.Bottom - fontSize) / 2, width, fontSize);
        layout = layout with { NumberBounds = ink, DigitCutout = cutout, Baseline = baseline, FontSize = fontSize };
        return digits;
    }

    internal static GraphicsPath ArcPath(int size, double percent = 100, bool hasNumber = true)
    {
        var path = new GraphicsPath();
        if (percent <= 0) return path;
        var rect = RingBounds(size);
        double angle = MenuArcMetrics.ArcStart, finish = angle - MenuArcMetrics.ArcSweep * percent / 100;
        // Split at the axes as in QuotaArc.path: no cubic overshoot outside the canvas.
        while (angle > finish)
        {
            double next = Math.Max(finish, (Math.Ceiling(angle / 90) - 1) * 90);
            path.AddArc(rect, (float)angle, (float)(next - angle));
            angle = next;
        }
        return path;
    }

    private static Bitmap Mask(int size, Action<Graphics> draw)
    {
        // Each target size gets its own geometry, baseline and exact native logo raster.
        // Supersampling only integrates vector edge coverage; no master icon is resized.
        const int samples = 4;
        using var high = new Bitmap(size * samples, size * samples, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(high))
        {
            g.PixelOffsetMode = PixelOffsetMode.Half;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.ScaleTransform(samples, samples);
            draw(g);
        }
        var result = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        var data = high.LockBits(new Rectangle(0, 0, high.Width, high.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        byte[] pixels = new byte[data.Stride * data.Height];
        try { Marshal.Copy(data.Scan0, pixels, 0, pixels.Length); }
        finally { high.UnlockBits(data); }
        for (int y = 0; y < size; y++) for (int x = 0; x < size; x++)
        {
            int alpha = 0;
            for (int j = 0; j < samples; j++) for (int i = 0; i < samples; i++)
                alpha += pixels[(y * samples + j) * data.Stride + (x * samples + i) * 4 + 3];
            result.SetPixel(x, y, Color.FromArgb((alpha + 8) / 16, Color.White));
        }
        return result;
    }

    internal static Bitmap NumberMask(double? percent, int size, bool showPercentage = true)
    {
        using var digits = NumberPath(percent, size, showPercentage, out _);
        return NumberMask(size, digits);
    }

    private static Bitmap NumberMask(int size, GraphicsPath digits)
        => Mask(size, g => { if (digits.PointCount > 0) g.FillPath(Brushes.White, digits); });

    internal static Bitmap NumberKnockoutMask(double? percent, int size, bool showPercentage = true)
    {
        using var digits = NumberPath(percent, size, showPercentage, out var layout);
        return NumberKnockoutMask(size, digits, layout.NumberOutlineWidth);
    }

    private static Bitmap NumberKnockoutMask(int size, GraphicsPath digits, float outline)
        => Mask(size, g =>
        {
            if (digits.PointCount == 0) return;
            using var pen = new Pen(Color.White, 2 * outline) { LineJoin = LineJoin.Round };
            g.FillPath(Brushes.White, digits); g.DrawPath(pen, digits);
        });

    private static Bitmap ArcMask(int size, double percent, float width, bool hasNumber, TrayRenderMode mode)
    {
        if (mode == TrayRenderMode.Reference) return ReferenceArcMask(size, percent, width, hasNumber);
        return Mask(size, g =>
        {
            if (percent <= 0) return;
            using var path = ArcPath(size, percent, hasNumber);
            using var pen = new Pen(Color.White, width) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round };
            g.DrawPath(pen, path);
        });
    }

    // Independent analytical reference: sample distance to a circular arc and its round caps.
    // This deliberately does not use GraphicsPath/AddArc, so tests detect direction/curve regressions.
    private static Bitmap ReferenceArcMask(int size, double percent, float width, bool hasNumber)
    {
        var result = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        if (percent <= 0) return result;
        const int samples = 8;
        double px = PixelScale(size), radius = MenuArcMetrics.Radius * px;
        double centerY = size / 2d;
        double start = MenuArcMetrics.ArcStart * Math.PI / 180, sweep = MenuArcMetrics.ArcSweep * percent / 100 * Math.PI / 180;
        double end = start - sweep, sx = radius * Math.Cos(start), sy = radius * Math.Sin(start);
        double ex = radius * Math.Cos(end), ey = radius * Math.Sin(end), halfSquared = width * width / 4;
        for (int y = 0; y < size; y++) for (int x = 0; x < size; x++)
        {
            int hits = 0;
            for (int j = 0; j < samples; j++) for (int i = 0; i < samples; i++)
            {
                double dx = x + (i + .5) / samples - size / 2d, dy = y + (j + .5) / samples - centerY;
                double angle = (start - Math.Atan2(dy, dx) + 2 * Math.PI) % (2 * Math.PI);
                double distance = Math.Sqrt(dx * dx + dy * dy) - radius;
                double squared = angle <= sweep ? distance * distance :
                    Math.Min((dx - sx) * (dx - sx) + (dy - sy) * (dy - sy), (dx - ex) * (dx - ex) + (dy - ey) * (dy - ey));
                if (squared <= halfSquared) hits++;
            }
            result.SetPixel(x, y, Color.FromArgb((hits * 255 + 32) / 64, Color.White));
        }
        return result;
    }

    internal static Bitmap Render(Vendor vendor, double? value, bool dark, int size, bool showPercentage, TrayRenderMode mode)
    {
        double? quota = Quota(value);
        using var digits = NumberPath(quota, size, showPercentage, out var layout);
        bool hasNumber = !layout.NumberBounds.IsEmpty;
        using var track = ArcMask(size, 100, layout.RingStroke, hasNumber, mode);
        using var fill = ArcMask(size, quota ?? 0, layout.RingStroke, hasNumber, mode);
        using var cutout = Mask(size, g =>
        {
            if (layout.DigitCutout.IsEmpty) return;
            using var path = UiPaint.Round(layout.DigitCutout, layout.FontSize * MenuArcMetrics.DigitCutoutCornerRatio);
            g.FillPath(Brushes.White, path);
        });
        using var logo = LogoMask(vendor, size, layout);
        using var knockout = NumberKnockoutMask(size, digits, layout.NumberOutlineWidth);
        using var number = NumberMask(size, digits);
        Color foreground = dark ? Color.White : Color.Black;
        Color color = ColorTranslator.FromHtml(Presentation.Color(quota, dark));
        var result = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        for (int y = 0; y < size; y++) for (int x = 0; x < size; x++)
        {
            float alpha = track.GetPixel(x, y).A / 255f * MenuArcMetrics.TrackOpacity;
            float r = foreground.R * alpha, green = foreground.G * alpha, b = foreground.B * alpha;
            void Over(Color ink, float a)
            {
                r = ink.R * a + r * (1 - a); green = ink.G * a + green * (1 - a); b = ink.B * a + b * (1 - a);
                alpha = a + alpha * (1 - a);
            }
            void DestinationOut(float a) { alpha *= 1 - a; r *= 1 - a; green *= 1 - a; b *= 1 - a; }
            Over(color, fill.GetPixel(x, y).A / 255f);
            DestinationOut(cutout.GetPixel(x, y).A / 255f); // Only arcs are cut out.
            Over(foreground, logo.GetPixel(x, y).A / 255f);
            DestinationOut(knockout.GetPixel(x, y).A / 255f); // Transparent glyph moat, never a background-colored halo.
            Over(foreground, number.GetPixel(x, y).A / 255f);
            int Byte(float v) => Math.Clamp((int)Math.Round(v), 0, 255);
            result.SetPixel(x, y, alpha <= 0 ? Color.Transparent : Color.FromArgb(Byte(alpha * 255), Byte(r / alpha), Byte(green / alpha), Byte(b / alpha)));
        }
        return result;
    }

    internal static Bitmap LogoMask(Vendor vendor, int size, TrayIconLayout layout)
    {
        var source = Logos.Get(vendor, true, layout.LogoBounds.Width);
        var result = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        float cx = layout.RingBounds.Left + layout.RingBounds.Width / 2;
        float cy = layout.RingBounds.Top + layout.RingBounds.Height / 2;
        float radius = (layout.RingBounds.Width - layout.RingStroke) / 2 - layout.LogoClearance;
        for (int y = 0; y < size; y++) for (int x = 0; x < size; x++)
        {
            if (!layout.LogoBounds.Contains(x, y)) continue;
            // Contain the entire pixel footprint in the full inner circle, including
            // the bottom opening and digit cutout. An arc-only moat lets Grok escape.
            float dx = Math.Abs(x + .5f - cx) + .5f, dy = Math.Abs(y + .5f - cy) + .5f;
            float coverage = Math.Clamp((radius - MathF.Sqrt(dx * dx + dy * dy)) * 2, 0, 1);
            int alpha = (int)MathF.Round(source.GetPixel(x - layout.LogoBounds.X, y - layout.LogoBounds.Y).A * coverage);
            result.SetPixel(x, y, Color.FromArgb(alpha, Color.White));
        }
        return result;
    }
}
