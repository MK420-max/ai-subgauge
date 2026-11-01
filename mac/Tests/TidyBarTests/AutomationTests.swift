import Foundation
import Testing
import Combine
@testable import TidyBar

extension TidyBarTests {
@Suite
final class AutomationTests {
    private func match(_ kind: String, _ value: String, _ context: RuleContext, enabled: Bool = true) -> Bool {
        RuleMatcher.matches(TriggerRule(kind: kind, value: value, enabled: enabled), context: context)
    }

    @Test
    func testDailyIntervalIncludesStartAndExcludesEnd() {
        #expect(!(match("time", "09:00-18:00", RuleContext(minutes: 539))))
        #expect(match("time", "09:00-18:00", RuleContext(minutes: 540)))
        #expect(match("time", "09:00-18:00", RuleContext(minutes: 1079)))
        #expect(!(match("time", "09:00-18:00", RuleContext(minutes: 1080))))
    }

    @Test
    func testOvernightIntervalCrossesMidnight() {
        #expect(!(match("time", "22:30-06:15", RuleContext(minutes: 1349))))
        #expect(match("time", "22:30-06:15", RuleContext(minutes: 1350)))
        #expect(match("time", "22:30-06:15", RuleContext(minutes: 1439)))
        #expect(match("time", "22:30-06:15", RuleContext(minutes: 0)))
        #expect(match("time", "22:30-06:15", RuleContext(minutes: 374)))
        #expect(!(match("time", "22:30-06:15", RuleContext(minutes: 375))))
    }

    @Test
    func testEqualIntervalEndpointsMeanWholeDay() {
        #expect(match("time", "09:00-09:00", RuleContext(minutes: 0)))
        #expect(match("time", "09:00-09:00", RuleContext(minutes: 539)))
        #expect(match("time", "09:00-09:00", RuleContext(minutes: 540)))
        #expect(match("time", "09:00-09:00", RuleContext(minutes: 1439)))
    }

    @Test
    func testInvalidTimesNeverActivateEvenDuringLiveEditing() {
        for text in ["25:00-26:00", "09:60-18:00", "9:00-18:00", "09:00-18:0", "09:00", "09:00--18:00", "-09:00-18:00", "09:00-18:00-", "+0:00-18:00", "09:+0-18:00"] {
            #expect(!(match("time", text, RuleContext(minutes: 600))), "Invalid interval: \(text)")
        }
    }

    @Test
    func testBatteryThresholdAndUnknownPowerSource() {
        #expect(!(match("battery", "20", RuleContext(battery: nil))))
        #expect(!(match("battery", "20", RuleContext(battery: 21))))
        #expect(match("battery", "20", RuleContext(battery: 20)))
        #expect(match("battery", "20", RuleContext(battery: 19)))
        #expect(match("battery", "0", RuleContext(battery: 0)))
        #expect(match("battery", "100", RuleContext(battery: 100)))
        #expect(!(match("battery", "101", RuleContext(battery: 20))))
        #expect(!(match("battery", "-1", RuleContext(battery: 20))))
        #expect(!(match("battery", "20%", RuleContext(battery: 20))))
    }

    @Test
    func testDisplayThresholdIsAtLeastTheRequestedNumber() {
        #expect(!(match("display", "2", RuleContext(displays: 1))))
        #expect(match("display", "2", RuleContext(displays: 2)))
        #expect(match("display", "2", RuleContext(displays: 3)))
        #expect(!(match("display", "many", RuleContext(displays: 2))))
    }

    @Test
    func testInvalidDisplayConditionsNeverActivateDuringLiveEditing() {
        for value in ["0", "-1", "33", "1.5"] {
            #expect(!(match("display", value, RuleContext(displays: 40))), "Invalid display threshold: \(value)")
        }
    }

    @Test
    func testApplicationAcceptsExactBundleOrNameWithoutCaseSensitivity() {
        let context = RuleContext(frontmostBundle: "com.apple.Safari", frontmostName: "Safari")
        #expect(match("app", " COM.APPLE.SAFARI ", context))
        #expect(match("app", "safari", context))
        #expect(!(match("app", "Safari Helper", context)))
        #expect(!(match("app", "com.apple", context)))
    }

    @Test
    func testWiFiAndFocusRequireExactNamedContext() {
        #expect(!(match("wifi", "Example", RuleContext(wifi: nil))))
        #expect(match("wifi", "Example", RuleContext(wifi: "Example")))
        #expect(!(match("wifi", "Example", RuleContext(wifi: "Example-Guest"))))
        #expect(!(match("wifi", "Example", RuleContext(wifi: "example"))))
        #expect(!(match("focus", "工作", RuleContext(focus: nil))))
        #expect(match("focus", "工作", RuleContext(focus: "工作")))
        #expect(!(match("focus", "工作", RuleContext(focus: "休息"))))
    }

    @Test
    func testDisabledEmptyAndUnknownConditionsNeverActivate() {
        let context = RuleContext(frontmostBundle: "com.apple.Safari", minutes: 600, battery: 20, displays: 2, wifi: "Example", focus: "工作")
        #expect(!(match("app", "com.apple.Safari", context, enabled: false)))
        #expect(!(match("time", "09:00-18:00", context, enabled: false)))
        #expect(!(match("app", "  ", context)))
        #expect(!(match("time", "", context)))
        #expect(!(match("script", "anything", context)))
    }
}
}

extension TidyBarTests.AutomationTests {
    @MainActor
    @Test
    func testAutomaticPresetRestoresOriginalAndGivesFirstRulePriority() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SettingsStore(url: folder.appendingPathComponent("settings.json"))
        let original = ItemRule(zone: .visible, group: "原布局")
        store.config.rules = ["test.app": original]
        let work = LayoutPreset(name: "工作", rules: ["test.app": ItemRule(zone: .hidden)], order: [], style: BarStyle())
        let other = LayoutPreset(name: "其他", rules: ["test.app": ItemRule(zone: .alwaysHidden)], order: [], style: BarStyle())
        store.config.presets = [work, other]
        store.config.triggers = [TriggerRule(name: "优先", kind: "app", value: "test.front", presetID: work.id),
                                 TriggerRule(name: "第二", kind: "battery", value: "100", presetID: other.id)]
        let controller = AutomationController(store: store)
        controller.evaluate(context: RuleContext(frontmostBundle: "test.front", battery: 30))
        #expect(store.config.rules == work.rules)
        controller.evaluate(context: RuleContext(frontmostBundle: "test.front", battery: 30))
        controller.evaluate(context: RuleContext(battery: nil))
        #expect(store.config.rules == ["test.app": original])
        #expect(try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: store.url)).rules == ["test.app": original])
        controller.stop()
    }

    @MainActor
    @Test
    func testRuleTransitionAndStopRestoreTheOriginalLayout() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SettingsStore(url: folder.appendingPathComponent("settings.json"))
        let first = LayoutPreset(name: "第一", rules: ["app": ItemRule(zone: .hidden)], order: [], style: BarStyle())
        let second = LayoutPreset(name: "第二", rules: ["app": ItemRule(zone: .alwaysHidden)], order: [], style: BarStyle())
        store.config.presets = [first, second]
        store.config.triggers = [TriggerRule(kind: "app", value: "first", presetID: first.id), TriggerRule(kind: "app", value: "second", presetID: second.id)]
        let controller = AutomationController(store: store)
        controller.evaluate(context: RuleContext(frontmostBundle: "first"))
        controller.evaluate(context: RuleContext(frontmostBundle: "second"))
        #expect(store.config.rules == second.rules)
        controller.stop()
        #expect(store.config.rules == [:])
    }

    @MainActor
    @Test
    func testRuleWithoutRestoreRetainsItsLayoutAfterConditionEnds() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SettingsStore(url: folder.appendingPathComponent("settings.json"))
        let preset = LayoutPreset(name: "保留", rules: ["app": ItemRule(zone: .hidden)], order: [], style: BarStyle())
        store.config.presets = [preset]
        store.config.triggers = [TriggerRule(kind: "focus", value: "工作", presetID: preset.id, restore: false)]
        let controller = AutomationController(store: store)
        controller.evaluate(context: RuleContext(focus: "工作"))
        controller.evaluate(context: RuleContext())
        #expect(store.config.rules == preset.rules)
        controller.stop()
        #expect(store.config.rules == preset.rules)
    }
}

extension TidyBarTests.AutomationTests {
    @MainActor
    private func withFailureScenario(_ check: @MainActor (SettingsStore, AutomationController, LayoutPreset, RuleContext, URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SettingsStore(url: folder.appendingPathComponent("配置/settings.json"))
        store.config.rules = ["test.app": ItemRule(zone: .visible, group: "原布局")]
        let preset = LayoutPreset(name: "失败重试", rules: ["test.app": ItemRule(zone: .hidden)], order: [], style: BarStyle())
        store.config.presets = [preset]
        store.config.triggers = [TriggerRule(kind: "app", value: "test.front", presetID: preset.id)]
        let controller = AutomationController(store: store)
        defer { controller.stop(); try? FileManager.default.removeItem(at: folder) }
        try check(store, controller, preset, RuleContext(frontmostBundle: "test.front"), folder)
    }

    @MainActor
    @Test
    func testSynchronousSaveFailureWaitsForExplicitRetry() throws {
        try withFailureScenario { store, controller, preset, context, _ in
            let original = store.config
            let configurationFolder = store.url.deletingLastPathComponent()
            try FileManager.default.removeItem(at: configurationFolder)
            try Data("阻止创建配置目录".utf8).write(to: configurationFolder)
            controller.evaluate(context: context)
            #expect(store.config == original)
            #expect(store.error != nil)
            #expect(controller.status.contains("失败"))
            try FileManager.default.removeItem(at: configurationFolder)
            try FileManager.default.createDirectory(at: configurationFolder, withIntermediateDirectories: true)
            controller.evaluate(context: context)
            #expect(store.config == original, "条件持续成立时，失败请求不应每 5 秒自动重复")
            controller.retryFailedPreset(context: context)
            #expect(store.config.rules == preset.rules)
            #expect(store.error == nil)
            #expect(!(controller.status.hasPrefix("自动预设应用失败：")))
        }
    }

    @MainActor
    @Test
    func testAsynchronousFailureDoesNotRepeatAndExplicitRetryRestoresNormally() throws {
        try withFailureScenario { store, controller, preset, context, _ in
            let original = store.config.rules
            controller.evaluate(context: context)
            store.config.rules = original
            controller.presetApplicationFailed(id: preset.id, message: "模拟位置校验失败")
            #expect(controller.status.contains("失败"))
            controller.evaluate(context: context)
            #expect(store.config.rules == original)
            controller.retryFailedPreset(context: context)
            #expect(store.config.rules == preset.rules)
            controller.evaluate(context: RuleContext())
            #expect(store.config.rules == original)
            #expect(!(controller.status.hasPrefix("自动预设应用失败：")))
        }
    }

    @MainActor
    @Test
    func testConditionEndingClearsFailureAndStaleFailureIsIgnored() throws {
        try withFailureScenario { store, controller, preset, context, _ in
            let original = store.config.rules
            controller.evaluate(context: context)
            controller.presetApplicationFailed(id: UUID(), message: "过期失败")
            #expect(!(controller.status.contains("过期失败")))
            store.config.rules = original
            controller.presetApplicationFailed(id: preset.id, message: "实际失败")
            controller.evaluate(context: RuleContext())
            #expect(!(controller.status.hasPrefix("自动预设应用失败：")))
            controller.evaluate(context: context)
            #expect(store.config.rules == preset.rules)
        }
    }

    @MainActor
    @Test
    func testFailureDeliveredDuringSynchronousPresetNotificationIsNotOverwritten() throws {
        try withFailureScenario { store, controller, preset, context, _ in
            let original = store.config.rules
            let observer = NotificationCenter.default.addObserver(forName: .tidyBarPresetApplied, object: store, queue: nil) { _ in
                MainActor.assumeIsolated {
                    store.config.rules = original
                    controller.presetApplicationFailed(id: preset.id, message: "同步回调失败")
                }
            }
            controller.evaluate(context: context)
            NotificationCenter.default.removeObserver(observer)
            #expect(store.config.rules == original)
            #expect(controller.status.contains("同步回调失败"))
            controller.evaluate(context: context)
            #expect(store.config.rules == original)
        }
    }
}

extension TidyBarTests.AutomationTests {
    @MainActor
    @Test
    func testFailedConditionEndRestoreSurvivesStopAndRequiresExplicitRetry() throws {
        try withFailureScenario { store, controller, preset, context, _ in
            let original = store.config.rules
            controller.evaluate(context: context)
            let directory = store.url.deletingLastPathComponent()
            try FileManager.default.removeItem(at: directory)
            try Data("阻挡恢复写入".utf8).write(to: directory)
            controller.evaluate(context: RuleContext())
            #expect(store.config.rules == preset.rules)
            #expect(controller.status.hasPrefix("自动布局恢复失败："))
            controller.stop()
            #expect(controller.status.hasPrefix("自动布局恢复失败："))
            try FileManager.default.removeItem(at: directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            controller.evaluate(context: RuleContext())
            #expect(store.config.rules == preset.rules, "恢复失败后不应每 5 秒无条件重复写入")
            controller.retryFailedPreset(context: RuleContext())
            #expect(store.config.rules == original)
            #expect(try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: store.url)).rules == original)
            #expect(!(controller.status.contains("恢复失败")))
        }
    }

    @MainActor
    @Test
    func testNewConditionWaitsUntilPreviousLayoutCanBeRestored() throws {
        try withFailureScenario { store, controller, preset, context, _ in
            let original = store.config.rules
            let second = LayoutPreset(name: "第二条件", rules: ["second.app": ItemRule(zone: .alwaysHidden)], order: [], style: BarStyle())
            store.config.presets.append(second)
            store.config.triggers.append(TriggerRule(kind: "app", value: "second.front", presetID: second.id))
            let secondContext = RuleContext(frontmostBundle: "second.front")
            controller.evaluate(context: context)
            let directory = store.url.deletingLastPathComponent()
            try FileManager.default.removeItem(at: directory)
            try Data("阻挡旧布局恢复".utf8).write(to: directory)
            controller.evaluate(context: secondContext)
            #expect(store.config.rules == preset.rules, "旧布局尚未恢复时不得提交新条件预设")
            #expect(controller.status.hasPrefix("自动布局恢复失败："))
            try FileManager.default.removeItem(at: directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            controller.evaluate(context: secondContext)
            #expect(store.config.rules == preset.rules)
            controller.retryFailedPreset(context: secondContext)
            #expect(store.config.rules == second.rules)
            controller.evaluate(context: RuleContext())
            #expect(store.config.rules == original, "第二条件应在恢复旧布局后捕获原始恢复点")
        }
    }
}

extension TidyBarTests.AutomationTests {
    @MainActor
    @Test
    func testWiFiSelectionFindsNameBeyondTheDefaultInterface() {
        #expect(AutomationController.preferredWiFiName([
            (ssid: nil, power: true, serviceActive: true),
            (ssid: "已连接网络", power: true, serviceActive: true)
        ]) == "已连接网络")
    }

    @MainActor
    @Test
    func testWiFiSelectionPrefersPoweredActiveServiceAndIgnoresEmptyNames() {
        #expect(AutomationController.preferredWiFiName([
            (ssid: "旧接口", power: false, serviceActive: false),
            (ssid: "", power: true, serviceActive: true),
            (ssid: "当前接口", power: true, serviceActive: true)
        ]) == "当前接口")
        #expect(AutomationController.preferredWiFiName([]) == nil)
        #expect(AutomationController.preferredWiFiName([(ssid: "", power: true, serviceActive: true), (ssid: nil, power: false, serviceActive: false)]) == nil)
    }

    @MainActor
    @Test
    func testWiFiSelectionRetainsAvailableFallbackNameWithoutTrimming() {
        #expect(AutomationController.preferredWiFiName([
            (ssid: " 含空格的网络 ", power: true, serviceActive: false)
        ]) == " 含空格的网络 ")
    }
}

extension TidyBarTests.AutomationTests {
    @Test
    func testManualWiFiReadIsConsumedWithoutStartingBackgroundPolling() {
        var plan = WiFiReadPlan(requested: true)
        #expect(plan.shouldRead(enabledRule: false, authorized: true, awaitingAuthorization: false, servicesEnabled: true) == true)
        for _ in 0..<5 {
            #expect(plan.shouldRead(enabledRule: false, authorized: true, awaitingAuthorization: false, servicesEnabled: true) == false)
        }
    }

    @Test
    func testPendingWiFiAuthorizationDeliversExactlyOneReadAfterGrant() {
        var plan = WiFiReadPlan(requested: true)
        #expect(plan.shouldRead(enabledRule: false, authorized: false, awaitingAuthorization: true, servicesEnabled: true) == false)
        #expect(plan.shouldRead(enabledRule: false, authorized: false, awaitingAuthorization: true, servicesEnabled: true) == false)
        #expect(plan.shouldRead(enabledRule: false, authorized: true, awaitingAuthorization: false, servicesEnabled: true) == true)
        #expect(plan.shouldRead(enabledRule: false, authorized: true, awaitingAuthorization: false, servicesEnabled: true) == false)
    }

    @Test
    func testOnlyEnabledWiFiRuleKeepsPollingAndDisableStopsIt() {
        var plan = WiFiReadPlan(requested: true)
        for _ in 0..<3 {
            #expect(plan.shouldRead(enabledRule: true, authorized: true, awaitingAuthorization: false, servicesEnabled: true) == true)
        }
        #expect(plan.shouldRead(enabledRule: false, authorized: true, awaitingAuthorization: false, servicesEnabled: true) == false)
    }

    @Test
    func testDeniedOrGloballyDisabledWiFiReadRequiresAnotherExplicitRequest() {
        for servicesEnabled in [true, false] {
            var plan = WiFiReadPlan(requested: true)
            #expect(plan.shouldRead(enabledRule: false, authorized: false, awaitingAuthorization: false, servicesEnabled: servicesEnabled) == false)
            #expect(plan.shouldRead(enabledRule: false, authorized: true, awaitingAuthorization: false, servicesEnabled: true) == false)
            plan.requested = true
            #expect(plan.shouldRead(enabledRule: false, authorized: true, awaitingAuthorization: false, servicesEnabled: true) == true)
        }
    }

    @MainActor
    @Test
    func testStartingAutomationTwiceDoesNotRepeatEvaluationOrLeaveAnotherTimer() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SettingsStore(url: folder.appendingPathComponent("settings.json"))
        let controller = AutomationController(store: store)
        var publications = 0
        let subscription = controller.$status.dropFirst().sink { _ in publications += 1 }
        controller.start()
        let afterFirstStart = publications
        #expect(afterFirstStart > 0)
        controller.start()
        #expect(publications == afterFirstStart)
        controller.stop()
        withExtendedLifetime(subscription) { }
    }
}
