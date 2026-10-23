import Darwin
import Foundation
import Testing
@testable import TidyBar

private final class MockMigrationKeychain: MigrationKeychain {
    var items: [String: Data] = [:]
    var reads: [String] = []
    var fail = false
    func read(service: String, account: String) throws -> Data? {
        reads.append(service + "/" + account)
        if fail { throw Failure.unavailable }
        return items[service + "/" + account]
    }
    func copyIfAbsent(_ data: Data, service: String, account: String) throws {
        if fail { throw Failure.unavailable }
        let key = service + "/" + account
        if items[key] == nil { items[key] = data }
    }
    enum Failure: Error { case unavailable }
}

extension TidyBarTests {
@Suite
final class UnificationTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("subgauge-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test
    func migrationCopiesAllDefaultsOnceWithoutOverwritingAndKeepsAutosaveAliases() throws {
        let old = "test.old." + UUID().uuidString, new = "test.new." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: new))
        defer { defaults.removePersistentDomain(forName: old); defaults.removePersistentDomain(forName: new) }
        let legacyPosition = "NSStatusItem Preferred Position " + LegacyIdentifiers.bundleID + ".main"
        defaults.setPersistentDomain(["enabled": true, "array": [1, 2], "existing": "old", legacyPosition: 12], forName: old)
        defaults.set("new", forKey: "existing")
        let folder = try directory()
        let migration = AppMigration(defaults: defaults, oldDomain: old, newDomain: new,
            oldDirectory: folder.appendingPathComponent("old"), newDirectory: folder.appendingPathComponent("new"), keychain: MockMigrationKeychain())
        #expect(migration.run().isEmpty)
        #expect(defaults.bool(forKey: "enabled"))
        #expect(defaults.array(forKey: "array") as? [Int] == [1, 2])
        #expect(defaults.string(forKey: "existing") == "new")
        #expect(defaults.integer(forKey: legacyPosition) == 12)
        #expect(defaults.integer(forKey: LegacyIdentifiers.current(legacyPosition)) == 12)
        defaults.set(false, forKey: "enabled")
        #expect(migration.run().isEmpty)
        #expect(!defaults.bool(forKey: "enabled"))
        #expect(defaults.persistentDomain(forName: old)?["enabled"] as? Bool == true)
    }

    @Test
    func migrationMergesDirectoriesWithoutOverwritingOrRemovingOldFiles() throws {
        let domain = "test.migration." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let folder = try directory(), old = folder.appendingPathComponent("old"), new = folder.appendingPathComponent("new")
        try PrivateFiles.write(Data("old".utf8), to: old.appendingPathComponent("nested/existing"))
        try PrivateFiles.write(Data("new".utf8), to: new.appendingPathComponent("nested/existing"))
        try PrivateFiles.write(Data("copied".utf8), to: old.appendingPathComponent("nested/missing"))
        try FileManager.default.createSymbolicLink(at: old.appendingPathComponent("link"), withDestinationURL: new)
        let migration = AppMigration(defaults: defaults, oldDomain: "test.missing." + UUID().uuidString, newDomain: domain,
            oldDirectory: old, newDirectory: new, keychain: MockMigrationKeychain())
        #expect(migration.run().isEmpty)
        #expect(migration.run().isEmpty)
        #expect(try String(contentsOf: new.appendingPathComponent("nested/existing")) == "new")
        #expect(try String(contentsOf: new.appendingPathComponent("nested/missing")) == "copied")
        #expect(try String(contentsOf: old.appendingPathComponent("nested/existing")) == "old")
        #expect(!FileManager.default.fileExists(atPath: new.appendingPathComponent("link").path))
    }

    @Test
    func migrationCopiesOnlyKnownAPIKeysRetainsOldAndDoesNotOverwriteNew() throws {
        let domain = "test.keys." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let keys = MockMigrationKeychain(), folder = try directory()
        let old = LegacyIdentifiers.keychainService + "/", new = AppIdentifiers.keychainService + "/"
        keys.items = [old + "deepseekAPI": Data("old-key".utf8), old + "openaiAPI": Data("old-openai".utf8),
                      new + "openaiAPI": Data("new-openai".utf8), old + "unknown": Data("unknown".utf8)]
        let migration = AppMigration(defaults: defaults, oldDomain: "test.absent." + UUID().uuidString, newDomain: domain,
            oldDirectory: folder.appendingPathComponent("old"), newDirectory: folder.appendingPathComponent("new"), keychain: keys)
        #expect(migration.run().isEmpty)
        #expect(keys.items[new + "deepseekAPI"] == keys.items[old + "deepseekAPI"])
        #expect(keys.items[new + "openaiAPI"] == Data("new-openai".utf8))
        #expect(keys.items[old + "openaiAPI"] == Data("old-openai".utf8))
        #expect(keys.items[new + "unknown"] == nil)
        #expect(!keys.reads.contains { $0.hasSuffix("/unknown") || $0.hasSuffix("/codex") })
        let reads = keys.reads.count
        #expect(migration.run().isEmpty)
        #expect(keys.reads.count == reads)
    }

    @Test
    func migrationKeychainFailureDoesNotBlockOtherStagesAndCanRetry() throws {
        let domain = "test.retry." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let keys = MockMigrationKeychain(), folder = try directory()
        keys.fail = true
        let migration = AppMigration(defaults: defaults, oldDomain: "test.absent." + UUID().uuidString, newDomain: domain,
            oldDirectory: folder.appendingPathComponent("old"), newDirectory: folder.appendingPathComponent("new"), keychain: keys)
        #expect(migration.run().count == 1)
        #expect(defaults.bool(forKey: AppMigration.marker + "defaults"))
        #expect(defaults.bool(forKey: AppMigration.marker + "files"))
        #expect(!defaults.bool(forKey: AppMigration.marker + "keychain"))
        keys.fail = false
        #expect(migration.run().isEmpty)
        #expect(defaults.bool(forKey: AppMigration.marker + "keychain"))
    }

    @MainActor
    @Test
    func settingsReadLegacyIdentifiersAndPreferCurrentRulesWithoutRewriting() throws {
        let file = try directory().appendingPathComponent("settings.json")
        var config = AppConfig()
        config.rules = [LegacyIdentifiers.bundleID: ItemRule(zone: .hidden), AppIdentifiers.bundleID: ItemRule(zone: .visible)]
        config.order = [LegacyIdentifiers.bundleID + "::" + LegacyIdentifiers.bundleID + ".main"]
        let data = try JSONEncoder().encode(config)
        try PrivateFiles.write(data, to: file)
        let store = SettingsStore(url: file)
        #expect(store.error == nil)
        #expect(store.config.rules[AppIdentifiers.bundleID]?.zone == .visible)
        #expect(store.config.rules[LegacyIdentifiers.bundleID] == nil)
        #expect(store.config.order == [AppIdentifiers.bundleID + "::" + AppIdentifiers.bundleID + ".main"])
        #expect(try Data(contentsOf: file) == data)
    }

    @Test
    func credentialReadsRejectSharedModesWithActionableChineseHintForEveryProvider() throws {
        let file = try directory().appendingPathComponent("auth.json")
        try Data("{}".utf8).write(to: file)
        for provider in ["Claude", "Grok", "Codex"] {
            for mode in [0o640, 0o604, 0o644, 0o444, 0o664] {
                try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
                #expect(throws: (any Error).self) { try CredentialFiles.read(at: file, provider: provider) }.map {
                    #expect($0.localizedDescription.contains("请将该文件权限改为 600"))
                }
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            #expect(try CredentialFiles.read(at: file, provider: provider) == Data("{}".utf8))
        }
    }

    @Test
    func grokCredentialFileUsesTheSameSecureReaderAndRejectsSymlinks() throws {
        let folder = try directory(), file = folder.appendingPathComponent("auth.json")
        try PrivateFiles.write(Data("{}".utf8), to: file)
        #expect(try GrokBuildUsageSource.readCredential(at: file) == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(throws: (any Error).self) { try GrokBuildUsageSource.readCredential(at: file) }.map {
            #expect($0.localizedDescription.contains("请将该文件权限改为 600"))
        }
        let link = folder.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: (any Error).self) { try GrokBuildUsageSource.readCredential(at: link) }
    }

    @Test
    func loginConsentIsIndependentPersistentAndDenialNeverCallsReader() throws {
        let domain = "test.consent." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let consent = ProviderLoginConsent(defaults: defaults)
        var reads = 0
        for provider in ProviderLoginConsent.providers {
            #expect(!consent.allows(provider))
            #expect(throws: (any Error).self) { try consent.withAccess(to: provider) { reads += 1 } }
        }
        #expect(reads == 0)
        consent.setAllowed(true, for: .claude)
        #expect(ProviderLoginConsent(defaults: defaults).allows(.claude))
        #expect(!consent.allows(.codex))
        #expect(!consent.allows(.grok))
        try consent.withAccess(to: .claude) { reads += 1 }
        #expect(reads == 1)
        consent.setAllowed(false, for: .claude)
        #expect(throws: (any Error).self) { try consent.withAccess(to: .claude) { reads += 1 } }
        #expect(reads == 1)
    }

    @Test
    func diagnosticsRedactSecretsEmailPathsAndHostname() throws {
        let text = "Bearer synthetic-bearer access_token=synthetic-access refresh_token: synthetic-refresh api_key=synthetic-key sk-test-key person@example.test /Users/Example/Library/auth example-mac.local eyJtest.payload.signature"
        let redacted = DiagnosticsRedactor.text(text, home: "/Users/Example", hostname: "example-mac.local")
        for secret in ["synthetic-bearer", "synthetic-access", "synthetic-refresh", "synthetic-key", "sk-test-key", "person@example.test", "/Users/Example", "example-mac", "eyJtest"] {
            #expect(!redacted.contains(secret))
        }
        #expect(redacted.contains("~/Library/auth"))
        let nested = DiagnosticsRedactor.value(["accessToken": "opaque", "nested": [["apiKey": "opaque2", "safe": "/Users/Someone/file"]]]) as? [String: Any]
        #expect(nested?["accessToken"] as? String == "[redacted]")
        #expect((nested?["nested"] as? [[String: Any]])?.first?["apiKey"] as? String == "[redacted]")
    }

    @MainActor
    @Test
    func diagnosticsIncludeOnlyVersionOSAndFixedProviderStates() throws {
        let snapshot = AIUsageSnapshot(provider: .grok, plan: "private-plan", balance: "private-balance",
            status: "private-status", source: "private-source", error: "private-token")
        let data = try DiagnosticsReport.data(snapshots: [snapshot])
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("private-"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["app", "version", "os", "providers"])
        #expect(object["version"] as? String == "2.0.0")
        #expect((object["providers"] as? [[String: String]])?.first?["state"] == "error")
    }

    @MainActor
    @Test
    func unsafeCredentialErrorsStayVisibleBeforeTheFirstSuccessfulRead() async throws {
        let store = AIUsageStore(fetcher: { _ in throw AIUsageError.unsafeCredential("请将该文件权限改为 600") })
        store.refresh(provider: .claude)
        let deadline = Date().addingTimeInterval(2)
        while store.isRefreshing, Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(store.visibleSnapshots.first?.provider == .claude)
        #expect(store.visibleSnapshots.first?.error == "请将该文件权限改为 600")
        store.stop()
    }

    @MainActor
    @Test
    func rejectedGrokSignatureNeverLaunchesTheCLI() async throws {
        var verified = false
        #expect(throws: (any Error).self) { try GrokCLITrust.verify(URL(fileURLWithPath: "/tmp/untrusted-grok")) }
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("grok-reject-" + UUID().uuidString)
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: fixture)
        defer { try? FileManager.default.removeItem(at: fixture) }
        do {
            try await GrokBuildConnection().login(fixture, verifyCLI: { _ in
                verified = true
                throw AIUsageError.unavailable("Grok CLI 官方签名或开发者团队校验失败")
            })
            Issue.record("Must reject an unverified executable")
        } catch { #expect(error.localizedDescription.contains("校验失败")) }
        #expect(verified)
        #expect(GrokCLITrust.requirement.contains("anchor apple generic"))
        #expect(GrokCLITrust.requirement.contains(GrokCLITrust.teamID))
        #expect(!GrokCLITrust.allowedPath(URL(fileURLWithPath: "/tmp/grok")))
    }

    @Test func developmentPreviewEntryAndRendererAreDebugOnly() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = root.appendingPathComponent("Sources/TidyBar")
        let app = try String(contentsOf: source.appendingPathComponent("App.swift"), encoding: .utf8)
        let entry = try #require(app.range(of: "if let directory = try PreviewRenderer.directory"))
        let guardStart = try #require(app.range(of: "#if DEBUG"))
        let guardEnd = try #require(app.range(of: "#endif", range: guardStart.upperBound..<app.endIndex))
        #expect(guardStart.upperBound < entry.lowerBound && entry.upperBound < guardEnd.lowerBound)
        let renderer = try String(contentsOf: source.appendingPathComponent("PreviewRenderer.swift"), encoding: .utf8)
        #expect(renderer.hasPrefix("#if DEBUG\n"))
        #expect(renderer.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("#endif"))
    }

    #if DEBUG
    @MainActor
    @Test
    func previewArgumentsAndDemoSnapshotsAreOfflineAndDeterministic() throws {
        #expect(try PreviewRenderer.directory(arguments: ["AISubGauge"]) == nil)
        #expect(throws: (any Error).self) { try PreviewRenderer.directory(arguments: ["AISubGauge", "--render-preview"]) }
        #expect(try PreviewRenderer.directory(arguments: ["AISubGauge", "--render-preview", "/tmp/demo"])?.path == "/tmp/demo")
        #expect(PreviewRenderer.snapshots.compactMap { $0.windows.first?.remainingPercent } == [72, 45, 88])
        #expect(PreviewRenderer.snapshots.count == 3)
    }
    #endif
}
}
