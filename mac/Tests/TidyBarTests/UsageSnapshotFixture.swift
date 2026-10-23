import Foundation
@testable import TidyBar

/// Fixed offline data shared by UI tests in both Debug and Release builds.
@MainActor
enum UsageSnapshotFixture {
    static let now = Date(timeIntervalSince1970: 1_792_512_000)
    static var snapshots: [AIUsageSnapshot] {
        let values: [(AIUsageProvider, Double, TimeInterval)] = [(.codex, 72, 12000), (.grok, 45, 86400), (.claude, 88, 432000)]
        return values.map { provider, remaining, reset in
            AIUsageSnapshot(provider: provider, plan: L10n.text("demo.label"), windows: [AIUsageWindow(id: "demo", title: L10n.text("quota.weekly"),
                remainingPercent: remaining, resetsAt: now.addingTimeInterval(reset))], isConnected: true,
                status: L10n.text("demo.label"), source: L10n.text("demo.offline.demo"), updatedAt: now)
        }
    }
}
