import Darwin
import Foundation

/// A valid Apple Developer ID signature from xAI is required, including for cached downloads.
/// No hash, ad hoc signature or executable found through PATH is trusted implicitly.
enum GrokCLITrust {
    static let teamID = "5Y6N3AJ54S"
    static let requirement = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"\(teamID)\" and identifier \"xai-grok-pager\""

    static func allowedPath(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let path = url.standardizedFileURL.path
        let directories = [home.appendingPathComponent(".local/bin"), home.appendingPathComponent(".grok/bin"),
            URL(fileURLWithPath: "/opt/homebrew/bin"), URL(fileURLWithPath: "/usr/local/bin"),
            AppIdentifiers.supportDirectory.appendingPathComponent("Tools")]
        return directories.contains { directory in
            path.hasPrefix(directory.path + "/") && url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL
        }
    }

    static func verify(_ url: URL) throws {
        let file = url.resolvingSymlinksInPath()
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        guard allowedPath(url), attributes?[.type] as? FileAttributeType == .typeRegular,
              let owner = attributes?[.ownerAccountID] as? NSNumber, [0, getuid()].contains(owner.uint32Value),
              let mode = attributes?[.posixPermissions] as? NSNumber, mode.intValue & 0o022 == 0 else {
            throw AIUsageError.unavailable(L10n.text("error.grok.cli.path.owner.or.permissions.validation"))
        }
        try verifySignature(file)
    }

    struct Prepared {
        let executable: URL
        var directory: URL { executable.deletingLastPathComponent() }
        func cleanup() { try? FileManager.default.removeItem(at: directory) }
    }

    /// Verify the private copy that will actually be executed, never the mutable source.
    static func prepare(_ url: URL, verifyCLI: ((URL) throws -> Void)? = nil) throws -> Prepared {
        guard verifyCLI != nil || allowedPath(url) else {
            throw AIUsageError.unavailable(L10n.text("error.grok.cli.path.owner.or.permissions.validation"))
        }
        let source = url.resolvingSymlinksInPath()
        let descriptor = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw AIUsageError.invalidResponse }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? input.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              [0, getuid()].contains(metadata.st_uid), metadata.st_mode & 0o022 == 0 else {
            throw AIUsageError.unavailable(L10n.text("error.grok.cli.path.owner.or.permissions.validation"))
        }
        var template = Array(FileManager.default.temporaryDirectory.appendingPathComponent("aisubgauge-grok-XXXXXX").path.utf8CString)
        guard mkdtemp(&template) != nil else { throw AIUsageError.invalidResponse } // 0700 from creation.
        let directory = URL(fileURLWithPath: String(cString: template), isDirectory: true)
        let prepared = Prepared(executable: directory.appendingPathComponent("grok"))
        do {
            let target = open(prepared.executable.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o700)
            guard target >= 0 else { throw AIUsageError.invalidResponse }
            let output = FileHandle(fileDescriptor: target, closeOnDealloc: true)
            defer { try? output.close() }
            while let bytes = try input.read(upToCount: 1_048_576), !bytes.isEmpty { try output.write(contentsOf: bytes) }
            try output.close()
            try (verifyCLI ?? verifySignature)(prepared.executable)
            return prepared
        } catch { prepared.cleanup(); throw error }
    }

    static func codesignArguments(for file: URL) -> [String] {
        ["--verify", "--strict", "-R", "=" + requirement, file.path]
    }

    static func verifySignature(_ file: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = codesignArguments(for: file)
        process.environment = CLIEnvironment.minimal()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit() }
        catch { throw AIUsageError.unavailable(L10n.text("error.could.not.validate.the.grok.cli.signature")) }
        guard process.terminationStatus == 0 else {
            throw AIUsageError.unavailable(L10n.text("error.grok.cli.official.signature.or.developer.team"))
        }
    }
}
