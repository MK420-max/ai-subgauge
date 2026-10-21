import Darwin
import Foundation
import Testing
@testable import TidyBar

extension TidyBarTests {
    @Test func codexTemporaryRootClearsInheritedACLBeforeCopying() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("codex-acl-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: parent) }
        var uuid = UUID().uuid
        #expect(mbr_gid_to_uuid(getgid(), &uuid) == 0)
        var acl = acl_init(1)
        defer { if let acl { acl_free(UnsafeMutableRawPointer(acl)) } }
        var entry: acl_entry_t?, permissions: acl_permset_t?, flags: acl_flagset_t?
        #expect(acl_create_entry(&acl, &entry) == 0)
        let ace = try #require(entry)
        #expect(acl_set_tag_type(ace, ACL_EXTENDED_ALLOW) == 0)
        #expect(acl_set_qualifier(ace, &uuid) == 0)
        #expect(acl_get_permset(ace, &permissions) == 0)
        let permissionSet = try #require(permissions)
        #expect(acl_add_perm(permissionSet, ACL_READ_DATA) == 0)
        #expect(acl_get_flagset_np(UnsafeMutableRawPointer(ace), &flags) == 0)
        let inheritance = try #require(flags)
        #expect(acl_add_flag_np(inheritance, ACL_ENTRY_DIRECTORY_INHERIT) == 0)
        #expect(acl_add_flag_np(inheritance, ACL_ENTRY_FILE_INHERIT) == 0)
        let parentACL = try #require(acl)
        #expect(acl_set_file(parent.path, ACL_TYPE_EXTENDED, parentACL) == 0)

        // Establish that this parent really passes its ACL to a freshly created directory.
        var template = Array(parent.appendingPathComponent("control-XXXXXX").path.utf8CString)
        #expect(mkdtemp(&template) != nil)
        let control = try #require(acl_get_file(String(cString: template), ACL_TYPE_EXTENDED))
        defer { acl_free(UnsafeMutableRawPointer(control)) }
        var inherited: acl_entry_t?
        #expect(acl_get_entry(control, ACL_FIRST_ENTRY.rawValue, &inherited) == 0)

        let root = try CodexCLITrust.privateDirectory(in: parent)
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        #expect(fd >= 0)
        defer { close(fd) }
        var metadata = stat()
        #expect(fstat(fd, &metadata) == 0)
        #expect(metadata.st_uid == getuid())
        #expect(metadata.st_mode & 0o7777 == 0o700)
        if let cleared = acl_get_fd(fd) {
            defer { acl_free(UnsafeMutableRawPointer(cleared)) }
            var remaining: acl_entry_t?
            #expect(acl_get_entry(cleared, ACL_FIRST_ENTRY.rawValue, &remaining) == -1)
            #expect(errno == EINVAL)
        } else { #expect(errno == ENOENT) } // Darwin may remove the empty ACL entirely.
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}
