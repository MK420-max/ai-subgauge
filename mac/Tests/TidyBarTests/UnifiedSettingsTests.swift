import AppKit
import SwiftUI
import Testing
@testable import TidyBar

extension TidyBarTests {
    @Test func settingsControlsUseSharedSwitchMenuAndButtonStyles() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/TidyBar")
        func source(_ name: String) throws -> String {
            try String(contentsOf: sources.appendingPathComponent(name + ".swift"), encoding: .utf8)
        }
        let chrome = try source("SettingsChrome")
        #expect(chrome.contains(".toggleStyle(SettingsSwitchStyle(approximate: approximate))"))
        #expect(chrome.contains(".toggleStyle(.switch)"))
        #expect(chrome.contains(".pickerStyle(.menu)"))
        #expect(chrome.contains(".buttonStyle(SettingsPillStyle())"))
        let root = try source("SettingsView")
        #expect(root.contains("selectedContent\n                    .modifier(SettingsControlStyle(approximate: approximateGlass))"))
        #expect(try source("SettingsSubscriptionsView").contains("}.modifier(SettingsControlStyle())"))
        // Includes conditional controls in account details and the connection sheet,
        // not just controls visible in the initial viewport of each page.
        for name in ["SettingsView", "SettingsSubscriptionsView", "Appearance", "Automation", "Widgets",
                     "Hotkeys", "ProviderLoginConsent", "RunningProcesses", "AIUsageView", "QuotaArc"] {
            let text = try source(name)
            #expect(!text.contains(".checkbox"), "Checkbox override in \(name)")
            for line in text.components(separatedBy: .newlines) where line.contains(".toggleStyle(") {
                #expect(line.contains(".toggleStyle(SettingsSwitchStyle("), "Nonuniform boolean style in \(name): \(line)")
            }
        }
        for name in ["Appearance", "Automation", "Widgets", "Hotkeys"] {
            let text = try source(name)
            #expect(text.contains("SettingsPage {") && text.contains("SettingsGroup(title:"))
            #expect(!text.contains(".formStyle(.grouped)"))
        }
    }

    @MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["SG_PREVIEW_DIR"] != nil))
    func r9cSettingsStylePreviews() throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["SG_PREVIEW_DIR"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("r9c-style-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let settings = SettingsStore(url: fixture.appendingPathComponent("settings.json"))
        settings.config.spacerWidths = [24]
        settings.savePreset(name: "Focused Work")
        settings.config.triggers = [TriggerRule(name: "Battery", kind: "battery", value: "20",
            presetID: settings.config.presets.first?.id, enabled: false)]
        settings.config.widgets.weather = true
        let name = "r9c-style-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let usage = AIUsageStore(applyDisplayFilters: false, displayDefaults: defaults, fetcher: { _ in throw AIUsageError.signedOut })
        usage.snapshots = UsageSnapshotFixture.snapshots
        let engine = MenuEngine(store: settings, accessibilityCheck: { false })
        for size in [StandaloneWindow.minimumSize, NSSize(width: 960, height: 680)] {
            let window = StandaloneWindow.make(size: size)
            defer { window.close() }
            window.appearance = NSAppearance(named: .aqua)
            for section in SettingsSection.sidebarPages {
                window.contentView = StandaloneWindow.hostingView(
                    SettingsView(store: settings, engine: engine, section: section, usageStore: usage, approximateGlass: true)
                        .defaultAppStorage(defaults).environment(\.appTheme, .light).environment(\.colorScheme, .light))
                try Self.cacheWindow(window, size: size, to: directory.appendingPathComponent(
                    "settings-\(section.rawValue)-\(Int(size.width))x\(Int(size.height)).png"))
            }
            window.contentView = StandaloneWindow.hostingView(
                SettingsView(store: settings, engine: engine, usageStore: usage, approximateGlass: true)
                    .overlay {
                        Color.black.opacity(0.12)
                        SubscriptionVendorGrid(approximateGlass: true, connected: [.codex, .claude, .grok],
                                               selected: .constant("codex"), cancel: {}, proceed: {})
                    }
                    .defaultAppStorage(defaults).environment(\.appTheme, .light).environment(\.colorScheme, .light))
            try Self.cacheWindow(window, size: size, to: directory.appendingPathComponent(
                "settings-addsub-\(Int(size.width))x\(Int(size.height)).png"))
        }
    }

    @MainActor @Test func settingsEntriesReuseOneWindowAndNavigateBeforeFirstAppearance() throws {
        _ = NSApplication.shared
        let settings = SettingsStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("r9b-settings-" + UUID().uuidString).appendingPathComponent("settings.json"))
        let engine = MenuEngine(store: settings, accessibilityCheck: { false })
        let usage = AIUsageStore(applyDisplayFilters: false, fetcher: { _ in throw AIUsageError.signedOut })
        usage.snapshots = UsageSnapshotFixture.snapshots
        let controller = SettingsWindowController(store: settings, engine: engine, usageStore: usage, approximateGlass: true)
        let delegate = AppDelegate(settingsController: controller)
        let quota = AIUsageMenuBarController(store: usage, onOpenUsage: {})
        let actions = AppActions.shared
        let previousSettings = actions.onSettings
        let previousCollection = actions.onCollectionSettings
        actions.onSettings = { controller.show($0) }
        actions.onCollectionSettings = { delegate.perform(NSSelectorFromString("collectionSettingsAction")) }
        defer {
            actions.onSettings = previousSettings
            actions.onCollectionSettings = previousCollection
            controller.window?.close()
            quota.stop()
        }
        #expect(controller.navigation.section == .subscriptions)
        #expect(SettingsSection.sidebarPages.first == .subscriptions)
        #expect(controller.window == nil)
        var firstWindow: NSWindow?
        func check(_ section: SettingsSection) throws {
            let window = try #require(controller.window)
            if let firstWindow { #expect(window === firstWindow) } else { firstWindow = window }
            #expect(controller.navigation.section == section)
            #expect(window.isVisible && !window.isMiniaturized)
            let windows = NSApp.windows.filter { $0.identifier?.rawValue == "ai-subgauge.settings" }
            #expect(windows.count == 1)
            #expect(window.contentMinSize == StandaloneWindow.minimumSize)
            #expect(window.contentView != nil)
        }
        // The collection context-menu selector must work even on the first open.
        delegate.perform(NSSelectorFromString("collectionSettingsAction"))
        try check(.bar)
        let menu = NSMenu()
        quota.menuNeedsUpdate(menu)
        let quotaSettings = try #require(menu.items.first { $0.action == NSSelectorFromString("openSettings") })
        quota.perform(quotaSettings.action, with: quotaSettings)
        try check(.subscriptions)
        let collectionSettings = try #require(menu.items.first { $0.action == #selector(AIUsageMenuBarController.openCollectionSettings) })
        quota.perform(collectionSettings.action, with: collectionSettings)
        try check(.bar)
        actions.showLayoutSettings()
        try check(.layout)
        quota.openPanelSettings() // The panel footer invokes this same action.
        try check(.panel)
        delegate.perform(NSSelectorFromString("settingsAction")) // App menu / Command-comma.
        try check(.subscriptions)
        for page in SettingsSection.sidebarPages {
            actions.showSettings(page)
            try check(page)
        }
        controller.window?.close()
        delegate.perform(NSSelectorFromString("settingsAction"))
        try check(.subscriptions)
        controller.window?.miniaturize(nil)
        quota.openPanelSettings()
        try check(.panel)
    }

    @MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["SG_PREVIEW_DIR"] != nil))
    func r9bSettingsSidebarOrderPreview() throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["SG_PREVIEW_DIR"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = SettingsStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("r9b-sidebar-" + UUID().uuidString).appendingPathComponent("settings.json"))
        let usage = AIUsageStore(applyDisplayFilters: false, fetcher: { _ in throw AIUsageError.signedOut })
        usage.snapshots = UsageSnapshotFixture.snapshots
        let size = NSSize(width: 960, height: 680)
        let window = StandaloneWindow.make(size: size)
        defer { window.close() }
        window.appearance = NSAppearance(named: .aqua)
        let view = SettingsView(store: settings, usageStore: usage, approximateGlass: true)
        #expect(view.section == .subscriptions)
        window.contentView = StandaloneWindow.hostingView(view.environment(\.appTheme, .light).environment(\.colorScheme, .light))
        try Self.cacheWindow(window, size: size, to: directory.appendingPathComponent("settings-sidebar-order.png"))
    }
}
