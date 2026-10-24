using AISubGauge.Core;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace AISubGauge.UI;

public static class IconExport
{
    public static void Save(string directory)
    {
        Directory.CreateDirectory(directory);
        (Vendor Vendor, int Percent)[] examples = [(Vendor.Codex, 72), (Vendor.Claude, 35), (Vendor.Grok, 8)];
        foreach (bool dark in new[] { false, true })
        {
            string theme = dark ? "dark" : "light";
            var families = examples.Select(e => new TrayIconFamily(e.Vendor, e.Percent, dark)).ToArray();
            Capture.SaveTrayIconFiles(directory, theme, families, dark);
            foreach (bool showPercentage in new[] { true, false })
            {
                string mode = showPercentage ? "percent" : "no-percent";
                // Three vendors, seven native sizes, each accompanied by exact 8x pixels.
                const int cell = 540, rowHeight = 620;
                using var sheet = new Bitmap(cell * examples.Length, rowHeight * TrayIconFamily.Sizes.Count);
                using var g = Graphics.FromImage(sheet);
                g.Clear(dark ? Color.FromArgb(37, 37, 42) : Color.FromArgb(236, 236, 240));
                for (int row = 0; row < TrayIconFamily.Sizes.Count; row++) for (int col = 0; col < examples.Length; col++)
                {
                    int size = TrayIconFamily.Sizes[row];
                    var example = examples[col];
                    string name = $"{example.Vendor.ToString().ToLowerInvariant()}-{example.Percent}-{theme}-{mode}-{size}px";
                    using var native = RingIcon.TrayBitmap(example.Vendor, example.Percent, dark, size, showPercentage);
                    native.Save(Path.Combine(directory, name + ".png"), ImageFormat.Png);
                    using var enlarged = Enlarge(native, 8);
                    enlarged.Save(Path.Combine(directory, name + "-8x.png"), ImageFormat.Png);
                    UiPaint.Text(g, $"{example.Vendor} {example.Percent} / {size}px / 1x + 8x", new(col * cell + 8, row * rowHeight, cell - 16, 28), dark ? Color.White : Color.Black, 14);
                    g.DrawImageUnscaled(native, col * cell + (cell - size) / 2, row * rowHeight + 30);
                    g.DrawImageUnscaled(enlarged, col * cell + (cell - size * 8) / 2, row * rowHeight + 102);
                }
                sheet.Save(Path.Combine(directory, $"mac-compare-{theme}-{mode}.png"), ImageFormat.Png);
            }
        }
        SaveOverview(directory, examples);
        File.WriteAllText(Path.Combine(directory, "README.txt"),
            "Offline Mac v9 design-proportion comparison, not a desktop capture.\n" +
            "Codex 72 / Claude 35 / Grok 8; reviewed Windows logo masks only.\n" +
            "Native 16,20,24,32,40,48,64px and exact nearest-neighbor 8x PNGs; both percentage modes.\n" +
            "Overview: both themes, all seven native sizes, plus 32px at exact 8x.\n" +
            "Reference measurement: 180px ring diameter, 22px stroke, 54px digit ink (0.30 diameter).\n" +
            "Windows targets: stroke 0.065, digit ink 0.32; 55.5 start, -291 sweep.\n" +
            "Ring outer diameter is canvas minus 0.5px; digits sit 1px inside the top cutout.\n" +
            "Default tray ICOs, contact sheets and overview omit digits; percent/no-percent PNGs show both modes.\n" +
            "Both modes use native logo sides 13,16,19,28,35,42,55px; all logo ink stays 0.5px inside the full inner circle.\n" +
            $"Windows digit font: {MacTrayRenderer.DigitFontName}; this is not the macOS system font.\n");
    }

    private static void SaveOverview(string directory, (Vendor Vendor, int Percent)[] examples)
    {
        const int cell = 320, height = 400;
        using var sheet = new Bitmap(cell * examples.Length, height * 2);
        using var g = Graphics.FromImage(sheet);
        for (int row = 0; row < 2; row++)
        {
            bool dark = row == 1;
            using var background = new SolidBrush(dark ? Color.FromArgb(37, 37, 42) : Color.FromArgb(236, 236, 240));
            g.FillRectangle(background, 0, row * height, sheet.Width, height);
            for (int col = 0; col < examples.Length; col++)
            {
                var example = examples[col];
                UiPaint.Text(g, $"{example.Vendor} {example.Percent} / {(dark ? "dark" : "light")}",
                    new(col * cell + 10, row * height, cell - 20, 24), dark ? Color.White : Color.Black, 14, true);
                UiPaint.Text(g, "16 / 20 / 24 / 32 / 40 / 48 / 64px; below: 32px at 8x",
                    new(col * cell + 10, row * height + 24, cell - 20, 20), dark ? Color.White : Color.Black, 10);
                int x = col * cell + 10;
                foreach (int size in TrayIconFamily.Sizes)
                {
                    using var native = RingIcon.TrayBitmap(example.Vendor, example.Percent, dark, size);
                    g.DrawImageUnscaled(native, x, row * height + 112 - size);
                    x += size + 8;
                }
                using var frame = RingIcon.TrayBitmap(example.Vendor, example.Percent, dark, 32);
                using var enlarged = Enlarge(frame, 8);
                g.DrawImageUnscaled(enlarged, col * cell + 32, row * height + 132);
            }
        }
        sheet.Save(Path.Combine(directory, "mac-compare-overview.png"), ImageFormat.Png);
    }

    internal static Bitmap Enlarge(Bitmap source, int scale)
    {
        var result = new Bitmap(source.Width * scale, source.Height * scale, PixelFormat.Format32bppArgb);
        var input = source.LockBits(new Rectangle(0, 0, source.Width, source.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        var output = result.LockBits(new Rectangle(0, 0, result.Width, result.Height), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        try
        {
            var pixels = new byte[input.Stride * source.Height];
            var enlarged = new byte[output.Stride * result.Height];
            Marshal.Copy(input.Scan0, pixels, 0, pixels.Length);
            // Copy straight-alpha bytes exactly: GDI+ DrawImage rounds premultiplied channels.
            for (int y = 0; y < result.Height; y++) for (int x = 0; x < result.Width; x++)
                Buffer.BlockCopy(pixels, y / scale * input.Stride + x / scale * 4, enlarged, y * output.Stride + x * 4, 4);
            Marshal.Copy(enlarged, 0, output.Scan0, enlarged.Length);
        }
        finally { source.UnlockBits(input); result.UnlockBits(output); }
        return result;
    }
}
