import Foundation

/// Fallback permission queries are bounded; system events can invalidate them early.
struct PermissionCache<Value> {
    private var cached: (value: Value, timestamp: TimeInterval)?

    mutating func value(now: TimeInterval = ProcessInfo.processInfo.systemUptime, query: () -> Value) -> Value {
        if let cached, now - cached.timestamp < 30 { return cached.value }
        let value = query()
        cached = (value, now)
        return value
    }

    mutating func invalidate() { cached = nil }
}
