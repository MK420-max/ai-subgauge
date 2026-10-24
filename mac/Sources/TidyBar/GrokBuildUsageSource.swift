import CoreFoundation
import Darwin
import Foundation
import OSLog

/// First-party account credits only. Never invokes Grok, a prompt, or a model endpoint.
enum GrokBuildUsageSource {
    static let source = L10n.text("error.grok.build.official.account.usage.api")
    private static let endpoint = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!

    struct Credential {
        fileprivate let token: String
        fileprivate let userID: String
        fileprivate let expiresAt: Date
        fileprivate let clientID: String
        fileprivate let canRefresh: Bool
    }

    /// Missing/non-first-party login returns nil, so the caller may use the Bot's labelled cache.
    static func fetch() async throws -> AIUsageSnapshot? {
        try ProviderLoginConsent().require(.grok)
        let authURL = try credentialURL()
        guard let credential = try readCredential(at: authURL, allowExpired: true) else { return nil }
        do { return try await fetchAuthenticated(credential, authURL: authURL) }
        catch is CancellationError { throw CancellationError() }
        catch {
            if Task.isCancelled { throw CancellationError() }
            let message = error is AIUsageError ? error.localizedDescription : L10n.text("error.grok.official.account.usage.is.temporarily.unavailable")
            throw AIUsageError.configuredAccountUnavailable(message, source: source)
        }
    }

    private static func fetchAuthenticated(_ initial: Credential, authURL: URL) async throws -> AIUsageSnapshot {
        let credential = try await credentialForBilling(initial, authURL: authURL)
        let blocker = GrokBuildRedirectBlocker()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration, delegate: blocker, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await fetchBilling(credential) { try await loadBilling($0, session: session) }
    }

    /// Refresh within 15 seconds of expiry; dependencies keep tests offline.
    static func credentialForBilling(_ initial: Credential, authURL: URL, now: Date = Date(),
        cli: () -> URL? = { installedCLI() },
        renew: (URL, URL, Credential) async throws -> Credential = { try await refreshCredential(executable: $0, authURL: $1, expected: $2) }
    ) async throws -> Credential {
        guard initial.expiresAt <= now.addingTimeInterval(15) else { return initial }
        guard initial.canRefresh, let executable = cli() else {
            throw AIUsageError.unavailable(L10n.text("error.your.grok.login.has.expired.reconnect.grok"))
        }
        return try await renew(executable, authURL, initial)
    }

    enum RenewalEvent {
        case refreshed(expiresIn: Int), failed
        var message: String {
            switch self {
            case .refreshed(let seconds): return "grok token refreshed, expires in \(seconds)s"
            case .failed: return "grok token refresh failed; reconnect or retry"
            }
        }
        static func log(_ event: Self) {
            Logger(subsystem: AppIdentifiers.bundleID, category: "grok-renewal").info("\(event.message, privacy: .public)")
        }
    }

    static func loadBilling(_ request: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 1_048_576 else { throw AIUsageError.invalidResponse }
            data.append(byte)
        }
        return (data, response)
    }

    /// Retry a transient billing outage once; auth failures never start a new login.
    static func fetchBilling(_ credential: Credential, load: (URLRequest) async throws -> (Data, URLResponse)) async throws -> AIUsageSnapshot {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("Bearer " + credential.token, forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        request.setValue(credential.userID, forHTTPHeaderField: "x-userid")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var retried = false
        while true {
            try Task.checkCancellation()
            let data: Data
            let response: URLResponse
            do { (data, response) = try await load(request) }
            catch is CancellationError { throw CancellationError() }
            catch {
                if Task.isCancelled { throw CancellationError() }
                throw AIUsageError.unavailable(L10n.text("error.could.not.read.grok.build.usage.check"))
            }
            try Task.checkCancellation()
            guard data.count <= 1_048_576 else { throw AIUsageError.invalidResponse }
            guard let http = response as? HTTPURLResponse, http.url == endpoint else {
                throw AIUsageError.unavailable(L10n.text("error.the.grok.build.usage.service.returned.an"))
            }
            if [502, 503, 504].contains(http.statusCode) {
                if !retried {
                    retried = true
                    try await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }
                throw AIUsageError.unavailable(L10n.text("error.the.official.grok.usage.service.is.temporarily", http.statusCode))
            }
            guard http.statusCode == 200 else {
                if [401, 403].contains(http.statusCode) {
                    throw AIUsageError.unavailable(L10n.text("error.your.grok.build.login.has.expired.or"))
                }
                throw AIUsageError.unavailable(L10n.text("error.the.grok.build.usage.service.is.temporarily", http.statusCode))
            }
            return try parse(data)
        }
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> AIUsageSnapshot {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = object["config"] as? [String: Any] else { throw AIUsageError.invalidResponse }
        var used: Double?
        if let raw = config["creditUsagePercent"], !(raw is NSNull) {
            guard let number = number(raw), number >= 0 else { throw AIUsageError.invalidResponse }
            used = number
        }
        let period = config["currentPeriod"] as? [String: Any]
        let type = period?["type"] as? String
        let title: String
        switch type {
        case "USAGE_PERIOD_TYPE_WEEKLY": title = L10n.text("quota.weekly")
        case "USAGE_PERIOD_TYPE_MONTHLY": title = L10n.text("quota.monthly")
        default: title = L10n.text("error.account.quota")
        }
        var reset: Date?
        if let value = period?["end"], !(value is NSNull) {
            guard let text = value as? String, let date = date(text) else { throw AIUsageError.invalidResponse }
            reset = date
        }
        var balance: String?
        if let raw = config["prepaidBalance"], !(raw is NSNull) {
            guard let cents = raw as? [String: Any] else { throw AIUsageError.invalidResponse }
            // Official proto3 Cent omits its zero-valued val field: {} is exactly zero.
            let value: Double
            if let rawValue = cents["val"] {
                guard let amount = number(rawValue), amount >= 0, amount.rounded() == amount,
                      amount <= 9_007_199_254_740_991 else { throw AIUsageError.invalidResponse }
                value = amount
            } else { value = 0 }
            balance = String(format: "US$ %.2f", locale: Locale(identifier: "en_US_POSIX"), value / 100)
        }
        let unified = (config["isUnifiedBillingUser"] as? NSNumber).flatMap {
            CFGetTypeID($0) == CFBooleanGetTypeID() ? $0.boolValue : nil
        }
        let status = unified == true ? L10n.text("error.official.shared.account.quota.loaded.specific.model") : L10n.text("error.official.build.account.quota.loaded.the.service")
        return AIUsageSnapshot(provider: .grok, plan: object["subscription_tier"] as? String,
            balance: balance, windows: [AIUsageWindow(id: "grok-build.included", title: title,
                remainingPercent: used.map { max(0, min(100, 100 - $0)) }, resetsAt: reset)],
            isConnected: true, status: status, source: source, updatedAt: now,
            expiresAt: now.addingTimeInterval(300))
    }

    /// Parses only the official scoped OAuth store. Secrets remain in memory and never enter errors.
    static func credential(from data: Data, now: Date = Date(), allowExpired: Bool = false) throws -> Credential? {
        guard let store = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIUsageError.unavailable(L10n.text("error.the.grok.build.login.file.is.corrupt"))
        }
        var candidates: [Credential] = []
        for (scope, raw) in store {
            guard let value = raw as? [String: Any] else {
                throw AIUsageError.unavailable(L10n.text("error.the.grok.build.login.file.format.is"))
            }
            guard let mode = value["auth_mode"] as? String, ["oidc", "external"].contains(mode),
                  let issuer = value["oidc_issuer"] as? String,
                  ["https://auth.x.ai", "https://auth.x.ai/"].contains(issuer) else { continue }
            guard let clientID = value["oidc_client_id"] as? String, !clientID.isEmpty,
                  scope == "https://auth.x.ai::" + clientID,
                  let token = value["key"] as? String, validHeader(token, maximum: 32768),
                  let userID = value["user_id"] as? String, validHeader(userID, maximum: 256),
                  let created = value["create_time"] as? String, let createdAt = date(created),
                  createdAt <= now.addingTimeInterval(300) else {
                throw AIUsageError.unavailable(L10n.text("error.grok.build.login.fields.are.incomplete.sign"))
            }
            let expiresAt: Date
            if let raw = value["expires_at"], !(raw is NSNull) {
                guard let text = raw as? String, let date = date(text) else {
                    throw AIUsageError.unavailable(L10n.text("error.the.grok.build.login.expiry.format.is"))
                }
                expiresAt = date
            } else { expiresAt = createdAt.addingTimeInterval(30 * 86400) }
            guard allowExpired || expiresAt > now.addingTimeInterval(15) else {
                throw AIUsageError.unavailable(L10n.text("error.your.grok.build.login.has.expired.sign"))
            }
            let refresh = value["refresh_token"] as? String
            candidates.append(Credential(token: token, userID: userID, expiresAt: expiresAt, clientID: clientID,
                canRefresh: mode == "oidc" && refresh.map { validHeader($0, maximum: 32768) } == true))
        }
        guard Set(candidates.map(\.userID)).count <= 1 else {
            throw AIUsageError.unavailable(L10n.text("error.the.grok.build.login.contains.multiple.accounts"))
        }
        return candidates.max { $0.expiresAt < $1.expiresAt }
    }

    private static func credentialURL() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let path: String
        if let override = environment["GROK_AUTH_PATH"], !override.isEmpty { path = override }
        else if let home = environment["GROK_HOME"], !home.isEmpty { path = (home as NSString).appendingPathComponent("auth.json") }
        else { path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok/auth.json").path }
        guard (path as NSString).isAbsolutePath else {
            throw AIUsageError.unavailable(L10n.text("error.the.grok.build.login.path.must.be"))
        }
        return URL(fileURLWithPath: path)
    }

    static func readCredential(at url: URL, allowExpired: Bool = false) throws -> Credential? {
        guard let data = try CredentialFiles.read(at: url, provider: "Grok") else { return nil }
        return try credential(from: data, allowExpired: allowExpired)
    }

    private static func installedCLI() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [home.appendingPathComponent(".local/bin/grok"), URL(fileURLWithPath: "/opt/homebrew/bin/grok"),
            URL(fileURLWithPath: "/usr/local/bin/grok"), home.appendingPathComponent(".grok/bin/grok")]
        let tools = home.appendingPathComponent("Library/Application Support/com.mike.aisubgauge/Tools")
        let managed = ((try? FileManager.default.contentsOfDirectory(at: tools, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("grok-") && $0.lastPathComponent.hasSuffix("-macos-aarch64") }
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
        return (candidates + managed).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// The official ACP handler only runs get_valid_token; it does not invoke authenticate or a prompt.
    static func refreshCredential(executable: URL, authURL: URL, expected: Credential, timeout: TimeInterval = 20,
        onLaunch: ((pid_t) -> Void)? = nil, verifyCLI: ((URL) throws -> Void)? = nil,
        log: @escaping (RenewalEvent) -> Void = RenewalEvent.log
    ) async throws -> Credential {
        try Task.checkCancellation()
        let refreshed = try await GrokCredentialRenewals.shared.refresh(at: authURL.standardizedFileURL) { epoch in
            do {
                return try await performRefresh(executable: executable, authURL: authURL, expected: expected,
                    timeout: timeout, epoch: epoch, onLaunch: onLaunch, verifyCLI: verifyCLI, log: log)
            } catch {
                log(.failed)
                throw error
            }
        }
        guard refreshed.userID == expected.userID, refreshed.clientID == expected.clientID else {
            throw AIUsageError.unavailable(L10n.text("error.the.current.grok.account.has.changed.reconnect"))
        }
        return refreshed
    }

    private static func performRefresh(executable: URL, authURL: URL, expected: Credential, timeout: TimeInterval,
        epoch: GrokRenewalEpoch,
        onLaunch: ((pid_t) -> Void)?, verifyCLI: ((URL) throws -> Void)?, log: @escaping (RenewalEvent) -> Void
    ) async throws -> Credential {
        guard expected.canRefresh else { throw AIUsageError.unavailable(L10n.text("error.your.grok.login.cannot.be.renewed.automatically")) }
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) {
            guard let current = try readCredential(at: authURL, allowExpired: true), current.canRefresh,
                  current.userID == expected.userID, current.clientID == expected.clientID else {
                throw AIUsageError.unavailable(L10n.text("error.the.current.grok.account.has.changed.reconnect"))
            }
            // A preceding request may already have renewed this account on disk.
            if current.expiresAt > Date().addingTimeInterval(15) { return current }
            let prepared = try GrokCLITrust.prepare(executable, verifyCLI: verifyCLI)
            defer { prepared.cleanup() }
            let refreshedCLI = Result {
                try refreshWithCLI(executable: prepared.executable, authURL: authURL, clientID: expected.clientID,
                    timeout: timeout, epoch: epoch, onLaunch: onLaunch)
            }
            try epoch.finish(at: authURL)
            try refreshedCLI.get()
            guard let refreshed = try readCredential(at: authURL), refreshed.userID == expected.userID,
                  refreshed.clientID == expected.clientID else {
                throw AIUsageError.unavailable(L10n.text("error.grok.renewal.did.not.return.a.valid"))
            }
            log(.refreshed(expiresIn: max(0, Int(refreshed.expiresAt.timeIntervalSinceNow))))
            return refreshed
        }
        return try await withTaskCancellationHandler {
            let refreshed = try await worker.value
            try Task.checkCancellation()
            return refreshed
        } onCancel: { worker.cancel() }
    }

    private static func refreshWithCLI(executable: URL, authURL: URL, clientID: String, timeout: TimeInterval,
        epoch: GrokRenewalEpoch, onLaunch: ((pid_t) -> Void)?) throws {
        try Task.checkCancellation()
        let folder = executable.deletingLastPathComponent()
        let input = Pipe(), output = Pipe()
        var environment = CLIEnvironment.grok()
        environment["GROK_HOME"] = folder.path; environment["GROK_AUTH_PATH"] = authURL.path
        environment["GROK_OAUTH2_CLIENT_ID"] = clientID
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETFL, O_NONBLOCK) == 0 else { throw POSIXError(.EIO) }
        let pid: pid_t
        do {
            pid = try epoch.launch {
                let process = try CLIProcess(executable: executable, arguments: ["agent", "stdio"], environment: environment, directory: folder,
                    input: input.fileHandleForReading.fileDescriptor, output: output.fileHandleForWriting.fileDescriptor)
                return GrokRenewalEpoch.Child(pid: process.processIdentifier,
                    stop: { _ in try process.stopRecordedChild() }, cleanup: { try process.stopRecordedChild() })
            }
        } catch { throw AIUsageError.unavailable(L10n.text("error.could.not.start.the.official.grok.renewal")) }
        try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
        defer {
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
        }
        onLaunch?(pid)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var buffer = Data(), total = 0
        func request(_ id: Int, _ method: String, _ params: [String: Any]) throws {
            try Task.checkCancellation()
            var message = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            message.append(10)
            var sent = 0
            while sent < message.count {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw AIUsageError.timeout }
                let count = try epoch.withCurrent {
                    message.withUnsafeBytes { bytes in
                        Darwin.write(input.fileHandleForWriting.fileDescriptor, bytes.baseAddress!.advanced(by: sent), message.count - sent)
                    }
                }
                if count > 0 { sent += count }
                else if count < 0 && [EAGAIN, EINTR].contains(errno) {
                    var writable = pollfd(fd: input.fileHandleForWriting.fileDescriptor, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&writable, 1, 50)
                } else { throw POSIXError(.EIO) }
            }
            while ProcessInfo.processInfo.systemUptime < deadline {
                try Task.checkCancellation()
                if let end = buffer.firstIndex(of: 10) {
                    let line = buffer.prefix(upTo: end); buffer.removeSubrange(...end)
                    guard let result = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          (result["id"] as? NSNumber)?.intValue == id else { continue }
                    guard result["error"] == nil, result["result"] != nil else {
                        throw AIUsageError.unavailable(L10n.text("error.grok.automatic.renewal.failed.reconnect.the.account"))
                    }
                    return // Deliberately discard the returned bearer; reread only the validated official store.
                }
                var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
                if poll(&descriptor, 1, 100) <= 0 { continue }
                try Task.checkCancellation()
                var bytes = [UInt8](repeating: 0, count: 8192)
                let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
                guard count > 0 else { throw AIUsageError.unavailable(L10n.text("error.the.grok.renewal.api.closed.reconnect.the")) }
                total += count
                guard total <= 1_048_576 else { throw AIUsageError.unavailable(L10n.text("error.the.grok.renewal.response.was.too.large")) }
                buffer.append(contentsOf: bytes.prefix(count))
            }
            throw AIUsageError.unavailable(L10n.text("error.grok.automatic.renewal.timed.out.refresh.later"))
        }
        try request(1, "initialize", ["protocolVersion": 1, "clientCapabilities": [:]])
        try request(2, "_x.ai/auth/getBearerToken", [:])
    }

    private static func validHeader(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum && value.utf8.allSatisfy { (0x21...0x7e).contains($0) }
    }
    private static func number(_ value: Any) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
    private static func date(_ value: String) -> Date? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

private final class GrokBuildRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Revocation fences new work; active work and cleanup never hold the state lock.
final class GrokRenewalEpoch: @unchecked Sendable {
    struct Child {
        let pid: pid_t
        let stop: (pid_t) throws -> Void
        let cleanup: () throws -> Void
    }
    private let lock = NSLock()
    private let cleanupLock = NSLock()
    private let quiesced = DispatchSemaphore(value: 0)
    private let restore: @Sendable (URL) throws -> Void
    private var current = true
    private var active = 0
    private var child: Child?
    private var failure: Error?
    var cleanupFailure: Error? { lock.withLock { failure } }

    init(restore: @escaping @Sendable (URL) throws -> Void = { try CredentialFiles.restrictAfterRenewal(at: $0) }) {
        self.restore = restore
    }

    func withCurrent<T>(_ operation: () throws -> T) throws -> T {
        try lock.withLock {
            guard current else { throw CancellationError() }
            active += 1
        }
        defer {
            lock.withLock {
                active -= 1
                if !current && active == 0 { quiesced.signal() }
            }
        }
        return try operation()
    }

    func launch(_ spawn: () throws -> Child) throws -> pid_t {
        try withCurrent {
            let launched = try spawn()
            lock.withLock { child = launched }
            return launched.pid
        }
    }

    func finish(at url: URL) throws {
        do {
            try withCurrent {
                try cleanupLock.withLock {
                    let recorded = lock.withLock { child }
                    try recorded?.cleanup()
                    lock.withLock { child = nil }
                    try withCurrent { try restore(url) }
                }
            }
        } catch {
            if !(error is CancellationError) {
                lock.withLock { current = false; failure = error }
            }
            throw error
        }
    }

    func revoke() { lock.withLock { current = false } }

    func abandon(at url: URL) throws {
        revoke()
        // Stop an already recorded writer even if another epoch operation is stuck.
        // Serialize against finish(), which may still be stopping the same child.
        try? cleanupLock.withLock { try stopChild() }
        // The actor bounds callers with cleanupWaitTimeout and keeps the store locked.
        // Continue cleanup after that deadline: an in-flight spawn may record its child late.
        while lock.withLock({ active != 0 }) {
            quiesced.wait()
        }
        try cleanupLock.withLock {
            // A failed first stop, or a late spawn, still requires a confirmed stop.
            do { try stopChild() }
            catch { try stopChild() }
            // Never restore or admit a fresh writer after an unconfirmed stop.
            do { try restore(url) }
            catch { try restore(url) }
        }
    }

    private func stopChild() throws {
        guard let recorded = lock.withLock({ child }) else { return }
        try recorded.stop(recorded.pid)
        lock.withLock {
            if child?.pid == recorded.pid { child = nil }
        }
    }
}

/// One renewal per official store; each caller owns only its continuation.
actor GrokCredentialRenewals {
    static let shared = GrokCredentialRenewals()
    private let cancellationCleanupTimeout: UInt64
    private let cleanupWaitTimeout: UInt64
    private let restore: @Sendable (URL) throws -> Void
    typealias Operation = (GrokRenewalEpoch) async throws -> GrokBuildUsageSource.Credential
    struct Cancellation {
        let waiter: CheckedContinuation<GrokBuildUsageSource.Credential, Error>
        let timeout: Task<Void, Never>
    }
    struct Entry {
        let id: UUID
        let task: Task<Void, Never>
        let epoch: GrokRenewalEpoch
        var waiters: [UUID: CheckedContinuation<GrokBuildUsageSource.Credential, Error>]
        var cancellations: [UUID: Cancellation] = [:]
        var queued: [UUID: QueuedWaiter] = [:]
        var abandoned = false
        var cleanupError: Error?
        var abandonmentTimeout: Task<Void, Never>?
    }
    struct QueuedWaiter {
        let waiter: CheckedContinuation<GrokBuildUsageSource.Credential, Error>
        let operation: Operation
        let timeout: Task<Void, Never>
    }
    private(set) var pending: [URL: Entry] = [:]

    init(cancellationCleanupTimeout: UInt64 = 3_000_000_000,
        cleanupWaitTimeout: UInt64 = 20_000_000_000,
        restore: @escaping @Sendable (URL) throws -> Void = { try CredentialFiles.restrictAfterRenewal(at: $0) }
    ) {
        self.cancellationCleanupTimeout = cancellationCleanupTimeout
        self.cleanupWaitTimeout = cleanupWaitTimeout
        self.restore = restore
    }

    func refresh(at url: URL, operation: @escaping Operation) async throws -> GrokBuildUsageSource.Credential {
        try Task.checkCancellation()
        let waiterID = UUID()
        let result: GrokBuildUsageSource.Credential = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let error = pending[url]?.cleanupError {
                    continuation.resume(throwing: error)
                } else if let entry = pending[url], entry.task.isCancelled {
                    let entryID = entry.id
                    let timeout = Task {
                        do { try await Task.sleep(nanoseconds: cleanupWaitTimeout) }
                        catch { return }
                        expireQueued(at: url, entryID: entryID, waiterID: waiterID)
                    }
                    pending[url]?.queued[waiterID] = QueuedWaiter(waiter: continuation, operation: operation, timeout: timeout)
                } else if pending[url] == nil {
                    start(at: url, waiters: [waiterID: continuation], operation: operation)
                } else {
                    pending[url]?.waiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(at: url, id: waiterID) }
        }
        try Task.checkCancellation()
        return result
    }

    private func start(at url: URL, waiters: [UUID: CheckedContinuation<GrokBuildUsageSource.Credential, Error>],
        operation: @escaping Operation
    ) {
        let id = UUID(), epoch = GrokRenewalEpoch(restore: restore)
        let task = Task {
            let result: Result<GrokBuildUsageSource.Credential, Error>
            do { result = .success(try await operation(epoch)) }
            catch { result = .failure(error) }
            finish(at: url, id: id, result: result)
        }
        pending[url] = Entry(id: id, task: task, epoch: epoch, waiters: waiters)
    }

    private func cancelWaiter(at url: URL, id: UUID) {
        if let queued = pending[url]?.queued.removeValue(forKey: id) {
            queued.timeout.cancel()
            queued.waiter.resume(throwing: CancellationError())
            return
        }
        guard let waiter = pending[url]?.waiters.removeValue(forKey: id) else { return }
        guard let entry = pending[url], entry.waiters.isEmpty else {
            waiter.resume(throwing: CancellationError())
            return
        }
        entry.task.cancel()
        let entryID = entry.id
        let timeout = Task {
            do { try await Task.sleep(nanoseconds: cancellationCleanupTimeout) }
            catch { return }
            finishCancellation(at: url, entryID: entryID, waiterID: id)
            abandon(at: url, id: entryID)
        }
        pending[url]?.cancellations[id] = Cancellation(waiter: waiter, timeout: timeout)
    }

    private func expireQueued(at url: URL, entryID: UUID, waiterID: UUID) {
        guard pending[url]?.id == entryID,
              let queued = pending[url]?.queued.removeValue(forKey: waiterID) else { return }
        queued.waiter.resume(throwing: AIUsageError.timeout)
    }

    private func finishCancellation(at url: URL, entryID: UUID, waiterID: UUID) {
        guard pending[url]?.id == entryID,
              let cancellation = pending[url]?.cancellations.removeValue(forKey: waiterID) else { return }
        cancellation.waiter.resume(throwing: CancellationError())
    }

    private func abandon(at url: URL, id: UUID) {
        guard let entry = pending[url], entry.id == id, !entry.abandoned else { return }
        pending[url]?.abandoned = true
        let epoch = entry.epoch
        epoch.revoke()
        // Also bound a stuck stop/restore hook, without waiting for the blocking worker to return.
        pending[url]?.abandonmentTimeout = Task {
            do { try await Task.sleep(nanoseconds: cleanupWaitTimeout) }
            catch { return }
            finishAbandonment(at: url, id: id, result: .failure(AIUsageError.timeout))
        }
        // Capture only the Sendable epoch, never the Entry or its continuations.
        Task.detached(priority: .utility) {
            let result = Result { try epoch.abandon(at: url) }
            await self.finishAbandonment(at: url, id: id, result: result)
        }
    }

    private func finishAbandonment(at url: URL, id: UUID, result: Result<Void, Error>) {
        guard let entry = pending[url], entry.id == id, entry.cleanupError == nil else { return }
        entry.abandonmentTimeout?.cancel()
        switch result {
        case .success:
            pending[url] = nil
            startQueued(at: url, entry: entry)
        case .failure(let error):
            // Fail closed for later callers too; late finish() cannot reopen an unsafe store.
            pending[url]?.cleanupError = error
            pending[url]?.queued.removeAll()
            for queued in entry.queued.values {
                queued.timeout.cancel()
                queued.waiter.resume(throwing: error)
            }
        }
    }

    private func startQueued(at url: URL, entry: Entry) {
        for queued in entry.queued.values { queued.timeout.cancel() }
        if let next = entry.queued.values.first {
            start(at: url, waiters: entry.queued.mapValues(\.waiter), operation: next.operation)
        }
    }

    private func finish(at url: URL, id: UUID, result: Result<GrokBuildUsageSource.Credential, Error>) {
        guard let entry = pending[url], entry.id == id, !entry.abandoned else { return }
        if let error = entry.epoch.cleanupFailure {
            pending[url]?.cleanupError = error
            for cancellation in entry.cancellations.values {
                cancellation.timeout.cancel()
                cancellation.waiter.resume(throwing: CancellationError())
            }
            pending[url]?.cancellations.removeAll()
            for waiter in entry.waiters.values { waiter.resume(throwing: error) }
            pending[url]?.waiters.removeAll()
            for queued in entry.queued.values {
                queued.timeout.cancel()
                queued.waiter.resume(throwing: error)
            }
            pending[url]?.queued.removeAll()
            // Fail callers promptly, then compensate stop/restore off the actor.
            // cleanupError retains the store lock even if this cleanup completes late.
            abandon(at: url, id: id)
            return
        }
        pending[url] = nil
        // Both completion paths take ownership on this actor, so each waiter resumes once.
        for cancellation in entry.cancellations.values {
            cancellation.timeout.cancel()
            cancellation.waiter.resume(throwing: CancellationError())
        }
        for waiter in entry.waiters.values { waiter.resume(with: result) }
        startQueued(at: url, entry: entry)
    }
}
