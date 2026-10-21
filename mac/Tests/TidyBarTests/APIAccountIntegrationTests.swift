import Foundation
import Testing
@testable import TidyBar

private actor APIRefreshGate {
    var continuation: CheckedContinuation<AIUsageSnapshot, Error>?
    func fetch() async throws -> AIUsageSnapshot {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    var ready: Bool { continuation != nil }
    func finish(_ snapshot: AIUsageSnapshot) { continuation?.resume(returning: snapshot); continuation = nil }
}

extension TidyBarTests {
@Suite
final class APIAccountIntegrationTests {
    @Test
    func testCredentialValidationDoesNotAcceptHeaderInjectionOrOversizedKey() throws {
        #expect(try APIAccountCredentials.validated("  fixture-key  ") == "fixture-key")
        for input in ["", "   ", "fixture key", "fixture\nkey", "fixture\rkey", "fixture\tkey", "测试", String(repeating: "x", count: 4097)] {
            #expect(throws: (any Error).self) { try APIAccountCredentials.validated(input) }
        }
    }

    @MainActor
    @Test
    func testMenuShowsKnownIntegerPercentOrActualAPIBalanceWithoutGuessing() {
        var snapshot = AIUsageSnapshot(provider: .deepseekAPI, balance: "CNY 12.34", isConnected: true, status: "已更新", source: "测试替身")
        #expect(AIUsageMenuBarController.displayValue(snapshot) == "CNY 12.34")
        snapshot.windows = [AIUsageWindow(id: "key", title: "剩余限额", remainingPercent: 76.6, resetsAt: nil)]
        #expect(AIUsageMenuBarController.displayValue(snapshot) == "77%")
        snapshot.windows[0].remainingPercent = 0
        #expect(AIUsageMenuBarController.displayValue(snapshot) == "0%")
        snapshot.windows = []
        snapshot.balance = nil
        #expect(AIUsageMenuBarController.displayValue(snapshot) == "—")
        snapshot.balance = "CNY 12.34"
        snapshot.error = "刷新失败"
        #expect(AIUsageMenuBarController.displayValue(snapshot) == "—")
    }

    @MainActor
    @Test
    func testRemovedAPIAccountCannotReturnFromAnOldRefresh() async throws {
        let gate = APIRefreshGate()
        let store = AIUsageStore(fetcher: { _ in try await gate.fetch() })
        store.refresh(provider: .deepseekAPI)
        try await waitForGate(gate)
        store.disconnectAPIAccount(.deepseekAPI)
        #expect(!(store.isRefreshing))
        #expect(store.visibleSnapshots.isEmpty)
        await gate.finish(AIUsageSnapshot(provider: .deepseekAPI, balance: "CNY 10.00", isConnected: true, status: "旧请求", source: "测试替身", updatedAt: Date()))
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(store.visibleSnapshots.isEmpty)
        store.stop()
    }

    @MainActor
    @Test
    func testVerifiedNewAPIConnectionReplacesOldRefreshWithoutASecondRequest() async throws {
        let gate = APIRefreshGate()
        let store = AIUsageStore(fetcher: { _ in try await gate.fetch() })
        store.refresh(provider: .deepseekAPI)
        try await waitForGate(gate)
        let current = AIUsageSnapshot(provider: .deepseekAPI, balance: "CNY 20.00", isConnected: true, status: "已验证", source: "测试替身", updatedAt: Date())
        store.acceptAPIConnection(current)
        #expect(store.visibleSnapshots == [current])
        #expect(!(store.isRefreshing))
        await gate.finish(AIUsageSnapshot(provider: .deepseekAPI, balance: "CNY 10.00", isConnected: true, status: "旧请求", source: "测试替身", updatedAt: Date()))
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(store.visibleSnapshots == [current])
        store.stop()
    }

    @MainActor
    private func waitForGate(_ gate: APIRefreshGate) async throws {
        for _ in 0..<300 {
            if await gate.ready { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        Issue.record("测试替身未启动")
    }
}
}
