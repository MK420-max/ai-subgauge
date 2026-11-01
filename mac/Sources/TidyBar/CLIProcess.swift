import Darwin
import Foundation
import os

/// Spawn into a new process group atomically, before the executable can create children.
final class CLIProcess: @unchecked Sendable {
    let processIdentifier: pid_t
    private let state: State
    private let reportCleanupFailure: @Sendable (pid_t, Error, Error) -> Void

    struct SpawnVerificationFailure: Error {
        let verificationError: Error
        let cleanupError: Error
        let forcedCleanupError: Error?
    }

    init(executable: URL, arguments: [String], environment: [String: String], directory: URL,
         input: Int32? = nil, output: Int32? = nil, beforeSpawn: (() throws -> Void)? = nil,
         verifySpawned: ((pid_t) throws -> Void)? = nil,
         openNull: () -> Int32 = { open("/dev/null", O_RDWR | O_CLOEXEC) },
         duplicate: (String) -> UnsafeMutablePointer<CChar>? = { strdup($0) },
         cleanupTimeout: TimeInterval = 1.2,
         signalGroup: @escaping (pid_t, Int32) -> Int32 = { kill($0, $1) },
         waitID: @escaping (pid_t, UnsafeMutablePointer<siginfo_t>) -> Int32 = {
             waitid(P_PID, id_t($0), $1, WEXITED | WNOHANG | WNOWAIT)
         },
         reportCleanupFailure: @escaping @Sendable (pid_t, Error, Error) -> Void = { pid, _, _ in
             // Fixed diagnostic: never log executable paths, arguments, environment or error payloads.
             Logger(subsystem: AppIdentifiers.bundleID, category: "CLIProcess")
                 .error("Child cleanup and forced fallback failed; group death/reap unconfirmed; pid=\(pid, privacy: .public)")
         }) throws {
        let null = openNull()
        guard null >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
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
        var argv: [UnsafeMutablePointer<CChar>?] = [], env: [UnsafeMutablePointer<CChar>?] = []
        defer { for pointer in argv + env { free(pointer) } }
        func append(_ strings: [String], to pointers: inout [UnsafeMutablePointer<CChar>?]) throws {
            for string in strings {
                guard let pointer = duplicate(string) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOMEM) }
                pointers.append(pointer)
            }
            pointers.append(nil)
        }
        try append([executable.path] + arguments, to: &argv)
        try append(environment.map { $0.key + "=" + $0.value }, to: &env)
        var pid: pid_t = 0
        try beforeSpawn?()
        try check(posix_spawn(&pid, executable.path, &actions, &attributes, &argv, &env))
        processIdentifier = pid
        state = State(pid: pid, timeout: cleanupTimeout, waitID: waitID, signalGroup: signalGroup)
        self.reportCleanupFailure = reportCleanupFailure
        if let verifySpawned {
            do {
                // START_SUSPENDED gates our SIGCONT, not signals from a hostile same-UID process.
                // That process can already read ~/.codex/auth.json and change user-writable files;
                // it is outside the macOS user-isolation boundary (see docs/SECURITY.md).
                // The caller must write no stdin/requests until this initializer returns successfully.
                try verifySpawned(pid)
                guard kill(pid, SIGCONT) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            } catch {
                let verificationError = error
                do { try stopRecordedChild() }
                catch {
                    let cleanupError = error
                    var forcedCleanupError: Error?
                    do { try state.forceKillAndReap() }
                    catch { forcedCleanupError = error }
                    throw SpawnVerificationFailure(verificationError: verificationError,
                        cleanupError: cleanupError, forcedCleanupError: forcedCleanupError)
                }
                throw verificationError
            }
        }
    }

    // Observation retains the leader (WNOWAIT) and never sends signals.
    var isRunning: Bool { get throws { try state.observeRunning() } }

    /// Finalize an exited command, including its group, before reporting/reaping its status.
    var succeeded: Bool { get throws { try state.completedSuccessfully() } }

    /// Returns only after repeated group-death confirmation and waitpid of our leader.
    /// On any uncertainty it throws; callers must not restore credentials after failure.
    func stopRecordedChild() throws { try state.stop() }

    /// Abandonment only: ignores stop failures and leaves final reaping to deinit.
    /// Never use this call as confirmation that credentials can be restored safely.
    func abandonBestEffort() { try? stopRecordedChild() }

    deinit {
        // Transfer sole reaper ownership, never self, off the releasing (possibly main) thread.
        let owned = state
        let report = reportCleanupFailure
        DispatchQueue.global(qos: .utility).async {
            do { try owned.stop() }
            catch {
                let cleanupError = error
                do { try owned.forceKillAndReap() }
                catch { report(owned.processIdentifier, cleanupError, error) }
            }
        }
    }

    final class State: @unchecked Sendable {
        let processIdentifier: pid_t
        let timeout: TimeInterval
        let waitID: (pid_t, UnsafeMutablePointer<siginfo_t>) -> Int32
        let signalGroup: (pid_t, Int32) -> Int32
        let lock = NSLock()
        var status: Int32?
        var reaped = false
        var cleaned = false

        init(pid: pid_t, timeout: TimeInterval,
             waitID: @escaping (pid_t, UnsafeMutablePointer<siginfo_t>) -> Int32,
             signalGroup: @escaping (pid_t, Int32) -> Int32) {
            processIdentifier = pid
            self.timeout = timeout
            self.waitID = waitID
            self.signalGroup = signalGroup
        }

        private func checkDeadline(_ deadline: TimeInterval) throws {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw AIUsageError.timeout }
        }

        private func serialized<T>(_ operation: (TimeInterval) throws -> T) throws -> T {
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            while !lock.try() { try checkDeadline(deadline); usleep(1_000) }
            defer { lock.unlock() }
            try checkDeadline(deadline)
            return try operation(deadline)
        }

        // Sole reaper: all waitid calls use WNOHANG | WNOWAIT; never reap elsewhere.
        // Injected observers must obey that nonblocking contract too. Check every return,
        // including late success and non-EINTR failure, against the same operation deadline.
        private func exited(until deadline: TimeInterval) throws -> Bool {
            if reaped { return true }
            while true {
                try checkDeadline(deadline)
                var info = siginfo_t()
                let result = waitID(processIdentifier, &info)
                let code = errno
                try checkDeadline(deadline)
                if result < 0 {
                    if code == EINTR { usleep(1_000); continue }
                    if code == ECHILD {
                        reaped = true // Ownership lost: never signal this PID/group again.
                        return true
                    }
                    throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
                }
                guard info.si_pid == processIdentifier else { return false }
                status = info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status
                return true
            }
        }

        func observeRunning() throws -> Bool {
            try serialized { try !exited(until: $0) }
        }

        func completedSuccessfully() throws -> Bool {
            try serialized { deadline in
                guard try exited(until: deadline) else { return false }
                try stopLocked(until: deadline)
                guard let status else { throw POSIXError(.ECHILD) }
                return status == 0
            }
        }

        private func groupHasLiveMembers(until deadline: TimeInterval) throws -> Bool {
            try checkDeadline(deadline)
            let needed = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(processIdentifier), nil, 0)
            guard needed >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            var members = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.size + 32)
            let capacity = members.count * MemoryLayout<pid_t>.size
            let bytes = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(processIdentifier), &members, Int32(capacity))
            guard bytes >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard bytes < capacity else { throw POSIXError(.EIO) } // Truncation is not proof of death.
            for pid in members.prefix(Int(bytes) / MemoryLayout<pid_t>.size) where pid > 0 {
                try checkDeadline(deadline)
                var info = proc_bsdinfo()
                let size = Int32(MemoryLayout<proc_bsdinfo>.size)
                let read = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
                if read == 0 && errno == ESRCH { continue }
                guard read == size else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                // Zombies cannot write. Retain our zombie leader until all writers are dead.
                if info.pbi_pgid == UInt32(processIdentifier), info.pbi_status != SZOMB { return true }
            }
            try checkDeadline(deadline)
            return false
        }

        func stop() throws { try serialized { try stopLocked(until: $0) } }

        private func signal(_ value: Int32) throws {
            guard !reaped else { return }
            if signalGroup(-processIdentifier, value) != 0, errno != ESRCH {
                let code = errno
                // EPERM during exit still requires death confirmation; it never permits restore.
                guard code == EPERM else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
            }
        }

        private func stopLocked(until deadline: TimeInterval) throws {
            if cleaned { return }
            _ = try exited(until: deadline)
            if reaped {
                // Ownership loss forbids signals, but still requires spaced death checks.
                for round in 0..<3 {
                    guard try !groupHasLiveMembers(until: deadline) else { throw POSIXError(.ECHILD) }
                    if round < 2 { usleep(5_000) }
                }
                cleaned = true
                return
            }
            try signal(SIGTERM)
            let grace = min(deadline, ProcessInfo.processInfo.systemUptime + 0.1)
            while ProcessInfo.processInfo.systemUptime < grace {
                if try exited(until: deadline) && !groupHasLiveMembers(until: deadline) { break }
                usleep(5_000)
            }
            // Repeat SIGKILL before each snapshot: a descendant forked across an earlier
            // snapshot still receives the next signal. Three spaced empty observations
            // mitigate proc_listpids TOCTOU; keep the leader unreaped throughout.
            var stable = 0
            while stable < 3 {
                try checkDeadline(deadline)
                _ = try exited(until: deadline)
                try signal(SIGKILL)
                if try exited(until: deadline) && !groupHasLiveMembers(until: deadline) { stable += 1 }
                else { stable = 0 }
                if stable < 3 { usleep(5_000) }
            }
            try reap(until: deadline)
            cleaned = true
        }

        private func reap(until deadline: TimeInterval) throws {
            guard !reaped else { return }
            while true {
                try checkDeadline(deadline)
                var value: Int32 = 0
                let waited = waitpid(processIdentifier, &value, WNOHANG)
                if waited == processIdentifier {
                    status = value & 0x7f == 0 ? (value >> 8) & 0xff : 128 + (value & 0x7f)
                    reaped = true
                    return
                }
                if waited < 0 {
                    let code = errno
                    if code == ECHILD { reaped = true; return }
                    if code != EINTR { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
                }
                usleep(5_000)
            }
        }

        /// Failed verification/last-owner cleanup: bypass a broken injected observer.
        /// Native WNOWAIT still fences ownership before every signal; errors fail closed.
        func forceKillAndReap() throws {
            try serialized { deadline in
                if reaped { try stopLocked(until: deadline); return }
                var stable = 0
                while stable < 3 {
                    try checkDeadline(deadline)
                    var info = siginfo_t()
                    let result = waitid(P_PID, id_t(processIdentifier), &info, WEXITED | WNOHANG | WNOWAIT)
                    if result < 0 {
                        let code = errno
                        if code == EINTR { usleep(1_000); continue }
                        if code == ECHILD {
                            reaped = true
                            // Lost ownership still requires group-death confirmation before cleaned.
                            try stopLocked(until: deadline)
                            return
                        }
                        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
                    }
                    try signal(SIGKILL)
                    if try info.si_pid == processIdentifier && !groupHasLiveMembers(until: deadline) { stable += 1 }
                    else { stable = 0 }
                    if stable < 3 { usleep(5_000) }
                }
                try reap(until: deadline)
                cleaned = true
            }
        }
    }
}
