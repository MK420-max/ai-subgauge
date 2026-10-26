using AISubGauge.Core;
using System.Diagnostics;

internal static partial class Program
{
    private sealed class VerificationClock : TimeProvider
    {
        private long timestamp;
        public override long TimestampFrequency => TimeSpan.TicksPerSecond;
        public override long GetTimestamp() => timestamp;
        internal void Advance(TimeSpan elapsed) => timestamp += elapsed.Ticks;
    }
    // Real non-write/non-delete-sharing leases, but no ancestor traversal in sandbox fixtures.
    private sealed class LeasedFixtureFiles : IExecutableFiles
    {
        public IEnumerable<string> Directories(string path) => [];
        public Stream OpenRead(string path) => VerificationLease(path);
    }
    private static FileStream VerificationLease(string path) => new(path, FileMode.Open, FileAccess.Read, FileShare.Read);
    private static string VerificationFile()
    {
        string path = Path.Combine(HardeningDirectory(), "grok.exe");
        File.WriteAllText(path, "synthetic executable"); return path;
    }
    private static void RunVerifierReliabilityTests()
    {
        var locations = new CliLocations(@"C:\Fixture\Local", @"C:\Fixture\Roaming", @"C:\Fixture\Profile");
        string codex = Path.Combine(locations.Local, "OpenAI", "Codex", "bin", "abcdef123456", "codex.exe");
        string grok = Path.Combine(locations.Profile, ".grok", "bin", "grok.exe");
        Test("concurrent Codex and Grok resolves wait for slow process-wide verification and both succeed", () =>
        {
            using var entered = new ManualResetEventSlim();
            int calls = 0, active = 0;
            var native = new DelegateSignatures(path =>
            {
                Equal(Interlocked.Increment(ref active), 1); Interlocked.Increment(ref calls);
                try { entered.Set(); Thread.Sleep(500); return path == codex ? SignedFixture("O=\"OpenAI OpCo, LLC\"") : GrokFixture(); }
                finally { Interlocked.Decrement(ref active); }
            });
            var first = new ExecutableResolver(new FakeExecutableFiles(codex), new AuthenticodeSignatures(native), locations);
            var second = new ExecutableResolver(new FakeExecutableFiles(grok), new AuthenticodeSignatures(native), locations);
            var resolving = Task.Run(() => { using var exe = first.Resolve("codex"); Equal(exe.Path, codex); });
            try
            {
                Check(entered.Wait(2000));
                using var exe = second.Resolve("grok"); Equal(exe.Path, grok);
            }
            finally { resolving.GetAwaiter().GetResult(); }
            Equal(calls, 2);
        });
        AsyncTest("hung verification times out, bounded Grok wait is retryable and recovery respects backoff", async () =>
        {
            using var release = new ManualResetEventSlim();
            int calls = 0;
            var verifier = new AuthenticodeSignatures(new DelegateSignatures(path =>
            {
                Interlocked.Increment(ref calls);
                if (path == codex) release.Wait();
                return path == codex ? SignedFixture("O=\"OpenAI OpCo, LLC\"") : GrokFixture();
            }), timeout: TimeSpan.FromMilliseconds(100), gateTimeout: TimeSpan.FromMilliseconds(150));
            var first = new ExecutableResolver(new FakeExecutableFiles(codex), verifier, locations);
            var second = new ExecutableResolver(new FakeExecutableFiles(grok), verifier, locations);
            var clock = new FakeClock();
            var refresh = new ScriptedRenewal((_, _) =>
            {
                using var exe = second.Resolve("grok");
                return new Credential(Jwt, "user", "client", clock.Now.AddHours(2));
            });
            using var provider = Reliable(clock, new Source(new Credential(Secret, "user", "client", clock.Now.AddMinutes(31))), refresh);
            await provider.FetchAsync(); clock.Advance(60);
            try
            {
                try { using var exe = first.Resolve("codex"); Check(false); }
                catch (SafeFailure failure) { Equal(failure.Fault, Fault.VerifierUnresponsive); Equal(failure.Verification!.Status, VerificationStatus.VerifierTimeout); }
                var watch = Stopwatch.StartNew(); var stale = await provider.FetchAsync();
                Check(watch.Elapsed >= TimeSpan.FromMilliseconds(100) && watch.Elapsed < TimeSpan.FromSeconds(3));
                Equal(provider.RefreshPolicy.LastFailure!.Verification!.Status, VerificationStatus.VerifierBusy);
                Equal(stale.Fault, Fault.VerifierUnresponsive); Equal(stale.GrokState, GrokState.Retrying);
                Check(stale.Stale); Equal(stale.Weekly.Percent, 22d); Equal(calls, 1);
                foreach (string language in new[] { "en", "zh-CN" })
                {
                    Check(!new Texts(language).Status(stale).Contains(new Texts(language)["GrokVerificationShort"]));
                    Check(new Texts(language).TrayStatus(stale).Contains(new Texts(language)["GrokVerifierRetrying"]));
                }
                Equal(provider.NextBackgroundRefresh, clock.Now.AddSeconds(30));
                clock.Advance(29); await provider.FetchAsync(); Equal(refresh.Count, 1);
            }
            finally { release.Set(); Check(SpinWait.SpinUntil(() => AuthenticodeSignatures.Idle, 2000)); }
            clock.Advance(1); var recovered = await provider.FetchAsync();
            Equal(recovered.Fault, Fault.None); Check(!recovered.Stale); Equal(calls, 2); Equal(provider.RefreshPolicy.Failures, 0);
        });
        Test("Grok resolver maps busy and timeout to retryable fault with signature diagnostics", () =>
        {
            foreach (var status in new[] { VerificationStatus.VerifierBusy, VerificationStatus.VerifierTimeout })
            {
                var resolver = new ExecutableResolver(new FakeExecutableFiles(grok),
                    new FakeSignatures(new(SignatureStatus.Invalid, Diagnostic: status)), locations);
                try { using var exe = resolver.Resolve("grok"); Check(false); }
                catch (SafeFailure failure)
                {
                    Equal(failure.Fault, Fault.VerifierUnresponsive); Equal(failure.Verification!.Status, status);
                    Equal(failure.Verification.Stage, VerificationStage.Signature);
                }
            }
        });
        Test("successful leased identity cache skips native verification until one-hour expiry", () =>
        {
            string path = VerificationFile(); var clock = new VerificationClock();
            var native = new FakeSignatures(GrokFixture()); var verifier = new AuthenticodeSignatures(native, clock: clock);
            ExecutableSignature Verify() { using var lease = VerificationLease(path); return verifier.Verify(path, lease); }
            Check(GrokPublisher.Accepts(Verify())); Check(GrokPublisher.Accepts(Verify())); Equal(native.Calls, 1);
            clock.Advance(TimeSpan.FromMinutes(59)); Check(GrokPublisher.Accepts(Verify())); Equal(native.Calls, 1);
            clock.Advance(TimeSpan.FromMinutes(1)); Check(GrokPublisher.Accepts(Verify())); Equal(native.Calls, 2);
            // Path-only calls cannot reuse or populate the leased cache.
            verifier.Verify(path); verifier.Verify(path); Equal(native.Calls, 4);
        });
        Test("cache invalidates on last-write, size, file replacement and full-path changes", () =>
        {
            string path = VerificationFile();
            var native = new FakeSignatures(GrokFixture()); var verifier = new AuthenticodeSignatures(native);
            void Verify(string target) { using var lease = VerificationLease(target); Check(GrokPublisher.Accepts(verifier.Verify(target, lease))); }
            Verify(path); Equal(native.Calls, 1);
            var modified = File.GetLastWriteTimeUtc(path).AddMinutes(1);
            File.SetLastWriteTimeUtc(path, modified); Verify(path); Equal(native.Calls, 2);
            File.AppendAllText(path, " size changed"); File.SetLastWriteTimeUtc(path, modified);
            Verify(path); Equal(native.Calls, 3);
            string content = File.ReadAllText(path); File.Move(path, path + ".preserved");
            File.WriteAllText(path, content); File.SetLastWriteTimeUtc(path, modified);
            Verify(path); Equal(native.Calls, 4); // Same path/size/time, different file index.
            string renamed = path + ".renamed.exe"; File.Move(path, renamed);
            Verify(renamed); Equal(native.Calls, 5); Verify(renamed); Equal(native.Calls, 5);
        });
        Test("cached signature still enforces vendor pins on every resolver call", () =>
        {
            string directory = HardeningDirectory(); var local = new CliLocations(directory, directory, directory);
            string path = Path.Combine(directory, ".grok", "bin", "grok.exe");
            Directory.CreateDirectory(Path.GetDirectoryName(path)!); File.WriteAllText(path, "synthetic executable");
            var native = new FakeSignatures(GrokFixture());
            var resolver = new ExecutableResolver(new LeasedFixtureFiles(), new AuthenticodeSignatures(native), local);
            using (resolver.Resolve("grok")) { }
            using (resolver.Resolve("grok")) { }
            Equal(native.Calls, 1);
            try { using var exe = resolver.Resolve("codex", path); Check(false); }
            catch (SafeFailure failure) { Equal(failure.Verification!.Status, VerificationStatus.PublisherMismatch); }
            Equal(native.Calls, 1);
        });
        Test("unsigned invalid and wrong-pinned signatures never enter successful cache", () =>
        {
            string path = VerificationFile();
            foreach (var signature in new[] { new ExecutableSignature(SignatureStatus.Unsigned), new ExecutableSignature(SignatureStatus.Invalid),
                GrokFixture() with { ChainThumbprints = ["LEAF", "WRONG", GrokPublisher.RootThumbprint] } })
            {
                var native = new FakeSignatures(signature); var verifier = new AuthenticodeSignatures(native);
                using var lease = VerificationLease(path);
                verifier.Verify(path, lease); verifier.Verify(path, lease); Equal(native.Calls, 2);
            }
        });
        Test("late successful worker cannot cache or authorize after verifier timeout", () =>
        {
            string path = VerificationFile(); using var release = new ManualResetEventSlim(); int calls = 0;
            var verifier = new AuthenticodeSignatures(new DelegateSignatures(_ =>
            {
                if (Interlocked.Increment(ref calls) == 1) release.Wait(); return GrokFixture();
            }), timeout: TimeSpan.FromMilliseconds(100));
            using var lease = VerificationLease(path);
            try { Equal(verifier.Verify(path, lease).Diagnostic, VerificationStatus.VerifierTimeout); }
            finally { release.Set(); Check(SpinWait.SpinUntil(() => AuthenticodeSignatures.Idle, 2000)); }
            Check(GrokPublisher.Accepts(verifier.Verify(path, lease))); Equal(calls, 2);
            Check(GrokPublisher.Accepts(verifier.Verify(path, lease))); Equal(calls, 2);
        });
        Test("cache identity requires matching live handle and preserves executable write exclusion", () =>
        {
            string path = VerificationFile(), other = VerificationFile();
            var native = new FakeSignatures(GrokFixture()); var verifier = new AuthenticodeSignatures(native);
            using (var lease = VerificationLease(path))
            {
                Check(GrokPublisher.Accepts(verifier.Verify(path, lease)));
                Throws(() => File.WriteAllText(path, "cannot replace leased executable"));
                Throws(() => verifier.Verify(other, lease)); Equal(native.Calls, 1);
            }
        });
    }
}
