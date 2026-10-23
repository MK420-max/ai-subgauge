import AppKit
import SwiftUI
import Testing
@testable import TidyBar

extension TidyBarTests {
    @Test func settingsV2SidebarAndVendorsKeepTheRequiredOrder() {
        #expect(SettingsSection.sidebarPages == [.subscriptions, .layout, .bar, .panel, .widgets, .appearance, .presets, .automation, .hotkeys, .general])
        #expect(SettingsSection.addonPages.count == 8)
        #expect(SubscriptionVendor.all.map(\.id) == ["codex", "claude", "grok", "gemini", "copilot", "cursor", "deepseek", "perplexity", "mistral", "qwen", "kimi"])
        #expect(SubscriptionVendor.all.filter { $0.provider == nil }.map(\.id) == ["copilot", "cursor", "perplexity", "mistral", "qwen"])
    }

    @MainActor @Test func settingsV2OrderAndMenuVisibilityPersistWithoutChangingPanelAccounts() throws {
        let name = "settings-v2-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = SubscriptionPreferences(defaults: defaults)
        #expect(preferences.order.prefix(3) == [.codex, .claude, .grok])
        #expect(preferences.showsInMenuBar(.claude))
        #expect(preferences.move(.grok, before: .codex))
        #expect(!preferences.move(.codex, before: .codex))
        preferences.setShowsInMenuBar(false, provider: .claude)
        let reopened = try #require(UserDefaults(suiteName: name))
        let store = AIUsageStore(applyDisplayFilters: false, displayDefaults: reopened, fetcher: { _ in throw AIUsageError.signedOut })
        store.snapshots = Self.settingsV2Snapshots
        #expect(store.subscriptionDisplaySnapshots.map(\.provider) == [.grok, .codex, .claude])
        #expect(store.menuBarDisplaySnapshots.map(\.provider) == [.grok, .codex])
        #expect(QuotaMenuImage.image(snapshots: store.menuBarDisplaySnapshots, showPercentage: true).size.width == 2 * MenuArcMetrics.segmentSize + MenuArcMetrics.segmentGap)
        preferences.setShowsInMenuBar(true, provider: .claude)
        #expect(store.menuBarDisplaySnapshots.map(\.provider) == [.grok, .codex, .claude])
        for provider in [AIUsageProvider.codex, .claude, .grok] { preferences.setShowsInMenuBar(false, provider: provider) }
        #expect(store.menuBarDisplaySnapshots.isEmpty)
        #expect(store.subscriptionDisplaySnapshots.count == 3)
    }

    @Test func subscriptionReorderCanDropAfterTheLastVisibleRowAndPersists() throws {
        let name = "subscription-drop-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = SubscriptionPreferences(defaults: defaults)
        #expect(preferences.move(.codex, after: .grok))
        #expect(preferences.order.prefix(3) == [.claude, .grok, .codex])
        let last = try #require(preferences.order.last)
        #expect(preferences.move(.claude, after: last))
        #expect(preferences.order.last == .claude)
        #expect(SubscriptionPreferences(defaults: try #require(UserDefaults(suiteName: name))).order == preferences.order)
        #expect(!preferences.move(.claude, after: .claude))
    }

    @MainActor @Test func settingsV2MonochromeUsesForegroundInMenuAndPanelArc() throws {
        #expect(SubscriptionPreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!).colorsByQuota)
        for percent in [8.0, 35, 72] {
            for foreground in [NSColor.black, .white] {
                #expect(QuotaMenuImage.fillColor(percent: percent, colorsByQuota: false, foreground: foreground) == foreground)
                #expect(QuotaMenuImage.fillColor(percent: percent, colorsByQuota: true, foreground: foreground) != foreground)
            }
        }
        for panel in [false, true] {
            let size: CGFloat = panel ? MenuArcMetrics.panelSize : MenuArcMetrics.segmentSize
            let image = panel
                ? QuotaMenuImage.segmentImage(provider: .grok, percent: 72, size: size, foreground: .black, colorsByQuota: false)
                : QuotaMenuImage.image(snapshots: [Self.settingsV2Snapshots[0]], showPercentage: false, colorsByQuota: false)
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size) * 2, pixelsHigh: Int(size) * 2,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            bitmap.size = NSSize(width: size, height: size)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
            NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
                image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
            }
            NSGraphicsContext.restoreGraphicsState()
            var filled = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    if color.alphaComponent > 0.5 {
                        filled += 1
                        #expect(abs(color.redComponent - color.greenComponent) < 0.01)
                        #expect(abs(color.greenComponent - color.blueComponent) < 0.01)
                    }
                }
            }
            #expect(filled > 30)
        }
    }

    @MainActor @Test func settingsV2RefreshPreferenceReschedulesTheExistingTimer() async throws {
        let name = "settings-v2-refresh-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = AIUsageStore(displayDefaults: defaults, fetcher: { _ in throw AIUsageError.signedOut })
        #expect(SubscriptionPreferences(defaults: defaults).refreshMinutes == 2)
        store.start()
        defer { store.stop() }
        #expect(store.scheduledRefreshInterval == 120)
        for minutes in SubscriptionPreferences.refreshOptions {
            defaults.set(minutes, forKey: SubscriptionPreferences.refreshKey)
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
            for _ in 0..<30 where store.scheduledRefreshInterval != TimeInterval(minutes * 60) {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(store.scheduledRefreshInterval == TimeInterval(minutes * 60))
        }
        defaults.set(999, forKey: SubscriptionPreferences.refreshKey)
        #expect(SubscriptionPreferences(defaults: defaults).refreshMinutes == 2)
    }

    @MainActor @Test func settingsV2NewCopyAndSidebarAreBilingual() throws {
        let keys = ["settings.subscriptions", "settings.addons", "settings.subscriptions.caption", "settings.addons.caption",
                    "settings.search", "settings.subscriptions.empty", "settings.addSubscription", "settings.refreshNow", "settings.accountDetails",
                    "settings.subscriptionMenuBar", "settings.login.cli", "settings.login.web", "settings.login.account", "settings.login.api",
                    "settings.subscriptionStatus", "settings.quotaDisplay", "settings.colorByQuota", "settings.refreshInterval", "settings.refreshMinutes",
                    "settings.chooseVendor", "settings.comingSoon", "settings.continue", "panel.showPercentageInMenuBar", "common.cancel",
                    "settings.menuBarDisplay", "settings.percentagePlacement", "settings.percentagePlacement.arcTop", "settings.percentagePlacement.beside"]
        for language in ["en", "zh-Hans"] {
            let catalog = try L10n.load(language)
            for key in keys + SettingsSection.allCases.map(\.titleKey) {
                #expect(catalog[key]?.isEmpty == false, "Missing \(language): \(key)")
            }
        }
        for vendor in SubscriptionVendor.all {
            #expect(NSImage(contentsOf: SharedResources.url(vendor.logo, directory: "logos/subscriptions"))?.isValid == true)
        }
    }

    @MainActor @Test func settingsV2FormattedCopyContainsValuesInsteadOfPlaceholders() throws {
        let previous = L10n.overrideLanguage
        defer { L10n.overrideLanguage = previous }
        for language in ["en", "zh-Hans"] {
            L10n.overrideLanguage = language
            let chinese = language == "zh-Hans"
            let snapshots = Self.settingsV2Snapshots
            let statuses = snapshots.map { snapshot in
                SettingsSubscriptionsView.status(snapshot, percent: snapshot.windows.first?.remainingPercent)
            }
            #expect(statuses == (chinese
                ? ["已连接 · CLI 登录 · 剩余 72%", "已连接 · 网页登录 · 剩余 35%", "已连接 · 账号授权 · 剩余 8%"]
                : ["Connected · CLI login · 72% remaining", "Connected · Web login · 35% remaining", "Connected · Account authorization · 8% remaining"]))
            let intervals = SubscriptionPreferences.refreshOptions.map { L10n.text("settings.refreshMinutes", $0) }
            #expect(intervals == SubscriptionPreferences.refreshOptions.map { "\($0)" + (chinese ? " 分钟" : " min") })
            for text in statuses + intervals {
                #expect(!text.contains("%@") && !text.contains("%d") && !text.contains("{0}") && !text.contains("{1}") && !text.contains("{2}"))
            }
            for (key, value) in try L10n.load(language) where key.hasPrefix("settings.") {
                #expect(!value.contains("%@") && !value.contains("%d"), "Unsupported format in \(language): \(key)")
            }
        }
    }

    @MainActor @Test func settingsV2DisplaySwitchesDefaultOnAndRenderSavedOffState() throws {
        let name = "settings-v2-switches-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        func greenPixels() throws -> Int {
            let view = SettingsDisplayPreferences(approximateGlass: true)
                .defaultAppStorage(defaults).environment(\.colorScheme, .light).frame(width: 400)
            let renderer = ImageRenderer(content: view)
            let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
            var green = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    if color.alphaComponent > 0.5 && color.greenComponent > color.redComponent + 0.15
                        && color.greenComponent > color.blueComponent + 0.15 { green += 1 }
                }
            }
            return green
        }
        #expect(try greenPixels() > 300)
        let keys = [AIUsageMenuBarPreference.key, AIUsageMenuBarPreference.percentageKey, SubscriptionPreferences.colorKey]
        for key in keys { defaults.set(false, forKey: key) }
        #expect(try greenPixels() == 0)
        for key in keys { defaults.set(true, forKey: key) }
        #expect(try greenPixels() > 300)
    }

    @MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["SG_PREVIEW_DIR"] != nil), arguments: ["zh-Hans", "en"])
    func settingsV2Previews(language: String) throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["SG_PREVIEW_DIR"]), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = L10n.overrideLanguage
        defer { L10n.overrideLanguage = previous }
        L10n.overrideLanguage = language
        let settings = SettingsStore(url: directory.appendingPathComponent("settings-v2-unused-fixture.json"))
        let name = "settings-v2-preview-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let usage = AIUsageStore(applyDisplayFilters: false, displayDefaults: defaults, fetcher: { _ in throw AIUsageError.signedOut })
        usage.snapshots = Self.settingsV2Snapshots
        for (suffix, section, dark, sheet) in [
            ("subs-light", SettingsSection.subscriptions, false, false),
            ("subs-dark", .subscriptions, true, false), ("addsub-light", .subscriptions, false, true),
            ("general-light", .general, false, false), ("addons-light", .addons, false, false)
        ] {
            let mode: AppTheme = dark ? .dark : .light
            let view = SettingsV2PreviewScene(dark: dark) {
                SettingsView(store: settings, section: section, usageStore: usage, approximateGlass: true)
                    .defaultAppStorage(defaults)
                    .overlay(alignment: .topLeading) {
                        if sheet {
                            Color.black.opacity(0.12).clipShape(RoundedRectangle(cornerRadius: 26))
                            SubscriptionVendorGrid(approximateGlass: true, connected: [.codex, .claude, .grok],
                                                   selected: .constant(nil), cancel: {}, proceed: {})
                                .shadow(color: .black.opacity(0.3), radius: 25, y: 20)
                                .padding(.leading, 110).padding(.top, 44)
                        }
                    }
                    .environment(\.appTheme, mode).environment(\.colorScheme, mode.colorScheme)
            }
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(x: 0, y: 0, width: 760, height: 520)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            window.orderBack(nil)
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1520, pixelsHigh: 1040,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0))
            bitmap.size = NSSize(width: 760, height: 520)
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            window.orderOut(nil)
            #expect(bitmap.pixelsWide == 1520 && bitmap.pixelsHigh == 1040)
            let filename = section == .subscriptions && !sheet
                ? "settings-\(mode.rawValue)-\(language == "en" ? "en" : "zh").png"
                : "settings-v2-impl-\(suffix)-\(language == "en" ? "en" : "zh").png"
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent(filename))
            if language == "zh-Hans", !dark, !sheet, section == .subscriptions || section == .general {
                let percentageFilename = section == .subscriptions ? "settings-subs-pct-zh.png" : "settings-general-pct-zh.png"
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent(percentageFilename))
            }
        }
    }

    @MainActor private static var settingsV2Snapshots: [AIUsageSnapshot] {
        [(AIUsageProvider.codex, "ChatGPT Plus", 72.0, CodexUsageSource.source),
         (.claude, "Pro", 35, ClaudeWebUsage.source), (.grok, "SuperGrok", 8, GrokBuildUsageSource.source)].map { provider, plan, percent, source in
            AIUsageSnapshot(provider: provider, plan: plan, windows: [
                .init(id: "five_hour", title: L10n.text("quota.fiveHours"), remainingPercent: percent,
                      resetsAt: UsageSnapshotFixture.now.addingTimeInterval(10800))
            ], isConnected: true, status: "", source: source, updatedAt: UsageSnapshotFixture.now.addingTimeInterval(-60))
        }
    }
}

private struct SettingsV2PreviewScene<Content: View>: View {
    var dark: Bool
    @ViewBuilder var content: () -> Content
    var body: some View {
        ZStack(alignment: .topLeading) {
            PanelV2PreviewWallpaper(dark: dark)
            content().shadow(color: .black.opacity(dark ? 0.55 : 0.28), radius: 30, y: 24)
                .padding(.leading, 60).padding(.top, 46)
        }.frame(width: 760, height: 520)
    }
}
