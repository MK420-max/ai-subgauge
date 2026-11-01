import Darwin
import Foundation
import Security
import OSLog

enum CodexCLITrust {
    static let teamID = "2DC432GLL2"
    static let requirement = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"\(teamID)\""
    static let candidates = [
        "/Applications/Codex.app/Contents/Resources/codex",
        "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        "/opt/homebrew/bin/codex", "/usr/local/bin/codex"
    ].map { URL(fileURLWithPath: $0) }

    static func allowedPath(_ original: URL, resolved: URL) -> Bool {
        let path = original.standardizedFileURL.path
        guard candidates.contains(where: { $0.path == path }) else { return false }
        if path.hasPrefix("/Applications/") { return resolved.path == path }
        let prefix = path.hasPrefix("/opt/homebrew/") ? "/opt/homebrew" : "/usr/local"
        return ["/Cellar/codex/", "/Caskroom/codex/"]
            .contains { resolved.path.hasPrefix(prefix + $0) }
    }

    static func isMachO(_ header: Data) -> Bool {
        [[0xfe, 0xed, 0xfa, 0xce], [0xce, 0xfa, 0xed, 0xfe], [0xfe, 0xed, 0xfa, 0xcf],
         [0xcf, 0xfa, 0xed, 0xfe], [0xca, 0xfe, 0xba, 0xbe], [0xbe, 0xba, 0xfe, 0xca],
         [0xca, 0xfe, 0xba, 0xbf], [0xbf, 0xba, 0xfe, 0xca]].contains { Data($0) == header.prefix(4) }
    }

    static func validMetadata(_ metadata: stat) -> Bool {
        metadata.st_mode & S_IFMT == S_IFREG && metadata.st_mode & 0o022 == 0
            && [0, getuid()].contains(metadata.st_uid)
    }

    static func verifySignature(_ file: URL) throws {
        _ = try verifyAndHash(file)
    }

    private static func verifyAndHash(_ file: URL) throws -> Data {
        var code: SecStaticCode?, rule: SecRequirement?
        guard SecStaticCodeCreateWithPath(file as CFURL, [], &code) == errSecSuccess,
              let code, SecRequirementCreateWithString(requirement as CFString, [], &rule) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), rule) == errSecSuccess else {
            throw AIUsageError.unavailable(L10n.text("usage.codex.was.not.found.install.and.sign"))
        }
        return try signingHash(code)
    }

    static func cdhash(_ file: URL) throws -> Data {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(file as CFURL, [], &code) == errSecSuccess, let code else { throw AIUsageError.invalidResponse }
        return try signingHash(code)
    }

    private static func signingHash(_ code: SecStaticCode) throws -> Data {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let hash = (information as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else {
            throw AIUsageError.invalidResponse
        }
        return hash
    }

    /// The kernel can select a different slice from Security's default (e.g. arm64e.x1).
    /// Collect slice cdhashes before/after the single all-architectures verification.
    private static func sliceHashes(_ file: URL, descriptor: Int32) throws -> [Data] {
        var bytes = [UInt8](repeating: 0, count: 8)
        guard pread(descriptor, &bytes, bytes.count, 0) == bytes.count else { throw AIUsageError.invalidResponse }
        let magic = Array(bytes.prefix(4))
        let wide = magic == [0xca, 0xfe, 0xba, 0xbf] || magic == [0xbf, 0xba, 0xfe, 0xca]
        let swapped = magic == [0xbe, 0xba, 0xfe, 0xca] || magic == [0xbf, 0xba, 0xfe, 0xca]
        guard wide || swapped || magic == [0xca, 0xfe, 0xba, 0xbe] else { return [try cdhash(file)] }
        func number(_ data: ArraySlice<UInt8>) -> UInt64 {
            (swapped ? Array(data.reversed()) : Array(data)).reduce(0) { ($0 << 8) | UInt64($1) }
        }
        let count = number(bytes[4..<8]), stride = wide ? 32 : 20
        guard (1...128).contains(count) else { throw AIUsageError.invalidResponse }
        bytes = [UInt8](repeating: 0, count: Int(count) * stride)
        guard pread(descriptor, &bytes, bytes.count, 8) == bytes.count else { throw AIUsageError.invalidResponse }
        return try (0..<Int(count)).map { index in
            let start = index * stride + 8
            let offset = number(bytes[start..<(start + (wide ? 8 : 4))])
            let attributes = [kSecCodeAttributeUniversalFileOffset as String: NSNumber(value: offset)] as CFDictionary
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPathAndAttributes(file as CFURL, [], attributes, &code) == errSecSuccess,
                  let code else { throw AIUsageError.invalidResponse }
            return try signingHash(code)
        }
    }

    final class Prepared {
        let executable: URL
        let directory: URL
        private let descriptor: Int32
        private let metadata: stat
        private let hash: Data
        private let hashes: [Data]
        private let publisherRequirement: String?

        init(executable: URL, directory: URL, publisherRequirement: String? = CodexCLITrust.requirement) throws {
            self.executable = executable; self.directory = directory
            self.publisherRequirement = publisherRequirement
            descriptor = open(executable.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw AIUsageError.invalidResponse }
            var opened = stat()
            do {
                guard fstat(descriptor, &opened) == 0, validMetadata(opened) else { throw AIUsageError.invalidResponse }
                hash = try cdhash(executable)
                hashes = try sliceHashes(executable, descriptor: descriptor)
                metadata = opened
            } catch { close(descriptor); throw error }
        }

        deinit { close(descriptor) }

        func validateBeforeSpawn() throws {
            var held = stat(), path = stat()
            guard fstat(descriptor, &held) == 0, lstat(executable.path, &path) == 0,
                  [held, path].allSatisfy({
                      $0.st_dev == metadata.st_dev && $0.st_ino == metadata.st_ino && $0.st_size == metadata.st_size
                          && $0.st_mode & S_IFMT == S_IFREG && $0.st_mode & 0o222 == 0
                          && $0.st_mtimespec.tv_sec == metadata.st_mtimespec.tv_sec && $0.st_mtimespec.tv_nsec == metadata.st_mtimespec.tv_nsec
                          && $0.st_ctimespec.tv_sec == metadata.st_ctimespec.tv_sec && $0.st_ctimespec.tv_nsec == metadata.st_ctimespec.tv_nsec
                  }), try cdhash(executable) == hash,
                  try sliceHashes(executable, descriptor: descriptor) == hashes else { throw AIUsageError.invalidResponse }
        }

        fileprivate func verify(_ target: URL, using verifier: ((URL) throws -> Void)?) throws {
            let verifiedHash: Data
            if let verifier { try verifier(target); verifiedHash = try cdhash(executable) }
            else { verifiedHash = try verifyAndHash(target) }
            guard verifiedHash == hash else { throw AIUsageError.invalidResponse }
            try validateBeforeSpawn()
        }

        func validateSpawned(_ pid: pid_t) throws {
            var code: SecCode?, expected: SecRequirement?
            // CLIProcess owns this unreaped child, so its PID cannot be recycled during the check.
            // Validate the running image with the same OpenAI requirement as the static copy,
            // plus its verified slice hashes. No privileged task port or entitlement is needed.
            let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
            let identity = hashes.map { hash in "cdhash H\"" + hash.map { String(format: "%02x", $0) }.joined() + "\"" }.joined(separator: " or ")
            let rule = publisherRequirement.map { "(\($0)) and (\(identity))" } ?? identity
            let flags: SecCSFlags = [] // kSecCSDefaultFlags (0); Swift omits the named zero constant.
            guard SecCodeCopyGuestWithAttributes(nil, attributes, flags, &code) == errSecSuccess, let code,
                  SecRequirementCreateWithString(rule as CFString, [], &expected) == errSecSuccess,
                  SecCodeCheckValidity(code, flags, expected) == errSecSuccess else {
                throw AIUsageError.invalidResponse
            }
            try validateBeforeSpawn()
        }

        @discardableResult func cleanup() -> Bool { CodexCLITrust.cleanup(directory) }
    }

    /// chmod is defense in depth: this UID can chmod its files back. The held inode/size/timestamps
    /// and cdhash are checked immediately before spawn, then the suspended kernel image is checked
    /// before our SIGCONT. Same-UID code can send SIGCONT early, read the original auth store, and
    /// change user-writable files; it is outside the macOS user-isolation boundary. The goal is to
    /// execute only OpenAI-signed CLI code and reject other-user/PATH/unsigned replacements, not
    /// isolate a compromised UID. See docs/SECURITY.md for signal/injection/dylib residual risks.
    private static func freeze(_ root: URL) throws {
        func visit(_ file: URL) throws {
            var metadata = stat()
            guard lstat(file.path, &metadata) == 0, metadata.st_uid == getuid() else { throw AIUsageError.invalidResponse }
            if metadata.st_mode & S_IFMT == S_IFLNK {
                // Bundle framework links may only resolve inside the private copy.
                guard file.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw AIUsageError.invalidResponse }
                return
            }
            let directory = metadata.st_mode & S_IFMT == S_IFDIR
            guard directory || metadata.st_mode & S_IFMT == S_IFREG else { throw AIUsageError.invalidResponse }
            if directory { for child in try FileManager.default.contentsOfDirectory(at: file, includingPropertiesForKeys: nil) { try visit(child) } }
            let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw AIUsageError.invalidResponse }
            defer { close(fd) }
            guard let acl = acl_init(0) else { throw AIUsageError.invalidResponse }
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            guard acl_set_fd(fd, acl) == 0,
                  fchmod(fd, directory || metadata.st_mode & 0o111 != 0 ? 0o500 : 0o400) == 0 else { throw AIUsageError.invalidResponse }
        }
        try visit(root)
    }

    @discardableResult private static func cleanup(_ root: URL) -> Bool {
        var metadata = stat()
        if lstat(root.path, &metadata) != 0, errno == ENOENT { return true }
        // Restore directory write permission only for removal; never follow copied symlinks.
        func writable(_ file: URL) throws {
            var info = stat()
            guard lstat(file.path, &info) == 0 else { throw AIUsageError.invalidResponse }
            guard info.st_mode & S_IFMT == S_IFDIR else { return }
            guard chmod(file.path, 0o700) == 0 else { throw AIUsageError.invalidResponse }
            for child in try FileManager.default.contentsOfDirectory(at: file, includingPropertiesForKeys: nil) { try writable(child) }
        }
        do {
            try writable(root)
            try FileManager.default.removeItem(at: root)
            guard lstat(root.path, &metadata) != 0, errno == ENOENT else { throw AIUsageError.invalidResponse }
            return true
        } catch {
            Logger(subsystem: AppIdentifiers.bundleID, category: "CodexCLITrust").error("Verified CLI temporary root cleanup failed; root disappearance was not confirmed.")
            return false
        }
    }

    /// The enclosing .app when `file` is a bundle's main executable (…/X.app/Contents/MacOS/name).
    static func enclosingBundle(_ file: URL) -> URL? {
        let macOS = file.deletingLastPathComponent(), contents = macOS.deletingLastPathComponent()
        let bundle = contents.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents",
              bundle.pathExtension == "app" else { return nil }
        return bundle
    }

    static func privateDirectory(in parent: URL) throws -> URL {
        var template = Array(parent.appendingPathComponent("aisubgauge-codex-XXXXXX").path.utf8CString)
        guard mkdtemp(&template) != nil else { throw AIUsageError.invalidResponse }
        let directory = URL(fileURLWithPath: String(cString: template), isDirectory: true)
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        do {
            guard fd >= 0 else { throw AIUsageError.invalidResponse }
            defer { close(fd) }
            guard let acl = acl_init(0) else { throw AIUsageError.invalidResponse }
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            var metadata = stat()
            // mkdtemp's mode does not remove ACLs inherited from the temporary parent.
            guard acl_set_fd(fd, acl) == 0, fstat(fd, &metadata) == 0,
                  metadata.st_uid == getuid(), metadata.st_mode & S_IFMT == S_IFDIR,
                  metadata.st_mode & 0o7777 == 0o700 else { throw AIUsageError.invalidResponse }
            return directory
        } catch { cleanup(directory); throw error }
    }

    /// Only execute the signed Mach-O copy; npm launchers cannot attest their publisher.
    static func prepare(_ original: URL, verifyCLI: ((URL) throws -> Void)? = nil) throws -> Prepared {
        let file = original.resolvingSymlinksInPath()
        guard verifyCLI != nil || allowedPath(original, resolved: file) else {
            throw AIUsageError.unavailable(L10n.text("usage.codex.was.not.found.install.and.sign"))
        }
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw AIUsageError.invalidResponse }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, validMetadata(metadata) else { throw AIUsageError.invalidResponse }
        let header = try handle.read(upToCount: 4) ?? Data()
        guard isMachO(header) else {
            throw AIUsageError.unavailable(L10n.text("usage.codex.was.not.found.install.and.sign"))
        }
        let directory = try privateDirectory(in: FileManager.default.temporaryDirectory)
        do {
            let executable: URL, signatureTarget: URL
            if let bundle = enclosingBundle(file) {
                // A bundle executable's signature is sealed to its bundle (Info.plist, resources), so a lone
                // copy of the Mach-O never validates (e.g. ChatGPT.app's CodexCLI.app). Copy the whole bundle
                // into the private directory, verify that copy and run only it.
                let copy = directory.appendingPathComponent(bundle.lastPathComponent, isDirectory: true)
                try FileManager.default.copyItem(at: bundle, to: copy)
                executable = copy.appendingPathComponent("Contents/MacOS").appendingPathComponent(file.lastPathComponent)
                signatureTarget = copy
            } else {
                executable = directory.appendingPathComponent("codex")
                signatureTarget = executable
                let target = open(executable.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o700)
                guard target >= 0 else { throw AIUsageError.invalidResponse }
                let output = FileHandle(fileDescriptor: target, closeOnDealloc: true)
                defer { try? output.close() }
                try output.write(contentsOf: header)
                while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty { try output.write(contentsOf: bytes) }
                try output.close()
            }
            try freeze(directory)
            // The injected verifier is only for synthetic tests; installed() always requires OpenAI
            // in both static and dynamic checks. No production option disables either check.
            let prepared = try Prepared(executable: executable, directory: directory,
                                        publisherRequirement: verifyCLI == nil ? requirement : nil)
            try prepared.verify(signatureTarget, using: verifyCLI) // One full verification, including nested code.
            return prepared
        } catch { cleanup(directory); throw error }
    }

    static func installed() throws -> Prepared {
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            if let prepared = try? prepare(candidate) { return prepared }
        }
        throw AIUsageError.unavailable(L10n.text("usage.codex.was.not.found.install.and.sign"))
    }
}
