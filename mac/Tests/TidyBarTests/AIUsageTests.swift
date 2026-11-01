import Foundation
import Darwin
import Testing
@testable import TidyBar

extension TidyBarTests {
@Suite
final class AIUsageTests {
    private func suspendedCLI() throws -> (folder: URL, executable: URL, pids: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tidy-usage-cancel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("test-cli")
        // Ignore TERM so cancellation must also exercise the bounded SIGKILL/reap path.
        let body = "#!/bin/sh\ntrap '' TERM\nprintf '%s\\n' $$ >> \"$0.pids\"\nexec /bin/sleep 30\n"
        try Data(body.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return (folder, script, URL(fileURLWithPath: script.path + ".pids"))
    }

    private func waitForFixturePIDs(_ file: URL, count: Int) async throws -> [pid_t] {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let text = try? String(contentsOf: file, encoding: .utf8), text.hasSuffix("\n") {
                let pids = text.split(separator: "\n").compactMap { Int32($0) }
                if pids.count >= count { return pids }
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        Issue.record("临时 CLI 未在期限内启动")
        throw AIUsageError.timeout
    }

    private func waitForFixtureExit(_ pid: pid_t) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if kill(pid, 0) != 0 { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        Issue.record("已取消的 CLI 子进程未及时回收")
    }

    @Test
    func testCancelledFetchPromptlyReapsItsTERMResistantCLI() async throws {
        let fixture = try suspendedCLI()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let fetch = Task { try await CodexUsageSource.fetch(executable: fixture.executable) }
        defer { fetch.cancel() }
        let pid = try await waitForFixturePIDs(fixture.pids, count: 1)[0]
        let cancelledAt = Date()
        fetch.cancel()
        do { _ = try await fetch.value; Issue.record("已取消的读取不得返回成功") }
        catch { #expect(error is CancellationError) }
        #expect(Date().timeIntervalSince(cancelledAt) < 2, "取消不应等待默认 20 秒超时")
        #expect(kill(pid, 0) != 0, "fetch 返回时必须已回收真实 CLI 子进程")
    }

    @MainActor
    @Test
    func testStopThenImmediateRefreshLeavesNoOldCLIProcess() async throws {
        let fixture = try suspendedCLI()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let store = AIUsageStore(fetcher: { _ in try await CodexUsageSource.fetch(executable: fixture.executable) })
        defer { store.stop() }
        let original = store.snapshots
        store.refresh(provider: .codex)
        let oldPID = try await waitForFixturePIDs(fixture.pids, count: 1)[0]
        store.stop()
        store.refresh(provider: .codex)
        let pids = try await waitForFixturePIDs(fixture.pids, count: 2)
        let newPID = pids[1]
        #expect(oldPID != newPID)
        try await waitForFixtureExit(oldPID)
        #expect(kill(newPID, 0) == 0, "停止旧读取不能终止新读取")
        #expect(store.isRefreshing)
        #expect(store.snapshots == original)
        store.stop()
        try await waitForFixtureExit(newPID)
        #expect(!(store.isRefreshing))
    }

    @Test
    func testCodexTimeoutAndCancellationTerminateTheWholeProcessGroup() async throws {
        for timedOut in [false, true] {
            let fixture = try suspendedCLI()
            defer { try? FileManager.default.removeItem(at: fixture.folder) }
            try Data(("#!/bin/sh\n" + ProcessTreeFixture.script(pids: fixture.pids)).utf8).write(to: fixture.executable)
            let task = Task { try await CodexUsageSource.fetch(executable: fixture.executable, timeout: timedOut ? 0.6 : 20) }
            defer { task.cancel() }
            let descendants = try await ProcessTreeFixture.pids(at: fixture.pids)
            let leader = getpgid(descendants[0])
            #expect(leader > 0 && leader != getpgrp())
            #expect(getpgid(leader) == leader)
            for child in descendants { #expect(getpgid(child) == leader) }
            if !timedOut { task.cancel() }
            do { _ = try await task.value; Issue.record("Codex read must not succeed") }
            catch {
                if timedOut { #expect(error.localizedDescription == AIUsageError.timeout.localizedDescription) }
                else { #expect(error is CancellationError) }
            }
            try await ProcessTreeFixture.expectExited([leader] + descendants)
            var status: Int32 = 0
            #expect(waitpid(leader, &status, WNOHANG) == -1 && errno == ECHILD)
        }
    }

    @Test
    func testCLIClosingItsInputReturnsFailureWithoutTerminatingTheApp() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tidy-usage-closed-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("test-cli")
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        #expect(throws: (any Error).self) { try CodexUsageSource.readFromCLI(executable: script, timeout: 1) }
    }

    @Test
    func testCLIReadTimeoutReapsTheChildAndDrainsNoSensitiveOutput() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tidy-usage-timeout-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("test-cli")
        let body = "#!/bin/sh\n/usr/bin/head -c 524288 /dev/zero >&2\nexec /bin/sleep 30\n"
        try Data(body.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        var launchedPID: pid_t?
        // Observe the spawned process directly: a response deadline need not allow shell side effects.
        #expect(throws: (any Error).self) { try CodexUsageSource.readFromCLI(executable: script, timeout: 0.3, onLaunch: { pid in
            launchedPID = pid
            #expect(pid > 0)
            #expect(kill(pid, 0) == 0, "开始等待超时前必须存在真实子进程")
        }) }.map { error in
            #expect(error.localizedDescription == AIUsageError.timeout.localizedDescription)
        }
        let pid = try #require(launchedPID)
        #expect(kill(pid, 0) != 0, "超时后的本机接口进程必须退出")
    }

    @Test
    func testCodexParsesAllBucketsAndSecondsWithoutInventingMissingWindow() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let response: [String: Any] = ["rateLimitsByLimitId": [
            "codex": ["primary": ["usedPercent": 9, "windowDurationMins": 10080, "resetsAt": 1_802_000_000],
                      "secondary": NSNull(), "planType": "pro", "credits": ["hasCredits": true, "unlimited": false, "balance": "123.45"]],
            "other": ["primary": ["usedPercent": 100, "windowDurationMins": 300]]
        ]]
        let result = try CodexUsageSource.parse(response, now: now)
        #expect(result.isConnected)
        #expect(result.plan == "pro")
        #expect(result.balance == "123.45 额度")
        #expect(result.windows.count == 2)
        #expect(result.windows[0].remainingPercent == 91)
        #expect(result.windows[0].resetsAt?.timeIntervalSince1970 == 1_802_000_000)
        #expect(result.windows[1].resetsAt == nil)
        #expect(result.updatedAt == now)
    }

    @Test
    func testCodexLegacyBucketAndUnlimitedCredits() throws {
        let result = try CodexUsageSource.parse(["rateLimits": [
            "primary": ["usedPercent": 15, "windowDurationMins": 300],
            "credits": ["unlimited": true]
        ]])
        #expect(result.windows.first?.remainingPercent == 85)
        #expect(result.windows.first?.title == "5 小时")
        #expect(result.balance == "不限额")
    }

    @Test
    func testMissingOrInvalidUsageIsUnknownRatherThanFullAllowance() throws {
        let result = try CodexUsageSource.parse(["rateLimits": [
            "primary": ["usedPercent": true], "secondary": ["usedPercent": -2]
        ]])
        #expect(result.windows.count == 2)
        #expect(result.windows.allSatisfy { $0.remainingPercent == nil })
        #expect(throws: (any Error).self) { try CodexUsageSource.parse([:]) }
        #expect(throws: (any Error).self) { try ClaudeUsageSource.parse([:]) }
    }

    @Test
    func testClaudeWindowsParseFractionalUtilizationAndISOReset() throws {
        let result = try ClaudeUsageSource.parse([
            "five_hour": ["utilization": 23.5, "resets_at": "2026-10-18T20:30:00.000Z"],
            "seven_day": NSNull(),
            "seven_day_sonnet": ["utilization": 110, "resets_at": "2026-10-20T10:00:00+00:00"]
        ])
        #expect(result.isConnected)
        #expect(result.windows.count == 2)
        #expect(result.windows[0].remainingPercent == 76.5)
        #expect(result.windows[1].remainingPercent == 0)
        #expect(result.windows[0].resetsAt != nil)
        #expect(result.windows[1].resetsAt != nil)
        #expect(result.balance == nil)
    }

    @Test
    func testClaudeNullFieldsNeverBecomeZeroUsageOrResetNow() throws {
        let result = try ClaudeUsageSource.parse(["five_hour": ["utilization": NSNull(), "resets_at": "invalid"]])
        #expect(result.windows.first?.remainingPercent == nil)
        #expect(result.windows.first?.resetsAt == nil)
    }
}
}

private actor UsageFetchProbe {
    private var calls: [AIUsageProvider: Int] = [:]
    private var pending: [AIUsageProvider: [CheckedContinuation<AIUsageSnapshot, Error>]] = [:]
    func fetch(_ provider: AIUsageProvider) async throws -> AIUsageSnapshot {
        calls[provider, default: 0] += 1
        return try await withCheckedThrowingContinuation { pending[provider, default: []].append($0) }
    }
    func count(_ provider: AIUsageProvider) -> Int { calls[provider, default: 0] }
    func complete(_ provider: AIUsageProvider, with result: Result<AIUsageSnapshot, Error>) {
        guard let continuation = pending[provider]?.first else { return }
        pending[provider]?.removeFirst()
        continuation.resume(with: result)
    }
}

extension TidyBarTests.AIUsageTests {
    @MainActor
    @Test
    func testOnlyConnectedProvidersAreVisible() {
        let store = AIUsageStore(fetcher: { _ in throw AIUsageError.timeout })
        #expect(store.visibleSnapshots.isEmpty)
        store.snapshots = [
            AIUsageSnapshot(provider: .codex, isConnected: true, status: "已更新", source: "测试替身"),
            AIUsageSnapshot(provider: .claude, isConnected: false, status: "未连接", source: "测试替身"),
            AIUsageSnapshot(provider: .grok, isConnected: true, status: "缓存", source: "测试替身")
        ]
        #expect(store.visibleSnapshots.map(\.provider) == [.codex, .grok])
    }

    @MainActor
    private func waitForUsageState(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        Issue.record("用量任务未在测试期限内完成")
    }

    @MainActor
    @Test
    func testRefreshDeduplicatesAndFailurePreservesLastSuccessfulData() async throws {
        let probe = UsageFetchProbe()
        let store = AIUsageStore(fetcher: { try await probe.fetch($0) })
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let good = AIUsageSnapshot(provider: .codex, windows: [AIUsageWindow(id: "week", title: "每周", remainingPercent: 88, resetsAt: date)], isConnected: true, status: "已更新", source: "测试替身", updatedAt: date)
        store.refresh(provider: .codex)
        store.refresh(provider: .codex)
        try await waitForUsageState { await probe.count(.codex) == 1 }
        await probe.complete(.codex, with: .success(good))
        try await waitForUsageState { !store.isRefreshing }
        #expect(store.snapshots.first { $0.provider == .codex } == good)
        store.refresh(provider: .codex)
        try await waitForUsageState { await probe.count(.codex) == 2 }
        await probe.complete(.codex, with: .failure(AIUsageError.timeout))
        try await waitForUsageState { !store.isRefreshing }
        let stale = try #require(store.snapshots.first { $0.provider == .codex })
        #expect(stale.windows == good.windows)
        #expect(stale.updatedAt == date)
        #expect(!(stale.isConnected))
        #expect(stale.error != nil)
        #expect(stale.status == "刷新失败，请稍后重试")
        let visible = try #require(store.visibleSnapshots.first)
        #expect(visible.windows.first?.remainingPercent == nil)
        #expect(visible.balance == nil)
        #expect(visible.updatedAt == date)
        store.refresh(provider: .codex)
        try await waitForUsageState { await probe.count(.codex) == 3 }
        await probe.complete(.codex, with: .success(good))
        try await waitForUsageState { !store.isRefreshing }
        #expect(store.visibleSnapshots.first?.windows.first?.remainingPercent == 88)
        #expect(store.visibleSnapshots.first?.error == nil)
        store.stop()
    }

    @MainActor
    @Test
    func testStopDiscardsLateResultAndDoesNotCancelNewRefresh() async throws {
        let probe = UsageFetchProbe()
        let store = AIUsageStore(fetcher: { try await probe.fetch($0) })
        let original = store.snapshots
        store.refresh(provider: .codex)
        try await waitForUsageState { await probe.count(.codex) == 1 }
        store.stop()
        #expect(!(store.isRefreshing))
        store.refresh(provider: .codex)
        try await waitForUsageState { await probe.count(.codex) == 2 }
        let old = AIUsageSnapshot(provider: .codex, isConnected: true, status: "过期回调", source: "测试替身", updatedAt: Date())
        await probe.complete(.codex, with: .success(old))
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(store.snapshots == original)
        #expect(store.isRefreshing)
        let current = AIUsageSnapshot(provider: .codex, isConnected: true, status: "新请求", source: "测试替身", updatedAt: Date())
        await probe.complete(.codex, with: .success(current))
        try await waitForUsageState { !store.isRefreshing }
        #expect(store.snapshots.first { $0.provider == .codex } == current)
        store.stop()
    }
}


extension TidyBarTests.AIUsageTests {
    @MainActor
    @Test
    func testVerifiedConfiguredAccountRemainsVisibleAfterFirstRefreshFailure() async throws {
        let store = AIUsageStore(fetcher: { provider in
            if provider == .grok { throw AIUsageError.configuredAccountUnavailable("登录需重新连接", source: GrokBuildUsageSource.source) }
            throw AIUsageError.unavailable("未登录")
        })
        store.refresh()
        try await waitForUsageState { !store.isRefreshing }
        let visible = try #require(store.visibleSnapshots.first)
        #expect(store.visibleSnapshots.map(\.provider) == [.grok])
        #expect(visible.wasConfigured)
        #expect(visible.source == GrokBuildUsageSource.source)
        #expect(!(visible.isConnected))
        #expect(visible.updatedAt == nil)
        #expect(visible.windows.isEmpty)
        #expect(visible.balance == nil)
        #expect(visible.error != nil)
        store.stop()
    }
}


extension TidyBarTests.AIUsageTests {
    @MainActor
    @Test
    func testConfirmedSignOutClearsPreviousQuotaAndHidesAccount() async throws {
        let probe = UsageFetchProbe()
        let store = AIUsageStore(fetcher: { try await probe.fetch($0) })
        let good = AIUsageSnapshot(provider: .grok, balance: "测试余额", windows: [AIUsageWindow(id: "week", title: "每周", remainingPercent: 70, resetsAt: nil)], isConnected: true, status: "已更新", source: "测试来源", updatedAt: Date())
        store.refresh(provider: .grok)
        try await waitForUsageState { await probe.count(.grok) == 1 }
        await probe.complete(.grok, with: .success(good))
        try await waitForUsageState { !store.isRefreshing }
        #expect(store.visibleSnapshots.count == 1)
        store.refresh(provider: .grok)
        try await waitForUsageState { await probe.count(.grok) == 2 }
        await probe.complete(.grok, with: .failure(AIUsageError.signedOut))
        try await waitForUsageState { !store.isRefreshing }
        #expect(store.visibleSnapshots.isEmpty)
        let reset = try #require(store.snapshots.first { $0.provider == .grok })
        #expect(!(reset.isConnected))
        #expect(!(reset.wasConfigured))
        #expect(reset.windows.isEmpty)
        #expect(reset.balance == nil)
        #expect(reset.updatedAt == nil)
        #expect(reset.error == nil)
        store.stop()
    }

    @Test
    func testOfficialCodexNullAccountIsTypedSignOut() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("codex-signout-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cli = folder.appendingPathComponent("codex")
        let script = """
        #!/bin/sh
        IFS= read -r first
        printf '%s\\n' '{"id":1,"result":{}}'
        IFS= read -r notification
        IFS= read -r account
        printf '%s\\n' '{"id":2,"result":{"account":null}}'
        exec /bin/sleep 30
        """
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        #expect(throws: (any Error).self) { try CodexUsageSource.readFromCLI(executable: cli, timeout: 3) }.map {
            guard case AIUsageError.signedOut = $0 else { Issue.record("官方空账户应明确退出登录"); return }
        }
    }
}
