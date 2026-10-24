using AISubGauge.Core;
using AISubGauge.UI;
using System.Globalization;
using System.Net;
using System.Text;
using System.Text.Json;
using System.Resources;

internal static partial class Program
{
    private static int passed, failed;
    private static readonly FakeClock Clock = new();
    private const string Secret = "sk-TEST-SECRET-123456789-DO-NOT-LEAK"; // gitleaks:allow -- synthetic test fixture
    private const string Jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJTRVNULVNFR1JFVCJ9.c2lnbmF0dXJlU0VDUkVU"; // gitleaks:allow -- synthetic test fixture
    private static readonly string Billing = "{\"subscription_tier\":\"SuperGrok\",\"config\":{\"creditUsagePercent\":78,\"currentPeriod\":{\"type\":\"USAGE_PERIOD_TYPE_WEEKLY\",\"end\":\"2026-10-28T00:00:00Z\"}}}";
    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length > 0)
        {
            if (args.Length != 1 || args[0] != "--packaging") return 2;
            RunPackagingTests();
            Console.WriteLine($"Packaging: {passed} PASS, {failed} FAIL"); return failed == 0 ? 0 : 1;
        }
        RunSecurityTests();
        RunTrayIconTests();
        RunTrayPercentageTests();
        Test("quota color boundaries (light/dark)", () =>
        {
            foreach (bool dark in new[] { false, true })
            {
                Equal(Presentation.Color(50, dark), dark ? "#30D158" : "#34C759"); Equal(Presentation.Color(100, dark), Presentation.Color(50, dark));
                Equal(Presentation.Color(20, dark), dark ? "#FF9F0A" : "#FF9500"); Equal(Presentation.Color(49, dark), Presentation.Color(20, dark));
                Equal(Presentation.Color(19, dark), dark ? "#FF453A" : "#FF3B30"); Equal(Presentation.Color(0, dark), Presentation.Color(19, dark));
            }
        });
        Test("percent clamp, missing and nonfinite values", () => { Equal(Presentation.Percent(-3), "0%"); Equal(Presentation.Percent(120), "100%"); Equal(Presentation.Percent(null), "—"); Equal(Presentation.Percent(double.NaN), "—"); Equal(new Window(double.PositiveInfinity).Percent, null); });
        Test("reset formatting Chinese and English", () =>
        {
            var zh = new Texts("zh-CN"); var en = new Texts("en");
            Equal(zh.Reset(Clock.Now.AddHours(3), Clock.Now), "3 小时后重置"); Equal(en.Reset(Clock.Now.AddHours(3), Clock.Now), "Resets in 3 hours");
            Equal(zh.Reset(Clock.Now.AddMinutes(8), Clock.Now), "8 分钟后重置"); Equal(en.Reset(Clock.Now.AddMinutes(8), Clock.Now), "Resets in 8 minutes");
            Equal(en.Reset(Clock.Now.AddHours(1), Clock.Now), "Resets in 1 hour"); Equal(en.Reset(Clock.Now.AddSeconds(45), Clock.Now), "Resets in 1 minute"); Equal(en.Reset(null, Clock.Now), "Reset time unavailable"); Equal(zh.Reset(Clock.Now.AddSeconds(-1), Clock.Now), "即将重置");
        });
        Test("system language and explicit overrides", () => { Equal(Presentation.ResolveLanguage(Language.System, new("zh-TW")), "zh-CN"); Equal(Presentation.ResolveLanguage(Language.System, new("fr-FR")), "en"); Equal(Presentation.ResolveLanguage(Language.English, new("zh-CN")), "en"); Equal(Presentation.ResolveLanguage(Language.Chinese, new("en-US")), "zh-CN"); });
        Test("all theme resolution combinations", () => { Check(!Presentation.IsDark(Theme.System, true)); Check(Presentation.IsDark(Theme.System, false)); Check(Presentation.IsDark(Theme.Dark, true)); Check(!Presentation.IsDark(Theme.Light, false)); });
        Test("running grace starts at observed stop, expires at 30s", () =>
        {
            var clock = new FakeClock(); var gate = new RunningGate(clock);
            Check(!gate.Visible(Vendor.Codex, false, false)); Check(gate.Visible(Vendor.Codex, true, false));
            clock.Advance(10); Check(gate.Visible(Vendor.Codex, false, false)); clock.Advance(29.999); Check(gate.Visible(Vendor.Codex, false, false));
            clock.Advance(.001); Check(!gate.Visible(Vendor.Codex, false, false)); Check(gate.Visible(Vendor.Codex, true, false));
            Check(!gate.Visible(Vendor.Claude, false, false));
        });
        Test("always show and switching it off", () => { var gate = new RunningGate(new FakeClock()); Check(gate.Visible(Vendor.Grok, false, true)); Check(!gate.Visible(Vendor.Grok, false, false)); });
        Test("autostart only touches AISubGauge2", () =>
        {
            var registry = new FakeRegistry(); registry.Values["AISubGauge"] = "legacy";
            Startup.Apply(registry, true, @"C:\Test Folder\AISubGauge2.exe"); Equal(registry.Values["AISubGauge2"], "\"C:\\Test Folder\\AISubGauge2.exe\" --autostart");
            Startup.Apply(registry, false, "unused"); Equal(registry.Values["AISubGauge"], "legacy"); Check(!registry.Values.ContainsKey("AISubGauge2")); Check(registry.Touched.All(n => n == "AISubGauge2"));
        });
        Test("screenshot has no registry side effects", () => { var registry = new FakeRegistry(); Startup.Apply(registry, true, "unused", true); Startup.Apply(registry, false, "unused", true); Equal(registry.Touched.Count, 0); });
        Test("screenshot settings store is read-only", () =>
        {
            string directory = Path.Combine(Environment.CurrentDirectory, "artifacts", "tests", "readonly-" + Guid.NewGuid().ToString("N"));
            var store = new SettingsStore(directory, true); store.Save(new()); Check(!Directory.Exists(directory));
        });
        Test("settings roundtrip and corrupted settings defaults", () =>
        {
            string directory = Path.Combine(Environment.CurrentDirectory, "artifacts", "tests", "settings");
            var store = new SettingsStore(directory); store.Save(new() { Language = Language.English, Theme = Theme.Dark, Autostart = false, AlwaysShow = true, TrayEnabled = [false, true, false] });
            var actual = store.Load(); Equal(actual.Language, Language.English); Equal(actual.Theme, Theme.Dark); Check(actual.AlwaysShow && !actual.Autostart && !actual.TrayEnabled[0]);
            File.WriteAllText(Path.Combine(directory, "settings.json"), "{broken"); Check(store.Load().Autostart);
        });
        Test("redactor known opaque secrets, bearer, key and JWT", () =>
        {
            var redactor = new Redactor(); redactor.Register("opaque-sensitive-test-value");
            string value = redactor.Clean(Secret + " " + Jwt + " Bearer opaque-secret " + "token=anothersecret \"cookie\":\"private-cookie\" opaque-sensitive-test-value");
            foreach (string secret in new[] { Secret, Jwt, "opaque-secret", "anothersecret", "private-cookie", "opaque-sensitive-test-value" }) Check(!value.Contains(secret));
            Equal(redactor.Clean("Codex: Network"), "Codex: Network");
        });
        Test("credential ToString and JSON never contain tokens", () => { var credential = new Credential(Secret, Jwt, Secret, Clock.Now); NoSecrets(credential.ToString(), JsonSerializer.Serialize(credential)); });
        Test("all resource keys exist in both languages", () =>
        {
            var manager = new ResourceManager("AISubGauge.Core.Strings", typeof(Texts).Assembly);
            var en = manager.GetResourceSet(new("en"), true, true)!; var zh = manager.GetResourceSet(new("zh-CN"), true, false)!;
            foreach (System.Collections.DictionaryEntry entry in en) { Check(zh.GetString((string)entry.Key) is { Length: > 0 }); Check(!((string)entry.Value!).Contains('\uFFFD')); }
        });
        Test("evidence options enforce language and theme", () =>
        {
            var parsed = Options.Parse(["--screenshot", "artifacts/evidence", "--theme", "dark", "--lang", "zh", "--demo"]); Check(parsed.Demo); Equal(parsed.Theme, Theme.Dark); Equal(parsed.Language, Language.Chinese);
            Throws(() => Options.Parse(["--screenshot", "artifacts/evidence"])); Throws(() => Options.Parse(["--theme", "unknown"])); Throws(() => Options.Parse(["--demo", "--demo"]));
        });
        Test("demo matches required values", () => { Equal(Snapshot.Demo(Vendor.Codex, Clock).FiveHour.Percent, 72d); Equal(Snapshot.Demo(Vendor.Claude, Clock).Weekly.Percent, 61d); Equal(Snapshot.Demo(Vendor.Grok, Clock).FiveHour.Percent, 8d); });
        Test("embedded brand logos and tray icon handles", () =>
        {
            foreach (var vendor in Enum.GetValues<Vendor>()) foreach (bool dark in new[] { false, true })
            {
                Check(Logos.Get(vendor, dark).Width > 0); using var bitmap = RingIcon.Bitmap(vendor, 72, dark); using var icon = RingIcon.Icon(bitmap); Check(icon.Handle != IntPtr.Zero); Equal(bitmap.Width, 32);
            }
            Logos.DisposeAll();
        });
        Test("brand alpha masks survive light/dark tinting", () =>
        {
            foreach (var vendor in Enum.GetValues<Vendor>())
            {
                var light = Logos.Get(vendor, false); var dark = Logos.Get(vendor, true);
                string directory = Path.Combine(Environment.CurrentDirectory, "artifacts", "layout-previews"); Directory.CreateDirectory(directory);
                light.Save(Path.Combine(directory, "logo-" + vendor + "-light.png")); dark.Save(Path.Combine(directory, "logo-" + vendor + "-dark.png"));
                int opaque = 0, transparent = 0;
                for (int y = 0; y < light.Height; y++) for (int x = 0; x < light.Width; x++)
                {
                    var a = light.GetPixel(x, y); var b = dark.GetPixel(x, y); Equal(a.A, b.A);
                    if (a.A == 0) transparent++;
                    if (a.A == 255) { opaque++; Equal(a.R, (byte)0); Equal(b.R, (byte)255); }
                }
                Check(opaque > 100 && transparent > 100);
            }
        });
        Test("NotifyIcon native identity is compatible with pinned runtime", () =>
        {
            using var first = new NotifyIcon(); using var second = new NotifyIcon();
            var a = TrayCapture.Identity(first); var b = TrayCapture.Identity(second);
            Check(a.Id != b.Id);
        });
        Test("tray evidence requires every icon in notification area or visible flyout", () =>
        {
            var tray = new System.Drawing.Rectangle(-400, 950, 400, 50);
            var flyout = new System.Drawing.Rectangle(-200, 750, 200, 180);
            var visible = TrayCapture.Locate("Codex", 0, new(-120, 960, 24, 24), tray);
            var hidden = TrayCapture.Locate("Claude", 0, new(-100, 800, 24, 24), tray);
            var missing = TrayCapture.Locate("Grok", unchecked((int)0x80004005), new(-100, 800, 24, 24), tray);
            var chevron = TrayCapture.Locate("Grok", 1, new(-180, 960, 24, 24), tray);
            Check(visible.InNotificationArea); Check(!hidden.InNotificationArea); Check(!chevron.InNotificationArea);
            Check(TrayCapture.Covered([visible, hidden], flyout));
            Check(!TrayCapture.Covered([visible, hidden, missing], flyout));
            Check(!TrayCapture.Covered([visible, chevron], flyout));
            Check(!TrayCapture.Covered([hidden], new(-80, 800, 24, 24)));
        });
        AsyncTest("overflow close failure is non-fatal after PNG write", async () =>
        {
            foreach (bool throws in new[] { false, true })
            {
                var closer = new FakeOverflowCloser { FailInvoke = throws, FailEscape = throws };
                var report = new TrayCaptureReport();
                string path = Path.Combine(Environment.CurrentDirectory, "artifacts", "tests", "close-warning.png");
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                await TrayCapture.CaptureWithCleanupAsync(() =>
                {
                    using var png = RingIcon.TrayBitmap(Vendor.Codex, 72, true, 16);
                    png.Save(path, System.Drawing.Imaging.ImageFormat.Png); report.OverflowCaptured = true;
                    return Task.CompletedTask;
                }, closer, report);
                using var saved = new System.Drawing.Bitmap(path); Equal(saved.Width, 16);
                Check(report.OverflowCaptured && !report.OverflowClosed && report.Warning is not null);
                Equal(string.Join(",", closer.Calls), "invoke,escape");
                NoSecrets(JsonSerializer.Serialize(report));
            }
        });
        AsyncTest("overflow close uses chevron first and Escape on stale UIA element", async () =>
        {
            var report = new TrayCaptureReport();
            var closed = new FakeOverflowCloser { Visible = false };
            await TrayCapture.CaptureWithCleanupAsync(() => Task.CompletedTask, closed, report);
            Check(report.OverflowClosed && closed.Calls.Count == 0);
            var chevron = new FakeOverflowCloser { CloseOnInvoke = true };
            await TrayCapture.CaptureWithCleanupAsync(() => Task.CompletedTask, chevron, report);
            Check(report.OverflowClosed && report.Warning is null); Equal(string.Join(",", chevron.Calls), "invoke");
            var escape = new FakeOverflowCloser { FailInvoke = true, CloseOnEscape = true };
            await TrayCapture.CaptureWithCleanupAsync(() => Task.CompletedTask, escape, report);
            Check(report.OverflowClosed && report.Warning is null); Equal(string.Join(",", escape.Calls), "invoke,escape");
        });
        AsyncTest("overflow cleanup preserves actual capture failure", async () =>
        {
            var original = new IOException("Simulated PNG write failure.");
            var report = new TrayCaptureReport();
            var closer = new FakeOverflowCloser { FailInvoke = true, FailEscape = true, FailVisibility = true };
            Exception? observed = null;
            try { await TrayCapture.CaptureWithCleanupAsync(() => Task.FromException(original), closer, report); }
            catch (Exception error) { observed = error; }
            Check(ReferenceEquals(original, observed)); Check(!report.OverflowCaptured && !report.OverflowClosed);
        });
        Test("tray metrics use taskbar DPI and system small-icon size", () =>
        {
            foreach (uint dpi in new uint[] { 96, 120, 144, 168, 192, 240, 288, 384 })
            {
                int expected = (int)(16 * dpi / 96);
                Equal(TrayIconMetrics.SmallIconSize(dpi, (index, actualDpi) => { Equal(index, 49); Equal(actualDpi, dpi); return expected; }), expected);
            }
            Equal(TrayIconMetrics.SmallIconSize(0, (_, dpi) => { Equal(dpi, 96u); return 16; }), 16);
            Equal(TrayIconMetrics.SmallIconSize(144, (_, _) => 0), 24);
        });
        Test("native-size tray glyphs and offline previews", () =>
        {
            string directory = Path.Combine(Environment.CurrentDirectory, "artifacts", "layout-previews"); Directory.CreateDirectory(directory);
            foreach (bool dark in new[] { false, true }) foreach (int size in TrayIconFamily.Sizes)
            {
                using var sheet = new System.Drawing.Bitmap(size * 6, size);
                using var graphics = System.Drawing.Graphics.FromImage(sheet);
                graphics.Clear(dark ? System.Drawing.Color.FromArgb(32, 32, 36) : System.Drawing.Color.FromArgb(245, 245, 248));
                double?[] values = [72, 35, 8, 100, 0, null];
                for (int i = 0; i < values.Length; i++)
                {
                    using var bitmap = RingIcon.TrayBitmap((Vendor)(i % 3), values[i], dark, size);
                    using var icon = RingIcon.Icon(bitmap); Equal(icon.Width, size); Equal(icon.Height, size);
                    var layout = RingIcon.GetTrayLayout(values[i], size);
                    int rows = 0;
                    for (int y = 0; y < (int)Math.Ceiling(layout.NumberBounds.Bottom); y++)
                    {
                        bool ink = false;
                        for (int x = (int)Math.Floor(layout.NumberBounds.Left); x < (int)Math.Ceiling(layout.NumberBounds.Right); x++)
                        {
                            var pixel = bitmap.GetPixel(x, y);
                            if (pixel.A >= 32 && pixel.R == pixel.G && pixel.G == pixel.B && (dark ? pixel.R > 128 : pixel.R < 127)) ink = true;
                        }
                        if (ink) rows++;
                    }
                    // NumberBounds is glyph ink, with the transparent moat measured separately.
                    if (i < 5 && rows < (int)layout.NumberBounds.Height - 1)
                    {
                        Console.WriteLine($"Number glyph {size}px / dark={dark} / {values[i]}: {rows} foreground rows in {layout.NumberBounds.Height}px ink box");
                        Check(false);
                    }
                    graphics.DrawImageUnscaled(bitmap, i * size, 0);
                }
                sheet.Save(Path.Combine(directory, $"tray-{(dark ? "dark" : "light")}-{size}px.png"));
            }
        });
        Test("offline UI layout previews (not screen evidence)", () =>
        {
            string directory = Path.Combine(Environment.CurrentDirectory, "artifacts", "layout-previews"); Directory.CreateDirectory(directory);
            foreach (string theme in new[] { "light", "dark" }) foreach (string lang in new[] { "zh", "en" })
            {
                using var app = new AISubGauge.UI.AppContext(Options.Parse(["--demo", "--theme", theme, "--lang", lang]));
                Equal(app.TrayDark, !SystemAppearance.Light(true));
                Equal(app.TrayIconSize, TrayIconMetrics.SmallIconSize());
                app.Settings.AlwaysShow = true; app.RefreshAsync().GetAwaiter().GetResult();
                var priorFamily = app.TrayIconFamilies[0];
                app.RefreshAsync().GetAwaiter().GetResult();
                Check(!ReferenceEquals(priorFamily, app.TrayIconFamilies[0]));
                foreach (var trayIcon in app.NotificationIcons) Equal(trayIcon.Icon!.Width, app.TrayIconSize);
                using var panel = new PanelForm(app); using var settings = new SettingsForm(app);
                void Save(Form form, string name)
                {
                    form.Show(); form.Refresh(); using var bitmap = new System.Drawing.Bitmap(form.Width, form.Height);
                    form.DrawToBitmap(bitmap, new System.Drawing.Rectangle(0, 0, form.Width, form.Height));
                    foreach (Control control in form.Controls)
                    {
                        if (control is not PillButton && control is not Toggle) continue;
                        foreach (var point in new[] { new System.Drawing.Point(control.Left, control.Top), new(control.Right - 1, control.Top), new(control.Left, control.Bottom - 1), new(control.Right - 1, control.Bottom - 1) })
                            Equal(bitmap.GetPixel(point.X, point.Y).ToArgb(), control.BackColor.ToArgb());
                    }
                    bitmap.Save(Path.Combine(directory, name + "-" + theme + "-" + lang + ".png")); form.Hide();
                }
                Save(panel, "panel"); settings.SelectPage(false); Save(settings, "settings-subs"); settings.SelectPage(true); Save(settings, "settings-general");
            }
        });
        AsyncTest("Claude subscription windows and plan", async () =>
        {
            using var provider = Make(Vendor.Claude, new Handler(_ => Response("{\"five_hour\":{\"utilization\":65,\"resets_at\":\"2026-10-23T00:00:00Z\"},\"seven_day\":{\"utilization\":39}}")), new Source(new Credential(Secret, plan: Plan.Pro)));
            var snapshot = await provider.FetchAsync(); Equal(snapshot.FiveHour.Percent, 35d); Equal(snapshot.Weekly.Percent, 61d); Equal(snapshot.Plan, Plan.Pro); Check(snapshot.FiveHour.Reset.HasValue);
        });
        AsyncTest("Grok expired credential renews before request", async () =>
        {
            var handler = new Handler(_ => Response(Billing)); var renewal = new Renewal(new Credential(Jwt, "user", "client", Clock.Now.AddHours(1)));
            using var provider = Make(Vendor.Grok, handler, new Source(new Credential(Secret, "user", "client", Clock.Now.AddSeconds(-1))), renewal);
            var result = await provider.FetchAsync(); Equal(result.Fault, Fault.None); Equal(handler.Count, 1); Equal(renewal.Count, 1); Equal(result.Weekly.Percent, 22d); Equal(result.FiveHour.Percent, null);
        });
        AsyncTest("Grok 401 refreshes and retries once", async () =>
        {
            var handler = new Handler(n => n == 1 ? Response(Secret, HttpStatusCode.Unauthorized) : Response(Billing), (request, n) => Check(request.Headers.Authorization?.Parameter == (n == 1 ? Secret : Jwt))); var renewal = new Renewal(new Credential(Jwt, "user", "client", Clock.Now.AddHours(2)));
            using var provider = Make(Vendor.Grok, handler, ValidSource(), renewal); var result = await provider.FetchAsync(); Equal(result.Fault, Fault.None); Equal(handler.Count, 2); Equal(renewal.Count, 1);
        });
        AsyncTest("Grok persistent 401 stops after single retry", async () =>
        {
            var handler = new Handler(_ => Response(Secret, HttpStatusCode.Unauthorized)); var renewal = new Renewal(new Credential(Jwt, "user", "client", Clock.Now.AddHours(2)));
            using var provider = Make(Vendor.Grok, handler, ValidSource(), renewal); Equal((await provider.FetchAsync()).Fault, Fault.SignIn); Equal(handler.Count, 2); Equal(renewal.Count, 1);
        });
        AsyncTest("pre-expiry renewal is not repeated after 401", async () =>
        {
            var handler = new Handler(_ => Response(Secret, HttpStatusCode.Unauthorized)); var renewal = new Renewal(new Credential(Jwt, "user", "client", Clock.Now.AddHours(2)));
            using var provider = Make(Vendor.Grok, handler, new Source(new Credential(Secret, "user", "client", Clock.Now.AddHours(-1))), renewal);
            Equal((await provider.FetchAsync()).Fault, Fault.SignIn); Equal(handler.Count, 1); Equal(renewal.Count, 1);
        });
        AsyncTest("Grok refuses account-changing refresh", async () =>
        {
            using var provider = Make(Vendor.Grok, new Handler(_ => Response("", HttpStatusCode.Unauthorized)), ValidSource(), new Renewal(new Credential(Jwt, "different-user", "client", Clock.Now.AddHours(2))));
            Equal((await provider.FetchAsync()).Fault, Fault.RefreshFailed);
        });
        AsyncTest("Grok CLI refresh protocol and readback", async () =>
        {
            var source = new Source(new Credential(Secret, "user", "client", Clock.Now.AddHours(2))); var rpc = new FakeRpc((id, _) => Parse("{}"));
            var renew = new GrokCliRefresh(source, Clock, _ => rpc); var result = await renew.RefreshAsync(new Credential(Secret, "user", "client", Clock.Now.AddHours(-1)), default);
            Check(rpc.Methods.SequenceEqual(new[] { "initialize", "_x.ai/auth/getBearerToken" })); Check(rpc.Disposed); Check(result.Expires > Clock.Now);
        });
        AsyncTest("Codex RPC parses only subscription and correct durations", async () =>
        {
            var rpc = CodexRpc(); var redactor = new Redactor(); var provider = new CodexProvider(Clock, new(redactor), () => rpc);
            var snapshot = await provider.FetchAsync(); Equal(snapshot.Plan, Plan.Plus); Equal(snapshot.FiveHour.Percent, 72d); Equal(snapshot.Weekly.Percent, 58d); Check(rpc.Disposed);
        });
        AsyncTest("Codex rejects API key account", async () =>
        {
            var rpc = new FakeRpc((id, _) => Parse(id == 2 ? "{\"account\":{\"type\":\"apiKey\"}}" : "{}"));
            var provider = new CodexProvider(Clock, new(new()), () => rpc); Equal((await provider.FetchAsync()).Fault, Fault.SignIn);
        });
        Test("Grok cache validity and no invented 5-hour window", () =>
        {
            var cache = new GrokBotCache(Clock); var root = Parse(CacheJson(Clock.Now.AddHours(1)));
            var snapshot = cache.Parse(root); Equal(snapshot.Weekly.Percent, 22d); Equal(snapshot.FiveHour.Percent, null); Equal(snapshot.Plan, Plan.SuperGrok);
            Equal(cache.Parse(Parse(CacheJson(Clock.Now.AddMinutes(-1)))).Fault, Fault.CacheExpired);
        });
        AsyncTest("full provider / renewal / failure secret containment", async () =>
        {
            var outputs = new List<string>(); var stdout = Console.Out; var stderr = Console.Error; using var capture = new StringWriter(); Console.SetOut(capture); Console.SetError(capture);
            try
            {
                for (int scenario = 0; scenario < 7; scenario++)
                {
                    int selected = scenario;
                    var redactor = new Redactor(); var log = new SafeLog(redactor, outputs.Add);
                    var handler = new Handler(n => selected switch
                    {
                        0 => Response(Billing.Replace("SuperGrok", Secret)),
                        1 => n == 1 ? Response(Secret, HttpStatusCode.Unauthorized) : Response(Billing),
                        2 => Response(Jwt, HttpStatusCode.InternalServerError),
                        3 => throw new HttpRequestException(Secret + Jwt),
                        4 => Response("{\"five_hour\":{\"utilization\":\"" + Secret + "\"}}"),
                        5 => Response("{\"unclosed\":\"" + Jwt),
                        _ => Response(Secret, HttpStatusCode.Unauthorized)
                    });
                    var renewal = new Renewal(new Credential(Jwt, "user", "client", Clock.Now.AddHours(2))) { Fail = selected == 6 };
                    using var provider = new SubscriptionProvider(selected == 4 ? Vendor.Claude : Vendor.Grok, ValidSource(), Clock, redactor, log, handler, renewal);
                    var result = await provider.FetchAsync(); outputs.Add(result.ToString()); outputs.Add(provider.ToString()!); outputs.Add(JsonSerializer.Serialize(result));
                    foreach (string lang in new[] { "en", "zh-CN" }) { var text = new Texts(lang); outputs.Add(text.Status(result)); outputs.Add(text.PlanName(result.Plan)); outputs.Add(text.Error(result.Fault)); }
                }
                var badRpc = new FakeRpc((_, _) => throw new Exception(Secret + Jwt));
                var codex = new CodexProvider(Clock, new(new(), outputs.Add), () => badRpc); outputs.Add((await codex.FetchAsync()).ToString());
                var refresh = new GrokCliRefresh(ValidSource(), Clock, _ => new FakeRpc((_, _) => throw new Exception(Secret + Jwt)));
                try { await refresh.RefreshAsync(new Credential(Secret), default); } catch (Exception error) { outputs.Add(error.Message); outputs.Add(error.ToString()); }
                outputs.Add(capture.ToString()); NoSecrets(outputs.ToArray());
            }
            finally { Console.SetOut(stdout); Console.SetError(stderr); }
        });
        Console.WriteLine($"Summary: {passed} PASS, {failed} FAIL"); return failed == 0 ? 0 : 1;
    }
    private static string CacheJson(DateTimeOffset expiry) => JsonSerializer.Serialize(new { schemaVersion = 2, value = new { kind = "present", expiresAtMs = expiry.ToUnixTimeMilliseconds(), reading = new { readAtMs = Clock.Now.AddHours(-1).ToUnixTimeMilliseconds(), usage = new { percentUsed = 78, hasNonZeroIncludedLimit = true, nextResetMs = Clock.Now.AddDays(5).ToUnixTimeMilliseconds(), grokPlanLabel = "SuperGrok" } } } });
    private static FakeRpc CodexRpc() => new((id, _) => Parse(id switch { 2 => "{\"account\":{\"type\":\"chatgpt\",\"planType\":\"plus\"}}", 3 => "{\"rateLimits\":{\"primary\":{\"usedPercent\":28,\"windowDurationMins\":300},\"secondary\":{\"usedPercent\":42,\"windowDurationMins\":10080}}}", _ => "{}" }));
    private static Source ValidSource() => new(new Credential(Secret, "user", "client", Clock.Now.AddHours(1)));
    private static SubscriptionProvider Make(Vendor vendor, Handler handler, Source source, IGrokRefresh? renewal = null) { var redactor = new Redactor(); return new(vendor, source, Clock, redactor, new(redactor), handler, renewal); }
    private static JsonElement Parse(string value) { using var document = JsonDocument.Parse(value); return document.RootElement.Clone(); }
    private static HttpResponseMessage Response(string text, HttpStatusCode status = HttpStatusCode.OK) => new(status) { Content = new StringContent(text, Encoding.UTF8, "application/json") };
    private static void NoSecrets(params string[] values) { foreach (string value in values) { Check(!value.Contains(Secret)); Check(!value.Contains(Jwt)); } }
    private sealed class FakeOverflowCloser : IOverflowCloser
    {
        public bool Visible { get; set; } = true;
        public bool FailVisibility { get; init; }
        public bool FailInvoke { get; init; }
        public bool FailEscape { get; init; }
        public bool CloseOnInvoke { get; init; }
        public bool CloseOnEscape { get; init; }
        public List<string> Calls { get; } = [];
        public bool IsVisible() => FailVisibility ? throw new InvalidOperationException(Secret) : Visible;
        public Task InvokeChevronAsync()
        {
            Calls.Add("invoke");
            if (FailInvoke) return Task.FromException(new System.Windows.Automation.ElementNotAvailableException(Secret));
            if (CloseOnInvoke) Visible = false;
            return Task.CompletedTask;
        }
        public void Escape()
        {
            Calls.Add("escape");
            if (FailEscape) throw new InvalidOperationException(Secret);
            if (CloseOnEscape) Visible = false;
        }
        public Task SettleAsync() => Task.CompletedTask;
    }
    private static void Check(bool condition) { if (!condition) throw new InvalidOperationException("Assertion failed."); }
    private static void Equal<T>(T actual, T expected) => Check(EqualityComparer<T>.Default.Equals(actual, expected));
    private static void Throws(Action action) { try { action(); } catch { return; } throw new InvalidOperationException("Expected failure."); }
    private static void Test(string name, Action action) { try { action(); passed++; Console.WriteLine("PASS " + name); } catch { failed++; Console.WriteLine("FAIL " + name); } }
    private static void AsyncTest(string name, Func<Task> action) => Test(name, () => action().GetAwaiter().GetResult());
    private sealed class FakeClock : IClock { public DateTimeOffset Now { get; private set; } = new(2026, 10, 22, 12, 0, 0, TimeSpan.Zero); public void Advance(double seconds) => Now = Now.AddTicks((long)Math.Round(seconds * TimeSpan.TicksPerSecond)); }
    private sealed class FakeRegistry : IRunRegistry { public Dictionary<string, string> Values { get; } = []; public List<string> Touched { get; } = []; public void Set(string name, string value) { Touched.Add(name); Values[name] = value; } public void Remove(string name) { Touched.Add(name); Values.Remove(name); } }
    private sealed class Source(Credential value) : ICredentialSource { public Task<Credential?> ReadAsync(Vendor vendor, CancellationToken cancellation) => Task.FromResult<Credential?>(value); }
    private sealed class Renewal(Credential value) : IGrokRefresh { public int Count { get; private set; } public bool Fail { get; init; } public Task<Credential> RefreshAsync(Credential expected, CancellationToken cancellation) { Count++; return Fail ? Task.FromException<Credential>(new Exception(Secret + Jwt)) : Task.FromResult(value); } }
    private sealed class Handler(Func<int, HttpResponseMessage> response, Action<HttpRequestMessage, int>? inspect = null) : HttpMessageHandler { public int Count { get; private set; } protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellation) { Count++; inspect?.Invoke(request, Count); var result = response(Count); result.RequestMessage = request; return Task.FromResult(result); } }
    private sealed class FakeRpc(Func<int, string, JsonElement> response) : IRpcSession { public List<string> Methods { get; } = []; public bool Disposed { get; private set; } public Task<JsonElement> CallAsync(int id, string method, object? parameters, CancellationToken cancellation) { Methods.Add(method); return Task.FromResult(response(id, method)); } public Task NotifyAsync(string method, CancellationToken cancellation) => Task.CompletedTask; public ValueTask DisposeAsync() { Disposed = true; return ValueTask.CompletedTask; } }
}




