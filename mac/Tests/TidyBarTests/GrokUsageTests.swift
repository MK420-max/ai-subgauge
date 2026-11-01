import Foundation
import Testing
@testable import TidyBar

extension TidyBarTests {
@Suite
final class GrokUsageTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private func cache(used: Any = 39.45169874373414, age: TimeInterval = 60, included: Bool = true) -> [String: Any] {
        ["schemaVersion": 2, "value": ["kind": "present", "selectedTeamId": NSNull(),
            "reading": ["usage": ["percentUsed": used, "nextResetMs": (now.timeIntervalSince1970 + 86400) * 1000,
                "hasNonZeroIncludedLimit": included, "isTeamSeat": false, "grokPlanLabel": "Grok Bot Plan"],
                "readAtMs": (now.timeIntervalSince1970 - age) * 1000],
            "expiresAtMs": (now.timeIntervalSince1970 + 3600) * 1000]]
    }

    @Test
    func testRealCacheShapePreservesSourceTimestampAndCalculatesRemaining() throws {
        let snapshot = try GrokUsageSource.parse(cache(), now: now)
        #expect(snapshot.provider == .grok)
        #expect(abs(try #require(snapshot.windows.first?.remainingPercent) - 60.54830125626586) <= 0.000001)
        #expect(snapshot.updatedAt == now.addingTimeInterval(-60))
        #expect(snapshot.expiresAt == now.addingTimeInterval(3600))
        #expect(snapshot.windows.first?.resetsAt == now.addingTimeInterval(86400))
        #expect(snapshot.plan == "Grok Bot Plan")
        #expect(snapshot.source.contains("缓存"))
        #expect(snapshot.status.contains("具体模型配置未提供"))
        #expect(snapshot.balance == nil)
    }

    @Test
    func testOlderCacheWithinOfficialTTLStillKeepsItsRealTimestamp() throws {
        let snapshot = try GrokUsageSource.parse(cache(age: 1800), now: now)
        #expect(!(snapshot.status.contains("缓存已过期")))
        #expect(snapshot.updatedAt == now.addingTimeInterval(-1800))
        #expect(abs(try #require(snapshot.windows.first?.remainingPercent) - 60.54830125626586) <= 0.000001)
    }

    @Test
    func testOfficialExpirationControlsTheExpiredState() throws {
        var response = cache(age: 1800)
        var value = try #require(response["value"] as? [String: Any])
        value["expiresAtMs"] = now.addingTimeInterval(-1).timeIntervalSince1970 * 1000
        response["value"] = value
        let snapshot = try GrokUsageSource.parse(response, now: now)
        #expect(snapshot.status.contains("缓存已过期"))
        #expect(snapshot.updatedAt == now.addingTimeInterval(-1800))
    }

    @Test
    func testUnknownIncludedLimitDoesNotInventFullRemainingQuota() throws {
        let snapshot = try GrokUsageSource.parse(cache(used: 0, included: false), now: now)
        #expect(snapshot.windows.first?.remainingPercent == nil)
        let overrun = try GrokUsageSource.parse(cache(used: 125), now: now)
        #expect(overrun.windows.first?.remainingPercent == 0)
    }

    @Test
    func testInvalidReadingsAndFutureClockAreRejected() {
        let invalidReadings: [Any] = [true, "39.4", -1, Double.nan, Double.infinity]
        for invalid in invalidReadings {
            #expect(throws: (any Error).self) { try GrokUsageSource.parse(cache(used: invalid), now: now) }
        }
        #expect(throws: (any Error).self) { try GrokUsageSource.parse(cache(age: -3600), now: now) }
        #expect(throws: (any Error).self) { try GrokUsageSource.parse(["schemaVersion": 2, "value": ["kind": "absent"]], now: now) }
        var missingTimestamp = cache()
        var value = missingTimestamp["value"] as? [String: Any] ?? [:]
        var reading = value["reading"] as? [String: Any] ?? [:]
        reading.removeValue(forKey: "readAtMs"); value["reading"] = reading; missingTimestamp["value"] = value
        #expect(throws: (any Error).self) { try GrokUsageSource.parse(missingTimestamp, now: now) }
    }

    @Test
    func testReadsOnlyCurrentAccountFilenameWithoutSecretsOrOtherData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("grok-usage-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Independent RFC 4648 fixtures, generated outside the implementation.
        let marker = "onqw4zbomnwgszlooqxhg3djmnss4y3mnfsw45bnnvsxiyjomfrwg33vnz2c243mn52a.blob"
        let reading = "onqw4zbomnwgszlooqxhg3djmnss4yldmnxxk3tufz2gk43ueu3ugyldmnxxk3tufz3wkzllnr4s25ltmftwkltdmfrwqzi.blob"
        #expect(GrokUsageSource.filename(for: "sand.client.slice.client-meta.account-slot") == marker)
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "value": "test|account"]).write(to: directory.appendingPathComponent(marker))
        try JSONSerialization.data(withJSONObject: cache()).write(to: directory.appendingPathComponent(reading))
        let snapshot = try GrokUsageSource.read(from: directory, now: now)
        #expect(snapshot.isConnected)
        #expect(snapshot.updatedAt == now.addingTimeInterval(-60))
        try FileManager.default.removeItem(at: directory.appendingPathComponent(reading))
        #expect(throws: (any Error).self) { try GrokUsageSource.read(from: directory, now: now) }.map {
            guard case AIUsageError.configuredAccountUnavailable(_, let source) = $0 else { Issue.record("有账户但缓存缺失应保留恢复入口"); return }
            #expect(source == GrokUsageSource.source)
        }
    }

    @Test
    func testAbsentOrExplicitlyEmptyCurrentAccountIsTypedSignOut() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("grok-signout-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent(GrokUsageSource.filename(for: "sand.client.slice.client-meta.account-slot"))
        func assertSignedOut() {
            #expect(throws: (any Error).self) { try GrokUsageSource.read(from: directory, now: now) }.map {
                guard case AIUsageError.signedOut = $0 else { Issue.record("缺少当前账户应明确退出登录"); return }
            }
        }
        assertSignedOut()
        for empty in ["", NSNull()] as [Any] {
            try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "value": empty]).write(to: marker)
            assertSignedOut()
        }
        // A malformed or unreadable marker cannot prove that the user has signed out.
        try Data("not-json".utf8).write(to: marker)
        #expect(throws: (any Error).self) { try GrokUsageSource.read(from: directory, now: now) }.map {
            if case AIUsageError.signedOut = $0 { Issue.record("损坏的标记不能当作退出登录") }
        }
        try FileManager.default.removeItem(at: marker)
        try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try GrokUsageSource.read(from: directory, now: now) }.map {
            if case AIUsageError.signedOut = $0 { Issue.record("不可读取的标记不能当作退出登录") }
        }
    }
}
}
