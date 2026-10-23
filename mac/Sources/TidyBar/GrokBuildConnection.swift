import AppKit
import Darwin
import SwiftUI

/// Opened only by the user's connect button. OAuth output is discarded, never logged.
@MainActor
final class GrokBuildConnection: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = GrokBuildConnection()
    @Published private(set) var status = L10n.text("connection.complete.official.grok.account.verification.in.your")
    @Published private(set) var isConnecting = false
    private var window: NSWindow?
    private var task: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var process: CLIProcess?
    private var session: URLSession?
    private var generation = 0

    func connect() {
        if window == nil {
            let panel = StandaloneWindow.make()
            panel.title = L10n.text("connection.connect.grok.live.usage"); panel.isReleasedWhenClosed = false
            panel.delegate = self; panel.contentView = NSHostingView(rootView: GrokBuildConnectionView(connection: self).padding(.top, 28))
            panel.center(); window = panel
        }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        guard !isConnecting else { return }
        generation += 1; let ticket = generation
        isConnecting = true; status = L10n.text("connection.preparing.the.official.grok.sign.in.tool")
        setDeadline(seconds: 600, message: L10n.text("connection.preparing.the.sign.in.tool.timed.out"))
        task = Task { [weak self] in
            guard let self else { return }
            var awaitingLogin = false
            do {
                try ProviderLoginConsent().require(.grok)
                let executable = try await self.executable()
                try Task.checkCancellation()
                guard ticket == self.generation else { return }
                awaitingLogin = true
                self.setDeadline(seconds: 300, message: L10n.text("connection.official.sign.in.timed.out.retry.and"))
                self.status = L10n.text("connection.complete.official.verification.in.the.browser.that")
                try await self.login(executable)
                guard ticket == self.generation, !Task.isCancelled else { return }
                self.deadline?.cancel(); self.deadline = nil; self.isConnecting = false; self.task = nil
                self.status = L10n.text("connection.official.sign.in.completed.an.account.usage")
                AIUsageStore.shared.refresh(provider: .grok)
            } catch {
                guard ticket == self.generation else { return }
                self.cancel((error as? AIUsageError)?.localizedDescription ?? (awaitingLogin
                    ? L10n.text("connection.official.sign.in.did.not.complete.retry")
                    : L10n.text("connection.could.not.prepare.the.sign.in.tool")))
            }
        }
    }

    func stop() { cancel(L10n.text("connection.connection.cancelled")); window?.orderOut(nil) }
    func windowWillClose(_ notification: Notification) { stop() }
    func cancel() { cancel(L10n.text("connection.connection.cancelled.you.can.retry.at.any")) }
    func setDeadline(seconds: TimeInterval, message: String) {
        deadline?.cancel()
        let ticket = generation
        deadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch { return }
            guard !Task.isCancelled, let self, self.generation == ticket else { return }
            self.cancel(message)
        }
    }
    private func cancel(_ message: String) {
        generation += 1; task?.cancel(); task = nil; deadline?.cancel(); deadline = nil
        session?.invalidateAndCancel(); session = nil
        process?.terminateAndWait()
        process = nil; isConnecting = false; status = message
    }

    private func executable() async throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [home.appendingPathComponent(".local/bin/grok"), URL(fileURLWithPath: "/opt/homebrew/bin/grok"),
                          URL(fileURLWithPath: "/usr/local/bin/grok"), home.appendingPathComponent(".grok/bin/grok")]
        if let existing = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            try GrokCLITrust.verify(existing)
            return existing
        }
        #if !arch(arm64)
        throw AIUsageError.unavailable(L10n.text("connection.automatic.downloads.currently.support.only.apple.silicon"))
        #else
        status = L10n.text("connection.reading.the.official.grok.stable.version.tool")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil; configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 600
        let session = URLSession(configuration: configuration, delegate: GrokBuildDownloadGuard(), delegateQueue: nil)
        self.session = session
        defer { session.invalidateAndCancel(); if self.session === session { self.session = nil } }
        let (versionData, response) = try await session.data(from: URL(string: "https://x.ai/cli/stable")!)
        try Self.check(response)
        guard versionData.count < 1024, let text = String(data: versionData, encoding: .utf8) else { throw AIUsageError.invalidResponse }
        let version = try Self.version(text)
        let directory = home.appendingPathComponent("Library/Application Support/com.mike.aisubgauge/Tools", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = directory.appendingPathComponent("grok-\(version)-macos-aarch64")
        if FileManager.default.isExecutableFile(atPath: destination.path) {
            try GrokCLITrust.verify(destination)
            return destination
        }
        status = L10n.text("connection.downloading.the.official.grok.sign.in.tool")
        let (download, downloadedResponse) = try await session.download(from: Self.artifactURL(version: version))
        defer { try? FileManager.default.removeItem(at: download) }
        try Self.check(downloadedResponse); try Task.checkCancellation()
        let size = (try FileManager.default.attributesOfItem(atPath: download.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0, size <= 512 * 1024 * 1024 else { throw AIUsageError.unavailable(L10n.text("connection.the.official.grok.tool.has.an.unexpected")) }
        let file = try FileHandle(forReadingFrom: download); defer { try? file.close() }
        guard try file.read(upToCount: 8) == Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 1]) else {
            throw AIUsageError.unavailable(L10n.text("connection.the.official.grok.tool.has.an.unexpected.321"))
        }
        let staging = directory.appendingPathComponent(".grok-download-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: download, to: staging)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
        try GrokCLITrust.verify(staging)
        // Same-directory rename is atomic; existing user CLI locations are never changed.
        try FileManager.default.moveItem(at: staging, to: destination)
        return destination
        #endif
    }

    func login(_ executable: URL, onLaunch: ((pid_t) -> Void)? = nil, verifyCLI: ((URL) throws -> Void)? = nil) async throws {
        try Task.checkCancellation()
        let prepared = try GrokCLITrust.prepare(executable, verifyCLI: verifyCLI)
        defer { prepared.cleanup() }
        try Task.checkCancellation()
        let process = try CLIProcess(executable: prepared.executable, arguments: ["login", "--oauth"],
            environment: CLIEnvironment.grok(), directory: prepared.directory)
        self.process = process
        defer { process.terminateAndWait(); if self.process === process { self.process = nil } }
        onLaunch?(process.processIdentifier)
        while process.isRunning { try await Task.sleep(nanoseconds: 200_000_000) }
        try Task.checkCancellation()
        guard process.succeeded else { throw AIUsageError.unavailable(L10n.text("connection.official.grok.sign.in.did.not.complete")) }
    }

    static func version(_ text: String) throws -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 80, value.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9._]+)?$"#, options: .regularExpression) != nil else {
            throw AIUsageError.unavailable(L10n.text("connection.the.official.grok.version.information.has.an"))
        }
        return value
    }
    static func artifactURL(version: String) throws -> URL {
        URL(string: "https://x.ai/cli/grok-\(try Self.version(version))-macos-aarch64")!
    }
    static func isOfficial(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "x.ai" && (url.port == nil || url.port == 443)
            && url.user == nil && url.password == nil
    }
    private static func check(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              let url = response.url, isOfficial(url) else {
            throw AIUsageError.unavailable(L10n.text("connection.could.not.download.the.sign.in.tool"))
        }
    }
}

private final class GrokBuildDownloadGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let url = request.url
        let allowed = url?.scheme == "https" && url?.host == "x.ai" && (url?.port == nil || url?.port == 443)
            && url?.user == nil && url?.password == nil
        completionHandler(allowed ? request : nil)
    }
}

private struct GrokBuildConnectionView: View {
    @ObservedObject var connection: GrokBuildConnection
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("connection.connect.grok.live.usage")).font(.headline)
            Text(connection.status).font(.callout).fixedSize(horizontal: false, vertical: true)
            Text(L10n.text("connection.uses.official.browser.sign.in.make.sure")).font(.caption).foregroundStyle(.secondary)
            HStack {
                if connection.isConnecting { ProgressView().controlSize(.small); Spacer(); Button(L10n.text("common.cancel")) { connection.cancel() } }
                else { Spacer(); Button(L10n.text("connection.close")) { connection.stop() }; Button(L10n.text("connection.retry.connection")) { connection.connect() }.keyboardShortcut(.defaultAction) }
            }
        }.padding(22).frame(width: 420, height: 205, alignment: .topLeading)
    }
}
