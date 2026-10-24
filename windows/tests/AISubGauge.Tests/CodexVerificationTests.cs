using AISubGauge.Core;
using AISubGauge.UI;
using System.Diagnostics;

internal static partial class Program
{
    private static void RunCodexVerificationTests()
    {
        var locations = new CliLocations(@"C:\Fixture\Local", @"C:\Fixture\Roaming", @"C:\Fixture\Profile");
        string local = Path.Combine(locations.Local, "OpenAI", "Codex", "bin", "abcdef123456", "codex.exe");
        string npm = Path.Combine(locations.Roaming, "npm", "node_modules", "@openai", "codex", "vendor", "x86_64-pc-windows-msvc", "codex", "codex.exe");
        const string custom = @"C:\Fixture\Custom\codex.exe";
        var signed = SignedFixture("O=\"OpenAI OpCo, LLC\"");
        ExecutableResolver Resolver(string path, ExecutableSignature signature) => new(new FakeExecutableFiles(path), new FakeSignatures(signature), locations);
        Test("LocalAppData rejects unsigned, wrong organization and wrong root even with npm toggle on", () =>
        {
            foreach (var signature in new[] { new ExecutableSignature(SignatureStatus.Unsigned), SignedFixture("O=Other"),
                SignedFixture("O=\"OpenAI OpCo, LLC\"", "LEAF", CodexPublisher.IntermediateThumbprint, "WRONG-ROOT") })
                foreach (bool allow in new[] { false, true }) Throws(() => Resolver(local, signature).Resolve("codex", allowUnsignedCodexNpm: allow));
        });
        Test("npm unsigned is opt-in, persists and exposes localized Unsigned badge", () =>
        {
            Check(!new Settings().AllowUnsignedCodexNpm);
            var resolver = Resolver(npm, new(SignatureStatus.Unsigned));
            Throws(() => resolver.Resolve("codex"));
            using var exe = resolver.Resolve("codex", allowUnsignedCodexNpm: true);
            Equal(exe.Location, ExecutableLocation.Npm); Check(exe.Unsigned);
            Equal(CodexRowPresentation.Badge(new("en"), exe.Unsigned), "Unsigned");
            Equal(CodexRowPresentation.Badge(new("zh-CN"), exe.Unsigned), "未签名");
            var directory = Path.Combine(Directory.GetCurrentDirectory(), "artifacts", "settings-tests", Guid.NewGuid().ToString("N"));
            var store = new SettingsStore(directory); store.Save(new() { AllowUnsignedCodexNpm = true }); Check(store.Load().AllowUnsignedCodexNpm);
            store.Save(new()); Check(!store.Load().AllowUnsignedCodexNpm);
            Throws(() => resolver.Resolve("codex", npm, true)); // An override never gets the npm exception.
            Throws(() => Resolver(npm, SignedFixture("O=Other")).Resolve("codex", allowUnsignedCodexNpm: true));
        });
        Test("General page exposes default-off bilingual npm toggle", () =>
        {
            foreach (string lang in new[] { "en", "zh" })
            {
                using var app = new AISubGauge.UI.AppContext(Options.Parse(["--demo", "--autostart", "--lang", lang]));
                app.SettingsWindow.SelectPage(true);
                var toggle = app.SettingsWindow.Controls.OfType<Toggle>().Single(t => t.AccessibleName == app.Text["AllowUnsignedCodexNpm"]);
                Check(!toggle.Checked); Check(toggle.Bounds.Bottom < app.SettingsWindow.ClientSize.Height);
                toggle.Checked = true; Application.DoEvents(); Check(app.Settings.AllowUnsignedCodexNpm);
            }
        });
        Test("process-wide busy gate rejects immediately after timeout without a second native call", () =>
        {
            using var entered = new ManualResetEventSlim(); using var release = new ManualResetEventSlim();
            int calls = 0;
            var first = new AuthenticodeSignatures(new DelegateSignatures(_ => { Interlocked.Increment(ref calls); entered.Set(); release.Wait(); return signed; }), TimeSpan.FromMilliseconds(120));
            var second = new AuthenticodeSignatures(new DelegateSignatures(_ => { Interlocked.Increment(ref calls); return signed; }));
            try
            {
                Equal(first.Verify(local).Diagnostic, VerificationStatus.VerifierTimeout); Check(entered.IsSet);
                var watch = Stopwatch.StartNew();
                for (int i = 0; i < 20; i++)
                {
                    var result = second.Verify(local); Equal(result.Status, SignatureStatus.Invalid); Equal(result.Diagnostic, VerificationStatus.VerifierBusy);
                }
                Check(watch.Elapsed < TimeSpan.FromSeconds(1)); Equal(calls, 1);
            }
            finally { release.Set(); Check(SpinWait.SpinUntil(() => AuthenticodeSignatures.Idle, 2000)); }
            Equal(second.Verify(local), signed); Equal(calls, 2);
        });
        Test("busy diagnostic logs at three consecutive process-wide results once per streak and resets", () =>
        {
            var messages = new List<string>(); var log = new SafeLog(new(), messages.Add);
            var probe = new AuthenticodeSignatures(new FakeSignatures(signed), log: log);
            // The first incomplete streak must not contribute to the next one.
            foreach (int busyCalls in new[] { 2, 8, 8 })
            {
                using var entered = new ManualResetEventSlim(); using var release = new ManualResetEventSlim();
                var blocked = new AuthenticodeSignatures(new DelegateSignatures(_ => { entered.Set(); release.Wait(); return signed; }),
                    TimeSpan.FromMilliseconds(120), log);
                int before = messages.Count;
                try
                {
                    Equal(blocked.Verify(local).Diagnostic, VerificationStatus.VerifierTimeout); Check(entered.IsSet);
                    Equal(messages.Count, before); // Timeout does not count as busy.
                    for (int i = 1; i <= busyCalls; i++)
                    {
                        Equal((i % 2 == 0 ? blocked : probe).Verify(local).Diagnostic, VerificationStatus.VerifierBusy);
                        Equal(messages.Count, before + (i >= 3 ? 1 : 0));
                    }
                }
                finally { release.Set(); Check(SpinWait.SpinUntil(() => AuthenticodeSignatures.Idle, 2000)); }
                Equal(probe.Verify(local), signed); // A non-busy verification resets the streak.
            }
            Equal(messages.Count, 2); Check(messages.All(m => m == "VerifierBusyRepeated"));
        });
        AsyncTest("busy and timeout yield dedicated bilingual panel/settings restart message", async () =>
        {
            foreach (var status in new[] { VerificationStatus.VerifierBusy, VerificationStatus.VerifierTimeout })
            {
                int calls = 0;
                var resolver = new ExecutableResolver(new FakeExecutableFiles(local, npm), new DelegateSignatures(_ =>
                {
                    calls++; return new(SignatureStatus.Invalid, Diagnostic: status);
                }), locations);
                var provider = new CodexProvider(Clock, new(new()), resolve: () => Task.Run(() => resolver.Resolve("codex")));
                var snapshot = await provider.FetchAsync(); Equal(snapshot.Fault, Fault.VerifierUnresponsive);
                Equal(calls, 1); // Later candidates cannot overwrite the hang with another failure.
                foreach (string language in new[] { "en", "zh-CN" })
                {
                    var text = new Texts(language);
                    string expected = language == "en" ? "Signature check is not responding. Please restart AI SubGauge." : "签名校验未响应，请重启 AI SubGauge";
                    Equal(CodexRowPresentation.PanelStatus(text, snapshot, Clock.Now), expected);
                    Equal(CodexRowPresentation.SettingsStatus(text, snapshot), expected);
                    Check(expected != text.Error(Fault.VerificationFailed));
                }
            }
        });
        AsyncTest("injected offline and empty CRL cache yield the same fixed panel/settings failure text", async () =>
        {
            foreach (uint code in new uint[] { 0x800B010E, 0x80092013, 0x80092012 })
            {
                var verifier = new AuthenticodeSignatures(new DelegateSignatures(_ => AuthenticodeSignatures.NativeFailure(unchecked((int)code))));
                var resolver = new ExecutableResolver(new FakeExecutableFiles(local), verifier, locations);
                var provider = new CodexProvider(Clock, new(new()), resolve: () => Task.Run(() => resolver.Resolve("codex")));
                var snapshot = await provider.FetchAsync(); Equal(snapshot.Fault, Fault.VerificationFailed);
                foreach (string language in new[] { "en", "zh-CN" })
                {
                    var text = new Texts(language); string expected = language == "en" ? "CLI verification failed." : "CLI 验证失败。";
                    Equal(CodexRowPresentation.PanelStatus(text, snapshot, Clock.Now), expected);
                    Equal(CodexRowPresentation.SettingsStatus(text, snapshot), expected);
                }
            }
        });
        Test("verify-codex output and exit codes use the app resolver for all locations", () =>
        {
            void CheckOutput(Func<VerifiedExecutable> resolve, int code, string line)
            {
                using var output = new StringWriter(); Equal(CodexVerificationCommand.Run(resolve, output), code);
                Equal(output.ToString(), line + Environment.NewLine);
            }
            CheckOutput(() => Resolver(local, signed).Resolve("codex"), 0, "codex-verify: Accepted location=LocalAppData signer=OpenAI OpCo, LLC");
            CheckOutput(() => Resolver(custom, signed).Resolve("codex", custom), 0, "codex-verify: Accepted location=Override signer=OpenAI OpCo, LLC");
            CheckOutput(() => Resolver(npm, new(SignatureStatus.Unsigned)).Resolve("codex", allowUnsignedCodexNpm: true), 0, "codex-verify: Accepted location=Npm signer=-");
            CheckOutput(() => Resolver(npm, new(SignatureStatus.Unsigned)).Resolve("codex"), 4, "codex-verify: Rejected:Unsigned location=Npm signer=-");
            CheckOutput(() => Resolver(local, new(SignatureStatus.Unsigned)).Resolve("codex"), 4, "codex-verify: Rejected:Unsigned location=LocalAppData signer=-");
            CheckOutput(() => Resolver(local, SignedFixture("O=Other")).Resolve("codex"), 4, "codex-verify: Rejected:PublisherMismatch location=LocalAppData signer=-");
            CheckOutput(() => Resolver(local, SignedFixture("O=\"OpenAI OpCo, LLC\"", "LEAF", CodexPublisher.IntermediateThumbprint, "WRONG-ROOT")).Resolve("codex"), 4, "codex-verify: Rejected:PublisherMismatch location=LocalAppData signer=-");
            CheckOutput(() => new ExecutableResolver(new FakeExecutableFiles(), new FakeSignatures(signed), locations).Resolve("codex"), 4, "codex-verify: Rejected:NotFound location=None signer=-");
            CheckOutput(() => throw new IOException(Secret), 4, "codex-verify: Rejected:Invalid location=None signer=-");
            CheckOutput(() => throw new SafeFailure(Fault.VerificationFailed, new(VerificationStatus.Invalid, ExecutableLocation.Override, "bad\nlocation=private/path")), 4, "codex-verify: Rejected:Invalid location=Override signer=-");
        });
        Test("real WinExe self-check rejects invalid arguments before settings access and exits 4 without GUI", () =>
        {
            string root = Directory.GetCurrentDirectory();
            var info = new ProcessStartInfo(Path.Combine(root, "src", "AISubGauge2", "bin", "Release", "net8.0-windows", "AISubGauge2.exe"), "--verify-codex --invalid")
            { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true };
            // Invalid arguments return before the CLI loads real user settings. Missing
            // executables are covered by the injected resolver above; native verification
            // is separately tested against the unsigned build assembly.
            // Use the same already-installed runtime as the test host; do not rely on global registration.
            string runtimeRoot = Path.GetFullPath(Path.Combine(System.Runtime.InteropServices.RuntimeEnvironment.GetRuntimeDirectory(), "..", "..", ".."));
            info.Environment["DOTNET_ROOT"] = runtimeRoot;
            info.Environment["DOTNET_ROOT_" + System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture.ToString().ToUpperInvariant()] = runtimeRoot;
            info.Environment["DOTNET_DISABLE_GUI_ERRORS"] = "1";
            using var process = Process.Start(info)!;
            var stdout = process.StandardOutput.ReadToEndAsync(); var stderr = process.StandardError.ReadToEndAsync();
            if (!process.WaitForExit(15000)) { process.Kill(); throw new Exception("Self-check timed out."); }
            Equal(process.ExitCode, 4); Equal(stderr.GetAwaiter().GetResult(), "");
            Equal(stdout.GetAwaiter().GetResult(), "codex-verify: Rejected:Invalid location=None signer=-" + Environment.NewLine);
        });
    }
}
