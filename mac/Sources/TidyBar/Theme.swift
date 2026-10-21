import AppKit
import SwiftUI

enum AppTheme: String, CaseIterable {
    case light, dark

    static let preferenceKey = "Theme"
    static func resolve(preference: String?, systemDark: Bool) -> AppTheme {
        preference.flatMap(AppTheme.init(rawValue:)) ?? (systemDark ? .dark : .light)
    }
    var colorScheme: ColorScheme { self == .dark ? .dark : .light }
    var appearance: NSAppearance { NSAppearance(named: self == .dark ? .darkAqua : .aqua)! }
}

struct ThemePalette: Decodable {
    let backgroundGradient: [String]
    let background, surface, surfaceAlt, border: String
    let textPrimary, textSecondary, accent, accentAlt, barTrack, demo, error: String
    let panelBorder, glassOverlay, buttonFill, buttonBorder, divider, wave: String

    var colors: [String] {
        backgroundGradient + [background, surface, surfaceAlt, border, textPrimary, textSecondary, accent, accentAlt,
            barTrack, demo, error, panelBorder, glassOverlay, buttonFill, buttonBorder, divider, wave]
    }

    func color(_ key: KeyPath<Self, String>) -> Color { Color(themeHex: self[keyPath: key]) }
}

struct ThemeCatalog: Decodable {
    let themes: [String: ThemePalette]
    let quota: [String: String]
    let providers: [String: String]

    static func load(at url: URL = SharedResources.url("theme.json")) throws -> ThemeCatalog {
        let catalog = try JSONDecoder().decode(Self.self, from: BoundedFile.read(url))
        guard ["light", "dark"].allSatisfy({ catalog.themes[$0]?.backgroundGradient.isEmpty == false }),
              ["high", "mid", "low"].allSatisfy({ catalog.quota[$0] != nil }),
              AIUsageProvider.allCases.allSatisfy({ catalog.providers[$0.rawValue] != nil }),
              (catalog.themes.values.flatMap(\.colors) + Array(catalog.quota.values) + Array(catalog.providers.values))
                .allSatisfy({ $0.range(of: "^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$", options: .regularExpression) != nil }) else {
            throw AIUsageError.invalidResponse
        }
        return catalog
    }
    static func loadOrDefault(at url: URL) -> ThemeCatalog { (try? load(at: url)) ?? builtIn }
    static let shared = loadOrDefault(at: SharedResources.url("theme.json"))
    func palette(_ theme: AppTheme) -> ThemePalette { themes[theme.rawValue] ?? Self.builtIn.themes[theme.rawValue]! }

    // Used only when the shared resource is absent, oversized or malformed.
    static let builtIn = ThemeCatalog(themes: [
        "light": ThemePalette(backgroundGradient: ["#FCD789", "#E9B48A", "#C99AA6", "#8A6CC0"],
            background: "#FBF3E8", surface: "#FFFFFF", surfaceAlt: "#F6E9DA", border: "#E4D2C4",
            textPrimary: "#2A2140", textSecondary: "#6B5F7A", accent: "#8A6CC0", accentAlt: "#E9A65A",
            barTrack: "#EADFD3", demo: "#C7832E", error: "#C2413A", panelBorder: "#FFFFFF66",
            glassOverlay: "#FFFFFF70", buttonFill: "#FFFFFF66", buttonBorder: "#FFFFFF99", divider: "#6B5F7A26", wave: "#FFFFFF40"),
        "dark": ThemePalette(backgroundGradient: ["#2B3160", "#1A1B42", "#130F2E"],
            background: "#16173A", surface: "#1F2150", surfaceAlt: "#262A5E", border: "#34386E",
            textPrimary: "#EEF0FF", textSecondary: "#A8B0D8", accent: "#9FB4FF", accentAlt: "#C8D4F2",
            barTrack: "#2C3068", demo: "#F0B45A", error: "#FF7A70", panelBorder: "#C8D4F233",
            glassOverlay: "#C8D4F205", buttonFill: "#C8D4F214", buttonBorder: "#C8D4F240", divider: "#C8D4F226", wave: "#C8D4F208")
    ], quota: ["high": "#2CAC6D", "mid": "#E7B228", "low": "#E04B52"], providers: [
        "codex": "#6ED1B5", "openaiAPI": "#6ED1B5", "claude": "#DE9E73", "anthropicAPI": "#DE9E73",
        "grok": "#A8A6FA", "xaiAPI": "#A8A6FA", "geminiAPI": "#7AADFA", "deepseekAPI": "#5E8AFF",
        "openrouterAPI": "#BFA8F5", "kimiAPI": "#8FC2FF", "minimaxAPI": "#FF8C7A"
    ])

    @MainActor func quotaColor(_ remaining: Double?) -> Color {
        guard let remaining = AIUsageMenuBarController.remaining(remaining) else { return .clear }
        let high = NSColor(Color(themeHex: quota["high"]!)).usingColorSpace(.deviceRGB)!
        let mid = NSColor(Color(themeHex: quota["mid"]!)).usingColorSpace(.deviceRGB)!
        let low = NSColor(Color(themeHex: quota["low"]!)).usingColorSpace(.deviceRGB)!
        if remaining >= 50 { return Color(high) }
        if remaining <= 15 { return Color(low) }
        let start = remaining < 32.5 ? low : mid
        let end = remaining < 32.5 ? mid : high
        let amount = (remaining - (remaining < 32.5 ? 15 : 32.5)) / 17.5
        func mix(_ first: CGFloat, _ last: CGFloat) -> Double {
            let from = (first * 255).rounded(), to = (last * 255).rounded()
            return (from + (to - from) * amount).rounded(.toNearestOrEven) / 255
        }
        return Color(.sRGB, red: mix(start.redComponent, end.redComponent),
                     green: mix(start.greenComponent, end.greenComponent),
                     blue: mix(start.blueComponent, end.blueComponent))
    }
}

extension Color {
    init(themeHex: String) {
        let hex = themeHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt64(hex, radix: 16) ?? 0
        let rgb = hex.count == 8 ? value >> 8 : value
        self.init(.sRGB, red: Double((rgb >> 16) & 255) / 255,
                  green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255,
                  opacity: hex.count == 8 ? Double(value & 255) / 255 : 1)
    }
}

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme.light
}
extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

private struct ThemedSurface: ViewModifier {
    @AppStorage(AppTheme.preferenceKey) private var preference = "system"
    @Environment(\.colorScheme) private var systemScheme
    var override: AppTheme?
    func body(content: Content) -> some View {
        let mode = override ?? AppTheme.resolve(preference: preference, systemDark: systemScheme == .dark)
        let palette = ThemeCatalog.shared.palette(mode)
        content
            .foregroundStyle(palette.color(\.textPrimary))
            .tint(palette.color(\.accent))
            .background(ThemeBackground(theme: mode))
            .environment(\.appTheme, mode)
            .environment(\.colorScheme, mode.colorScheme)
    }
}
extension View {
    func appThemed(_ override: AppTheme? = nil) -> some View { modifier(ThemedSurface(override: override)) }
}

struct ThemeBackground: View {
    var theme: AppTheme
    var body: some View {
        let palette = ThemeCatalog.shared.palette(theme)
        LinearGradient(colors: palette.backgroundGradient.map { Color(themeHex: $0) },
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .background(palette.color(\.background))
            .overlay(palette.color(\.glassOverlay))
            .overlay {
                GeometryReader { geometry in
                    Ellipse().fill(palette.color(\.wave)).blur(radius: 24)
                    .overlay(Ellipse().stroke(palette.color(\.wave), lineWidth: 1))
                    .frame(width: geometry.size.width * 1.8, height: geometry.size.height * 2)
                    .rotationEffect(.degrees(35))
                    .position(x: geometry.size.width * 1.45, y: geometry.size.height * 1.3)
                }
            }
            .clipped().allowsHitTesting(false).accessibilityHidden(true)
    }
}

@MainActor
enum AppBrand {
    static func logo(_ theme: AppTheme) -> NSImage {
        NSImage(contentsOf: SharedResources.url("app-\(theme.rawValue)-1024.png", directory: "brand"))!
    }
    static func icon(_ theme: AppTheme) -> NSImage {
        NSImage(contentsOf: SharedResources.url("AISubGauge-\(theme.rawValue).icns", directory: "brand"))!
    }
    static let idleAsset = "tray-mono"
    static func idleImage() -> NSImage {
        // PNG representations are rasterizations of tray-mono.svg; template tint follows macOS.
        let image = NSImage(size: NSSize(width: 18, height: 18))
        for size in [18, 36] {
            let url = SharedResources.url("\(idleAsset)-\(size).png", directory: "brand")
            if let data = try? Data(contentsOf: url), let representation = NSBitmapImageRep(data: data) {
                representation.size = image.size
                image.addRepresentation(representation)
            }
        }
        image.isTemplate = true
        image.accessibilityDescription = L10n.text("idle.title")
        return image
    }
}

/// AppKit menus, alerts and windows inherit this appearance; SwiftUI uses the same preference.
@MainActor
final class ThemeController {
    private var appearanceObservation: NSKeyValueObservation?
    private var defaultsObservation: NSObjectProtocol?
    func start() {
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { _, _ in
            Task { @MainActor in Self.updateIcon() }
        }
        defaultsObservation = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.apply() } }
        apply()
    }
    func stop() {
        appearanceObservation = nil
        if let defaultsObservation { NotificationCenter.default.removeObserver(defaultsObservation) }
        defaultsObservation = nil
    }
    private func apply() {
        let manual = UserDefaults.standard.string(forKey: AppTheme.preferenceKey).flatMap(AppTheme.init(rawValue:))
        let desired = manual?.appearance
        if NSApp.appearance?.name != desired?.name { NSApp.appearance = desired }
        Self.updateIcon()
    }
    private static func updateIcon() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        NSApp.applicationIconImage = AppBrand.icon(dark ? .dark : .light)
    }
}
