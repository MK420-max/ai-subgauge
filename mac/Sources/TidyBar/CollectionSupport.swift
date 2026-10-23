import AppKit
import Darwin

@MainActor
enum CollectionAccess {
    static var message: String { L10n.text("collection.accessibilityRequired") }
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    static func alert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: L10n.text("collection.openSystemSettings"))
        alert.addButton(withTitle: L10n.text("common.cancel"))
        return alert
    }

    static func showPrompt() {
        NSApp.activate(ignoringOtherApps: true)
        if alert().runModal() == .alertFirstButtonReturn { openSettings() }
    }

    static func openSettings() { NSWorkspace.shared.open(settingsURL) }
}

/// An allowlist of collection health values; never serialize settings or menu items.
struct CollectionDiagnostic: Codable, Equatable {
    let axTrusted: Bool
    let postEventAccess: Bool
    let ruleCounts: [String: Int]
    let engineRunning: Bool
    let timestamp: Date

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.mike.aisubgauge/收纳诊断.json")
    }

    init(axTrusted: Bool, postEventAccess: Bool, rules: [String: ItemRule], engineRunning: Bool, timestamp: Date = Date()) {
        self.axTrusted = axTrusted
        self.postEventAccess = postEventAccess
        self.ruleCounts = Dictionary(uniqueKeysWithValues: ItemZone.allCases.map { zone in
            (zone.rawValue, rules.values.filter { $0.zone == zone }.count)
        })
        self.engineRunning = engineRunning
        self.timestamp = timestamp
    }

    func hasSameState(as other: Self) -> Bool {
        axTrusted == other.axTrusted && postEventAccess == other.postEventAccess
            && ruleCounts == other.ruleCounts && engineRunning == other.engineRunning
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let temporary = directory.appendingPathComponent(".collection-" + UUID().uuidString)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); unlink(temporary.path) }
        try handle.write(contentsOf: data)
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }
}
