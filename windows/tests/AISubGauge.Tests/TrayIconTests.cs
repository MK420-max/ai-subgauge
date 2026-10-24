using AISubGauge.Core;
using AISubGauge.UI;
using System.Drawing;
using System.Runtime.InteropServices;

internal static partial class Program
{
    private static readonly int[] RequiredIconSizes = [16, 20, 24, 32, 40, 48, 64];
    private static readonly int[] RequiredAppIconSizes = [16, 20, 24, 32, 40, 48, 64, 256];

    private static void RunTrayIconTests()
    {
        Test("v9 full-canvas ring, nonregressing logo proportions and inset arc-top digits", () =>
        {
            Equal(MenuArcMetrics.ArcStart, 55.5f); Equal(MenuArcMetrics.ArcSweep, 291f);
            foreach (int size in RequiredIconSizes.Concat(new[] { 22 }))
            foreach (bool show in new[] { true, false })
            foreach (double? percent in Enumerable.Range(0, 101).Select(n => (double?)n)
                .Concat(new double?[] { null, -1, 101, double.NaN, double.NegativeInfinity, double.PositiveInfinity }))
            {
                var layout = RingIcon.GetTrayLayout(percent, size, show);
                try
                {
                    bool hasNumber = show && percent is double n && double.IsFinite(n);
                    float diameter = layout.RingBounds.Width + layout.RingStroke, px = diameter / 22;
                    float logoRatio = layout.LogoBounds.Width / diameter;
                    float minimum = size switch { <= 24 => .763f, 32 => .795f, 40 => .789f, 48 => .806f, 64 => .795f, _ => .763f };
                    Check(logoRatio >= minimum);
                    Check(diameter / size >= .94f);
                    Check(layout.LogoBounds.Width == layout.LogoBounds.Height);
                    Check(layout.LogoBounds.Left >= 0 && layout.LogoBounds.Right <= size);
                    Check(layout.LogoBounds.Top >= 0 && layout.LogoBounds.Bottom < size);
                    // Both modes use enlarged artwork clipped to the full inner circle.
                    Check(layout.LogoBounds.Width / (diameter - 2 * layout.RingStroke) >= .85f);
                    Check(Math.Abs(layout.LogoBounds.Left + layout.LogoBounds.Width / 2f - size / 2f) <= .5f);
                    Check(Math.Abs(layout.LogoBounds.Top + layout.LogoBounds.Height / 2f -
                        (layout.RingBounds.Top + layout.RingBounds.Height / 2)) <= .5f);
                    Check(layout.RingStroke / diameter is >= .05f and <= .08f);
                    Check(Math.Abs(layout.RingBounds.Left + layout.RingBounds.Right - size) < .0001);
                    Check(layout.RingBounds.Left - layout.RingStroke / 2 <= 1);
                    Equal(layout.NumberBounds.IsEmpty, !hasNumber);
                    Equal(layout.DigitCutout.IsEmpty, !hasNumber);
                    if (!hasNumber) continue;
                    float digitRatio = layout.NumberBounds.Height / diameter;
                    Check(digitRatio is >= .30f and <= .38f);
                    // Only a quarter-pixel AA margin surrounds the centered ring.
                    Check(Math.Abs(diameter - (size - .5f)) < .001);
                    Check(Math.Abs(layout.RingBounds.Top - layout.RingStroke / 2 - .25f) < .001);
                    Equal(layout.Baseline, MathF.Ceiling(layout.Baseline));
                    Check(layout.NumberBounds.Top >= .999f && layout.NumberBounds.Top <= 1.001f);
                    Check(layout.NumberBounds.Left >= 1 && layout.NumberBounds.Right <= size - 1);
                    Check(layout.NumberBounds.Bottom <= size - 1);
                    Check(Math.Abs(layout.DigitCutout.Height - layout.FontSize) < .001);
                    Check(Math.Abs(layout.DigitCutout.Width - layout.NumberBounds.Width - 2 * .9f * (22f / 18) * px) < .001);
                    Check(Math.Abs(layout.NumberOutlineWidth - .35f * px) < .001);
                }
                catch
                {
                    Console.WriteLine($"Layout {size}px / {percent} / show={show}: {layout}");
                    throw;
                }
            }
            Throws(() => RingIcon.GetTrayLayout(72, 0));
        });
        Test("all logo ink including Grok slash stays wholly inside the inner circle and off canvas edges", () =>
        {
            foreach (int size in RequiredIconSizes) foreach (var vendor in Enum.GetValues<Vendor>())
            foreach (bool dark in new[] { false, true }) foreach (bool show in new[] { false, true })
            foreach (double? percent in new double?[] { null, 0, 8, 35, 72, 100 })
            {
                var layout = RingIcon.GetTrayLayout(percent, size, show);
                using var logo = MacTrayRenderer.LogoMask(vendor, size, layout);
                using var number = MacTrayRenderer.NumberMask(percent, size, show);
                using var frame = RingIcon.TrayBitmap(vendor, percent, dark, size, show);
                using var otherVendor = RingIcon.TrayBitmap(vendor == Vendor.Codex ? Vendor.Grok : Vendor.Codex, percent, dark, size, show);
                double cx = layout.RingBounds.Left + layout.RingBounds.Width / 2;
                double cy = layout.RingBounds.Top + layout.RingBounds.Height / 2;
                double inner = (layout.RingBounds.Width - layout.RingStroke) / 2;
                bool ink = false;
                for (int y = 0; y < size; y++) for (int x = 0; x < size; x++)
                {
                    if (logo.GetPixel(x, y).A > 0)
                    {
                        ink = true;
                        double dx = Math.Abs(x + .5 - cx) + .5, dy = Math.Abs(y + .5 - cy) + .5;
                        if (dx * dx + dy * dy > inner * inner)
                            throw new Exception($"Logo outside inner circle: {vendor} {size}px at {x},{y}");
                        if (!(x > 0 && y > 0 && x < size - 1 && y < size - 1))
                        { Console.WriteLine($"Logo touches edge: {vendor} {size}px {x},{y}"); Check(false); }
                    }
                    if (x != 0 && y != 0 && x != size - 1 && y != size - 1) continue;
                    if (number.GetPixel(x, y).A != 0)
                    { Console.WriteLine($"Digit touches edge: {percent} {size}px {x},{y} alpha={number.GetPixel(x, y).A}"); Check(false); }
                    // Neither foreground mask touches the edge; only the shared ring
                    // and its cutout remain, identical across brands in the final raster.
                    Equal(frame.GetPixel(x, y).ToArgb(), otherVendor.GetPixel(x, y).ToArgb());
                }
                Check(ink);
            }
        });
        Test("digit-shown output preserves contained logo ink outside the digit knockout", () =>
        {
            bool preserved = true;
            foreach (int size in RequiredIconSizes) foreach (var vendor in Enum.GetValues<Vendor>())
            foreach (bool dark in new[] { false, true }) foreach (bool show in new[] { true })
            {
                var layout = RingIcon.GetTrayLayout(100, size, show);
                var source = Logos.Get(vendor, dark, layout.LogoBounds.Width);
                using var frame = RingIcon.TrayBitmap(vendor, 100, dark, size, show);
                using var number = MacTrayRenderer.NumberMask(100, size, show);
                using var knockout = MacTrayRenderer.NumberKnockoutMask(100, size, show);
                using var contained = MacTrayRenderer.LogoMask(vendor, size, layout);
                var ringColor = ColorTranslator.FromHtml(Presentation.Color(100, dark));
                double originalInk = 0, visibleInk = 0, fullSourceInk = 0, containedInk = 0;
                for (int y = 0; y < source.Height; y++) for (int x = 0; x < source.Width; x++)
                {
                    double sourceAlpha = source.GetPixel(x, y).A / 255d;
                    int fx = layout.LogoBounds.X + x, fy = layout.LogoBounds.Y + y;
                    fullSourceInk += sourceAlpha;
                    containedInk += contained.GetPixel(fx, fy).A / 255d;
                    // Moving the digits inside the ring intentionally obscures more
                    // of the logo. Compare against the enlarged, contained artwork;
                    // only the explicit glyph knockout is exempt from visibility.
                    double available = contained.GetPixel(fx, fy).A / 255d * (1 - knockout.GetPixel(fx, fy).A / 255d)
                        * (1 - number.GetPixel(fx, fy).A / 255d);
                    originalInk += available;
                    var pixel = frame.GetPixel(fx, fy);
                    // Separate neutral logo/digit ink from the colored 100% arc in
                    // the final composite, then subtract the independently drawn digits.
                    double ringAlpha = pixel.A / 255d * (pixel.G - pixel.R) / (ringColor.G - ringColor.R);
                    double logoAlpha = Math.Clamp((pixel.A - number.GetPixel(fx, fy).A) / 255d - ringAlpha, 0, 1);
                    // The neutral track can contribute at antialiased arc edges;
                    // never credit more ink than the original asset has here.
                    visibleInk += Math.Min(available, logoAlpha);
                }
                double retained = visibleInk / originalInk;
                if (retained < .99 || containedInk <= 0)
                {
                    Console.WriteLine($"Logo {vendor} {size}px dark={dark} show={show}: available ink {retained:P1}, circle fit {containedInk / fullSourceInk:P1}");
                    preserved = false;
                }
            }
            Check(preserved);
        });
        Test("rasterized heavy digits occupy 30..38 percent of the ring at every native size", () =>
        {
            foreach (int size in RequiredIconSizes)
            foreach (int percent in new[] { 0, 4, 8, 11, 20, 35, 44, 50, 72, 88, 100 })
            {
                using var mask = MacTrayRenderer.NumberMask(percent, size);
                var layout = RingIcon.GetTrayLayout(percent, size, true);
                int left = size, top = size, right = 0, bottom = 0;
                double coverage = 0;
                for (int y = 0; y < size; y++) for (int x = 0; x < size; x++)
                {
                    int alpha = mask.GetPixel(x, y).A;
                    coverage += alpha / 255d;
                    if (alpha < 128) continue;
                    left = Math.Min(left, x); right = Math.Max(right, x + 1);
                    top = Math.Min(top, y); bottom = Math.Max(bottom, y + 1);
                }
                float ratio = (bottom - top) / (layout.RingBounds.Width + layout.RingStroke);
                if (ratio is < .30f or > .38f || top > 1 || Math.Abs((left + right) / 2f - size / 2f) > 1 ||
                    coverage / (layout.NumberBounds.Width * layout.NumberBounds.Height) < .45)
                    throw new Exception($"Digit raster {percent} at {size}px: height ratio {ratio:F3}, top {top}, coverage {coverage:F1}");
                // The exported composition must actually contain these glyphs in foreground.
                foreach (bool dark in new[] { false, true })
                {
                    using var frame = RingIcon.TrayBitmap(Vendor.Codex, percent, dark, size, true);
                    for (int y = 0; y < size; y++) for (int x = 0; x < size; x++)
                    {
                        if (mask.GetPixel(x, y).A < 240) continue;
                        var p = frame.GetPixel(x, y);
                        Check(p.A >= 240 && Math.Abs(p.R - (dark ? 255 : 0)) <= 16 && Math.Abs(p.G - p.R) <= 16);
                    }
                }
            }
        });
        Test("digit moat is transparent, glyphs are foreground, and missing quota omits digits", () =>
        {
            foreach (int size in RequiredIconSizes) foreach (bool dark in new[] { false, true })
            foreach (double percent in new double[] { 0, 8, 20, 35, 50, 72, 100 })
            {
                var layout = RingIcon.GetTrayLayout(percent, size, true);
                using var frame = RingIcon.TrayBitmap(Vendor.Codex, percent, dark, size, true);
                bool ink = false, clear = false;
                for (int y = 0; y < Math.Ceiling(layout.DigitCutout.Bottom); y++)
                for (int x = Math.Max(0, (int)Math.Floor(layout.DigitCutout.Left)); x < Math.Min(size, Math.Ceiling(layout.DigitCutout.Right)); x++)
                {
                    var p = frame.GetPixel(x, y);
                    // At 16px the subpixel moat may share every pixel with a glyph/arc edge.
                    clear |= p.A < 32;
                    if (p.A == 0 || p.R != p.G || p.G != p.B) continue;
                    if (p.R != (dark ? 255 : 0))
                    {
                        Console.WriteLine($"Unexpected digit halo {size}px {percent} dark={dark} at {x},{y}: {p}");
                        Check(false);
                    }
                    ink |= p.A >= 64 && layout.NumberBounds.Contains(x + .5f, y + .5f);
                }
                if (!(ink && clear))
                {
                    Console.WriteLine($"Digit {size}px {percent} dark={dark}: ink={ink}, clear={clear}");
                    Check(false);
                }
            }
            Equal(RingIcon.GetTrayLayout(null, 32).NumberBounds, RectangleF.Empty);
        });
        Test("native arcs agree with independent analytical Mac reference in both percentage modes", () =>
        {
            foreach (int size in RequiredIconSizes) foreach (bool dark in new[] { false, true })
            foreach (bool show in new[] { false, true })
            foreach (var (vendor, percent) in new[] { (Vendor.Codex, 72), (Vendor.Claude, 35), (Vendor.Grok, 8) })
            {
                using var native = RingIcon.TrayBitmap(vendor, percent, dark, size, show);
                using var reference = RingIcon.TrayBitmap(vendor, percent, dark, size, show, TrayRenderMode.Reference);
                double error = 0;
                for (int y = 0; y < size; y++) for (int x = 0; x < size; x++)
                {
                    var a = native.GetPixel(x, y); var b = reference.GetPixel(x, y);
                    error += Math.Abs(a.A - b.A) + Math.Abs(a.R * a.A / 255d - b.R * b.A / 255d)
                        + Math.Abs(a.G * a.A / 255d - b.G * b.A / 255d) + Math.Abs(a.B * a.A / 255d - b.B * b.A / 255d);
                }
                if (error / (size * size * 4) > 3)
                    throw new Exception($"Reference mismatch {size}px {vendor} {dark} {show}: mean channel error {error / (size * size * 4):F2}");
                AssertFullBleed(native, show);
            }
        });
        Test("Mac track alpha, fill direction and quota colors", () =>
        {
            foreach (bool dark in new[] { false, true })
            foreach (int percent in new[] { 0, 8, 19, 20, 35, 49, 50, 72, 100 })
            {
                using var bitmap = RingIcon.TrayBitmap(Vendor.Codex, percent, dark, 220, false);
                double angle = 40 * Math.PI / 180;
                double radius = (219.5 - 219.5 * .065) / 2;
                int x = (int)(110 + radius * Math.Cos(angle)), y = (int)(110 + radius * Math.Sin(angle));
                var p = bitmap.GetPixel(x, y);
                if (percent == 0) { Check(Math.Abs(p.A - 76.5) <= 1); Equal(p.R, (byte)(dark ? 255 : 0)); }
                else Equal(p.ToArgb(), ColorTranslator.FromHtml(Presentation.Color(percent, dark)).ToArgb());
                Equal(bitmap.GetPixel(110, 219).A, (byte)0); // Bottom opening.
                Check(bitmap.GetPixel(110, 0).A > 0); // Track crosses the top without digits.
            }
        });
        Test("ICO has exactly seven native Mac-geometry frames for every vendor and theme", () =>
        {
            foreach (var vendor in Enum.GetValues<Vendor>()) foreach (bool dark in new[] { false, true })
            foreach (double? percent in new double?[] { 0, 8, 19, 20, 35, 49, 50, 72, 100, null })
            {
                var family = new TrayIconFamily(vendor, percent, dark);
                InspectIco(family.ToIco(), (frame, size) =>
                {
                    AssertFullBleed(frame, percent.HasValue);
                    using var native = RingIcon.TrayBitmap(vendor, percent, dark, size);
                    for (int y = 0; y < size; y++) for (int x = 0; x < size; x++)
                    {
                        var a = frame.GetPixel(x, y); var b = native.GetPixel(x, y);
                        if (a.ToArgb() != b.ToArgb())
                        {
                            Console.WriteLine($"Icon pixel mismatch: {vendor} {dark} {percent} {size}px ({x},{y}) decoded={a.ToArgb():X8} native={b.ToArgb():X8}");
                            Check(false);
                        }
                    }
                });
            }
        });
        Test("Windows loads every ICO size and scales down from the next larger frame", () =>
        {
            var family = new TrayIconFamily(Vendor.Codex, 72, true);
            foreach (int size in RequiredIconSizes)
            {
                Equal(TrayIconFamily.BestSize(size), size);
                using var icon = family.CreateIcon(size); Equal(icon.Width, size); Equal(icon.Height, size);
                using var bitmap = icon.ToBitmap(); AssertFullBleed(bitmap);
            }
            foreach (var (requested, selected) in new[] { (12, 16), (18, 20), (28, 32), (36, 40), (56, 64), (80, 64) })
            {
                Equal(TrayIconFamily.BestSize(requested), selected);
                using var icon = family.CreateIcon(requested); Equal(icon.Width, requested); Equal(icon.Height, requested);
            }
            Throws(() => family.CreateIcon(0));
        });
        Test("live Windows DPI metrics load the audited native ICO layer", () =>
        {
            var family = new TrayIconFamily(Vendor.Grok, 8, true);
            Console.WriteLine("DPI AUDIT: scale | DPI | SM_CXSMICON | native layer | loaded size");
            foreach (int scale in new[] { 100, 125, 150, 175, 200, 250, 300, 400 })
            {
                uint dpi = (uint)(96 * scale / 100);
                int size = GetSystemMetricsForDpi(49, dpi);
                Check(size > 0);
                Equal(TrayIconMetrics.SmallIconSize(dpi, GetSystemMetricsForDpi), size);
                using var icon = family.CreateIcon(size);
                Equal(icon.Width, size); Equal(icon.Height, size);
                Console.WriteLine($"DPI AUDIT: {scale}% | {dpi} | {size} | {TrayIconFamily.BestSize(size)} | {icon.Width}");
                if (RequiredIconSizes.Contains(size))
                {
                    using var loaded = icon.ToBitmap();
                    using var native = RingIcon.TrayBitmap(Vendor.Grok, 8, true, size);
                    for (int y = 0; y < size; y++) for (int x = 0; x < size; x++)
                    {
                        var actual = loaded.GetPixel(x, y); var expected = native.GetPixel(x, y);
                        Equal(actual.A, expected.A);
                        if (actual.A == 255) Equal(actual.ToArgb(), expected.ToArgb());
                    }
                }
            }
            foreach (int size in RequiredIconSizes)
            {
                var layout = RingIcon.GetTrayLayout(72, size);
                float outer = layout.RingBounds.Width + layout.RingStroke;
                Console.WriteLine($"GEOMETRY AUDIT: {size}px | outer {outer:F2} | outer/canvas {outer / size:F6} | logo {layout.LogoBounds.Width}px | logo/outer {layout.LogoBounds.Width / outer:F6}");
            }
        });
        Test("app.ico contains all eight reviewed native PNGs verbatim including 256px", () =>
        {
            byte[] asset = File.ReadAllBytes(Path.Combine(Environment.CurrentDirectory, "assets", "app.ico"));
            InspectIco(asset, (_, _) => { }, RequiredAppIconSizes, (png, size) =>
                Check(png.SequenceEqual(File.ReadAllBytes(Path.Combine(Environment.CurrentDirectory, "assets", "brand", $"app-light-win-{size}.png")))));
        });
        Test("only reviewed logo masks are embedded, with exact source bytes", () =>
        {
            var assembly = typeof(Logos).Assembly;
            string[] resources = assembly.GetManifestResourceNames();
            Equal(resources.Length, 3);
            foreach (string name in new[] { "openai-512.png", "claude-512.png", "grok-512.png" })
            {
                using var stream = assembly.GetManifestResourceStream(resources.Single(r => r.EndsWith(name, StringComparison.Ordinal)))!;
                using var bytes = new MemoryStream(); stream.CopyTo(bytes);
                Check(bytes.ToArray().SequenceEqual(File.ReadAllBytes(Path.Combine(Environment.CurrentDirectory, "assets", "logos", name))));
            }
        });
        Test("logo masks preserve alpha and use black or white at every display size", () =>
        {
            foreach (var vendor in Enum.GetValues<Vendor>())
            foreach (int size in RequiredIconSizes.Select(s => RingIcon.GetTrayLayout(72, s).LogoBounds.Width).Concat(new[] { 24, 36, 128, 512 }).Distinct())
            {
                var light = Logos.Get(vendor, false, size); var dark = Logos.Get(vendor, true, size);
                Equal(light.Width, size); Equal(light.Height, size); Equal(dark.Width, size); Equal(dark.Height, size);
                bool ink = false, transparent = false, antialiased = false;
                for (int y = 0; y < size; y++) for (int x = 0; x < size; x++)
                {
                    var a = light.GetPixel(x, y); var b = dark.GetPixel(x, y);
                    Equal(a.A, b.A);
                    transparent |= a.A == 0; antialiased |= a.A is > 0 and < 255;
                    if (a.A == 0) continue;
                    ink = true;
                    Check(a.R == 0 && a.G == 0 && a.B == 0);
                    Check(b.R == 255 && b.G == 255 && b.B == 255);
                }
                if (!(ink && transparent && antialiased))
                    Console.WriteLine($"Logo {vendor} {size}px: ink={ink}, transparent={transparent}, antialiased={antialiased}");
                Check(ink && transparent && antialiased);
                if (size == 512)
                {
                    string name = vendor switch { Vendor.Codex => "openai", Vendor.Claude => "claude", _ => "grok" };
                    using var original = new Bitmap(Path.Combine(Environment.CurrentDirectory, "assets", "logos", name + "-512.png"));
                    for (int y = 0; y < size; y++) for (int x = 0; x < size; x++)
                        if (light.GetPixel(x, y).A != original.GetPixel(x, y).A)
                        {
                            Console.WriteLine($"Logo {vendor} alpha mismatch at ({x},{y})");
                            Check(false);
                        }
                }
            }
        });
        Test("repository contains no retired avatar files or directories", () =>
        {
            var pending = new Stack<string>(); pending.Push(Environment.CurrentDirectory);
            while (pending.TryPop(out var directory))
            foreach (string entry in Directory.EnumerateFileSystemEntries(directory))
            {
                string name = Path.GetFileName(entry);
                Check(!name.StartsWith("grokbot", StringComparison.OrdinalIgnoreCase));
                Check(!name.Contains("old-avatar", StringComparison.OrdinalIgnoreCase));
                if (Directory.Exists(entry) && name is not (".git" or "artifacts" or "bin" or "obj" or ".dotnethome" or ".nuget") &&
                    (File.GetAttributes(entry) & FileAttributes.ReparsePoint) == 0) pending.Push(entry);
            }
        });
        Test("export-icons WinExe runs without GUI and exports exact native/8x Mac comparison pixels", () =>
        {
            string directory = Path.Combine(Environment.CurrentDirectory, "artifacts", "mac-compare");
            var info = new System.Diagnostics.ProcessStartInfo(Path.Combine(Environment.CurrentDirectory,
                "src", "AISubGauge2", "bin", "Release", "net8.0-windows", "AISubGauge2.exe"))
            { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
            info.ArgumentList.Add("--export-icons"); info.ArgumentList.Add(directory);
            string runtimeRoot = Path.GetFullPath(Path.Combine(RuntimeEnvironment.GetRuntimeDirectory(), "..", "..", ".."));
            info.Environment["DOTNET_ROOT"] = runtimeRoot;
            info.Environment["DOTNET_ROOT_" + RuntimeInformation.ProcessArchitecture.ToString().ToUpperInvariant()] = runtimeRoot;
            info.Environment["DOTNET_DISABLE_GUI_ERRORS"] = "1";
            using var process = System.Diagnostics.Process.Start(info)!;
            var stdout = process.StandardOutput.ReadToEndAsync(); var stderr = process.StandardError.ReadToEndAsync();
            if (!process.WaitForExit(60000)) { process.Kill(); throw new Exception("Export timed out."); }
            Equal(process.ExitCode, 0); Equal(stderr.GetAwaiter().GetResult(), "");
            Check(stdout.GetAwaiter().GetResult().StartsWith("Icon export complete:", StringComparison.Ordinal));
            using (var overview = new Bitmap(Path.Combine(directory, "mac-compare-overview.png")))
            { Equal(overview.Width, 960); Equal(overview.Height, 800); }
            foreach (bool dark in new[] { false, true })
            foreach (var (vendor, percent) in new[] { (Vendor.Codex, 72), (Vendor.Claude, 35), (Vendor.Grok, 8) })
            {
                string name = vendor == Vendor.Codex ? "tray-icon-" : $"tray-icon-{vendor.ToString().ToLowerInvariant()}-";
                string path = Path.Combine(directory, name + (dark ? "dark" : "light") + ".ico");
                Check(File.ReadAllBytes(path).SequenceEqual(new TrayIconFamily(vendor, percent, dark, false).ToIco()));
            }
            foreach (bool dark in new[] { false, true }) foreach (bool show in new[] { true, false })
            {
                string theme = dark ? "dark" : "light", mode = show ? "percent" : "no-percent";
                using var sheet = new Bitmap(Path.Combine(directory, $"mac-compare-{theme}-{mode}.png"));
                Equal(sheet.Width, 540 * 3); Equal(sheet.Height, 620 * 7);
                foreach (int size in RequiredIconSizes)
                foreach (var (vendor, percent) in new[] { (Vendor.Codex, 72), (Vendor.Claude, 35), (Vendor.Grok, 8) })
                {
                    string stem = $"{vendor.ToString().ToLowerInvariant()}-{percent}-{theme}-{mode}-{size}px";
                    using var native = new Bitmap(Path.Combine(directory, stem + ".png"));
                    using var enlarged = new Bitmap(Path.Combine(directory, stem + "-8x.png"));
                    using var expected = RingIcon.TrayBitmap(vendor, percent, dark, size, show);
                    Equal(enlarged.Width, size * 8); Equal(enlarged.Height, size * 8);
                    for (int y = 0; y < size; y++) for (int x = 0; x < size; x++)
                    {
                        int pixel = native.GetPixel(x, y).ToArgb();
                        Equal(pixel, expected.GetPixel(x, y).ToArgb());
                        for (int dy = 0; dy < 8; dy++) for (int dx = 0; dx < 8; dx++)
                            Equal(enlarged.GetPixel(x * 8 + dx, y * 8 + dy).ToArgb(), pixel);
                    }
                }
            }
        });
        Test("offline export helper saves seven-size ICOs and exact 1x/4x contact sheets", () =>
        {
            string directory = Path.Combine(Environment.CurrentDirectory, "artifacts", "layout-previews");
            Directory.CreateDirectory(directory);
            foreach (bool dark in new[] { false, true }) foreach (string lang in new[] { "en", "zh" })
            {
                string suffix = (dark ? "dark" : "light") + "-" + lang;
                var families = new[] { new TrayIconFamily(Vendor.Codex, 72, dark), new TrayIconFamily(Vendor.Claude, 35, dark), new TrayIconFamily(Vendor.Grok, 8, dark) };
                Capture.SaveTrayIconFiles(directory, suffix, families, dark);
                foreach (string name in new[] { "tray-icon-", "tray-icon-claude-", "tray-icon-grok-" })
                    InspectIco(File.ReadAllBytes(Path.Combine(directory, name + suffix + ".ico")), (frame, _) => AssertFullBleed(frame));
                using var sheet = new Bitmap(Path.Combine(directory, "tray-icon-sizes-" + suffix + ".png"));
                Equal(sheet.Width, 284 * 7); Equal(sheet.Height, 380 * 3);
                for (int row = 0; row < 3; row++) for (int i = 0; i < RequiredIconSizes.Length; i++)
                {
                    int size = RequiredIconSizes[i];
                    for (int y = 0; y < size; y++) for (int x = 0; x < size; x++)
                    {
                        int original = sheet.GetPixel(i * 284 + (284 - size) / 2 + x, row * 380 + 32 + y).ToArgb();
                        for (int dy = 0; dy < 4; dy++) for (int dx = 0; dx < 4; dx++)
                            Equal(sheet.GetPixel(i * 284 + (284 - size * 4) / 2 + x * 4 + dx, row * 380 + 108 + y * 4 + dy).ToArgb(), original);
                    }
                }
            }
        });
    }

    private static byte[] ReadResource(IntPtr module, IntPtr type, IntPtr name)
    {
        IntPtr resource = FindResource(module, name, type); Check(resource != IntPtr.Zero);
        int length = checked((int)SizeofResource(module, resource)); Check(length > 0);
        IntPtr data = LockResource(LoadResource(module, resource)); Check(data != IntPtr.Zero);
        var bytes = new byte[length]; Marshal.Copy(data, bytes, 0, length); return bytes;
    }
    private delegate bool ResourceNameCallback(IntPtr module, IntPtr type, IntPtr name, IntPtr parameter);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr LoadLibraryEx(string path, IntPtr file, uint flags);
    [DllImport("kernel32.dll")] private static extern bool FreeLibrary(IntPtr module);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern bool EnumResourceNames(IntPtr module, IntPtr type, ResourceNameCallback callback, IntPtr parameter);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr FindResource(IntPtr module, IntPtr name, IntPtr type);
    [DllImport("kernel32.dll")] private static extern uint SizeofResource(IntPtr module, IntPtr resource);
    [DllImport("kernel32.dll")] private static extern IntPtr LoadResource(IntPtr module, IntPtr resource);
    [DllImport("kernel32.dll")] private static extern IntPtr LockResource(IntPtr resource);
    [DllImport("user32.dll")] private static extern int GetSystemMetricsForDpi(int index, uint dpi);

    private static void InspectIco(byte[] bytes, Action<Bitmap, int> inspect, int[]? sizes = null, Action<byte[], int>? inspectPng = null)
    {
        sizes ??= RequiredIconSizes;
        using var stream = new MemoryStream(bytes); using var reader = new BinaryReader(stream);
        Equal(reader.ReadUInt16(), (ushort)0); Equal(reader.ReadUInt16(), (ushort)1); Equal(reader.ReadUInt16(), (ushort)sizes.Length);
        int nextOffset = 6 + sizes.Length * 16;
        foreach (int size in sizes)
        {
            byte dimension = size == 256 ? (byte)0 : (byte)size;
            Equal(reader.ReadByte(), dimension); Equal(reader.ReadByte(), dimension);
            Equal(reader.ReadByte(), (byte)0); Equal(reader.ReadByte(), (byte)0);
            Equal(reader.ReadUInt16(), (ushort)1); Equal(reader.ReadUInt16(), (ushort)32);
            int length = reader.ReadInt32(), offset = reader.ReadInt32(); Equal(offset, nextOffset);
            Check(length > 0 && offset + length <= bytes.Length); nextOffset += length;
            using var png = new MemoryStream(bytes, offset, length); using var frame = new Bitmap(png);
            Equal(frame.Width, size); Equal(frame.Height, size); inspect(frame, size);
            inspectPng?.Invoke(bytes.AsSpan(offset, length).ToArray(), size);
        }
        Equal(nextOffset, bytes.Length);
    }

    private static void AssertFullBleed(Bitmap frame, bool hasNumber = true)
    {
        // Measure actual raster ink, including the digits and the round bottom caps.
        int left = frame.Width, top = frame.Height, right = 0, bottom = 0;
        for (int y = 0; y < frame.Height; y++) for (int x = 0; x < frame.Width; x++)
        {
            if (frame.GetPixel(x, y).A < 16) continue;
            left = Math.Min(left, x); top = Math.Min(top, y); right = Math.Max(right, x + 1); bottom = Math.Max(bottom, y + 1);
        }
        double strokeRatio = .065;
        double diameter = frame.Height - .5;
        double expectedBottom = frame.Height / 2d + diameter *
            ((1 - strokeRatio) / 2 * Math.Sin(55.5 * Math.PI / 180) + strokeRatio / 2);
        Check(left <= 1 && frame.Width - right <= 1);
        Check(top <= 1);
        if (Math.Abs(bottom - expectedBottom) > 1)
            throw new Exception($"Mac arc {frame.Width}px: bottom {bottom}, expected {expectedBottom:F2}");
        Equal(frame.GetPixel(frame.Width / 2, frame.Height - 1).A, (byte)0);
    }
}
