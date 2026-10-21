import Foundation
import CoreFoundation

/// Reads only Grok Bot's active-account marker and its own aggregate usage cache.
/// No cookies, tokens, transcripts, model requests or billing mutations are used.
enum GrokUsageSource {
    static let source = L10n.text("usage.grok.bot.official.local.usage.cache.read")

    static func fetch() async throws -> AIUsageSnapshot {
        try ProviderLoginConsent().require(.grok)
        if let live = try await GrokBuildUsageSource.fetch() { return live }
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Grok Bot/sand-client-persistence", isDirectory: true)
        return try await Task.detached(priority: .utility) { try read(from: directory) }.value
    }

    static func read(from directory: URL, now: Date = Date()) throws -> AIUsageSnapshot {
        let markerURL = directory.appendingPathComponent(filename(for: "sand.client.slice.client-meta.account-slot"))
        let bytes: Data
        do { bytes = try BoundedFile.read(markerURL, maximum: 256_000) }
        catch let error as POSIXError where error.code == .ENOENT { throw AIUsageError.signedOut }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            throw AIUsageError.signedOut
        }
        catch { throw AIUsageError.unavailable(L10n.text("usage.could.not.read.the.current.grok.bot")) }
        guard bytes.count <= 256_000,
              let marker = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              number(marker["schemaVersion"]) == 1 else {
            throw AIUsageError.unavailable(L10n.text("usage.the.grok.bot.current.account.marker.format"))
        }
        if marker["value"] is NSNull || (marker["value"] as? String) == "" { throw AIUsageError.signedOut }
        guard let slot = marker["value"] as? String, slot.utf8.count <= 512,
              let escaped = slot.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")) else {
            throw AIUsageError.unavailable(L10n.text("usage.the.grok.bot.current.account.marker.format"))
        }
        let key = "sand.client.slice.account.\(escaped).weekly-usage.cache"
        do { return try parse(object(at: directory.appendingPathComponent(filename(for: key))), now: now) }
        catch {
            throw AIUsageError.configuredAccountUnavailable(L10n.text("usage.the.grok.bot.account.is.configured.but"), source: source)
        }
    }

    static func parse(_ response: [String: Any], now: Date = Date()) throws -> AIUsageSnapshot {
        guard number(response["schemaVersion"]) == 2,
              let value = response["value"] as? [String: Any],
              value["kind"] as? String == "present",
              let reading = value["reading"] as? [String: Any],
              let usage = reading["usage"] as? [String: Any],
              let used = number(usage["percentUsed"]), used >= 0,
              let readAt = milliseconds(reading["readAtMs"]),
              readAt <= now.addingTimeInterval(300),
              let expiresAt = milliseconds(value["expiresAtMs"]), expiresAt >= readAt else {
            throw AIUsageError.unavailable(L10n.text("usage.the.grok.bot.local.usage.cache.is"))
        }
        let included = usage["hasNonZeroIncludedLimit"] as? Bool == true
        let remaining: Double? = included ? max(0, min(100, 100 - used)) : nil
        let teamSeat = usage["isTeamSeat"] as? Bool == true
        var windows = [AIUsageWindow(id: "grok.weekly", title: teamSeat ? L10n.text("usage.team.weekly") : L10n.text("quota.weekly"),
                                     remainingPercent: remaining, resetsAt: milliseconds(usage["nextResetMs"]))]
        if let onDemand = usage["onDemand"] as? [String: Any],
           let spent = number(onDemand["usedCents"]), spent >= 0,
           let limit = number(onDemand["limitCents"]), limit > 0 {
            windows.append(AIUsageWindow(id: "grok.additional", title: L10n.text("usage.extra.usage.limit"),
                                         remainingPercent: max(0, min(100, 100 - spent / limit * 100)), resetsAt: nil))
        }
        let stale = now >= expiresAt
        let freshness = stale ? L10n.text("usage.the.cache.has.expired.open.account.usage") : L10n.text("usage.loaded.the.latest.local.cache.written.by")
        let status = freshness + L10n.text("usage.this.is.the.current.account.s.shared")
        let plan = (usage["grokPlanLabel"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        return AIUsageSnapshot(provider: .grok, plan: plan, windows: windows, isConnected: true,
                               status: status, source: source, updatedAt: readAt, expiresAt: expiresAt)
    }

    /// Grok Bot persists keys as unpadded, lower-case RFC 4648 base32 filenames.
    static func filename(for key: String) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567".utf8)
        var output: [UInt8] = []
        var buffer: UInt32 = 0
        var bits = 0
        for byte in key.utf8 {
            buffer = (buffer << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                output.append(alphabet[Int((buffer >> bits) & 31)])
            }
            buffer &= (1 << bits) - 1
        }
        if bits > 0 { output.append(alphabet[Int((buffer << (5 - bits)) & 31)]) }
        return String(decoding: output, as: UTF8.self) + ".blob"
    }

    private static func object(at url: URL) throws -> [String: Any] {
        guard let data = try? BoundedFile.read(url, maximum: 256_000),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIUsageError.unavailable(L10n.text("usage.no.readable.grok.bot.usage.cache.was"))
        }
        return object
    }
    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }
    private static func milliseconds(_ value: Any?) -> Date? {
        guard let value = number(value), value > 0, value <= 253_402_300_799_000 else { return nil }
        return Date(timeIntervalSince1970: value / 1000)
    }
}
