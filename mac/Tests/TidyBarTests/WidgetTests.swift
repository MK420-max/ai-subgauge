import Foundation
import Testing
import Combine
@testable import TidyBar

extension TidyBarTests {
@Suite
final class WidgetTests {
    private func currentThreadIsMain() -> Bool { Thread.isMainThread }
    @Test
    func testWeatherResponseRequiresCurrentTemperatureAndCode() throws {
        let response = try JSONDecoder().decode(WeatherResponse.self, from: Data("{\"current\":{\"temperature_2m\":-3.5,\"weather_code\":85},\"other\":true}".utf8))
        #expect(response.current.temperature_2m == -3.5)
        #expect(response.current.weather_code == 85)
        for invalid in ["{}", "{\"current\":{}}", "{\"current\":{\"temperature_2m\":\"warm\",\"weather_code\":0}}", "{\"current\":{\"temperature_2m\":8.2}}"] {
            #expect(throws: (any Error).self) { try JSONDecoder().decode(WeatherResponse.self, from: Data(invalid.utf8)) }
        }
    }

    @MainActor
    @Test
    func testDisabledWeatherCancelsAndClearsDataWithoutStartingRequest() {
        let data = WidgetData()
        data.temperature = 8
        data.weatherCode = 2
        data.weatherDate = Date(); data.weatherAttemptDate = Date(); data.weatherCoordinate = "49,-123"
        data.weatherTask = Task { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        data.refreshWeather(options: WidgetOptions())
        #expect(data.weatherTask == nil)
        #expect(data.temperature == nil)
        #expect(data.weatherCode == nil)
        #expect(data.weatherDate == nil)
        #expect(data.weatherAttemptDate == nil)
        #expect(data.weatherCoordinate == "")
        #expect(data.weatherStatus == "天气未开启")
    }

    @MainActor
    @Test
    func testInvalidCoordinatesNeverStartNetworkRequest() {
        let data = WidgetData()
        for coordinate in [(91.0, 0.0), (0.0, -181.0), (Double.nan, 0), (0, Double.infinity)] {
            var options = WidgetOptions()
            options.weather = true
            options.weatherLatitude = coordinate.0
            options.weatherLongitude = coordinate.1
            data.refreshWeather(options: options)
            #expect(data.weatherTask == nil)
            #expect(data.weatherStatus.contains("经纬度无效"))
        }
    }

    @MainActor
    @Test
    func testMusicCommandsRemainOrderedAndOldResultNeverPublishes() async {
        let began = TestSignal()
        let probe = MusicExecutionProbe(firstStarted: began)
        let data = WidgetData(musicExecutor: { command in await Task.detached { probe.execute(command) }.value })
        var publishedTitles: [String] = []
        let subscription = data.$musicTitle.dropFirst().sink { publishedTitles.append($0) }
        data.setMusicEnabled(true)
        data.music(command: "previous")
        #expect(await began.wait(timeout: 2))
        data.music(command: "next")
        probe.releaseFirst.signal()
        await data.musicTask?.value
        #expect(probe.commands == ["previous", "next"])
        #expect(probe.maximumConcurrent == 1)
        #expect(publishedTitles == ["next"])
        #expect(data.musicTitle == "next")
        withExtendedLifetime(subscription) { }
    }

    @MainActor
    @Test
    func testDisablingMusicIgnoresRunningResultAndSkipsQueuedAction() async {
        let began = TestSignal()
        let probe = MusicExecutionProbe(firstStarted: began)
        let data = WidgetData(musicExecutor: { command in await Task.detached { probe.execute(command) }.value })
        data.setMusicEnabled(true)
        data.music(command: "previous")
        #expect(await began.wait(timeout: 2))
        data.music(command: "next")
        let pending = data.musicTask
        data.setMusicEnabled(false)
        probe.releaseFirst.signal()
        await pending?.value
        #expect(probe.commands == ["previous"])
        #expect(data.musicTitle == "音乐")
        #expect(data.musicStatus == "音乐小组件未开启")
        #expect(!(data.musicConnected))
    }

    @MainActor
    @Test
    func testMusicFailureAndNotRunningNeverPretendToBeConnected() async {
        let data = WidgetData(musicExecutor: { command in
            switch command {
            case "failure": return MusicExecutionResult(error: "无法创建音乐控制脚本")
            case "empty": return MusicExecutionResult()
            default: return MusicExecutionResult(title: "未运行")
            }
        })
        data.setMusicEnabled(true)
        data.music(command: "failure")
        await data.musicTask?.value
        #expect(!(data.musicConnected))
        #expect(data.musicStatus.contains("无法创建音乐控制脚本"))
        data.music(command: "empty")
        await data.musicTask?.value
        #expect(!(data.musicConnected))
        #expect(data.musicStatus.contains("没有返回播放状态"))
        data.music()
        await data.musicTask?.value
        #expect(!(data.musicConnected))
        #expect(data.musicStatus.contains("尚未运行"))
    }

    @MainActor
    @Test
    func testCalendarGrantReturningAfterDisableCannotRefreshOrChangeStatus() async {
        let began = TestSignal()
        var continuation: CheckedContinuation<Bool, Never>?
        let data = WidgetData(calendarAccessRequest: {
            await withCheckedContinuation { result in
                continuation = result
                began.signal()
            }
        })
        data.calendarEnabled = true
        let pending = data.requestCalendar()
        #expect(await began.wait(timeout: 2))
        data.calendarEnabled = false
        continuation?.resume(returning: true)
        await pending?.value
        #expect(data.events == [])
        #expect(data.calendarStatus == "日历未开启")
        #expect(data.requestCalendar() == nil)
    }

    @MainActor
    @Test
    func testCalendarDeniedResultHasExplicitMessageWithoutSystemPermissionRequest() async {
        let data = WidgetData(calendarAccessRequest: { false })
        data.calendarEnabled = true
        await data.requestCalendar()?.value
        #expect(data.calendarStatus.contains("权限未允许"))
        data.calendarEnabled = false
        data.events = ["旧日程"]
        data.refreshCalendar()
        #expect(data.events.isEmpty)
        #expect(data.calendarStatus == "日历未开启")
    }


    @MainActor
    @Test
    func testMusicRunsExecutorOnMainActorAndReportsRealExecutionStages() async {
        var onMainThread = false
        let data = WidgetData(musicExecutor: { _ in
            onMainThread = self.currentThreadIsMain()
            return MusicExecutionResult(error: "AppleEvent 已超时", errorCode: -1712)
        })
        var stages: [String] = []
        let subscription = data.$musicStage.sink { stages.append($0) }
        data.setMusicEnabled(true)
        data.music()
        #expect(data.musicStage == "排队")
        #expect(data.musicStatus.contains("请稍候"))
        await data.musicTask?.value
        #expect(onMainThread)
        #expect(stages.contains("执行中"))
        #expect(data.musicStage == "超时")
        #expect(data.musicStatus.contains("响应超时"))
        #expect(!(data.musicStatus.contains("自动化")))
        #expect(!(data.musicConnected))
        let diagnostic = data.diagnosticState
        #expect(diagnostic["musicStage"] as? String == "超时")
        #expect(diagnostic["calendarEventCount"] as? Int == 0)
        #expect(diagnostic["musicTitle"] == nil)
        #expect(diagnostic["events"] == nil)
        data.setMusicEnabled(false)
        #expect(data.musicStage == "未启用")
        withExtendedLifetime(subscription) { }
    }

    @MainActor
    @Test
    func testMusicWorkspaceCheckDoesNotSendEventsWhenNotRunning() async {
        var scripts = 0
        let result = await WidgetData.executeMusicScript(command: "playpause", runningCheck: { false }, scriptExecutor: { _ in
            scripts += 1; return MusicExecutionResult(title: "错误替身")
        })
        #expect(scripts == 0)
        #expect(result.title == "未运行")
        #expect(result.diagnostics.map(\.stage) == ["检查运行状态"])
    }

    @MainActor
    @Test
    func testMusicConnectionIdentifiesFailingPhaseWithoutLibraryContentInDiagnostics() async {
        var scripts: [String] = []
        let result = await WidgetData.executeMusicScript(command: "info", runningCheck: { true }, scriptExecutor: { source in
            scripts.append(source)
            if source.contains("return version") { return MusicExecutionResult(title: "私有版本文本") }
            return MusicExecutionResult(error: "私有曲库错误文本", errorCode: -1712, errorRange: NSRange(location: 55, length: 12), errorAppName: "Music")
        })
        #expect(scripts.count == 2)
        #expect(scripts.allSatisfy { $0.contains("application id \"com.apple.Music\"") && $0.contains("4 seconds") })
        #expect(result.stage == "读取播放状态")
        #expect(result.diagnostics.map(\.stage) == ["检查运行状态", "读取版本", "读取播放状态"])
        let failure = try? JSONSerialization.data(withJSONObject: result.diagnostics.map(\.dictionary))
        let text = failure.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(text.contains("-1712"))
        #expect(text.contains("errorRange"))
        #expect(!(text.contains("私有")))
        #expect(!(text.contains("return version")))
    }

    @MainActor
    @Test
    func testMusicTrackMetadataUsesOneSnapshotDuringTrackChanges() async {
        var trackScript: String?
        let result = await WidgetData.executeMusicScript(command: "next", runningCheck: { true }, scriptExecutor: { source in
            if source.contains("properties of current track") {
                trackScript = source
                return MusicExecutionResult(title: "测试歌曲 — 测试艺人")
            }
            return MusicExecutionResult(title: source.contains("player state") ? "false" : "完成")
        })
        #expect(result.title == "测试歌曲 — 测试艺人")
        #expect(result.stage == "读取当前歌曲")
        guard let trackScript else { Issue.record("未读取曲目属性快照"); return }
        #expect(trackScript.components(separatedBy: "current track").count - 1 == 1, "跨曲切换时只可读取一次目标曲目，名称与艺人应来自同一属性快照")
        #expect(trackScript.contains("name of trackProperties"))
        #expect(trackScript.contains("artist of trackProperties"))
        let application = #"application id "com.apple.Music""#
        #expect(trackScript.contains(application))
        // Compile against the same installed app without LaunchServices bundle-ID lookup.
        // This only compiles the script; it does not launch Music or send Apple events.
        let compileSource = trackScript.replacingOccurrences(of: application, with: #"application "/System/Applications/Music.app""#)
        var compileError: NSDictionary?
        #expect(NSAppleScript(source: compileSource)?.compileAndReturnError(&compileError) == true, "曲目快照脚本必须能由系统编译：\(compileError?.description ?? "无错误详情")")
    }

    @MainActor
    @Test
    func testMusicControlIsSentExactlyOnceWhenSubsequentReadTimesOut() async {
        var scripts: [String] = []
        let result = await WidgetData.executeMusicScript(command: "playpause", runningCheck: { true }, scriptExecutor: { source in
            scripts.append(source)
            return source.contains("playpause") ? MusicExecutionResult(title: "完成") : MusicExecutionResult(error: "超时", errorCode: -1712)
        })
        #expect(scripts.filter { $0.contains("playpause") }.count == 1)
        #expect(scripts.count == 2)
        #expect(!(scripts.contains { $0.contains("return version") }))
        #expect(result.stage == "读取播放状态")
    }

    @MainActor
    @Test
    func testMusicDisabledBetweenStagesNeverSendsQueuedControl() async {
        var enabled = true
        var calls = 0
        let result = await WidgetData.executeMusicScript(command: "next", runningCheck: { true }, scriptExecutor: { _ in
            calls += 1
            return MusicExecutionResult(title: "完成")
        }, shouldContinue: { enabled }, stageChanged: { if $0 == "执行控制" { enabled = false } })
        #expect(calls == 0)
        #expect(result.error != nil)
    }

    @MainActor
    @Test
    func testExtendedMusicConnectionOnlyExtendsReadOnlyVersionPhase() async {
        var scripts: [String] = []
        let result = await WidgetData.executeMusicScript(command: "info-long", runningCheck: { true }, scriptExecutor: { source in
            scripts.append(source)
            return MusicExecutionResult(title: source.contains("return version") ? "1.0" : "true")
        })
        #expect(result.title == "未播放")
        #expect(scripts.count == 2)
        #expect(scripts[0].contains("30 seconds"))
        #expect(scripts[0].contains("return version"))
        #expect(scripts[1].contains("4 seconds"))
        #expect(!(scripts.contains { $0.contains("playpause") || $0.contains("next track") || $0.contains("previous track") }))
    }

    @MainActor
    @Test
    func testDisabledWeatherClearsOnceAndThenPublishesNothing() {
        let data = WidgetData()
        data.temperature = 8
        data.weatherCode = 2
        data.weatherDate = Date()
        data.weatherCoordinate = "49,-123"
        data.weatherStatus = "旧天气"
        var publications = 0
        let subscription = data.objectWillChange.sink { _ in publications += 1 }
        data.refreshWeather(options: WidgetOptions())
        #expect(publications > 0)
        let afterClear = publications
        let request = data.weatherRequestID
        for _ in 0..<5 { data.refreshWeather(options: WidgetOptions()) }
        #expect(publications == afterClear)
        #expect(data.weatherRequestID == request)
        #expect(data.temperature == nil)
        #expect(data.weatherTask == nil)
        withExtendedLifetime(subscription) { }
    }

    @MainActor
    @Test
    func testAllWidgetsDisabledTickIsQuietAndClockEnableResumesTick() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SettingsStore(url: folder.appendingPathComponent("settings.json"))
        let data = WidgetData()
        data.weatherStatus = "尚未清理"
        let controller = WidgetController(store: store, data: data)
        var publications = 0
        let subscription = data.objectWillChange.sink { _ in publications += 1 }
        for _ in 0..<5 { controller.tick() }
        #expect(publications == 0)
        #expect(data.weatherStatus == "尚未清理")
        store.config.widgets.clock = true
        controller.tick()
        #expect(data.weatherStatus == "天气未开启")
        #expect(publications > 0)
        #expect(data.weatherTask == nil)
        withExtendedLifetime(subscription) { }
    }

    @MainActor
    @Test
    func testCalendarTickStillRefreshesAfterIdleWithoutReadingUnauthorizedEvents() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SettingsStore(url: folder.appendingPathComponent("settings.json"))
        let data = WidgetData()
        data.events = ["已过期的测试条目"]
        let controller = WidgetController(store: store, data: data)
        for _ in 0..<5 { controller.tick() }
        #expect(data.events.count == 1)
        store.config.widgets.calendar = true
        // The injected data remains unauthorized/disabled, so the real refresh
        // clears stale test data without accessing the user's EventKit events.
        for _ in 0..<4 { controller.tick() }
        #expect(data.events.isEmpty)
        #expect(data.calendarStatus == "日历未开启")
    }

}
}


private final class MusicExecutionProbe: @unchecked Sendable {
    let releaseFirst = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let firstStarted: TestSignal
    private var recorded: [String] = []
    private var active = 0
    private var peak = 0

    init(firstStarted: TestSignal) { self.firstStarted = firstStarted }
    var commands: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    var maximumConcurrent: Int { lock.lock(); defer { lock.unlock() }; return peak }

    func execute(_ command: String) -> MusicExecutionResult {
        lock.lock()
        recorded.append(command); active += 1; peak = max(peak, active)
        let first = recorded.count == 1
        lock.unlock()
        if first {
            firstStarted.signal()
            _ = releaseFirst.wait(timeout: .now() + 4)
        }
        lock.lock(); active -= 1; lock.unlock()
        return MusicExecutionResult(title: command)
    }
}
