import Foundation
import LocalAuthentication
import Security

protocol MigrationKeychain {
    func read(service: String, account: String) throws -> Data?
    func copyIfAbsent(_ data: Data, service: String, account: String) throws
}

/// Only generic-password items with this app's known API-provider account names are queried.
struct SystemMigrationKeychain: MigrationKeychain {
    func read(service: String, account: String) throws -> Data? {
        var query = attributes(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw Failure.keychain }
        return data
    }

    func copyIfAbsent(_ data: Data, service: String, account: String) throws {
        var item = attributes(service: service, account: account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else { throw Failure.keychain }
    }

    private func attributes(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
    enum Failure: Error { case keychain }
}

struct AppMigration {
    static let marker = "migration.aisubgauge.v1."
    let defaults: UserDefaults
    let oldDomain: String
    let newDomain: String
    let oldDirectory: URL
    let newDirectory: URL
    let keychain: any MigrationKeychain

    static func runAtLaunch() -> [String] {
        let parent = AppIdentifiers.supportDirectory.deletingLastPathComponent()
        return AppMigration(defaults: .standard, oldDomain: LegacyIdentifiers.bundleID,
            newDomain: AppIdentifiers.bundleID,
            oldDirectory: parent.appendingPathComponent(LegacyIdentifiers.bundleID),
            newDirectory: AppIdentifiers.supportDirectory, keychain: SystemMigrationKeychain()).run()
    }

    /// Successful stages run once. Failed stages retry on a later launch, without blocking startup.
    @discardableResult func run() -> [String] {
        var failures: [String] = []
        if !defaults.bool(forKey: Self.marker + "defaults") {
            var target = defaults.persistentDomain(forName: newDomain) ?? [:]
            let old = defaults.persistentDomain(forName: oldDomain) ?? [:]
            for (key, value) in old where target[key] == nil { target[key] = value }
            // AppKit embeds autosave identifiers in defaults keys. Preserve both keys.
            for (key, value) in target where key.contains(LegacyIdentifiers.bundleID) {
                let renamed = LegacyIdentifiers.current(key)
                if target[renamed] == nil { target[renamed] = value }
            }
            target[Self.marker + "defaults"] = true
            defaults.setPersistentDomain(target, forName: newDomain)
        }
        if !defaults.bool(forKey: Self.marker + "files") {
            do {
                try copyDirectory(oldDirectory, to: newDirectory)
                defaults.set(true, forKey: Self.marker + "files")
            } catch { failures.append(L10n.text("migration.the.old.settings.directory.could.not.be")) }
        }
        if !defaults.bool(forKey: Self.marker + "keychain") {
            var complete = true
            for provider in AIUsageProvider.allCases where provider.isAPIAccount {
                do {
                    if try keychain.read(service: AppIdentifiers.keychainService, account: provider.rawValue) != nil { continue }
                    if let data = try keychain.read(service: LegacyIdentifiers.keychainService, account: provider.rawValue) {
                        try keychain.copyIfAbsent(data, service: AppIdentifiers.keychainService, account: provider.rawValue)
                    }
                } catch { complete = false }
            }
            if complete { defaults.set(true, forKey: Self.marker + "keychain") }
            else { failures.append(L10n.text("migration.some.old.api.keys.could.not.be")) }
        }
        return failures
    }

    private func copyDirectory(_ source: URL, to destination: URL) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: source.path) else { return }
        let attributes = try manager.attributesOfItem(atPath: source.path)
        // Never follow symlinks out of the old application directory.
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { return }
        if manager.fileExists(atPath: destination.path) {
            guard try manager.attributesOfItem(atPath: destination.path)[.type] as? FileAttributeType == .typeDirectory else { return }
        } else { try PrivateFiles.createDirectory(at: destination) }
        for child in try manager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            let target = destination.appendingPathComponent(child.lastPathComponent)
            let type = try manager.attributesOfItem(atPath: child.path)[.type] as? FileAttributeType
            if type == .typeDirectory { try copyDirectory(child, to: target) }
            else if type == .typeRegular, !manager.fileExists(atPath: target.path) {
                try manager.copyItem(at: child, to: target)
            }
        }
    }
}
