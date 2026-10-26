import AppKit
import SwiftUI
import Testing
@testable import TidyBar

extension TidyBarTests {
    @MainActor @Test func statusActionsFollowTenStepToggleSequence() throws {
        _ = NSApplication.shared
        for input in [0, 1, 2, 3] {
            for quotaFirst in [false, true] {
                try checkStatusActionSequence(input: input, quotaFirst: quotaFirst)
            }
        }
    }

    @MainActor private func checkStatusActionSequence(input: Int, quotaFirst: Bool) throws {
        let manager = PopupManager.shared
        manager.dismiss()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("toggle-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = SettingsStore(url: directory.appendingPathComponent("settings.json"))
        settings.config.useFloatingBar = true
        let engine = MenuEngine(store: settings, accessibilityCheck: { true })
        let delegate = AppDelegate(engine: engine)
        let drawerButton = NSButton()
        drawerButton.target = delegate
        drawerButton.action = #selector(AppDelegate.statusClicked(_:))
        let defaultsName = "toggle-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        let store = AIUsageStore(applyDisplayFilters: false, displayDefaults: defaults,
            fetcher: { _ in throw AIUsageError.signedOut })
        store.snapshots = UsageSnapshotFixture.snapshots
        let quota = AIUsageMenuBarController(store: store, onOpenUsage: {})
        let quotaButton = NSButton()
        quotaButton.target = quota
        quotaButton.action = #selector(AIUsageMenuBarController.statusItemClicked(_:))
        let registration = manager.registerStatusButton(drawerButton)
        defer {
            manager.dismiss()
            manager.unregisterStatusFrames(registration)
            defaults.removePersistentDomain(forName: defaultsName)
        }
        let first: PopupManager.Kind = quotaFirst ? .quota : .drawer
        let second: PopupManager.Kind = quotaFirst ? .drawer : .quota
        let clicks = [first, first, first, second, second, second, first, first, second, second]
        let expected: [PopupManager.Kind?] = [first, nil, first, second, nil, second, first, nil, second, nil]
        let original = manager.panel
        for (index, click) in clicks.enumerated() {
            let button = click == .quota ? quotaButton : drawerButton
            let selector = try #require(button.action)
            func action() {
                #expect(button.sendAction(selector, to: button.target))
            }
            func verify() {
                #expect(manager.kind == expected[index], "step \(index + 1), input \(input), quotaFirst \(quotaFirst)")
                #expect(original.isVisible == (expected[index] != nil))
                #expect(manager.panel === original)
                #expect(NSApp.windows.filter { $0 is AIUsagePanel && $0.isVisible }.count == (expected[index] == nil ? 0 : 1))
            }
            if input == 0 {
                #expect(StatusItemApplication.actionEvent == nil)
                action() // AX/programmatic action: no sendEvent, no current mouse event.
            } else {
                let event: NSEvent
                if input == 1 {
                    event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                        timestamp: 1, windowNumber: 0, context: nil, characters: " ",
                        charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
                } else {
                    event = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [],
                        timestamp: Double(input * 100 + (quotaFirst ? 1 : 0)) + Double(index) * 0.000001,
                        windowNumber: button.window?.windowNumber ?? 0,
                        context: nil, eventNumber: 500, clickCount: 1, pressure: 0))
                }
                func dispatchedAction() {
                    #expect(StatusItemApplication.actionEvent === event)
                    action()
                    if input >= 2 {
                        verify()
                        action() // Same real mouse event through a second action path is ignored.
                    }
                }
                if input == 3 {
                    let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
                        timestamp: event.timestamp - 0.0000001, windowNumber: 0, context: nil,
                        eventNumber: 499, clickCount: 1, pressure: 1))
                    var current = down
                    StatusItemApplication.dispatch(down, currentEvent: { current }) {
                        current = event // NSButton's tracking loop dequeues mouse-up.
                        dispatchedAction()
                    }
                } else if input == 2 {
                    let stale = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [],
                        timestamp: 1, windowNumber: 0, context: nil, eventNumber: 777, clickCount: 1, pressure: 0))
                    StatusItemApplication.dispatch(event, currentEvent: { stale }, action: dispatchedAction)
                } else {
                    StatusItemApplication.dispatch(event, action: dispatchedAction)
                }
                #expect(StatusItemApplication.actionEvent == nil)
            }
            verify()
            print("toggle input=\(input) quotaFirst=\(quotaFirst) step=\(index + 1) visible=\(String(describing: manager.kind))")
        }
        // A new AX action immediately after a mouse dispatch must not inherit its ID.
        #expect(quotaButton.sendAction(try #require(quotaButton.action), to: quota))
        #expect(manager.kind == .quota)
        #expect(quotaButton.sendAction(try #require(quotaButton.action), to: quota))
        #expect(manager.kind == nil && !original.isVisible)
        if input == 3 {
            manager.present(.drawer, anchor: drawerButton) { _ in }
            let down = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
                timestamp: 500, windowNumber: 0, context: nil, eventNumber: 1000, clickCount: 1, pressure: 1))
            let up = try #require(NSEvent.mouseEvent(with: .rightMouseUp, location: .zero, modifierFlags: [],
                timestamp: quotaFirst ? 502 : 501, windowNumber: 0, context: nil, eventNumber: 1001, clickCount: 1, pressure: 0))
            let selector = try #require(quotaButton.action)
            var current = down
            StatusItemApplication.dispatch(down, currentEvent: { current }) {
                current = up
                #expect(quotaButton.sendAction(selector, to: quota))
            }
            #expect(manager.kind == nil && !original.isVisible)
        }
    }

    @MainActor @Test func outsideMonitorUsesEventPositionAndExcludesBothStatusItems() throws {
        _ = NSApplication.shared
        let manager = PopupManager()
        let window = NSWindow(contentRect: NSRect(x: -900, y: -900, width: 120, height: 24),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { manager.dismiss(); window.close() }
        let first = NSButton(frame: NSRect(x: 0, y: 0, width: 40, height: 24))
        let second = NSButton(frame: NSRect(x: 60, y: 0, width: 40, height: 24))
        window.contentView?.addSubview(first)
        window.contentView?.addSubview(second)
        manager.registerStatusFrames { [first, second].compactMap(PopupManager.screenFrame) }
        manager.present(.drawer, anchor: first) { panel in panel.setFrameOrigin(NSPoint(x: -700, y: -700)) }
        for button in [first, second] {
            // The sandbox may provide NSWindows with windowNumber == 0. Such a
            // synthetic event has no window and therefore uses screen coordinates.
            if window.windowNumber > 0 {
                let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
                    location: NSPoint(x: button.frame.midX, y: button.frame.midY), modifierFlags: [], timestamp: 1,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
                manager.dismissForClick(event)
                #expect(manager.kind == .drawer && manager.panel.isVisible)
            }
            let frame = try #require(PopupManager.screenFrame(button))
            let global = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
                location: NSPoint(x: frame.midX, y: frame.midY), modifierFlags: [], timestamp: 2,
                windowNumber: 0, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
            manager.dismissForClick(global)
            #expect(manager.kind == .drawer && manager.panel.isVisible)
        }
        let outside = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
            location: NSPoint(x: -2000, y: -2000), modifierFlags: [], timestamp: 3,
            windowNumber: 0, context: nil, eventNumber: 3, clickCount: 1, pressure: 0))
        manager.dismissForClick(outside)
        #expect(manager.kind == nil && !manager.panel.isVisible)
    }

    @MainActor @Test func visiblePopupBelongsToItsIconRegardlessOfContent() {
        _ = NSApplication.shared
        let manager = PopupManager()
        let button = NSButton()
        defer { manager.dismiss() }
        manager.present(.search, anchor: button) { _ in }
        manager.present(.drawer, anchor: button) { _ in }
        #expect(manager.kind == nil && !manager.panel.isVisible)
    }

    @MainActor @Test func mouseDeduplicationUsesBothNumberAndTimestampOnly() throws {
        _ = NSApplication.shared
        let manager = PopupManager()
        func event(_ number: Int, _ timestamp: TimeInterval, _ window: Int = 0) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero,
                modifierFlags: [], timestamp: timestamp, windowNumber: window, context: nil,
                eventNumber: number, clickCount: 1, pressure: 0))
        }
        #expect(manager.consume(try event(100, 1)))
        #expect(!manager.consume(try event(100, 1, 123)))
        #expect(manager.consume(try event(100, 1.000001)))
        #expect(manager.consume(try event(101, 1.000001)))
    }

    @MainActor @Test func repeatedEventAcrossDispatchesStillTogglesAndSwitchesVisiblePopup() async throws {
        _ = NSApplication.shared
        let manager = PopupManager()
        defer { manager.dismiss() }
        // AXPress can leave currentEvent pointing at the same mouse-up across actions.
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero,
            modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 0))
        let clicks: [PopupManager.Kind] = [.drawer, .drawer, .drawer, .quota, .quota, .quota, .drawer, .drawer]
        let expected: [PopupManager.Kind?] = [.drawer, nil, .drawer, .quota, nil, .quota, .drawer, nil]
        for (click, visible) in zip(clicks, expected) {
            manager.present(click, event: event) { panel in
                panel.contentView = NSHostingView(rootView: Text("Dispatch fixture"))
            }
            #expect(manager.kind == visible)
            #expect(manager.panel.isVisible == (visible != nil))
            #expect(NSApp.windows.filter { $0 is AIUsagePanel && $0.isVisible }.count == (visible == nil ? 0 : 1))
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        manager.present(.drawer) { _ in }
        manager.panel.orderOut(nil) // An AppKit dismissal outside the manager must not block reopening.
        #expect(manager.kind == nil)
        manager.present(.drawer) { _ in }
        #expect(manager.kind == .drawer && manager.panel.isVisible)
        let firstAnchor = NSView(), secondAnchor = NSView()
        manager.present(.search, anchor: firstAnchor) { _ in }
        manager.present(.search, anchor: secondAnchor) { _ in }
        #expect(manager.kind == .search && manager.panel.isVisible)
        manager.present(.search, anchor: secondAnchor) { _ in }
        #expect(manager.kind == nil && !manager.panel.isVisible)
    }

    @MainActor @Test func quotaDrawerAndSearchShareOneWindowAndToggleIndependently() throws {
        _ = NSApplication.shared
        let manager = PopupManager.shared
        defer { manager.dismiss() }
        let store = AIUsageStore(applyDisplayFilters: false, fetcher: { _ in throw AIUsageError.signedOut })
        store.snapshots = UsageSnapshotFixture.snapshots
        let quota = AIUsageMenuBarController(store: store, onOpenUsage: {})
        defer { quota.stop() }
        let window = NSWindow(contentRect: NSRect(x: -1000, y: -1000, width: 120, height: 30),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 40, height: 30))
        let quotaButton = NSButton(), searchButton = NSButton()
        window.contentView = button
        let original = manager.panel
        func visible() -> Int { NSApp.windows.filter { $0 is AIUsagePanel && $0.isVisible }.count }
        let fixture = PopupButtonFixture(manager: manager)
        button.target = fixture
        button.action = #selector(PopupButtonFixture.click)
        searchButton.target = fixture
        searchButton.action = #selector(PopupButtonFixture.click)
        for kind in [PopupManager.Kind.quota, .drawer, .search, .quota, .search, .drawer] {
            if kind == .quota { quota.togglePanel(relativeTo: quotaButton) }
            else { fixture.kind = kind; (kind == .search ? searchButton : button).performClick(nil) }
            #expect(manager.kind == kind && original.isVisible)
            #expect(visible() == 1 && manager.panel === original)
        }
        // Mouse-down on either status item must leave mouse-up to own the toggle.
        let frame = try #require(PopupManager.screenFrame(button))
        manager.dismissForClick(at: NSPoint(x: frame.midX, y: frame.midY))
        #expect(original.isVisible)
        button.performClick(nil)
        #expect(!original.isVisible && manager.kind == nil && visible() == 0)
        button.performClick(nil)
        original.cancelOperation(nil)
        #expect(!original.isVisible && manager.kind == nil)
        button.performClick(nil)
        manager.dismissForClick(at: NSPoint(x: original.frame.minX - 100, y: original.frame.minY - 100))
        #expect(!original.isVisible && manager.kind == nil)
        #expect(original.styleMask.contains(.borderless) && !original.isOpaque && original.backgroundColor == .clear)
    }

    @MainActor @Test func blankAndStatusPathsConsumeEachMouseEventOnlyOnce() throws {
        _ = NSApplication.shared
        let scheduler = EmptyClickTestScheduler()
        let manager = scheduler.makeManager()
        let statusFrame = NSRect(x: 100, y: 100, width: 40, height: 24)
        manager.registerStatusFrames { [statusFrame] }
        var toggles = 0
        func event(_ number: Int) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [],
                timestamp: Double(number), windowNumber: 0, context: nil, eventNumber: number, clickCount: 1, pressure: 0))
        }
        let status = try event(1)
        #expect(!manager.handleEmptyClick(status, at: NSPoint(x: 110, y: 110), onScannedItem: false) { toggles += 1 })
        if manager.consume(status) { toggles += 1 }
        #expect(toggles == 1)
        #expect(!manager.consume(status))
        // A stale or missing scanner frame still cannot turn a status click into blank space.
        #expect(!manager.handleEmptyClick(status, at: NSPoint(x: 110, y: 110), onScannedItem: false) { toggles += 1 })
        let blank = try event(2)
        #expect(manager.handleEmptyClick(blank, at: NSPoint(x: 200, y: 110), onScannedItem: false) { toggles += 1 })
        #expect(!manager.handleEmptyClick(blank, at: NSPoint(x: 200, y: 110), onScannedItem: false) { toggles += 1 })
        #expect(toggles == 1) // Pending blank clicks leave button actions available.
        scheduler.advance()
        #expect(!manager.consume(blank)) // Only the confirmed blank click has now consumed the event.
        #expect(toggles == 2)
        let scanned = try event(3)
        #expect(!manager.handleEmptyClick(scanned, at: NSPoint(x: 220, y: 110), onScannedItem: true) { toggles += 1 })
        #expect(toggles == 2)
        let next = try event(4)
        #expect(manager.consume(next))
        #expect(!manager.handleEmptyClick(next, at: NSPoint(x: 220, y: 110), onScannedItem: false) { toggles += 1 })
    }

    @MainActor @Test func restoredSettingsApplyCollectionPresetsAndKeepSpacerWidthsOnDisk() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("settings.json")
        let settings = SettingsStore(url: file)
        settings.config.rules = ["fixture.app": ItemRule(zone: .hidden, group: "Tools")]
        settings.config.order = ["fixture.app::item"]
        settings.config.spacerWidths = [24, 48]
        settings.savePreset(name: "Collection")
        let preset = try #require(settings.config.presets.first)
        settings.config.rules = [:]; settings.config.order = []
        #expect(settings.applyPreset(preset))
        let reopened = SettingsStore(url: file)
        #expect(reopened.config.rules == preset.rules && reopened.config.order == preset.order)
        #expect(reopened.config.spacerWidths == [24, 48])
        reopened.config.presets = [preset]
        reopened.config.rules = ["fixture.app": ItemRule(zone: .visible)]
        reopened.config.triggers = [TriggerRule(kind: "app", value: "fixture.front", presetID: preset.id)]
        let automation = AutomationController(store: reopened)
        automation.evaluate(context: RuleContext(frontmostBundle: "fixture.front"))
        #expect(reopened.config.rules == preset.rules && reopened.config.order == preset.order)
        automation.evaluate(context: RuleContext())
        #expect(reopened.config.rules["fixture.app"]?.zone == .visible)
        #expect(reopened.config.spacerWidths == [24, 48])
    }

    @MainActor @Test func collectionSettingsResizeAndScrollAtMinimumSize() throws {
        _ = NSApplication.shared
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("collection-resize-" + UUID().uuidString).appendingPathComponent("settings.json")
        let settings = SettingsStore(url: file)
        let engine = MenuEngine(store: settings, accessibilityCheck: { false })
        let usage = AIUsageStore(applyDisplayFilters: false, fetcher: { _ in throw AIUsageError.signedOut })
        settings.config.spacerWidths = [24, 48]
        #expect(settings.error == nil)
        let previous = L10n.overrideLanguage
        defer { L10n.overrideLanguage = previous }
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        for language in ["zh-Hans", "en"] {
            L10n.overrideLanguage = language
            for section in [SettingsSection.layout, .bar] {
                let window = StandaloneWindow.make()
                defer { window.close() }
                window.contentView = StandaloneWindow.hostingView(SettingsView(store: settings, engine: engine, section: section,
                    usageStore: usage, approximateGlass: true))
                for size in [NSSize(width: 680, height: 460), NSSize(width: 960, height: 680)] {
                    window.setContentSize(size)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                    let hosting = try #require(window.contentView)
                    hosting.superview?.layoutSubtreeIfNeeded()
                    let content = try #require(scrollViews(hosting).first { $0.convert($0.bounds, to: hosting).minX > 200 })
                    let document = try #require(content.documentView)
                    #expect(content.bounds.width > 400)
                    #expect(document.bounds.width <= content.contentView.bounds.width + 1, "Collection page must fit horizontally: \(language) \(section)")
                    if size.width == 680 {
                        #expect(document.bounds.height > content.contentView.bounds.height)
                        content.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.height - content.contentView.bounds.height))
                        content.reflectScrolledClipView(content.contentView)
                        #expect(content.contentView.bounds.minY > 0)
                    }
                }
            }
        }
    }

    @MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["SG_PREVIEW_DIR"] != nil))
    func r9NativeCollectionPreviews() throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["SG_PREVIEW_DIR"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = SettingsStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("collection-preview-" + UUID().uuidString).appendingPathComponent("settings.json"))
        let engine = MenuEngine(store: settings, accessibilityCheck: { true })
        engine.refreshAccessibility()
        engine.items = [
            MenuEntry(id: "fixture.1", bundleID: "fixture.network", name: "Network", title: "Connected", frame: .zero,
                      icon: NSImage(systemSymbolName: "wifi", accessibilityDescription: nil), isRunning: true, canMove: true),
            MenuEntry(id: "fixture.2", bundleID: "fixture.sound", name: "Sound", title: "Output volume", frame: .zero,
                      icon: NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: nil), isRunning: true, canMove: true),
            MenuEntry(id: "fixture.3", bundleID: "fixture.sync", name: "Cloud Sync", title: "Up to date", frame: .zero,
                      icon: NSImage(systemSymbolName: "cloud", accessibilityDescription: nil), isRunning: true, canMove: true)
        ]
        // Synthetic configuration only; no installed settings or account sources are opened.
        settings.config.rules = ["fixture.network": ItemRule(zone: .hidden, group: "Tools"),
                                 "fixture.sound": ItemRule(zone: .visible), "fixture.sync": ItemRule(zone: .hidden, group: "Tools")]
        settings.config.spacerWidths = [24, 48]
        #expect(settings.error == nil)
        let usage = AIUsageStore(applyDisplayFilters: false, fetcher: { _ in throw AIUsageError.signedOut })
        usage.snapshots = UsageSnapshotFixture.snapshots
        for (name, all, theme) in [("drawer-light", false, AppTheme.light), ("drawer-dark", false, .dark), ("search-light", true, .light)] {
            let panel = AIUsagePanel()
            defer { panel.close() }
            let size = NSSize(width: 480, height: 360)
            panel.setContentSize(size)
            panel.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
            panel.contentView = StandaloneWindow.hostingView(SearchContent(store: settings, engine: engine, showAll: all,
                dismiss: {}, approximateGlass: true).environment(\.appTheme, theme).environment(\.colorScheme, theme.colorScheme))
            try Self.cacheWindow(panel, size: size, to: directory.appendingPathComponent(name + ".png"))
        }
        for section in [SettingsSection.layout, .bar] {
            for size in [NSSize(width: 680, height: 460), NSSize(width: 960, height: 680)] {
                let window = StandaloneWindow.make(size: size)
                defer { window.close() }
                window.appearance = NSAppearance(named: .aqua)
                window.contentView = StandaloneWindow.hostingView(SettingsView(store: settings, engine: engine, section: section,
                    usageStore: usage, approximateGlass: true).environment(\.appTheme, .light).environment(\.colorScheme, .light))
                window.setContentSize(size)
                try Self.cacheWindow(window, size: size, to: directory.appendingPathComponent("settings-\(section.rawValue)-\(Int(size.width))x\(Int(size.height)).png"))
            }
        }
        let panel = AIUsagePanel()
        defer { panel.close() }
        let height = AIUsagePopoverView.height(for: 3)
        let size = NSSize(width: AIUsagePopoverView.width, height: height)
        panel.setContentSize(size)
        panel.appearance = NSAppearance(named: .aqua)
        panel.contentView = StandaloneWindow.hostingView(AIUsagePopoverView(store: usage, now: UsageSnapshotFixture.now,
            height: height, onOpenUsage: {}, scrollable: false, themeOverride: .light, approximateGlass: true))
        try Self.cacheWindow(panel, size: size, to: directory.appendingPathComponent("panel-light.png"))
    }
}

@MainActor private final class PopupButtonFixture: NSObject {
    let manager: PopupManager
    var kind = PopupManager.Kind.drawer
    init(manager: PopupManager) { self.manager = manager }
    @objc func click(_ button: NSButton) {
        manager.present(kind, anchor: button) { panel in
            panel.contentView = NSHostingView(rootView: Text("Collection fixture").padding(24))
            panel.setContentSize(NSSize(width: 480, height: 360))
            panel.setFrameOrigin(NSPoint(x: -800, y: -800))
        }
    }
}
