import Foundation
import Security

/// API credentials stay in the user's login keychain; snapshots and preferences contain no key.
final class APIAccountCredentials {
    static let shared = APIAccountCredentials()
    private let service = AppIdentifiers.keychainService
    private let lock = NSLock()

    enum CredentialError: LocalizedError {
        case invalidKey, unsupportedProvider, keychain(OSStatus)
        var errorDescription: String? {
            switch self {
            case .invalidKey: return L10n.text("error.enter.a.valid.api.key.it.cannot")
            case .unsupportedProvider: return L10n.text("error.this.service.does.not.support.saving.api")
            case .keychain: return L10n.text("error.could.not.access.the.system.keychain.check")
            }
        }
    }

    static func validated(_ value: String) throws -> String {
        guard value.rangeOfCharacter(from: .newlines) == nil else { throw CredentialError.invalidKey }
        let key = value.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, key.utf8.count <= 4096,
              key.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { throw CredentialError.invalidKey }
        return key
    }

    func credential(for provider: AIUsageProvider) throws -> String? {
        guard provider.isAPIAccount else { return nil }
        lock.lock(); defer { lock.unlock() }
        var query = query(for: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialError.keychain(status) }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw CredentialError.invalidKey
        }
        return try Self.validated(key)
    }

    func save(_ value: String, for provider: AIUsageProvider) throws {
        guard provider.isAPIAccount, APIUsageSource.supportsDirectFetch(provider) else { throw CredentialError.unsupportedProvider }
        let key = try Self.validated(value)
        lock.lock(); defer { lock.unlock() }
        let query = query(for: provider)
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(key.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CredentialError.keychain(status) }
    }

    func remove(for provider: AIUsageProvider) throws {
        guard provider.isAPIAccount else { return }
        lock.lock(); defer { lock.unlock() }
        let status = SecItemDelete(query(for: provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError.keychain(status) }
    }

    var configuredProviders: [AIUsageProvider] {
        lock.lock(); defer { lock.unlock() }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecReturnAttributes as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String,
                  let provider = AIUsageProvider(rawValue: account), provider.isAPIAccount else { return nil }
            return provider
        }
    }

    private func query(for provider: AIUsageProvider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: provider.rawValue]
    }
}

extension AIUsageProvider {
    var isAPIAccount: Bool {
        switch self {
        case .codex, .claude, .grok: return false
        default: return true
        }
    }
}
