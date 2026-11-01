import AppKit
import Combine
import Darwin
import SwiftUI

/// Time is supplied by the caller. A grace period starts at the first absent sample.
struct RunningVisibility {
    static let pollInterval: TimeInterval = 5
    static let gracePeriod: TimeInterval = 30
    private var seen = Set<String>()
    private var absentSince: [String: TimeInterval] = [:]

    mutating func update(now: TimeInterval, running: [String: Bool]) -> Set<String> {
        for (provider, active) in running {
            if active {
                seen.insert(provider)
                absentSince[provider] = nil
            } else if seen.contains(provider), absentSince[provider] == nil {
                absentSince[provider] = now
            }
        }
        return Set(running.keys.filter { provider in
            running[provider] == true || (seen.contains(provider)
                && absentSince[provider].map { now - $0 < Self.gracePeriod } == true)
        })
    }

    static func visible(selected: Set<String>, running: Set<String>, alwaysShowAll: Bool) -> Set<String> {
        alwaysShowAll ? selected : selected.intersection(running)
    }

    static func showsIdle(_ visible: Set<String>) -> Bool { visible.isEmpty }
}

enum SharedResources {
    static func url(_ filename: String, directory: String? = nil) -> URL {
        let bundled = (directory.map { Bundle.main.resourceURL?.appendingPathComponent($0) }
            ?? Bundle.main.resourceURL)?.appendingPathComponent(filename)
        if let bundled, FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        // SwiftPM development binaries run from the Mac checkout; distributions use Resources.
        let shared = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .deletingLastPathComponent().appendingPathComponent("shared")
        return (directory.map { shared.appendingPathComponent($0) } ?? shared).appendingPathComponent(filename)
    }
}

struct RunningProcessMap {
    let names: [String: [String]]

    init(bundledURL: URL = SharedResources.url("running-processes.json"), overrideURL: URL? = nil) {
        let override = overrideURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentifiers.bundleID).appendingPathComponent("running-processes.json")
        func read(_ url: URL) -> [String: [String]]? {
            guard let data = try? BoundedFile.read(url),
                  let value = try? JSONDecoder().decode([String: [String]].self, from: data),
                  value.values.allSatisfy({ $0.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }) else { return nil }
            return value
        }
        names = read(override) ?? read(bundledURL) ?? [:]
    }

    init(names: [String: [String]]) { self.names = names }

    func match(_ processNames: Set<String>) -> [String: Bool] {
        let folded = Set(processNames.map { $0.lowercased() })
        return names.mapValues { $0.contains { folded.contains($0.lowercased()) } }
    }

    /// Reads names only. No command lines, arguments, environments or process memory.
    @MainActor static func processNames() -> Set<String> {
        var names = Set<String>()
        for app in NSWorkspace.shared.runningApplications {
            if let name = app.localizedName { names.insert(name) }
            if let name = app.executableURL?.lastPathComponent { names.insert(name) }
        }
        let required = proc_listallpids(nil, 0)
        guard required > 0 else { return names }
        var pids = [pid_t](repeating: 0, count: Int(required) + 128)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        for pid in pids.prefix(max(0, min(Int(count), pids.count))) where pid > 0 {
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let size = buffer.withUnsafeMutableBytes { proc_name(pid, $0.baseAddress, UInt32($0.count)) }
            if size > 0 { names.insert(String(cString: buffer)) }
        }
        return names
    }
}

extension AIUsageProvider {
    var processKey: String {
        switch self {
        case .openaiAPI: return "codex"
        case .anthropicAPI: return "claude"
        case .geminiAPI: return "gemini"
        case .xaiAPI: return "grok"
        case .kimiAPI: return "kimi"
        case .deepseekAPI: return "deepseek"
        case .openrouterAPI: return "openrouter"
        case .minimaxAPI: return "minimax"
        default: return rawValue
        }
    }
}

/// Per-provider overrides layer on the existing connected/configured-account rule.
enum AIVisibilityPreferences {
    static let alwaysShowKey = "AlwaysShowAll"
    static let selectionKey = "aiUsage.selectedProviders"
    static func selectionOverrides(defaults: UserDefaults = .standard) -> [String: Bool] {
        (defaults.dictionary(forKey: selectionKey) ?? [:]).compactMapValues { $0 as? Bool }
    }
    static func selected(automatic: Set<String>, defaults: UserDefaults = .standard) -> Set<String> {
        let overrides = selectionOverrides(defaults: defaults)
        return Set(AIUsageProvider.allCases.map(\.rawValue).filter { overrides[$0] ?? automatic.contains($0) })
    }
    static func setSelected(_ selected: Bool, provider: AIUsageProvider, defaults: UserDefaults = .standard) {
        var values = selectionOverrides(defaults: defaults)
        values[provider.rawValue] = selected
        defaults.set(values, forKey: selectionKey)
    }
}

@MainActor
final class RunningAIStore: ObservableObject {
    @Published private(set) var active = Set<String>()
    private var state = RunningVisibility()
    private var timer: Timer?
    private let clock: () -> TimeInterval
    private let readNames: () -> Set<String>
    private let mapping: RunningProcessMap

    init(mapping: RunningProcessMap = RunningProcessMap(), clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         readNames: (() -> Set<String>)? = nil) {
        self.mapping = mapping; self.clock = clock; self.readNames = readNames ?? { RunningProcessMap.processNames() }
    }
    func poll() {
        let next = state.update(now: clock(), running: mapping.match(readNames()))
        if next != active { active = next }
    }
    func start() {
        guard timer == nil else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: RunningVisibility.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        timer?.tolerance = 0.25
    }
    func stop() { timer?.invalidate(); timer = nil }
}

struct AIProviderVisibilityView: View {
    @ObservedObject var store: AIUsageStore
    @AppStorage(AIVisibilityPreferences.alwaysShowKey) private var alwaysShowAll = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(L10n.text("settings.alwaysShowAll"), isOn: $alwaysShowAll)
            Text(L10n.text("settings.running.help")).font(.caption).foregroundStyle(.secondary)
            DisclosureGroup(L10n.text("settings.providers")) {
                ForEach(AIUsageProvider.allCases) { provider in
                    Toggle(provider.title, isOn: Binding(get: { store.selectedProviders.contains(provider.rawValue) }, set: {
                        AIVisibilityPreferences.setSelected($0, provider: provider)
                        store.objectWillChange.send()
                    }))
                }
                Button(L10n.text("settings.providers.automatic")) {
                    UserDefaults.standard.removeObject(forKey: AIVisibilityPreferences.selectionKey)
                    store.objectWillChange.send()
                }
            }
        }.toggleStyle(SettingsSwitchStyle())
    }
}
