import Darwin
import Foundation

/// Spawn into a new process group atomically, before the executable can create children.
final class CLIProcess: @unchecked Sendable {
    let processIdentifier: pid_t
    private var status: Int32?
    private let lock = NSLock()
    private var reaped = false
    private var cleanupResult: Result<Void, Error>?

    init(executable: URL, arguments: [String], environment: [String: String], directory: URL,
         input: Int32? = nil, output: Int32? = nil, beforeSpawn: (() throws -> Void)? = nil,
         verifySpawned: ((pid_t) throws -> Void)? = nil) throws {
        let null = open("/dev/null", O_RDWR | O_CLOEXEC)
        guard null >= 0 else { throw POSIXError(.EIO) }
        defer { close(null) }
        var attributes: posix_spawnattr_t?, actions: posix_spawn_file_actions_t?
        func check(_ result: Int32) throws {
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
        }
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        let suspended = verifySpawned == nil ? 0 : POSIX_SPAWN_START_SUSPENDED
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | suspended)))
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        for (source, destination) in [(input ?? null, STDIN_FILENO), (output ?? null, STDOUT_FILENO), (null, STDERR_FILENO)] {
            try check(posix_spawn_file_actions_adddup2(&actions, source, destination))
        }
        try check(posix_spawn_file_actions_addchdir(&actions, directory.path))
        var argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        var env = environment.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { for pointer in argv + env { free(pointer) } }
        var pid: pid_t = 0
        try beforeSpawn?()
        try check(posix_spawn(&pid, executable.path, &actions, &attributes, &argv, &env))
        processIdentifier = pid
        if let verifySpawned {
            do {
                // START_SUSPENDED gates our SIGCONT, not signals from a hostile same-UID process.
                // That process can already read ~/.codex/auth.json and change user-writable files;
                // it is outside the macOS user-isolation boundary (see docs/SECURITY.md).
                // The caller must write no stdin/requests until this initializer returns successfully.
                try verifySpawned(pid)
                guard kill(pid, SIGCONT) == 0 else { throw POSIXError(.EIO) }
            } catch {
                try? stopRecordedChild()
                throw error
            }
        }
    }

    // This class is the sole reaper. Observation never releases the PID/group identity.
    // Do not attach Foundation Process handlers or call waitpid for this child elsewhere.
    private func exited() throws -> Bool {
        if reaped { return true }
        var info = siginfo_t()
        var result: Int32
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        repeat {
            result = waitid(P_PID, id_t(processIdentifier), &info, WEXITED | WNOHANG | WNOWAIT)
            if result < 0 && errno == EINTR && ProcessInfo.processInfo.systemUptime >= deadline {
                throw AIUsageError.timeout
            }
        } while result < 0 && errno == EINTR
        if result < 0 {
            if errno == ECHILD {
                reaped = true // Ownership was lost: never signal this PID or group again.
                return true
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard info.si_pid == processIdentifier else { return false }
        status = info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status
        return true
    }

    var isRunning: Bool { lock.withLock { (try? !exited()) ?? true } }
    var succeeded: Bool { lock.withLock { status == 0 } }

    private func groupHasLiveMembers() throws -> Bool {
        let needed = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(processIdentifier), nil, 0)
        guard needed >= 0 else { throw POSIXError(.EIO) }
        var members = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.size + 32)
        let capacity = members.count * MemoryLayout<pid_t>.size
        let bytes = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(processIdentifier), &members, Int32(capacity))
        guard bytes >= 0, bytes < capacity else { throw POSIXError(.EIO) }
        for pid in members.prefix(Int(bytes) / MemoryLayout<pid_t>.size) where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            let read = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
            if read == 0 && errno == ESRCH { continue }
            guard read == size else { throw POSIXError(.EIO) }
            // A zombie cannot write. Keep our zombie leader unreaped until every writer is dead.
            if info.pbi_pgid == UInt32(processIdentifier), info.pbi_status != SZOMB { return true }
        }
        return false
    }

    /// Bounded, serialized group termination; retain the leader until the group cannot write.
    func stopRecordedChild() throws {
        try lock.withLock {
            if let cleanupResult { return try cleanupResult.get() }
            let result = Result<Void, Error> {
                _ = try exited()
                if reaped {
                    guard try !groupHasLiveMembers() else { throw POSIXError(.ECHILD) }
                    return
                }
                func signal(_ value: Int32) throws {
                    // exited() uses WNOWAIT, and all our observers/reapers share this lock.
                    _ = try exited()
                    guard !reaped else { return }
                    if kill(-processIdentifier, value) != 0, errno != ESRCH {
                        let code = errno
                        // Darwin can deny signals during exit. The bounded checks below must
                        // still confirm the entire group is dead; EPERM never authorizes restore.
                        guard code == EPERM else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
                    }
                }
                func groupExited() throws -> Bool {
                    try exited() && !groupHasLiveMembers()
                }
                if try !groupExited() {
                    try signal(SIGTERM)
                    let grace = ProcessInfo.processInfo.systemUptime + 0.1
                    while try !groupExited(), ProcessInfo.processInfo.systemUptime < grace { usleep(5_000) }
                    if try !groupExited() { try signal(SIGKILL) }
                    let deadline = ProcessInfo.processInfo.systemUptime + 1
                    while try !groupExited() {
                        guard ProcessInfo.processInfo.systemUptime < deadline else { throw AIUsageError.timeout }
                        usleep(5_000)
                    }
                }
                guard !reaped else { return }
                var value: Int32 = 0
                var waited: pid_t
                let reapDeadline = ProcessInfo.processInfo.systemUptime + 1
                repeat {
                    waited = waitpid(processIdentifier, &value, WNOHANG)
                    if waited < 0 && errno == EINTR && ProcessInfo.processInfo.systemUptime >= reapDeadline {
                        throw AIUsageError.timeout
                    }
                } while waited < 0 && errno == EINTR
                guard waited == processIdentifier || (waited < 0 && errno == ECHILD) else { throw AIUsageError.timeout }
                reaped = true
            }
            // Retry failures while ownership is retained. exited() fences every signal once
            // waitpid/ECHILD releases ownership, including on a later cleanup attempt.
            if case .success = result { cleanupResult = result }
            try result.get()
        }
    }

    func terminateAndWait() { try? stopRecordedChild() }
}
