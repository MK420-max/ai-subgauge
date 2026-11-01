import Foundation
import SwiftUI

/// No shared opt-in: each subscription provider has its own persisted decision.
struct ProviderLoginConsent {
    static let providers: [AIUsageProvider] = [.codex, .claude, .grok]
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    static func key(_ provider: AIUsageProvider) -> String { "loginReuse.consent." + provider.rawValue }
    func allows(_ provider: AIUsageProvider) -> Bool {
        Self.providers.contains(provider) && defaults.bool(forKey: Self.key(provider))
    }
    func setAllowed(_ allowed: Bool, for provider: AIUsageProvider) {
        guard Self.providers.contains(provider) else { return }
        defaults.set(allowed, forKey: Self.key(provider))
    }
    func require(_ provider: AIUsageProvider) throws {
        guard allows(provider) else {
            throw AIUsageError.configuredAccountUnavailable(L10n.text("consent.allow.0.local.login.reuse.separately.in", provider.title), source: provider.initialSource)
        }
    }
    func withAccess<T>(to provider: AIUsageProvider, read: () throws -> T) throws -> T {
        try require(provider)
        return try read()
    }
}

struct ProviderLoginConsentView: View {
    @AppStorage("loginReuse.consent.codex") private var codex = false
    @AppStorage("loginReuse.consent.claude") private var claude = false
    @AppStorage("loginReuse.consent.grok") private var grok = false
    var body: some View {
        Section(L10n.text("consent.reuse.local.logins.from.other.apps.separate")) {
            Toggle(L10n.text("consent.allow.codex.chatgpt.local.login.reuse"), isOn: $codex)
            Toggle(L10n.text("consent.allow.claude.code.local.login.reuse"), isOn: $claude)
            Toggle(L10n.text("consent.allow.grok.cli.grok.bot.local.login"), isOn: $grok)
            Text(L10n.text("consent.off.by.default.a.provider.s.login"))
                .font(.caption).foregroundStyle(.secondary)
        }.onChange(of: codex) { _, _ in AIUsageStore.shared.refresh(provider: .codex) }
            .onChange(of: claude) { _, _ in AIUsageStore.shared.refresh(provider: .claude) }
            .onChange(of: grok) { _, _ in AIUsageStore.shared.refresh(provider: .grok) }
    }
}
