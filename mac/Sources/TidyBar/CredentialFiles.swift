import Darwin
import Foundation
import MenuBarShim

/// Open before checking metadata; never read a symlink, foreign-owned or shared credential.
enum CredentialFiles {
    static func validateRenewedMetadata(_ metadata: stat) throws {
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == getuid() else {
            throw AIUsageError.unsafeCredential(L10n.text("error.the.0.login.file.has.an.unsafe", "Grok"))
        }
    }

    static func restrictAfterRenewal(at file: URL) throws {
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw AIUsageError.invalidResponse }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0 else {
            throw AIUsageError.invalidResponse
        }
        try validateRenewedMetadata(opened)
        guard fchmod(descriptor, 0o600) == 0 else { throw AIUsageError.invalidResponse }
        try validateACL(descriptor, provider: "Grok")
    }

    static func validateACL(_ descriptor: Int32, provider: String) throws {
        func unsafe() -> AIUsageError { .unsafeCredential(L10n.text("error.the.0.login.file.has.an.unsafe", provider)) }
        guard let acl = acl_get_fd(descriptor) else {
            if errno == ENOENT { return } // No extended ACL on this opened file.
            throw unsafe()
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var owner = UUID().uuid
        guard mbr_uid_to_uuid(getuid(), &owner) == 0 else { throw unsafe() }
        var entry: acl_entry_t?
        var index = ACL_FIRST_ENTRY
        while true {
            let result = acl_get_entry(acl, index.rawValue, &entry)
            // Darwin returns -1 with errno=EINVAL at end of an ACL (including an empty ACL).
            if result != 0 {
                guard errno == EINVAL else { throw unsafe() }
                break
            }
            index = ACL_NEXT_ENTRY
            guard let entry else { throw unsafe() }
            var tag = ACL_UNDEFINED_TAG
            guard acl_get_tag_type(entry, &tag) == 0 else { throw unsafe() }
            if tag != ACL_EXTENDED_ALLOW { continue }
            guard let qualifier = acl_get_qualifier(entry) else { throw unsafe() }
            defer { acl_free(qualifier) }
            if withUnsafeBytes(of: &owner, { memcmp(qualifier, $0.baseAddress!, 16) == 0 }) { continue }
            var permissions: acl_permset_t?
            guard acl_get_permset(entry, &permissions) == 0, let permissions else { throw unsafe() }
            for permission in [ACL_READ_DATA, ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_DELETE,
                               ACL_WRITE_SECURITY, ACL_CHANGE_OWNER, ACL_WRITE_ATTRIBUTES, ACL_WRITE_EXTATTRIBUTES] {
                let granted = acl_get_perm_np(permissions, permission)
                guard granted == 0 else { throw unsafe() }
            }
        }
    }

    static func validate(_ metadata: stat, provider: String) throws {
        if metadata.st_mode & 0o044 != 0 {
            throw AIUsageError.unsafeCredential(L10n.text("error.the.0.login.file.is.readable.by", provider))
        }
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == getuid(),
              metadata.st_mode & 0o022 == 0, metadata.st_size >= 0, metadata.st_size <= 1_048_576 else {
            throw AIUsageError.unsafeCredential(L10n.text("error.the.0.login.file.has.an.unsafe", provider))
        }
    }

    static func read(at file: URL, provider: String) throws -> Data? {
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw AIUsageError.unsafeCredential(L10n.text("error.could.not.safely.read.the.0.login", provider)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw AIUsageError.invalidResponse }
        try validate(metadata, provider: provider)
        try validateACL(descriptor, provider: provider)
        return try BoundedFile.read(handle, maximum: 1_048_576)
    }
}
