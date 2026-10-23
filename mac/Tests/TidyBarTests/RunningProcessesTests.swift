import Foundation
import Testing
@testable import TidyBar

extension TidyBarTests {
    @Test func runningGraceStartsWhenProcessesDisappearAndReappearanceIsImmediate() {
        var state = RunningVisibility()
        #expect(state.update(now: 0, running: ["codex": false]).isEmpty)
        #expect(state.update(now: 5, running: ["codex": true]) == ["codex"])
        #expect(state.update(now: 10, running: ["codex": false]) == ["codex"])
        #expect(state.update(now: 39, running: ["codex": false]) == ["codex"])
        #expect(state.update(now: 41, running: ["codex": false]).isEmpty)
        #expect(state.update(now: 42, running: ["codex": true]) == ["codex"])
        #expect(state.update(now: 50, running: ["codex": false]) == ["codex"])
        #expect(state.update(now: 79, running: ["codex": false]) == ["codex"])
        #expect(state.update(now: 80, running: ["codex": false]).isEmpty)
    }

    @Test func selectionAlwaysShowAndIdleUseTheSameFinalSet() {
        let selected: Set<String> = ["codex", "claude"]
        let visible = RunningVisibility.visible(selected: selected, running: ["codex", "grok"], alwaysShowAll: false)
        #expect(visible == ["codex"])
        #expect(!RunningVisibility.showsIdle(visible))
        #expect(RunningVisibility.visible(selected: selected, running: [], alwaysShowAll: true) == selected)
        let idle = RunningVisibility.visible(selected: selected, running: ["grok"], alwaysShowAll: false)
        #expect(RunningVisibility.showsIdle(idle))
        #expect(RunningVisibility.showsIdle(RunningVisibility.visible(selected: [], running: ["grok"], alwaysShowAll: true)))
    }

    @Test func processNamesMatchExactlyAndWithoutCaseSensitivity() {
        let mapping = RunningProcessMap(names: ["codex": ["codex", "ChatGPT"], "grok": ["Grok Bot", "grok"], "claude": ["Claude"]])
        #expect(mapping.match(["CHATGPT", "gRoK bOt", "claude-helper", "codex.exe"]) == ["codex": true, "grok": true, "claude": false])
        #expect(mapping.match(["not-codex", "grok-helper"]).values.allSatisfy { !$0 })
    }

    @Test func sharedDefaultsAndSettingsDirectoryOverride() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("running-map-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let missing = folder.appendingPathComponent("missing.json")
        let bundled = RunningProcessMap(overrideURL: missing)
        #expect(bundled.names["codex"] == ["codex", "Codex", "ChatGPT"])
        #expect(bundled.names["glm"] == ["glm", "zai"])
        #expect(bundled.names.count == 7)
        let override = folder.appendingPathComponent("running-processes.json")
        try Data(#"{"codex":["Custom App"],"grok":[]}"#.utf8).write(to: override)
        let custom = RunningProcessMap(overrideURL: override)
        #expect(custom.match(["custom app"])["codex"] == true)
        #expect(custom.match(["Grok Bot"])["grok"] == false)
        try Data("invalid".utf8).write(to: override)
        #expect(RunningProcessMap(overrideURL: override).names == bundled.names)
    }

    @MainActor @Test func injectedClockAndNamesDriveTheGracePeriod() {
        var time: TimeInterval = 0
        var names: Set<String> = ["codex"]
        let monitor = RunningAIStore(mapping: RunningProcessMap(names: ["codex": ["Codex"]]), clock: { time }, readNames: { names })
        monitor.poll(); #expect(monitor.active == ["codex"])
        time = 5; names = []; monitor.poll()
        time = 34; monitor.poll(); #expect(monitor.active == ["codex"])
        time = 35; monitor.poll(); #expect(monitor.active.isEmpty)
        names = ["CODEX"]; monitor.poll(); #expect(monitor.active == ["codex"])
        #expect(RunningVisibility.pollInterval == 5)
    }

    @MainActor @Test func fakeProcessesDriveDisplayedQuotaThroughExactGraceBoundary() throws {
        let domain = "test.running-display." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        var time: TimeInterval = 0
        var names: Set<String> = ["ChatGPT"]
        let monitor = RunningAIStore(mapping: RunningProcessMap(names: ["codex": ["ChatGPT"]]),
            clock: { time }, readNames: { names })
        let store = AIUsageStore(displayDefaults: defaults, fetcher: { _ in throw AIUsageError.signedOut })
        store.snapshots = [AIUsageSnapshot(provider: .codex, isConnected: true, status: "", source: "fixture")]
        func poll() {
            monitor.poll()
            store.runningProviders = monitor.active
        }
        poll(); #expect(store.menuBarDisplaySnapshots.map(\.provider) == [.codex])
        names = []; time = 5; poll()
        #expect(store.menuBarDisplaySnapshots.map(\.provider) == [.codex])
        time = 34.999; poll()
        #expect(store.menuBarDisplaySnapshots.map(\.provider) == [.codex])
        time = 35; poll(); #expect(store.menuBarDisplaySnapshots.isEmpty)
        names = ["CHATGPT"]; poll()
        #expect(store.menuBarDisplaySnapshots.map(\.provider) == [.codex])
    }

    @Test func automaticProviderSelectionRespectsExplicitOverrides() throws {
        let domain = "test.visibility." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        #expect(!defaults.bool(forKey: AIVisibilityPreferences.alwaysShowKey))
        #expect(AIVisibilityPreferences.selected(automatic: ["codex"], defaults: defaults) == ["codex"])
        AIVisibilityPreferences.setSelected(false, provider: .codex, defaults: defaults)
        AIVisibilityPreferences.setSelected(true, provider: .claude, defaults: defaults)
        #expect(AIVisibilityPreferences.selected(automatic: ["codex", "grok"], defaults: defaults) == ["claude", "grok"])
    }

    @MainActor @Test func accountDisplayIntegratesSelectionProcessMappingAndIdle() throws {
        let domain = "test.display." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = AIUsageStore(displayDefaults: defaults, fetcher: { _ in throw AIUsageError.signedOut })
        store.snapshots = [
            AIUsageSnapshot(provider: .codex, isConnected: true, status: "", source: ""),
            AIUsageSnapshot(provider: .claude, isConnected: true, status: "", source: ""),
            AIUsageSnapshot(provider: .openaiAPI, isConnected: true, status: "", source: "")
        ]
        #expect(RunningVisibility.showsIdle(Set(store.displaySnapshots.map { $0.provider.rawValue })))
        store.runningProviders = ["codex"]
        #expect(store.displaySnapshots.map(\.provider) == [.codex, .openaiAPI])
        AIVisibilityPreferences.setSelected(false, provider: .codex, defaults: defaults)
        #expect(store.displaySnapshots.map(\.provider) == [.openaiAPI])
        defaults.set(true, forKey: AIVisibilityPreferences.alwaysShowKey)
        #expect(store.displaySnapshots.map(\.provider) == [.claude, .openaiAPI])
        AIVisibilityPreferences.setSelected(false, provider: .claude, defaults: defaults)
        AIVisibilityPreferences.setSelected(false, provider: .openaiAPI, defaults: defaults)
        #expect(RunningVisibility.showsIdle(Set(store.displaySnapshots.map { $0.provider.rawValue })))
    }

    @MainActor @Test func liveNameReaderReturnsNamesWithoutReadingArguments() {
        #expect(!RunningProcessMap.processNames().isEmpty)
    }
}
