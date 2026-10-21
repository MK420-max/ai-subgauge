import AppKit
import SwiftUI
import WebKit

struct ClaudeUsageOrganization: Identifiable, Equatable {
    var id: String
    var name: String
}

enum ClaudeWebUsage {
    static let source = L10n.text("connection.claude.official.web.usage.api")
    static let connectedProfileKey = "claudeWebHasConnectedProfile"
    static func rememberProfile(in defaults: UserDefaults) { defaults.set(true, forKey: connectedProfileKey) }
    static func canRestoreProfile(in defaults: UserDefaults) -> Bool { defaults.bool(forKey: connectedProfileKey) }
    static func organizations(_ value: Any) throws -> [ClaudeUsageOrganization] {
        guard let rows = value as? [[String: Any]], !rows.isEmpty, rows.count <= 100 else { throw AIUsageError.invalidResponse }
        var result: [ClaudeUsageOrganization] = []
        for row in rows {
            guard let rawID = row["uuid"] as? String, let uuid = UUID(uuidString: rawID),
                  let name = row["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !result.contains(where: { $0.id == uuid.uuidString.lowercased() }) else { throw AIUsageError.invalidResponse }
            result.append(ClaudeUsageOrganization(id: uuid.uuidString.lowercased(), name: String(name.prefix(200))))
        }
        return result
    }
    static func selected(from organizations: [ClaudeUsageOrganization], id: String?) throws -> ClaudeUsageOrganization {
        if let id, let selection = organizations.first(where: { $0.id == id }) { return selection }
        if organizations.count == 1, let only = organizations.first { return only }
        throw AIUsageError.unavailable(L10n.text("connection.select.the.organization.whose.usage.you.want"))
    }
    static func snapshot(_ value: [String: Any], now: Date = Date()) throws -> AIUsageSnapshot {
        var result = try ClaudeUsageSource.parse(value, now: now)
        result.source = source
        if let extra = value["extra_usage"] as? [String: Any], extra["is_enabled"] as? Bool == true,
           let utilization = extra["utilization"] as? NSNumber,
           CFGetTypeID(utilization) != CFBooleanGetTypeID(), utilization.doubleValue.isFinite, utilization.doubleValue >= 0 {
            result.balance = String(format: L10n.text("connection.extra.quota.remaining.0f"), max(0, 100 - utilization.doubleValue))
        }
        return result
    }
    static func canRead(_ url: URL?) -> Bool { url?.scheme == "https" && url?.host == "claude.ai" && (url?.port == nil || url?.port == 443) }
    static func canNavigateInLogin(_ url: URL) -> Bool {
        url.scheme == "https" && (url.port == nil || url.port == 443) && ["claude.ai", "auth.claude.com", "accounts.google.com", "appleid.apple.com", "login.microsoftonline.com"].contains(url.host ?? "")
    }
}

@MainActor
final class ClaudeWebConnection: NSObject, ObservableObject, WKNavigationDelegate {
    static let shared = ClaudeWebConnection()
    @Published private(set) var status = L10n.text("connection.sign.in.on.the.official.page.below")
    @Published private(set) var organizations: [ClaudeUsageOrganization] = []
    @Published var selectedOrganizationID: String? = nil
    @Published private(set) var isReading = false
    private var webView: WKWebView?
    private var window: NSWindow?
    private var task: Task<AIUsageSnapshot, Error>?
    private var generation = 0
    private var pageReady = false
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults; super.init() }

    private func prepareBrowser() -> WKWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: UUID(uuidString: "4B941760-C836-4F88-A78A-580E221EF5BA")!)
        let browser = WKWebView(frame: .zero, configuration: configuration)
        browser.navigationDelegate = self
        webView = browser
        return browser
    }

    func restoreExistingSession() {
        guard webView == nil, ClaudeWebUsage.canRestoreProfile(in: defaults) else { return }
        status = L10n.text("connection.restoring.the.claude.web.connection.please.wait")
        prepareBrowser().load(URLRequest(url: URL(string: "https://claude.ai/settings/usage")!))
    }

    func connect() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let browser = prepareBrowser()
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 720), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        panel.title = L10n.text("connection.connect.claude.official.usage")
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: ClaudeWebConnectionView(connection: self, browser: browser))
        panel.center(); window = panel
        panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        if browser.url == nil { browser.load(URLRequest(url: URL(string: "https://claude.ai/settings/usage")!)) }
    }

    func fetch() async throws -> AIUsageSnapshot {
        if let task { return try await task.value }
        guard let browser = webView, pageReady, ClaudeWebUsage.canRead(browser.url) else {
            throw AIUsageError.unavailable(L10n.text("connection.click.connect.claude.web.sign.in.on"))
        }
        let ticket = generation
        let pending = Task { @MainActor in
            let list = try await self.read(path: "/api/organizations", browser: browser)
            try Task.checkCancellation()
            guard self.generation == ticket else { throw CancellationError() }
            let organizations = try ClaudeWebUsage.organizations(list)
            self.organizations = organizations
            if let selected = self.selectedOrganizationID, !organizations.contains(where: { $0.id == selected }) {
                self.selectedOrganizationID = nil
            }
            let organization = try ClaudeWebUsage.selected(from: organizations, id: self.selectedOrganizationID)
            self.selectedOrganizationID = organization.id
            let value = try await self.read(path: "/api/organizations/\(organization.id)/usage", browser: browser)
            try Task.checkCancellation()
            guard self.generation == ticket, self.selectedOrganizationID == organization.id else { throw CancellationError() }
            guard let object = value as? [String: Any] else { throw AIUsageError.invalidResponse }
            return try ClaudeWebUsage.snapshot(object)
        }
        task = pending; isReading = true
        defer { if generation == ticket { task = nil; isReading = false } }
        do {
            let result = try await pending.value
            try Task.checkCancellation()
            guard generation == ticket else { throw CancellationError() }
            ClaudeWebUsage.rememberProfile(in: defaults)
            status = L10n.text("connection.connected.usage.can.still.refresh.automatically.after")
            return result
        } catch {
            if generation == ticket {
                status = (error as? AIUsageError)?.localizedDescription ?? L10n.text("connection.could.not.read.usage.confirm.your.sign")
            }
            throw error
        }
    }

    func stop() {
        generation += 1; task?.cancel(); task = nil; isReading = false
        window?.close(); window?.contentView = nil; window = nil
        webView?.stopLoading(); webView?.navigationDelegate = nil; webView = nil
        organizations = []; selectedOrganizationID = nil; pageReady = false
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if webView === self.webView { pageReady = false }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView, ClaudeWebUsage.canRead(webView.url) else { return }
        pageReady = true
        AIUsageStore.shared.refresh(provider: .claude)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView else { return }
        pageReady = false
        status = L10n.text("connection.the.claude.page.could.not.load.reconnect")
    }

    private func read(path: String, browser: WKWebView) async throws -> Any {
        guard ClaudeWebUsage.canRead(browser.url) else { throw AIUsageError.unavailable(L10n.text("connection.return.to.the.official.claude.page.then")) }
        let result = try await browser.callAsyncJavaScript("""
        if (location.origin !== 'https://claude.ai') return {status: 0};
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), 15000);
        try {
            const response = await fetch(path, {method: 'GET', credentials: 'same-origin', redirect: 'error', signal: controller.signal});
            if (!response.ok) return {status: response.status};
            const value = await response.json();
            return {status: response.status, value: path === '/api/organizations' && Array.isArray(value)
                ? value.map(org => ({uuid: org.uuid, name: org.name})) : value};
        } finally { clearTimeout(timer); }
        """, arguments: ["path": path], in: nil, contentWorld: .defaultClient)
        guard let response = result as? [String: Any], let code = response["status"] as? Int else { throw AIUsageError.invalidResponse }
        if [401, 403].contains(code) { throw AIUsageError.unavailable(L10n.text("connection.your.claude.web.session.has.expired.reconnect")) }
        guard code == 200, let value = response["value"] else { throw AIUsageError.unavailable(L10n.text("connection.could.not.read.claude.official.usage.please")) }
        return value
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if ClaudeWebUsage.canNavigateInLogin(url) {
            if action.targetFrame == nil { webView.load(action.request); decisionHandler(.cancel) }
            else { decisionHandler(.allow) }
        } else {
            if action.navigationType == .linkActivated, ["https", "http"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel)
        }
    }
}

private struct ClaudeWebBrowser: NSViewRepresentable {
    let browser: WKWebView
    func makeNSView(context: Context) -> WKWebView { browser }
    func updateNSView(_ view: WKWebView, context: Context) { }
}

private struct ClaudeWebConnectionView: View {
    @ObservedObject var connection: ClaudeWebConnection
    let browser: WKWebView
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("connection.claude.official.web.connection")).font(.title2.bold())
            Text(L10n.text("connection.complete.sign.in.and.verification.yourself.the")).font(.callout).foregroundStyle(.secondary)
            HStack {
                if connection.organizations.count > 1 {
                    Picker(L10n.text("connection.organization.for.usage"), selection: $connection.selectedOrganizationID) {
                        Text(L10n.text("connection.select.an.organization")).tag(String?.none)
                        ForEach(connection.organizations) { organization in Text(organization.name).tag(Optional(organization.id)) }
                    }.frame(maxWidth: 380)
                }
                Button(connection.isReading ? L10n.text("connection.reading") : L10n.text("connection.read.usage")) {
                    Task { if (try? await connection.fetch()) != nil { AIUsageStore.shared.refresh(provider: .claude) } }
                }.disabled(connection.isReading)
                Button(L10n.text("connection.return.to.official.usage.page")) { browser.load(URLRequest(url: URL(string: "https://claude.ai/settings/usage")!)) }
            }
            Text(connection.status).font(.caption).textSelection(.enabled)
            Divider()
            ClaudeWebBrowser(browser: browser)
        }.padding(16).frame(minWidth: 720, minHeight: 540)
    }
}
