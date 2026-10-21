using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using AISubGauge.Providers;

namespace AISubGauge.UI;

internal static class TrayIconRenderer
{
    public static int CurrentSize()
    {
        // Use the primary taskbar's DPI for the notification area.
        Size small = SystemInformation.SmallIconSize;
        IntPtr taskbar = FindWindow("Shell_TrayWnd", null);
        uint dpi = taskbar == IntPtr.Zero ? 0 : GetDpiForWindow(taskbar);
        int pixels = dpi == 0 ? small.Width : GetSystemMetricsForDpi(49 /* SM_CXSMICON */, dpi);
        return Math.Clamp(pixels > 0 ? pixels : small.Width, 16, 64);
    }

    public static Bitmap Render(LogoCatalog logos, string logoResource, QuotaSnapshot? snapshot, int size)
    {
        if (logoResource.EndsWith(".grokbot-head.png", StringComparison.Ordinal))
            return RenderMaskedHead(logos, logoResource, snapshot, size);

        // Supersample the liquid edge, rounded clip and logo, then reduce to the actual tray size.
        const int scale = 4;
        using var canvas = new Bitmap(size * scale, size * scale, PixelFormat.Format32bppArgb);
        using (Graphics graphics = Graphics.FromImage(canvas))
        {
            graphics.Clear(Color.Transparent);
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
            graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
            graphics.CompositingQuality = CompositingQuality.HighQuality;
            var bounds = new RectangleF(scale * 0.5f, scale * 0.5f, (size - 1) * scale, (size - 1) * scale);
            using GraphicsPath background = UiStyle.RoundedRectangle(bounds, Math.Max(2, size / 5f) * scale);
            // Continuous fill quantised to 10% steps (rounded; any positive remainder shows at least one step).
            int lit = 0;
            if (snapshot?.RemainingPercent is double remaining)
            {
                lit = (int)Math.Round(Math.Clamp(remaining, 0, 100) / 10, MidpointRounding.AwayFromZero);
                if (remaining > 0 && lit == 0) lit = 1;
            }
            float filled = bounds.Height * lit / 10f;
            GraphicsState state = graphics.Save();
            graphics.SetClip(background);
            using (var off = new SolidBrush(Color.FromArgb(72, 58, 62, 70)))
            using (var on = new SolidBrush(UiStyle.QuotaColor(snapshot?.RemainingPercent)))
            {
                graphics.FillRectangle(off, bounds.Left, bounds.Top, bounds.Width, bounds.Height - filled);
                if (lit > 0) graphics.FillRectangle(on, bounds.Left, bounds.Bottom - filled, bounds.Width, filled);
            }
            graphics.Restore(state);

            Bitmap logo = logos.Get(logoResource);
            Rectangle ink = LogoBounds(logo);
            float padding = 0f; // v0.6.1: logo fills the whole icon (no inset).
            float fit = (size - padding) * scale / (float)Math.Max(ink.Width, ink.Height);
            var target = new RectangleF((canvas.Width - ink.Width * fit) / 2, (canvas.Height - ink.Height * fit) / 2,
                ink.Width * fit, ink.Height * fit);
            using var tint = new ImageAttributes();
            tint.SetWrapMode(WrapMode.TileFlipXY);
            tint.SetColorMatrix(new ColorMatrix { Matrix00 = 0, Matrix11 = 0, Matrix22 = 0, Matrix33 = 0.28f });
            // A subpixel dark outline keeps the white brand legible over every liquid color.
            float edge = scale * 0.35f;
            foreach (PointF offset in new[] { new PointF(-edge, -edge), new PointF(edge, -edge), new PointF(-edge, edge), new PointF(edge, edge) })
            {
                RectangleF shadow = target;
                shadow.Offset(offset);
                DrawLogo(graphics, logo, ink, shadow, tint);
            }
            if (logos.IsMonochromeDark(logoResource))
                tint.SetColorMatrix(new ColorMatrix { Matrix00 = 0, Matrix11 = 0, Matrix22 = 0, Matrix40 = 1, Matrix41 = 1, Matrix42 = 1 });
            else
                tint.ClearColorMatrix(); // Preserve every original channel of colored app/brand icons.
            DrawLogo(graphics, logo, ink, target, tint);

            // Demo state is labelled only in the tooltip and details panel; the icon carries no badge.
        }
        var bitmap = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        using (Graphics graphics = Graphics.FromImage(bitmap))
        {
            graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
            graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
            using var attributes = new ImageAttributes();
            attributes.SetWrapMode(WrapMode.TileFlipXY);
            graphics.DrawImage(canvas, new Rectangle(0, 0, size, size), 0, 0, canvas.Width, canvas.Height, GraphicsUnit.Pixel, attributes);
        }
        return bitmap;
    }

    /// <summary>
    /// Grok Bot only: the head silhouette itself is the gauge. The head fills the icon, its body is
    /// filled bottom-up in 10% steps with the quota colour, the rest is dark grey, eyes stay near-black,
    /// and nothing is drawn behind it.
    /// </summary>
    private static Bitmap RenderMaskedHead(LogoCatalog logos, string logoResource, QuotaSnapshot? snapshot, int size)
    {
        const int scale = 4;
        int big = size * scale;
        using var canvas = new Bitmap(big, big, PixelFormat.Format32bppArgb);
        Bitmap logo = logos.Get(logoResource);
        Rectangle ink = LogoBounds(logo);
        float fit = (float)(size * scale) / Math.Max(ink.Width, ink.Height);
        var target = new RectangleF((big - ink.Width * fit) / 2, (big - ink.Height * fit) / 2, ink.Width * fit, ink.Height * fit);
        using (Graphics graphics = Graphics.FromImage(canvas))
        {
            graphics.Clear(Color.Transparent);
            graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
            graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
            graphics.CompositingQuality = CompositingQuality.HighQuality;
            using var plain = new ImageAttributes();
            plain.SetWrapMode(WrapMode.TileFlipXY);
            DrawLogo(graphics, logo, ink, target, plain);
        }

        int lit = 0;
        if (snapshot?.RemainingPercent is double remaining)
        {
            lit = (int)Math.Round(Math.Clamp(remaining, 0, 100) / 10, MidpointRounding.AwayFromZero);
            if (remaining > 0 && lit == 0) lit = 1;
        }
        float fillTop = target.Bottom - target.Height * lit / 10f;
        Color on = UiStyle.QuotaColor(snapshot?.RemainingPercent);
        Color off = Color.FromArgb(96, 100, 108);
        Color eye = Color.FromArgb(18, 18, 20);

        var rect = new Rectangle(0, 0, big, big);
        BitmapData data = canvas.LockBits(rect, ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
        try
        {
            int bytes = data.Stride * big;
            byte[] px = new byte[bytes];
            Marshal.Copy(data.Scan0, px, 0, bytes);
            for (int y = 0; y < big; y++)
            {
                // Antialias the liquid line across one supersampled row.
                float cover = Math.Clamp(y + 1 - fillTop, 0f, 1f);
                Color body = Lerp(off, on, lit > 0 ? cover : 0f);
                for (int x = 0; x < big; x++)
                {
                    int i = y * data.Stride + x * 4;
                    byte a = px[i + 3];
                    if (a == 0) continue;
                    float lum = (px[i] + px[i + 1] + px[i + 2]) / 3f / 255f;
                    // Dark source pixels are the eyes; blend smoothly between eye and body colour.
                    float t = Math.Clamp((lum - 0.25f) / 0.3f, 0f, 1f);
                    Color c = Lerp(eye, body, t);
                    px[i] = c.B; px[i + 1] = c.G; px[i + 2] = c.R;
                }
            }
            Marshal.Copy(px, 0, data.Scan0, bytes);
        }
        finally { canvas.UnlockBits(data); }

        var bitmap = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        using (Graphics graphics = Graphics.FromImage(bitmap))
        {
            graphics.Clear(Color.Transparent);
            graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
            graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
            graphics.CompositingQuality = CompositingQuality.HighQuality;
            using var attributes = new ImageAttributes();
            attributes.SetWrapMode(WrapMode.TileFlipXY);
            graphics.DrawImage(canvas, new Rectangle(0, 0, size, size), 0, 0, big, big, GraphicsUnit.Pixel, attributes);
        }
        return bitmap;
    }

    private static Color Lerp(Color a, Color b, float t) => Color.FromArgb(
        (int)(a.R + (b.R - a.R) * t), (int)(a.G + (b.G - a.G) * t), (int)(a.B + (b.B - a.B) * t));

    private static Rectangle LogoBounds(Bitmap logo)
    {
        int left = logo.Width, top = logo.Height, right = 0, bottom = 0;
        for (int y = 0; y < logo.Height; y++)
        for (int x = 0; x < logo.Width; x++)
        {
            if (logo.GetPixel(x, y).A == 0)
                continue;
            left = Math.Min(left, x);
            top = Math.Min(top, y);
            right = Math.Max(right, x + 1);
            bottom = Math.Max(bottom, y + 1);
        }
        return right > left && bottom > top ? Rectangle.FromLTRB(left, top, right, bottom) : new Rectangle(0, 0, logo.Width, logo.Height);
    }

    private static void DrawLogo(Graphics graphics, Image logo, Rectangle source, RectangleF target, ImageAttributes tint)
    {
        PointF[] corners = { new(target.Left, target.Top), new(target.Right, target.Top), new(target.Left, target.Bottom) };
        graphics.DrawImage(logo, corners, source, GraphicsUnit.Pixel, tint);
    }

    public static Icon CreateIcon(LogoCatalog logos, string logoResource, QuotaSnapshot? snapshot, int size)
    {
        using Bitmap bitmap = Render(logos, logoResource, snapshot, size);
        return CreateIcon(bitmap);
    }

    internal static Bitmap RenderIdle(int size, bool? taskbarDark = null)
    {
        var bitmap = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        using var stream = SharedResources.Open(AppBrand.IdleResource(size, taskbarDark ?? AppTheme.TaskbarDark));
        using var image = new Bitmap(stream);
        using Graphics graphics = Graphics.FromImage(bitmap);
        graphics.Clear(Color.Transparent);
        graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
        if (image.Width == size && image.Height == size) graphics.DrawImageUnscaled(image, 0, 0);
        else graphics.DrawImage(image, new Rectangle(0, 0, size, size));
        return bitmap;
    }

    internal static Icon CreateIdleIcon(int size)
    {
        using Bitmap bitmap = RenderIdle(size);
        return CreateIcon(bitmap);
    }

    private static Icon CreateIcon(Bitmap bitmap)
    {
        IntPtr handle = bitmap.GetHicon();
        try
        {
            using Icon borrowed = Icon.FromHandle(handle);
            return (Icon)borrowed.Clone();
        }
        finally { DestroyIcon(handle); }
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr FindWindow(string className, string? windowName);

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr window);

    [DllImport("user32.dll")]
    private static extern int GetSystemMetricsForDpi(int index, uint dpi);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyIcon(IntPtr icon);
}
