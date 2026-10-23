import Darwin
import Foundation
import Testing
@testable import TidyBar

extension TidyBarTests {
@Suite
final class GrokBuildUsageTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    private func auth(issuer: String = "https://auth.x.ai", mode: String = "oidc", expires: Date? = nil) -> [String: Any] {
        ["auth_mode": mode, "oidc_issuer": issuer, "oidc_client_id": "test-client",
         "key": "synthetic-test-bearer", "user_id": "synthetic-user",
         "create_time": ISO8601DateFormatter().string(from: now.addingTimeInterval(-60)),
         "expires_at": ISO8601DateFormatter().string(from: expires ?? now.addingTimeInterval(3600))]
    }
    private func scoped(_ value: [String: Any]) -> [String: Any] { ["https://auth.x.ai::test-client": value] }

    @Test
    func testOfficialCreditsAreUsedPercentAndPrepaidBalanceIsUSDCents() throws {
        let response: [String: Any] = ["config": ["creditUsagePercent": 42.5,
            "currentPeriod": ["type": "USAGE_PERIOD_TYPE_WEEKLY", "end": "2033-05-19T03:33:20Z"],
            "prepaidBalance": ["val": 1234], "isUnifiedBillingUser": true]]
        let snapshot = try GrokBuildUsageSource.parse(data(response), now: now)
        #expect(snapshot.windows.first?.remainingPercent == 57.5)
        #expect(snapshot.windows.first?.title == "每周")
        #expect(snapshot.windows.first?.resetsAt == Date(timeIntervalSince1970: 2_000_086_400))
        #expect(snapshot.balance == "US$ 12.34")
        #expect(snapshot.updatedAt == now)
        #expect(snapshot.status.contains("共享账户"))
        #expect(snapshot.source.contains("官方"))
    }

    @Test
    func testMissingQuotaAndBalanceRemainUnknownAndMonthlyIsNotWeekly() throws {
        let snapshot = try GrokBuildUsageSource.parse(data(["config": ["currentPeriod": ["type": "USAGE_PERIOD_TYPE_MONTHLY"]]]), now: now)
        #expect(snapshot.windows.first?.remainingPercent == nil)
        #expect(snapshot.balance == nil)
        #expect(snapshot.windows.first?.resetsAt == nil)
        #expect(snapshot.windows.first?.title == "每月")
        #expect(snapshot.status.contains("未确认共享"))
    }

    @Test
    func testProtoZeroBalanceAndOverrunAreExact() throws {
        let snapshot = try GrokBuildUsageSource.parse(data(["config": ["creditUsagePercent": 125, "prepaidBalance": [:] as [String: Any]]]), now: now)
        #expect(snapshot.windows.first?.remainingPercent == 0)
        #expect(snapshot.balance == "US$ 0.00")
    }

    @Test
    func testInvalidReadingsDoNotProduceFakeQuota() throws {
        for used in [true, "42", -1] as [Any] {
            #expect(throws: (any Error).self) { try GrokBuildUsageSource.parse(data(["config": ["creditUsagePercent": used]]), now: now) }
        }
        #expect(throws: (any Error).self) { try GrokBuildUsageSource.parse(data(["config": ["prepaidBalance": ["val": true]]]), now: now) }
        #expect(throws: (any Error).self) { try GrokBuildUsageSource.parse(data(["config": ["prepaidBalance": ["val": "1234"]]]), now: now) }
        #expect(throws: (any Error).self) { try GrokBuildUsageSource.parse(data(["config": ["currentPeriod": ["end": "not-a-date"]]]), now: now) }
        #expect(throws: (any Error).self) { try GrokBuildUsageSource.parse(data(["config": NSNull()]), now: now) }
    }

    @Test
    func testOnlyScopedFirstPartyOAuthCredentialsAreEligible() throws {
        #expect(try GrokBuildUsageSource.credential(from: data(scoped(auth())), now: now) != nil)
        #expect(try GrokBuildUsageSource.credential(from: data(scoped(auth(issuer: "https://example.test"))), now: now) == nil)
        #expect(try GrokBuildUsageSource.credential(from: data(scoped(auth(mode: "api_key"))), now: now) == nil)
        #expect(try GrokBuildUsageSource.credential(from: data([:] as [String: Any]), now: now) == nil)
        #expect(throws: (any Error).self) { try GrokBuildUsageSource.credential(from: data(["other-scope": auth()]), now: now) }
    }

    @Test
    func testExpiredAmbiguousOrHeaderInjectedCredentialsAreRejected() throws {
        #expect(throws: (any Error).self) { try GrokBuildUsageSource.credential(from: data(scoped(auth(expires: now.addingTimeInterval(-1)))), now: now) }
        var injected = auth(); injected["key"] = "synthetic\r\nHeader: unsafe"
        #expect(throws: (any Error).self) { try GrokBuildUsageSource.credential(from: data(scoped(injected)), now: now) }
        var other = auth(); other["user_id"] = "another-synthetic-user"; other["oidc_client_id"] = "other-client"
        #expect(throws: (any Error).self) { try GrokBuildUsageSource.credential(from: data([
            "https://auth.x.ai::test-client": auth(), "https://auth.x.ai::other-client": other]), now: now) }
    }
}
}


extension TidyBarTests.GrokBuildUsageTests {
    private func renewalFixture(script: String, changedAccount: Bool = false) throws -> (URL, URL, GrokBuildUsageSource.Credential) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("grok-renewal-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let executable = folder.appendingPathComponent("grok"), authURL = folder.appendingPathComponent("auth.json")
        var expired = auth(expires: Date().addingTimeInterval(-60))
        expired["create_time"] = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
        expired["refresh_token"] = "synthetic-refresh-only"
        let bytes = try data(scoped(expired))
        try bytes.write(to: authURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
        var renewed = expired
        renewed["key"] = "synthetic-renewed-bearer"
        renewed["expires_at"] = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        if changedAccount { renewed["user_id"] = "another-synthetic-user" }
        try data(scoped(renewed)).write(to: URL(fileURLWithPath: authURL.path + ".next"))
        try ("#!/bin/sh\n" + script).write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (executable, authURL, try #require(try GrokBuildUsageSource.credential(from: bytes, allowExpired: true)))
    }

    private var renewalScript: String {
        """
        [ "$1" = agent ] && [ "$2" = stdio ] || exit 11
        [ "$GROK_OAUTH2_ISSUER" = https://auth.x.ai ] || exit 14
        [ "$GROK_OAUTH2_CLIENT_ID" = test-client ] || exit 15
        [ . -ef "$GROK_HOME" ] || exit 16
        [ -z "$GROK_AUTH$GROK_API_KEY$XAI_API_KEY$GROK_CODE_XAI_API_KEY$GROK_AUTH_PROVIDER_COMMAND" ] || exit 17
        [ -z "$OPENAI_API_KEY$ANTHROPIC_API_KEY$CLAUDE_CODE_OAUTH_TOKEN$AWS_SECRET_ACCESS_KEY$OTEL_EXPORTER_OTLP_HEADERS$SENTRY_DSN" ] || exit 18
        [ "$GROK_TELEMETRY_ENABLED" = 0 ] && [ "$GROK_EXTERNAL_OTEL" = 0 ] || exit 19
        [ "$GROK_LOG_FILE" = /dev/null ] && [ "$RUST_LOG" = off ] || exit 20
        IFS= read -r first
        case "$first" in *initialize*) ;; *) exit 12;; esac
        printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{}}'
        IFS= read -r second
        case "$second" in *getBearerToken*) ;; *) exit 13;; esac
        cp "$GROK_AUTH_PATH.next" "$GROK_AUTH_PATH"
        chmod 644 "$GROK_AUTH_PATH"
        printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":{"token":"synthetic-ignored"}}'
        exec /bin/sleep 30
        """
    }

    @Test
    func testOfficialRenewalRPCReusesSameAccountAndReapsChild() async throws {
        let (cli, authURL, expired) = try renewalFixture(script: renewalScript)
        defer { try? FileManager.default.removeItem(at: cli.deletingLastPathComponent()) }
        var pid: pid_t = 0
        _ = try await GrokBuildUsageSource.refreshCredential(executable: cli, authURL: authURL, expected: expired, onLaunch: { pid = $0 }, verifyCLI: { _ in })
        #expect(pid > 0)
        #expect(kill(pid, 0) != 0)
        #expect(try GrokBuildUsageSource.credential(from: Data(contentsOf: authURL)) != nil)
        #expect((try FileManager.default.attributesOfItem(atPath: authURL.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test
    func testRenewalTimeoutAndCancellationEndAllDescendants() async throws {
        for timedOut in [false, true] {
            let (cli, authURL, expired) = try renewalFixture(script: "")
            defer { try? FileManager.default.removeItem(at: cli.deletingLastPathComponent()) }
            let pids = cli.deletingLastPathComponent().appendingPathComponent("descendants")
            let original = try Data(contentsOf: authURL)
            try Data(("#!/bin/sh\nchmod 644 \"$GROK_AUTH_PATH\"\n" + ProcessTreeFixture.script(pids: pids)).utf8).write(to: cli)
            var leader: pid_t = 0
            let task = Task {
                try await GrokBuildUsageSource.refreshCredential(executable: cli, authURL: authURL, expected: expired,
                    timeout: timedOut ? 0.6 : 20, onLaunch: { leader = $0 }, verifyCLI: { _ in })
            }
            defer { task.cancel() }
            let descendants = try await ProcessTreeFixture.pids(at: pids)
            #expect(leader > 0 && getpgid(leader) == leader)
            for child in descendants { #expect(getpgid(child) == leader) }
            if !timedOut { task.cancel() }
            do { _ = try await task.value; Issue.record("Renewal must not succeed") }
            catch {
                if timedOut { #expect(error.localizedDescription.contains("超时")) }
                else { #expect(error is CancellationError) }
            }
            try await ProcessTreeFixture.expectExited([leader] + descendants)
            #expect((try FileManager.default.attributesOfItem(atPath: authURL.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            #expect(try Data(contentsOf: authURL) == original)
        }
    }

    @Test
    func testFailedRenewalRestrictsCredentialPermissionsBeforeReturning() async throws {
        let protocolFailure = renewalScript.replacingOccurrences(of: "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"token\":\"synthetic-ignored\"}}",
            with: "{\"jsonrpc\":\"2.0\",\"id\":2,\"error\":{\"code\":-1}}")
        for script in [protocolFailure, "chmod 644 \"$GROK_AUTH_PATH\"\nexit 1\n"] {
            let (cli, authURL, expired) = try renewalFixture(script: script)
            defer { try? FileManager.default.removeItem(at: cli.deletingLastPathComponent()) }
            var pid: pid_t = 0
            do {
                _ = try await GrokBuildUsageSource.refreshCredential(executable: cli, authURL: authURL, expected: expired,
                    onLaunch: { pid = $0 }, verifyCLI: { _ in })
                Issue.record("Failed renewal must be rejected")
            } catch { #expect(error is AIUsageError) }
            #expect(pid > 0 && kill(pid, 0) != 0)
            #expect((try FileManager.default.attributesOfItem(atPath: authURL.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
    }

    @Test
    func testRenewalRejectsAReplacedCredentialSymlinkWithoutChangingItsTarget() async throws {
        let script = renewalScript.replacingOccurrences(of: "cp \"$GROK_AUTH_PATH.next\" \"$GROK_AUTH_PATH\"\nchmod 644 \"$GROK_AUTH_PATH\"", with:
            "mv \"$GROK_AUTH_PATH\" \"$GROK_AUTH_PATH.old\"\nln -s \"$GROK_AUTH_PATH.next\" \"$GROK_AUTH_PATH\"")
        let (cli, authURL, expired) = try renewalFixture(script: script)
        defer { try? FileManager.default.removeItem(at: cli.deletingLastPathComponent()) }
        do {
            _ = try await GrokBuildUsageSource.refreshCredential(executable: cli, authURL: authURL, expected: expired, verifyCLI: { _ in })
            Issue.record("Symlink credentials must be rejected")
        } catch { #expect(error is AIUsageError) }
        var metadata = stat()
        #expect(lstat(authURL.path, &metadata) == 0 && metadata.st_mode & S_IFMT == S_IFLNK)
        #expect(FileManager.default.fileExists(atPath: authURL.path + ".old"))
        let target = URL(fileURLWithPath: authURL.path + ".next")
        #expect((try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue == 0o644)
    }

    @Test
    func testRenewalRejectsAChangedAccount() async throws {
        let (cli, authURL, expired) = try renewalFixture(script: renewalScript, changedAccount: true)
        defer { try? FileManager.default.removeItem(at: cli.deletingLastPathComponent()) }
        do {
            _ = try await GrokBuildUsageSource.refreshCredential(executable: cli, authURL: authURL, expected: expired, verifyCLI: { _ in })
            Issue.record("不得接受其他账户的续期结果")
        } catch { #expect(error.localizedDescription.contains("同一账户")) }
    }

    @Test
    func testRenewalTimeoutAndCancellationReapTheirRealProcesses() async throws {
        let (cli, authURL, expired) = try renewalFixture(script: "trap '' TERM\nexec /bin/sleep 30\n")
        defer { try? FileManager.default.removeItem(at: cli.deletingLastPathComponent()) }
        var timedPID: pid_t = 0
        do {
            _ = try await GrokBuildUsageSource.refreshCredential(executable: cli, authURL: authURL, expected: expired, timeout: 0.3, onLaunch: { timedPID = $0 }, verifyCLI: { _ in })
            Issue.record("应返回续期超时")
        } catch { #expect(error.localizedDescription.contains("超时")) }
        #expect(timedPID > 0)
        #expect(kill(timedPID, 0) != 0)
        let launched = TestSignal()
        var cancelledPID: pid_t = 0
        let task = Task {
            try await GrokBuildUsageSource.refreshCredential(executable: cli, authURL: authURL, expected: expired, onLaunch: { cancelledPID = $0; launched.signal() }, verifyCLI: { _ in })
        }
        #expect(await launched.wait(timeout: 3))
        task.cancel()
        do { _ = try await task.value; Issue.record("应取消续期") }
        catch { #expect(error is CancellationError) }
        #expect(cancelledPID > 0)
        // The cancelled caller returns promptly; worker cleanup completes independently.
        try await ProcessTreeFixture.expectExited([cancelledPID])
    }

    @Test
    func testRenewalRejectsOversizedOutputAndReapsChild() async throws {
        let (cli, authURL, expired) = try renewalFixture(script: "exec /usr/bin/head -c 1100000 /dev/zero\n")
        defer { try? FileManager.default.removeItem(at: cli.deletingLastPathComponent()) }
        var pid: pid_t = 0
        do {
            _ = try await GrokBuildUsageSource.refreshCredential(executable: cli, authURL: authURL, expected: expired, onLaunch: { pid = $0 }, verifyCLI: { _ in })
            Issue.record("应拒绝过大的续期响应")
        } catch { #expect(error.localizedDescription.contains("过大")) }
        #expect(pid > 0)
        #expect(kill(pid, 0) != 0)
    }
}


extension TidyBarTests.GrokBuildUsageTests {
    @Test
    func testMissingRefreshMetadataNeverLaunchesAProcess() async throws {
        var value = auth(expires: now.addingTimeInterval(-60))
        value["refresh_token"] = ""
        let credential = try #require(try GrokBuildUsageSource.credential(from: data(scoped(value)), now: now, allowExpired: true))
        var launched = false
        do {
            _ = try await GrokBuildUsageSource.refreshCredential(executable: URL(fileURLWithPath: "/not/a/cli"), authURL: URL(fileURLWithPath: "/not/an/auth.json"), expected: credential, onLaunch: { _ in launched = true })
            Issue.record("缺少续期元数据应要求重新连接")
        } catch { #expect(error.localizedDescription.contains("重新连接")) }
        #expect(!(launched))
    }
}

extension TidyBarTests.GrokBuildUsageTests {
    @Test(arguments: [16.0, 15.0, 0.0, -1.0])
    func renewalStartsAtFifteenSecondsBeforeExpiry(seconds: TimeInterval) async throws {
        var value = auth(expires: now.addingTimeInterval(seconds))
        value["refresh_token"] = "synthetic-refresh-boundary"
        let initial = try #require(try GrokBuildUsageSource.credential(from: data(scoped(value)), now: now, allowExpired: true))
        let fresh = try #require(try GrokBuildUsageSource.credential(from: data(scoped(auth())), now: now))
        var renewals = 0, lookups = 0
        _ = try await GrokBuildUsageSource.credentialForBilling(initial,
            authURL: URL(fileURLWithPath: "/unused-synthetic-credential"), now: now,
            cli: { lookups += 1; return URL(fileURLWithPath: "/unused-synthetic-cli") },
            renew: { _, _, _ in renewals += 1; return fresh })
        #expect(renewals == (seconds <= 15 ? 1 : 0))
        #expect(lookups == renewals)
    }

    @Test func concurrentRenewalsLaunchOncePersistAndLogOnlySafeEvents() async throws {
        let (cli, file, expired) = try renewalFixture(script: renewalScript)
        let launches = RenewalObservations()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    _ = try await GrokBuildUsageSource.refreshCredential(executable: cli, authURL: file, expected: expired,
                        onLaunch: { _ in launches.launched() }, verifyCLI: { _ in }, log: { launches.log($0) })
                }
            }
            try await group.waitForAll()
        }
        // Reusing an expired snapshot must reuse the valid on-disk renewal.
        _ = try await GrokBuildUsageSource.refreshCredential(executable: cli, authURL: file, expected: expired,
            onLaunch: { _ in launches.launched() }, verifyCLI: { _ in }, log: { launches.log($0) })
        #expect(launches.count == 1)
        let saved = try #require(try GrokBuildUsageSource.readCredential(at: file))
        _ = try await GrokBuildUsageSource.fetchBilling(saved) { request in
            let usesRenewedToken = request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-renewed-bearer"
            #expect(usesRenewedToken)
            return (try self.data(["config": ["creditUsagePercent": 25]]),
                try #require(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(launches.messages.count == 1)
        #expect(launches.messages.first?.hasPrefix("grok token refreshed, expires in ") == true)
        #expect(launches.messages.allSatisfy { !$0.contains("synthetic-") && !$0.contains("Bearer") && !$0.contains("test-client") })
    }

    @MainActor @Test func renewalFailureShowsUnavailableQuotaAndNeverLogsReturnedSecrets() async throws {
        let script = """
        IFS= read -r first
        printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{}}'
        IFS= read -r second
        printf '%s\\n' 'synthetic-stderr-secret' >&2
        printf '%s\\n' '{"jsonrpc":"2.0","id":2,"error":{"message":"synthetic-error-secret","token":"synthetic-ignored"}}'
        """
        let (cli, file, expired) = try renewalFixture(script: script)
        let events = RenewalObservations()
        let store = AIUsageStore(applyDisplayFilters: false, fetcher: { _ in
            _ = try await GrokBuildUsageSource.refreshCredential(executable: cli, authURL: file, expected: expired,
                verifyCLI: { _ in }, log: { events.log($0) })
            throw AIUsageError.invalidResponse
        })
        store.snapshots = [AIUsageSnapshot(provider: .grok, windows: [
            .init(id: "weekly", title: "fixture", remainingPercent: 50)
        ], isConnected: true, status: "", source: "fixture", updatedAt: Date())]
        store.refresh(provider: .grok)
        for _ in 0..<400 where store.isRefreshing { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(!store.isRefreshing)
        let snapshot = try #require(store.visibleSnapshots.first)
        #expect(!snapshot.isConnected)
        #expect(snapshot.error == L10n.text("error.grok.automatic.renewal.failed.reconnect.the.account"))
        #expect(snapshot.windows.first?.remainingPercent == nil)
        #expect(events.messages == ["grok token refresh failed; reconnect or retry"])
        #expect(events.messages.allSatisfy { !$0.contains("synthetic-") && !$0.contains("Bearer") })
        store.stop()
    }
}

private final class RenewalObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var launchCount = 0
    private var recorded: [String] = []
    func launched() { lock.withLock { launchCount += 1 } }
    func log(_ event: GrokBuildUsageSource.RenewalEvent) { lock.withLock { recorded.append(event.message) } }
    var count: Int { lock.withLock { launchCount } }
    var messages: [String] { lock.withLock { recorded } }
}

extension TidyBarTests.GrokBuildUsageTests {
    private func waitForWaiters(_ count: Int, at url: URL, in renewals: GrokCredentialRenewals) async throws {
        for _ in 0..<1000 {
            if await renewals.pending[url]?.waiters.count == count { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        Issue.record("Shared renewal did not register the expected waiters")
        throw AIUsageError.timeout
    }

    @Test func cancellingOneWaiterLeavesSharedRenewalRunningAndDoesNotStartDuplicates() async throws {
        let renewals = GrokCredentialRenewals(), release = TestSignal()
        let calls = RenewalObservations()
        let url = URL(fileURLWithPath: "/tmp/synthetic-renewal-" + UUID().uuidString)
        let credential = try #require(try GrokBuildUsageSource.credential(from: data(scoped(auth())), now: now))
        let operation: () async throws -> GrokBuildUsageSource.Credential = {
            calls.launched()
            _ = await release.wait(timeout: 5)
            try Task.checkCancellation()
            return credential
        }
        let first = Task { try await renewals.refresh(at: url, operation: operation) }
        let second = Task { try await renewals.refresh(at: url, operation: operation) }
        defer { release.signal(); first.cancel(); second.cancel() }
        try await waitForWaiters(2, at: url, in: renewals)
        first.cancel()
        do { _ = try await first.value; Issue.record("Cancelled waiter must throw") }
        catch is CancellationError {}
        // A caller joining after the cancelled waiter has returned must still reuse the worker.
        let third = Task { try await renewals.refresh(at: url, operation: operation) }
        defer { third.cancel() }
        try await waitForWaiters(2, at: url, in: renewals)
        #expect(calls.count == 1)
        release.signal()
        for task in [second, third] {
            let result = try await task.value
            let snapshot = try await GrokBuildUsageSource.fetchBilling(result) { request in
                let matches = request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-test-bearer"
                #expect(matches)
                return (try self.data(["config": ["creditUsagePercent": 25]]),
                        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            #expect(snapshot.windows.first?.remainingPercent == 75)
        }
        #expect(calls.count == 1)
        #expect(await renewals.pending[url] == nil)
    }

    @Test func cancellingAllWaitersCancelsWorkerButKeepsEntryUntilCleanupFinishes() async throws {
        let renewals = GrokCredentialRenewals(), cancelled = TestSignal(), cleanup = TestSignal()
        let calls = RenewalObservations()
        let url = URL(fileURLWithPath: "/tmp/synthetic-renewal-" + UUID().uuidString)
        let operation: () async throws -> GrokBuildUsageSource.Credential = {
            calls.launched()
            do { try await Task.sleep(nanoseconds: 10_000_000_000) }
            catch {
                cancelled.signal()
                _ = await Task.detached { await cleanup.wait(timeout: 5) }.value
                throw error
            }
            throw AIUsageError.invalidResponse
        }
        let first = Task { try await renewals.refresh(at: url, operation: operation) }
        let second = Task { try await renewals.refresh(at: url, operation: operation) }
        defer { cleanup.signal(); first.cancel(); second.cancel() }
        try await waitForWaiters(2, at: url, in: renewals)
        first.cancel(); second.cancel()
        for task in [first, second] {
            do { _ = try await task.value; Issue.record("Cancelled waiter must throw") }
            catch is CancellationError {}
        }
        #expect(await cancelled.wait(timeout: 1))
        #expect(await renewals.pending[url] != nil)
        let third = Task { try await renewals.refresh(at: url, operation: operation) }
        defer { third.cancel() }
        try await waitForWaiters(1, at: url, in: renewals)
        #expect(calls.count == 1)
        cleanup.signal()
        do { _ = try await third.value; Issue.record("Joining a cancelling worker must observe its failure") }
        catch is CancellationError {}
        #expect(await renewals.pending[url] == nil)
        #expect(calls.count == 1)
    }
}
