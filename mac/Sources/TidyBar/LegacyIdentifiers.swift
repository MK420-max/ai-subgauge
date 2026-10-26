import Foundation

/// Read-only compatibility identifiers from releases before the initial AI SubGauge release.
/// Keep these in one place: migration copies old state and never removes it.
enum LegacyIdentifiers {
    static let bundleID = "com.mike.menubartidy"
    static let keychainService = bundleID + ".api"

    static func current(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: bundleID, with: AppIdentifiers.bundleID)
    }
}

enum AppIdentifiers {
    static let name = "AI SubGauge"
    static let version = "2.0.3"
    static let bundleID = "com.mike.aisubgauge"
    static let keychainService = bundleID + ".api"
    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID, isDirectory: true)
    }
}
