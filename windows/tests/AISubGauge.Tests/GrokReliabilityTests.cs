using AISubGauge.Core;
using AISubGauge.UI;
using System.Net;
using System.Security.Cryptography.X509Certificates;

internal static partial class Program
{
    private sealed class ScriptedRenewal(Func<int, Credential, Credential> action) : IGrokRefresh
    {
        internal int Count { get; private set; }
        public Task<Credential> RefreshAsync(Credential expected, CancellationToken cancellation) => Task.FromResult(action(++Count, expected));
    }
    private static SubscriptionProvider Reliable(FakeClock clock, ICredentialSource source, IGrokRefresh refresh,
        GrokLastGoodStore? store = null) => new(Vendor.Grok, source, clock, new(), new(new()),
            new Handler(_ => Response(Billing)), refresh, lastGoodStore: store, jitter: () => 0);

    private static void RunGrokReliabilityTests()
    {
        RunVerifierReliabilityTests();
        AsyncTest("expired token + refresh 401 preserves last-good timestamp and offers bilingual sign-in", async () =>
        {
            var clock = new FakeClock();
            var source = new ChangingSource(new Credential(Secret, "user", "client", clock.Now.AddHours(1)));
            var refresh = new ScriptedRenewal((_, _) => throw RpcSession.RpcError(Parse("{\"code\":401}")));
            using var provider = Reliable(clock, source, refresh);
            var good = await provider.FetchAsync(); Equal(good.Weekly.Percent, 22d);
            clock.Advance(3601);
            var stale = await provider.FetchAsync();
            Equal(stale.GrokState, GrokState.SignInExpired); Equal(stale.Fault, Fault.SignIn);
            Check(stale.Stale); Equal(stale.Weekly, good.Weekly); Equal(stale.Updated, good.Updated);
            Check(Presentation.CanSignInAgain(stale));
            foreach (string language in new[] { "zh-CN", "en" })
            {
                var text = new Texts(language); string message = text.Status(stale);
                Check(message.Contains(language == "zh-CN" ? "登录已过期，点重新登录" : "Sign-in expired — click Sign in again"));
                Check(message.Contains("22%")); Check(message.Contains(good.Updated.LocalDateTime.ToString("HH:mm")));
                Check(text.TrayStatus(stale).Contains(text["GrokSignInExpired"]));
                Check(text.TrayStatus(stale).Contains("22%"));
                Equal(CodexRowPresentation.SettingsStatus(text, stale), message);
                Equal(CodexRowPresentation.PanelStatus(text, stale, clock.Now), message);
            }
            clock.Advance(86400); await provider.FetchAsync(); Equal(refresh.Count, 1);
            source.Value = new Credential(Jwt, "user", "client", clock.Now.AddHours(2));
            var recovered = await provider.FetchAsync(); Check(!recovered.Stale); Equal(recovered.GrokState, GrokState.Ready);
            Equal(provider.RefreshPolicy.Failures, 0);
        });
        AsyncTest("transient RPC failures back off 30/60/120/300/600/900 seconds, retain stale and recover", async () =>
        {
            var clock = new FakeClock(); var source = new Source(new Credential(Secret, "user", "client", clock.Now.AddMinutes(31)));
            var refresh = new ScriptedRenewal((n, _) => n <= 7
                ? throw new HttpRequestException("synthetic transient", null, HttpStatusCode.ServiceUnavailable)
                : new Credential(Jwt, "user", "client", clock.Now.AddHours(2)));
            using var provider = Reliable(clock, source, refresh);
            var good = await provider.FetchAsync(); clock.Advance(60);
            int count = 0;
            foreach (int seconds in new[] { 30, 60, 120, 300, 600, 900, 900 })
            {
                var failed = await provider.FetchAsync(); ++count;
                Equal(refresh.Count, count); Check(failed.Stale); Equal(failed.Updated, good.Updated);
                Equal(failed.Weekly.Percent, 22d); Equal(failed.Fault, Fault.Network);
                Equal(provider.NextBackgroundRefresh, clock.Now.AddSeconds(seconds));
                if (count >= GrokRefreshPolicy.SignInThreshold) Equal(failed.GrokState, GrokState.SignInExpired);
                else Equal(failed.GrokState, GrokState.Retrying);
                clock.Advance(seconds - .01); await provider.FetchAsync(); Equal(refresh.Count, count);
                clock.Advance(.01);
            }
            var recovered = await provider.FetchAsync(); Equal(refresh.Count, 8);
            Equal(recovered.Fault, Fault.None); Check(!recovered.Stale); Equal(recovered.GrokState, GrokState.Ready);
            Equal(provider.RefreshPolicy.Failures, 0); Equal(provider.RefreshPolicy.LastFailure, null);
            Check(recovered.Updated > good.Updated);
        });
        AsyncTest("background deadline fires 30 minutes before expiry with fake clock", async () =>
        {
            var clock = new FakeClock(); var expires = clock.Now.AddMinutes(31);
            var refresh = new ScriptedRenewal((_, _) => new Credential(Jwt, "user", "client", clock.Now.AddHours(2)));
            using var provider = Reliable(clock, new Source(new Credential(Secret, "user", "client", expires)), refresh);
            await provider.FetchAsync(); Equal(refresh.Count, 0); Equal(provider.NextBackgroundRefresh, expires.AddMinutes(-30));
            clock.Advance(59); Check(provider.NextBackgroundRefresh > clock.Now);
            clock.Advance(1); Check(provider.NextBackgroundRefresh <= clock.Now); Check(clock.Now < expires);
            await provider.FetchAsync(); Equal(refresh.Count, 1); Equal(provider.NextBackgroundRefresh, clock.Now.AddMinutes(90));
        });
        AsyncTest("unchanged near-expiry token schedules expiry deadline without a refresh spin", async () =>
        {
            var clock = new FakeClock(); var credential = new Credential(Secret, "user", "client", clock.Now.AddMinutes(1));
            var refresh = new ScriptedRenewal((_, expected) => expected);
            using var provider = Reliable(clock, new Source(credential), refresh);
            Equal((await provider.FetchAsync()).Fault, Fault.None); Equal(refresh.Count, 1);
            Equal(provider.NextBackgroundRefresh, credential.Expires!.Value);
            clock.Advance(59); Check(provider.NextBackgroundRefresh > clock.Now);
        });
        AsyncTest("repaired CLI recovers after capped retry without credential change", async () =>
        {
            var clock = new FakeClock();
            var refresh = new ScriptedRenewal((n, _) => n == 1
                ? throw new SafeFailure(Fault.GrokVerificationFailed, new(VerificationStatus.PublisherMismatch, ExecutableLocation.LocalAppData))
                : new Credential(Jwt, "user", "client", clock.Now.AddHours(2)));
            using var provider = Reliable(clock, new Source(new Credential(Secret, "user", "client", clock.Now.AddMinutes(31))), refresh);
            await provider.FetchAsync(); clock.Advance(60);
            var stale = await provider.FetchAsync(); Check(stale.Stale); Equal(stale.GrokState, GrokState.VerificationFailed);
            clock.Advance(899); await provider.FetchAsync(); Equal(refresh.Count, 1);
            clock.Advance(1); var recovered = await provider.FetchAsync(); Equal(refresh.Count, 2);
            Equal(recovered.GrokState, GrokState.Ready); Check(!recovered.Stale); Equal(provider.RefreshPolicy.Failures, 0);
        });
        Test("jitter is bounded, verifier busy retries, definitive failures stop", () =>
        {
            var clock = new FakeClock();
            foreach (double jitter in new[] { 0d, .5, 1 })
            {
                var policy = new GrokRefreshPolicy(clock, () => jitter);
                policy.Failed(new(Fault.VerifierUnresponsive, new(VerificationStatus.VerifierBusy, ExecutableLocation.LocalAppData)));
                Equal(policy.NextAttempt, clock.Now.AddSeconds(30 * (1 + .2 * jitter)));
                for (int i = 0; i < 10; ++i) policy.Failed(new(Fault.Network));
                Equal(policy.NextAttempt, clock.Now.AddMinutes(15));
                policy.Failed(new(Fault.SignIn)); Equal(policy.NextAttempt, DateTimeOffset.MaxValue);
                policy.Reset(); Equal(policy.Failures, 0); policy.ThrowIfWaiting();
            }
        });
        AsyncTest("expired token with verifier busy is retryable; wrong publisher stays a distinct verification state", async () =>
        {
            foreach (var status in new[] { VerificationStatus.VerifierBusy, VerificationStatus.VerifierTimeout, VerificationStatus.PublisherMismatch })
            {
                var clock = new FakeClock();
                var refresh = new ThrowingRefresh(new SafeFailure(status == VerificationStatus.PublisherMismatch
                    ? Fault.GrokVerificationFailed : Fault.VerifierUnresponsive, new(status, ExecutableLocation.LocalAppData, Stage: VerificationStage.Signature)));
                using var provider = Reliable(clock, new Source(new Credential(Secret, "user", "client", clock.Now.AddSeconds(-1))), refresh);
                var result = await provider.FetchAsync();
                if (status == VerificationStatus.PublisherMismatch)
                {
                    Equal(result.GrokState, GrokState.VerificationFailed); Check(!Presentation.CanSignInAgain(result));
                    Equal(new Texts("en").Status(result), "Grok CLI verification failed");
                    Equal(provider.NextBackgroundRefresh, clock.Now.AddMinutes(15));
                }
                else { Equal(result.GrokState, GrokState.SignInExpired); Equal(provider.NextBackgroundRefresh, clock.Now.AddSeconds(30)); }
            }
        });
        AsyncTest("last-good persists only quota/times and survives restart and failures", async () =>
        {
            var clock = new FakeClock(); string directory = HardeningDirectory();
            var store = new GrokLastGoodStore(directory, new(new()));
            using (var first = Reliable(clock, new Source(new Credential(Secret, "user", "client", clock.Now.AddHours(2))), new Renewal(new Credential(Jwt)), store))
                Equal((await first.FetchAsync()).Fault, Fault.None);
            string json = File.ReadAllText(Path.Combine(directory, "last-good.json")); NoSecrets(json);
            foreach (string forbidden in new[] { "Token", "UserId", "ClientId", "Plan", "user", "client" }) Check(!json.Contains(forbidden));
            using var second = Reliable(clock, new Source(new Credential(Secret, "user", "client", clock.Now.AddSeconds(-1))),
                new ThrowingRefresh(new SafeFailure(Fault.SignIn)), store);
            var result = await second.FetchAsync(); Check(result.Stale); Equal(result.Weekly.Percent, 22d);
            Equal(File.ReadAllText(Path.Combine(directory, "last-good.json")), json);
            File.WriteAllText(Path.Combine(directory, "last-good.json"), "{broken"); Equal(store.Load(), null);
        });
        Test("file-access diagnostic preserves exact closed status/stage and never exception messages", () =>
        {
            var locations = new CliLocations(@"C:\Fixture\Local", @"C:\Fixture\Roaming", @"C:\Fixture\Profile");
            var signatures = new FakeSignatures(GrokFixture());
            foreach (var status in new[] { VerificationStatus.AccessDenied, VerificationStatus.SharingViolation })
            {
                var resolver = new ExecutableResolver(new DeniedExecutableFiles(status), signatures, locations);
                try { using var executable = resolver.Resolve("grok"); Check(false); }
                catch (SafeFailure error)
                {
                    Equal(error.Verification!.Status, status); Equal(error.Verification.Stage, VerificationStage.OpenDirectory);
                    var output = new List<string>(); new SafeLog(new(), output.Add).Write(Vendor.Grok, error.Fault, verification: error.Verification);
                    Check(output.Single().Contains("verification=" + status)); Check(output.Single().Contains("verificationStage=OpenDirectory"));
                    Check(!output.Single().Contains("Fixture"));
                }
            }
            Equal(signatures.Calls, 0);
        });
        Test("Grok EV organization and pinned chain remain fail-closed", () =>
        {
            var valid = GrokFixture(); Check(GrokPublisher.Accepts(valid));
            foreach (var signature in new[]
            {
                valid with { Subject = new X500DistinguishedName("O=Evil, CN=X.AI LLC") },
                valid with { Subject = new X500DistinguishedName("O=X.AI LLC, O=Evil") },
                valid with { ChainThumbprints = ["LEAF", "WRONG", GrokPublisher.RootThumbprint] },
                valid with { ChainThumbprints = ["LEAF", GrokPublisher.IntermediateThumbprint, "WRONG"] },
                valid with { Status = SignatureStatus.Invalid }
            }) Check(!GrokPublisher.Accepts(signature));
        });
        Test("LocalStatus is timestamped in app.log even when observer throws", () =>
        {
            string directory = HardeningDirectory();
            var log = new SafeLog(new(), _ => throw new IOException(Secret), directory);
            log.Write(LocalStatus.VerifierBusyRepeated);
            string line = File.ReadAllLines(Path.Combine(directory, "app.log")).Single();
            Check(DateTimeOffset.TryParse(line.Split(' ')[0], out _)); Check(line.EndsWith("local=VerifierBusyRepeated")); NoSecrets(line);
        });
        Test("new reliability resources match strings-source", () =>
        {
            foreach (string line in File.ReadLines(Path.Combine(Environment.CurrentDirectory, "src", "AISubGauge.Core", "strings-source.txt")))
            {
                var parts = line.Split('|');
                if (parts[0] is not ("GrokSignInExpired" or "GrokVerificationShort" or "StaleValue" or "GrokVerifierRetrying")) continue;
                Equal(new Texts("zh-CN")[parts[0]], parts[1]); Equal(new Texts("en")[parts[0]], parts[2]);
            }
        });
        Test("stale expired UI renders both languages, full tooltip and existing sign-in links", () =>
        {
            string directory = Path.Combine(Environment.CurrentDirectory, "artifacts", "grok-reliability-ui");
            Directory.CreateDirectory(directory);
            foreach (string language in new[] { "zh", "en" })
            {
                using var app = new AISubGauge.UI.AppContext(Options.Parse(["--demo", "--autostart", "--lang", language]));
                Application.DoEvents(); app.Settings.AlwaysShow = true; app.RefreshAsync().GetAwaiter().GetResult();
                var snapshot = new Snapshot(Vendor.Grok, Plan.SuperGrok, new(), new(22), Clock.Now, Fault.Network)
                    { Stale = true, GrokState = GrokState.SignInExpired };
                app.Snapshots[(int)Vendor.Grok] = snapshot;
                using var icon = new NotifyIcon { Text = app.Text.TrayStatus(snapshot) };
                Check(icon.Text.Contains(app.Text["GrokSignInExpired"])); Check(icon.Text.Contains("22%"));
                using var panel = new PanelForm(app); app.SettingsWindow.SelectPage(false);
                panel.UpdateSignIn(); app.SettingsWindow.UpdateSignIn();
                foreach (var (form, name) in new (Form, string)[] { (panel, "panel"), (app.SettingsWindow, "settings") })
                {
                    form.Show(); form.Refresh();
                    Check(form.Controls.OfType<LinkLabel>().Single().Visible);
                    using var bitmap = new System.Drawing.Bitmap(form.Width, form.Height);
                    form.DrawToBitmap(bitmap, new System.Drawing.Rectangle(0, 0, form.Width, form.Height));
                    bitmap.Save(Path.Combine(directory, name + "-" + language + ".png")); form.Hide();
                }
            }
        });
    }
    private sealed class DeniedExecutableFiles(VerificationStatus status) : IExecutableFiles
    {
        public IEnumerable<string> Directories(string path) => [];
        public Stream OpenRead(string path)
        {
            VerificationTrace.Step(VerificationStage.OpenDirectory); throw new LocalFileFailure(status);
        }
    }
}
