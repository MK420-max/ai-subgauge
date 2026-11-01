#if DEBUG
import AppKit
import SwiftUI

/// GUI acceptance uses the real views, with no migration, credentials, fetches or menu-bar engine.
@MainActor
final class UIPreviewApp: NSObject, NSApplicationDelegate {
    private let store = AIUsageStore(applyDisplayFilters: false, fetcher: { _ in throw AIUsageError.signedOut })
    private var controller: AIUsageMenuBarController!
    private var settings: NSWindow?

    static func run() {
        let app = NSApplication.shared
        let delegate = UIPreviewApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let application = NSMenuItem()
        let commands = NSMenu()
        commands.addItem(withTitle: L10n.text("windows.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        application.submenu = commands
        menu.addItem(application)
        NSApp.mainMenu = menu
        store.snapshots = Self.snapshots(count: 3, observed: false)
        controller = AIUsageMenuBarController(store: store, onOpenUsage: { [weak self] in self?.showSettings() })
        controller.start(observeRunning: false)
        showSettings()
    }

    func applicationWillTerminate(_ notification: Notification) { controller.stop() }

    static func snapshots(count: Int, observed: Bool) -> [AIUsageSnapshot] {
        if observed {
            // Integer percentages read from the running UI on 2026-10-21 at 16:23 PDT.
            return [(AIUsageProvider.codex, 15.0, 1_793_082_720.0), (.grok, 18.0, 1_792_734_120.0)].map { provider, percent, reset in
                AIUsageSnapshot(provider: provider, windows: [.init(id: "weekly", title: L10n.text("quota.weekly"),
                    remainingPercent: percent, resetsAt: Date(timeIntervalSince1970: reset))], isConnected: true,
                    status: "UI readback fixture", source: "UI readback · 2026-10-21 16:23 PDT", updatedAt: Date())
            }
        }
        return PreviewRenderer.snapshots.filter { count == 3 || $0.provider != .claude }.map {
            var value = $0
            if value.provider == .claude { value.windows[0].remainingPercent = 18 }
            value.windows = value.windows.map { window in
                var result = window
                result.resetsAt = window.resetsAt.map { Date().addingTimeInterval($0.timeIntervalSince(PreviewRenderer.now)) }
                return result
            }
            value.updatedAt = Date()
            return value
        }
    }

    private func showSettings() {
        if settings == nil {
            let window = StandaloneWindow.make()
            window.title = "AI SubGauge UI v2 Preview"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: UIPreviewControls { [weak self] count, observed, theme in
                self?.controller.themeOverride = theme
                self?.store.snapshots = Self.snapshots(count: count, observed: observed)
            }.padding(.top, 28))
            window.center()
            settings = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settings?.makeKeyAndOrderFront(nil)
    }
}

private struct UIPreviewControls: View {
    var update: (Int, Bool, AppTheme?) -> Void
    @State private var count = 3
    @State private var observed = false
    @State private var theme = "system"
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("UI v2 · Offline GUI acceptance").font(.headline)
            MenuBarPercentageToggle()
            Picker("Subscriptions", selection: $count) { Text("3").tag(3); Text("2").tag(2) }
                .pickerStyle(.segmented)
            Toggle("Use observed UI values (Codex 15%, Grok 18%)", isOn: $observed)
                .toggleStyle(.checkbox).font(.caption)
            Picker("Panel", selection: $theme) {
                Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
            }.pickerStyle(.segmented)
        }.padding(20)
            .onChange(of: count) { _, _ in apply() }
            .onChange(of: observed) { _, _ in apply() }
            .onChange(of: theme) { _, _ in apply() }
    }
    private func apply() { update(count, observed, AppTheme(rawValue: theme)) }
}
#endif
