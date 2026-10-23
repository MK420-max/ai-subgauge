import AppKit
import Combine
import CoreLocation
import CoreWLAN
import IOKit.ps
import SwiftUI

struct RuleContext {
    var frontmostBundle = ""
    var frontmostName = ""
    var minutes = 0
    var battery: Int?
    var displays = 1
    var wifi: String?
    var focus: String?
}

enum RuleMatcher {
    static func matches(_ rule: TriggerRule, context: RuleContext) -> Bool {
        guard rule.enabled else { return false }
        let value = rule.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        switch rule.kind {
        case "app": return value.caseInsensitiveCompare(context.frontmostBundle) == .orderedSame || value.caseInsensitiveCompare(context.frontmostName) == .orderedSame
        case "battery":
            guard let threshold = Int(value), let battery = context.battery else { return false }
            return (0...100).contains(threshold) && battery <= threshold
        case "display":
            guard let required = Int(value), (1...32).contains(required) else { return false }
            return context.displays >= required
        case "wifi": return context.wifi == value
        case "focus": return context.focus == value
        case "time":
            let parts = value.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 2, let start = minutes(String(parts[0])), let end = minutes(String(parts[1])) else { return false }
            if start == end { return true }
            return start < end ? (start..<end).contains(context.minutes) : context.minutes >= start || context.minutes < end
        default: return false
        }
    }

    static func minutes(_ value: String) -> Int? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
              parts[0].utf8.allSatisfy({ (48...57).contains($0) }), parts[1].utf8.allSatisfy({ (48...57).contains($0) }),
              let hour = Int(parts[0]), let minute = Int(parts[1]), (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return hour * 60 + minute
    }

    static func batteryLevel() -> Int? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let capacity = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            return Int((Double(capacity) / Double(maximum) * 100).rounded())
        }
        return nil
    }
}

struct WiFiReadPlan {
    var requested = false

    mutating func shouldRead(enabledRule: Bool, authorized: Bool, awaitingAuthorization: Bool, servicesEnabled: Bool) -> Bool {
        let requested = self.requested
        if requested && (!awaitingAuthorization || !servicesEnabled) { self.requested = false }
        return (requested || enabledRule) && authorized && servicesEnabled
    }
}

@MainActor
final class AutomationController: NSObject, ObservableObject, CLLocationManagerDelegate {
    static weak var shared: AutomationController?
    @Published var status = L10n.text("automation.no.automation.rule.is.active")
    @Published var wifiStatus = L10n.text("automation.wi.fi.rules.need.location.access.to")
    private let store: SettingsStore
    private var timer: Timer?
    private let location = CLLocationManager()
    private var activeID: UUID?
    private var restorePoint: LayoutPreset?
    private var pendingRestorePoint: LayoutPreset?
    private var appliedPresetID: UUID?
    private var shouldRestore = false
    private var failedPresetID: UUID?
    private var focus: String?
    private var wifiReadPlan = WiFiReadPlan()
    private(set) var wifiHasName = false
    private(set) var wifiDiagnostics: [String: Any] = [:]
    var wifiAccessGranted: Bool { location.authorizationStatus == .authorizedAlways }

    init(store: SettingsStore) {
        self.store = store
        super.init()
        Self.shared = self
        location.delegate = self
    }

    func start() {
        guard timer == nil else { return }
        evaluate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil; wifiReadPlan.requested = false; restoreIfNeeded() }

    func setFocus(_ name: String?) { focus = name; evaluate() }
    func requestWiFiAccess() {
        wifiReadPlan.requested = true
        location.requestWhenInUseAuthorization()
        evaluate()
    }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.evaluate() }
    }

    func evaluate() {
        // Menu interactions may temporarily bring this app forward; evaluate the scene
        // after that interaction restores focus instead of treating it as a new scene.
        guard AppActions.shared.engine?.isBusy != true else { return }
        let now = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let app = NSWorkspace.shared.frontmostApplication
        let enabledWiFiRule = store.config.triggers.contains { $0.enabled && $0.kind == "wifi" }
        let wantsWifi = wifiReadPlan.requested || enabledWiFiRule
        let servicesEnabled = CLLocationManager.locationServicesEnabled()
        let authorized = wifiAccessGranted
        var wifi: String?
        var interfaceDiagnostics: [[String: Any]] = []
        let shouldRead = wifiReadPlan.shouldRead(enabledRule: enabledWiFiRule, authorized: authorized,
                                               awaitingAuthorization: location.authorizationStatus == .notDetermined,
                                               servicesEnabled: servicesEnabled)
        if shouldRead {
            let client = CWWiFiClient.shared()
            var interfaces = client.interfaces() ?? []
            if interfaces.isEmpty, let fallback = client.interface() { interfaces = [fallback] }
            let observations = interfaces.map { interface in
                (ssid: interface.ssid(), power: interface.powerOn(), serviceActive: interface.serviceActive(),
                 name: interface.interfaceName ?? L10n.text("automation.unknown.interface"), ssidDataPresent: interface.ssidData() != nil)
            }
            wifi = Self.preferredWiFiName(observations.map { (ssid: $0.ssid, power: $0.power, serviceActive: $0.serviceActive) })
            interfaceDiagnostics = observations.map {
                ["name": $0.name, "power": $0.power, "serviceActive": $0.serviceActive,
                 "ssidPresent": $0.ssid?.isEmpty == false, "ssidDataPresent": $0.ssidDataPresent]
            }
        }
        if wantsWifi {
            wifiHasName = wifi != nil
            wifiDiagnostics = ["authorized": authorized, "locationServicesEnabled": servicesEnabled,
                               "hasNetworkName": wifiHasName, "interfaces": interfaceDiagnostics]
            if !servicesEnabled {
                wifiStatus = L10n.text("automation.system.location.services.are.off.enable.them")
            } else {
                switch location.authorizationStatus {
                case .denied, .restricted: wifiStatus = L10n.text("automation.location.access.is.not.allowed.for.this")
                case .notDetermined: wifiStatus = L10n.text("automation.allow.location.access.in.the.system.prompt")
                default: wifiStatus = wifi.map { L10n.text("automation.current.network.0", $0) } ?? L10n.text("automation.location.access.is.allowed.but.the.system")
                }
            }
        }
        let context = RuleContext(frontmostBundle: app?.bundleIdentifier ?? "", frontmostName: app?.localizedName ?? "", minutes: (now.hour ?? 0) * 60 + (now.minute ?? 0), battery: RuleMatcher.batteryLevel(), displays: NSScreen.screens.count, wifi: wifi, focus: focus)
        evaluate(context: context)
    }

    static func preferredWiFiName(_ interfaces: [(ssid: String?, power: Bool, serviceActive: Bool)]) -> String? {
        let named = interfaces.filter { $0.ssid?.isEmpty == false }
        return (named.first { $0.power && $0.serviceActive } ?? named.first)?.ssid
    }

    func evaluate(context: RuleContext) {
        guard pendingRestorePoint == nil else { return }
        let matched = store.config.triggers.first { RuleMatcher.matches($0, context: context) && $0.presetID != nil }
        guard let rule = matched, let preset = store.config.presets.first(where: { $0.id == rule.presetID }) else {
            if activeID != nil, !restoreIfNeeded() { return }
            status = L10n.text("automation.no.automation.rule.is.active")
            return
        }
        guard rule.id != activeID || appliedPresetID != preset.id else {
            if failedPresetID == nil { shouldRestore = rule.restore }
            return
        }
        guard restoreIfNeeded() else { return }
        restorePoint = LayoutPreset(name: L10n.text("automation.layout.before.automation"), rules: store.config.rules, order: store.config.order, style: store.config.style)
        shouldRestore = rule.restore
        activeID = rule.id
        appliedPresetID = preset.id
        failedPresetID = nil
        status = L10n.text("automation.applying.0.1", rule.name, preset.name)
        guard store.applyPreset(preset) else {
            presetApplicationFailed(id: preset.id, message: store.error ?? L10n.text("automation.settings.could.not.be.saved"))
            return
        }
    }

    func presetApplicationFailed(id: UUID, message: String) {
        guard appliedPresetID == id, pendingRestorePoint == nil else { return }
        failedPresetID = id
        restorePoint = nil
        shouldRestore = false
        status = L10n.text("automation.automatic.preset.failed.0.click.check.now", message)
    }

    func retryFailedPreset(context: RuleContext? = nil) {
        if let pendingRestorePoint, !attemptRestore(pendingRestorePoint) { return }
        if failedPresetID != nil { clearActiveState() }
        if let context { evaluate(context: context) }
        else { evaluate() }
    }

    @discardableResult
    private func restoreIfNeeded() -> Bool {
        guard pendingRestorePoint == nil else { return false }
        if shouldRestore, let saved = restorePoint { return attemptRestore(saved) }
        clearActiveState()
        return true
    }

    private func attemptRestore(_ saved: LayoutPreset) -> Bool {
        guard store.applyPreset(saved) else {
            pendingRestorePoint = saved
            status = L10n.text("automation.automatic.layout.restoration.failed.0.click.check", store.error ?? L10n.text("automation.settings.could.not.be.saved"))
            return false
        }
        clearActiveState()
        return true
    }

    private func clearActiveState() {
        activeID = nil
        appliedPresetID = nil
        restorePoint = nil
        pendingRestorePoint = nil
        shouldRestore = false
        failedPresetID = nil
    }
}

struct AutomationSettingsView: View {
    @ObservedObject var store: SettingsStore
    
    private let kinds = [("app", L10n.text("automation.frontmost.app")), ("time", L10n.text("automation.daily.time.range")), ("battery", L10n.text("automation.battery.at.or.below")), ("display", L10n.text("automation.display.count")), ("wifi", L10n.text("automation.wi.fi.network")), ("focus", L10n.text("automation.focus.scene"))]

    var body: some View {
        SettingsPage {
            SettingsGroup(title: L10n.text("automation.rule")) {
                Text(L10n.text("automation.switch.presets.when.conditions.match.if.several"))
                    .foregroundStyle(.secondary)
                if store.config.presets.isEmpty { Text(L10n.text("automation.save.a.layout.on.the.presets.page")).foregroundStyle(.orange) }
                ForEach($store.config.triggers) { $rule in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            TextField(L10n.text("automation.rule.name"), text: $rule.name)
                            Button(role: .destructive) { store.config.triggers.removeAll { $0.id == rule.id } } label: { Image(systemName: "trash") }.help(L10n.text("automation.delete.rule"))
                        }
                        Toggle(L10n.text("automation.enabled"), isOn: $rule.enabled)
                        HStack {
                            Picker(L10n.text("automation.condition"), selection: $rule.kind) { ForEach(kinds, id: \.0) { key, label in Text(label).tag(key) } }.frame(width: 205)
                            if rule.kind == "battery" || rule.kind == "display" {
                                Stepper(value: Binding(
                                    get: { Int(rule.value) ?? (rule.kind == "battery" ? 0 : 1) },
                                    set: { rule.value = String($0) }
                                ), in: rule.kind == "battery" ? 0...100 : 1...32) {
                                    Text(rule.value.isEmpty ? placeholder(rule.kind) : rule.value).monospacedDigit()
                                }
                            } else {
                                TextField(placeholder(rule.kind), text: $rule.value)
                            }
                        }
                        Picker(L10n.text("menu.apply.preset"), selection: $rule.presetID) {
                            Text(L10n.text("automation.select.a.preset")).tag(nil as UUID?)
                            ForEach(store.config.presets) { Text($0.name).tag(Optional($0.id)) }
                        }
                        Toggle(L10n.text("automation.restore.the.original.layout.when.the.condition"), isOn: $rule.restore)
                        if rule.kind == "focus" {
                            Text(L10n.text("automation.pass.a.focus.scene.from.macos.shortcuts"))
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        if rule.kind == "wifi" {
                            Button(L10n.text("automation.allow.wi.fi.name.access")) { AutomationController.shared?.requestWiFiAccess() }
                        }
                    }.padding(.vertical, 6)
                }
                Button(L10n.text("automation.add.automation.rule"), systemImage: "plus") {
                    var draft = TriggerRule(); draft.enabled = false
                    store.config.triggers.append(draft)
                }.disabled(store.config.triggers.count >= 200)
            }
            SettingsGroup(title: L10n.text("automation.current.status")) {
                if let controller = AutomationController.shared {
                    AutomationStatusView(controller: controller)
                } else { Text(L10n.text("automation.the.automation.service.has.not.started")) }
            }
        }
    }

    private func placeholder(_ kind: String) -> String {
        switch kind {
        case "app": return L10n.text("automation.app.name.or.identifier.e.g.com")
        case "time": return L10n.text("automation.09.00.18.00.supports.overnight.ranges")
        case "battery": return L10n.text("automation.0.to.100.e.g.20")
        case "display": return L10n.text("automation.at.least.this.many.e.g.2")
        case "wifi": return L10n.text("automation.exact.wi.fi.name")
        default: return L10n.text("automation.scene.name.e.g.work")
        }
    }
}

private struct AutomationStatusView: View {
    @ObservedObject var controller: AutomationController
    var body: some View {
        Text(controller.status)
        Text(controller.wifiStatus).font(.caption).foregroundStyle(.secondary)
        Button(L10n.text("automation.read.current.wi.fi.name")) { controller.requestWiFiAccess() }
        Button(L10n.text("automation.check.now")) { controller.retryFailedPreset() }
    }
}
