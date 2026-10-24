import AppKit
import Testing
@testable import TidyBar

extension TidyBarTests {
    @MainActor @Test func menuRenderKeyIgnoresMetadataAndRepeatedNotifications() {
        let snapshot = AIUsageSnapshot(provider: .codex,
            windows: [AIUsageWindow(id: "quota", title: "quota", remainingPercent: 72)], isConnected: true,
            status: "fixture", source: "fixture")
        func key(_ snapshots: [AIUsageSnapshot], enabled: Bool = true, percentage: Bool = true,
                 colors: Bool = true, placement: AIUsageMenuBarPreference.PercentagePlacement = .arcTop,
                 appearance: NSAppearance.Name = .aqua) -> AIUsageMenuBarRenderKey {
            AIUsageMenuBarRenderKey(snapshots: snapshots, enabled: enabled, showPercentage: percentage,
                colorsByQuota: colors, placement: placement,
                appearance: AIUsageMenuBarAppearance(NSAppearance(named: appearance)!))
        }
        let initial = key([snapshot])
        var metadata = snapshot
        metadata.updatedAt = .distantPast
        metadata.expiresAt = .distantPast
        metadata.source = "new source"
        metadata.status = "new status"
        metadata.plan = "new plan"
        metadata.windows[0].title = "new window title"
        // Any defaults/timer/store notification with the same pixels must skip AppKit setters.
        var applied: AIUsageMenuBarRenderKey?
        var assignments = 0
        for next in [initial] + Array(repeating: key([metadata]), count: 100) {
            if applied != next { applied = next; assignments += 1 }
        }
        #expect(assignments == 1)
        #expect(AIUsageMenuBarController.isCached(metadata, now: Date()))
        var changed = snapshot
        changed.windows[0].remainingPercent = 71.5
        #expect(key([changed]) != initial)
        changed = snapshot; changed.error = "offline"
        #expect(key([changed]) != initial)
        changed = snapshot; changed.isConnected = false
        #expect(key([changed]) != initial)
        #expect(key([snapshot], percentage: false) != initial)
        #expect(key([snapshot], colors: false) != initial)
        #expect(key([snapshot], placement: .beside) != initial)
        #expect(key([snapshot], appearance: .darkAqua) != initial)
        var other = snapshot; other.provider = .claude
        #expect(key([other]) != initial)
        #expect(key([snapshot, other]) != key([other, snapshot]))
        #expect(key([snapshot], enabled: false) == key([], percentage: false, colors: false, placement: .beside))
        #expect(key([snapshot], percentage: false, placement: .beside) == key([snapshot], percentage: false))
    }

    @MainActor @Test func menuRenderKeyNormalizesUnknownQuotaAndTracksRecovery() {
        var snapshot = AIUsageSnapshot(provider: .codex, windows: [], isConnected: true, status: "fixture", source: "fixture")
        func key(_ snapshot: AIUsageSnapshot) -> AIUsageMenuBarRenderKey {
            AIUsageMenuBarRenderKey(snapshots: [snapshot], enabled: true, showPercentage: true,
                colorsByQuota: true, placement: .arcTop,
                appearance: AIUsageMenuBarAppearance(NSAppearance(named: .aqua)!))
        }
        let unknown = key(snapshot)
        for percent in [Double.nan, .infinity, -1, 101] {
            snapshot.windows = [AIUsageWindow(id: "quota", title: "quota", remainingPercent: percent)]
            #expect(key(snapshot) == unknown)
        }
        snapshot.windows[0].remainingPercent = 0
        #expect(key(snapshot) != unknown)
        snapshot.error = "offline"
        #expect(key(snapshot) == unknown)
        snapshot.error = "different error, same unknown pixels"
        #expect(key(snapshot) == unknown)
    }

    @MainActor @Test func menuRenderKeyTracksResolvedColorsEvenWhenAppearanceNameMatches() {
        let snapshot = AIUsageSnapshot(provider: .codex,
            windows: [AIUsageWindow(id: "quota", title: "quota", remainingPercent: 72)], isConnected: true,
            status: "fixture", source: "fixture")
        let appearance = AIUsageMenuBarAppearance(NSAppearance(named: .aqua)!)
        let changed = AIUsageMenuBarAppearance(dark: appearance.dark, quotaColors: [.red, .orange, .green])
        func key(_ style: AIUsageMenuBarAppearance) -> AIUsageMenuBarRenderKey {
            AIUsageMenuBarRenderKey(snapshots: [snapshot], enabled: true, showPercentage: true,
                colorsByQuota: true, placement: .arcTop, appearance: style)
        }
        let updates = AIUsageMenuBarUpdates()
        var renders = 0
        #expect(key(appearance) != key(changed))
        for style in [appearance, appearance, changed, changed] {
            _ = updates.image(for: key(style)) { renders += 1; return NSImage() }
        }
        #expect(renders == 2)
    }
}
