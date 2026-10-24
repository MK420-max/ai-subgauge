import AppKit
import Combine
import Testing
@testable import TidyBar

extension TidyBarTests {
    @MainActor @Test func menuBitmapDedupeRunsBeforeRendererAndReentrantFeedback() {
        let updates = AIUsageMenuBarUpdates()
        func key(_ appearance: NSAppearance.Name = .aqua) -> AIUsageMenuBarRenderKey {
            AIUsageMenuBarRenderKey(snapshots: [], enabled: false, showPercentage: true,
                colorsByQuota: true, placement: .arcTop, appearance: appearance)
        }
        var renders = 0
        let first = updates.image(for: key()) {
            renders += 1
            // AppKit can notify effectiveAppearance while rendering/assigning the image.
            #expect(updates.image(for: key()) { renders += 1; return NSImage() } == nil)
            return NSImage()
        }
        #expect(first != nil)
        for _ in 0..<200 {
            #expect(updates.image(for: key()) { renders += 1; return NSImage() } == nil)
        }
        #expect(renders == 1)
        #expect(updates.image(for: key(.darkAqua)) { renders += 1; return NSImage() } != nil)
        #expect(renders == 2)
        updates.reset()
        #expect(updates.image(for: key(.darkAqua)) { renders += 1; return NSImage() } != nil)
        #expect(renders == 3)
    }

    @MainActor @Test func menuAppearanceFiltersEquivalentKVONotifications() throws {
        _ = NSApplication.shared
        let view = NSView()
        view.appearance = try #require(NSAppearance(named: .aqua))
        var names: [NSAppearance.Name] = []
        let observation = AIUsageMenuBarUpdates.appearanceChanges(of: view).sink { names.append($0) }
        defer { observation.cancel() }
        func notify() {
            view.willChangeValue(forKey: "effectiveAppearance")
            view.didChangeValue(forKey: "effectiveAppearance")
        }
        for _ in 0..<200 { notify() }
        #expect(names.isEmpty)
        view.appearance = try #require(NSAppearance(named: .darkAqua))
        notify()
        #expect(names == [.darkAqua])
        for _ in 0..<200 { notify() }
        #expect(names == [.darkAqua])
        view.appearance = try #require(NSAppearance(named: .aqua))
        notify()
        #expect(names == [.darkAqua, .aqua])
    }

    @MainActor @Test func menuUpdateRequestsCoalesceAndReadLatestInputs() async throws {
        let updates = AIUsageMenuBarUpdates()
        defer { updates.reset() }
        var input = 0
        var applied: [Int] = []
        for value in 1...200 {
            input = value
            updates.request { applied.append(input) }
        }
        #expect(applied.isEmpty)
        for _ in 0..<100 where applied.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(applied == [200])
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(applied == [200])
        updates.request { applied.append(201) }
        for _ in 0..<100 where applied.count < 2 { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(applied == [200, 201])
    }

    @MainActor @Test func menuPendingUpdatesCancelAndRestartWithoutOldWork() async throws {
        let updates = AIUsageMenuBarUpdates()
        defer { updates.reset() }
        var applied: [Int] = []
        updates.request { applied.append(1) }
        updates.reset()
        updates.request { applied.append(2) }
        for _ in 0..<100 where applied.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(applied == [2])
        updates.request { applied.append(3) }
        updates.reset()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(applied == [2])
    }

    @MainActor @Test func menuDefaultsFilterAutosaveWritesAndTrackEveryRelevantPreference() throws {
        let domain = "menu-updates-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = SubscriptionPreferences(defaults: defaults)
        var states: [SubscriptionPreferences.State] = []
        var displayChanges = 0
        let observation = preferences.changes.sink { states.append($0) }
        let displayObservation = preferences.changes.map(\.display).removeDuplicates().dropFirst()
            .sink { _ in displayChanges += 1 }
        defer { observation.cancel(); displayObservation.cancel() }
        func write(_ value: Any, _ key: String) {
            defaults.set(value, forKey: key)
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        }
        for index in 0..<100 {
            write(index, "NSStatusItem Preferred Position fixture.ai-usage")
            write(index % 2 == 0, "NSStatusItem Visible fixture.ai-usage")
            write(Data([UInt8(index)]), "MenuBarAgentFileBookmark")
        }
        write(999, SubscriptionPreferences.refreshKey) // Effective default remains two minutes.
        write("system", AppTheme.preferenceKey)
        #expect(states.count == 1)
        #expect(displayChanges == 0)
        let changes: [(Any, String)] = [
            (false, AIUsageMenuBarPreference.key),
            (false, AIUsageMenuBarPreference.percentageKey),
            ("beside", AIUsageMenuBarPreference.placementKey),
            (false, SubscriptionPreferences.colorKey),
            (["grok", "codex"], SubscriptionPreferences.orderKey),
            (["codex"], SubscriptionPreferences.hiddenKey),
            (["codex": false], AIVisibilityPreferences.selectionKey),
            (true, AIVisibilityPreferences.alwaysShowKey),
            ("dark", AppTheme.preferenceKey)
        ]
        for (index, change) in changes.enumerated() {
            write(change.0, change.1)
            #expect(states.count == index + 2)
            #expect(displayChanges == index + 1)
            for _ in 0..<10 { write(change.0, change.1) }
            #expect(states.count == index + 2)
            #expect(displayChanges == index + 1)
        }
        write(5, SubscriptionPreferences.refreshKey)
        #expect(states.count == changes.count + 2)
        #expect(states.last?.refreshMinutes == 5)
        #expect(displayChanges == changes.count) // Timer preference cannot redraw the status item.
    }
}
