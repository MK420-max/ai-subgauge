import AppKit
import Darwin
import Foundation
import Testing
@testable import TidyBar

extension TidyBarTests {
    private func reviewFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("security-review-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return folder
    }

    @Test func codexTrustAcceptsOnlyFixedEntrypointsAndKnownResolvedInstallations() {
        let brew = URL(fileURLWithPath: "/opt/homebrew/bin/codex")
        for path in ["/opt/homebrew/Cellar/codex/1.0/bin/codex", "/opt/homebrew/Caskroom/codex/1.0/bin/codex"] {
            #expect(CodexCLITrust.allowedPath(brew, resolved: URL(fileURLWithPath: path)))
        }
        let local = URL(fileURLWithPath: "/usr/local/bin/codex")
        #expect(!CodexCLITrust.allowedPath(local, resolved: URL(fileURLWithPath: "/usr/local/lib/node_modules/@openai/codex/bin/codex.js")))
        let app = URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex")
        #expect(CodexCLITrust.allowedPath(app, resolved: app))
        for path in ["/tmp/codex", "/opt/homebrew/bin/codex", "/opt/homebrew/Caskroom/codex-evil/1/bin/codex",
                     "/opt/homebrew/lib/node_modules/@openai/codex-evil/bin/codex.js", "/usr/local/Caskroom/codex/1/bin/codex",
                     "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js"] {
            #expect(!CodexCLITrust.allowedPath(brew, resolved: URL(fileURLWithPath: path)))
        }
        for path in ["/tmp/codex", "/Users/example/bin/codex", "/opt/homebrew/Cellar/codex/1/bin/codex"] {
            #expect(!CodexCLITrust.allowedPath(URL(fileURLWithPath: path), resolved: app))
        }
        #expect(!CodexCLITrust.allowedPath(app, resolved: URL(fileURLWithPath: "/tmp/codex")))
        #expect(CodexCLITrust.candidates.count == 4) // No PATH-derived candidate.
    }

    @Test func codexTrustRequiresDeveloperIDAndRejectsUnsignedAndOtherTeams() throws {
        #expect(CodexCLITrust.requirement.contains("anchor apple generic"))
        #expect(CodexCLITrust.requirement.contains("1.2.840.113635.100.6.1.13"))
        #expect(CodexCLITrust.requirement.contains("2DC432GLL2"))
        #expect(throws: (any Error).self) { try CodexCLITrust.verifySignature(URL(fileURLWithPath: "/usr/bin/true")) }
        let folder = try reviewFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("codex")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
        #expect(throws: (any Error).self) { try CodexCLITrust.verifySignature(file) }
        var checked = false
        #expect(throws: (any Error).self) { try CodexCLITrust.prepare(file, verifyCLI: { _ in checked = true }) }.map {
            #expect($0.localizedDescription == L10n.text("usage.codex.was.not.found.install.and.sign"))
        }
        #expect(!checked)
        #expect(CodexCLITrust.isMachO(Data([0xcf, 0xfa, 0xed, 0xfe])))
        #expect(CodexCLITrust.isMachO(Data([0xca, 0xfe, 0xba, 0xbe])))
        #expect(!CodexCLITrust.isMachO(Data("#!/b".utf8)))
    }

    @Test func codexMachORequiresTrustedOwnerAndUnsharedPermissions() {
        var metadata = stat()
        metadata.st_uid = getuid(); metadata.st_mode = S_IFREG | 0o755
        #expect(CodexCLITrust.validMetadata(metadata))
        for mode in [0o775, 0o757, 0o777] as [mode_t] {
            metadata.st_mode = S_IFREG | mode
            #expect(!CodexCLITrust.validMetadata(metadata))
        }
        metadata.st_mode = S_IFREG | 0o755; metadata.st_uid = getuid() + 1
        #expect(!CodexCLITrust.validMetadata(metadata))
        metadata.st_uid = 0
        #expect(CodexCLITrust.validMetadata(metadata))
        metadata.st_mode = S_IFDIR | 0o755
        #expect(!CodexCLITrust.validMetadata(metadata))
    }

    @Test func codexExecutesVerifiedPrivateMachOCopyAfterSourceReplacement() throws {
        let folder = try reviewFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("original"), cli = folder.appendingPathComponent("codex")
        try Data(contentsOf: URL(fileURLWithPath: "/usr/bin/true")).write(to: source)
        try SyntheticCodeFixture.sign(source)
        let trusted = try Data(contentsOf: source)
        try FileManager.default.createSymbolicLink(at: cli, withDestinationURL: source)
        let prepared = try CodexCLITrust.prepare(cli, verifyCLI: { snapshot in
            #expect(snapshot != source && snapshot != cli)
            #expect(try Data(contentsOf: snapshot) == trusted)
            let attributes = try FileManager.default.attributesOfItem(atPath: snapshot.deletingLastPathComponent().path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o500)
            #expect((attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid())
            try FileManager.default.moveItem(at: source, to: folder.appendingPathComponent("saved-original"))
            try Data("#!/bin/sh\nexit 42\n".utf8).write(to: source)
        })
        defer { prepared.cleanup() }
        let process = try CLIProcess(executable: prepared.executable, arguments: [], environment: CLIEnvironment.codex(), directory: prepared.directory,
            beforeSpawn: prepared.validateBeforeSpawn, verifySpawned: prepared.validateSpawned)
        defer { process.abandonBestEffort() }
        let deadline = Date().addingTimeInterval(3)
        while try process.isRunning && Date() < deadline { usleep(5_000) }
        #expect(try !process.isRunning && process.succeeded)
        prepared.cleanup()
        #expect(!FileManager.default.fileExists(atPath: prepared.directory.path))
    }

    @Test func codexFailedCopySignatureIsRejectedAndCleaned() throws {
        let folder = try reviewFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("codex")
        // A signed Mach-O from a different publisher must not pass the OpenAI requirement.
        try Data(contentsOf: URL(fileURLWithPath: "/usr/bin/true")).write(to: source)
        var copy: URL?
        #expect(throws: (any Error).self) {
            try CodexCLITrust.prepare(source, verifyCLI: { snapshot in copy = snapshot; try CodexCLITrust.verifySignature(snapshot) })
        }
        #expect(!FileManager.default.fileExists(atPath: try #require(copy).deletingLastPathComponent().path))
        try Data(contentsOf: URL(fileURLWithPath: "/usr/bin/true")).write(to: source)
        #expect(throws: (any Error).self) { try CodexCLITrust.prepare(source, verifyCLI: CodexCLITrust.verifySignature) }
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: source.path)
        var verified = false
        #expect(throws: (any Error).self) { try CodexCLITrust.prepare(source, verifyCLI: { _ in verified = true }) }
        #expect(!verified)
    }

    @MainActor @Test func grokLaunchesTheVerifiedPrivateCopyEvenWhenTheSourceIsReplaced() async throws {
        let folder = try reviewFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("original"), cli = folder.appendingPathComponent("grok")
        let marker = folder.appendingPathComponent("marker")
        let trusted = "#!/bin/sh\nprintf trusted > '\(marker.path)'\n"
        try Data(trusted.utf8).write(to: source)
        try FileManager.default.createSymbolicLink(at: cli, withDestinationURL: source)
        var copy: URL?
        try await GrokBuildConnection().login(cli, verifyCLI: { snapshot in
            copy = snapshot
            #expect(snapshot != source && snapshot != cli)
            #expect(try String(contentsOf: snapshot, encoding: .utf8) == trusted)
            let attributes = try FileManager.default.attributesOfItem(atPath: snapshot.deletingLastPathComponent().path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
            #expect((attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid())
            try FileManager.default.moveItem(at: source, to: folder.appendingPathComponent("saved-original"))
            try Data("#!/bin/sh\nprintf replaced > '\(marker.path)'\n".utf8).write(to: source)
        })
        #expect(try String(contentsOf: marker, encoding: .utf8) == "trusted")
        #expect(!FileManager.default.fileExists(atPath: try #require(copy).deletingLastPathComponent().path))
    }

    @Test func grokFailedCopySignatureIsRejectedAndCleaned() throws {
        let folder = try reviewFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("grok")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: source)
        var copy: URL?
        #expect(throws: (any Error).self) {
            try GrokCLITrust.prepare(source, verifyCLI: { snapshot in copy = snapshot; try GrokCLITrust.verifySignature(snapshot) })
        }
        #expect(!FileManager.default.fileExists(atPath: try #require(copy).deletingLastPathComponent().path))
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: source.path)
        var verified = false
        #expect(throws: (any Error).self) { try GrokCLITrust.prepare(source, verifyCLI: { _ in verified = true }) }
        #expect(!verified)
    }

    @MainActor @Test func grokLoginCancellationAndDeadlineTerminateTheWholeProcessGroup() async throws {
        let folder = try reviewFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for timedOut in [false, true] {
            let cli = folder.appendingPathComponent("cli-\(timedOut)"), pids = folder.appendingPathComponent("pids-\(timedOut)")
            try Data(("#!/bin/sh\n" + ProcessTreeFixture.script(pids: pids)).utf8).write(to: cli)
            let connection = GrokBuildConnection()
            var leader: pid_t = 0
            let login = Task { try await connection.login(cli, onLaunch: { leader = $0 }, verifyCLI: { _ in }) }
            defer { login.cancel(); connection.cancel() }
            let descendants = try await ProcessTreeFixture.pids(at: pids)
            #expect(leader > 0 && getpgid(leader) == leader)
            for child in descendants { #expect(getpgid(child) == leader) }
            if timedOut { connection.setDeadline(seconds: 0.01, message: "deadline") }
            else { login.cancel() }
            do { try await login.value; Issue.record("Login must not succeed") }
            catch { if !timedOut { #expect(error is CancellationError) } }
            if timedOut { #expect(connection.status == "deadline") }
            try await ProcessTreeFixture.expectExited([leader] + descendants)
        }
    }

    @Test func renewedCredentialPermissionsRejectLinksSpecialFilesAndForeignOwners() throws {
        let folder = try reviewFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("auth.json"), link = folder.appendingPathComponent("link")
        try Data("synthetic".utf8).write(to: file)
        for mode in [0o644, 0o666, 0o400] {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
            try CredentialFiles.restrictAfterRenewal(at: file)
            #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: (any Error).self) { try CredentialFiles.restrictAfterRenewal(at: link) }
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o644)
        #expect(throws: (any Error).self) { try CredentialFiles.restrictAfterRenewal(at: folder) }
        let fifo = folder.appendingPathComponent("fifo")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: (any Error).self) { try CredentialFiles.restrictAfterRenewal(at: fifo) }
        var foreign = stat(); foreign.st_mode = S_IFREG | 0o600; foreign.st_uid = getuid() + 1
        #expect(throws: (any Error).self) { try CredentialFiles.validateRenewedMetadata(foreign) }
    }

    @Test func diagnosticsRefuseExistingFilesCredentialDirectoriesAndLinksIntoThem() throws {
        let folder = try reviewFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let data = Data("diagnostics".utf8), output = folder.appendingPathComponent("export.json")
        try DiagnosticsReport.write(data, to: output, home: folder, environment: [:])
        #expect(try Data(contentsOf: output) == data)
        #expect((try FileManager.default.attributesOfItem(atPath: output.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(throws: (any Error).self) { try DiagnosticsReport.write(Data("overwrite".utf8), to: output, home: folder, environment: [:]) }
        #expect(try Data(contentsOf: output) == data)
        for name in [".codex", ".claude", ".grok", ".gemini", ".kimi-code", ".config/github-copilot", "Library/Keychains", "configured"] {
            let directory = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            #expect(throws: (any Error).self) {
                try DiagnosticsReport.write(data, to: directory.appendingPathComponent("new.json"), home: folder,
                    environment: ["CODEX_HOME": folder.appendingPathComponent("configured").path])
            }
        }
        let link = folder.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder.appendingPathComponent(".codex"))
        #expect(throws: (any Error).self) { try DiagnosticsReport.write(data, to: link.appendingPathComponent("new.json"), home: folder, environment: [:]) }
        let dangling = folder.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: folder.appendingPathComponent("new.json"))
        #expect(throws: (any Error).self) { try DiagnosticsReport.write(data, to: dangling, home: folder, environment: [:]) }
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("new.json").path))
    }

    @Test func resourceReadersEnforceOneMiBAndThemeFallsBackOnInvalidContents() throws {
        let folder = try reviewFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("resource.json"), missing = folder.appendingPathComponent("missing")
        var bytes = Data("{\"codex\":[\"custom\"]}".utf8)
        bytes.append(Data(repeating: 32, count: BoundedFile.maximum - bytes.count))
        try bytes.write(to: file)
        #expect(try BoundedFile.read(file).count == BoundedFile.maximum)
        #expect(RunningProcessMap(overrideURL: file).names == ["codex": ["custom"]])
        bytes.append(32); try bytes.write(to: file)
        #expect(throws: (any Error).self) { try BoundedFile.read(file) }
        #expect(throws: (any Error).self) { try L10n.load("en", at: file) }
        #expect(throws: (any Error).self) { try ThemeCatalog.load(at: file) }
        #expect(RunningProcessMap(bundledURL: missing, overrideURL: file).names.isEmpty)
        #expect(RunningProcessMap(overrideURL: file).names == RunningProcessMap(overrideURL: missing).names)
        #expect(ThemeCatalog.loadOrDefault(at: file).providers == ThemeCatalog.builtIn.providers)
        #expect(ThemeCatalog.loadOrDefault(at: missing).palette(.dark).background == ThemeCatalog.builtIn.palette(.dark).background)
        try Data("{\"key\":\"value\"}".utf8).write(to: file)
        #expect(try L10n.load("en", at: file) == ["key": "value"])
        for content in ["invalid", "{}"] {
            try Data(content.utf8).write(to: file)
            #expect(ThemeCatalog.loadOrDefault(at: file).palette(.light).colors == ThemeCatalog.builtIn.palette(.light).colors)
        }
        var theme = try #require(try JSONSerialization.jsonObject(with: BoundedFile.read(SharedResources.url("theme.json"))) as? [String: Any])
        theme["quota"] = ["high": "not-a-color", "mid": "#123456", "low": "#123456"]
        try JSONSerialization.data(withJSONObject: theme).write(to: file)
        #expect(throws: (any Error).self) { try ThemeCatalog.load(at: file) }
        #expect(ThemeCatalog.loadOrDefault(at: file).quota == ThemeCatalog.builtIn.quota)
    }

    @MainActor @Test func grokPrivateLogoIsOptionalAndFallsBackToLobe() throws {
        let folder = try reviewFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let privateURL = folder.appendingPathComponent("grokbot.png")
        let fallback = SharedResources.url("grok.png", directory: "logos")
        let lobe = try #require(AIUsageBrand.grokImage(privateURL: privateURL, fallbackURL: fallback))
        #expect(lobe.isValid)
        #expect(lobe.isTemplate)
        let custom = NSImage(size: NSSize(width: 7, height: 9))
        custom.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 7, height: 9).fill(); custom.unlockFocus()
        try #require(custom.tiffRepresentation).write(to: privateURL)
        #expect(AIUsageBrand.grokImage(privateURL: privateURL, fallbackURL: fallback)?.size == custom.size)
        #expect(AIUsageBrand.grokImage(privateURL: privateURL, fallbackURL: fallback)?.isTemplate == false)
        try Data("invalid".utf8).write(to: privateURL)
        #expect(AIUsageBrand.grokImage(privateURL: privateURL, fallbackURL: fallback)?.size == lobe.size)
    }
}

@Suite struct CodexBundleExecutableTests {
    @Test func bundleExecutableIsRecognised() {
        let exe = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
        #expect(CodexCLITrust.enclosingBundle(exe)?.lastPathComponent == "CodexCLI.app")
        #expect(CodexCLITrust.enclosingBundle(URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex")) == nil)
        #expect(CodexCLITrust.enclosingBundle(URL(fileURLWithPath: "/opt/homebrew/bin/codex")) == nil)
    }

    private func fixture() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-bundle-test-" + UUID().uuidString)
        let bundle = root.appendingPathComponent("CodexCLI.app")
        let binary = bundle.appendingPathComponent("Contents/MacOS/codex")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contentsOf: URL(fileURLWithPath: "/usr/bin/true")).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        try SyntheticCodeFixture.sign(binary)
        let resources = bundle.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data("sealed-fixture-resource".utf8).write(to: resources.appendingPathComponent("fixture.txt"))
        return (root, binary)
    }

    @Test func injectedVerifierStillCopiesWholeBundleAndExecutesInsideCopy() throws {
        let (root, binary) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = try #require(CodexCLITrust.enclosingBundle(binary)).appendingPathComponent("Contents/Resources")
        try FileManager.default.createSymbolicLink(atPath: resources.appendingPathComponent("fixture-link.txt").path,
                                                   withDestinationPath: "fixture.txt")
        var verified: URL?
        let prepared = try CodexCLITrust.prepare(binary, verifyCLI: { bundle in
            verified = bundle
            #expect(bundle.pathExtension == "app")
            #expect(bundle != CodexCLITrust.enclosingBundle(binary))
            let resource = try String(contentsOf: bundle.appendingPathComponent("Contents/Resources/fixture.txt"), encoding: .utf8)
            #expect(resource == "sealed-fixture-resource")
        })
        defer { prepared.cleanup() }
        #expect(prepared.executable.path.hasPrefix(try #require(verified).path + "/"))
        for path in [prepared.directory, try #require(verified), prepared.executable] {
            #expect((try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber)?.intValue == 0o500)
        }
        let entries = try #require(FileManager.default.enumerator(at: prepared.directory, includingPropertiesForKeys: nil))
        for case let file as URL in entries {
            var metadata = stat()
            #expect(lstat(file.path, &metadata) == 0)
            #expect(metadata.st_uid == getuid())
        }
        let process = try CLIProcess(executable: prepared.executable, arguments: [], environment: CLIEnvironment.codex(), directory: prepared.directory,
            beforeSpawn: prepared.validateBeforeSpawn, verifySpawned: prepared.validateSpawned)
        defer { process.abandonBestEffort() }
        let deadline = Date().addingTimeInterval(3)
        while try process.isRunning && Date() < deadline { usleep(5_000) }
        #expect(try process.succeeded)
        #expect(prepared.cleanup())
        #expect(!FileManager.default.fileExists(atPath: prepared.directory.path))
    }

    @Test func externalBundleSymlinkIsRejectedBeforeVerificationWithoutChangingTarget() throws {
        let (root, binary) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("external.txt")
        let bytes = Data("synthetic-external-resource".utf8)
        try bytes.write(to: target)
        let resources = try #require(CodexCLITrust.enclosingBundle(binary)).appendingPathComponent("Contents/Resources")
        try FileManager.default.createSymbolicLink(at: resources.appendingPathComponent("external-link"), withDestinationURL: target)
        var verified = false
        #expect(throws: (any Error).self) { try CodexCLITrust.prepare(binary, verifyCLI: { _ in verified = true }) }
        #expect(!verified)
        #expect(try Data(contentsOf: target) == bytes)
    }

    @Test func bundleSignatureFailureCleansTheEntirePrivateRoot() throws {
        let (root, binary) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var copiedRoot: URL?
        #expect(throws: (any Error).self) {
            try CodexCLITrust.prepare(binary, verifyCLI: { bundle in
                copiedRoot = bundle.deletingLastPathComponent()
                throw AIUsageError.invalidResponse
            })
        }
        #expect(!FileManager.default.fileExists(atPath: try #require(copiedRoot).path))
    }

    @Test func replacementAndInPlaceModificationAreRejectedBeforeSpawn() throws {
        for replace in [true, false] {
            let (root, binary) = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let prepared = try CodexCLITrust.prepare(binary, verifyCLI: { _ in })
            defer { prepared.cleanup() }
            // Model a hostile process with the same UID, which can undo chmod.
            let parent = prepared.executable.deletingLastPathComponent()
            #expect(chmod(parent.path, 0o700) == 0)
            if replace {
                try FileManager.default.moveItem(at: prepared.executable, to: parent.appendingPathComponent("old"))
                try FileManager.default.copyItem(at: binary, to: prepared.executable)
            } else {
                #expect(chmod(prepared.executable.path, 0o700) == 0)
                let handle = try FileHandle(forWritingTo: prepared.executable)
                try handle.seekToEnd(); try handle.write(contentsOf: Data([0])); try handle.close()
            }
            #expect(chmod(prepared.executable.path, 0o500) == 0)
            #expect(throws: (any Error).self) { try prepared.validateBeforeSpawn() }
        }
    }

    @Test func mismatchedSuspendedProcessIsKilledBeforeUserCodeRuns() throws {
        let (root, binary) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let prepared = try CodexCLITrust.prepare(binary, verifyCLI: { _ in })
        defer { prepared.cleanup() }
        let marker = root.appendingPathComponent("should-not-exist")
        var pid: pid_t = 0
        #expect(throws: (any Error).self) {
            try CLIProcess(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "touch '\(marker.path)'"],
                environment: CLIEnvironment.codex(), directory: root, verifySpawned: {
                    pid = $0; try prepared.validateSpawned($0)
                })
        }
        #expect(pid > 0)
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func dynamicOpenAIRequirementRejectsMatchingAdHocImage() throws {
        let (root, binary) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let prepared = try CodexCLITrust.prepare(binary, verifyCLI: { _ in })
        defer { prepared.cleanup() }
        // The slice cdhash matches, but a synthetic ad-hoc signer is not OpenAI.
        let productionTrust = try CodexCLITrust.Prepared(executable: prepared.executable, directory: prepared.directory)
        var pid: pid_t = 0
        #expect(throws: (any Error).self) {
            try CLIProcess(executable: prepared.executable, arguments: [], environment: CLIEnvironment.codex(), directory: prepared.directory,
                beforeSpawn: productionTrust.validateBeforeSpawn, verifySpawned: {
                    pid = $0; try productionTrust.validateSpawned($0)
                })
        }
        #expect(pid > 0)
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }
}
