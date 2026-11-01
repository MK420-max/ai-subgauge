import AppKit
import Testing
@testable import TidyBar

extension TidyBarTests {
    @MainActor @Test func quotaAndCollectionFramesExcludeEmptyClickWithoutScannerEntries() throws {
        _ = NSApplication.shared
        let manager = PopupManager()
        let quotaFrame = NSRect(x: 100, y: 100, width: 53, height: 24)
        let collectionFrame = NSRect(x: 200, y: 100, width: 24, height: 24)
        manager.registerStatusFrames { [quotaFrame] }
        manager.registerStatusFrames { [collectionFrame] }
        var toggles = 0
        for (index, x) in [101.0, 151, 201, 222].enumerated() {
            let event = try emptyClickEvent(index + 1)
            #expect(!manager.handleEmptyClick(event, at: NSPoint(x: x, y: 110), onScannedItem: false) { toggles += 1 })
            #expect(manager.consume(event), "The button action must still own this event")
        }
        #expect(toggles == 0)
    }

    @MainActor @Test func genuineBlankClickStillTogglesExactlyOnce() throws {
        _ = NSApplication.shared
        let scheduler = EmptyClickTestScheduler()
        let manager = scheduler.makeManager()
        manager.registerStatusFrames { [NSRect(x: 100, y: 100, width: 53, height: 24)] }
        let event = try emptyClickEvent(1)
        var toggles = 0
        #expect(manager.handleEmptyClick(event, at: NSPoint(x: 180, y: 110), onScannedItem: false) { toggles += 1 })
        #expect(!manager.handleEmptyClick(event, at: NSPoint(x: 180, y: 110), onScannedItem: false) { toggles += 1 })
        #expect(toggles == 0)
        scheduler.advance()
        #expect(toggles == 1)
    }

    @MainActor @Test func statusFrameProvidersFollowReorderingAndReleaseOldPositions() throws {
        _ = NSApplication.shared
        let scheduler = EmptyClickTestScheduler()
        let manager = scheduler.makeManager()
        var quotaFrame = NSRect(x: 100, y: 100, width: 53, height: 24)
        var collectionFrame = NSRect(x: 200, y: 100, width: 24, height: 24)
        manager.registerStatusFrames { [quotaFrame] }
        manager.registerStatusFrames { [collectionFrame] }
        #expect(manager.isStatusClick(at: NSPoint(x: 110, y: 110)))
        #expect(manager.isStatusClick(at: NSPoint(x: 210, y: 110)))
        quotaFrame.origin.x = 300
        collectionFrame.origin.x = 400
        var toggles = 0
        for (index, x) in [310.0, 410].enumerated() {
            #expect(!manager.handleEmptyClick(try emptyClickEvent(index + 1), at: NSPoint(x: x, y: 110),
                onScannedItem: false) { toggles += 1 })
        }
        for (index, x) in [110.0, 210].enumerated() {
            #expect(!manager.isStatusClick(at: NSPoint(x: x, y: 110)))
            #expect(manager.handleEmptyClick(try emptyClickEvent(index + 3), at: NSPoint(x: x, y: 110),
                onScannedItem: false) { toggles += 1 })
        }
        #expect(toggles == 0)
        scheduler.advance()
        #expect(toggles == 2)
    }

    @MainActor @Test func registeredButtonReadsCurrentWindowAndButtonGeometry() throws {
        _ = NSApplication.shared
        let manager = PopupManager()
        let window = NSWindow(contentRect: NSRect(x: -900, y: -900, width: 120, height: 24),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 53, height: 24))
        window.contentView?.addSubview(button)
        let registration = manager.registerStatusButton(button)
        let old = try #require(PopupManager.screenFrame(button))
        #expect(manager.isStatusClick(at: NSPoint(x: old.midX, y: old.midY)))
        window.setFrameOrigin(NSPoint(x: -700, y: -900))
        button.frame.size.width = 80
        let current = try #require(PopupManager.screenFrame(button))
        #expect(!manager.isStatusClick(at: NSPoint(x: old.midX, y: old.midY)))
        let point = NSPoint(x: current.maxX - 1, y: current.midY)
        #expect(manager.isStatusClick(at: point))
        manager.unregisterStatusFrames(registration)
        #expect(!manager.isStatusClick(at: point))
    }

    @MainActor @Test func quotaMouseUpPresentsQuotaFromClosedOrOpenDrawerInEitherMonitorOrder() throws {
        _ = NSApplication.shared
        let manager = PopupManager.shared
        manager.dismiss()
        let defaultsName = "empty-click-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        let store = AIUsageStore(applyDisplayFilters: false, displayDefaults: defaults,
            fetcher: { _ in throw AIUsageError.signedOut })
        store.snapshots = UsageSnapshotFixture.snapshots
        let quota = AIUsageMenuBarController(store: store, onOpenUsage: {})
        let quotaButton = NSButton(), drawerButton = NSButton()
        let quotaFrame = NSRect(x: 100, y: 100, width: 53, height: 24)
        let registration = manager.registerStatusFrames { [quotaFrame] }
        defer {
            manager.dismiss()
            manager.unregisterStatusFrames(registration)
            defaults.removePersistentDomain(forName: defaultsName)
        }
        let point = NSPoint(x: 110, y: 110)
        var toggles = 0
        var number = 100
        for drawerOpen in [false, true] {
            for monitorFirst in [true, false] {
                manager.dismiss()
                if drawerOpen { manager.present(.drawer, anchor: drawerButton) { _ in } }
                manager.dismissForClick(at: point) // Mouse-down must preserve the drawer until the quota action.
                #expect(manager.kind == (drawerOpen ? .drawer : nil))
                let event = try emptyClickEvent(number)
                number += 1
                func monitor() {
                    #expect(!manager.handleEmptyClick(event, at: point, onScannedItem: false) {
                        toggles += 1
                        manager.present(.drawer, anchor: drawerButton) { _ in }
                    })
                }
                StatusItemApplication.dispatch(event) {
                    if monitorFirst { monitor() }
                    quota.statusItemClicked(quotaButton)
                    if !monitorFirst { monitor() }
                }
                #expect(manager.kind == .quota && manager.panel.isVisible)
                #expect(toggles == 0)
                // The next independent click retains the existing quota toggle behavior.
                StatusItemApplication.dispatch(try emptyClickEvent(number)) { quota.statusItemClicked(quotaButton) }
                number += 1
                #expect(manager.kind == nil && !manager.panel.isVisible)
            }
        }
    }

    @MainActor @Test func statusActionsCancelBlankCandidatesInEitherOrderWithMissingOrWrongFrames() throws {
        _ = NSApplication.shared
        for source in [PopupManager.EventSource.local, .global] {
            for missingFrames in [true, false] {
                for monitorFirst in [true, false] {
                    let scheduler = EmptyClickTestScheduler()
                    let manager = scheduler.makeManager()
                    manager.registerStatusFrames {
                        missingFrames ? [] : [NSRect(x: 800, y: 100, width: 53, height: 24)]
                    }
                    let event = try emptyClickEvent(500)
                    #expect(event.window == nil)
                    var toggles = 0
                    func monitor() {
                        let queued = manager.handleEmptyClick(event, at: NSPoint(x: 110, y: 110),
                            onScannedItem: false, source: source) { toggles += 1 }
                        #expect(queued == monitorFirst)
                    }
                    if monitorFirst { monitor() }
                    scheduler.advance(by: 0.05)
                    // A hosted button/AX action can have no matching NSEvent.
                    manager.recordStatusItemAction()
                    let actionEvent = monitorFirst ? event : try emptyClickEvent(999)
                    #expect(manager.consume(actionEvent), "The monitor must leave the button action available")
                    if !monitorFirst { monitor() }
                    scheduler.advance(by: 0.3)
                    #expect(toggles == 0)
                    // The recent-action guard expires; a later real blank click works.
                    #expect(manager.handleEmptyClick(try emptyClickEvent(501), at: NSPoint(x: 180, y: 110),
                        onScannedItem: false, source: source) { toggles += 1 })
                    #expect(toggles == 0)
                    scheduler.advance()
                    #expect(toggles == 1)
                }
            }
        }
    }

    @MainActor @Test func realQuotaAndDrawerActionsCancelDeferredBlankClickWithoutFrames() async throws {
        _ = NSApplication.shared
        let manager = PopupManager.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("empty-action-" + UUID().uuidString)
        let settings = SettingsStore(url: directory.appendingPathComponent("settings.json"))
        settings.config.useFloatingBar = true
        let delegate = AppDelegate(engine: MenuEngine(store: settings, accessibilityCheck: { true }))
        let defaultsName = "empty-action-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        let store = AIUsageStore(applyDisplayFilters: false, displayDefaults: defaults,
            fetcher: { _ in throw AIUsageError.signedOut })
        store.snapshots = UsageSnapshotFixture.snapshots
        let quota = AIUsageMenuBarController(store: store, onOpenUsage: {})
        let quotaButton = NSButton(), drawerButton = NSButton()
        defer {
            manager.dismiss()
            defaults.removePersistentDomain(forName: defaultsName)
        }
        var number = 10_000
        for kind in [PopupManager.Kind.quota, .drawer] {
            for source in [PopupManager.EventSource.local, .global] {
                for monitorFirst in [true, false] {
                    for drawerOpen in [false, true] {
                        let button = kind == .quota ? quotaButton : drawerButton
                        // The deterministic tests above drive an injected clock. This
                        // integration check also exercises the production scheduler/actions.
                        try await Task.sleep(for: .milliseconds(170))
                        manager.dismiss()
                        if drawerOpen { manager.present(.drawer, anchor: drawerButton) { _ in } }
                        let expected: PopupManager.Kind? = drawerOpen && kind == .drawer ? nil : kind
                        let event = try emptyClickEvent(number)
                        number += 1
                        var toggles = 0
                        func monitor() {
                            let queued = manager.handleEmptyClick(event, at: NSPoint(x: 50_000, y: 50_000),
                                onScannedItem: false, source: source) { toggles += 1 }
                            #expect(queued == monitorFirst)
                        }
                        if monitorFirst { monitor() }
                        // No active dispatch: simulate a hosted action with no matching event ID.
                        #expect(StatusItemApplication.actionEvent == nil)
                        if kind == .quota { quota.statusItemClicked(button) }
                        else { delegate.statusClicked(button) }
                        if !monitorFirst { monitor() }
                        #expect(manager.kind == expected)
                        try await Task.sleep(for: .milliseconds(200))
                        #expect(toggles == 0)
                        #expect(manager.kind == expected)
                    }
                }
            }
        }
    }

    @MainActor @Test func statusActionGenerationCancelsEvenAfterRecentTimeWindowExpires() throws {
        _ = NSApplication.shared
        let scheduler = EmptyClickTestScheduler()
        let manager = scheduler.makeManager()
        var toggles = 0
        #expect(manager.handleEmptyClick(try emptyClickEvent(600), at: NSPoint(x: 110, y: 110),
            onScannedItem: false, source: .global) { toggles += 1 })
        scheduler.advance(by: 0.1)
        manager.recordStatusItemAction()
        // Simulate a busy main queue: the delayed callback runs well after 150ms.
        scheduler.time += 1
        scheduler.advance()
        #expect(toggles == 0)
    }

    @MainActor @Test func blankClickSharedByLocalAndGlobalMonitorsTogglesOnlyAfterDelay() throws {
        _ = NSApplication.shared
        let scheduler = EmptyClickTestScheduler()
        let manager = scheduler.makeManager()
        let event = try emptyClickEvent(700)
        var toggles = 0
        #expect(manager.handleEmptyClick(event, at: NSPoint(x: 180, y: 110), onScannedItem: false,
            source: .global) { toggles += 1 })
        #expect(!manager.handleEmptyClick(event, at: NSPoint(x: 180, y: 110), onScannedItem: false,
            source: .local) { toggles += 1 })
        scheduler.advance(by: 0.149)
        #expect(toggles == 0)
        scheduler.advance(by: 0.002)
        #expect(toggles == 1)
        scheduler.advance()
        #expect(toggles == 1)
    }

    @MainActor @Test func accessibilityFrameExcludesStatusButtonWhenConvertedFrameIsWrongOrMissing() throws {
        _ = NSApplication.shared
        let manager = PopupManager()
        let button = AXFrameStatusButton(frame: .zero)
        button.axFrame = NSRect(x: 100, y: 100, width: 53, height: 24)
        let registration = manager.registerStatusButton(button)
        #expect(PopupManager.screenFrame(button) == nil)
        #expect(manager.isStatusClick(at: NSPoint(x: 110, y: 110)))
        let window = NSWindow(contentRect: NSRect(x: -900, y: -900, width: 120, height: 24),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        button.frame.size = NSSize(width: 53, height: 24)
        window.contentView?.addSubview(button)
        let converted = try #require(PopupManager.screenFrame(button))
        #expect(!converted.contains(NSPoint(x: 110, y: 110)))
        var toggles = 0
        #expect(!manager.handleEmptyClick(try emptyClickEvent(800), at: NSPoint(x: 110, y: 110),
            onScannedItem: false) { toggles += 1 })
        button.axFrame.origin.x = 300
        #expect(!manager.isStatusClick(at: NSPoint(x: 110, y: 110)))
        #expect(manager.isStatusClick(at: NSPoint(x: 310, y: 110)))
        manager.unregisterStatusFrames(registration)
        #expect(!manager.isStatusClick(at: NSPoint(x: 310, y: 110)))
        #expect(toggles == 0)
    }

    @MainActor private func emptyClickEvent(_ number: Int) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [],
            timestamp: Double(number), windowNumber: 0, context: nil,
            eventNumber: number, clickCount: 1, pressure: 0))
    }
}

@MainActor
final class EmptyClickTestScheduler {
    var time: TimeInterval = 1_000
    private var actions: [(deadline: TimeInterval, action: () -> Void)] = []

    func makeManager() -> PopupManager {
        PopupManager(now: { self.time }, schedule: { delay, action in
            self.actions.append((self.time + delay, action))
        })
    }

    func advance(by interval: TimeInterval = PopupManager.emptyClickDelay) {
        let target = time + interval
        while let index = actions.indices.min(by: { actions[$0].deadline < actions[$1].deadline }),
              actions[index].deadline <= target {
            let next = actions.remove(at: index)
            time = max(time, next.deadline)
            next.action()
        }
        time = target
    }
}

@MainActor
private final class AXFrameStatusButton: NSButton {
    var axFrame = NSRect.zero
    override func accessibilityFrame() -> NSRect { axFrame }
}
