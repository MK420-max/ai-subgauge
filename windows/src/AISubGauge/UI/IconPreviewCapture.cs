using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.IO;
using System.Linq;
using AISubGauge.Providers;

namespace AISubGauge.UI;

internal static class IconPreviewCapture
{
    public static void Save(string directory, LogoCatalog logos)
    {
        Directory.CreateDirectory(directory);
        IQuotaProvider[] providers = ProviderRegistry.CreateEnabled().ToArray();
        int[] percentages = { 85, 40, 10 };
        int[] sizes = { 16, 20, 24, 32 };
        const int zoom = 8, labelWidth = 128, cellSize = 288, headerHeight = 40;
        using var montage = new Bitmap(labelWidth + sizes.Length * cellSize + 16,
            headerHeight + providers.Length * percentages.Length * cellSize + 16, PixelFormat.Format32bppArgb);
        using (Graphics graphics = Graphics.FromImage(montage))
        using (var font = new Font("Segoe UI", 12, FontStyle.Regular, GraphicsUnit.Pixel))
        {
            graphics.Clear(Color.FromArgb(32, 32, 32));
            graphics.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
            graphics.InterpolationMode = InterpolationMode.NearestNeighbor;
            graphics.PixelOffsetMode = PixelOffsetMode.Half;
            for (int column = 0; column < sizes.Length; column++)
                graphics.DrawString(I18n.Get("windows.icon.dimensions", sizes[column]), font, Brushes.White, labelWidth + column * cellSize + 16, 12);
            int row = 0;
            foreach (IQuotaProvider provider in providers)
            foreach (int percentage in percentages)
            {
                QuotaSnapshot snapshot = Sample(provider, percentage);
                int top = headerHeight + row * cellSize;
                graphics.DrawString($"{provider.DisplayName} {percentage}%", font, Brushes.White, 16, top + cellSize / 2 - 16);
                graphics.DrawString(I18n.Get("demo.label"), font, Brushes.LightGray, 16, top + cellSize / 2 + 4);
                for (int column = 0; column < sizes.Length; column++)
                {
                    int size = sizes[column];
                    using Bitmap original = TrayIconRenderer.Render(logos, provider.LogoResource, snapshot, size);
                    original.Save(Path.Combine(directory, $"{provider.Id}-{percentage}-{size}.png"), ImageFormat.Png);
                    var target = new Rectangle(labelWidth + column * cellSize + (cellSize - size * zoom) / 2,
                        top + (cellSize - size * zoom) / 2, size * zoom, size * zoom);
                    graphics.DrawImage(original, target, 0, 0, size, size, GraphicsUnit.Pixel);
                }
                row++;
            }
        }
        montage.Save(Path.Combine(directory, "preview-zoom.png"), ImageFormat.Png);
        SaveTaskbar(Path.Combine(directory, "taskbar-mock.png"), logos, providers);
    }

    private static QuotaSnapshot Sample(IQuotaProvider provider, int percentage) => new()
    {
        Provider = provider,
        Plan = I18n.Get("windows.icon.preview"),
        IsDemo = true,
        Windows = new() { new() { Id = "preview", Title = I18n.Get("windows.preview"), RemainingPercent = percentage } }
    };

    private static void SaveTaskbar(string path, LogoCatalog logos, IQuotaProvider[] providers)
    {
        using var bitmap = new Bitmap(640, 48, PixelFormat.Format32bppArgb);
        using (Graphics graphics = Graphics.FromImage(bitmap))
        using (var pen = new Pen(Color.FromArgb(238, 238, 238), 1.25f) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round })
        using (var separator = new Pen(Color.FromArgb(64, 64, 64)))
        using (var font = new Font("Segoe UI", 11, FontStyle.Regular, GraphicsUnit.Pixel))
        using (var format = new StringFormat { Alignment = StringAlignment.Far })
        {
            graphics.Clear(Color.FromArgb(32, 32, 32));
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            graphics.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
            graphics.DrawLines(pen, new[] { new PointF(12, 26), new PointF(16, 22), new PointF(20, 26) });

            // Codex, Claude, Grok Bot and Gemini at native 100% / 150% taskbar sizes.
            for (int index = 0; index < 4; index++)
            {
                DrawTraySample(graphics, logos, providers[index], index % 2 == 0 ? 85 : 40, 16, 36 + index * 28);
                DrawTraySample(graphics, logos, providers[index], index % 2 == 0 ? 40 : 10, 24, 164 + index * 36);
            }
            graphics.DrawLine(separator, 150, 10, 150, 38);
            graphics.DrawLine(separator, 312, 10, 312, 38);

            graphics.TranslateTransform(140, 0);

            graphics.DrawArc(pen, 186, 18, 20, 18, 225, 90);
            graphics.DrawArc(pen, 190, 22, 12, 10, 225, 90);
            graphics.FillEllipse(Brushes.White, 195, 29, 2, 2);
            graphics.FillPolygon(Brushes.White, new[]
            {
                new Point(216, 22), new Point(219, 22), new Point(223, 18),
                new Point(223, 30), new Point(219, 26), new Point(216, 26)
            });
            graphics.DrawArc(pen, 222, 19, 8, 10, -55, 110);
            graphics.DrawArc(pen, 220, 16, 16, 16, -50, 100);
            graphics.DrawRectangle(pen, 247, 19, 23, 11);
            graphics.FillRectangle(Brushes.White, 249, 21, 14, 7);
            graphics.FillRectangle(Brushes.White, 271, 22, 2, 5);
            graphics.DrawString(I18n.Get("windows.preview.clock"), font, Brushes.White, new RectangleF(284, 7, 104, 16), format);
            graphics.DrawString(I18n.Get("windows.preview.date"), font, Brushes.White, new RectangleF(284, 25, 104, 16), format);
        }
        bitmap.Save(path, ImageFormat.Png);
    }

    private static void DrawTraySample(Graphics graphics, LogoCatalog logos, IQuotaProvider provider, int percentage, int size, int x)
    {
        using Bitmap icon = TrayIconRenderer.Render(logos, provider.LogoResource, Sample(provider, percentage), size);
        graphics.DrawImageUnscaled(icon, x, (48 - size) / 2);
    }
}
