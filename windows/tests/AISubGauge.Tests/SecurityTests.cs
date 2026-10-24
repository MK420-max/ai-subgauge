using AISubGauge.Core;
using AISubGauge.UI;
using System.Windows.Forms;
using System.Security.Cryptography.X509Certificates;

internal static partial class Program
{
    private static void RunSecurityTests()
    {
        RunTrustAndLockTests();
        RunCodexVerificationTests();
        Test("failing autostart registry leaves refresh and both timers running; Settings shows error", () =>
        {
            var messages = new List<string>();
            using var app = new AISubGauge.UI.AppContext(Options.Parse(["--demo", "--autostart", "--lang", "en"]), new FailingRegistry(), new(new(), messages.Add));
            Application.DoEvents();
            Check(app.AutostartFailed); Check(app.TimersRunning); Check(app.Updated is not null);
            Equal(messages.Single(), "AutostartFailed");
            app.SettingsWindow.SelectPage(true);
            var toggle = app.SettingsWindow.Controls.OfType<Toggle>().Single(t => t.AccessibleName == app.Text["Autostart"]);
            Check(toggle.Error); Equal(toggle.AccessibleDescription, app.Text["AutostartFailed"]);
            app.RefreshAsync().GetAwaiter().GetResult(); Check(app.TimersRunning);
        });
        Test("autostart failure clears after successful retry, including disable failures", () =>
        {
            var registry = new FailingRegistry(); var messages = new List<string>();
            var state = new AutostartState(registry, new(new(), messages.Add));
            state.Apply(false, "test.exe"); Check(state.Failed);
            registry.Fail = false; state.Apply(false, "test.exe"); Check(!state.Failed);
            Equal(messages.Single(), "AutostartFailed");
        });
        Test("diagnostic sink failure cannot break startup or cleanup", () =>
        {
            var log = new SafeLog(new(), _ => throw new IOException(Secret));
            var state = new AutostartState(new FailingRegistry(), log);
            state.Apply(true, "test.exe"); Check(state.Failed);
            RefreshCleanup.TryDelete("unused", log, _ => throw new IOException(Secret));
        });
        Test("refresh cleanup failure logs only fixed status", () =>
        {
            var messages = new List<string>();
            RefreshCleanup.TryDelete("sensitive-path", new(new(), messages.Add), _ => throw new IOException(Secret));
            Equal(messages.Single(), "RefreshCleanupFailed");
        });
        var locations = new CliLocations(@"C:\Fixture\Local", @"C:\Fixture\Roaming", @"C:\Fixture\Profile");
        string known = Path.Combine(locations.Local, "OpenAI", "Codex", "bin", "abcdef123456", "codex.exe");
        string grok = Path.Combine(locations.Profile, ".grok", "bin", "grok.exe");
        Test("Codex accepts signed known location and retains file lease until launch", () =>
        {
            var files = new FakeExecutableFiles(known); var verifier = new FakeSignatures(SignedFixture("O=\"OpenAI OpCo, LLC\""));
            var resolver = new ExecutableResolver(files, verifier, locations);
            using (var exe = resolver.Resolve("codex")) { Equal(exe.Path, known); Check(!exe.Custom); Check(files.LastLease!.CanRead); }
            Check(!files.LastLease!.CanRead); Equal(verifier.Calls, 1);
        });
        Test("Codex rejects invalid signatures and signed files from another publisher", () =>
        {
            foreach (var signature in new[] { new ExecutableSignature(SignatureStatus.Invalid), SignedFixture("CN=Other") })
            {
                var files = new FakeExecutableFiles(known);
                Throws(() => new ExecutableResolver(files, new FakeSignatures(signature), locations).Resolve("codex"));
                Check(!files.LastLease!.CanRead);
            }
        });
        Test("Codex overrides require valid OpenAI signature and expose custom-path flag", () =>
        {
            const string custom = @"C:\Fixture\Custom\codex.exe";
            foreach (var signature in new[] { new ExecutableSignature(SignatureStatus.Unsigned), new ExecutableSignature(SignatureStatus.Invalid), SignedFixture("CN=Other") })
                Throws(() => new ExecutableResolver(new FakeExecutableFiles(custom), new FakeSignatures(signature), locations).Resolve("codex", custom));
            using var exe = new ExecutableResolver(new FakeExecutableFiles(custom), new FakeSignatures(SignedFixture("CN=OpenAI, O=\"OpenAI OpCo, LLC\"")), locations).Resolve("codex", custom);
            Check(exe.Custom); Equal(exe.Path, custom);
        });
        Test("Codex ignores PATH and candidates outside known locations, including traversal", () =>
        {
            foreach (string untrusted in new[] { @"C:\Fixture\Untrusted\codex.exe", Path.Combine(locations.Local, "OpenAI", "Codex", "bin", "..", "outside", "codex.exe"), Path.Combine(locations.Local, "OpenAI", "Codex", "bin", "not-a-hash", "codex.exe") })
            {
                var files = new FakeExecutableFiles(untrusted);
                Throws(() => new ExecutableResolver(files, new FakeSignatures(SignedFixture("O=\"OpenAI OpCo, LLC\"")), locations).Resolve("codex"));
                Check(!files.Opened.Contains(untrusted));
            }
        });
        Test("Codex supports official npm global native package paths", () =>
        {
            string path = Path.Combine(locations.Roaming, "npm", "node_modules", "@openai", "codex-win32-x64", "vendor", "x86_64-pc-windows-msvc", "codex", "codex.exe");
            using var exe = new ExecutableResolver(new FakeExecutableFiles(path), new FakeSignatures(new(SignatureStatus.Unsigned)), locations).Resolve("codex", allowUnsignedCodexNpm: true);
            Equal(exe.Path, path); Check(exe.Unsigned);
        });
        Test("Grok overrides stay in known locations and expose custom-path flag", () =>
        {
            var resolver = new ExecutableResolver(new FakeExecutableFiles(grok), new FakeSignatures(new(SignatureStatus.Unsigned)), locations);
            using var standard = resolver.Resolve("grok"); Check(!standard.Custom);
            using var custom = resolver.Resolve("grok", grok); Check(custom.Custom);
            Throws(() => resolver.Resolve("grok", @"C:\Fixture\Untrusted\grok.exe"));
        });
        Test("unsafe file open or verifier errors fail closed without leaking details", () =>
        {
            var files = new FakeExecutableFiles(known) { FailOpen = true };
            Throws(() => new ExecutableResolver(files, new FakeSignatures(new(SignatureStatus.Unsigned)), locations).Resolve("codex"));
            files.FailOpen = false;
            Throws(() => new ExecutableResolver(files, new FakeSignatures(new(SignatureStatus.Unsigned)) { Fail = true }, locations).Resolve("codex"));
            Check(!files.LastLease!.CanRead);
        });
        Test("native WinVerifyTrust recognizes unsigned build assembly without executing it", () =>
        {
            Equal(new AuthenticodeSignatures().Verify(typeof(Startup).Assembly.Location).Status, SignatureStatus.Unsigned);
        });
    }
    private sealed class FailingRegistry : IRunRegistry
    {
        public bool Fail { get; set; } = true;
        public void Set(string name, string value) { if (Fail) throw new UnauthorizedAccessException(Secret); }
        public void Remove(string name) { if (Fail) throw new UnauthorizedAccessException(Secret); }
    }
    private sealed class FakeExecutableFiles(params string[] paths) : IExecutableFiles
    {
        public bool FailOpen { get; set; }
        public MemoryStream? LastLease { get; private set; }
        public List<string> Opened { get; } = [];
        public IEnumerable<string> Directories(string path) => paths.Select(p => Path.GetDirectoryName(p)!);
        public Stream OpenRead(string path)
        {
            Opened.Add(path);
            if (FailOpen || !paths.Contains(path)) throw new IOException(Secret);
            return LastLease = new MemoryStream();
        }
    }
    private sealed class FakeSignatures(ExecutableSignature signature) : IExecutableSignatures
    {
        public bool Fail { get; init; }
        public int Calls { get; private set; }
        public ExecutableSignature Verify(string path) { Calls++; return Fail ? throw new IOException(Secret) : signature; }
    }
}
