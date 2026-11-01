import Darwin
import Foundation
import Testing
@testable import TidyBar

private final class ExitObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: Int32?
    private var observationDelay: useconds_t = 0
    private var observations = 0
    private var restores = 0

    func delay(by microseconds: useconds_t) { lock.withLock { observationDelay = microseconds } }
    func fail(with code: Int32?) { lock.withLock { failure = code } }
    var calls: Int { lock.withLock { observations } }
    var restoreCount: Int { lock.withLock { restores } }
    func restored() { lock.withLock { restores += 1 } }
    func wait(_ pid: pid_t, _ info: UnsafeMutablePointer<siginfo_t>) -> Int32 {
        let delay = lock.withLock { observationDelay }
        if delay > 0 { usleep(delay) }
        return lock.withLock {
            observations += 1
            if let failure { errno = failure; return -1 }
            return waitid(P_PID, id_t(pid), info, WEXITED | WNOHANG | WNOWAIT)
        }
    }
}

extension TidyBarTests {
@Suite
struct CLIProcessTests {
    private enum VerificationError: Error { case rejected }

    private func readPID(from pipe: Pipe) throws -> pid_t {
        var descriptor = pollfd(fd: pipe.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        try #require(poll(&descriptor, 1, 3_000) > 0)
        var bytes = [UInt8](repeating: 0, count: 64)
        let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
        try #require(count > 0)
        return try #require(pid_t(String(decoding: bytes.prefix(count), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    private func expectReaped(_ pid: pid_t) {
        var status: Int32 = 0
        #expect(waitpid(pid, &status, WNOHANG) == -1 && errno == ECHILD)
    }

    private func expectExited(_ pid: pid_t) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while true {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            let read = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
            if read == 0 && errno == ESRCH { return }
            try #require(read == size)
            if info.pbi_status == SZOMB { return }
            try #require(ProcessInfo.processInfo.systemUptime < deadline, "Recorded group member must exit")
            usleep(5_000)
        }
    }

    @Test func observationErrorsSurfaceAndRenewalCleanupFailsClosed() throws {
        for code in [EINVAL, EIO] {
            for abandon in [false, true] {
                let observer = ExitObserver()
                let process = try CLIProcess(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
                    environment: [:], directory: URL(fileURLWithPath: #filePath).deletingLastPathComponent(), waitID: observer.wait)
                defer { observer.fail(with: nil); process.abandonBestEffort() }
                let epoch = GrokRenewalEpoch(restore: { _ in observer.restored() })
                _ = try epoch.launch {
                    GrokRenewalEpoch.Child(pid: process.processIdentifier,
                        stop: { _ in try process.stopRecordedChild() }, cleanup: { try process.stopRecordedChild() })
                }
                observer.fail(with: code)
                for _ in 0..<2 {
                    do { _ = try process.isRunning; Issue.record("Observation errors must reach the caller") }
                    catch let error as POSIXError { #expect(error.code.rawValue == code) }
                }
                do {
                    let unused = URL(fileURLWithPath: #filePath).appendingPathComponent("unused-store")
                    if abandon { try epoch.abandon(at: unused) }
                    else { try epoch.finish(at: unused) }
                    Issue.record("Unconfirmed cleanup must fail closed")
                } catch let error as POSIXError { #expect(error.code.rawValue == code) }
                #expect(observer.restoreCount == 0)
                #expect(throws: CancellationError.self) { try epoch.withCurrent {} }
                if !abandon { #expect((epoch.cleanupFailure as? POSIXError)?.code.rawValue == code) }
                observer.fail(with: nil)
                try process.stopRecordedChild()
                expectReaped(process.processIdentifier)
            }
        }
    }

    @Test func observationLeavesLiveGroupUntouchedUntilExplicitStop() throws {
        let output = Pipe(), observer = ExitObserver()
        let process = try CLIProcess(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; /bin/sleep 30 & printf '%s\\n' \"$!\"; exit 0"], environment: [:],
            directory: URL(fileURLWithPath: #filePath).deletingLastPathComponent(),
            output: output.fileHandleForWriting.fileDescriptor, waitID: observer.wait)
        defer { process.abandonBestEffort() }
        try output.fileHandleForWriting.close()
        let descendant = try readPID(from: output)
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while try process.isRunning {
            try #require(ProcessInfo.processInfo.systemUptime < deadline)
            usleep(5_000)
        }
        // Observation must leave this recorded, TERM-ignoring descendant alive.
        #expect(kill(descendant, 0) == 0)
        var leaderInfo = siginfo_t()
        #expect(waitid(P_PID, id_t(process.processIdentifier), &leaderInfo, WEXITED | WNOHANG | WNOWAIT) == 0)
        #expect(leaderInfo.si_pid == process.processIdentifier)
        try process.stopRecordedChild()
        #expect(try process.succeeded)
        expectReaped(process.processIdentifier)
        try expectExited(descendant)
        let calls = observer.calls
        for _ in 0..<3 {
            #expect(try !process.isRunning)
            try process.stopRecordedChild()
        }
        #expect(observer.calls == calls)
        expectReaped(process.processIdentifier)
    }

    @Test(arguments: [useconds_t(0), 150_000])
    func concurrentPollingAndStopReapOnce(observerDelay: useconds_t) throws {
        let observer = ExitObserver()
        let process = try CLIProcess(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["0.01"],
            environment: [:], directory: URL(fileURLWithPath: #filePath).deletingLastPathComponent(), waitID: observer.wait)
        defer { process.abandonBestEffort() }
        observer.delay(by: observerDelay)
        DispatchQueue.concurrentPerform(iterations: 12) { _ in
            do { _ = try process.isRunning; try process.stopRecordedChild() }
            // Each call bounds lock contention as well as cleanup. A slow observer
            // may exhaust a competing caller's deadline without losing reaper ownership.
            catch AIUsageError.timeout {}
            catch { Issue.record(error) }
        }
        observer.delay(by: 0)
        try process.stopRecordedChild()
        expectReaped(process.processIdentifier)
        #expect(try !process.isRunning)
        let calls = observer.calls
        try process.stopRecordedChild()
        #expect(observer.calls == calls)
    }

    @Test func verificationFailureKillsGroupAndReapsDespiteObservationError() throws {
        let output = Pipe(), observer = ExitObserver()
        observer.fail(with: EINVAL)
        var leader: pid_t = 0, descendant: pid_t = 0
        do {
            let process = try CLIProcess(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; /bin/sleep 30 & printf '%s\\n' \"$!\"; wait"], environment: [:],
                directory: URL(fileURLWithPath: #filePath).deletingLastPathComponent(),
                output: output.fileHandleForWriting.fileDescriptor, verifySpawned: { pid in
                    leader = pid
                    // Only resume our recorded child, to exercise a group with a live descendant.
                    try #require(kill(pid, SIGCONT) == 0)
                    descendant = try readPID(from: output)
                    throw VerificationError.rejected
                }, waitID: observer.wait)
            observer.fail(with: nil)
            process.abandonBestEffort()
            Issue.record("Verification must fail")
        } catch let error as CLIProcess.SpawnVerificationFailure {
            #expect(error.verificationError is VerificationError)
            #expect((error.cleanupError as? POSIXError)?.code == .EINVAL)
            #expect(error.forcedCleanupError == nil)
        }
        try #require(leader > 0 && descendant > 0)
        expectReaped(leader)
        try expectExited(descendant)
    }

    private func waitForLeaderExit(_ pid: pid_t) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while true {
            var info = siginfo_t()
            try #require(waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0)
            if info.si_pid == pid { return }
            try #require(ProcessInfo.processInfo.systemUptime < deadline)
            usleep(1_000)
        }
    }

    private func waitForReaped(_ pid: pid_t) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while true {
            var info = siginfo_t()
            let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
            if result < 0 && errno == ECHILD { return }
            try #require(ProcessInfo.processInfo.systemUptime < deadline, "Background owner must reap")
            usleep(1_000)
        }
    }

    @Test func succeededObservesExitAndReapsWithoutPriorPolling() throws {
        for code in [0, 23] {
            let process = try CLIProcess(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "exit \(code)"], environment: [:],
                directory: URL(fileURLWithPath: #filePath).deletingLastPathComponent())
            defer { process.abandonBestEffort() }
            try waitForLeaderExit(process.processIdentifier)
            #expect(try process.succeeded == (code == 0))
            expectReaped(process.processIdentifier)
        }
    }

    @Test func succeededWhileRunningDoesNotStopChild() throws {
        let process = try CLIProcess(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
            environment: [:], directory: URL(fileURLWithPath: #filePath).deletingLastPathComponent())
        defer { process.abandonBestEffort() }
        #expect(try !process.succeeded)
        #expect(try process.isRunning)
    }

    @Test func succeededThrowsWhenOwnershipIsLostWithoutExitStatus() throws {
        let process = try CLIProcess(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 0"],
            environment: [:], directory: URL(fileURLWithPath: #filePath).deletingLastPathComponent(),
            signalGroup: { _, _ in Issue.record("Lost ownership must forbid signals"); return 0 })
        try waitForLeaderExit(process.processIdentifier)
        var status: Int32 = 0
        try #require(waitpid(process.processIdentifier, &status, 0) == process.processIdentifier)
        for _ in 0..<2 {
            do { _ = try process.succeeded; Issue.record("Unknown exit status must throw") }
            catch let error as POSIXError { #expect(error.code == .ECHILD) }
            try process.stopRecordedChild()
        }
    }

    @Test(arguments: [false, true])
    func forcedCleanupAfterOwnershipLossConfirmsAndCachesDeath(alreadyObserved: Bool) throws {
        let process = try CLIProcess(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 0"],
            environment: [:], directory: URL(fileURLWithPath: #filePath).deletingLastPathComponent())
        try process.stopRecordedChild()
        // The kernel child is already reaped; this state owns no live PID and may never signal.
        let observer = ExitObserver()
        let state = CLIProcess.State(pid: process.processIdentifier, timeout: 1.2, waitID: observer.wait,
            signalGroup: { _, _ in Issue.record("Lost ownership must forbid signals"); return 0 })
        if alreadyObserved { #expect(try !state.observeRunning()) }
        observer.fail(with: EINVAL)
        try state.forceKillAndReap()
        #expect(state.reaped && state.cleaned)
        let calls = observer.calls
        try state.stop()
        try state.forceKillAndReap()
        #expect(observer.calls == calls)
    }

    @Test func forcedCleanupAfterOwnershipLossRejectsLiveGroup() throws {
        let output = Pipe()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("unowned-cli-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let release = folder.appendingPathComponent("release")
        let process = try CLIProcess(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "(while [ -d \"$FOLDER\" ] && [ ! -f \"$RELEASE\" ]; do /bin/sleep 0.01; done) & printf '%s\\n' \"$!\"; exit 0"],
            environment: ["FOLDER": folder.path, "RELEASE": release.path], directory: folder,
            output: output.fileHandleForWriting.fileDescriptor,
            signalGroup: { _, _ in Issue.record("Lost ownership must forbid signals"); return 0 })
        defer { try? Data().write(to: release) }
        try output.fileHandleForWriting.close()
        let descendant = try readPID(from: output)
        try waitForLeaderExit(process.processIdentifier)
        var status: Int32 = 0
        try #require(waitpid(process.processIdentifier, &status, 0) == process.processIdentifier)
        let observer = ExitObserver()
        let state = CLIProcess.State(pid: process.processIdentifier, timeout: 1.2, waitID: observer.wait,
            signalGroup: { _, _ in Issue.record("Lost ownership must forbid signals"); return 0 })
        do { try state.forceKillAndReap(); Issue.record("A live unowned group forbids cleanup confirmation") }
        catch let error as POSIXError { #expect(error.code == .ECHILD) }
        #expect(state.reaped && !state.cleaned)
        try Data().write(to: release)
        try expectExited(descendant)
        try state.forceKillAndReap()
        #expect(state.cleaned)
        try process.stopRecordedChild()
    }

    @Test func deinitReportsBothCleanupFailures() async throws {
        let reported = TestSignal(), observer = ExitObserver()
        observer.fail(with: EINVAL)
        var process: CLIProcess? = try CLIProcess(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
            environment: [:], directory: URL(fileURLWithPath: #filePath).deletingLastPathComponent(),
            signalGroup: { _, _ in errno = EIO; return -1 }, waitID: observer.wait,
            reportCleanupFailure: { pid, cleanupError, forcedError in
                #expect(pid > 0)
                #expect((cleanupError as? POSIXError)?.code == .EINVAL)
                #expect((forcedError as? POSIXError)?.code == .EIO)
                #expect(!Thread.isMainThread)
                reported.signal()
            })
        let pid = try #require(process?.processIdentifier)
        defer {
            // Only our recorded, still-owned child group; never signal after ECHILD.
            var info = siginfo_t()
            if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 {
                #expect(kill(-pid, SIGKILL) == 0)
                var status: Int32 = 0
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            }
        }
        process = nil
        try #require(await reported.wait(timeout: 3))
    }

    @MainActor @Test(arguments: [false, true], [false, true])
    func deinitReapsOffReleasingThreadEvenWithBrokenObserver(brokenObserver: Bool, leaderExited: Bool) throws {
        let observer = ExitObserver(), output = Pipe()
        var process: CLIProcess? = try CLIProcess(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; /bin/sleep 30 & printf '%s\\n' \"$!\"; " + (leaderExited ? "exit 0" : "wait")],
            environment: [:], directory: URL(fileURLWithPath: #filePath).deletingLastPathComponent(),
            output: output.fileHandleForWriting.fileDescriptor, waitID: observer.wait)
        let pid = try #require(process?.processIdentifier)
        try output.fileHandleForWriting.close()
        let descendant = try readPID(from: output)
        if leaderExited { try waitForLeaderExit(pid) }
        if brokenObserver { observer.fail(with: EINVAL) }
        let start = ProcessInfo.processInfo.systemUptime
        process = nil
        #expect(ProcessInfo.processInfo.systemUptime - start < 0.2)
        try waitForReaped(pid)
        try expectExited(descendant)
    }

    @Test(arguments: [false, true])
    func stopConfirmsGroupDeathAndReapBeforeEpochRestore(abandon: Bool) throws {
        let output = Pipe(), observer = ExitObserver()
        let process = try CLIProcess(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; /bin/sleep 30 & printf '%s\\n' \"$!\"; wait"],
            environment: [:], directory: URL(fileURLWithPath: #filePath).deletingLastPathComponent(),
            output: output.fileHandleForWriting.fileDescriptor)
        defer { process.abandonBestEffort() }
        try output.fileHandleForWriting.close()
        let descendant = try readPID(from: output)
        let epoch = GrokRenewalEpoch(restore: { _ in
            self.expectReaped(process.processIdentifier)
            // This assertion runs inside restore, before it can repair permissions.
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            let read = proc_pidinfo(descendant, PROC_PIDTBSDINFO, 0, &info, size)
            #expect((read == 0 && errno == ESRCH) || (read == size && info.pbi_status == SZOMB))
            observer.restored()
        })
        _ = try epoch.launch {
            GrokRenewalEpoch.Child(pid: process.processIdentifier,
                stop: { _ in try process.stopRecordedChild() }, cleanup: { try process.stopRecordedChild() })
        }
        let unused = URL(fileURLWithPath: #filePath).appendingPathComponent("unused-synthetic-store")
        if abandon { try epoch.abandon(at: unused) }
        else { try epoch.finish(at: unused) }
        #expect(observer.restoreCount == 1)
    }

    @Test func stopRepeatsKillUntilThreeStableGroupDeathChecks() throws {
        let output = Pipe()
        var killRounds = 0
        let process = try CLIProcess(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; /bin/sleep 30 & printf '%s\\n' \"$!\"; exit 0"],
            environment: [:], directory: URL(fileURLWithPath: #filePath).deletingLastPathComponent(),
            output: output.fileHandleForWriting.fileDescriptor, signalGroup: { group, signal in
                if signal == SIGKILL {
                    killRounds += 1
                    // Model a writer missed by an earlier group signal. A one-shot kill wedges.
                    if killRounds == 1 { return 0 }
                }
                return kill(group, signal)
            })
        defer { process.abandonBestEffort() }
        try output.fileHandleForWriting.close()
        let descendant = try readPID(from: output)
        try waitForLeaderExit(process.processIdentifier)
        try process.stopRecordedChild()
        #expect(killRounds >= 4) // Missed signal, then at least three stable confirmations.
        expectReaped(process.processIdentifier)
        try expectExited(descendant)
    }

    @Test(arguments: [Int32(0), EINTR, EINVAL])
    func observerDeadlineCoversLateSuccessAndEveryError(code: Int32) throws {
        let observer = ExitObserver()
        let process = try CLIProcess(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
            environment: [:], directory: URL(fileURLWithPath: #filePath).deletingLastPathComponent(),
            cleanupTimeout: 0.02, waitID: { _, _ in
                usleep(40_000)
                if code == 0 { return 0 }
                errno = code
                return -1
            })
        let epoch = GrokRenewalEpoch(restore: { _ in observer.restored() })
        _ = try epoch.launch {
            GrokRenewalEpoch.Child(pid: process.processIdentifier,
                stop: { _ in try process.stopRecordedChild() }, cleanup: { try process.stopRecordedChild() })
        }
        #expect(throws: AIUsageError.self) { _ = try process.isRunning }
        #expect(throws: AIUsageError.self) { _ = try process.succeeded }
        #expect(throws: AIUsageError.self) {
            try epoch.finish(at: URL(fileURLWithPath: #filePath).appendingPathComponent("unused-synthetic-store"))
        }
        #expect(observer.restoreCount == 0)
        // Deinit's native observer fallback owns cleanup/reap after this broken observer.
    }

    @Test(arguments: [1, 2])
    func allocationFailureNeverSpawnsTruncatedArgumentsOrEnvironment(failAt: Int) throws {
        var calls = 0, spawned = false
        do {
            _ = try CLIProcess(executable: URL(fileURLWithPath: "/bin/true"), arguments: [],
                environment: ["SYNTHETIC": "fixture"], directory: URL(fileURLWithPath: #filePath).deletingLastPathComponent(),
                beforeSpawn: { spawned = true }, duplicate: { value in
                    calls += 1
                    if calls == failAt { errno = ENOMEM; return nil }
                    return strdup(value)
                })
            Issue.record("Allocation failure must abort before spawn")
        } catch let error as POSIXError { #expect(error.code == .ENOMEM) }
        #expect(!spawned && calls == failAt)
    }

    @Test func openFailurePreservesErrnoBeforeSpawn() throws {
        var spawned = false
        do {
            _ = try CLIProcess(executable: URL(fileURLWithPath: "/bin/true"), arguments: [], environment: [:],
                directory: URL(fileURLWithPath: #filePath).deletingLastPathComponent(), beforeSpawn: { spawned = true },
                openNull: { errno = EMFILE; return -1 })
            Issue.record("open failure must abort")
        } catch let error as POSIXError { #expect(error.code == .EMFILE) }
        #expect(!spawned)
    }

}
}
