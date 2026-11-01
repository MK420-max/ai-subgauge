import Foundation
import Testing
@testable import TidyBar

extension TidyBarTests {
    @Test func permissionCacheExpiresAfterThirtySecondsAndCanBeInvalidated() {
        var cache = PermissionCache<Bool>()
        var checks = 0
        var granted = false
        func query() -> Bool { checks += 1; return granted }
        let initial = cache.value(now: 100, query: query)
        #expect(!initial)
        granted = true
        let beforeExpiry = cache.value(now: 129.9, query: query)
        #expect(!beforeExpiry)
        #expect(checks == 1)
        let expired = cache.value(now: 130, query: query)
        #expect(expired)
        #expect(checks == 2)
        granted = false
        cache.invalidate()
        let invalidated = cache.value(now: 131, query: query)
        #expect(!invalidated)
        #expect(checks == 3)
    }

    @MainActor @Test func accessibilityFallbackCachesInjectedCheckButExplicitRefreshIsImmediate() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SettingsStore(url: folder.appendingPathComponent("settings.json"))
        var checks = 0
        var granted = false
        let engine = MenuEngine(store: store, accessibilityCheck: { checks += 1; return granted })
        engine.refreshAccessibility(force: false)
        granted = true
        engine.refreshAccessibility(force: false)
        #expect(checks == 1)
        #expect(!engine.accessibilityGranted)
        engine.refreshAccessibility()
        #expect(checks == 2)
        #expect(engine.accessibilityGranted)
        granted = false
        engine.onAccessibilityRequired = {}
        #expect(!engine.requireCollectionAccessibility())
        #expect(checks == 3)
    }

    @MainActor @Test func cachedDatesMatchFreshFormattersAcrossLanguageAndTimeZoneChanges() {
        let previousLanguage = L10n.overrideLanguage
        let previousTimeZone = NSTimeZone.default
        defer {
            L10n.overrideLanguage = previousLanguage
            NSTimeZone.default = previousTimeZone
        }
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        for zone in ["America/Vancouver", "Asia/Shanghai", "America/Vancouver"] {
            NSTimeZone.default = TimeZone(identifier: zone)!
            for language in ["en", "zh-Hans", "en"] {
                L10n.overrideLanguage = language
                for key in ["format.dateTime", "panel.timeFormat"] {
                    let fresh = DateFormatter()
                    fresh.locale = L10n.locale
                    fresh.timeZone = .current
                    fresh.dateFormat = L10n.text(key)
                    #expect(L10n.date(date, formatKey: key) == fresh.string(from: date))
                    if key == "format.dateTime" {
                        #expect(AIUsageMenuBarController.date(date) == fresh.string(from: date))
                    }
                }
            }
        }
    }
}
