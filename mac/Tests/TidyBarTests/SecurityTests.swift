import Darwin
import Foundation
import Testing
@testable import TidyBar

extension TidyBarTests {
@Suite
final class SecurityTests {
    private let runtime = ["HOME": "/example/home", "PATH": "/usr/bin:/bin", "USER": "example",
                           "LOGNAME": "example", "LANG": "en_US.UTF-8", "LC_ALL": "C", "LC_CTYPE": "UTF-8", "TMPDIR": "/example/tmp"]
    private var untrustedEnvironment: [String: String] {
        runtime.merging(["OPENAI_API_KEY": "synthetic", "ANTHROPIC_API_KEY": "synthetic",
                         "CLAUDE_CODE_OAUTH_TOKEN": "synthetic", "AWS_SECRET_ACCESS_KEY": "synthetic",
                         "XAI_API_KEY": "synthetic", "GROK_AUTH": "synthetic", "GROK_API_KEY": "synthetic",
                         "GROK_AUTH_PROVIDER_COMMAND": "synthetic", "GROK_OAUTH2_ISSUER": "https://invalid.example",
                         "GROK_TELEMETRY_ENABLED": "1", "OTEL_EXPORTER_OTLP_HEADERS": "synthetic",
                         "SENTRY_DSN": "synthetic", "DYLD_INSERT_LIBRARIES": "synthetic",
                         "GROK_HOME": "/example/grok", "GROK_AUTH_PATH": "/example/grok/auth.json",
                         "CODEX_HOME": "/example/codex"]) { _, new in new }
    }

    @Test
    func testMinimalCLIEnvironmentDropsUnrelatedSecretsTelemetryAndInjection() {
        #expect(CLIEnvironment.minimal(from: untrustedEnvironment) == runtime)
        #expect(CLIEnvironment.minimal(from: [:]).isEmpty)
    }

    @Test
    func testCodexKeepsOnlyRuntimeAndItsLocalStoreOverride() {
        #expect(CLIEnvironment.codex(from: untrustedEnvironment) == runtime.merging([
            "CODEX_HOME": "/example/codex", "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        ]) { _, new in new })
        #expect(CLIEnvironment.codex(from: ["PATH": "/tmp/untrusted"]) == ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"])
    }

    @Test
    func testGrokKeepsStoreLocationsAndForcesOfficialIssuerAndDisabledTelemetry() {
        let environment = CLIEnvironment.grok(from: untrustedEnvironment)
        for (key, value) in runtime { #expect(environment[key] == value) }
        #expect(environment["GROK_HOME"] == "/example/grok")
        #expect(environment["GROK_AUTH_PATH"] == "/example/grok/auth.json")
        #expect(environment["GROK_OAUTH2_ISSUER"] == "https://auth.x.ai")
        #expect(environment["GROK_TELEMETRY_ENABLED"] == "0")
        #expect(environment["GROK_EXTERNAL_OTEL"] == "0")
        #expect(environment["GROK_LOG_FILE"] == "/dev/null")
        #expect(environment["RUST_LOG"] == "off")
        let extraKeys = Set(environment.keys).subtracting(runtime.keys)
        #expect(extraKeys == ["GROK_HOME", "GROK_AUTH_PATH", "GROK_OAUTH2_ISSUER", "GROK_TELEMETRY_ENABLED", "GROK_EXTERNAL_OTEL", "GROK_LOG_FILE", "RUST_LOG"])
    }

    @Test
    func testClaudeSessionHasNoPersistentCookiesCacheOrCredentials() {
        let configuration = ClaudeUsageSource.sessionConfiguration()
        #expect(!(configuration.httpShouldSetCookies))
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCache == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test
    func testOAuthRequestAndSuccessfulUsageStayOnTheOfficialEndpoint() async throws {
        let snapshot = try await ClaudeUsageSource.fetch(token: "synthetic-oauth") { request in
            #expect(request.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-oauth")
            #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"five_hour":{"utilization":25}}"#.utf8), response)
        }
        #expect(snapshot.windows.first?.remainingPercent == 75)
    }

    @Test
    func testOAuthRejectsChangedHostSchemePortAndPath() async throws {
        for address in ["https://invalid.example/api/oauth/usage", "https://api.anthropic.com.invalid.example/api/oauth/usage",
                        "http://api.anthropic.com/api/oauth/usage", "https://api.anthropic.com:444/api/oauth/usage",
                        "https://api.anthropic.com/other"] {
            do {
                _ = try await ClaudeUsageSource.fetch(token: "synthetic-oauth") { _ in
                    (Data(#"{"five_hour":{"utilization":25}}"#.utf8), HTTPURLResponse(url: URL(string: address)!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
                Issue.record("A changed response URL must be rejected")
            } catch { #expect(error is AIUsageError) }
        }
    }

    @Test
    func testOAuthRejectsAuthFailuresAndRedirectStatusWithoutEchoingPayload() async throws {
        for status in [302, 401, 403, 500] {
            do {
                _ = try await ClaudeUsageSource.fetch(token: "synthetic-oauth") { request in
                    (Data("synthetic-private-response".utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
                }
                Issue.record("An unsuccessful response must be rejected")
            } catch {
                #expect(!(error.localizedDescription.contains("synthetic-oauth")))
                #expect(!(error.localizedDescription.contains("synthetic-private-response")))
            }
        }
    }

    @Test
    func testRedirectDelegateRejectsSameHostAndCrossHostRedirects() {
        let session = URLSession(configuration: ClaudeUsageSource.sessionConfiguration())
        defer { session.invalidateAndCancel() }
        let original = URL(string: "https://api.anthropic.com/api/oauth/usage")!
        let task = session.dataTask(with: original) // Never resumed; this test performs no network I/O.
        let response = HTTPURLResponse(url: original, statusCode: 302, httpVersion: nil, headerFields: nil)!
        for target in [original, URL(string: "https://invalid.example/")!] {
            var called = false
            NoUsageRedirects().urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: target)) { request in
                called = true
                #expect(request == nil)
            }
            #expect(called)
        }
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tidy-security-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func credential(in directory: URL, mode: Int = 0o600) throws -> URL {
        let url = directory.appendingPathComponent(".credentials.json")
        try Data(#"{"claudeAiOauth":{"accessToken":"synthetic-oauth"}}"#.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        return url
    }

    private func environmentCLI(in directory: URL) throws -> URL {
        let cli = directory.appendingPathComponent("fixture-cli")
        try "#!/bin/sh\n/usr/bin/env > \"\(cli.path).environment\"\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        return cli
    }

    private func capturedEnvironment(_ cli: URL) throws -> [String: String] {
        let text = try String(contentsOfFile: cli.path + ".environment", encoding: .utf8)
        return Dictionary(uniqueKeysWithValues: text.split(separator: "\n").compactMap { line in
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return nil }
            return (String(pair[0]), String(pair[1]))
        })
    }

    @Test
    func testCodexChildReceivesOnlyItsAllowedEnvironment() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cli = try environmentCLI(in: directory)
        #expect(throws: (any Error).self) { try CodexUsageSource.readFromCLI(executable: cli, timeout: 2) }
        var actual = try capturedEnvironment(cli)
        for key in ["PWD", "SHLVL", "_"] { actual[key] = nil } // Added by the fixture's shell.
        #expect(actual == CLIEnvironment.codex())
    }

    @MainActor
    @Test
    func testGrokLoginChildUsesTheSameSanitizedPolicyAsRenewal() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cli = try environmentCLI(in: directory)
        try await GrokBuildConnection().login(cli, verifyCLI: { _ in })
        var actual = try capturedEnvironment(cli)
        for key in ["PWD", "SHLVL", "_"] { actual[key] = nil }
        #expect(actual == CLIEnvironment.grok())
    }

    @Test
    func testClaudeReadsOwnedRegularCredentialFile() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        for mode in [0o600, 0o400] {
            #expect(try ClaudeUsageSource.token(at: credential(in: directory, mode: mode)) == "synthetic-oauth")
        }
    }

    @Test
    func testClaudeRejectsGroupOrOtherWritableCredentials() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        for mode in [0o620, 0o602, 0o666] {
            #expect(throws: (any Error).self) { try ClaudeUsageSource.token(at: credential(in: directory, mode: mode)) }
        }
    }

    @Test
    func testClaudeRejectsSymlinkAndDirectoryCredentials() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try credential(in: directory)
        let link = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: (any Error).self) { try ClaudeUsageSource.token(at: link) }
        #expect(throws: (any Error).self) { try ClaudeUsageSource.token(at: directory) }
    }

    @Test
    func testClaudeRejectsOversizedAndMalformedCredentials() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try credential(in: directory)
        try Data(repeating: 32, count: 1_048_577).write(to: file)
        #expect(throws: (any Error).self) { try ClaudeUsageSource.token(at: file) }
        try Data("invalid-json".utf8).write(to: file)
        #expect(try ClaudeUsageSource.token(at: file) == nil)
    }

    @Test
    func testClaudeMetadataRejectsForeignOwnerAndSpecialFile() throws {
        var metadata = stat()
        metadata.st_mode = S_IFREG | 0o600
        metadata.st_uid = getuid()
        metadata.st_size = 1_048_576
        #expect(throws: Never.self) { try ClaudeUsageSource.validateCredentialFile(metadata) }
        metadata.st_uid = getuid() &+ 1
        #expect(throws: (any Error).self) { try ClaudeUsageSource.validateCredentialFile(metadata) }
        metadata.st_uid = getuid()
        metadata.st_mode = S_IFIFO | 0o600
        #expect(throws: (any Error).self) { try ClaudeUsageSource.validateCredentialFile(metadata) }
    }

    private func mode(_ url: URL) throws -> Int {
        try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue & 0o777
    }

    @Test
    func testPrivateWriteCreatesOwnerOnlyDirectoryAndFile() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("private/nested/diagnostics.json")
        let data = Data("synthetic-diagnostic".utf8)
        try PrivateFiles.write(data, to: file)
        #expect(try Data(contentsOf: file) == data)
        #expect(try mode(file) == 0o600)
        #expect(try mode(file.deletingLastPathComponent()) == 0o700)
        #expect(try mode(directory.appendingPathComponent("private")) == 0o700)
    }

    @Test
    func testPrivateWriteTightensExistingPermissionsAndReplacesContents() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("diagnostics.json")
        try Data("old".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        try PrivateFiles.write(Data("new".utf8), to: file)
        #expect(try mode(directory) == 0o700)
        #expect(try mode(file) == 0o600)
        #expect(try String(contentsOf: file, encoding: .utf8) == "new")
    }

    @Test
    func testExportRestrictsFileWithoutChangingTheChosenPublicDirectory() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        let file = directory.appendingPathComponent("export.json")
        try PrivateFiles.write(Data("export".utf8), to: file, privateDirectory: false)
        #expect(try mode(file) == 0o600)
        #expect(try mode(directory) == 0o755)
    }

    @Test
    func testFailedAtomicWritePreservesDestinationAndLeavesNoStagingFile() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("existing-directory")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try PrivateFiles.write(Data("new".utf8), to: destination) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["existing-directory"])
    }

    @MainActor
    @Test
    func testSettingsPersistenceUsesPrivatePermissions() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        let store = SettingsStore(url: file)
        store.save()
        #expect(store.error == nil)
        #expect(try mode(directory) == 0o700)
        #expect(try mode(file) == 0o600)
    }

    @MainActor
    @Test
    func testPositionAccessErrorRedactsHomeButKeepsErrorCodeAndDomain() {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/example.plist").path
        let error = NSError(domain: "synthetic-domain", code: 42, userInfo: [NSLocalizedDescriptionKey: "Cannot read " + path])
        let diagnostic = MenuEngine.errorDiagnostic(error)
        #expect(diagnostic["description"] as? String == "Cannot read ~/Library/example.plist")
        #expect(diagnostic["domain"] as? String == "synthetic-domain")
        #expect(diagnostic["code"] as? Int == 42)
    }

    @MainActor
    @Test
    func testGeneralDiagnosticsRedactHomeInTopLevelAndNestedErrors() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let output: [String: Any] = [
            "lastError": "Cannot read \(home)/Library/settings.json",
            "status": "Failed at \(home)/one and \(home)/two",
            "aiUsage": [["error": "Cannot open \(home)/.claude/.credentials.json", "connected": false]],
            "widgets": ["error": "Cannot read \(home)/Library/calendar"],
            "wifi": ["error": "Failed at \(home)/Library/wifi"],
            "code": 42, "empty": NSNull(), "version": "1.1.1"
        ]
        let data = try AppDelegate.diagnosticsData(output)
        let diagnostic = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(diagnostic["lastError"] as? String == "Cannot read ~/Library/settings.json")
        #expect(diagnostic["status"] as? String == "Failed at ~/one and ~/two")
        #expect((diagnostic["aiUsage"] as? [[String: Any]])?.first?["error"] as? String == "Cannot open ~/.claude/.credentials.json")
        #expect((diagnostic["aiUsage"] as? [[String: Any]])?.first?["connected"] as? Bool == false)
        #expect((diagnostic["widgets"] as? [String: Any])?["error"] as? String == "Cannot read ~/Library/calendar")
        #expect((diagnostic["wifi"] as? [String: Any])?["error"] as? String == "Failed at ~/Library/wifi")
        #expect(diagnostic["code"] as? Int == 42)
        #expect(diagnostic["empty"] is NSNull)
        #expect(diagnostic["version"] as? String == "1.1.1")
    }

    @MainActor
    @Test
    func testLoadingExistingSettingsTightensPermissionsWithoutRewriting() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        var config = AppConfig()
        config.showLabels = false
        let data = try JSONEncoder().encode(config)
        try data.write(to: file)
        let modified = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        for permissions in [0o644, 0o666, 0o700] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path)
            let store = SettingsStore(url: file)
            #expect(store.error == nil)
            #expect(store.config == config)
            #expect(try mode(file) == 0o600)
            #expect(try mode(directory) == 0o700)
            #expect(try Data(contentsOf: file) == data)
            #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date == modified)
        }
    }

    @MainActor
    @Test
    func testLoadingSettingsDoesNotWidenAlreadyRestrictedFile() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        let config = AppConfig()
        try JSONEncoder().encode(config).write(to: file)
        for permissions in [0o600, 0o400] {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path)
            let store = SettingsStore(url: file)
            #expect(store.error == nil)
            #expect(store.config == config)
            #expect(try mode(file) == permissions)
        }
    }

    @MainActor
    @Test
    func testDamagedSettingsAreRestrictedAndPreservedOnLoad() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        let damaged = Data("invalid-json".utf8)
        try damaged.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: file.path)
        let store = SettingsStore(url: file)
        #expect(store.error != nil)
        #expect(store.config == AppConfig())
        #expect(try mode(file) == 0o600)
        #expect(try mode(directory) == 0o700)
        #expect(try Data(contentsOf: file) == damaged)
    }

    @Test
    func testMissingClaudeFileUsesTheSignInHint() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("missing.json")
        #expect(try ClaudeUsageSource.token(at: file) == nil)
        #expect(throws: (any Error).self) { try ClaudeUsageSource.existingToken(environment: [:], file: file) }.map {
            #expect($0.localizedDescription == "尚未连接 Claude Code 账户，请先登录后再刷新。")
        }
    }

    @Test
    func testExistingUnsafeClaudeFileKeepsTheSpecificError() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        for permissions in [0o620, 0o602, 0o666] {
            let file = try credential(in: directory, mode: permissions)
            #expect(throws: (any Error).self) { try ClaudeUsageSource.existingToken(environment: [:], file: file) }.map {
                #expect($0.localizedDescription.contains("不安全") || $0.localizedDescription.contains("请将该文件权限改为 600"))
            }
        }
        // O_NOFOLLOW must also reject a dangling symlink instead of treating it as missing.
        let link = directory.appendingPathComponent("dangling.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory.appendingPathComponent("missing.json"))
        #expect(throws: (any Error).self) { try ClaudeUsageSource.existingToken(environment: [:], file: link) }.map {
            #expect($0.localizedDescription == "无法安全读取 Claude 登录文件，请在官方 CLI 重新登录。")
        }
    }

    @Test
    func testClaudeTokenLookupRejectsSharedPermissionsAndKeepsEnvironmentPriority() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try credential(in: directory, mode: 0o644)
        #expect(throws: (any Error).self) { try ClaudeUsageSource.existingToken(environment: [:], file: file) }
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: file.path)
        #expect(try ClaudeUsageSource.existingToken(environment: ["CLAUDE_CODE_OAUTH_TOKEN": "synthetic-env"], file: file) == "synthetic-env")
    }
}
}
