import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

extension Notification.Name {
    static let tidyBarPresetApplied = Notification.Name("com.mike.aisubgauge.presetApplied")
}

enum ItemZone: String, Codable, CaseIterable, Identifiable {
    case visible, hidden, alwaysHidden
    var id: String { rawValue }
    var title: String {
        switch self {
        case .visible: return L10n.text("layout.alwaysVisible")
        case .hidden: return L10n.text("settings.collected")
        case .alwaysHidden: return L10n.text("settings.always.hidden")
        }
    }
}

struct ItemRule: Codable, Equatable {
    var zone: ItemZone = .visible
    var group: String = ""
    var showWhenActive: Bool = false
}

struct GradientColorStop: Codable, Equatable, Identifiable {
    var id = UUID()
    var color: String
    var location: Double
}

struct BarStyle: Codable, Equatable {
    var enabled = false
    var color = "#24324B"
    var endColor = "#6A5AE0"
    var gradient = false
    var opacity = 0.5
    var cornerRadius = 10.0
    var borderWidth = 0.0
    var borderColor = "#FFFFFF"
    var shadow = false
    var split = false
    var hideNotch = false
    var darkColor = "#182032"
    var useDarkStyle = false
    var gradientStops: [GradientColorStop]? = nil
    var roundTop: Bool? = nil
    var roundBottom: Bool? = nil
    var roundUnderMenuBar: Bool? = nil
    var darkBorderColor: String? = nil
    var linkBorderColors: Bool? = nil
}

struct TriggerRule: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = L10n.text("settings.new.rule")
    var kind = "app"
    var value = ""
    var presetID: UUID?
    var enabled = true
    var restore = true
}

struct LayoutPreset: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var rules: [String: ItemRule]
    var order: [String]
    var style: BarStyle
}

struct WidgetOptions: Codable, Equatable {
    var clock = false
    var calendar = false
    var music = false
    var weather = false
    var weatherCity = L10n.text("settings.beijing")
    var weatherLatitude = 39.9042
    var weatherLongitude = 116.4074
}

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
}

struct AppConfig: Codable, Equatable {
    var schemaVersion = 1
    var rules: [String: ItemRule] = [:]
    var order: [String] = []
    var style = BarStyle()
    var presets: [LayoutPreset] = []
    var triggers: [TriggerRule] = []
    var widgets = WidgetOptions()
    var autoHideDelay = 10.0
    var revealOnHover = false
    var revealOnScroll = false
    var revealOnEmptyClick = false
    var useFloatingBar = true
    var showLabels = true
    var launchAtLogin = false
    var spacerWidths: [Double] = []
    var hotkeyCode: UInt32 = 11
    var hotkeyModifiers: UInt32 = 768
    var searchHotkeyCode: UInt32 = 49
    var searchHotkeyModifiers: UInt32 = 768
    var presetHotkeys: [String: Shortcut] = [:]
    var itemHotkeys: [String: Shortcut] = [:]

    func validate() throws {
        guard schemaVersion == 1 else { throw SettingsError.invalid(L10n.text("settings.unsupported.configuration.version")) }
        try Self.validateLayout(rules: rules, order: order, style: style)
        guard presets.count <= 100, triggers.count <= 200,
              Set(presets.map(\.id)).count == presets.count,
              Set(triggers.map(\.id)).count == triggers.count else {
            throw SettingsError.invalid(L10n.text("settings.too.many.presets.or.rules.or.duplicate"))
        }
        for preset in presets {
            guard !preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  preset.name.count <= 100 else { throw SettingsError.invalid(L10n.text("settings.invalid.preset.name")) }
            try Self.validateLayout(rules: preset.rules, order: preset.order, style: preset.style)
        }
        let presetIDs = Set(presets.map(\.id))
        guard presetHotkeys.count <= 100, itemHotkeys.count <= 2000,
              presetHotkeys.keys.allSatisfy({ key in UUID(uuidString: key).map { presetIDs.contains($0) } ?? false }),
              itemHotkeys.keys.allSatisfy({ !$0.isEmpty && $0.count <= 512 }),
              (Array(presetHotkeys.values) + Array(itemHotkeys.values)).allSatisfy({
                  $0.keyCode <= 127 && $0.modifiers & ~UInt32(0x1F00) == 0 && ($0.modifiers == 0 || $0.modifiers & UInt32(0x1900) != 0)
              }) else { throw SettingsError.invalid(L10n.text("settings.invalid.preset.or.icon.shortcut")) }
        for rule in triggers {
            guard !rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  rule.name.count <= 100, rule.value.count <= 512,
                  ["app", "time", "battery", "display", "wifi", "focus"].contains(rule.kind),
                  rule.presetID.map({ presetIDs.contains($0) }) ?? true else {
                throw SettingsError.invalid(L10n.text("settings.invalid.automation.rule.name.type.or.preset"))
            }
            // Disabled drafts may be incomplete while the user edits them.
            if rule.enabled {
                guard rule.presetID != nil, !rule.value.isEmpty else {
                    throw SettingsError.invalid(L10n.text("settings.an.enabled.automation.rule.must.have.a"))
                }
                switch rule.kind {
                case "battery":
                    guard let n = Int(rule.value), (0...100).contains(n) else {
                        throw SettingsError.invalid(L10n.text("settings.battery.conditions.must.be.integers.from.0"))
                    }
                case "display":
                    guard let n = Int(rule.value), (1...32).contains(n) else {
                        throw SettingsError.invalid(L10n.text("settings.display.count.must.be.from.1.to"))
                    }
                case "time":
                    guard rule.value.range(of: "^([01][0-9]|2[0-3]):[0-5][0-9]-([01][0-9]|2[0-3]):[0-5][0-9]$", options: .regularExpression) != nil else {
                        throw SettingsError.invalid(L10n.text("settings.time.range.format.must.be.09.00"))
                    }
                default: break
                }
            }
        }
        guard autoHideDelay.isFinite, (0...3600).contains(autoHideDelay),
              spacerWidths.count <= 20,
              spacerWidths.allSatisfy({ $0.isFinite && (4...300).contains($0) }),
              widgets.weatherLatitude.isFinite, (-90...90).contains(widgets.weatherLatitude),
              widgets.weatherLongitude.isFinite, (-180...180).contains(widgets.weatherLongitude),
              widgets.weatherCity.count <= 100,
              hotkeyCode <= 127, searchHotkeyCode <= 127,
              hotkeyModifiers & ~UInt32(0x1F00) == 0,
              searchHotkeyModifiers & ~UInt32(0x1F00) == 0 else {
            throw SettingsError.invalid(L10n.text("settings.collection.bar.weather.or.shortcut.values.are"))
        }
    }

    private static func validateLayout(rules: [String: ItemRule], order: [String], style: BarStyle) throws {
        guard rules.count <= 2000, order.count <= 2000,
              Set(order).count == order.count,
              rules.keys.allSatisfy({ !$0.isEmpty && $0.count <= 512 }),
              order.allSatisfy({ !$0.isEmpty && $0.count <= 512 }),
              rules.values.allSatisfy({ $0.group.count <= 100 }) else {
            throw SettingsError.invalid(L10n.text("settings.the.icon.layout.contains.invalid.items.duplicate"))
        }
        if let stops = style.gradientStops {
            guard (2...8).contains(stops.count), Set(stops.map(\.id)).count == stops.count,
                  stops.allSatisfy({ $0.location.isFinite && (0...1).contains($0.location)
                      && $0.color.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil }),
                  zip(stops, stops.dropFirst()).allSatisfy({ pair in pair.0.location <= pair.1.location }) else {
                throw SettingsError.invalid(L10n.text("settings.a.gradient.needs.2.to.8.valid"))
            }
        }
        let colors = [style.color, style.endColor, style.borderColor, style.darkColor] + (style.darkBorderColor.map { [$0] } ?? [])
        guard colors.allSatisfy({ $0.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil }),
              style.opacity.isFinite, (0...1).contains(style.opacity),
              style.cornerRadius.isFinite, (0...50).contains(style.cornerRadius),
              style.borderWidth.isFinite, (0...10).contains(style.borderWidth) else {
            throw SettingsError.invalid(L10n.text("settings.invalid.appearance.color.or.dimensions"))
        }
    }
}

enum SettingsError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published var config: AppConfig { didSet { save() } }
    @Published var error: String?
    let url: URL
    private var skipSave = false

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.mike.aisubgauge", isDirectory: true).appendingPathComponent("settings.json")
        config = AppConfig()
        if FileManager.default.fileExists(atPath: self.url.path) {
            skipSave = true
            defer { skipSave = false }
            do {
                try PrivateFiles.createDirectory(at: self.url.deletingLastPathComponent())
                let permissions = try FileManager.default.attributesOfItem(atPath: self.url.path)[.posixPermissions] as? NSNumber
                if let permissions, permissions.intValue & 0o177 != 0 {
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.url.path)
                }
                config = try Self.decode(BoundedFile.read(self.url, maximum: 5_000_000))
            }
            catch { self.error = L10n.text("settings.could.not.read.saved.settings.0.the", error.localizedDescription) }
        }
    }

    func save() {
        guard !skipSave else { return }
        do {
            let data = try exportData(redacted: false)
            try write(data)
            error = nil
        } catch { self.error = L10n.text("settings.settings.were.not.saved.0", error.localizedDescription) }
    }

    func exportData(redacted: Bool = true) throws -> Data {
        try config.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var exported = config
        if redacted {
            exported.widgets.weatherCity = ""
            exported.widgets.weatherLatitude = 0
            exported.widgets.weatherLongitude = 0
            exported.widgets.weather = false
            for index in exported.triggers.indices where exported.triggers[index].kind == "wifi" {
                exported.triggers[index].name = "[redacted]"
                exported.triggers[index].value = ""
                exported.triggers[index].enabled = false
            }
        }
        return try encoder.encode(exported)
    }

    func importData(_ data: Data) throws {
        let candidate = try Self.decode(data)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try write(encoder.encode(candidate))
        skipSave = true
        config = candidate
        skipSave = false
        error = nil
    }

    private func write(_ data: Data) throws {
        try PrivateFiles.write(data, to: url)
    }

    private static func decode(_ data: Data) throws -> AppConfig {
        guard data.count <= 5_000_000 else { throw SettingsError.invalid(L10n.text("settings.the.configuration.file.exceeds.5.mb")) }
        var candidate: AppConfig
        do { candidate = try JSONDecoder().decode(AppConfig.self, from: data) }
        catch { throw SettingsError.invalid(L10n.text("settings.the.configuration.file.is.incomplete.or.contains")) }
        try candidate.validate()
        func rules(_ old: [String: ItemRule]) -> [String: ItemRule] {
            var result = old
            for (key, value) in old where LegacyIdentifiers.current(key) != key {
                let current = LegacyIdentifiers.current(key)
                if result[current] == nil { result[current] = value }
                result[key] = nil
            }
            return result
        }
        func order(_ old: [String]) -> [String] {
            var seen = Set<String>()
            return old.map(LegacyIdentifiers.current).filter { seen.insert($0).inserted }
        }
        candidate.rules = rules(candidate.rules)
        candidate.order = order(candidate.order)
        for index in candidate.presets.indices {
            candidate.presets[index].rules = rules(candidate.presets[index].rules)
            candidate.presets[index].order = order(candidate.presets[index].order)
        }
        try candidate.validate()
        return candidate
    }

    func exportSettings() {
        let panel = NSSavePanel()
        panel.title = L10n.text("settings.export.settings")
        panel.nameFieldStringValue = L10n.text("settings.ai.subgauge.settings.json")
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do { try PrivateFiles.write(exportData(), to: destination, privateDirectory: false); error = nil }
        catch { self.error = L10n.text("settings.export.failed.0", error.localizedDescription) }
    }

    func importSettings() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("settings.import.settings")
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        do { try importData(BoundedFile.read(source, maximum: 5_000_000)) }
        catch { self.error = L10n.text("settings.import.failed.the.original.configuration.was.kept", error.localizedDescription) }
    }

    func savePreset(name: String, order: [String]? = nil) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100 else { error = L10n.text("settings.enter.a.preset.name.with.1.to"); return }
        guard config.presets.count < 100 else { error = L10n.text("settings.you.can.save.up.to.100.presets"); return }
        config.presets.append(LayoutPreset(name: name, rules: config.rules, order: order ?? config.order, style: config.style))
    }

    @discardableResult
    func applyPreset(_ preset: LayoutPreset) -> Bool {
        let previousConfig = config
        let previous = LayoutPreset(name: L10n.text("settings.before.applying.preset"), rules: config.rules, order: config.order, style: config.style)
        var updated = config
        updated.rules = preset.rules
        updated.order = preset.order
        updated.style = preset.style
        config = updated
        guard error == nil else {
            skipSave = true
            config = previousConfig
            skipSave = false
            return false
        }
        NotificationCenter.default.post(name: .tidyBarPresetApplied, object: self, userInfo: ["previousLayout": previous, "presetID": preset.id])
        return true
    }

    func deletePreset(_ id: UUID) {
        var updated = config
        updated.presets.removeAll { $0.id == id }
        updated.presetHotkeys.removeValue(forKey: id.uuidString)
        for index in updated.triggers.indices where updated.triggers[index].presetID == id {
            updated.triggers[index].presetID = nil
            updated.triggers[index].enabled = false
        }
        config = updated
    }
}
