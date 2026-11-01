import Foundation
import Testing
@testable import TidyBar

extension TidyBarTests {
@Suite
final class ClaudeWebConnectionTests {
    private let first = "2d2a3f0d-0cb2-48df-863f-1058490254cf"
    private let second = "6c171d6b-364e-496b-942d-95930973d37b"

    @Test
    func testOnlySuccessfulProfileMarkerEnablesRestoreAndStoresNoOrganization() throws {
        let suite = "tidy-claude-profile-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!(ClaudeWebUsage.canRestoreProfile(in: defaults)))
        ClaudeWebUsage.rememberProfile(in: defaults)
        let reopened = try #require(UserDefaults(suiteName: suite))
        #expect(ClaudeWebUsage.canRestoreProfile(in: reopened))
        let saved = try #require(reopened.persistentDomain(forName: suite))
        #expect(Set(saved.keys) == [ClaudeWebUsage.connectedProfileKey])
        #expect(saved[ClaudeWebUsage.connectedProfileKey] as? Bool == true)
    }

    @MainActor
    @Test
    func testUnconnectedProfileRestoreRemainsUnconnectedWithoutCreatingLoginUI() async throws {
        let suite = "tidy-claude-unconnected-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let connection = ClaudeWebConnection(defaults: defaults)
        connection.restoreExistingSession()
        do { _ = try await connection.fetch(); Issue.record("未连接时不能产生用量") }
        catch { #expect(error.localizedDescription.contains("完成登录")) }
        #expect(connection.organizations.isEmpty)
        #expect(connection.selectedOrganizationID == nil)
        connection.stop()
        #expect(!(ClaudeWebUsage.canRestoreProfile(in: defaults)))
    }

    @Test
    func testOrganizationSelectionRequiresExplicitChoiceWhenSeveralExist() throws {
        let list = try ClaudeWebUsage.organizations([["uuid": first, "name": "个人"], ["uuid": second, "name": "团队"]])
        #expect(throws: (any Error).self) { try ClaudeWebUsage.selected(from: list, id: nil) }
        #expect(throws: (any Error).self) { try ClaudeWebUsage.selected(from: list, id: UUID().uuidString) }
        #expect(try ClaudeWebUsage.selected(from: list, id: second).name == "团队")
        #expect(try ClaudeWebUsage.selected(from: [list[0]], id: nil).id == first)
    }

    @Test
    func testMalformedDuplicateAndUnsafeOrganizationIDsAreRejected() throws {
        for value: Any in [[], ["uuid": first], [["uuid": "../../conversations", "name": "团队"]], [["uuid": first, "name": "   "]], [["uuid": first, "name": "一"], ["uuid": first.uppercased(), "name": "重复"]]] {
            #expect(throws: (any Error).self) { try ClaudeWebUsage.organizations(value) }
        }
        #expect(throws: (any Error).self) { try ClaudeWebUsage.organizations(Array(repeating: ["uuid": first, "name": "过多"], count: 101)) }
    }

    @Test
    func testOrganizationParseOnlyRetainsChoiceFieldsAndNormalizesIDs() throws {
        let list = try ClaudeWebUsage.organizations([["uuid": first.uppercased(), "name": "个人", "private_member": ["email": "不应保留"]]])
        #expect(list == [ClaudeUsageOrganization(id: first, name: "个人")])
        #expect(!(String(describing: list).contains("不应保留")))
    }

    @Test
    func testReadingIsRestrictedToExactOfficialHTTPSOrigin() {
        #expect(ClaudeWebUsage.canRead(URL(string: "https://claude.ai/settings/usage")))
        for url in ["http://claude.ai/", "https://claude.ai:444/", "https://claude.ai.example.com/", "https://claude.ai@evil.example/", "https://auth.claude.com/", "file:///tmp/usage"] {
            #expect(!(ClaudeWebUsage.canRead(URL(string: url))))
        }
        #expect(!(ClaudeWebUsage.canRead(nil)))
        #expect(ClaudeWebUsage.canNavigateInLogin(URL(string: "https://accounts.google.com/login")!))
        #expect(!(ClaudeWebUsage.canNavigateInLogin(URL(string: "https://accounts.google.com.evil.example/")!)))
    }

    @Test
    func testOfficialWebQuotaPreservesResetAndSourceWithoutInventingCurrency() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = try ClaudeWebUsage.snapshot([
            "five_hour": ["utilization": 12.5, "resets_at": "2026-10-19T01:00:00Z"],
            "seven_day": ["utilization": 30],
            "extra_usage": ["is_enabled": true, "utilization": 25]
        ], now: now)
        #expect(snapshot.source == ClaudeWebUsage.source)
        #expect(snapshot.windows.first?.remainingPercent == 87.5)
        #expect(snapshot.windows.first?.resetsAt != nil)
        #expect(snapshot.windows.last?.resetsAt == nil)
        #expect(snapshot.updatedAt == now)
        #expect(snapshot.balance == "额外额度剩余 75%")
        #expect(snapshot.plan == nil)
    }

    @Test
    func testUnavailableExtraUsageIsNotReportedAsFullBalance() throws {
        for extra: [String: Any] in [["is_enabled": false, "utilization": 0], ["is_enabled": true], ["is_enabled": true, "utilization": true], ["is_enabled": true, "utilization": -1]] {
            let snapshot = try ClaudeWebUsage.snapshot(["five_hour": ["utilization": NSNull()], "extra_usage": extra])
            #expect(snapshot.balance == nil)
            #expect(snapshot.windows.first?.remainingPercent == nil)
        }
        #expect(throws: (any Error).self) { try ClaudeWebUsage.snapshot([:]) }
    }
}
}
