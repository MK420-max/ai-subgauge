import AppKit
import SwiftUI
import Testing
@testable import TidyBar

extension TidyBarTests {
    @MainActor @Test func collectionWithoutAccessibilityPromptsAtEntriesAndRecovers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("collection-permission-" + UUID().uuidString)
        let settings = SettingsStore(url: directory.appendingPathComponent("settings.json"))
        var trusted = false
        let engine = MenuEngine(store: settings, accessibilityCheck: { trusted })
        engine.start(observeSystem: false)
        defer { engine.stop() }
        var prompts = 0, toggles = 0
        engine.onAccessibilityRequired = { prompts += 1 }
        let oldEngine = AppActions.shared.engine
        let oldToggle = AppActions.shared.onToggle
        defer { AppActions.shared.engine = oldEngine; AppActions.shared.onToggle = oldToggle }
        AppActions.shared.engine = engine
        AppActions.shared.onToggle = { toggles += 1 }
        let store = AIUsageStore(applyDisplayFilters: false, fetcher: { _ in throw AIUsageError.signedOut })
        let controller = AIUsageMenuBarController(store: store, onOpenUsage: {})
        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)
        let permission = try #require(menu.items.first { $0.title == CollectionAccess.message })
        #expect(permission.action == #selector(AIUsageMenuBarController.openCollectionAccessibility))
        #expect((permission.target as? AIUsageMenuBarController) === controller)
        controller.toggleCollection() // Right-click expand/collapse.
        let footer = PanelActions(updated: "fixture", refreshing: false, dark: false,
            refresh: {}, onOpenUsage: {}, onToggleCollection: { controller.toggleCollectionBar() })
        footer.onToggleCollection()
        #expect(prompts == 2 && toggles == 0)
        #expect(!engine.isExpanded)
        #expect(engine.lastError == CollectionAccess.message)
        let previous = L10n.overrideLanguage
        defer { L10n.overrideLanguage = previous }
        L10n.overrideLanguage = "zh-Hans"
        let alert = CollectionAccess.alert()
        #expect(alert.messageText == "需要辅助功能权限才能收纳 → 打开系统设置")
        #expect(alert.buttons.first?.title == "打开系统设置")
        #expect(CollectionAccess.settingsURL.absoluteString == "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        let view = SettingsView(store: settings, engine: engine, section: .bar, usageStore: store, approximateGlass: true)
            .appThemed().frame(width: 1000, height: 700)
        #expect(ImageRenderer(content: view).cgImage != nil)
        L10n.overrideLanguage = previous

        trusted = true
        engine.refreshAccessibility() // The same check invoked by the 5-second refresh timer.
        #expect(engine.accessibilityGranted && engine.lastError == nil)
        controller.menuNeedsUpdate(menu)
        #expect(!menu.items.contains { $0.title == CollectionAccess.message })
        footer.onToggleCollection()
        #expect(toggles == 1 && prompts == 2)
        controller.toggleCollection()
        #expect(engine.isExpanded)
        trusted = false
        engine.refreshAccessibility()
        #expect(!engine.accessibilityGranted)
    }

    @Test func collectionDiagnosticContainsOnlyNonSensitiveHealthFields() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("collection-health-" + UUID().uuidString)
            .appendingPathComponent("收纳诊断.json")
        let diagnostic = CollectionDiagnostic(axTrusted: false, postEventAccess: false,
            rules: ["private-app-id": ItemRule(zone: .hidden, group: "private-group"),
                    "second-app-id": ItemRule(zone: .alwaysHidden), "visible-app-id": ItemRule()],
            engineRunning: true, timestamp: Date(timeIntervalSince1970: 1_800_000_000))
        try diagnostic.write(to: url)
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let unchanged = CollectionDiagnostic(axTrusted: false, postEventAccess: false,
            rules: ["a": ItemRule(zone: .hidden), "b": ItemRule(zone: .alwaysHidden), "c": ItemRule()],
            engineRunning: true, timestamp: diagnostic.timestamp.addingTimeInterval(60))
        #expect(diagnostic.hasSameState(as: unchanged))
        #expect(!diagnostic.hasSameState(as: CollectionDiagnostic(axTrusted: true, postEventAccess: false,
            rules: [:], engineRunning: true)))
        let data = try Data(contentsOf: url)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == ["axTrusted", "postEventAccess", "ruleCounts", "engineRunning", "timestamp"])
        #expect(json["axTrusted"] as? Bool == false)
        #expect(json["postEventAccess"] as? Bool == false)
        #expect(json["engineRunning"] as? Bool == true)
        #expect(json["ruleCounts"] as? [String: Int] == ["visible": 1, "hidden": 1, "alwaysHidden": 1])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(CollectionDiagnostic.self, from: data) == diagnostic)
        let text = try #require(String(data: data, encoding: .utf8))
        for forbidden in ["private-app-id", "private-group", "second-app-id", "visible-app-id", "token", "key", "auth", "account", "path"] {
            #expect(!text.contains(forbidden))
        }
    }

    @MainActor @Test func collectionStartupStartsEngineAndEntryActionsReachToggle() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("collection-test-" + UUID().uuidString + ".json")
        let settings = SettingsStore(url: file)
        let engine = MenuEngine(store: settings, accessibilityCheck: { true })
        let actions = AppActions()
        #expect(!engine.started)
        actions.startCollection(engine, observeSystem: false)
        defer { engine.stop() }
        #expect(engine.started)
        #expect(actions.engine === engine)
        actions.onToggle = { engine.toggle() }
        actions.toggle()
        #expect(engine.isExpanded)

        // Exercise the same NSMenu target/action used by the status item's right click.
        engine.stop()
        actions.startCollection(engine, observeSystem: false)
        let oldEngine = AppActions.shared.engine
        let oldToggle = AppActions.shared.onToggle
        let oldSettings = AppActions.shared.onCollectionSettings
        defer {
            AppActions.shared.engine = oldEngine
            AppActions.shared.onToggle = oldToggle
            AppActions.shared.onCollectionSettings = oldSettings
        }
        var openedSettings = 0, toggledBar = 0
        AppActions.shared.onToggle = { toggledBar += 1 }
        AppActions.shared.engine = engine
        AppActions.shared.onCollectionSettings = { openedSettings += 1 }
        let store = AIUsageStore(applyDisplayFilters: false, fetcher: { _ in throw AIUsageError.signedOut })
        let controller = AIUsageMenuBarController(store: store, onOpenUsage: {})
        controller.toggleCollectionBar()
        #expect(toggledBar == 1)
        #expect(!engine.isExpanded) // Floating-bar routing and menu expansion are distinct actions.
        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)
        for (title, expected) in [(L10n.text("menu.toggleCollection"), "toggleCollection"),
                                   (L10n.text("menu.collectionSettings"), "openCollectionSettings")] {
            let item = try #require(menu.items.first { $0.title == title })
            let selector = try #require(item.action)
            #expect(NSStringFromSelector(selector) == expected)
            #expect((item.target as? AIUsageMenuBarController) === controller)
            controller.perform(selector, with: item)
        }
        #expect(engine.isExpanded)
        #expect(openedSettings == 1)

        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/TidyBar/App.swift")
        let source = try String(contentsOf: app, encoding: .utf8)
        #expect(source.contains("AppActions.shared.startCollection(engine)"))
        #expect(source.contains("installStatusItem()"))
        #expect(source.contains("onCollectionSettings = { [weak self] in self?.collectionSettingsAction() }"))
    }

    @MainActor @Test func collectionSettingsRemainReachableAndControlsPersist() throws {
        #expect(SettingsSection.addonPages.contains(.bar))
        #expect(SettingsSection.sidebarPages.contains(.bar))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("collection-controls-" + UUID().uuidString)
            .appendingPathComponent("settings.json")
        let settings = SettingsStore(url: file)
        settings.config.useFloatingBar = false
        settings.config.showLabels = false
        settings.config.revealOnHover = true
        settings.config.revealOnScroll = true
        settings.config.revealOnEmptyClick = true
        settings.config.autoHideDelay = 25
        settings.config.spacerWidths = [24, 48]
        #expect(settings.error == nil)
        let reopened = SettingsStore(url: file)
        #expect(!reopened.config.useFloatingBar && !reopened.config.showLabels)
        #expect(reopened.config.revealOnHover && reopened.config.revealOnScroll && reopened.config.revealOnEmptyClick)
        #expect(reopened.config.autoHideDelay == 25 && reopened.config.spacerWidths == [24, 48])
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/TidyBar/SettingsView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("case .bar: barPage"))
        #expect(source.contains("SettingsChrome(section: $navigation.section"))
        for property in ["useFloatingBar", "showLabels", "revealOnHover", "revealOnScroll", "revealOnEmptyClick", "autoHideDelay", "spacerWidths[index]"] {
            #expect(source.contains("$store.config." + property))
        }
    }

    @MainActor @Test func collectionPanelButtonFitsBothLanguagesAndCallsTheAction() throws {
        let previous = L10n.overrideLanguage
        defer { L10n.overrideLanguage = previous }
        for language in ["zh-Hans", "en"] {
            L10n.overrideLanguage = language
            for updated in [L10n.text("panel.updatedTime", "17:38:00"), L10n.text("status.notUpdated")] {
                var calls = 0
                let footer = PanelActions(updated: updated, refreshing: false, dark: false,
                    refresh: {}, onOpenUsage: {}, onToggleCollection: { calls += 1 })
                footer.onToggleCollection()
                #expect(calls == 1)
                // Measure intrinsic content before imposing 340pt, so clipping cannot
                // conceal overflow in the 360pt panel's 10pt horizontal insets.
                let natural = ImageRenderer(content: footer.fixedSize())
                let naturalImage = try #require(natural.cgImage)
                #expect(naturalImage.width <= 340)
                let renderer = ImageRenderer(content: footer.frame(width: 340, height: 35))
                let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
                var runs: [Range<Int>] = []
                var start: Int?
                // The four capsule fills cross the center row continuously. Text
                // strokes are shorter than 25px and cannot count as a button.
                for x in 0...bitmap.pixelsWide {
                    let alpha = x < bitmap.pixelsWide ? bitmap.colorAt(x: x, y: bitmap.pixelsHigh / 2)!.alphaComponent : 0
                    if alpha > 0.3 {
                        if start == nil { start = x }
                    } else if let lower = start {
                        if x - lower >= 25 { runs.append(lower..<x) }
                        start = nil
                    }
                }
                #expect(runs.count == 4)
                for run in runs {
                    #expect(run.lowerBound >= 0 && run.upperBound <= 340)
                }
            }
            let sourceURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Sources/TidyBar/AIUsagePopover.swift")
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            #expect(source.contains("Button(action: onToggleCollection)"))
            #expect(source.contains("ai-usage.popover-collection"))
            let catalog = try L10n.load(language)
            for key in ["panel.collection", "menu.toggleCollection", "menu.collectionSettings"] {
                #expect(catalog[key]?.isEmpty == false)
            }
        }
    }
}
