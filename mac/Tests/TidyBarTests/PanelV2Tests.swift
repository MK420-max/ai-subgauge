import AppKit
import SwiftUI
import Testing
@testable import TidyBar

extension TidyBarTests {
    @MainActor @Test func panelV2Has360PointWidthAndBilingualCopy() throws {
        #expect(AIUsagePopoverView.width == 360)
        let previous = L10n.overrideLanguage
        defer { L10n.overrideLanguage = previous }
        for language in ["en", "zh-Hans"] {
            L10n.overrideLanguage = language
            let store = Self.panelV2Store()
            let view = AIUsagePopoverView(store: store, now: UsageSnapshotFixture.now,
                height: AIUsagePopoverView.height(for: 3), onOpenUsage: {}, scrollable: false,
                themeOverride: .light, approximateGlass: true)
            let renderer = ImageRenderer(content: view)
            #expect(try #require(renderer.cgImage).width == 360)
            let catalog = try L10n.load(language)
            for key in ["panel.remainingQuota", "panel.quotaWindows", "panel.updatedTime", "panel.timeFormat",
                        "panel.resetDaysShort", "panel.resetHoursShort", "panel.refresh", "panel.settings",
                        "windows.quit", "quota.fiveHours", "quota.weekly", "common.unknown"] {
                #expect(catalog[key]?.isEmpty == false)
            }
        }
    }

    @MainActor @Test func panelV2MatchesRealWindowKindsAndKeepsMissingQuotasEmpty() throws {
        let previous = L10n.overrideLanguage
        defer { L10n.overrideLanguage = previous }
        for language in ["en", "zh-Hans"] {
            L10n.overrideLanguage = language
            let codex = try CodexUsageSource.parse(["rateLimits": [
                "primary": ["windowDurationMins": 300, "usedPercent": 28],
                "secondary": ["windowDurationMins": 10080, "usedPercent": 42]
            ]])
            #expect(PanelQuotaData.window(.fiveHours, in: codex)?.remainingPercent == 72)
            #expect(PanelQuotaData.window(.weekly, in: codex)?.remainingPercent == 58)
            var grok = AIUsageSnapshot(provider: .grok, windows: [
                .init(id: "grok.weekly", title: L10n.text("usage.team.weekly"), remainingPercent: 22),
                .init(id: "grok.additional", title: L10n.text("usage.extra.usage.limit"), remainingPercent: 99)
            ], isConnected: true, status: "fixture", source: "fixture")
            #expect(PanelQuotaData.window(.fiveHours, in: grok) == nil)
            let weekly = try #require(PanelQuotaData.window(.weekly, in: grok))
            #expect(PanelQuotaData.remaining(weekly, in: grok) == 22)
            #expect(PanelQuotaData.remaining(nil, in: grok) == nil)
            grok.isConnected = false
            #expect(PanelQuotaData.remaining(weekly, in: grok) == nil)
            #expect(PanelQuotaText.status(grok, now: UsageSnapshotFixture.now) == "fixture")
            grok.isConnected = true
            grok.error = "offline fixture"
            #expect(PanelQuotaData.remaining(weekly, in: grok) == nil)
            #expect(PanelQuotaText.status(grok, now: UsageSnapshotFixture.now) == L10n.text("error.refresh", "offline fixture"))
            for invalid in [Double.nan, .infinity, -1, 101] {
                #expect(PanelQuotaData.remaining(.init(id: "invalid", title: "", remainingPercent: invalid), in: codex) == nil)
            }
            let shortWindow = AIUsageSnapshot(provider: .codex, windows: [
                .init(id: "codex.primary", title: L10n.text("usage.0.minutes", 60), remainingPercent: 50)
            ], isConnected: true, status: "", source: "fixture")
            #expect(PanelQuotaData.window(.fiveHours, in: shortWindow) == nil)
        }
    }

    @MainActor @Test func panelV2ColorsReuseMenuThresholdsAndScaledGlyphLayout() {
        for (percent, expected) in [(0.0, NSColor.systemRed), (19.999, .systemRed),
                                    (20, .systemOrange), (49.999, .systemOrange), (50, .systemGreen), (100, .systemGreen)] {
            #expect(QuotaMenuImage.fillColor(percent: percent) == expected)
        }
        let image = QuotaMenuImage.segmentImage(provider: .codex, percent: 72, size: MenuArcMetrics.panelSize, foreground: .white)
        #expect(image.size == NSSize(width: MenuArcMetrics.panelSize, height: MenuArcMetrics.panelSize))
        #expect(!image.isTemplate)
        #expect(PanelQuotaText.compactReset(UsageSnapshotFixture.now.addingTimeInterval(10800), now: UsageSnapshotFixture.now)
                == L10n.text("panel.resetHoursShort", 3))
        #expect(PanelQuotaText.compactReset(UsageSnapshotFixture.now.addingTimeInterval(172800), now: UsageSnapshotFixture.now)
                == L10n.text("panel.resetDaysShort", 2))
    }

    /// Offline rendering uses a translucent tint because ImageRenderer has no window backdrop.
    @MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["SG_PREVIEW_DIR"] != nil), arguments: ["zh-Hans", "en"])
    func panelV2Previews(language: String) throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["SG_PREVIEW_DIR"]), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = L10n.overrideLanguage
        defer { L10n.overrideLanguage = previous }
        L10n.overrideLanguage = language
        let store = Self.panelV2Store()
        for dark in [false, true] {
            let theme: AppTheme = dark ? .dark : .light
            let view = PanelV2PreviewWallpaper(dark: dark)
                .overlay(alignment: .topTrailing) {
                    AIUsagePopoverView(store: store, now: UsageSnapshotFixture.now,
                        height: AIUsagePopoverView.height(for: 3), onOpenUsage: {}, scrollable: false,
                        themeOverride: theme, approximateGlass: true)
                        .shadow(color: .black.opacity(dark ? 0.5 : 0.25), radius: 25, y: 18)
                        .padding(.top, 30).padding(.trailing, 96)
                }
                .frame(width: 640, height: 340)
                .environment(\.colorScheme, theme.colorScheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            #expect(image.width == 1280 && image.height == 680)
            let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("panel-\(theme.rawValue)-\(language == "en" ? "en" : "zh").png"))
        }
    }

    @MainActor private static func panelV2Store() -> AIUsageStore {
        let store = AIUsageStore(applyDisplayFilters: false, fetcher: { _ in throw AIUsageError.signedOut })
        let values: [(AIUsageProvider, String, Double, Double, TimeInterval)] = [
            (.codex, "Plus", 72, 58, 10800), (.claude, "Pro", 35, 61, 7200), (.grok, "SuperGrok", 8, 22, 172800)
        ]
        store.snapshots = values.map { provider, plan, fiveHours, weekly, reset in
            AIUsageSnapshot(provider: provider, plan: plan, windows: [
                .init(id: "five_hour", title: L10n.text("quota.fiveHours"), remainingPercent: fiveHours,
                      resetsAt: UsageSnapshotFixture.now.addingTimeInterval(reset)),
                .init(id: "seven_day", title: L10n.text("quota.weekly"), remainingPercent: weekly)
            ], isConnected: true, status: "", source: "fixture", updatedAt: UsageSnapshotFixture.now.addingTimeInterval(-60))
        }
        return store
    }
}

struct PanelV2PreviewWallpaper: View {
    var dark: Bool
    var body: some View {
        GeometryReader { geometry in
            LinearGradient(colors: (dark ? ["#0B1026", "#1A0B2E"] : ["#FDE2E4", "#D7E9FF"]).map { Color(themeHex: $0) },
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay { glow(dark ? "#C2410C" : "#FF9F6B", at: .init(x: 0.18, y: 0.3), radius: geometry.size.width * 0.4) }
                .overlay { glow(dark ? "#1D4ED8" : "#6FB7FF", at: .init(x: 0.8, y: 0.25), radius: geometry.size.width * 0.36) }
                .overlay { glow(dark ? "#7C3AED" : "#B98CFF", at: .init(x: 0.6, y: 0.9), radius: geometry.size.width * 0.4) }
                .overlay { glow(dark ? "#0E7490" : "#FFE07A", at: .init(x: 0.4, y: 0.6), radius: geometry.size.width * 0.26) }
        }
    }
    private func glow(_ hex: String, at center: UnitPoint, radius: CGFloat) -> some View {
        RadialGradient(colors: [Color(themeHex: hex), Color(themeHex: hex).opacity(0)],
                       center: center, startRadius: 0, endRadius: radius)
    }
}
