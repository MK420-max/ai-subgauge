import Foundation
import Testing
@testable import TidyBar

extension TidyBarTests {
@Suite
@MainActor
final class GrokBuildConnectionTests {
    private func loginFixture() throws -> (folder: URL, executable: URL, authFile: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("grok-login-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let executable = folder.appendingPathComponent("grok"), authFile = folder.appendingPathComponent("auth.json")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try Data(#"{"fixture":"fake-login"}"#.utf8).write(to: authFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: authFile.path)
        return (folder, executable, authFile)
    }

    @Test
    func testSuccessfulLoginRestrictsCredentialPermissions() async throws {
        let fixture = try loginFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        #expect(try FileManager.default.attributesOfItem(atPath: fixture.authFile.path)[.posixPermissions] as? Int == 0o644)
        try await GrokBuildConnection().login(fixture.executable, verifyCLI: { _ in }, authFile: fixture.authFile)
        #expect(try FileManager.default.attributesOfItem(atPath: fixture.authFile.path)[.posixPermissions] as? Int == 0o600)
    }

    @Test
    func testLoginPermissionFailureHasUserFacingError() async throws {
        let fixture = try loginFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        var attempts = 0
        do {
            try await GrokBuildConnection().login(fixture.executable, verifyCLI: { _ in }, authFile: fixture.authFile, restrict: { file in
                attempts += 1
                #expect(file == fixture.authFile)
                throw CocoaError(.fileWriteNoPermission)
            })
            Issue.record("Login must fail when credential permissions cannot be secured")
        } catch AIUsageError.unavailable(let message) {
            #expect(message == L10n.text("error.grok.login.permissions.could.not.be.secured"))
            #expect(message.contains("600"))
        }
        #expect(attempts == 1)
    }

    @Test
    func testLoginDeadlineReplacesPreparationDeadline() async throws {
        let connection = GrokBuildConnection()
        connection.setDeadline(seconds: 0.001, message: "工具准备超时")
        connection.setDeadline(seconds: 0.01, message: "官方登录超时")
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(connection.status == "官方登录超时")
        #expect(!(connection.isConnecting))
    }

    @Test
    func testStopCancelsPendingStageDeadline() async throws {
        let connection = GrokBuildConnection()
        connection.setDeadline(seconds: 0.001, message: "不应触发的超时")
        connection.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(connection.status == "已取消连接。")
    }

    @Test
    func testOfficialVersionCreatesOnlyFixedArtifactPath() throws {
        #expect(try GrokBuildConnection.version("0.1.150\n") == "0.1.150")
        #expect(try GrokBuildConnection.artifactURL(version: "0.1.151-alpha.2").absoluteString == "https://x.ai/cli/grok-0.1.151-alpha.2-macos-aarch64")
        for value in ["../../evil", "0.1.2/other", "0.1.2?url=https://example.test", "0.1.2\nextra", "latest", "0.1.2;sh"] {
            #expect(throws: (any Error).self) { try GrokBuildConnection.artifactURL(version: value) }
        }
    }

    @Test
    func testDownloadRedirectTrustExcludesCredentialsPortsAndOtherHosts() {
        #expect(GrokBuildConnection.isOfficial(URL(string: "https://x.ai/cli/stable")!))
        #expect(GrokBuildConnection.isOfficial(URL(string: "https://x.ai:443/cli/file")!))
        for value in ["http://x.ai/cli/file", "https://x.ai.example.test/cli/file", "https://example.test/file",
                      "https://user:pass@x.ai/file", "https://x.ai:8443/file", "file:///tmp/grok"] {
            #expect(!(GrokBuildConnection.isOfficial(URL(string: value)!)))
        }
    }
}
}
