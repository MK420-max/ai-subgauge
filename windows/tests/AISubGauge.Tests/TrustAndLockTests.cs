using AISubGauge.Core;
using AISubGauge.UI;
using System.Diagnostics;
using System.Formats.Asn1;
using System.Security.Cryptography.X509Certificates;

internal static partial class Program
{
    private static ExecutableSignature SignedFixture(string subject, params string[] chain) =>
        new(SignatureStatus.Valid, new X500DistinguishedName(subject), chain.Length == 0
            ? ["SYNTHETIC-LEAF", CodexPublisher.IntermediateThumbprint, CodexPublisher.RootThumbprint] : chain);

    private static void RunTrustAndLockTests()
    {
        Test("Codex exact organization with quoted comma is accepted; CN is irrelevant", () =>
        {
            Check(CodexPublisher.Accepts(SignedFixture("CN=OpenAI, O=\"OpenAI OpCo, LLC\", C=US")));
            Check(CodexPublisher.Accepts(SignedFixture("CN=Unrelated, O=\"OpenAI OpCo, LLC\"")));
        });
        Test("Codex rejects publisher substrings, missing O, CN-only O and duplicate O", () =>
        {
            foreach (string subject in new[]
            {
                "CN=OpenAI, O=NotOpenAI Ltd", "O=\"OpenAI OpCo, LLC Evil\"", "CN=OpenAI",
                "CN=\"OpenAI OpCo, LLC\"", "CN=\"O=OpenAI OpCo, LLC\"",
                "O=\"openai OpCo, LLC\"", "O=\"OpenAI OpCo, LLC\", O=Evil",
                "CN=\"Evil, O=OpenAI OpCo, LLC\""
            }) Check(!CodexPublisher.Accepts(SignedFixture(subject)));
        });
        Test("X500 decoded values reject escaped quotes, backslashes, whitespace and RDN injection", () =>
        {
            // Construct real DER values so quoting/escaping round trips cannot normalize an evil value.
            foreach (string value in new[]
            {
                "OpenAI OpCo, LLC", "\"OpenAI OpCo, LLC\"", @"OpenAI OpCo\, LLC",
                "OpenAI OpCo, LLC ", " OpenAI OpCo, LLC", "OpenAI OpCo, LLC\nO=Evil",
                "OpenAI OpCo, LLC\0Evil", "Evil\nO=OpenAI OpCo, LLC"
            })
            {
                var writer = new AsnWriter(AsnEncodingRules.DER);
                writer.PushSequence(); writer.PushSetOf(); writer.PushSequence();
                writer.WriteObjectIdentifier("2.5.4.10"); writer.WriteCharacterString(UniversalTagNumber.UTF8String, value);
                writer.PopSequence(); writer.PopSetOf(); writer.PopSequence();
                var signature = SignedFixture("CN=Fixture") with { Subject = new X500DistinguishedName(writer.Encode()) };
                Equal(CodexPublisher.Accepts(signature), value == CodexPublisher.Organization);
            }
        });
        Test("Codex requires terminal pinned root and a pinned intermediate between leaf and root", () =>
        {
            const string subject = "O=\"OpenAI OpCo, LLC\"";
            foreach (string[] chain in new string[][]
            {
                ["LEAF", CodexPublisher.IntermediateThumbprint, "WRONG-ROOT"],
                ["LEAF", "WRONG-INTERMEDIATE", CodexPublisher.RootThumbprint],
                ["LEAF", CodexPublisher.RootThumbprint],
                ["LEAF", CodexPublisher.RootThumbprint, CodexPublisher.IntermediateThumbprint],
                [CodexPublisher.IntermediateThumbprint, "OTHER", CodexPublisher.RootThumbprint]
            }) Check(!CodexPublisher.Accepts(SignedFixture(subject, chain)));
            Check(!CodexPublisher.Accepts(SignedFixture(subject) with { ChainThumbprints = null }));
            Check(!CodexPublisher.Accepts(SignedFixture(subject) with { Status = SignatureStatus.Invalid }));
            Check(!CodexPublisher.Accepts(SignedFixture(subject) with { Subject = null }));
        });
        Test("rotating leaf certificates do not change issuer pin acceptance", () =>
        {
            foreach (string leaf in new[] { "LEAF-ONE", "LEAF-TWO" })
                Check(CodexPublisher.Accepts(SignedFixture("O=\"OpenAI OpCo, LLC\"", leaf,
                    CodexPublisher.IntermediateThumbprint, CodexPublisher.RootThumbprint)));
        });
        Test("WinVerifyTrust flags retain revocation checking and disable network retrieval", () =>
        {
            Equal(AuthenticodeSignatures.CacheOnlyUrlRetrieval, 0x1000u);
            Equal(AuthenticodeSignatures.ProviderFlags, 0x1080u);
        });
        Test("verification runs off caller thread and preserves successful result", () =>
        {
            int caller = Environment.CurrentManagedThreadId, worker = caller;
            var expected = SignedFixture("O=\"OpenAI OpCo, LLC\"");
            var verifier = new AuthenticodeSignatures(new DelegateSignatures(_ => { worker = Environment.CurrentManagedThreadId; return expected; }));
            Equal(verifier.Verify("synthetic.exe"), expected); Check(worker != caller);
        });
        Test("hung verifier times out within budget, returns Invalid and discards late success", () =>
        {
            using var entered = new ManualResetEventSlim(); using var release = new ManualResetEventSlim();
            using var finished = new ManualResetEventSlim();
            var verifier = new AuthenticodeSignatures(new DelegateSignatures(_ =>
            {
                entered.Set(); release.Wait(); finished.Set(); return SignedFixture("O=\"OpenAI OpCo, LLC\"");
            }), TimeSpan.FromMilliseconds(150));
            try
            {
                var watch = Stopwatch.StartNew(); var result = verifier.Verify("synthetic.exe");
                Check(entered.IsSet); Check(watch.Elapsed < TimeSpan.FromSeconds(2));
                Equal(result, new ExecutableSignature(SignatureStatus.Invalid, Diagnostic: VerificationStatus.VerifierTimeout));
                Check(!finished.IsSet);
            }
            finally { release.Set(); Check(finished.Wait(TimeSpan.FromSeconds(2))); Check(SpinWait.SpinUntil(() => AuthenticodeSignatures.Idle, 2000)); }
        });
        Test("verifier exceptions become a fixed Invalid status without exception data", () =>
        {
            var verifier = new AuthenticodeSignatures(new DelegateSignatures(_ => throw new IOException(Secret)));
            Equal(verifier.Verify("synthetic.exe"), new ExecutableSignature(SignatureStatus.Invalid));
        });
        Test("locked or unknown desktop blocks capture callback and writes exact safe failure", () =>
        {
            string directory = Path.Combine(Directory.GetCurrentDirectory(), "artifacts", "lock-tests", Guid.NewGuid().ToString("N"));
            foreach (var probe in new[] { new FakeLockProbe(false), new FakeLockProbe(false, true) })
            {
                int captures = 0;
                bool started = ScreenshotSession.TryStart(directory, () => captures++, probe);
                Equal(started, false); Equal(captures, 0);
                Equal(started ? 0 : ScreenshotSession.LockedExitCode, 3);
                Equal(File.ReadAllText(Path.Combine(directory, "capture-failed.txt")), "Session is locked; no screenshots taken.");
                Equal(Directory.GetFiles(directory).Length, 1);
            }
        });
        Test("unlocked default desktop allows capture callback and recheck detects subsequent lock", () =>
        {
            var probe = new FakeLockProbe(true); int captures = 0;
            Check(ScreenshotSession.TryStart("unused", () => captures++, probe)); Equal(captures, 1);
            probe.Unlocked = false;
            bool blocked = false;
            try { ScreenshotSession.EnsureUnlocked(probe); } catch (SessionLockedException) { blocked = true; }
            Check(blocked);
        });
    }
    private sealed class DelegateSignatures(Func<string, ExecutableSignature> verify) : IExecutableSignatures
    {
        public ExecutableSignature Verify(string path) => verify(path);
    }
    private sealed class FakeLockProbe(bool unlocked, bool fail = false) : IScreenshotLockProbe
    {
        public bool Unlocked { get; set; } = unlocked;
        public bool IsUnlockedDefaultDesktop() => fail ? throw new IOException(Secret) : Unlocked;
    }
}
