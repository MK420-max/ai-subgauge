import Darwin
import Foundation

enum BoundedFile {
    static let maximum = 1_048_576
    static func read(_ url: URL, maximum: Int = maximum) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size >= 0, metadata.st_size <= maximum else { throw AIUsageError.invalidResponse }
        return try read(file, maximum: maximum)
    }

    static func read(_ file: FileHandle, maximum: Int) throws -> Data {
        var data = Data()
        while let chunk = try file.read(upToCount: min(8192, maximum + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maximum else { throw AIUsageError.invalidResponse }
        }
        return data
    }
}
