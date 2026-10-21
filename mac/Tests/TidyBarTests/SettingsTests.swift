import Foundation
import Testing
@testable import TidyBar

extension TidyBarTests {
@Suite
final class SettingsTests {
    @MainActor
    private func withStore(_ body: (SettingsStore, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacMenuBarTidy-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        try body(SettingsStore(url: url), url)
    }

    @MainActor
    @Test
    func testAtomicSaveExportImportAndReload() throws {
        try withStore { store, url in
            #expect(store.error == nil)
            #expect(!(store.config.widgets.clock))
            store.config.rules["com.test.application"] = ItemRule(zone: .hidden, group: "工作", showWhenActive: true)
            store.config.order = ["com.test.application#0"]
            store.config.style.enabled = true
            #expect(store.error == nil)
            let snapshot = store.config
            #expect(SettingsStore(url: url).config == snapshot)
            let exported = try store.exportData(redacted: false)
            store.config.rules = [:]
            try store.importData(exported)
            #expect(store.config == snapshot)
            #expect(SettingsStore(url: url).config == snapshot)
        }
    }

    @MainActor
    @Test
    func testInvalidImportPreservesMemoryAndDisk() throws {
        try withStore { store, url in
            store.config.rules["com.test.application"] = ItemRule(zone: .alwaysHidden)
            let initial = store.config
            let disk = try Data(contentsOf: url)
            @MainActor func reject(_ data: Data, sourceLocation: SourceLocation = #_sourceLocation) throws {
                #expect(throws: (any Error).self, sourceLocation: sourceLocation) { try store.importData(data) }
                #expect(store.config == initial, sourceLocation: sourceLocation)
                #expect(try Data(contentsOf: url) == disk, sourceLocation: sourceLocation)
            }
            @MainActor func rejectConfig(_ update: (inout AppConfig) -> Void, sourceLocation: SourceLocation = #_sourceLocation) throws {
                var config = initial
                update(&config)
                try reject(JSONEncoder().encode(config), sourceLocation: sourceLocation)
            }
            try reject(Data("{".utf8))
            try reject(Data("{}".utf8))
            try reject(Data("[1,2]".utf8))
            try reject(Data(repeating: 32, count: 5_000_001))
            try rejectConfig { $0.schemaVersion = 2 }
            try rejectConfig { $0.style.opacity = 2 }
            try rejectConfig { $0.style.color = "invalid" }
            try rejectConfig { $0.autoHideDelay = -1 }
            try rejectConfig { $0.widgets.weatherLatitude = 91 }
            try rejectConfig { $0.widgets.weatherLongitude = -181 }
            try rejectConfig { $0.spacerWidths = [0] }
            try rejectConfig { $0.order = ["duplicate", "duplicate"] }
            try rejectConfig { $0.hotkeyCode = 128 }
            try rejectConfig { $0.itemHotkeys = ["icon": Shortcut(keyCode: 1, modifiers: 512)] }
            try rejectConfig { $0.presetHotkeys = [UUID().uuidString: Shortcut(keyCode: 1, modifiers: 256)] }
            try rejectConfig { $0.triggers = [TriggerRule(name: "无效类型", kind: "script", value: "x", enabled: false)] }
            try rejectConfig { $0.triggers = [TriggerRule(name: "缺失预设", presetID: UUID(), enabled: false)] }
            try rejectConfig {
                let preset = LayoutPreset(name: "重复", rules: [:], order: [], style: BarStyle())
                $0.presets = [preset, preset]
            }
            try rejectConfig {
                let rule = TriggerRule(enabled: false)
                $0.triggers = [rule, rule]
            }
            try rejectConfig {
                let preset = LayoutPreset(name: "时段", rules: [:], order: [], style: BarStyle())
                $0.presets = [preset]
                $0.triggers = [TriggerRule(kind: "time", value: "25:00-26:00", presetID: preset.id)]
            }
        }
    }

    @MainActor
    @Test
    func testPresetAppliesAndDeletionClearsReferences() throws {
        try withStore { store, _ in
            store.config.rules["com.test.application"] = ItemRule(zone: .hidden, group: "工具")
            store.savePreset(name: "工作")
            let preset = try #require(store.config.presets.first)
            store.config.rules = [:]
            store.applyPreset(preset)
            #expect(store.config.rules == preset.rules)
            store.config.presetHotkeys[preset.id.uuidString] = Shortcut(keyCode: 1, modifiers: 256)
            store.config.triggers = [TriggerRule(kind: "app", value: "com.test.application", presetID: preset.id)]
            #expect(store.error == nil)
            store.deletePreset(preset.id)
            #expect(store.config.presets.isEmpty)
            #expect(store.config.presetHotkeys.isEmpty)
            #expect(store.config.triggers.first?.presetID == nil)
            #expect(store.config.triggers.first?.enabled == false)
            #expect(store.error == nil)
        }
    }

    @MainActor
    @Test
    func testSavingCapturedOrderDoesNotSendAnOrderChangeToTheLiveLayout() throws {
        try withStore { store, url in
            store.config.order = ["original"]
            store.savePreset(name: "现场布局", order: ["captured-left", "captured-right"])
            #expect(store.config.order == ["original"])
            #expect(store.config.presets.first?.order == ["captured-left", "captured-right"])
            #expect(SettingsStore(url: url).config == store.config)
        }
    }

    @MainActor
    @Test
    func testApplyingSamePresetTwiceEmitsTwoIntents() throws {
        try withStore { store, _ in
            store.savePreset(name: "工作")
            let preset = try #require(store.config.presets.first)
            var appliedCount = 0
            let observer = NotificationCenter.default.addObserver(forName: .tidyBarPresetApplied, object: store, queue: nil) { notification in
                let previous = notification.userInfo?["previousLayout"] as? LayoutPreset
                #expect(previous != nil)
                appliedCount += 1
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            store.applyPreset(preset)
            store.applyPreset(preset)
            #expect(appliedCount == 2)
        }
    }

    @MainActor
    @Test
    func testPresetIntentContainsPreviousLayoutForRollback() throws {
        try withStore { store, _ in
            store.config.rules = ["com.test.previous": ItemRule(zone: .hidden)]
            store.config.order = ["previous-icon"]
            store.config.style.color = "#112233"
            let previous = store.config
            let preset = LayoutPreset(name: "目标", rules: ["com.test.target": ItemRule(zone: .alwaysHidden)], order: ["target-icon"], style: BarStyle())
            var appliedCount = 0
            let observer = NotificationCenter.default.addObserver(forName: .tidyBarPresetApplied, object: store, queue: nil) { notification in
                let layout = notification.userInfo?["previousLayout"] as? LayoutPreset
                #expect(notification.userInfo?["presetID"] as? UUID == preset.id)
                #expect(layout?.rules == previous.rules)
                #expect(layout?.order == previous.order)
                #expect(layout?.style == previous.style)
                appliedCount += 1
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            store.applyPreset(preset)
            #expect(appliedCount == 1)
        }
    }

    @MainActor
    @Test
    func testFailedPresetSaveDoesNotEmitAppliedIntent() throws {
        try withStore { store, url in
            store.save()
            let blocked = SettingsStore(url: url.appendingPathComponent("child.json"))
            let preset = LayoutPreset(name: "无法保存", rules: ["test": ItemRule(zone: .hidden)], order: [], style: BarStyle())
            let before = blocked.config
            var appliedCount = 0
            let observer = NotificationCenter.default.addObserver(forName: .tidyBarPresetApplied, object: blocked, queue: nil) { _ in
                appliedCount += 1
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            #expect(!(blocked.applyPreset(preset)))
            #expect(blocked.error != nil)
            #expect(blocked.config == before)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            #expect(appliedCount == 0)
        }
    }

    @MainActor
    @Test
    func testDisabledShortcutAndDraftRuleCanBeSaved() throws {
        try withStore { store, url in
            store.config.itemHotkeys = ["icon": Shortcut(keyCode: 1, modifiers: 0)]
            store.config.triggers = [TriggerRule(enabled: false)]
            #expect(store.error == nil)
            #expect(SettingsStore(url: url).config == store.config)
        }
    }

    @MainActor
    @Test
    func testSaveFailureIsVisibleAndDamagedLoadIsPreserved() throws {
        try withStore { store, url in
            store.save()
            let blocked = SettingsStore(url: url.appendingPathComponent("child.json"))
            blocked.config.showLabels = false
            #expect(blocked.error != nil)
            let damaged = Data("damaged".utf8)
            try damaged.write(to: url)
            let loaded = SettingsStore(url: url)
            #expect(loaded.error != nil)
            #expect(loaded.config == AppConfig())
            #expect(try Data(contentsOf: url) == damaged)
        }
    }

    @MainActor
    @Test
    func testOldStyleJSONWithoutOptionalFieldsStillImports() throws {
        try withStore { store, _ in
            var legacy = AppConfig()
            legacy.style.color = "#123456"
            legacy.style.cornerRadius = 14
            legacy.presets = [LayoutPreset(name: "旧预设", rules: [:], order: [], style: legacy.style)]
            var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
            var style = try #require(object["style"] as? [String: Any])
            let fields = ["gradientStops", "roundTop", "roundBottom", "roundUnderMenuBar", "darkBorderColor", "linkBorderColors"]
            fields.forEach { style.removeValue(forKey: $0) }
            object["style"] = style
            var presets = try #require(object["presets"] as? [[String: Any]])
            presets[0]["style"] = style
            object["presets"] = presets
            try store.importData(JSONSerialization.data(withJSONObject: object))
            #expect(store.config == legacy)
            #expect(store.config.style.gradientStops == nil)
            #expect(store.config.style.roundTop == nil)
            #expect(store.config.style.roundBottom == nil)
            #expect(store.config.style.roundUnderMenuBar == nil)
            #expect(store.config.style.darkBorderColor == nil)
            #expect(store.config.style.linkBorderColors == nil)
        }
    }

    @MainActor
    @Test
    func testAdvancedStyleFieldsAndStopIdentitiesRoundTrip() throws {
        try withStore { store, url in
            var config = AppConfig()
            config.style.gradientStops = [
                GradientColorStop(color: "#102030", location: 0),
                GradientColorStop(color: "#AABBCC", location: 0.4),
                GradientColorStop(color: "#334455", location: 0.4),
                GradientColorStop(color: "#FFEEDD", location: 1)
            ]
            config.style.roundTop = false
            config.style.roundBottom = true
            config.style.roundUnderMenuBar = true
            config.style.darkBorderColor = "#010203"
            config.style.linkBorderColors = false
            config.presets = [LayoutPreset(name: "独立形态", rules: [:], order: [], style: config.style)]
            try store.importData(JSONEncoder().encode(config))
            #expect(store.config == config)
            let exported = try store.exportData(redacted: false)
            #expect(try JSONDecoder().decode(AppConfig.self, from: exported) == config)
            #expect(SettingsStore(url: url).config == config)
            #expect(store.config.presets.first?.style.gradientStops?.map(\.id) == config.style.gradientStops?.map(\.id))
        }
    }

    @MainActor
    @Test
    func testInvalidGradientImportsPreserveExistingSettings() throws {
        try withStore { store, url in
            store.config.style.color = "#ABCDEF"
            let snapshot = store.config
            let disk = try Data(contentsOf: url)
            @MainActor func reject(_ stops: [GradientColorStop]?) throws {
                var config = snapshot
                config.style.gradientStops = stops
                #expect(throws: (any Error).self) { try store.importData(JSONEncoder().encode(config)) }
                #expect(store.config == snapshot)
                #expect(try Data(contentsOf: url) == disk)
            }
            try reject([])
            try reject([GradientColorStop(color: "#FFFFFF", location: 0)])
            try reject((0..<9).map { GradientColorStop(color: "#FFFFFF", location: Double($0) / 8) })
            try reject([GradientColorStop(color: "invalid", location: 0), GradientColorStop(color: "#FFFFFF", location: 1)])
            try reject([GradientColorStop(color: "#000000", location: -0.1), GradientColorStop(color: "#FFFFFF", location: 1)])
            try reject([GradientColorStop(color: "#000000", location: 0), GradientColorStop(color: "#FFFFFF", location: 1.1)])
            try reject([GradientColorStop(color: "#000000", location: 0.8), GradientColorStop(color: "#FFFFFF", location: 0.2)])
            let duplicate = GradientColorStop(color: "#FFFFFF", location: 0.5)
            try reject([duplicate, duplicate])
            var config = snapshot
            config.style.darkBorderColor = "#GGGGGG"
            #expect(throws: (any Error).self) { try store.importData(JSONEncoder().encode(config)) }
            #expect(store.config == snapshot)
            #expect(try Data(contentsOf: url) == disk)
        }
    }

    @Test
    func testNonfiniteGradientLocationFailsValidation() {
        var config = AppConfig()
        config.style.gradientStops = [GradientColorStop(color: "#000000", location: .nan), GradientColorStop(color: "#FFFFFF", location: 1)]
        #expect(throws: (any Error).self) { try config.validate() }
        config.style.gradientStops?[0].location = .infinity
        #expect(throws: (any Error).self) { try config.validate() }
    }
}
}
