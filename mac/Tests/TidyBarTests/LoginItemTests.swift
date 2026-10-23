import Foundation
import ServiceManagement
import Testing
@testable import TidyBar

extension TidyBarTests {
    @Test func loginItemRegistersAndUnregistersWithoutTouchingSystem() throws {
        var status = SMAppService.Status.notRegistered
        var registrations = 0, removals = 0
        let service = LoginItemService(status: { status }, register: {
            registrations += 1; status = .enabled
        }, unregister: {
            removals += 1; status = .notRegistered
        })
        try service.setEnabled(true)
        #expect(service.status() == .enabled)
        #expect(registrations == 1 && removals == 0)
        try service.setEnabled(false)
        #expect(service.status() == .notRegistered)
        #expect(registrations == 1 && removals == 1)
    }

    @Test func loginItemSurfacesApprovalAndRegistrationFailure() {
        let service = LoginItemService(status: { .requiresApproval }, register: {
            throw AIUsageError.invalidResponse
        }, unregister: {})
        #expect(service.status() == .requiresApproval)
        #expect(throws: AIUsageError.self) { try service.setEnabled(true) }
        #expect(service.status() == .requiresApproval)
    }

    @Test func loginItemBundleMatchesReleaseIdentity() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let plist = try #require(PropertyListSerialization.propertyList(
            from: Data(contentsOf: root.appendingPathComponent("Resources/Info.plist")), format: nil) as? [String: Any])
        #expect(plist["CFBundleIdentifier"] as? String == AppIdentifiers.bundleID)
        #expect(plist["CFBundleExecutable"] as? String == "AISubGauge")
        let signing = try String(contentsOf: root.appendingPathComponent("sign-app.sh"), encoding: .utf8)
        #expect(signing.contains("--identifier " + AppIdentifiers.bundleID))
    }

    @MainActor @Test func menuBarPercentageFalseSurvivesReopeningDefaultsAndStore() throws {
        let domain = "test.percentage." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        #expect(AIUsageMenuBarPreference.showsPercentage(defaults: defaults))
        defaults.set(false, forKey: AIUsageMenuBarPreference.percentageKey)
        let reopened = try #require(UserDefaults(suiteName: domain))
        let store = AIUsageStore(displayDefaults: reopened, fetcher: { _ in throw AIUsageError.signedOut })
        #expect(!AIUsageMenuBarPreference.showsPercentage(defaults: reopened))
        #expect(reopened.object(forKey: AIUsageMenuBarPreference.percentageKey) as? Bool == false)
        #expect(!store.isRefreshing)
        #expect(!AIUsageMenuBarPreference.showsPercentage(defaults: reopened))
    }
}
