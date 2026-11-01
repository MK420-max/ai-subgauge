using AISubGauge.Core;
using System.Security.Cryptography;
using System.Text.Json;

internal static partial class Program
{
    private static void RunRefreshRegressionTests()
    {
        Test("refresh cleanup retries access denied three times and logs once", () =>
        {
            int calls = 0;
            var delays = new List<int>();
            var messages = new List<string>();
            RefreshCleanup.TryDelete("scratch-fixture", new(new(), messages.Add),
                _ => { ++calls; throw new UnauthorizedAccessException(); }, delays.Add);
            Equal(calls, 3);
            Check(delays.SequenceEqual(new[] { 100, 100 }));
            Equal(messages.Single(), "RefreshCleanupFailed");
        });
        Test("refresh cleanup treats a missing directory as clean without retry or log", () =>
        {
            int calls = 0;
            var delays = new List<int>();
            var messages = new List<string>();
            RefreshCleanup.TryDelete("scratch-fixture", new(new(), messages.Add),
                _ => { ++calls; throw new DirectoryNotFoundException(); }, delays.Add);
            Equal(calls, 1); Equal(delays.Count, 0); Equal(messages.Count, 0);
        });
        AsyncTest("valid token with one RefreshFailed retries until the existing threshold", async () =>
        {
            var clock = new FakeClock();
            var credential = new Credential(Secret, "user", "client", clock.Now.AddMinutes(30));
            var refresh = new ScriptedRenewal((_, _) => throw new SafeFailure(Fault.RefreshFailed));
            using var provider = Reliable(clock, new Source(credential), refresh);
            for (int count = 1; count <= GrokRefreshPolicy.SignInThreshold; ++count)
            {
                var result = await provider.FetchAsync();
                Check(credential.Expires > clock.Now);
                Equal(result.Fault, Fault.RefreshFailed); Equal(provider.RefreshPolicy.Failures, count);
                Equal(result.GrokState, count < GrokRefreshPolicy.SignInThreshold ? GrokState.Retrying : GrokState.SignInExpired);
                clock.Advance((provider.NextBackgroundRefresh - clock.Now).TotalSeconds);
            }
        });
        foreach (bool expired in new[] { false, true })
        AsyncTest($"sign-in state is retained for {(expired ? "expired token" : "explicit rejection")}", async () =>
        {
            var clock = new FakeClock();
            var credential = new Credential(Secret, "user", "client", clock.Now.AddMinutes(expired ? -1 : 30));
            var refresh = new ScriptedRenewal((_, _) => throw new SafeFailure(expired ? Fault.RefreshFailed : Fault.SignIn));
            using var provider = Reliable(clock, new Source(credential), refresh);
            Equal((await provider.FetchAsync()).GrokState, GrokState.SignInExpired);
        });
        foreach (string expiry in new[] { "missing", "null", "invalid", "out of range", "expired", "valid" })
        // A worker avoids the WinForms context left by earlier tests; the deadline also
        // bounds synchronous file operations before the first await.
        AsyncTest($"real credential file post-refresh check: {expiry} expires_at", () => Task.Run(async () =>
        {
            var clock = new FakeClock();
            string directory = Path.Combine(Path.GetTempPath(), "aisubgauge-refresh-regression-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(directory);
            string path = Path.Combine(directory, "auth.json");
            var entry = new Dictionary<string, object?>
            {
                ["auth_mode"] = "oidc", ["oidc_issuer"] = "https://auth.x.ai",
                ["oidc_client_id"] = "client", ["user_id"] = "user", ["key"] = Secret,
                ["create_time"] = clock.Now.ToString("O")
            };
            if (expiry != "missing") entry["expires_at"] = expiry switch
            {
                "null" => null, "invalid" => "not-a-date", "out of range" => 1e100,
                "expired" => clock.Now.AddSeconds(-1).ToString("O"),
                _ => clock.Now.AddHours(2).ToString("O")
            };
            File.WriteAllText(path, JsonSerializer.Serialize(new Dictionary<string, object?> { ["https://auth.x.ai::client"] = entry }));
            var files = new FixtureCredentialFiles(path, clock);
            if (expiry is "missing" or "null")
                Equal((await files.ReadAsync(Vendor.Grok, default))!.Expires, clock.Now.AddDays(30));
            int calls = 0;
            var refresh = new GrokCliRefresh(files, clock, _ =>
            {
                ++calls; return new FakeRpc((_, _) => Parse("{}"));
            });
            using var provider = Reliable(clock, new Source(new Credential(Secret, "user", "client", clock.Now.AddMinutes(30))), refresh);
            var result = await provider.FetchAsync();
            Equal(calls, 1);
            Equal(result.Fault, expiry == "valid" ? Fault.None : Fault.RefreshFailed);
            Equal(result.GrokState, expiry == "valid" ? GrokState.Ready : GrokState.Retrying);
            Equal(provider.RefreshPolicy.Failures, expiry == "valid" ? 0 : 1);
            if (expiry != "valid")
            {
                Equal(provider.NextBackgroundRefresh, clock.Now.AddSeconds(30));
                await provider.FetchAsync(); Equal(calls, 1);
            }
            // Retain the tiny synthetic fixtures; this regression suite never deletes files.
        }).WaitAsync(TimeSpan.FromSeconds(5)));
        Test("executable hashing rejects oversized files and accepts the exact limit", () =>
        {
            Equal(LocalFiles.MaximumExecutableBytes, 512L * 1024 * 1024);
            string directory = Path.Combine(Path.GetTempPath(), "aisubgauge-size-regression-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(directory);
            string path = Path.Combine(directory, "codex.exe");
            byte[] bytes = [1, 2, 3, 4, 5, 6, 7, 8];
            File.WriteAllBytes(path, bytes);
            using (var lease = File.OpenRead(path))
            {
                lease.Position = 3;
                Equal(LocalFiles.ContentHash(lease.SafeFileHandle, 8), Convert.ToHexString(SHA256.HashData(bytes)));
                Equal(lease.Position, 3L);
                try { LocalFiles.ContentHash(lease.SafeFileHandle, 7); Check(false); }
                catch (IOException) { }
            }
        });
        Test("executable resolution fails closed above the size limit before signature verification", () =>
        {
            string directory = Path.Combine(Path.GetTempPath(), "aisubgauge-size-regression-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(directory);
            string path = Path.Combine(directory, "codex.exe");
            File.WriteAllBytes(path, [1, 2, 3, 4, 5, 6, 7, 8]);
            int verifications = 0;
            var signatures = new DelegateSignatures(_ => { ++verifications; return SignedFixture("O=\"OpenAI OpCo, LLC\""); });
            var locations = new CliLocations(directory, directory, directory);
            using (var executable = new ExecutableResolver(new ExecutableFiles(8), signatures, locations).Resolve("codex", path))
                Equal(executable.Path, path);
            Equal(verifications, 1);
            try { using var executable = new ExecutableResolver(new ExecutableFiles(7), signatures, locations).Resolve("codex", path); Check(false); }
            catch (SafeFailure failure) { Equal(failure.Fault, Fault.VerificationFailed); Equal(failure.Verification!.Status, VerificationStatus.Invalid); }
            Equal(verifications, 1);
        });
    }

    // Exercise the production parser using only this test's synthetic file. Production
    // CredentialFiles still opens credentials through LocalFiles and its security checks.
    private sealed class FixtureCredentialFiles(string path, IClock clock) : ICredentialSource
    {
        public Task<Credential?> ReadAsync(Vendor vendor, CancellationToken cancellation) => ReadAsync(cancellation, false);
        public Task<Credential?> ReadAfterRefreshAsync(CancellationToken cancellation) => ReadAsync(cancellation, true);
        private async Task<Credential?> ReadAsync(CancellationToken cancellation, bool requireExplicitExpiry)
        {
            await using var file = File.OpenRead(path);
            using var auth = await JsonDocument.ParseAsync(file, cancellationToken: cancellation).ConfigureAwait(false);
            return new CredentialFiles(clock).ParseGrok(auth.RootElement, requireExplicitExpiry);
        }
    }
}
