import Darwin
import Foundation

/// Spawn into a new process group atomically, before the executable can create children.
final class CLIProcess {
    let processIdentifier: pid_t
    private var status: Int32?
    private var cleaned = false

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
        if let verifySpawned {
            do {
                // START_SUSPENDED gates our SIGCONT, not signals from a hostile same-UID process.
                // That process can already read ~/.codex/auth.json and change user-writable files;
                // it is outside the macOS user-isolation boundary (see docs/SECURITY.md).
                // The caller must write no stdin/requests until this initializer returns successfully.
                try verifySpawned(pid)
                guard kill(pid, SIGCONT) == 0 else { throw POSIXError(.EIO) }
            } catch {
                kill(-pid, SIGKILL)
                var value: Int32 = 0
                while waitpid(pid, &value, 0) < 0 && errno == EINTR { }
                throw error
            }
        }
        processIdentifier = pid
    }

    var isRunning: Bool {
        if status != nil { return false }
        var value: Int32 = 0
        let result = waitpid(processIdentifier, &value, WNOHANG)
        if result == processIdentifier { status = value }
        return result == 0 || (result < 0 && errno == EINTR)
    }
    var succeeded: Bool { status == 0 }

    func terminateAndWait() {
        guard !cleaned else { return }
        cleaned = true
        // The leader may already have exited while a descendant still holds a pipe open.
        kill(-processIdentifier, SIGTERM)
        usleep(50_000)
        kill(-processIdentifier, SIGKILL)
        if status == nil {
            var value: Int32 = 0
            var result: pid_t
            repeat { result = waitpid(processIdentifier, &value, 0) } while result < 0 && errno == EINTR
            if result == processIdentifier { status = value }
        }
        let deadline = Date().addingTimeInterval(1)
        while kill(-processIdentifier, 0) == 0, Date() < deadline { usleep(5_000) }
    }
}
