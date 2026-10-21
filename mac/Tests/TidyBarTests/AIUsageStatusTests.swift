import Foundation
import Testing
@testable import TidyBar

extension TidyBarTests {
    @MainActor @Test func menuBarWarnsOnlyWhenTheSnapshotHasAnError() {
        for provider in AIUsageProvider.allCases {
            var snapshot = AIUsageSnapshot(provider: provider, windows: [
                AIUsageWindow(id: "quota", title: "Quota", remainingPercent: 72, resetsAt: nil)
            ], isConnected: true, status: "", source: "fixture")
            #expect(AIUsageMenuBarController.statusTitle(snapshot) == "72%")
            snapshot.error = L10n.text("error.grok.automatic.renewal.failed.reconnect.the.account")
            #expect(AIUsageMenuBarController.statusTitle(snapshot) == "— ⚠︎")
            snapshot.isConnected = false
            #expect(AIUsageMenuBarController.statusTitle(snapshot) == "— ⚠︎")
            snapshot.error = ""
            #expect(AIUsageMenuBarController.statusTitle(snapshot) == "— ⚠︎")
            snapshot.error = nil
            #expect(AIUsageMenuBarController.statusTitle(snapshot) == "—")
            snapshot.isConnected = true
            #expect(AIUsageMenuBarController.statusTitle(snapshot) == "72%")
        }
    }

    @Test func usageViewsPreserveLocalizedGrokRenewalErrors() throws {
        let previous = L10n.overrideLanguage
        defer { L10n.overrideLanguage = previous }
        for language in ["en", "zh-Hans"] {
            L10n.overrideLanguage = language
            let catalog = try L10n.load(language)
            for key in ["error.grok.cli.official.signature.or.developer.team",
                        "error.grok.automatic.renewal.failed.reconnect.the.account",
                        "error.grok.automatic.renewal.timed.out.refresh.later"] {
                let error = AIUsageError.unavailable(L10n.text(key))
                let message = try #require(catalog[key])
                #expect(error.localizedDescription == message)
                var snapshot = AIUsageSnapshot(provider: .grok, status: "", source: "fixture", error: error.localizedDescription)
                #expect(PanelQuotaText.refreshError(snapshot) == L10n.text("error.refresh", message))
                snapshot.error = nil
                #expect(PanelQuotaText.refreshError(snapshot) == nil)
                snapshot.error = ""
                #expect(PanelQuotaText.refreshError(snapshot) == nil)
            }
        }
        #expect(PanelQuotaText.refreshError(nil) == nil)
    }
}
