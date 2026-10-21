import Darwin
import Foundation
import MenuBarShim
import Security
import Testing
@testable import TidyBar

enum SyntheticCodeFixture {
    static func sign(_ file: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", "--identifier", "org.example.fixture", file.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}

@Suite struct SecurityHardeningTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hardening-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    @Test func defaultAdHocRequirementRejectsDifferentCodeWithTheSameIdentifier() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: first)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/false"), to: second)
        try SyntheticCodeFixture.sign(first); try SyntheticCodeFixture.sign(second)
        var code: SecStaticCode?, other: SecStaticCode?, requirement: SecRequirement?, text: CFString?
        #expect(SecStaticCodeCreateWithPath(first as CFURL, [], &code) == errSecSuccess)
        #expect(SecStaticCodeCreateWithPath(second as CFURL, [], &other) == errSecSuccess)
        let signed = try #require(code), different = try #require(other)
        #expect(SecCodeCopyDesignatedRequirement(signed, [], &requirement) == errSecSuccess)
        let rule = try #require(requirement)
        #expect(SecRequirementCopyString(rule, [], &text) == errSecSuccess)
        #expect((try #require(text) as String).contains("cdhash"))
        #expect(SecStaticCodeCheckValidity(signed, [], rule) == errSecSuccess)
        #expect(SecStaticCodeCheckValidity(different, [], rule) != errSecSuccess)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        #expect(!(try String(contentsOf: source.appendingPathComponent("build.sh"), encoding: .utf8)).contains("--requirements"))
    }

    private func setACL(_ file: URL, owner: Bool, permission: acl_perm_t, tag: acl_tag_t = ACL_EXTENDED_ALLOW) throws {
        var uuid = UUID().uuid
        #expect((owner ? mbr_uid_to_uuid(getuid(), &uuid) : mbr_gid_to_uuid(getgid(), &uuid)) == 0)
        var acl = acl_init(1)
        defer { if let acl { acl_free(UnsafeMutableRawPointer(acl)) } }
        var entry: acl_entry_t?, permissions: acl_permset_t?
        #expect(acl_create_entry(&acl, &entry) == 0)
        let ace = try #require(entry)
        #expect(acl_set_tag_type(ace, tag) == 0)
        #expect(acl_set_qualifier(ace, &uuid) == 0)
        #expect(acl_get_permset(ace, &permissions) == 0)
        let set = try #require(permissions)
        #expect(acl_add_perm(set, permission) == 0)
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        #expect(descriptor >= 0)
        defer { close(descriptor) }
        let value = try #require(acl)
        #expect(acl_set_fd(descriptor, value) == 0)
    }

    @Test func credentialsRejectNonOwnerReadAndWriteACLsDespiteMode0600() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("synthetic.json")
        try Data("{\"synthetic\":true}".utf8).write(to: file)
        #expect(chmod(file.path, 0o600) == 0)
        for permission in [ACL_READ_DATA, ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_WRITE_SECURITY, ACL_CHANGE_OWNER] {
            try setACL(file, owner: false, permission: permission)
            #expect(throws: (any Error).self) { try CredentialFiles.read(at: file, provider: "fixture") }
            #expect(throws: (any Error).self) { try CredentialFiles.restrictAfterRenewal(at: file) }
        }
        try setACL(file, owner: true, permission: ACL_READ_DATA)
        #expect(try CredentialFiles.read(at: file, provider: "fixture") != nil)
        try setACL(file, owner: false, permission: ACL_READ_ATTRIBUTES)
        #expect(try CredentialFiles.read(at: file, provider: "fixture") != nil)
        try setACL(file, owner: false, permission: ACL_WRITE_DATA, tag: ACL_EXTENDED_DENY)
        #expect(try CredentialFiles.read(at: file, provider: "fixture") != nil)
    }

    @Test func boundedReaderStopsAtLimitPlusOneEvenWhenTheStreamIsLonger() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("growing.json")
        try Data(repeating: 32, count: 100_000).write(to: file)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        #expect(throws: (any Error).self) { try BoundedFile.read(handle, maximum: 10_000) }
        #expect(try handle.offset() == 10_001)
        #expect(throws: (any Error).self) { try BoundedFile.read(file, maximum: 10_000) }
    }

    @MainActor @Test func exportedSettingsRemoveWiFiAndLocationWithoutChangingSavedSettings() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        let store = SettingsStore(url: file)
        var config = AppConfig()
        config.widgets.weatherCity = "Private City"
        config.widgets.weatherLatitude = 49.2827
        config.widgets.weatherLongitude = -123.1207
        config.widgets.weather = true
        let preset = LayoutPreset(name: "fixture", rules: [:], order: [], style: BarStyle())
        config.presets = [preset]
        config.triggers = [TriggerRule(name: "Private Network", kind: "wifi", value: "Private Network", presetID: preset.id)]
        store.config = config
        #expect(store.error == nil)
        #expect(SettingsStore(url: file).config == config)
        let bytes = try store.exportData()
        let text = String(decoding: bytes, as: UTF8.self)
        for secret in ["Private City", "Private Network", "49.2827", "-123.1207"] { #expect(!text.contains(secret)) }
        let exported = try JSONDecoder().decode(AppConfig.self, from: bytes)
        try exported.validate()
        #expect(exported.triggers.first?.enabled == false)
        #expect(store.config == config)
    }

    @Test func diagnosticsRedactStructuredAndTextLocations() throws {
        let object: [String: Any] = ["SSID": "Private Network", "weatherLatitude": 49.2827, "longitude": -123.1207,
            "nested": ["kind": "wifi", "value": "Private Network", "name": "Private Network"],
            "message": "SSID=\"Private Network\" coordinates=[49.2827, -123.1207]", "version": "1.2.0"]
        let data = try JSONSerialization.data(withJSONObject: DiagnosticsRedactor.value(object))
        let text = String(decoding: data, as: UTF8.self)
        for secret in ["Private Network", "49.2827", "-123.1207"] { #expect(!text.contains(secret)) }
        #expect(text.contains("1.2.0"))
    }

    @MainActor @Test func oversizedSettingsLoadPreservesTheFileAndReportsAnError() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        let bytes = Data(repeating: 32, count: 5_000_001)
        try bytes.write(to: file)
        #expect(SettingsStore(url: file).error != nil)
        #expect(try Data(contentsOf: file) == bytes)
    }
}
