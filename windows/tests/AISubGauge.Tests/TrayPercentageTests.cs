using AISubGauge.Core;
using AISubGauge.UI;
using System.Drawing;
using System.Windows.Forms;

internal static partial class Program
{
    private static void RunTrayPercentageTests()
    {
        int before = passed, failures = failed;
        Test("both modes use the same larger logo at every size 16..64", () =>
        {
            var rows = new List<string> { "Size,ShownRatio,HiddenRatio,Scale,ShownSide,HiddenSide" };
            foreach (int size in Enumerable.Range(16, 49))
            {
                var shown = MacTrayRenderer.GetLayout(72, size, true);
                var hidden = MacTrayRenderer.GetLayout(72, size, false);
                double diameter = shown.RingBounds.Width + shown.RingStroke;
                double scale = hidden.LogoBounds.Width / (double)shown.LogoBounds.Width;
                Equal(scale, 1d);
                Equal(shown.LogoBounds, hidden.LogoBounds);
                Equal(shown.LogoClearance, hidden.LogoClearance);
                int oldSide = size switch { 16 => 12, 20 => 15, 24 => 18, 32 => 26, 40 => 32, 48 => 39, 64 => 51, _ => (int)MathF.Round(size * .8f) };
                Equal(shown.LogoBounds.Width, (int)MathF.Round(oldSide * 1.08f));
                Equal(hidden.RingBounds, shown.RingBounds); Equal(hidden.RingStroke, shown.RingStroke);
                Check(hidden.NumberBounds.IsEmpty && hidden.DigitCutout.IsEmpty);
                foreach (double? percent in new double?[] { null, 0, 100, -1, 101, double.NaN, double.PositiveInfinity })
                {
                    Equal(MacTrayRenderer.GetLayout(percent, size, false), hidden);
                    Equal(MacTrayRenderer.GetLayout(percent, size, true).LogoBounds, hidden.LogoBounds);
                }
                string row = FormattableString.Invariant($"{size},{shown.LogoBounds.Width / diameter:F6},{hidden.LogoBounds.Width / diameter:F6},{scale:F6},{shown.LogoBounds.Width},{hidden.LogoBounds.Width}");
                rows.Add(row); Console.WriteLine("LOGO RATIO: " + row);
            }
            File.WriteAllLines(Path.Combine(Environment.CurrentDirectory, "artifacts", "fixL-logo-ratios.csv"), rows);
        });
        Test("both modes keep identical logo ink half a pixel inside the inner circle at every size and brand", () =>
        {
            var rows = new List<string> { "Size,Vendor,RetainedInkRatio,MinimumClearance" };
            foreach (int size in Enumerable.Range(16, 49)) foreach (var vendor in Enum.GetValues<Vendor>())
            {
                var layout = MacTrayRenderer.GetLayout(100, size, false);
                using var logo = MacTrayRenderer.LogoMask(vendor, size, layout);
                using var shownLogo = MacTrayRenderer.LogoMask(vendor, size, MacTrayRenderer.GetLayout(100, size, true));
                var source = Logos.Get(vendor, true, layout.LogoBounds.Width);
                double cx = layout.RingBounds.Left + layout.RingBounds.Width / 2;
                double cy = layout.RingBounds.Top + layout.RingBounds.Height / 2;
                double inner = (layout.RingBounds.Width - layout.RingStroke) / 2;
                double retained = 0, original = 0, clearance = double.MaxValue;
                for (int y = 0; y < source.Height; y++) for (int x = 0; x < source.Width; x++)
                    original += source.GetPixel(x, y).A;
                for (int y = 0; y < size; y++) for (int x = 0; x < size; x++)
                {
                    int alpha = logo.GetPixel(x, y).A;
                    Equal(shownLogo.GetPixel(x, y).ToArgb(), logo.GetPixel(x, y).ToArgb());
                    double dx = Math.Abs(x + .5 - cx) + .5, dy = Math.Abs(y + .5 - cy) + .5;
                    // The accepted clipping must leave the interior artwork intact.
                    if (Math.Sqrt(dx * dx + dy * dy) < inner - 1.00001 && layout.LogoBounds.Contains(x, y))
                        Equal(alpha, (int)source.GetPixel(x - layout.LogoBounds.X, y - layout.LogoBounds.Y).A);
                    if (alpha == 0) continue;
                    retained += alpha;
                    clearance = Math.Min(clearance, inner - Math.Sqrt(dx * dx + dy * dy));
                    if (clearance < .5 - .00001 || x == 0 || y == 0 || x == size - 1 || y == size - 1)
                    {
                        Console.WriteLine($"Hidden logo containment: {vendor} {size}px at {x},{y}, clearance={clearance}");
                        throw new Exception($"Hidden logo containment: {vendor} {size}px at {x},{y}, clearance={clearance}");
                    }
                }
                // Report clipping separately; ink retention is not a substitute
                // for visually reviewing brand recognizability at native sizes.
                Check(retained > 0 && original > 0);
                rows.Add(FormattableString.Invariant($"{size},{vendor},{retained / original:F6},{clearance:F6}"));
            }
            File.WriteAllLines(Path.Combine(Environment.CurrentDirectory, "artifacts", "fixL-logo-containment.csv"), rows);
            using var sheet = new Bitmap(8 * 120, 3 * 140);
            using (var g = Graphics.FromImage(sheet))
            {
                g.Clear(Color.FromArgb(37, 37, 42));
                g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.NearestNeighbor;
                g.PixelOffsetMode = System.Drawing.Drawing2D.PixelOffsetMode.Half;
                foreach (int size in Enumerable.Range(16, 8)) foreach (var vendor in Enum.GetValues<Vendor>())
                {
                    int x = (size - 16) * 120, y = (int)vendor * 140;
                    g.DrawString($"{vendor} {size}px", SystemFonts.DefaultFont, Brushes.White, x + 4, y + 4);
                    using var frame = MacTrayRenderer.Render(vendor, 72, true, size, false, TrayRenderMode.Native);
                    g.DrawImageUnscaled(frame, x + 4, y + 22);
                    g.DrawImage(frame, new Rectangle(x + 4, y + 46, size * 4, size * 4), 0, 0, size, size, GraphicsUnit.Pixel);
                }
            }
            sheet.Save(Path.Combine(Environment.CurrentDirectory, "artifacts", "fixL-small-logos.png"), System.Drawing.Imaging.ImageFormat.Png);
        });
        Test("shown output contains heavy foreground digit ink over the unchanged logo at every size", () =>
        {
            foreach (int size in Enumerable.Range(16, 49)) foreach (var vendor in Enum.GetValues<Vendor>())
            foreach (bool dark in new[] { false, true }) foreach (int percent in new[] { 0, 8, 35, 72, 100 })
            {
                using var shown = RingIcon.TrayBitmap(vendor, percent, dark, size, true);
                using var hidden = RingIcon.TrayBitmap(vendor, percent, dark, size, false);
                using var digits = MacTrayRenderer.NumberMask(percent, size, true);
                int digitPixels = 0, changedPixels = 0;
                for (int y = 0; y < size; y++) for (int x = 0; x < size; x++)
                {
                    var pixel = shown.GetPixel(x, y);
                    if (digits.GetPixel(x, y).A >= 240)
                    {
                        digitPixels++;
                        Check(pixel.A >= 240 && Math.Abs(pixel.R - (dark ? 255 : 0)) <= 16 && Math.Abs(pixel.G - pixel.R) <= 16);
                    }
                    if (pixel.ToArgb() != hidden.GetPixel(x, y).ToArgb()) changedPixels++;
                }
                Check(digitPixels > 0 && changedPixels > 0);
                AssertFullBleed(shown); AssertFullBleed(hidden, false);
            }
        });
        Test("default tray layout and ICO family omit digits", () =>
        {
            foreach (var vendor in Enum.GetValues<Vendor>()) foreach (bool dark in new[] { false, true })
            {
                var family = new TrayIconFamily(vendor, 72, dark);
                Check(family.ToIco().SequenceEqual(new TrayIconFamily(vendor, 72, dark, false).ToIco()));
                Check(!family.ToIco().SequenceEqual(new TrayIconFamily(vendor, 72, dark, true).ToIco()));
                foreach (int size in RequiredIconSizes)
                {
                    Check(RingIcon.GetTrayLayout(72, size).NumberBounds.IsEmpty);
                    using var actual = RingIcon.TrayBitmap(vendor, 72, dark, size);
                    using var expected = RingIcon.TrayBitmap(vendor, 72, dark, size, false);
                    for (int y = 0; y < size; y++) for (int x = 0; x < size; x++)
                        Equal(actual.GetPixel(x, y).ToArgb(), expected.GetPixel(x, y).ToArgb());
                }
            }
        });
        Test("tray percentage defaults off for new, missing, old and corrupt settings", () =>
        {
            string directory = Path.Combine(Environment.CurrentDirectory, "artifacts", "tests", "tray-default-" + Guid.NewGuid().ToString("N"));
            var store = new SettingsStore(directory);
            Check(!new Settings().ShowTrayPercentage); Check(!store.Load().ShowTrayPercentage);
            Directory.CreateDirectory(directory);
            File.WriteAllText(Path.Combine(directory, "settings.json"), "{\"Autostart\":false,\"TrayEnabled\":[false,true,false]}");
            var old = store.Load(); Check(!old.ShowTrayPercentage); Check(!old.Autostart && !old.TrayEnabled[0]);
            File.WriteAllText(Path.Combine(directory, "settings.json"), "{broken"); Check(!store.Load().ShowTrayPercentage);
        });
        Test("tray percentage persists both false and true without changing other preferences", () =>
        {
            string directory = Path.Combine(Environment.CurrentDirectory, "artifacts", "tests", "tray-roundtrip-" + Guid.NewGuid().ToString("N"));
            var store = new SettingsStore(directory);
            foreach (bool show in new[] { false, true })
            {
                store.Save(new() { ShowTrayPercentage = show, Language = Language.Chinese, Theme = Theme.Dark, TrayEnabled = [false, true, false] });
                var actual = store.Load(); Equal(actual.ShowTrayPercentage, show); Equal(actual.Language, Language.Chinese);
                Equal(actual.Theme, Theme.Dark); Check(actual.TrayEnabled.SequenceEqual(new[] { false, true, false }));
            }
        });
        Test("tray percentage has exact English and Chinese labels", () =>
        {
            Equal(new Texts("en")["ShowTrayPercentage"], "Show percentage in tray");
            Equal(new Texts("zh-CN")["ShowTrayPercentage"], "托盘显示百分比");
        });
        Test("subscription toggle saves and replaces all three tray families and live icons in the same UI event cycle", () =>
        {
            foreach (string lang in new[] { "en", "zh" })
            {
                string directory = Path.Combine(Environment.CurrentDirectory, "artifacts", "tests", "tray-event-" + Guid.NewGuid().ToString("N"));
                var store = new SettingsStore(directory);
                using var app = new AISubGauge.UI.AppContext(Options.Parse(["--demo", "--autostart", "--lang", lang]), null, settingsStore: store);
                Application.DoEvents();
                foreach (bool show in new[] { true, false })
                {
                    var beforeFamilies = app.TrayIconFamilies.ToArray();
                    var beforeIcons = app.NotificationIcons.Select(n => n.Icon).ToArray();
                    var toggle = app.SettingsWindow.Controls.OfType<Toggle>().Single(t => t.AccessibleName == app.Text["ShowTrayPercentage"]);
                    Equal(toggle.Checked, !show);
                    Check(app.SettingsWindow.Controls.OfType<Toggle>().Where(t => t != toggle).All(t => t.Top > toggle.Bottom));
                    toggle.Checked = show; Application.DoEvents();
                    Equal(app.Settings.ShowTrayPercentage, show); Equal(store.Load().ShowTrayPercentage, show);
                    for (int i = 0; i < 3; i++)
                    {
                        Check(!ReferenceEquals(beforeFamilies[i], app.TrayIconFamilies[i]));
                        Check(!ReferenceEquals(beforeIcons[i], app.NotificationIcons[i].Icon));
                        var snapshot = app.Snapshots[i];
                        var expected = new TrayIconFamily(snapshot.Vendor, snapshot.FiveHour.Percent ?? snapshot.Weekly.Percent, app.TrayDark, show);
                        Check(expected.ToIco().SequenceEqual(app.TrayIconFamilies[i].ToIco()));
                        using var expectedIcon = expected.CreateIcon(app.TrayIconSize);
                        using var expectedBitmap = expectedIcon.ToBitmap(); using var actualBitmap = app.NotificationIcons[i].Icon!.ToBitmap();
                        for (int y = 0; y < actualBitmap.Height; y++) for (int x = 0; x < actualBitmap.Width; x++)
                            Equal(actualBitmap.GetPixel(x, y).ToArgb(), expectedBitmap.GetPixel(x, y).ToArgb());
                    }
                }
            }
        });
        Test("read-only screenshot store preserves existing settings bytes when percentage changes", () =>
        {
            string directory = Path.Combine(Environment.CurrentDirectory, "artifacts", "tests", "tray-readonly-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(directory);
            string path = Path.Combine(directory, "settings.json"), original = "{\"ShowTrayPercentage\":false}";
            File.WriteAllText(path, original);
            var store = new SettingsStore(directory, readOnly: true);
            var settings = store.Load(); settings.ShowTrayPercentage = true; store.Save(settings);
            Equal(File.ReadAllText(path), original); Equal(Directory.GetFiles(directory).Length, 1);
        });
        Test("capture helpers export both layouts for every theme and language without settings access", () =>
        {
            string directory = Path.Combine(Environment.CurrentDirectory, "artifacts", "fixL-previews"); Directory.CreateDirectory(directory);
            var snapshots = Enum.GetValues<Vendor>().Select(v => Snapshot.Demo(v, Clock)).ToArray();
            foreach (bool dark in new[] { false, true }) foreach (string lang in new[] { "en", "zh" })
            foreach (bool show in new[] { true, false })
            {
                string suffix = (dark ? "dark" : "light") + "-" + lang;
                var families = snapshots.Select(s => new TrayIconFamily(s.Vendor, s.FiveHour.Percent, dark, show)).ToArray();
                Capture.SaveTrayIconFiles(directory, suffix, families, dark, show);
                string mode = show ? "percent-" : "";
                string preview = Path.Combine(directory, "tray-icon-" + mode + suffix + ".png");
                Capture.SaveTrayIconPreview(preview, snapshots, dark, 16, show);
                using var image = new Bitmap(preview); Equal(image.Width, 480); Equal(image.Height, 160);
                using var sheet = new Bitmap(Path.Combine(directory, "tray-icon-sizes-" + mode + suffix + ".png"));
                Equal(sheet.Width, 284 * 7); Equal(sheet.Height, 380 * 3);
                for (int i = 0; i < 3; i++)
                {
                    using var native = RingIcon.TrayBitmap((Vendor)i, snapshots[i].FiveHour.Percent, dark, 16, show);
                    var background = dark ? Color.FromArgb(28, 28, 32) : Color.FromArgb(246, 246, 248);
                    using var expected = new Bitmap(16, 16); using (var g = Graphics.FromImage(expected)) { g.Clear(background); g.DrawImageUnscaled(native, 0, 0); }
                    for (int y = 0; y < 16; y++) for (int x = 0; x < 16; x++)
                        Equal(image.GetPixel(i * 160 + x * 10 + 5, y * 10 + 5).ToArgb(), expected.GetPixel(x, y).ToArgb());
                }
            }
        });
        Console.WriteLine($"Tray percentage: {passed - before} PASS, {failed - failures} FAIL");
    }
}
