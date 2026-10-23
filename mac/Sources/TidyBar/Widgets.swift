import AppKit
import SwiftUI
import EventKit
import Combine

struct WeatherResponse: Decodable {
    struct Current: Decodable { var temperature_2m: Double; var weather_code: Int }
    var current: Current
}

struct MusicPhaseDiagnostic: Sendable {
    var stage: String
    var elapsed: TimeInterval
    var errorCode: Int?
    var errorRange: NSRange?
    var errorAppName: String?
    var dictionary: [String: Any] {
        var value: [String: Any] = ["stage": stage, "elapsedSeconds": elapsed]
        if let errorCode { value["errorCode"] = errorCode }
        if let errorRange { value["errorRange"] = ["location": errorRange.location, "length": errorRange.length] }
        if let errorAppName { value["errorAppName"] = errorAppName }
        return value
    }
}

struct MusicExecutionResult: Sendable {
    var title: String?
    var error: String?
    var errorCode: Int?
    var errorRange: NSRange?
    var errorAppName: String?
    var stage: String?
    var diagnostics: [MusicPhaseDiagnostic] = []
}

@MainActor
final class WidgetData: ObservableObject {
    static let shared = WidgetData()
    @Published var calendarStatus = L10n.text("widgets.access.has.not.been.requested.click.the")
    @Published var musicStatus = L10n.text("widgets.click.connect.music.to.read.playback.information")
    @Published private(set) var musicStage = L10n.text("widgets.disabled")
    @Published var weatherStatus = L10n.text("widgets.weather.is.off")
    @Published var events: [String] = []
    @Published var musicTitle = L10n.text("widgets.music")
    @Published var temperature: Double?
    @Published var weatherCode: Int?
    let eventStore = EKEventStore()
    var musicConnected = false
    var calendarEnabled = false {
        didSet {
            guard oldValue != calendarEnabled else { return }
            calendarGeneration = UUID()
            if !calendarEnabled { events = []; calendarStatus = L10n.text("widgets.calendar.is.off") }
        }
    }
    private var calendarGeneration = UUID()
    private var musicEnabled = false
    private var musicSession = UUID()
    private var musicRequestID = UUID()
    private(set) var musicTask: Task<Void, Never>?
    private var musicDiagnostics: [MusicPhaseDiagnostic] = []
    @Published private(set) var canExtendMusicCheck = false
    private let musicExecutor: (@MainActor (String) async -> MusicExecutionResult)?
    private let calendarAccessRequest: (() async throws -> Bool)?

    init(musicExecutor: (@MainActor (String) async -> MusicExecutionResult)? = nil,
         calendarAccessRequest: (() async throws -> Bool)? = nil) {
        self.musicExecutor = musicExecutor
        self.calendarAccessRequest = calendarAccessRequest
    }
    var diagnosticState: [String: Any] {
        let calendarAuthorization: String
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: calendarAuthorization = L10n.text("widgets.not.requested")
        case .restricted: calendarAuthorization = L10n.text("widgets.restricted")
        case .denied: calendarAuthorization = L10n.text("widgets.denied")
        case .fullAccess: calendarAuthorization = L10n.text("widgets.full.read.access")
        case .writeOnly: calendarAuthorization = L10n.text("widgets.write.only")
        @unknown default: calendarAuthorization = L10n.text("widgets.unknown")
        }
        return ["calendarAuthorization": calendarAuthorization, "calendarEnabled": calendarEnabled,
                "calendarEventCount": events.count, "musicEnabled": musicEnabled,
                "musicConnected": musicConnected, "musicStage": musicStage,
                "musicPhases": musicDiagnostics.map(\.dictionary)]
    }

    var weatherDate: Date?
    var weatherAttemptDate: Date?
    var weatherTask: Task<Void, Never>?
    var weatherCoordinate = ""
    var weatherRequestID = UUID()

    @discardableResult
    func requestCalendar() -> Task<Void, Never>? {
        guard calendarEnabled else { return nil }
        let generation = calendarGeneration
        return Task {
            guard calendarEnabled, calendarGeneration == generation, !Task.isCancelled else { return }
            do {
                let granted: Bool
                if let calendarAccessRequest { granted = try await calendarAccessRequest() }
                else { granted = try await eventStore.requestFullAccessToEvents() }
                guard calendarEnabled, calendarGeneration == generation, !Task.isCancelled else { return }
                if granted { refreshCalendar() }
                else { calendarStatus = L10n.text("widgets.calendar.access.is.not.allowed.enable.it") }
            } catch {
                guard calendarEnabled, calendarGeneration == generation, !Task.isCancelled else { return }
                calendarStatus = L10n.text("widgets.could.not.request.calendar.access.0", error.localizedDescription)
            }
        }
    }
    func refreshCalendar() {
        guard calendarEnabled else { events = []; calendarStatus = L10n.text("widgets.calendar.is.off"); return }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            calendarStatus = L10n.text("widgets.calendar.read.access.has.not.been.granted"); events = []; return
        }
        let now = Date()
        let predicate = eventStore.predicateForEvents(withStart: now, end: now.addingTimeInterval(7 * 86400), calendars: nil)
        let upcoming = eventStore.events(matching: predicate).filter { $0.endDate > now }.sorted { $0.startDate < $1.startDate }.prefix(8)
        let format = DateFormatter(); format.locale = L10n.locale; format.dateFormat = L10n.text("widgets.mmm.d.eee.hh.mm")
        events = upcoming.map { "\($0.isAllDay ? DateFormatter.localizedString(from: $0.startDate, dateStyle: .short, timeStyle: .none) + L10n.text("widgets.all.day") : format.string(from: $0.startDate))  \($0.title ?? L10n.text("widgets.untitled.event"))" }
        calendarStatus = events.isEmpty ? L10n.text("widgets.no.events.in.the.next.7.days") : L10n.text("widgets.0.upcoming.events.in.the.next.7", events.count)
    }
    func setMusicEnabled(_ enabled: Bool) {
        guard enabled != musicEnabled else { return }
        musicEnabled = enabled
        musicSession = UUID()
        musicRequestID = UUID()
        canExtendMusicCheck = false
        musicDiagnostics = []
        if !enabled {
            musicTask?.cancel()
            musicConnected = false
            musicTitle = L10n.text("widgets.music")
            musicStatus = L10n.text("widgets.the.music.widget.is.off")
            musicStage = L10n.text("widgets.disabled")
        } else {
            musicStatus = L10n.text("widgets.click.connect.music.to.read.playback.information")
            musicStage = L10n.text("widgets.not.connected.yet")
        }
    }

    func music(command: String = "info") {
        guard musicEnabled else { return }
        let previous = musicTask
        let session = musicSession
        let requestID = UUID()
        musicRequestID = requestID
        let execute = musicExecutor
        if command == "info-long" { canExtendMusicCheck = false }
        musicStage = L10n.text("widgets.queued")
        musicStatus = L10n.text("widgets.waiting.for.the.music.operation.please.wait")
        // Preserve click order. NSAppleScript stays on the main thread. Each event
        // waits at most four seconds; a timeout does not cancel the target's action.
        // Control commands are sent once, with no automatic retry.
        musicTask = Task {
            await previous?.value
            guard musicEnabled, musicSession == session, !Task.isCancelled else { return }
            if musicRequestID == requestID {
                musicStage = L10n.text("widgets.running")
                musicStatus = command == "info" ? L10n.text("widgets.reading.music.status.please.wait") : L10n.text("widgets.performing.the.music.operation.please.wait")
            }
            await Task.yield()
            guard musicEnabled, musicSession == session, !Task.isCancelled else { return }
            let result: MusicExecutionResult
            if let execute { result = await execute(command) }
            else {
                result = await Self.executeMusicScript(command: command, shouldContinue: { self.musicEnabled && self.musicSession == session }, stageChanged: { stage in
                    if self.musicEnabled && self.musicSession == session && self.musicRequestID == requestID {
                        self.musicStage = stage
                    }
                })
            }
            guard musicEnabled, musicSession == session, musicRequestID == requestID, !Task.isCancelled else { return }
            musicDiagnostics = result.diagnostics
            canExtendMusicCheck = command != "info-long" && result.stage == L10n.text("widgets.read.version") && result.errorCode == -1712
            if let error = result.error {
                switch result.errorCode {
                case -1712: musicStatus = L10n.text("widgets.music.timed.out.0.try.connecting.again", result.stage.map { L10n.text("widgets.during.0", $0) } ?? "")
                case -1743: musicStatus = L10n.text("widgets.music.control.access.is.not.allowed.check")
                default: musicStatus = L10n.text("widgets.could.not.connect.to.music.0", error)
                }
                musicConnected = false
                musicStage = (result.stage ?? "") + (result.errorCode == -1712 ? L10n.text("widgets.timed.out") : L10n.text("widgets.failed"))
            } else if let title = result.title {
                musicConnected = title != L10n.text("widgets.not.running")
                musicStage = title == L10n.text("widgets.not.running") ? L10n.text("widgets.not.running") : L10n.text("widgets.succeeded")
                musicTitle = title
                musicStatus = title == L10n.text("widgets.not.running") ? L10n.text("widgets.music.is.not.running.open.music.then") : L10n.text("widgets.current.0", title)
            } else {
                musicConnected = false
                musicStatus = L10n.text("widgets.music.did.not.return.playback.status.try")
                musicStage = L10n.text("widgets.failed")
            }
        }
    }

    static func executeMusicScript(command: String,
                                   runningCheck: () -> Bool = { !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty },
                                   scriptExecutor: @MainActor (String) -> MusicExecutionResult = WidgetData.runMusicPhase,
                                   shouldContinue: @MainActor () -> Bool = { true },
                                   stageChanged: @MainActor (String) -> Void = { _ in }) async -> MusicExecutionResult {
        let checkStart = Date()
        stageChanged(L10n.text("widgets.check.running.status"))
        let running = runningCheck()
        var diagnostics = [MusicPhaseDiagnostic(stage: L10n.text("widgets.check.running.status"), elapsed: Date().timeIntervalSince(checkStart))]
        guard running else { return MusicExecutionResult(title: L10n.text("widgets.not.running"), diagnostics: diagnostics) }

        func phase(_ name: String, _ body: String, timeout: Int = 4) async -> MusicExecutionResult {
            stageChanged(name)
            await Task.yield()
            guard !Task.isCancelled && shouldContinue() else { return MusicExecutionResult(error: L10n.text("widgets.operation.cancelled"), stage: name, diagnostics: diagnostics) }
            let source = """
            with timeout of \(timeout) seconds
                tell application id "com.apple.Music"
                    \(body)
                end tell
            end timeout
            """
            let start = Date()
            var result = scriptExecutor(source)
            diagnostics.append(MusicPhaseDiagnostic(stage: name, elapsed: Date().timeIntervalSince(start), errorCode: result.errorCode, errorRange: result.errorRange, errorAppName: result.errorAppName))
            result.stage = name
            result.diagnostics = diagnostics
            return result
        }
        let action: String?
        switch command {
        case "playpause": action = "playpause"
        case "next": action = "next track"
        case "previous": action = "previous track"
        default: action = nil
        }
        if let action {
            let result = await phase(L10n.text("widgets.execute.control"), action + "\nreturn \"完成\"")
            if result.error != nil { return result }
        } else {
            let result = await phase(L10n.text("widgets.read.version"), "return version", timeout: command == "info-long" ? 30 : 4)
            if result.error != nil { return result }
        }
        let state = await phase(L10n.text("widgets.read.playback.status"), "return (player state is stopped) as text")
        if state.error != nil { return state }
        if state.title == "true" { return MusicExecutionResult(title: L10n.text("widgets.not.playing"), diagnostics: diagnostics) }
        return await phase(L10n.text("widgets.read.current.song"), """
            set trackProperties to properties of current track
            return (name of trackProperties) & " — " & (artist of trackProperties)
            """)
    }

    private static func runMusicPhase(_ source: String) -> MusicExecutionResult {
        guard let script = NSAppleScript(source: source) else { return MusicExecutionResult(error: L10n.text("widgets.could.not.create.the.music.control.script")) }
        var error: NSDictionary?
        let output = script.executeAndReturnError(&error).stringValue
        if let error {
            return MusicExecutionResult(error: L10n.text("widgets.music.automation.request.failed"), errorCode: error[NSAppleScript.errorNumber] as? Int,
                                        errorRange: (error[NSAppleScript.errorRange] as? NSValue)?.rangeValue,
                                        errorAppName: error[NSAppleScript.errorAppName] as? String)
        }
        guard let output else { return MusicExecutionResult(error: L10n.text("widgets.music.did.not.return.a.valid.state")) }
        return MusicExecutionResult(title: output)
    }
    func refreshWeather(options: WidgetOptions, force: Bool = false) {
        guard options.weather else {
            guard weatherTask != nil || temperature != nil || weatherCode != nil || weatherDate != nil || weatherAttemptDate != nil || !weatherCoordinate.isEmpty || weatherStatus != L10n.text("widgets.weather.is.off") else { return }
            weatherTask?.cancel(); weatherTask = nil; weatherRequestID = UUID()
            if temperature != nil { temperature = nil }
            if weatherCode != nil { weatherCode = nil }
            weatherDate = nil; weatherAttemptDate = nil; weatherCoordinate = ""
            if weatherStatus != L10n.text("widgets.weather.is.off") { weatherStatus = L10n.text("widgets.weather.is.off") }
            return
        }
        guard options.weatherLatitude.isFinite, options.weatherLongitude.isFinite, (-90...90).contains(options.weatherLatitude), (-180...180).contains(options.weatherLongitude) else {
            weatherTask?.cancel(); weatherTask = nil; weatherRequestID = UUID(); temperature = nil; weatherCode = nil; weatherDate = nil; weatherAttemptDate = nil; weatherCoordinate = ""; weatherStatus = L10n.text("widgets.invalid.coordinates.latitude.must.be.90.to"); return
        }
        let coordinate = "\(options.weatherLatitude),\(options.weatherLongitude)"
        if !force && coordinate == weatherCoordinate {
            if let temperature, let weatherCode, weatherDate != nil {
                weatherStatus = L10n.text("widgets.0.1.c.2.using.the.latest", options.weatherCity, Int(temperature.rounded()), Self.weatherDescription(weatherCode))
            }
            if weatherTask != nil { return }
            if let date = weatherAttemptDate, Date().timeIntervalSince(date) < 1800 { return }
        }
        weatherTask?.cancel(); weatherCoordinate = coordinate; weatherAttemptDate = Date()
        weatherStatus = L10n.text("widgets.getting.weather.for.0", options.weatherCity)
        let city = options.weatherCity
        let requestID = UUID(); weatherRequestID = requestID
        weatherTask = Task {
            defer { if self.weatherRequestID == requestID { self.weatherTask = nil } }
            do {
                guard var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast") else { throw URLError(.badURL) }
                components.queryItems = [URLQueryItem(name: "latitude", value: String(options.weatherLatitude)), URLQueryItem(name: "longitude", value: String(options.weatherLongitude)), URLQueryItem(name: "current", value: "temperature_2m,weather_code"), URLQueryItem(name: "timezone", value: "auto")]
                guard let url = components.url else { throw URLError(.badURL) }
                var request = URLRequest(url: url); request.timeoutInterval = 15
                let (data, response) = try await URLSession.shared.data(for: request)
                try Task.checkCancellation()
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                let forecast = try JSONDecoder().decode(WeatherResponse.self, from: data)
                temperature = forecast.current.temperature_2m; weatherCode = forecast.current.weather_code; weatherDate = Date()
                weatherStatus = L10n.text("widgets.0.1.c.2.just.updated", city, Int(forecast.current.temperature_2m.rounded()), Self.weatherDescription(forecast.current.weather_code))
            } catch is CancellationError { }
            catch { if !Task.isCancelled { temperature = nil; weatherStatus = L10n.text("widgets.weather.update.failed.0.click.to.retry", error.localizedDescription) } }
        }
    }
    static func weatherDescription(_ code: Int) -> String {
        switch code { case 0: return L10n.text("widgets.clear"); case 1...3: return L10n.text("widgets.cloudy"); case 45, 48: return L10n.text("widgets.fog"); case 51...57: return L10n.text("widgets.drizzle"); case 61...67: return L10n.text("widgets.rain"); case 71...77: return L10n.text("widgets.snow"); case 80...82: return L10n.text("widgets.rain.showers"); case 85,86: return L10n.text("widgets.snow.showers"); case 95...99: return L10n.text("widgets.thunderstorm"); default: return L10n.text("widgets.unknown.weather") }
    }
}

@MainActor
final class WidgetController: NSObject, NSMenuDelegate {
    private let store: SettingsStore
    private let data: WidgetData
    private var items: [String: NSStatusItem] = [:]
    private var timer: Timer?
    private var observation: NSObjectProtocol?
    private var subscription: AnyCancellable?
    private var tickCount = 0
    init(store: SettingsStore, data: WidgetData? = nil) { self.store = store; self.data = data ?? .shared; super.init() }
    func start() {
        guard timer == nil else { return }
        subscription = data.objectWillChange.sink { [weak self] _ in Task { @MainActor in self?.render() } }
        observation = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in
            guard let self, self.store.config.widgets.calendar else { return }
            self.data.refreshCalendar(); self.render()
        } }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        update()
    }
    func stop() {
        timer?.invalidate(); timer = nil
        subscription?.cancel(); subscription = nil
        if let observation { NotificationCenter.default.removeObserver(observation) }; observation = nil
        for item in items.values { NSStatusBar.system.removeStatusItem(item) }; items.removeAll()
        data.calendarEnabled = false
        data.setMusicEnabled(false)
        data.refreshWeather(options: WidgetOptions())
    }
    func update() {
        let widgets = store.config.widgets
        data.calendarEnabled = widgets.calendar
        data.setMusicEnabled(widgets.music)
        for (id, enabled) in [("clock", widgets.clock), ("calendar", widgets.calendar), ("music", widgets.music), ("weather", widgets.weather)] {
            if enabled && items[id] == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                item.autosaveName = "com.mike.aisubgauge.widget.\(id)"
                item.button?.setAccessibilityIdentifier("com.mike.aisubgauge.widget.\(id)")
                let menu = NSMenu(); menu.identifier = NSUserInterfaceItemIdentifier(id); menu.delegate = self; item.menu = menu
                items[id] = item
            } else if !enabled, let item = items.removeValue(forKey: id) { NSStatusBar.system.removeStatusItem(item) }
        }
        if widgets.calendar { data.refreshCalendar() }
        data.refreshWeather(options: widgets)
        render()
    }
    func tick() {
        let widgets = store.config.widgets
        guard widgets.clock || widgets.calendar || widgets.music || widgets.weather else { return }
        tickCount += 1
        if tickCount % 4 == 0 && store.config.widgets.calendar { data.refreshCalendar() }
        if store.config.widgets.music && data.musicConnected && tickCount % 2 == 0 { data.music() }
        data.refreshWeather(options: store.config.widgets)
        render()
    }
    private func render() {
        let format = DateFormatter(); format.locale = L10n.locale; format.dateFormat = L10n.text("widgets.mmm.d.eee.hh.mm")
        items["clock"]?.button?.title = format.string(from: Date()); items["clock"]?.button?.toolTip = L10n.text("widgets.clock")
        items["calendar"]?.button?.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: L10n.text("widgets.upcoming.calendar"))
        items["calendar"]?.button?.toolTip = data.calendarStatus
        items["music"]?.button?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: L10n.text("widgets.music.controls"))
        items["music"]?.button?.toolTip = data.musicStatus
        items["weather"]?.button?.title = data.temperature.map { "\(Int($0.rounded()))°" } ?? L10n.text("widgets.weather")
        items["weather"]?.button?.toolTip = data.weatherStatus
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ selector: Selector? = nil) { let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; menu.addItem(item) }
        switch menu.identifier?.rawValue {
        case "clock":
            let format = DateFormatter(); format.locale = L10n.locale; format.dateStyle = .full; format.timeStyle = .medium
            add(format.string(from: Date())); add(L10n.text("widgets.copy.current.time"), #selector(copyTime))
        case "calendar":
            data.refreshCalendar(); add(data.calendarStatus)
            for event in data.events { add(event) }
            menu.addItem(.separator()); add(L10n.text("widgets.allow.calendar.access"), #selector(allowCalendar)); add(L10n.text("widgets.open.calendar"), #selector(openCalendar))
        case "music":
            add(data.musicStatus); add(L10n.text("widgets.connect.music.refresh"), #selector(connectMusic))
            if data.canExtendMusicCheck { add(L10n.text("widgets.extend.connection.check.up.to.30.seconds"), #selector(extendMusicCheck)) }
            menu.addItem(.separator())
            add(L10n.text("widgets.play.pause"), #selector(playPause)); add(L10n.text("widgets.previous.track"), #selector(previousTrack)); add(L10n.text("widgets.next.track"), #selector(nextTrack)); add(L10n.text("widgets.open.music"), #selector(openMusic))
        case "weather":
            add(data.weatherStatus); if let date = data.weatherDate { add(L10n.text("widgets.updated.0", DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short))) }
            add(L10n.text("widgets.refresh.weather"), #selector(refreshWeather)); add(L10n.text("widgets.weather.data.open.meteo"), #selector(openWeatherSource))
        default: break
        }
    }
    @objc private func copyTime() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(DateFormatter.localizedString(from: Date(), dateStyle: .full, timeStyle: .medium), forType: .string) }
    @objc private func allowCalendar() { data.requestCalendar() }
    @objc private func connectMusic() { data.music() }
    @objc private func extendMusicCheck() { data.music(command: "info-long") }
    @objc private func playPause() { data.music(command: "playpause") }
    @objc private func previousTrack() { data.music(command: "previous") }
    @objc private func nextTrack() { data.music(command: "next") }
    @objc private func refreshWeather() { data.refreshWeather(options: store.config.widgets, force: true) }
    @objc private func openCalendar() { if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") { NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) } }
    @objc private func openMusic() { if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") { NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) } }
    @objc private func openWeatherSource() { if let url = URL(string: "https://open-meteo.com/") { NSWorkspace.shared.open(url) } }
}

struct WidgetSettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject private var data = WidgetData.shared
    var body: some View {
        SettingsPage {
            SettingsGroup(title: L10n.text("widgets.clock")) {
                Toggle(L10n.text("widgets.show.date.and.time.in.the.menu"), isOn: $store.config.widgets.clock)
                Text(L10n.text("widgets.uses.the.current.system.time.zone.click")).font(.caption).foregroundStyle(.secondary)
            }
            SettingsGroup(title: L10n.text("widgets.upcoming.calendar")) {
                Toggle(L10n.text("widgets.show.calendar.widget"), isOn: $store.config.widgets.calendar)
                if store.config.widgets.calendar {
                    Text(data.calendarStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Button(L10n.text("widgets.allow.calendar.access")) { data.requestCalendar() }
                    ForEach(Array(data.events.enumerated()), id: \.offset) { _, event in Text(event).font(.callout) }
                }
            }
            SettingsGroup(title: L10n.text("widgets.music.controls")) {
                Toggle(L10n.text("widgets.show.music.widget"), isOn: Binding(
                    get: { store.config.widgets.music },
                    set: { enabled in
                        store.config.widgets.music = enabled
                        data.setMusicEnabled(enabled)
                    }
                ))
                if store.config.widgets.music {
                    Text(data.musicStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], alignment: .leading, spacing: 8) {
                        Button(L10n.text("widgets.connect.music")) { data.music() }
                        Button(L10n.text("widgets.previous.track")) { data.music(command: "previous") }
                        Button(L10n.text("widgets.play.pause")) { data.music(command: "playpause") }
                        Button(L10n.text("widgets.next.track")) { data.music(command: "next") }
                    }
                    if data.canExtendMusicCheck {
                        Button(L10n.text("widgets.extend.connection.check.up.to.30.seconds")) { data.music(command: "info-long") }
                            .help(L10n.text("widgets.only.extends.the.wait.for.reading.the"))
                    }
                    Text(L10n.text("widgets.controls.the.macos.music.app.the.system")).font(.caption).foregroundStyle(.secondary)
                }
            }
            SettingsGroup(title: L10n.text("widgets.weather.751")) {
                Toggle(L10n.text("widgets.show.weather.widget"), isOn: $store.config.widgets.weather)
                if store.config.widgets.weather {
                    TextField(L10n.text("widgets.city.name"), text: $store.config.widgets.weatherCity)
                    HStack {
                        Text(L10n.text("widgets.latitude"))
                        Spacer()
                        TextField(L10n.text("widgets.latitude"), value: $store.config.widgets.weatherLatitude, format: .number.precision(.fractionLength(4)))
                            .labelsHidden().frame(width: 100)
                        Stepper(L10n.text("widgets.latitude"), value: $store.config.widgets.weatherLatitude, in: -90...90, step: 0.0001)
                            .labelsHidden()
                    }
                    HStack {
                        Text(L10n.text("widgets.longitude"))
                        Spacer()
                        TextField(L10n.text("widgets.longitude"), value: $store.config.widgets.weatherLongitude, format: .number.precision(.fractionLength(4)))
                            .labelsHidden().frame(width: 100)
                        Stepper(L10n.text("widgets.longitude"), value: $store.config.widgets.weatherLongitude, in: -180...180, step: 0.0001)
                            .labelsHidden()
                    }
                    Text(data.weatherStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Button(L10n.text("widgets.refresh.weather")) { data.refreshWeather(options: store.config.widgets, force: true) }
                    Text(L10n.text("widgets.when.enabled.only.the.entered.coordinates.are")).font(.caption).foregroundStyle(.secondary)
                    if let url = URL(string: "https://open-meteo.com/") { Link(L10n.text("widgets.open.meteo.weather.data.and.license"), destination: url) }
                }
            }
        }
    }
}
