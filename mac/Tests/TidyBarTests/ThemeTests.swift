import AppKit
import SwiftUI
import Testing
@testable import TidyBar

extension TidyBarTests {
    @Test func sharedThemesParseWithMatchingKeysAndValidColors() throws {
        let document = try #require(try JSONSerialization.jsonObject(with:
            Data(contentsOf: SharedResources.url("theme.json"))) as? [String: Any])
        let themes = try #require(document["themes"] as? [String: [String: Any]])
        let light = try #require(themes["light"]), dark = try #require(themes["dark"])
        #expect(Set(themes.keys) == ["light", "dark"])
        #expect(Set(light.keys) == Set(dark.keys))
        let hex = try NSRegularExpression(pattern: "^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$")
        for palette in [light, dark] {
            for value in palette.values {
                let colors = try (value as? [String]) ?? [#require(value as? String)]
                #expect(!colors.isEmpty)
                for color in colors {
                    #expect(hex.firstMatch(in: color, range: NSRange(color.startIndex..., in: color)) != nil)
                }
            }
        }
        let catalog = try ThemeCatalog.load()
        #expect(catalog.palette(.light).backgroundGradient.count >= 2)
        #expect(catalog.palette(.dark).backgroundGradient.count >= 2)
        #expect(Set(catalog.providers.keys) == Set(AIUsageProvider.allCases.map(\.rawValue)))
    }

    @Test func themeResolvesSystemAndManualSelections() {
        for preference in [nil, "system", "unknown"] as [String?] {
            #expect(AppTheme.resolve(preference: preference, systemDark: false) == .light)
            #expect(AppTheme.resolve(preference: preference, systemDark: true) == .dark)
        }
        for systemDark in [false, true] {
            #expect(AppTheme.resolve(preference: "light", systemDark: systemDark) == .light)
            #expect(AppTheme.resolve(preference: "dark", systemDark: systemDark) == .dark)
        }
    }

    @MainActor @Test func idleIconUsesMonochromeTemplateAtBothScales() throws {
        #expect(AppBrand.idleAsset == "tray-mono")
        let image = AppBrand.idleImage()
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 18, height: 18))
        let representations = image.representations.compactMap { $0 as? NSBitmapImageRep }
        #expect(Set(representations.map(\.pixelsWide)) == [18, 36])
        for bitmap in representations {
            var visiblePixels = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    if color.alphaComponent > 0 {
                        visiblePixels += 1
                        #expect(color.redComponent == color.greenComponent)
                        #expect(color.greenComponent == color.blueComponent)
                    }
                }
            }
            #expect(visiblePixels > 0)
        }
    }

    @MainActor @Test func quotaUsesExistingLiquidColorsAndContinuousTransitions() throws {
        let catalog = try ThemeCatalog.load()
        #expect(catalog.quota == ["high": "#2CAC6D", "mid": "#E7B228", "low": "#E04B52"])
        #expect(catalog.quotaColor(100).tidyHex == "#2CAC6D")
        #expect(catalog.quotaColor(50).tidyHex == "#2CAC6D")
        #expect(catalog.quotaColor(32.5).tidyHex == "#E7B228")
        #expect(catalog.quotaColor(15).tidyHex == "#E04B52")
        #expect(catalog.quotaColor(0).tidyHex == "#E04B52")
        #expect(catalog.quotaColor(23.75).tidyHex == "#E47E3D")
        #expect(catalog.quotaColor(41.25).tidyHex == "#8AAF4A")
        #expect(catalog.quotaColor(nil) == .clear)
        #expect(catalog.quotaColor(.nan) == .clear)
    }

    @MainActor @Test func previewThemeArgumentsAndCompactBilingualText() throws {
        #expect(try PreviewRenderer.theme(arguments: ["app"]) == nil)
        for mode in AppTheme.allCases {
            let args = ["app", "--theme", mode.rawValue, "--render-preview", "/tmp/preview", "--lang", "en"]
            #expect(try PreviewRenderer.theme(arguments: args) == mode)
            #expect(try PreviewRenderer.directory(arguments: args)?.path == "/tmp/preview")
            #expect(AppBrand.logo(mode).isValid)
            #expect(AppBrand.icon(mode).isValid)
        }
        for args in [["app", "--theme"], ["app", "--theme", "system"],
                     ["app", "--theme", "dark", "--theme", "light"]] {
            #expect(throws: (any Error).self) { try PreviewRenderer.theme(arguments: args) }
        }
        let previous = L10n.overrideLanguage
        defer { L10n.overrideLanguage = previous }
        for language in ["en", "zh-Hans"] {
            L10n.overrideLanguage = language
            #expect(PreviewRenderer.snapshots.map(\.provider) == [.codex, .grok, .claude])
            #expect(PreviewRenderer.snapshots.allSatisfy { $0.status == L10n.text("demo.label") })
            let reset = PanelQuotaText.reset(PreviewRenderer.now.addingTimeInterval(12000), now: PreviewRenderer.now)
            #expect(reset == (language == "en" ? "resets in 3h 20m" : "3小时20分后重置"))
            #expect(L10n.text("panel.quotaLeft", "72%") == (language == "en" ? "72% left" : "剩余 72%"))
            #expect(PanelQuotaText.reset(nil, now: PreviewRenderer.now) == L10n.text("panel.resetUnknown"))
            #expect(PanelQuotaText.reset(PreviewRenderer.now, now: PreviewRenderer.now) == L10n.text("panel.resetDue"))
        }
    }
}
