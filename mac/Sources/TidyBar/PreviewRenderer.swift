import AppKit
import SwiftUI

/// Development-only entry point. Called before AppDelegate, migration, stores or timers start.
@MainActor
enum PreviewRenderer {
    static let now = Date(timeIntervalSince1970: 1_792_512_000)
    static var snapshots: [AIUsageSnapshot] {
        let values: [(AIUsageProvider, Double, TimeInterval)] = [(.codex, 72, 12000), (.grok, 45, 86400), (.claude, 88, 432000)]
        return values.map { provider, remaining, reset in
            AIUsageSnapshot(provider: provider, plan: L10n.text("demo.label"), windows: [AIUsageWindow(id: "demo", title: L10n.text("quota.weekly"),
                remainingPercent: remaining, resetsAt: now.addingTimeInterval(reset))], isConnected: true,
                status: L10n.text("demo.label"), source: L10n.text("demo.offline.demo"), updatedAt: now)
        }
    }

    static func theme(arguments: [String]) throws -> AppTheme? {
        guard let flag = arguments.firstIndex(of: "--theme") else { return nil }
        guard flag + 1 < arguments.count, let value = AppTheme(rawValue: arguments[flag + 1]),
              arguments.filter({ $0 == "--theme" }).count == 1 else {
            throw AIUsageError.unavailable(L10n.text("error.themeArgument"))
        }
        return value
    }

    static func directory(arguments: [String]) throws -> URL? {
        guard arguments.contains("--render-preview") else { return nil }
        _ = try theme(arguments: arguments)
        var values = arguments
        for option in ["--lang", "--theme"] {
            if let flag = values.firstIndex(of: option) {
                let allowed = option == "--lang" ? ["en", "zh-Hans"] : ["light", "dark"]
                guard flag + 1 < values.count, allowed.contains(values[flag + 1]) else {
                    throw AIUsageError.unavailable(L10n.text("demo.usage.aisubgauge.render.preview.dir.lang.en"))
                }
                values.removeSubrange(flag...flag + 1)
            }
        }
        guard values.count == 3, values[1] == "--render-preview", !values[2].isEmpty,
              !values[2].hasPrefix("--") else {
            throw AIUsageError.unavailable(L10n.text("demo.usage.aisubgauge.render.preview.dir.lang.en"))
        }
        return URL(fileURLWithPath: values[2], isDirectory: true)
    }

    static func render(to directory: URL, theme: AppTheme? = nil) throws {
        // Load only offline assets from this checkout or the development bundle.
        AIUsageBrand.previewResources = Bundle.main.resourceURL?.appendingPathComponent("ProviderLogos")
        if !FileManager.default.fileExists(atPath: AIUsageBrand.previewResources!.path) {
            AIUsageBrand.previewResources = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources/ProviderLogos")
        }
        let mode = theme ?? AppTheme.resolve(preference: nil,
            systemDark: NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        let store = AIUsageStore(applyDisplayFilters: false, fetcher: { _ in throw AIUsageError.signedOut })
        store.snapshots = snapshots // Never start the store or invoke its fetcher.
        let view = AIUsagePopoverView(store: store, now: now, height: AIUsagePopoverView.height(for: 3),
            onOpenUsage: {}, scrollable: false, themeOverride: mode)
        let filename = "mac-panel-\(mode.rawValue)-\(L10n.language).png"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try save(view, scale: 1, to: directory.appendingPathComponent(filename))
        let retina = directory.appendingPathComponent("2x", isDirectory: true)
        try FileManager.default.createDirectory(at: retina, withIntermediateDirectories: true)
        try save(view, scale: 2, to: retina.appendingPathComponent(filename))
    }

    private static func save<V: View>(_ view: V, scale: CGFloat, to url: URL) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let cgImage = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
            throw AIUsageError.unavailable(L10n.text("demo.the.current.graphics.session.cannot.render.the"))
        }
        try data.write(to: url)
    }
}
