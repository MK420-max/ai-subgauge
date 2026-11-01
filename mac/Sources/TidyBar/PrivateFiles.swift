import Darwin
import Foundation

/// Private state uses owner-only permissions, including during an atomic replacement.
enum PrivateFiles {
    static func createDirectory(at url: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    static func write(_ data: Data, to url: URL, privateDirectory: Bool = true) throws {
        let directory = url.deletingLastPathComponent()
        if privateDirectory { try createDirectory(at: directory) }
        var template = Array(directory.appendingPathComponent(".tidybar-XXXXXX").path.utf8CString)
        let descriptor = mkstemp(&template) // Always creates the staging file with mode 0600.
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let temporary = URL(fileURLWithPath: String(cString: template))
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
        }
        try handle.write(contentsOf: data)
        try handle.close()
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
