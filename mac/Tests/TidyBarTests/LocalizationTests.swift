import Foundation
import Testing
@testable import TidyBar

extension TidyBarTests {
    @Test func sharedCatalogsHaveIdenticalNonemptyKeysAndValuesAndValidReferences() throws {
        let en = try L10n.load("en"), zh = try L10n.load("zh-Hans")
        #expect(!en.isEmpty)
        #expect(Set(en.keys) == Set(zh.keys))
        let placeholders = try NSRegularExpression(pattern: #"\{\d+\}"#)
        func tokens(_ value: String) -> Set<String> {
            Set(placeholders.matches(in: value, range: NSRange(value.startIndex..., in: value)).map {
                String(value[Range($0.range, in: value)!])
            })
        }
        for (key, value) in en {
            #expect(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            let translated = try #require(zh[key])
            #expect(!translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(tokens(value) == tokens(translated))
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/TidyBar")
        let pattern = try NSRegularExpression(pattern: #"L10n\.text\("([^"]+)""#)
        var references = Set<String>()
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where file.pathExtension == "swift" {
            let source = try String(contentsOf: file)
            for match in pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                references.insert(String(source[Range(match.range(at: 1), in: source)!]))
            }
        }
        #expect(!references.isEmpty)
        #expect(references.isSubset(of: Set(en.keys)))
    }

    @Test func nativePermissionDescriptionsAlsoUseSharedKeys() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let info = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: root.appendingPathComponent("Resources/Info.plist")), format: nil) as? [String: Any])
        for language in ["en", "zh-Hans"] {
            let catalog = try L10n.load(language)
            for key in ["CFBundleName", "CFBundleDisplayName", "NSCalendarsFullAccessUsageDescription", "NSAppleEventsUsageDescription", "NSLocationUsageDescription", "NSLocationWhenInUseUsageDescription"] {
                let reference = try #require(info[key] as? String)
                #expect(catalog[reference]?.isEmpty == false)
            }
        }
    }

    @Test func languageFollowsSystemOrExplicitPreference() {
        #expect(L10n.resolve(preference: nil, preferredLanguages: ["zh-TW"]) == "zh-Hans")
        #expect(L10n.resolve(preference: "system", preferredLanguages: ["zh-HK"]) == "zh-Hans")
        #expect(L10n.resolve(preference: nil, preferredLanguages: ["fr-FR"]) == "en")
        #expect(L10n.resolve(preference: nil, preferredLanguages: []) == "en")
        #expect(L10n.resolve(preference: "en", preferredLanguages: ["zh-CN"]) == "en")
        #expect(L10n.resolve(preference: "zh-Hans", preferredLanguages: ["en"]) == "zh-Hans")
    }

    #if DEBUG
    @MainActor @Test func previewLanguageArgumentsAndTranslations() throws {
        let previous = L10n.overrideLanguage
        defer { L10n.overrideLanguage = previous }
        try L10n.configure(arguments: ["AISubGauge", "--render-preview", "/tmp/preview", "--lang", "en"])
        #expect(L10n.text("panel.title") == "Account quota")
        #expect(L10n.text("panel.accountCount", 3) == "3 accounts")
        #expect(L10n.text("error.refresh", "{0}") == "Refresh failed: {0}")
        #expect(PreviewRenderer.snapshots.first?.status == "Demo data")
        #expect(try PreviewRenderer.directory(arguments: ["AISubGauge", "--lang", "en", "--render-preview", "/tmp/preview"])?.path == "/tmp/preview")
        try L10n.configure(arguments: ["AISubGauge", "--lang", "zh-Hans"])
        #expect(L10n.text("panel.title") == "账户余量")
        #expect(PreviewRenderer.snapshots.first?.status == "演示数据")
        #expect(throws: (any Error).self) { try L10n.configure(arguments: ["AISubGauge", "--lang", "fr"]) }
        #expect(throws: (any Error).self) { try L10n.configure(arguments: ["AISubGauge", "--lang"]) }
        #expect(throws: (any Error).self) { try PreviewRenderer.directory(arguments: ["AISubGauge", "--render-preview", "/tmp/preview", "--lang", "en", "--lang", "zh-Hans"]) }
    }
    #endif
}
