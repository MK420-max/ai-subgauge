import Combine
import Darwin
import Foundation

enum AIUsageProvider: String, CaseIterable, Identifiable {
    case codex, claude, grok
    case openaiAPI, anthropicAPI, geminiAPI, xaiAPI, deepseekAPI, openrouterAPI, kimiAPI, minimaxAPI
    var id: String { rawValue }
    var title: String {
        switch self {
        case .codex: return L10n.text("provider.codex")
        case .claude: return L10n.text("provider.claude")
        case .grok: return L10n.text("provider.grok")
        case .openaiAPI: return L10n.text("provider.openaiAPI")
        case .anthropicAPI: return L10n.text("provider.anthropicAPI")
        case .geminiAPI: return L10n.text("provider.geminiAPI")
        case .xaiAPI: return L10n.text("provider.xaiAPI")
        case .deepseekAPI: return L10n.text("provider.deepseekAPI")
        case .openrouterAPI: return L10n.text("provider.openrouterAPI")
        case .kimiAPI: return L10n.text("provider.kimiAPI")
        case .minimaxAPI: return L10n.text("provider.minimaxAPI")
        }
    }
    var initialSource: String {
        switch self {
        case .codex: return CodexUsageSource.source
        case .claude: return ClaudeUsageSource.source
        case .grok: return L10n.text("usage.grok.bot.local.api")
        default: return title + L10n.text("usage.official.api")
        }
    }
}

struct AIUsageWindow: Identifiable, Equatable {
    var id: String
    var title: String
    var remainingPercent: Double?
    var resetsAt: Date?
}

struct AIUsageSnapshot: Identifiable, Equatable {
    var provider: AIUsageProvider
    var id: AIUsageProvider { provider }
    var plan: String? = nil
    var balance: String? = nil
    var windows: [AIUsageWindow] = []
    var isConnected = false
    var status: String
    var source: String
    var error: String? = nil
    var updatedAt: Date? = nil
    var expiresAt: Date? = nil
    var wasConfigured = false
}

enum AIUsageError: LocalizedError {
    case unavailable(String)
    case unsafeCredential(String)
    case configuredAccountUnavailable(String, source: String? = nil)
    case signedOut
    case invalidResponse
    case timeout
    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .unsafeCredential(let message), .configuredAccountUnavailable(let message, _): return message
        case .signedOut: return L10n.text("usage.you.are.not.signed.in")
        case .invalidResponse: return L10n.text("usage.the.usage.service.returned.an.unsupported.data")
        case .timeout: return L10n.text("usage.reading.usage.timed.out.please.try.again")
        }
    }
}

private func usageNumber(_ value: Any?) -> Double? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
    return number.doubleValue
}

private func remainingUsage(_ value: Any?) -> Double? {
    guard let used = usageNumber(value), used >= 0 else { return nil }
    return max(0, min(100, 100 - used))
}

private func usageDate(_ value: Any?) -> Date? {
    if let seconds = usageNumber(value), seconds > 0 { return Date(timeIntervalSince1970: seconds) }
    guard let value = value as? String else { return nil }
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return parser.date(from: value) ?? ISO8601DateFormatter().date(from: value)
}

enum CodexUsageSource {
    static let source = L10n.text("usage.codex.official.local.api")

    static func fetch() async throws -> AIUsageSnapshot {
        try ProviderLoginConsent().require(.codex)
        let environment = ProcessInfo.processInfo.environment
        let home = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        _ = try CredentialFiles.read(at: home.appendingPathComponent("auth.json"), provider: "Codex")
        return try await fetch(executable: nil)
    }

    static func fetch(executable: URL?, timeout: TimeInterval = 20) async throws -> AIUsageSnapshot {
        try Task.checkCancellation()
        let reader = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            if let executable { return try readFromCLI(executable: executable, timeout: timeout) }
            return try fetchBlocking(timeout: timeout)
        }
        return try await withTaskCancellationHandler {
            let snapshot = try await reader.value
            try Task.checkCancellation()
            return snapshot
        } onCancel: {
            reader.cancel()
        }
    }

    static func parse(_ response: [String: Any], plan: String? = nil, now: Date = Date()) throws -> AIUsageSnapshot {
        let buckets = response["rateLimitsByLimitId"] as? [String: [String: Any]]
            ?? (response["rateLimits"] as? [String: Any]).map { ["codex": $0] }
        guard let buckets, !buckets.isEmpty else { throw AIUsageError.invalidResponse }
        var snapshot = AIUsageSnapshot(provider: .codex, plan: plan, isConnected: true, status: L10n.text("status.updated"), source: source, updatedAt: now)
        for key in buckets.keys.sorted() {
            guard let bucket = buckets[key] else { continue }
            snapshot.plan = snapshot.plan ?? bucket["planType"] as? String
            if let credits = bucket["credits"] as? [String: Any] {
                if credits["unlimited"] as? Bool == true { snapshot.balance = L10n.text("usage.unlimited") }
                else if credits["hasCredits"] as? Bool == true, let balance = credits["balance"] as? String { snapshot.balance = balance + L10n.text("usage.credits") }
            }
            for name in ["primary", "secondary"] {
                guard let window = bucket[name] as? [String: Any] else { continue }
                let minutes = usageNumber(window["windowDurationMins"])
                let title: String
                switch minutes {
                case 300: title = L10n.text("quota.fiveHours")
                case 10080: title = L10n.text("quota.weekly")
                case .some(let n) where n > 0 && n < Double(Int.max): title = L10n.text("usage.0.minutes", Int(n))
                default: title = name == "primary" ? L10n.text("usage.primary.quota") : L10n.text("usage.secondary.quota")
                }
                snapshot.windows.append(AIUsageWindow(id: key + "." + name, title: buckets.count > 1 ? key + " · " + title : title,
                    remainingPercent: remainingUsage(window["usedPercent"]), resetsAt: usageDate(window["resetsAt"])))
            }
        }
        if snapshot.windows.isEmpty { snapshot.status = L10n.text("usage.account.connected.the.service.has.not.returned") }
        return snapshot
    }

    private static func fetchBlocking(timeout: TimeInterval) throws -> AIUsageSnapshot {
        let prepared = try CodexCLITrust.installed()
        defer { prepared.cleanup() }
        return try readFromCLI(executable: prepared.executable, timeout: timeout, prepared: prepared)
    }

    static func readFromCLI(executable: URL, timeout: TimeInterval = 20, onLaunch: ((pid_t) -> Void)? = nil,
                            prepared: CodexCLITrust.Prepared? = nil) throws -> AIUsageSnapshot {
        try Task.checkCancellation()
        let input = Pipe(), output = Pipe()
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let process: CLIProcess
        do {
            // CLIProcess completes dynamic signature validation before returning. Keep the stdin
            // pipe empty until then, even if another same-UID process sends SIGCONT prematurely.
            process = try CLIProcess(executable: executable,
                arguments: ["app-server", "--listen", "stdio://", "-c", "analytics.enabled=false"],
                environment: CLIEnvironment.codex(), directory: executable.deletingLastPathComponent(),
                input: input.fileHandleForReading.fileDescriptor, output: output.fileHandleForWriting.fileDescriptor,
                beforeSpawn: prepared.map { copy in { try copy.validateBeforeSpawn() } },
                verifySpawned: prepared.map { copy in { try copy.validateSpawned($0) } })
        } catch { throw AIUsageError.unavailable(L10n.text("usage.could.not.start.the.codex.local.usage")) }
        try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
        defer {
            try? input.fileHandleForWriting.close()
            process.abandonBestEffort()
            try? output.fileHandleForReading.close()
        }
        onLaunch?(process.processIdentifier)
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = Data()
        func send(_ message: [String: Any]) throws {
            try Task.checkCancellation()
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        func receive(_ id: Int) throws -> [String: Any] {
            while Date() < deadline {
                try Task.checkCancellation()
                if let lineEnd = buffer.firstIndex(of: 10) {
                    let line = buffer.prefix(upTo: lineEnd)
                    buffer.removeSubrange(...lineEnd)
                    guard let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          (value["id"] as? NSNumber)?.intValue == id else { continue }
                    guard value["error"] == nil, let result = value["result"] as? [String: Any] else {
                        throw AIUsageError.unavailable(L10n.text("usage.codex.could.not.return.usage.check.your"))
                    }
                    return result
                }
                var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
                if poll(&descriptor, 1, 100) <= 0 { continue }
                try Task.checkCancellation()
                var bytes = [UInt8](repeating: 0, count: 8192)
                let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
                guard count > 0 else { throw AIUsageError.unavailable(L10n.text("usage.the.codex.local.api.closed.check.your")) }
                buffer.append(contentsOf: bytes.prefix(count))
                guard buffer.count <= 1_000_000 else { throw AIUsageError.invalidResponse }
            }
            throw AIUsageError.timeout
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "ai_subgauge", "title": AppIdentifiers.name, "version": AppIdentifiers.version]]])
        _ = try receive(1)
        try send(["method": "initialized", "params": [:]])
        try send(["id": 2, "method": "account/read", "params": ["refreshToken": false]])
        let accountResult = try receive(2)
        if accountResult["account"] is NSNull { throw AIUsageError.signedOut }
        let account = accountResult["account"] as? [String: Any]
        guard account?["type"] as? String == "chatgpt" else { throw AIUsageError.unavailable(L10n.text("usage.codex.is.not.signed.in.to.a")) }
        try send(["id": 3, "method": "account/rateLimits/read"])
        return try parse(receive(3), plan: account?["planType"] as? String)
    }
}

enum ClaudeUsageSource {
    static let source = L10n.text("usage.claude.first.party.oauth.usage.api")

    static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 20
        return configuration
    }

    static func fetch() async throws -> AIUsageSnapshot {
        guard ProviderLoginConsent().allows(.claude) else { return try await ClaudeWebConnection.shared.fetch() }
        let token: String
        do { token = try await Task.detached(priority: .utility) { try existingToken() }.value }
        catch let error as AIUsageError {
            if case .unsafeCredential = error { throw error }
            return try await ClaudeWebConnection.shared.fetch()
        }
        let session = URLSession(configuration: sessionConfiguration(), delegate: NoUsageRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await fetch(token: token) { try await loadUsage($0, session: session) }
    }

    static func loadUsage(_ request: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 1_048_576 else { throw AIUsageError.invalidResponse }
            data.append(byte)
        }
        return (data, response)
    }

    static func fetch(token: String, load: (URLRequest) async throws -> (Data, URLResponse)) async throws -> AIUsageSnapshot {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else { throw AIUsageError.invalidResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await load(request)
        guard data.count <= 1_048_576 else { throw AIUsageError.invalidResponse }
        guard let response = response as? HTTPURLResponse, response.url?.host == url.host,
              response.url == url else { throw AIUsageError.invalidResponse }
        guard response.statusCode == 200 else {
            if [401, 403].contains(response.statusCode) { throw AIUsageError.unavailable(L10n.text("usage.your.claude.login.has.expired.or.lacks")) }
            throw AIUsageError.unavailable(L10n.text("usage.the.claude.usage.service.is.temporarily.unavailable", response.statusCode))
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIUsageError.invalidResponse }
        return try parse(object)
    }

    static func parse(_ response: [String: Any], now: Date = Date()) throws -> AIUsageSnapshot {
        let names = [("five_hour", L10n.text("quota.fiveHours")), ("seven_day", L10n.text("quota.weekly")), ("seven_day_opus", L10n.text("usage.opus.weekly")), ("seven_day_sonnet", L10n.text("usage.sonnet.weekly"))]
        let windows = names.compactMap { key, title -> AIUsageWindow? in
            guard let value = response[key] as? [String: Any] else { return nil }
            return AIUsageWindow(id: key, title: title, remainingPercent: remainingUsage(value["utilization"]), resetsAt: usageDate(value["resets_at"]))
        }
        guard !windows.isEmpty else { throw AIUsageError.invalidResponse }
        return AIUsageSnapshot(provider: .claude, windows: windows, isConnected: true, status: L10n.text("status.updated"), source: source, updatedAt: now)
    }

    private static func token(from data: Data) -> String? {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = value["claudeAiOauth"] as? [String: Any], let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        return token
    }

    static func existingToken(environment: [String: String] = ProcessInfo.processInfo.environment,
                              file: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")) throws -> String {
        if let value = environment["CLAUDE_CODE_OAUTH_TOKEN"], !value.isEmpty { return value }
        if let value = try token(at: file) { return value }
        throw AIUsageError.unavailable(L10n.text("usage.claude.code.is.not.connected.sign.in"))
    }

    static func validateCredentialFile(_ metadata: stat) throws {
        try CredentialFiles.validate(metadata, provider: "Claude")
    }

    static func token(at file: URL) throws -> String? {
        guard let data = try CredentialFiles.read(at: file, provider: "Claude") else { return nil }
        return token(from: data)
    }
}


@MainActor
final class AIUsageStore: ObservableObject {
    static let shared = AIUsageStore()
    @Published var snapshots = AIUsageProvider.allCases.map {
        AIUsageSnapshot(provider: $0, status: L10n.text("usage.not.read.yet"), source: $0.initialSource)
    }
    @Published var isRefreshing = false
    var visibleSnapshots: [AIUsageSnapshot] {
        snapshots.filter { $0.isConnected || $0.updatedAt != nil || $0.wasConfigured }.map { snapshot in
            guard !snapshot.isConnected || snapshot.error != nil else { return snapshot }
            var unavailable = snapshot
            unavailable.windows = snapshot.windows.map {
                AIUsageWindow(id: $0.id, title: $0.title, remainingPercent: nil, resetsAt: $0.resetsAt)
            }
            unavailable.balance = nil
            return unavailable
        }
    }
    @Published var runningProviders = Set<String>()
    private let applyDisplayFilters: Bool
    private let displayDefaults: UserDefaults
    private var preferencesObserver: AnyCancellable?
    var selectedProviders: Set<String> {
        AIVisibilityPreferences.selected(automatic: Set(visibleSnapshots.map { $0.provider.rawValue }), defaults: displayDefaults)
    }
    var displaySnapshots: [AIUsageSnapshot] {
        guard applyDisplayFilters else { return visibleSnapshots }
        let running = Set(AIUsageProvider.allCases.filter { runningProviders.contains($0.processKey) }.map(\.rawValue))
        let visible = RunningVisibility.visible(selected: selectedProviders, running: running,
            alwaysShowAll: displayDefaults.bool(forKey: AIVisibilityPreferences.alwaysShowKey))
        let available = Dictionary(uniqueKeysWithValues: visibleSnapshots.map { ($0.provider, $0) })
        return snapshots.filter { visible.contains($0.provider.rawValue) }.map { available[$0.provider] ?? $0 }
    }
    var subscriptionPreferences: SubscriptionPreferences { SubscriptionPreferences(defaults: displayDefaults) }
    private(set) var scheduledRefreshInterval: TimeInterval?
    private var timer: Timer?
    private var tasks: [AIUsageProvider: Task<Void, Never>] = [:]
    private var generation = 0
    private let fetcher: (AIUsageProvider) async throws -> AIUsageSnapshot

    init(applyDisplayFilters: Bool = true, displayDefaults: UserDefaults = .standard, fetcher: ((AIUsageProvider) async throws -> AIUsageSnapshot)? = nil) {
        self.applyDisplayFilters = applyDisplayFilters
        self.displayDefaults = displayDefaults
        self.fetcher = fetcher ?? { provider in
            switch provider {
            case .codex: return try await CodexUsageSource.fetch()
            case .claude: return try await ClaudeUsageSource.fetch()
            case .grok: return try await GrokUsageSource.fetch()
            default:
                guard let credential = try APIAccountCredentials.shared.credential(for: provider) else { throw AIUsageError.signedOut }
                do { return try await APIUsageSource.fetch(provider: provider, credential: credential) }
                catch is CancellationError { throw CancellationError() }
                catch {
                    let message = error is AIUsageError ? error.localizedDescription : L10n.text("usage.api.quota.is.temporarily.unavailable.check.your")
                    throw AIUsageError.configuredAccountUnavailable(message, source: provider.initialSource)
                }
            }
        }
    }

    func start() {
        preferencesObserver = subscriptionPreferences.changes.dropFirst().sink { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.objectWillChange.send()
                if self.timer != nil { self.scheduleRefresh() }
            }
        }
        guard timer == nil else { return }
        refresh()
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        let interval = TimeInterval(subscriptionPreferences.refreshMinutes * 60)
        guard scheduledRefreshInterval != interval || timer == nil else { return }
        timer?.invalidate()
        scheduledRefreshInterval = interval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        preferencesObserver = nil
        timer?.invalidate(); timer = nil
        scheduledRefreshInterval = nil
        generation += 1
        tasks.values.forEach { $0.cancel() }; tasks.removeAll()
        isRefreshing = false
    }

    func acceptAPIConnection(_ snapshot: AIUsageSnapshot) {
        guard snapshot.provider.isAPIAccount else { return }
        tasks.removeValue(forKey: snapshot.provider)?.cancel()
        if let index = snapshots.firstIndex(where: { $0.provider == snapshot.provider }) { snapshots[index] = snapshot }
        isRefreshing = !tasks.isEmpty
    }

    func disconnectAPIAccount(_ provider: AIUsageProvider) {
        guard provider.isAPIAccount else { return }
        tasks.removeValue(forKey: provider)?.cancel()
        if let index = snapshots.firstIndex(where: { $0.provider == provider }) {
            snapshots[index] = AIUsageSnapshot(provider: provider, status: L10n.text("status.notConnected"), source: provider.initialSource)
        }
        isRefreshing = !tasks.isEmpty
    }

    func refresh(provider: AIUsageProvider? = nil) {
        for provider in provider.map({ [$0] }) ?? AIUsageProvider.allCases where tasks[provider] == nil {
            let ticket = generation
            let fetch = fetcher
            tasks[provider] = Task { [weak self] in
                let result: Result<AIUsageSnapshot, Error>
                do { result = .success(try await fetch(provider)) }
                catch { result = .failure(error) }
                guard let self, ticket == self.generation, !Task.isCancelled,
                      let index = self.snapshots.firstIndex(where: { $0.provider == provider }) else { return }
                switch result {
                case .success(let snapshot): self.snapshots[index] = snapshot
                case .failure(AIUsageError.signedOut):
                    let source = self.snapshots[index].source
                    self.snapshots[index] = AIUsageSnapshot(provider: provider, status: L10n.text("usage.not.signed.in"), source: source)
                case .failure(let error):
                    if case AIUsageError.unsafeCredential = error { self.snapshots[index].wasConfigured = true }
                    if case AIUsageError.configuredAccountUnavailable(_, let source) = error {
                        self.snapshots[index].wasConfigured = true
                        if let source, self.snapshots[index].updatedAt == nil { self.snapshots[index].source = source }
                    }
                    self.snapshots[index].isConnected = false
                    self.snapshots[index].error = error is AIUsageError ? error.localizedDescription : L10n.text("usage.usage.is.temporarily.unavailable.check.your.network")
                    self.snapshots[index].status = self.snapshots[index].updatedAt != nil || self.snapshots[index].wasConfigured ? L10n.text("usage.refresh.failed.please.try.again.later") : L10n.text("status.notConnected")
                }
                self.tasks.removeValue(forKey: provider)
                self.isRefreshing = !self.tasks.isEmpty
            }
        }
        isRefreshing = !tasks.isEmpty
    }
}
