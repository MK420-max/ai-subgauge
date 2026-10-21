import Foundation

/// Shared flat JSON catalogs. Language changes take effect after restarting the app.
enum L10n {
    static var overrideLanguage: String?
    private static let launchLanguage = resolve(preference: UserDefaults.standard.string(forKey: "Language"),
        preferredLanguages: Locale.preferredLanguages)
    static var language: String { overrideLanguage ?? launchLanguage }
    static var locale: Locale { Locale(identifier: language) }
    private static let catalogs: [String: [String: String]] = Dictionary(uniqueKeysWithValues: ["en", "zh-Hans"].map {
        ($0, (try? load($0)) ?? [:])
    })

    static func resolve(preference: String?, preferredLanguages: [String]) -> String {
        if let preference, ["en", "zh-Hans"].contains(preference) { return preference }
        return preferredLanguages.first?.lowercased().hasPrefix("zh") == true ? "zh-Hans" : "en"
    }
    static func load(_ language: String, at url: URL? = nil) throws -> [String: String] {
        try JSONDecoder().decode([String: String].self, from: BoundedFile.read(url ?? SharedResources.url(language + ".json", directory: "i18n")))
    }
    static func text(_ key: String, _ arguments: Any...) -> String {
        let template = catalogs[language]?[key] ?? catalogs["en"]?[key] ?? key
        // One pass avoids interpreting placeholder-like text inside user/server values.
        let parts = template.components(separatedBy: "{")
        return (parts.first ?? "") + parts.dropFirst().map { part in
            guard let end = part.firstIndex(of: "}"), let index = Int(part[..<end]), arguments.indices.contains(index) else { return "{" + part }
            return String(describing: arguments[index]) + part[part.index(after: end)...]
        }.joined()
    }
    static func configure(arguments: [String]) throws {
        guard let flag = arguments.firstIndex(of: "--lang") else { return }
        guard flag + 1 < arguments.count, ["en", "zh-Hans"].contains(arguments[flag + 1]),
              arguments.filter({ $0 == "--lang" }).count == 1 else {
            throw AIUsageError.unavailable(text("error.languageArgument"))
        }
        overrideLanguage = arguments[flag + 1]
    }
}
