import Foundation
import Darwin
import Testing
@testable import TidyBar

// Notifications, defaults and subprocess tests share process-global state.
@Suite(.serialized)
struct TidyBarTests {
    // Historical fixtures assert Chinese copy. Production still follows the system.
    init() { L10n.overrideLanguage = "zh-Hans" }
}

final class TestSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false

    func signal() { lock.withLock { signaled = true } }

    func wait(timeout: TimeInterval) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if lock.withLock({ signaled }) { return true }
            do { try await Task.sleep(nanoseconds: 5_000_000) }
            catch { return false }
        }
        return lock.withLock { signaled }
    }
}

enum ProcessTreeFixture {
    static func script(pids: URL) -> String {
        """
        trap '' TERM
        /bin/sh -c '
          trap "" TERM
          /bin/sleep 30 &
          child=$!
          printf "%s\\n" "$$" "$child" > "\(pids.path)"
          wait
        ' &
        wait
        """
    }

    static func pids(at url: URL) async throws -> [Int32] {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let text = try? String(contentsOf: url, encoding: .utf8), text.hasSuffix("\n") {
                let values = text.split(separator: "\n").compactMap { Int32($0) }
                if values.count == 2 { return values }
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw AIUsageError.timeout
    }

    static func expectExited(_ pids: [Int32]) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < deadline, pids.contains(where: { kill($0, 0) == 0 }) {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        for pid in pids { #expect(kill(pid, 0) != 0, "CLI and every descendant must exit") }
    }
}
