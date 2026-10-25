using AISubGauge.Core;
using AISubGauge.UI;
using System.Diagnostics;
using System.Globalization;
using System.Net;
using System.Text.RegularExpressions;

internal static partial class Program
{
    private static void RunGrokSignInTests()
    {
        foreach (var status in new[] { HttpStatusCode.Unauthorized, HttpStatusCode.Forbidden })
        {
            AsyncTest($"Grok billing {(int)status} is localized sign-in expired, including retry", async () =>
            {
                using var provider = Make(Vendor.Grok, new Handler(_ => Response("ignored body", status)), ValidSource(),
                    new Renewal(new Credential(Jwt, "user", "client", Clock.Now.AddHours(2))));
                AssertExpired(await provider.FetchAsync(), Fault.SignIn);
            });
            AsyncTest($"HTTP exception {(int)status} retains auth classification for all shared providers", async () =>
            {
                foreach (var vendor in new[] { Vendor.Grok, Vendor.Claude })
                {
                    using var provider = Make(vendor, new Handler(_ => throw new HttpRequestException(Secret, null, status)), ValidSource());
                    var snapshot = await provider.FetchAsync(); Equal(snapshot.Fault, Fault.SignIn);
                    Equal(new Texts("en").Status(snapshot), vendor + " sign-in expired");
                }
            });
            AsyncTest($"Grok refresh HTTP {(int)status} is sign-in expired and retains stage/status", async () =>
            {
                var lines = new List<string>();
                var refresh = new ThrowingRefresh(new HttpRequestException(Secret, null, status));
                using var provider = new SubscriptionProvider(Vendor.Grok, ExpiredSource(), Clock, new(), new(new(), lines.Add),
                    new Handler(_ => throw new InvalidOperationException()), refresh);
                AssertExpired(await provider.FetchAsync(), Fault.SignIn);
                Check(lines.Single().Contains($"stage=refresh-http fault=SignIn http={(int)status}"));
            });
        }
        AsyncTest("Grok stale sign-in / failed refresh RPC stays expired without cache fallback", async () =>
        {
            var cache = new CountingCache(); var lines = new List<string>();
            var refresh = new GrokCliRefresh(ValidSource(), Clock, _ => new FakeRpc((_, _) => throw new Exception(Secret)));
            using var provider = new SubscriptionProvider(Vendor.Grok, ExpiredSource(), Clock, new(), new(new(), lines.Add),
                new Handler(_ => throw new InvalidOperationException()), refresh, cache);
            AssertExpired(await provider.FetchAsync(), Fault.RefreshFailed);
            Equal(cache.Count, 0); Check(lines.Single().Contains("stage=refresh-rpc fault=RefreshFailed"));
        });
        AsyncTest("Grok billing 401 then failed refresh logs each failing stage once", async () =>
        {
            var lines = new List<string>();
            using var provider = new SubscriptionProvider(Vendor.Grok, ValidSource(), Clock, new(), new(new(), lines.Add),
                new Handler(_ => Response("ignored", HttpStatusCode.Unauthorized)), new ThrowingRefresh(new Exception(Secret)));
            AssertExpired(await provider.FetchAsync(), Fault.RefreshFailed);
            Equal(lines.Count, 2);
            Check(lines[0].Contains("stage=billing-http fault=SignIn http=401"));
            Check(lines[1].Contains("stage=refresh-rpc fault=RefreshFailed"));
        });
        AsyncTest("Grok premature RPC EOF remains a refresh failure requiring sign-in", async () =>
        {
            var refresh = new GrokCliRefresh(ValidSource(), Clock, _ => new FakeRpc((_, _) => throw new SafeFailure(Fault.InvalidData)));
            using var provider = Make(Vendor.Grok, new Handler(_ => throw new InvalidOperationException()), ExpiredSource(), refresh);
            AssertExpired(await provider.FetchAsync(), Fault.RefreshFailed);
        });
        AsyncTest("Grok refresh RPC preserves structured HTTP auth and server errors", async () =>
        {
            foreach (int status in new[] { 401, 403, 503 })
            {
                var lines = new List<string>();
                var refresh = new GrokCliRefresh(ValidSource(), Clock, _ => new FakeRpc((_, _) =>
                    throw RpcSession.RpcError(Parse($"{{\"code\":-32000,\"data\":{{\"statusCode\":{status}}}}}"))));
                using var provider = new SubscriptionProvider(Vendor.Grok, ExpiredSource(), Clock, new(), new(new(), lines.Add),
                    new Handler(_ => throw new InvalidOperationException()), refresh);
                var snapshot = await provider.FetchAsync(); Equal(snapshot.Fault, status == 503 ? Fault.Network : Fault.SignIn);
                Check(lines.Single().Contains($"stage=refresh-http fault={snapshot.Fault} http={status}"));
            }
        });
        AsyncTest("Grok DNS / HTTP 5xx remain network in billing and refresh", async () =>
        {
            foreach (var status in new HttpStatusCode?[] { null, HttpStatusCode.ServiceUnavailable })
            {
                using var billing = Make(Vendor.Grok, new Handler(_ => throw new HttpRequestException(Secret, null, status)), ValidSource());
                Equal((await billing.FetchAsync()).Fault, Fault.Network);
                var refresh = new GrokCliRefresh(ValidSource(), Clock, _ => new FakeRpc((_, _) => throw new HttpRequestException(Secret, null, status)));
                using var provider = Make(Vendor.Grok, new Handler(_ => throw new InvalidOperationException()), ExpiredSource(), refresh);
                var snapshot = await provider.FetchAsync(); Equal(snapshot.Fault, Fault.Network);
                Equal(new Texts("zh-CN").Status(snapshot), "连接失败，请稍后刷新");
                Equal(new Texts("en").Status(snapshot), "Connection failed; try refreshing later");
            }
            using var server = Make(Vendor.Grok, new Handler(_ => Response("ignored", HttpStatusCode.InternalServerError)), ValidSource());
            Equal((await server.FetchAsync()).Fault, Fault.Network);
        });
        AsyncTest("Grok refresh cancellation remains timeout", async () =>
        {
            using var provider = Make(Vendor.Grok, new Handler(_ => throw new InvalidOperationException()), ExpiredSource(),
                new ThrowingRefresh(new OperationCanceledException()));
            Equal((await provider.FetchAsync()).Fault, Fault.Timeout);
        });
        AsyncTest("failure logs identify credential read and parse stages", async () =>
        {
            var lines = new List<string>();
            using var missing = new SubscriptionProvider(Vendor.Grok, new MissingCredentials(), Clock, new(), new(new(), lines.Add));
            AssertExpired(await missing.FetchAsync(), Fault.SignIn);
            Check(lines.Single().Contains("stage=read-credentials fault=SignIn")); lines.Clear();
            using var malformed = new SubscriptionProvider(Vendor.Grok, ValidSource(), Clock, new(), new(new(), lines.Add), new Handler(_ => Response("{broken")));
            Equal((await malformed.FetchAsync()).Fault, Fault.InvalidData);
            Check(lines.Single().Contains("stage=parse fault=InvalidData"));
        });
        AsyncTest("Grok renewed bearer cannot override credentials from a new login", async () =>
        {
            var original = new Credential(Secret, "user", "client", Clock.Now.AddHours(-1));
            var source = new ChangingSource(original);
            var renewal = new Renewal(new Credential(Jwt, "user", "client", Clock.Now.AddHours(3)));
            const string newToken = "synthetic-new-login";
            using var provider = new SubscriptionProvider(Vendor.Grok, source, Clock, new(), new(new()),
                new Handler(_ => Response(Billing), (request, n) => Equal(request.Headers.Authorization!.Parameter, n == 1 ? Jwt : newToken)), renewal);
            Equal((await provider.FetchAsync()).Fault, Fault.None);
            source.Value = new Credential(newToken, "user", "client", Clock.Now.AddHours(2));
            Equal((await provider.FetchAsync()).Fault, Fault.None); Equal(renewal.Count, 1);
        });
        AsyncTest("app.log is ISO timestamped and contains no credentials, identity, bodies or paths", async () =>
        {
            const string token = "xai-SECRET-TOKEN-123456", user = "sample-private-user-123", email = "private@example.test";
            string directory = LogTestDirectory();
            var log = new SafeLog(new(), directory: directory);
            foreach (bool exception in new[] { false, true })
            {
                using var provider = new SubscriptionProvider(Vendor.Grok, new Source(new Credential(token, user, email, Clock.Now.AddHours(1))), Clock, new(), log,
                    new Handler(_ => exception ? throw new HttpRequestException(token + user + email + directory, null, HttpStatusCode.Forbidden) : Response(token + user + email + directory, HttpStatusCode.Forbidden)));
                AssertExpired(await provider.FetchAsync(), Fault.SignIn);
            }
            string contents = File.ReadAllText(Path.Combine(directory, "app.log"));
            foreach (string forbidden in new[] { token, user, email, directory, "Authorization", "Bearer" }) Check(!contents.Contains(forbidden));
            var lines = File.ReadAllLines(Path.Combine(directory, "app.log")); Equal(lines.Length, 2);
            foreach (string line in lines)
            {
                Check(Regex.IsMatch(line, @"^\S+ vendor=Grok stage=billing-http fault=SignIn http=403$"));
                Check(DateTimeOffset.TryParseExact(line.Split(' ')[0], "O", CultureInfo.InvariantCulture, DateTimeStyles.None, out _));
            }
        });
        Test("log rotation overwrites only app.1.log and keeps two files", () =>
        {
            string directory = LogTestDirectory(); Directory.CreateDirectory(directory);
            var log = new SafeLog(new(), directory: directory);
            for (int i = 0; i < 3; i++)
            {
                File.WriteAllText(Path.Combine(directory, "app.log"), new string((char)('A' + i), SafeLog.MaxBytes + 1));
                log.Write(Vendor.Grok, Fault.SignIn, FailureStage.BillingHttp, 401);
                Equal(Directory.GetFiles(directory).Length, 2);
                Equal(File.ReadAllText(Path.Combine(directory, "app.1.log"))[0], (char)('A' + i));
                Equal(File.ReadAllLines(Path.Combine(directory, "app.log")).Length, 1);
            }
        });
        Test("log is thread-safe across instances and sinks / IO failures never escape", () =>
        {
            string directory = LogTestDirectory();
            Parallel.For(0, 200, _ => new SafeLog(new(), directory: directory).Write(Vendor.Grok, Fault.Network, FailureStage.BillingHttp));
            Equal(File.ReadAllLines(Path.Combine(directory, "app.log")).Length, 200);
            var broken = new SafeLog(new(), _ => throw new IOException(Secret), Path.Combine(directory, "app.log"));
            broken.Write(Vendor.Grok, Fault.Network); broken.Write(LocalStatus.RefreshCleanupFailed);
        });
        AsyncTest("Grok launcher uses validated path and login ArgumentList, retains lease and awaits exit", async () =>
        {
            var locations = new CliLocations(@"C:\Fixture\Local", @"C:\Fixture\Roaming", @"C:\Fixture\Profile With Spaces");
            string path = Path.Combine(locations.Profile, ".grok", "bin", "grok.exe");
            var files = new FakeExecutableFiles(path);
            var resolver = new ExecutableResolver(files, new FakeSignatures(new(SignatureStatus.Unsigned)), locations);
            var exited = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            int starts = 0;
            var launcher = new GrokSignIn(() => Task.FromResult(resolver.Resolve("grok")), info =>
            {
                starts++; Equal(info.FileName, path); Check(info.ArgumentList.SequenceEqual(new[] { "login" }));
                Equal(info.Arguments, ""); Check(!info.UseShellExecute && !info.CreateNoWindow);
                Check(!info.RedirectStandardInput && !info.RedirectStandardOutput && !info.RedirectStandardError);
                Equal(info.WindowStyle, ProcessWindowStyle.Normal); Check(files.LastLease!.CanRead);
                return exited.Task;
            });
            var pending = launcher.RunAsync(); Check(!pending.IsCompleted); Check(launcher.Running);
            Check(!await launcher.RunAsync()); Equal(starts, 1); Check(files.LastLease!.CanRead);
            exited.SetResult(); Check(await pending.ConfigureAwait(false)); Check(!launcher.Running); Check(!files.LastLease!.CanRead);
            Check(await launcher.RunAsync()); Equal(starts, 2);
        });
        AsyncTest("Grok launcher rejects unvalidated path and releases running gate after errors", async () =>
        {
            int starts = 0;
            var locations = new CliLocations(@"C:\Fixture\Local", @"C:\Fixture\Roaming", @"C:\Fixture\Profile");
            var resolver = new ExecutableResolver(new FakeExecutableFiles(@"C:\Fixture\evil.exe"), new FakeSignatures(new(SignatureStatus.Unsigned)), locations);
            var rejected = new GrokSignIn(() => Task.FromResult(resolver.Resolve("grok", @"C:\Fixture\evil.exe")), _ => { starts++; return Task.CompletedTask; });
            for (int i = 0; i < 2; i++)
            {
                try { await rejected.RunAsync(); Check(false); } catch (SafeFailure) { }
                Check(!rejected.Running); Equal(starts, 0);
            }
            var lease = new MemoryStream();
            var failing = new GrokSignIn(() => Task.FromResult(new VerifiedExecutable("fixture.exe", false, lease)), _ => throw new IOException(Secret));
            try { await failing.RunAsync(); Check(false); } catch (IOException) { }
            Check(!failing.Running); Check(!lease.CanRead);
        });
        Test("Grok popup/settings expose localized re-login only for sign-in faults", () =>
        {
            foreach (string lang in new[] { "zh", "en" })
            {
                using var app = new AISubGauge.UI.AppContext(Options.Parse(["--demo", "--autostart", "--lang", lang]));
                System.Windows.Forms.Application.DoEvents();
                app.Settings.AlwaysShow = true; app.RefreshAsync().GetAwaiter().GetResult();
                using var panel = new PanelForm(app); app.SettingsWindow.Show(); panel.Show();
                foreach (var fault in new[] { Fault.SignIn, Fault.RefreshFailed, Fault.Network, Fault.None })
                {
                    app.Snapshots[(int)Vendor.Grok] = Snapshot.Failure(Vendor.Grok, fault, Clock);
                    panel.UpdateSignIn(); app.SettingsWindow.UpdateSignIn();
                    bool expected = Presentation.SignInExpired(fault);
                    foreach (var form in new Form[] { panel, app.SettingsWindow })
                    {
                        var link = form.Controls.OfType<LinkLabel>().Single();
                        Equal(link.Visible, expected); Equal(link.Text, lang == "zh" ? "重新登录" : "Sign in again");
                    }
                    Check(!Presentation.CanSignInAgain(Snapshot.Failure(Vendor.Codex, fault, Clock)));
                }
                app.SettingsWindow.SelectPage(true); Check(!app.SettingsWindow.Controls.OfType<LinkLabel>().Any());
            }
        });
        Test("new localized resource keys match strings-source in both languages", () =>
        {
            foreach (string line in File.ReadLines(Path.Combine(Environment.CurrentDirectory, "src", "AISubGauge.Core", "strings-source.txt")))
            {
                var parts = line.Split('|');
                if (parts[0] is not ("SignInExpired" or "SignInAgain")) continue;
                Equal(new Texts("zh-CN")[parts[0]], parts[1]); Equal(new Texts("en")[parts[0]], parts[2]);
            }
        });
    }

    private static void AssertExpired(Snapshot snapshot, Fault expected)
    {
        Equal(snapshot.Fault, expected);
        foreach (string lang in new[] { "en", "zh-CN" })
        {
            var text = new Texts(lang); string message = lang == "en" ? "Grok sign-in expired" : "Grok 登录已过期";
            Equal(text.Status(snapshot), message); Equal(CodexRowPresentation.PanelStatus(text, snapshot, Clock.Now), message);
            Equal(CodexRowPresentation.SettingsStatus(text, snapshot), message);
        }
    }
    private static string LogTestDirectory() => Path.Combine(Environment.CurrentDirectory, "artifacts", "tests", "grok-log-" + Guid.NewGuid().ToString("N"));
    private static Source ExpiredSource() => new(new Credential(Secret, "user", "client", Clock.Now.AddHours(-1)));
    private sealed class ThrowingRefresh(Exception error) : IGrokRefresh
    { public Task<Credential> RefreshAsync(Credential expected, CancellationToken cancellation) => Task.FromException<Credential>(error); }
    private sealed class MissingCredentials : ICredentialSource
    { public Task<Credential?> ReadAsync(Vendor vendor, CancellationToken cancellation) => Task.FromResult<Credential?>(null); }
    private sealed class ChangingSource(Credential value) : ICredentialSource
    {
        public Credential Value { get; set; } = value;
        public Task<Credential?> ReadAsync(Vendor vendor, CancellationToken cancellation) => Task.FromResult<Credential?>(Value);
    }
    private sealed class CountingCache : IGrokCache
    {
        public int Count { get; private set; }
        public Task<Snapshot> ReadAsync(CancellationToken cancellation) { Count++; return Task.FromResult(Snapshot.Demo(Vendor.Grok, Clock)); }
    }
}
