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
                else {
                    #expect(error is CancellationError)
                    #expect((try FileManager.default.attributesOfItem(atPath: authURL.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
                }
            }
            try await ProcessTreeFixture.expectExited([leader] + descendants)
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline,
                  (try FileManager.default.attributesOfItem(atPath: authURL.path)[.posixPermissions] as? NSNumber)?.intValue != 0o600 {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            #expect((try FileManager.default.attributesOfItem(atPath: authURL.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            #expect(try Data(contentsOf: authURL) == original)
        }
    }

    @Test
    func testCancellationLatencyReport() async throws {
        guard ProcessInfo.processInfo.environment["SG_CANCEL_LATENCY"] == "1" else { return }
        for _ in 0..<25 {
            let (cli, authURL, expired) = try renewalFixture(script: "")
            defer { try? FileManager.default.removeItem(at: cli.deletingLastPathComponent()) }
            let pids = cli.deletingLastPathComponent().appendingPathComponent("descendants")
            try Data(("#!/bin/sh\nchmod 644 \"$GROK_AUTH_PATH\"\n" + ProcessTreeFixture.script(pids: pids)).utf8).write(to: cli)
            var leader: pid_t = 0
            let task = Task {
                try await GrokBuildUsageSource.refreshCredential(executable: cli, authURL: authURL, expected: expired,
                    onLaunch: { leader = $0 }, verifyCLI: { _ in })
            }
            defer { task.cancel() }
            let descendants = try await ProcessTreeFixture.pids(at: pids)
            let t0 = ProcessInfo.processInfo.systemUptime
            task.cancel()
            do { _ = try await task.value; Issue.record("Renewal must be cancelled") }
            catch is CancellationError {
                let t1 = ProcessInfo.processInfo.systemUptime
                print("CANCEL_LATENCY_MS \((t1 - t0) * 1000)")
            }
            try await ProcessTreeFixture.expectExited([leader] + descendants)
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
        // The final cancelled caller returns after worker cleanup.
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
        defer { try? FileManager.default.removeItem(at: cli.deletingLastPathComponent()) }
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

private final class RenewalGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if opened { continuation.resume() }
                else { waiters.append(continuation) }
            }
        }
    }

    func open() {
        let continuations = lock.withLock {
            opened = true
            let continuations = waiters
            waiters.removeAll()
            return continuations
        }
        for continuation in continuations { continuation.resume() }
    }
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

    @Test func cancellingOneOfTwoCallersStillReturnsRenewedCredentialToTheOther() async throws {
        let gate = "while [ ! -f \"$GROK_AUTH_PATH.release\" ]; do /bin/sleep 0.01; done\n"
        let (cli, file, expired) = try renewalFixture(script: gate + renewalScript)
        defer { try? FileManager.default.removeItem(at: cli.deletingLastPathComponent()) }
        let launches = RenewalObservations()
        let operation = {
            try await GrokBuildUsageSource.refreshCredential(executable: cli, authURL: file, expected: expired,
                onLaunch: { _ in launches.launched() }, verifyCLI: { _ in })
        }
        let first = Task { try await operation() }
        let second = Task { try await operation() }
        defer { first.cancel(); second.cancel() }
        try await waitForWaiters(2, at: file.standardizedFileURL, in: .shared)
        first.cancel()
        do { _ = try await first.value; Issue.record("Cancelled caller must throw") }
        catch is CancellationError {}
        #expect(await GrokCredentialRenewals.shared.pending[file.standardizedFileURL]?.task.isCancelled == false)
        try Data().write(to: URL(fileURLWithPath: file.path + ".release"))
        let renewed = try await second.value
        _ = try await GrokBuildUsageSource.fetchBilling(renewed) { request in
            let usesRenewedToken = request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-renewed-bearer"
            #expect(usesRenewedToken)
            return (try self.data(["config": ["creditUsagePercent": 25]]),
                try #require(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        #expect(launches.count == 1)
    }

    @Test func cancellingOneWaiterLeavesSharedRenewalRunningAndDoesNotStartDuplicates() async throws {
        let renewals = GrokCredentialRenewals(), release = TestSignal()
        let calls = RenewalObservations()
        let url = URL(fileURLWithPath: "/tmp/synthetic-renewal-" + UUID().uuidString)
        let credential = try #require(try GrokBuildUsageSource.credential(from: data(scoped(auth())), now: now))
        let operation: GrokCredentialRenewals.Operation = { _ in
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
        #expect(await renewals.pending[url]?.waiters.count == 1)
        #expect(await renewals.pending[url]?.task.isCancelled == false)
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
        let operation: GrokCredentialRenewals.Operation = { _ in
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
        first.cancel()
        do { _ = try await first.value; Issue.record("Cancelled waiter must throw") }
        catch is CancellationError {}
        second.cancel()
        #expect(await cancelled.wait(timeout: 1))
        let returned = TestSignal()
        let completion = Task {
            defer { returned.signal() }
            do { _ = try await second.value; Issue.record("Cancelled waiter must throw") }
            catch is CancellationError {}
        }
        #expect(!(await returned.wait(timeout: 0.05)))
        #expect(await renewals.pending[url] != nil)
        #expect(calls.count == 1)
        cleanup.signal()
        try await completion.value
        #expect(await returned.wait(timeout: 1))
        #expect(await renewals.pending[url] == nil)
        #expect(calls.count == 1)
    }

    @Test func finalWaiterCancellationReturnsWithinCleanupDeadline() async throws {
        let restored = TestSignal()
        let renewals = GrokCredentialRenewals(cancellationCleanupTimeout: 100_000_000, restore: { _ in restored.signal() })
        let cancelled = TestSignal(), cleanup = TestSignal()
        let url = URL(fileURLWithPath: "/tmp/synthetic-renewal-" + UUID().uuidString)
        let task = Task {
            try await renewals.refresh(at: url) { _ in
                do { try await Task.sleep(nanoseconds: 10_000_000_000) }
                catch {
                    cancelled.signal()
                    _ = await Task.detached { await cleanup.wait(timeout: 10) }.value
                    throw error
                }
                throw AIUsageError.invalidResponse
            }
        }
        defer { cleanup.signal(); task.cancel() }
        try await waitForWaiters(1, at: url, in: renewals)
        let entry = try #require(await renewals.pending[url])
        task.cancel()
        #expect(await cancelled.wait(timeout: 1))
        do { _ = try await boundedResult(task); Issue.record("Cancelled waiter must throw") }
        catch is CancellationError {}
        #expect(await restored.wait(timeout: 2))
        cleanup.signal()
        await entry.task.value
        try await waitForNoPending(at: url, in: renewals)
        #expect(await renewals.pending[url] == nil)
    }

    private func waitForNoPending(at url: URL, in renewals: GrokCredentialRenewals) async throws {
        for _ in 0..<1000 {
            if await renewals.pending[url] == nil { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw AIUsageError.timeout
    }

    private func waitForCleanupFailure(at url: URL, in renewals: GrokCredentialRenewals) async throws {
        for _ in 0..<1000 {
            if await renewals.pending[url]?.cleanupError != nil { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw AIUsageError.timeout
    }

    private func waitForQueued(_ count: Int, at url: URL, in renewals: GrokCredentialRenewals) async throws {
        for _ in 0..<1000 {
            if await renewals.pending[url]?.queued.count == count { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        Issue.record("Renewal did not register the expected cleanup waiters")
        throw AIUsageError.timeout
    }

    private func boundedResult(_ task: Task<GrokBuildUsageSource.Credential, Error>, timeout: TimeInterval = 2) async throws -> GrokBuildUsageSource.Credential {
        let returned = TestSignal()
        let completion = Task {
            let result = await task.result
            returned.signal()
            return result
        }
        try #require(await returned.wait(timeout: timeout), "Renewal caller must finish within the bound")
        return try await completion.value.get()
    }

    private func beginCancelledRenewal(at url: URL, in renewals: GrokCredentialRenewals,
        cleanup: RenewalGate, calls: RenewalObservations = RenewalObservations(),
        onStart: @escaping (GrokRenewalEpoch) throws -> Void = { _ in },
        onCleanup: @escaping (GrokRenewalEpoch) throws -> Void = { _ in }
    ) async throws -> Task<GrokBuildUsageSource.Credential, Error> {
        let started = TestSignal(), cancelled = TestSignal()
        let task = Task {
            try await renewals.refresh(at: url) { epoch in
                try onStart(epoch)
                calls.launched()
                started.signal()
                do { try await Task.sleep(nanoseconds: 10_000_000_000) }
                catch {
                    cancelled.signal()
                    await cleanup.wait()
                    try onCleanup(epoch)
                    throw error
                }
                throw AIUsageError.invalidResponse
            }
        }
        do {
            try #require(await started.wait(timeout: 2))
            task.cancel()
            try #require(await cancelled.wait(timeout: 2))
            return task
        } catch {
            task.cancel()
            cleanup.open()
            throw error
        }
    }

    @Test func newCallerDuringCleanupRunsFreshOperation() async throws {
        let renewals = GrokCredentialRenewals(cancellationCleanupTimeout: 60_000_000_000)
        let cleanup = RenewalGate(), calls = RenewalObservations()
        let file = try syntheticStore()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let original = try await beginCancelledRenewal(at: file, in: renewals, cleanup: cleanup, calls: calls, onCleanup: { epoch in
            try epoch.withCurrent { try CredentialFiles.restrictAfterRenewal(at: file) }
        })
        let fresh = try #require(try GrokBuildUsageSource.credential(from: data(scoped(auth())), now: now))
        let next = Task {
            try await renewals.refresh(at: file) { _ in
                calls.launched()
                let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
                #expect(permissions == 0o600)
                return fresh
            }
        }
        defer { cleanup.open(); original.cancel(); next.cancel() }
        try await waitForQueued(1, at: file, in: renewals)
        #expect(calls.count == 1)
        cleanup.open()
        do { _ = try await boundedResult(original); Issue.record("Original waiter must be cancelled") }
        catch is CancellationError {}
        let result = try await boundedResult(next)
        _ = try await GrokBuildUsageSource.fetchBilling(result) { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-test-bearer")
            return (try self.data(["config": ["creditUsagePercent": 25]]),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(calls.count == 2)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        #expect(await renewals.pending[file] == nil)
    }

    @Test func newCallerDuringCleanupCanBeCancelledWithoutAffectingLaterCallers() async throws {
        let renewals = GrokCredentialRenewals(), cleanup = RenewalGate(), calls = RenewalObservations()
        let url = URL(fileURLWithPath: "/tmp/synthetic-renewal-" + UUID().uuidString)
        let original = try await beginCancelledRenewal(at: url, in: renewals, cleanup: cleanup)
        let fresh = try #require(try GrokBuildUsageSource.credential(from: data(scoped(auth())), now: now))
        let cancelled = Task {
            try await renewals.refresh(at: url) { _ in calls.launched(); return fresh }
        }
        defer { cleanup.open(); original.cancel(); cancelled.cancel() }
        try await waitForQueued(1, at: url, in: renewals)
        cancelled.cancel()
        do { _ = try await boundedResult(cancelled, timeout: 1); Issue.record("Queued waiter must be cancelled") }
        catch is CancellationError {}
        #expect(await renewals.pending[url]?.queued.isEmpty == true)
        #expect(calls.count == 0)
        let next = Task { try await renewals.refresh(at: url) { _ in calls.launched(); return fresh } }
        defer { next.cancel() }
        try await waitForQueued(1, at: url, in: renewals)
        cleanup.open()
        _ = try await boundedResult(next)
        do { _ = try await boundedResult(original); Issue.record("Original waiter must be cancelled") }
        catch is CancellationError {}
        #expect(calls.count == 1)
        #expect(await renewals.pending[url] == nil)
    }

    @Test func twoNewCallersDuringCleanupShareOneFreshOperation() async throws {
        let renewals = GrokCredentialRenewals(), cleanup = RenewalGate(), release = RenewalGate()
        let calls = RenewalObservations()
        let url = URL(fileURLWithPath: "/tmp/synthetic-renewal-" + UUID().uuidString)
        let original = try await beginCancelledRenewal(at: url, in: renewals, cleanup: cleanup)
        let fresh = try #require(try GrokBuildUsageSource.credential(from: data(scoped(auth())), now: now))
        let operation: GrokCredentialRenewals.Operation = { _ in
            calls.launched()
            await release.wait()
            return fresh
        }
        let first = Task { try await renewals.refresh(at: url, operation: operation) }
        let second = Task { try await renewals.refresh(at: url, operation: operation) }
        defer { cleanup.open(); release.open(); original.cancel(); first.cancel(); second.cancel() }
        try await waitForQueued(2, at: url, in: renewals)
        #expect(calls.count == 0)
        cleanup.open()
        try await waitForWaiters(2, at: url, in: renewals)
        release.open()
        _ = try await boundedResult(first)
        _ = try await boundedResult(second)
        do { _ = try await boundedResult(original); Issue.record("Original waiter must be cancelled") }
        catch is CancellationError {}
        #expect(calls.count == 1)
        #expect(await renewals.pending[url] == nil)
    }

    @Test func stuckCleanupForceStopsRecordedChildRestoresPermissionsAndStartsFreshRenewal() async throws {
        let file = try syntheticStore()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let renewals = GrokCredentialRenewals(cancellationCleanupTimeout: 100_000_000)
        let cleanup = RenewalGate(), calls = RenewalObservations(), stops = RenewalObservations()
        let original = try await beginCancelledRenewal(at: file, in: renewals, cleanup: cleanup, calls: calls,
            onStart: { epoch in
                let pid = try epoch.launch {
                    GrokRenewalEpoch.Child(pid: 424242, stop: { pid in
                        #expect(pid == 424242) // Fake hook: never signal an actual process.
                        stops.launched()
                    }, cleanup: { Issue.record("Abandoned child must not be cleaned twice") })
                }
                #expect(pid == 424242)
            })
        let oldEntry = try #require(await renewals.pending[file])
        let fresh = try #require(try GrokBuildUsageSource.credential(from: data(scoped(auth())), now: now))
        let next = Task {
            try await renewals.refresh(at: file) { epoch in
                calls.launched()
                #expect(stops.count == 1)
                #expect(try self.permissions(file) == 0o600)
                try epoch.withCurrent {
                    try Data("fresh synthetic store".utf8).write(to: file)
                    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
                }
                try epoch.finish(at: file)
                return fresh
            }
        }
        defer { cleanup.open(); original.cancel(); next.cancel() }
        try await waitForQueued(1, at: file, in: renewals)
        _ = try await boundedResult(next, timeout: 1)
        do { _ = try await boundedResult(original); Issue.record("Original waiter must be cancelled") }
        catch is CancellationError {}
        #expect(calls.count == 2 && stops.count == 1)
        #expect(try permissions(file) == 0o600)
        cleanup.open()
        await oldEntry.task.value
        #expect(await renewals.pending[file] == nil)
        let later = Task { try await renewals.refresh(at: file) { _ in fresh } }
        _ = try await boundedResult(later)
    }

    @Test func abandonedWorkerCannotWriteOrLaunchLateOrClobberFreshEntry() async throws {
        let file = try syntheticStore()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let renewals = GrokCredentialRenewals(cancellationCleanupTimeout: 100_000_000)
        let cleanup = RenewalGate(), release = RenewalGate(), freshStarted = TestSignal()
        let rejected = RenewalObservations(), freshWritesFinished = TestSignal()
        let original = try await beginCancelledRenewal(at: file, in: renewals, cleanup: cleanup, onCleanup: { epoch in
            #expect(throws: CancellationError.self) {
                try epoch.withCurrent { try Data("stale write".utf8).write(to: file) }
            }
            #expect(throws: CancellationError.self) {
                try epoch.launch {
                    Issue.record("Stale worker must not launch another writer")
                    return GrokRenewalEpoch.Child(pid: 424243, stop: { _ in }, cleanup: {})
                }
            }
            #expect(throws: CancellationError.self) { try epoch.finish(at: file) }
            rejected.launched()
        })
        let oldEntry = try #require(await renewals.pending[file])
        let fresh = try #require(try GrokBuildUsageSource.credential(from: data(scoped(auth())), now: now))
        let next = Task {
            try await renewals.refresh(at: file) { epoch in
                let writer = Task.detached {
                    try epoch.withCurrent {
                        let deadline = ProcessInfo.processInfo.systemUptime + 5
                        repeat {
                            try Data("fresh write".utf8).write(to: file)
                            freshStarted.signal()
                            usleep(1_000)
                        } while rejected.count == 0 && ProcessInfo.processInfo.systemUptime < deadline
                        #expect(rejected.count == 1)
                    }
                }
                try await writer.value
                freshWritesFinished.signal()
                await release.wait()
                try epoch.finish(at: file)
                return fresh
            }
        }
        defer { if rejected.count == 0 { rejected.launched() }; cleanup.open(); release.open(); original.cancel(); next.cancel() }
        try #require(await freshStarted.wait(timeout: 1))
        let newID = try #require(await renewals.pending[file]?.id)
        #expect(newID != oldEntry.id)
        cleanup.open()
        await oldEntry.task.value
        #expect(rejected.count == 1)
        try #require(await freshWritesFinished.wait(timeout: 2))
        #expect(try Data(contentsOf: file) == Data("fresh write".utf8))
        #expect(await renewals.pending[file]?.id == newID)
        #expect(await renewals.pending[file]?.waiters.count == 1)
        release.open()
        _ = try await boundedResult(next)
        do { _ = try await boundedResult(original); Issue.record("Original waiter must be cancelled") }
        catch is CancellationError {}
        #expect(await renewals.pending[file] == nil)
        #expect(try permissions(file) == 0o600)
    }

    @Test func forceRestoreFailureFailsQueuedAndLaterCallersWithoutStartingRenewal() async throws {
        let renewals = GrokCredentialRenewals(cancellationCleanupTimeout: 100_000_000,
            restore: { _ in throw AIUsageError.invalidResponse })
        let cleanup = RenewalGate(), calls = RenewalObservations()
        let url = try syntheticStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original = try await beginCancelledRenewal(at: url, in: renewals, cleanup: cleanup)
        let oldEntry = try #require(await renewals.pending[url])
        let operation: GrokCredentialRenewals.Operation = { _ in
            calls.launched()
            throw AIUsageError.timeout
        }
        let first = Task { try await renewals.refresh(at: url, operation: operation) }
        let second = Task { try await renewals.refresh(at: url, operation: operation) }
        defer { cleanup.open(); original.cancel(); first.cancel(); second.cancel() }
        try await waitForQueued(2, at: url, in: renewals)
        for caller in [first, second] {
            do { _ = try await boundedResult(caller, timeout: 1); Issue.record("Restore failure must be returned") }
            catch AIUsageError.invalidResponse {}
        }
        cleanup.open()
        await oldEntry.task.value
        let later = Task { try await renewals.refresh(at: url, operation: operation) }
        do { _ = try await boundedResult(later); Issue.record("Unsafe store must remain blocked") }
        catch AIUsageError.invalidResponse {}
        do { _ = try await boundedResult(original); Issue.record("Original waiter must be cancelled") }
        catch is CancellationError {}
        #expect(calls.count == 0)
        #expect(await renewals.pending[url]?.cleanupError != nil)
        #expect(await renewals.pending[url]?.queued.isEmpty == true)
    }

    @Test func failedChildStopDoesNotRestorePermissionsOrStartFreshRenewal() async throws {
        let file = try syntheticStore()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let renewals = GrokCredentialRenewals(cancellationCleanupTimeout: 100_000_000)
        let cleanup = RenewalGate(), calls = RenewalObservations()
        let original = try await beginCancelledRenewal(at: file, in: renewals, cleanup: cleanup, onStart: { epoch in
            _ = try epoch.launch {
                GrokRenewalEpoch.Child(pid: 424244, stop: { _ in throw AIUsageError.timeout }, cleanup: {})
            }
        })
        let oldEntry = try #require(await renewals.pending[file])
        let next = Task {
            try await renewals.refresh(at: file) { _ in calls.launched(); throw AIUsageError.invalidResponse }
        }
        defer { cleanup.open(); original.cancel(); next.cancel() }
        do { _ = try await boundedResult(next); Issue.record("Unconfirmed child exit must block the next writer") }
        catch AIUsageError.timeout {}
        #expect(calls.count == 0)
        #expect(try permissions(file) == 0o644)
        cleanup.open()
        await oldEntry.task.value
        #expect(try permissions(file) == 0o644)
        do { _ = try await boundedResult(original); Issue.record("Original waiter must be cancelled") }
        catch is CancellationError {}
    }

    @Test func multipleQueuedCallersShareFreshRenewalAfterForceStop() async throws {
        let renewals = GrokCredentialRenewals(cancellationCleanupTimeout: 100_000_000, restore: { _ in })
        let cleanup = RenewalGate(), release = RenewalGate(), started = TestSignal()
        let calls = RenewalObservations()
        let url = try syntheticStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original = try await beginCancelledRenewal(at: url, in: renewals, cleanup: cleanup)
        let oldEntry = try #require(await renewals.pending[url])
        let fresh = try #require(try GrokBuildUsageSource.credential(from: data(scoped(auth())), now: now))
        let operation: GrokCredentialRenewals.Operation = { _ in
            calls.launched()
            started.signal()
            await release.wait()
            return fresh
        }
        let first = Task { try await renewals.refresh(at: url, operation: operation) }
        let second = Task { try await renewals.refresh(at: url, operation: operation) }
        let cancelled = Task { try await renewals.refresh(at: url, operation: operation) }
        defer { cleanup.open(); release.open(); original.cancel(); first.cancel(); second.cancel(); cancelled.cancel() }
        try await waitForQueued(3, at: url, in: renewals)
        cancelled.cancel()
        do { _ = try await boundedResult(cancelled); Issue.record("Queued caller must be cancelled") }
        catch is CancellationError {}
        try #require(await started.wait(timeout: 1))
        try await waitForWaiters(2, at: url, in: renewals)
        let later = Task { try await renewals.refresh(at: url, operation: operation) }
        defer { later.cancel() }
        try await waitForWaiters(3, at: url, in: renewals)
        cleanup.open()
        await oldEntry.task.value
        #expect(await renewals.pending[url]?.waiters.count == 3)
        #expect(calls.count == 1)
        release.open()
        for caller in [first, second, later] { _ = try await boundedResult(caller) }
        do { _ = try await boundedResult(original); Issue.record("Original waiter must be cancelled") }
        catch is CancellationError {}
        #expect(await renewals.pending[url] == nil)
    }

    @Test func queuedCallersCanCancelWhileForcedChildStopIsInProgress() async throws {
        let renewals = GrokCredentialRenewals(cancellationCleanupTimeout: 100_000_000, restore: { _ in })
        let cleanup = RenewalGate(), stopping = TestSignal(), calls = RenewalObservations()
        let stopRelease = DispatchSemaphore(value: 0)
        let url = try syntheticStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original = try await beginCancelledRenewal(at: url, in: renewals, cleanup: cleanup, onStart: { epoch in
            _ = try epoch.launch {
                GrokRenewalEpoch.Child(pid: 424245, stop: { pid in
                    #expect(pid == 424245)
                    stopping.signal()
                    guard stopRelease.wait(timeout: .now() + 2) == .success else { throw AIUsageError.timeout }
                }, cleanup: {})
            }
        })
        let oldEntry = try #require(await renewals.pending[url])
        defer { stopRelease.signal(); cleanup.open(); original.cancel() }
        try #require(await stopping.wait(timeout: 1))
        // The original cancellation deadline is independent of force-stop completion.
        do { _ = try await boundedResult(original, timeout: 1); Issue.record("Original waiter must be cancelled") }
        catch is CancellationError {}
        let fresh = try #require(try GrokBuildUsageSource.credential(from: data(scoped(auth())), now: now))
        let operation: GrokCredentialRenewals.Operation = { _ in calls.launched(); return fresh }
        let next = Task { try await renewals.refresh(at: url, operation: operation) }
        let cancelled = Task { try await renewals.refresh(at: url, operation: operation) }
        defer { next.cancel(); cancelled.cancel() }
        try await waitForQueued(2, at: url, in: renewals)
        cancelled.cancel()
        do { _ = try await boundedResult(cancelled, timeout: 1); Issue.record("Queued caller must be cancelled") }
        catch is CancellationError {}
        #expect(calls.count == 0)
        stopRelease.signal()
        _ = try await boundedResult(next)
        cleanup.open()
        await oldEntry.task.value
        #expect(calls.count == 1)
        #expect(await renewals.pending[url] == nil)
    }

    private func syntheticStore() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("grok-store-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("synthetic-store")
        try Data().write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        return file
    }

    private func permissions(_ file: URL) throws -> Int? {
        try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
    }
}

extension TidyBarTests.GrokBuildUsageTests {
    @Test func successfulAbandonmentHasNoUnresolvedOriginalContinuations() async throws {
        let file = try syntheticStore(), cleanup = RenewalGate(), stopping = TestSignal()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let release = DispatchSemaphore(value: 0)
        let renewals = GrokCredentialRenewals(cancellationCleanupTimeout: 100_000_000)
        let original = try await beginCancelledRenewal(at: file, in: renewals, cleanup: cleanup, onStart: { epoch in
            _ = try epoch.launch {
                GrokRenewalEpoch.Child(pid: 424249, stop: { _ in
                    stopping.signal()
                    #expect(release.wait(timeout: .now() + 5) == .success)
                }, cleanup: {})
            }
        })
        let entry = try #require(await renewals.pending[file])
        defer { release.signal(); cleanup.open(); original.cancel() }
        try #require(await stopping.wait(timeout: 2))
        do { _ = try await boundedResult(original, timeout: 1); Issue.record("Original cancellation must precede abandonment success") }
        catch is CancellationError {}
        #expect(await renewals.pending[file]?.waiters.isEmpty == true)
        #expect(await renewals.pending[file]?.cancellations.isEmpty == true)
        release.signal()
        try await waitForNoPending(at: file, in: renewals)
        cleanup.open()
        await entry.task.value
        #expect(await renewals.pending[file] == nil)
    }

    @Test func normalCleanupFailureCompensatesStopAndRestoreAndRevokesOldWrites() async throws {
        let file = try syntheticStore(), cleanup = RenewalGate(), restored = TestSignal()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let stops = RenewalObservations(), restores = RenewalObservations(), calls = RenewalObservations()
        let renewals = GrokCredentialRenewals(cancellationCleanupTimeout: 60_000_000_000, restore: { url in
            restores.launched()
            if restores.count == 1 { throw AIUsageError.invalidResponse }
            try CredentialFiles.restrictAfterRenewal(at: url)
            restored.signal()
        })
        let original = try await beginCancelledRenewal(at: file, in: renewals, cleanup: cleanup, onStart: { epoch in
            _ = try epoch.launch {
                GrokRenewalEpoch.Child(pid: 424250, stop: { _ in
                    stops.launched()
                    if stops.count == 1 { throw AIUsageError.timeout }
                }, cleanup: { throw AIUsageError.timeout })
            }
        }, onCleanup: { epoch in
            do { try epoch.finish(at: file) }
            catch {
                #expect(throws: CancellationError.self) {
                    try epoch.withCurrent { try Data("stale".utf8).write(to: file) }
                }
                throw error
            }
        })
        let next = Task {
            try await renewals.refresh(at: file) { _ in calls.launched(); throw AIUsageError.invalidResponse }
        }
        defer { cleanup.open(); original.cancel(); next.cancel() }
        try await waitForQueued(1, at: file, in: renewals)
        cleanup.open()
        do { _ = try await boundedResult(next); Issue.record("Normal cleanup failure must fail the queue") }
        catch AIUsageError.timeout {}
        do { _ = try await boundedResult(original); Issue.record("Original cancellation must return before its long timer") }
        catch is CancellationError {}
        try #require(await restored.wait(timeout: 2))
        #expect(stops.count == 2 && restores.count == 2)
        #expect(try permissions(file) == 0o600)
        #expect(try Data(contentsOf: file).isEmpty)
        let later = Task {
            try await renewals.refresh(at: file) { _ in calls.launched(); throw AIUsageError.invalidResponse }
        }
        do { _ = try await boundedResult(later); Issue.record("Compensation must preserve the fail-closed store lock") }
        catch AIUsageError.timeout {}
        #expect(calls.count == 0)
        #expect(await renewals.pending[file]?.cleanupError != nil)
    }

    @Test func lateSpawnAfterCleanupTimeoutIsStoppedAndRestored() async throws {
        let file = try syntheticStore(), cleanup = RenewalGate()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let completed = TestSignal(), stopped = TestSignal(), restored = TestSignal()
        let stops = RenewalObservations()
        let renewals = GrokCredentialRenewals(cancellationCleanupTimeout: 100_000_000,
            cleanupWaitTimeout: 100_000_000, restore: { url in
                #expect(stops.count == 1)
                try CredentialFiles.restrictAfterRenewal(at: url)
                restored.signal()
            })
        let original = try await beginCancelledRenewal(at: file, in: renewals, cleanup: cleanup, onStart: { epoch in
            Task.detached {
                defer { completed.signal() }
                do {
                    _ = try epoch.launch {
                        entered.signal()
                        #expect(release.wait(timeout: .now() + 5) == .success)
                        return GrokRenewalEpoch.Child(pid: 424251, stop: { _ in
                            stops.launched()
                            stopped.signal()
                        }, cleanup: {})
                    }
                    #expect(throws: CancellationError.self) {
                        try epoch.withCurrent { try Data("stale".utf8).write(to: file) }
                    }
                } catch { Issue.record("In-flight spawn must finish recording its child") }
            }
            #expect(entered.wait(timeout: .now() + 2) == .success)
        })
        let entry = try #require(await renewals.pending[file])
        defer { release.signal(); cleanup.open(); original.cancel() }
        do { _ = try await boundedResult(original); Issue.record("Original cancellation must return") }
        catch is CancellationError {}
        let next = Task {
            try await renewals.refresh(at: file) { _ in Issue.record("Late spawn must keep the store locked"); throw AIUsageError.invalidResponse }
        }
        do { _ = try await boundedResult(next); Issue.record("Stuck spawn must time out the queue") }
        catch AIUsageError.timeout {}
        try await waitForCleanupFailure(at: file, in: renewals)
        #expect(await renewals.pending[file]?.cleanupError != nil)
        release.signal()
        try #require(await completed.wait(timeout: 2))
        try #require(await stopped.wait(timeout: 2))
        try #require(await restored.wait(timeout: 2))
        #expect(stops.count == 1)
        #expect(try permissions(file) == 0o600)
        #expect(try Data(contentsOf: file).isEmpty)
        cleanup.open()
        await entry.task.value
        #expect(await renewals.pending[file]?.cleanupError != nil)
    }

    @Test func normalCleanupFailureFailsQueuedAndLaterCallersWithoutRestoring() async throws {
        let file = try syntheticStore()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let restored = RenewalObservations(), cleanup = RenewalGate(), calls = RenewalObservations()
        let renewals = GrokCredentialRenewals(cancellationCleanupTimeout: 60_000_000_000,
            restore: { _ in restored.launched() })
        let original = try await beginCancelledRenewal(at: file, in: renewals, cleanup: cleanup,
            onStart: { epoch in
                _ = try epoch.launch {
                    GrokRenewalEpoch.Child(pid: 424246, stop: { _ in throw AIUsageError.timeout },
                        cleanup: { throw AIUsageError.timeout })
                }
            }, onCleanup: { try $0.finish(at: file) })
        let next = Task {
            try await renewals.refresh(at: file) { _ in calls.launched(); throw AIUsageError.invalidResponse }
        }
        defer { cleanup.open(); original.cancel(); next.cancel() }
        try await waitForQueued(1, at: file, in: renewals)
        cleanup.open()
        do { _ = try await boundedResult(next); Issue.record("Cleanup failure must fail the queued caller") }
        catch AIUsageError.timeout {}
        let later = Task {
            try await renewals.refresh(at: file) { _ in calls.launched(); throw AIUsageError.invalidResponse }
        }
        do { _ = try await boundedResult(later); Issue.record("Failed cleanup must keep the store blocked") }
        catch AIUsageError.timeout {}
        do { _ = try await boundedResult(original); Issue.record("Original caller must be cancelled") }
        catch is CancellationError {}
        #expect(restored.count == 0 && calls.count == 0)
        #expect(try permissions(file) == 0o644)
    }

    @Test func recordedWriterStopsBeforeActiveDrainAndHonorsConfiguredCleanupWait() async throws {
        let file = try syntheticStore(), cleanup = RenewalGate()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let completed = TestSignal(), stopped = TestSignal()
        let renewals = GrokCredentialRenewals(cancellationCleanupTimeout: 50_000_000,
            cleanupWaitTimeout: 3_000_000_000)
        let original = try await beginCancelledRenewal(at: file, in: renewals, cleanup: cleanup, onStart: { epoch in
            _ = try epoch.launch {
                let process = try CLIProcess(executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "trap '' TERM; while :; do printf stale > \"$STORE\"; /bin/chmod 644 \"$STORE\"; /bin/sleep 0.01; done"],
                    environment: ["STORE": file.path], directory: file.deletingLastPathComponent())
                return GrokRenewalEpoch.Child(pid: process.processIdentifier, stop: { _ in
                    try process.stopRecordedChild()
                    stopped.signal()
                }, cleanup: { try process.stopRecordedChild() })
            }
            Task.detached {
                defer { completed.signal() }
                do {
                    try epoch.withCurrent {
                        entered.signal()
                        #expect(release.wait(timeout: .now() + 5) == .success)
                    }
                } catch { Issue.record("Active operation must enter before cancellation") }
            }
            #expect(entered.wait(timeout: .now() + 2) == .success)
        })
        let entry = try #require(await renewals.pending[file])
        let fresh = try #require(try GrokBuildUsageSource.credential(from: data(scoped(auth())), now: now))
        let next = Task {
            try await renewals.refresh(at: file) { epoch in
                #expect(try self.permissions(file) == 0o600)
                try epoch.withCurrent { try Data("fresh".utf8).write(to: file) }
                return fresh
            }
        }
        defer { release.signal(); cleanup.open(); original.cancel(); next.cancel() }
        try await waitForQueued(1, at: file, in: renewals)
        try #require(await stopped.wait(timeout: 1))
        do { _ = try await boundedResult(original); Issue.record("Original cancellation must return while active work is blocked") }
        catch is CancellationError {}
        // A legitimate cleanup taking over one second still fits the configured three seconds.
        try await Task.sleep(nanoseconds: 1_100_000_000)
        #expect(await renewals.pending[file]?.cleanupError == nil)
        #expect(await renewals.pending[file]?.abandoned == true)
        release.signal()
        try #require(await completed.wait(timeout: 2))
        _ = try await boundedResult(next)
        #expect(try Data(contentsOf: file) == Data("fresh".utf8))
        cleanup.open()
        await entry.task.value
        #expect(await renewals.pending[file] == nil)
    }

    @Test func normalFinishUsesInjectedRestore() throws {
        let restored = RenewalObservations()
        let epoch = GrokRenewalEpoch(restore: { _ in restored.launched() })
        try epoch.finish(at: FileManager.default.temporaryDirectory.appendingPathComponent("unused-synthetic-url"))
        #expect(restored.count == 1)
    }

    @Test func queuedWaiterTimesOutWhileCleanupRemainsPending() async throws {
        let file = try syntheticStore()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let renewals = GrokCredentialRenewals(cancellationCleanupTimeout: 60_000_000_000,
            cleanupWaitTimeout: 100_000_000)
        let cleanup = RenewalGate(), calls = RenewalObservations()
        let original = try await beginCancelledRenewal(at: file, in: renewals, cleanup: cleanup)
        let entry = try #require(await renewals.pending[file])
        let next = Task {
            try await renewals.refresh(at: file) { _ in calls.launched(); throw AIUsageError.invalidResponse }
        }
        defer { cleanup.open(); original.cancel(); next.cancel() }
        do { _ = try await boundedResult(next); Issue.record("Queued waiter must time out") }
        catch AIUsageError.timeout {}
        #expect(calls.count == 0)
        #expect(await renewals.pending[file]?.id == entry.id)
        #expect(await renewals.pending[file]?.queued.isEmpty == true)
        cleanup.open()
        await entry.task.value
        do { _ = try await boundedResult(original); Issue.record("Original caller must be cancelled") }
        catch is CancellationError {}
    }

    @Test func stuckForceStopTimesOutAndLateSuccessCannotReopenStore() async throws {
        let file = try syntheticStore()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let cleanup = RenewalGate(), stopping = TestSignal(), stopped = TestSignal(), restored = TestSignal(), calls = RenewalObservations()
        let stopRelease = DispatchSemaphore(value: 0)
        let renewals = GrokCredentialRenewals(cancellationCleanupTimeout: 100_000_000,
            cleanupWaitTimeout: 100_000_000, restore: { url in
                try CredentialFiles.restrictAfterRenewal(at: url)
                restored.signal()
            })
        let original = try await beginCancelledRenewal(at: file, in: renewals, cleanup: cleanup, onStart: { epoch in
            _ = try epoch.launch {
                GrokRenewalEpoch.Child(pid: 424247, stop: { _ in
                    stopping.signal()
                    guard stopRelease.wait(timeout: .now() + 5) == .success else { throw AIUsageError.timeout }
                    stopped.signal()
                }, cleanup: {})
            }
        })
        let entry = try #require(await renewals.pending[file])
        defer { stopRelease.signal(); cleanup.open(); original.cancel() }
        try #require(await stopping.wait(timeout: 2))
        let next = Task {
            try await renewals.refresh(at: file) { _ in calls.launched(); throw AIUsageError.invalidResponse }
        }
        defer { next.cancel() }
        do { _ = try await boundedResult(next); Issue.record("Stuck force stop must fail the queue") }
        catch AIUsageError.timeout {}
        try await waitForCleanupFailure(at: file, in: renewals)
        #expect(try permissions(file) == 0o644)
        stopRelease.signal()
        try #require(await stopped.wait(timeout: 2))
        try #require(await restored.wait(timeout: 2))
        #expect(try permissions(file) == 0o600)
        cleanup.open()
        await entry.task.value
        let later = Task {
            try await renewals.refresh(at: file) { _ in calls.launched(); throw AIUsageError.invalidResponse }
        }
        do { _ = try await boundedResult(later); Issue.record("Late success must not reopen the entry") }
        catch AIUsageError.timeout {}
        #expect(calls.count == 0)
        #expect(await renewals.pending[file]?.cleanupError != nil)
        do { _ = try await boundedResult(original); Issue.record("Original caller must be cancelled") }
        catch is CancellationError {}
    }

    @Test func blockedCurrentOperationCannotHoldRevocationLockOrHangQueue() async throws {
        let file = try syntheticStore()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let cleanup = RenewalGate(), completed = TestSignal(), restored = TestSignal()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let renewals = GrokCredentialRenewals(cancellationCleanupTimeout: 100_000_000,
            cleanupWaitTimeout: 100_000_000, restore: { url in
                try CredentialFiles.restrictAfterRenewal(at: url)
                restored.signal()
            })
        let original = try await beginCancelledRenewal(at: file, in: renewals, cleanup: cleanup, onStart: { epoch in
            Task.detached {
                defer { completed.signal() }
                do {
                    try epoch.withCurrent {
                        entered.signal()
                        #expect(release.wait(timeout: .now() + 5) == .success)
                    }
                } catch { Issue.record("Test operation was revoked before entering") }
            }
            #expect(entered.wait(timeout: .now() + 2) == .success)
        })
        let entry = try #require(await renewals.pending[file])
        let next = Task {
            try await renewals.refresh(at: file) { _ in Issue.record("Blocked old writer forbids fresh operation"); throw AIUsageError.invalidResponse }
        }
        defer { release.signal(); cleanup.open(); original.cancel(); next.cancel() }
        do { _ = try await boundedResult(original); Issue.record("Original caller must be cancelled") }
        catch is CancellationError {}
        do { _ = try await boundedResult(next, timeout: 3); Issue.record("Quiescence must have a bound") }
        catch AIUsageError.timeout {}
        try await waitForCleanupFailure(at: file, in: renewals)
        #expect(!(await restored.wait(timeout: 0.01)))
        #expect(try permissions(file) == 0o644)
        release.signal()
        try #require(await completed.wait(timeout: 2))
        try #require(await restored.wait(timeout: 2))
        #expect(try permissions(file) == 0o600)
        cleanup.open()
        await entry.task.value
        #expect(await renewals.pending[file]?.cleanupError != nil)
    }

    @Test func waitersArrivingAndCancellingDuringFailedStopUseLiveActorState() async throws {
        let file = try syntheticStore()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let cleanup = RenewalGate(), stopping = TestSignal(), calls = RenewalObservations(), stops = RenewalObservations()
        let release = DispatchSemaphore(value: 0)
        let renewals = GrokCredentialRenewals(cancellationCleanupTimeout: 100_000_000)
        let original = try await beginCancelledRenewal(at: file, in: renewals, cleanup: cleanup, onStart: { epoch in
            _ = try epoch.launch {
                GrokRenewalEpoch.Child(pid: 424248, stop: { _ in
                    stops.launched()
                    stopping.signal()
                    if stops.count == 1 { _ = release.wait(timeout: .now() + 5) }
                    throw AIUsageError.invalidResponse
                }, cleanup: {})
            }
        })
        let entry = try #require(await renewals.pending[file])
        defer { release.signal(); cleanup.open(); original.cancel() }
        try #require(await stopping.wait(timeout: 2))
        let operation: GrokCredentialRenewals.Operation = { _ in calls.launched(); throw AIUsageError.timeout }
        let first = Task { try await renewals.refresh(at: file, operation: operation) }
        let cancelled = Task { try await renewals.refresh(at: file, operation: operation) }
        defer { first.cancel(); cancelled.cancel() }
        try await waitForQueued(2, at: file, in: renewals)
        cancelled.cancel()
        do { _ = try await boundedResult(cancelled); Issue.record("Queued cancellation must complete once") }
        catch is CancellationError {}
        let late = Task { try await renewals.refresh(at: file, operation: operation) }
        defer { late.cancel() }
        try await waitForQueued(2, at: file, in: renewals)
        release.signal()
        for caller in [first, late] {
            do { _ = try await boundedResult(caller); Issue.record("Live queued callers must receive stop failure") }
            catch AIUsageError.invalidResponse {}
        }
        cleanup.open()
        await entry.task.value
        #expect(calls.count == 0)
        #expect(await renewals.pending[file]?.queued.isEmpty == true)
        #expect(try permissions(file) == 0o644)
        do { _ = try await boundedResult(original); Issue.record("Original caller must be cancelled") }
        catch is CancellationError {}
    }

    @Test func forcedStopEndsRealDescendantWriterBeforeFreshWritesAndFinalRestriction() async throws {
        let file = try syntheticStore(), cleanup = RenewalGate()
        let folder = file.deletingLastPathComponent(), pidsFile = file.deletingLastPathComponent().appendingPathComponent("pids")
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("writer.sh")
        try """
        trap '' TERM
        if [ "$1" = writer ]; then
          while :; do printf stale > "$STORE"; /bin/chmod 644 "$STORE"; /bin/sleep 0.01; done
        fi
        if [ "$1" = middle ]; then
          /bin/sh "$0" writer &
          printf '%s\\n%s\\n' "$$" "$!" > "$PIDS"
          wait
          exit
        fi
        /bin/sh "$0" middle &
        wait
        """.write(to: script, atomically: true, encoding: .utf8)
        let renewals = GrokCredentialRenewals(cancellationCleanupTimeout: 100_000_000)
        let original = try await beginCancelledRenewal(at: file, in: renewals, cleanup: cleanup, onStart: { epoch in
            _ = try epoch.launch {
                let process = try CLIProcess(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [script.path],
                    environment: ["STORE": file.path, "PIDS": pidsFile.path], directory: folder)
                return GrokRenewalEpoch.Child(pid: process.processIdentifier,
                    stop: { _ in try process.stopRecordedChild() }, cleanup: { try process.stopRecordedChild() })
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while (try? Data(contentsOf: file)) != Data("stale".utf8) || !FileManager.default.fileExists(atPath: pidsFile.path) {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw AIUsageError.timeout }
                usleep(5_000)
            }
        })
        let descendants = try await ProcessTreeFixture.pids(at: pidsFile)
        let entry = try #require(await renewals.pending[file])
        let fresh = try #require(try GrokBuildUsageSource.credential(from: data(scoped(auth())), now: now))
        let next = Task {
            try await renewals.refresh(at: file) { epoch in
                #expect(try self.permissions(file) == 0o600)
                try await ProcessTreeFixture.expectExited(descendants)
                for _ in 0..<20 {
                    try epoch.withCurrent { try Data("fresh".utf8).write(to: file) }
                    try await Task.sleep(nanoseconds: 5_000_000)
                    #expect(try Data(contentsOf: file) == Data("fresh".utf8))
                }
                try epoch.finish(at: file)
                return fresh
            }
        }
        defer { cleanup.open(); original.cancel(); next.cancel() }
        _ = try await boundedResult(next, timeout: 5)
        cleanup.open()
        await entry.task.value
        do { _ = try await boundedResult(original); Issue.record("Original caller must be cancelled") }
        catch is CancellationError {}
        #expect(try permissions(file) == 0o600)
        #expect(try Data(contentsOf: file) == Data("fresh".utf8))
    }

    @Test func processObservationRetainsPIDUntilGroupCleanupAndHandlesExternalReap() async throws {
        for code in [0, 23] {
            let process = try CLIProcess(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit \(code)"],
                environment: [:], directory: FileManager.default.temporaryDirectory)
            defer { process.terminateAndWait() }
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while process.isRunning {
                try #require(ProcessInfo.processInfo.systemUptime < deadline)
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            #expect(process.succeeded == (code == 0))
            var info = siginfo_t()
            #expect(waitid(P_PID, id_t(process.processIdentifier), &info, WEXITED | WNOHANG | WNOWAIT) == 0)
            #expect(info.si_pid == process.processIdentifier) // isRunning has not reaped it.
            if code == 23 {
                var status: Int32 = 0
                #expect(waitpid(process.processIdentifier, &status, WNOHANG) == process.processIdentifier)
            }
            try process.stopRecordedChild() // ECHILD is terminal too; no later signals.
            try process.stopRecordedChild()
            #expect(kill(process.processIdentifier, 0) != 0)
        }
    }

    @Test func failedProcessCleanupCanRetryAfterOwnershipLossWithoutSignalling() async throws {
        let file = try syntheticStore(), release = file.deletingLastPathComponent().appendingPathComponent("release")
        let folder = file.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let process = try CLIProcess(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "(while [ -d \"$FOLDER\" ] && [ ! -f \"$RELEASE\" ]; do /bin/sleep 0.01; done) & exit 0"],
            environment: ["FOLDER": folder.path, "RELEASE": release.path], directory: folder)
        defer { process.terminateAndWait() }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while process.isRunning {
            try #require(ProcessInfo.processInfo.systemUptime < deadline)
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        // Simulate loss of ownership of our recorded leader. Neither cleanup may signal
        // the remaining group; its writer exits only after the explicit fixture release.
        var status: Int32 = 0
        try #require(waitpid(process.processIdentifier, &status, WNOHANG) == process.processIdentifier)
        do { try process.stopRecordedChild(); Issue.record("A live group with a reaped leader cannot confirm cleanup") }
        catch let error as POSIXError { #expect(error.code == .ECHILD) }
        try Data().write(to: release)
        let cleanupDeadline = ProcessInfo.processInfo.systemUptime + 2
        while true {
            do { try process.stopRecordedChild(); break }
            catch let error as POSIXError {
                #expect(error.code == .ECHILD)
                try #require(ProcessInfo.processInfo.systemUptime < cleanupDeadline, "A failed cleanup must be retryable after the group exits")
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        try process.stopRecordedChild()
    }
}
