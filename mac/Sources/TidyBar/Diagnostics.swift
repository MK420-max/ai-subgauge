import AppKit
import Darwin
import SwiftUI
import UniformTypeIdentifiers

enum DiagnosticsRedactor {
    static func text(_ input: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                     hostname: String = ProcessInfo.processInfo.hostName) -> String {
        var result = input.replacingOccurrences(of: home, with: "~")
        for host in Set([hostname, String(hostname.split(separator: ".").first ?? "")]) where !host.isEmpty {
            result = result.replacingOccurrences(of: host, with: "[host]", options: .caseInsensitive)
        }
        let replacements = [
            (#"(?i)\b(?:ssid|wi-?fi(?:name)?|(?:weather)?latitude|(?:weather)?longitude|coordinates?|weathercity)\s*[\"']?\s*[:=]\s*(?:\"[^\"]*\"|'[^']*'|\[[^\]]*\]|[^\r\n,;}]+)"#, "[location redacted]"),
            (#"(?<![\w.])-?\d{1,2}\.\d{3,}\s*,\s*-?\d{1,3}\.\d{3,}(?![\w.])"#, "[coordinates redacted]"),
            (#"/Users/[^/\s\"<>]+"#, "~"),
            (#"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, "[email]"),
            (#"(?i)\b[a-z0-9_-]+\.local\b"#, "[host]"),
            (#"(?i)\bBearer\s+[^\s\"',;}]+"#, "Bearer [redacted]"),
            (#"(?i)(?:access[_-]?token|refresh[_-]?token|api[_-]?key|authorization|password|secret|token)\s*[\"']?\s*[:=]\s*[\"']?[^\s\"',;}]+"#, "[redacted]"),
            (#"\b(?:sk-|xai-|ghp_|github_pat_)[A-Za-z0-9_-]+"#, "[redacted]"),
            (#"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#, "[redacted]")
        ]
        for (pattern, replacement) in replacements {
            result = result.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return result
    }

    static func value(_ input: Any) -> Any {
        if let string = input as? String { return text(string) }
        if let object = input as? [String: Any] {
            return object.reduce(into: [String: Any]()) { result, pair in
                let (key, value) = pair
                let secret = key.range(of: "(?i)token|password|secret|credential|api.?key|authorization|email|hostname|ssid|latitude|longitude|coordinate|weathercity", options: .regularExpression) != nil
                    || (value is String && key.range(of: "(?i)^wi.?fi(?:name)?$", options: .regularExpression) != nil)
                    || (object["kind"] as? String == "wifi" && ["value", "name"].contains(key))
                result[text(key)] = secret ? "[redacted]" : self.value(value)
            }
        }
        if let array = input as? [Any] { return array.map(value) }
        return input
    }
}

enum DiagnosticsReport {
    static func write(_ data: Data, to destination: URL,
                      home: URL = FileManager.default.homeDirectoryForCurrentUser,
                      environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        var existing = stat()
        guard lstat(destination.path, &existing) != 0 else { throw POSIXError(.EEXIST) }
        guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        // Foundation normalizes /private/var back to the /var symlink. Keep realpath's
        // actual directory spelling for the no-follow descriptor walk below.
        func canonicalPath(_ url: URL) -> String {
            guard let pointer = realpath(url.path, nil) else { return url.path }
            defer { free(pointer) }
            return String(cString: pointer)
        }
        let file = URL(fileURLWithPath: canonicalPath(destination.deletingLastPathComponent()))
            .appendingPathComponent(destination.lastPathComponent)
        var protected = [".codex", ".claude", ".grok", ".gemini", ".kimi-code", ".config/github-copilot", "Library/Keychains"]
            .map { home.appendingPathComponent($0) }
        for key in ["CODEX_HOME", "GROK_HOME"] {
            if let path = environment[key], !path.isEmpty { protected.append(URL(fileURLWithPath: path)) }
        }
        if let path = environment["GROK_AUTH_PATH"], !path.isEmpty {
            protected.append(URL(fileURLWithPath: path).deletingLastPathComponent())
        }
        guard !protected.contains(where: {
            let path = canonicalPath($0)
            return file.path.caseInsensitiveCompare(path) == .orderedSame
                || file.path.lowercased().hasPrefix(path.lowercased() + "/")
        }) else { throw AIUsageError.invalidResponse }
        // Walk without following links, then create exclusively relative to the opened parent.
        // Existing files (including dangling links) are never replaced.
        var parent = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(parent) }
        for component in file.deletingLastPathComponent().pathComponents.dropFirst() {
            let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            close(parent); parent = next
        }
        let descriptor = openat(parent, file.lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
    }

    static func data(snapshots: [AIUsageSnapshot]) throws -> Data {
        let states = snapshots.map { snapshot -> [String: Any] in
            // Fixed status labels only: no server errors, account identifiers, paths or credentials.
            ["provider": snapshot.provider.rawValue,
             "state": snapshot.error != nil ? "error" : snapshot.isConnected ? "connected" : "not_connected"]
        }
        return try AppDelegate.diagnosticsData(["app": AppIdentifiers.name, "version": AppIdentifiers.version,
            "os": ProcessInfo.processInfo.operatingSystemVersionString, "providers": states])
    }
}

@MainActor
final class DiagnosticsPreview {
    static let shared = DiagnosticsPreview()
    private var window: NSWindow?
    func show(snapshots: [AIUsageSnapshot]) {
        guard let data = try? DiagnosticsReport.data(snapshots: snapshots), let text = String(data: data, encoding: .utf8) else { return }
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 500),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = L10n.text("diagnostics.export.diagnostics.redacted.preview"); panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: DiagnosticsPreviewView(text: text, close: { [weak panel] in panel?.close() }).appThemed())
        panel.center(); window = panel
        panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}

private struct DiagnosticsPreviewView: View {
    let text: String
    let close: () -> Void
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("diagnostics.review.the.redacted.content.below")).font(.headline)
            Text(L10n.text("diagnostics.contains.only.the.app.version.os.version"))
                .font(.caption).foregroundStyle(.secondary)
            ScrollView { Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            if let error { Text(error).foregroundStyle(.orange) }
            HStack {
                Button(L10n.text("common.cancel"), action: close).keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.text("diagnostics.confirm.copy")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
                Button(L10n.text("diagnostics.confirm.export")) { export() }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(minWidth: 550, minHeight: 400)
    }
    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "AI SubGauge-diagnostics.json"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do { try DiagnosticsReport.write(Data(text.utf8), to: destination); close() }
        catch { self.error = L10n.text("diagnostics.diagnostics.export.failed.choose.a.writable.location") }
    }
}
