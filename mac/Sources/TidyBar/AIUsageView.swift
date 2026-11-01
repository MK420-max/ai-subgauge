import AppKit
import SwiftUI

struct AIAccountConnectionSheet: View {
    @Environment(\.appTheme) private var themeMode
    private var theme: ThemePalette { ThemeCatalog.shared.palette(themeMode) }
    @ObservedObject var store: AIUsageStore
    @Environment(\.dismiss) private var dismiss
    var initialProvider: AIUsageProvider = .deepseekAPI
    @State private var selected: AIUsageProvider = .deepseekAPI
    @State private var secret = ""
    @State private var teamID = ""
    @State private var configured = Set<AIUsageProvider>()
    @State private var message: String?
    @State private var connecting = false
    @State private var connectionTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text("panel.connect.ai.account")).font(.system(size: 20, weight: .semibold))
                    Text(L10n.text("panel.subscription.and.api.quotas.are.shown.separately"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.text("common.done")) { dismiss() }.disabled(connecting)
                    .keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.text("panel.subscription.accounts")).font(.headline)
                    HStack(spacing: 10) {
                        subscription(.codex, title: L10n.text("panel.sign.in.to.codex")) { openApplication("ChatGPT.app") }
                        subscription(.claude, title: L10n.text("panel.connect.claude")) { ClaudeWebConnection.shared.connect() }
                        subscription(.grok, title: L10n.text("panel.connect.grok")) { GrokBuildConnection.shared.connect() }
                    }
                    Text(L10n.text("panel.uses.your.official.account.login.chatgpt.chat"))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 16) {
                        Link(L10n.text("panel.chatgpt.account"), destination: URL(string: "https://chatgpt.com/")!)
                        Link(L10n.text("panel.gemini.account"), destination: URL(string: "https://gemini.google.com/")!)
                    }.font(.caption)
                    Divider()
                    HStack {
                        Text(L10n.text("panel.api.accounts")).font(.headline)
                        Spacer()
                        Text(L10n.text("panel.reading.billing.does.not.incur.model.call")).font(.caption).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(AIUsageProvider.allCases.filter(\.isAPIAccount)) { provider in
                            Button {
                                selected = provider
                                secret = ""
                                teamID = ""
                                message = nil
                            } label: {
                                HStack(spacing: 9) {
                                    AIUsageProviderLogo(provider: provider, size: 23)
                                        .foregroundStyle(provider.usageTint).frame(width: 25, height: 25)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(provider.title).font(.system(size: 12, weight: .medium))
                                        Text(configured.contains(provider) ? L10n.text("status.connected") : APIUsageSource.supportsDirectFetch(provider) ? L10n.text("panel.quota.available") : L10n.text("panel.official.billing"))
                                            .font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    if provider == selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(provider.usageTint) }
                                }
                                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(provider == selected ? provider.usageTint.opacity(0.1) : theme.color(\.divider), in: RoundedRectangle(cornerRadius: 14))
                                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(provider == selected ? provider.usageTint.opacity(0.5) : theme.color(\.divider)))
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(connecting)
                                .accessibilityIdentifier("ai-usage.connect.\(provider.rawValue)")
                        }
                    }
                    connectionDetail
                }
            }
        }
        .modifier(SettingsControlStyle())
        .padding(24).frame(width: 520, height: 480)
        .foregroundStyle(theme.color(\.textPrimary))
        .background(theme.color(\.background))
        .onAppear {
            selected = initialProvider.isAPIAccount ? initialProvider : initialProvider == .codex ? .openaiAPI : initialProvider == .claude ? .anthropicAPI : .xaiAPI
            configured = Set(APIAccountCredentials.shared.configuredProviders)
        }
        .onDisappear {
            connectionTask?.cancel()
            secret = ""
            teamID = ""
        }
    }

    private var connectionDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(selected.title).font(.headline)
            Text(APIUsageSource.availabilityNote(selected))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if APIUsageSource.supportsDirectFetch(selected) {
                SecureField(selected == .xaiAPI ? L10n.text("panel.paste.your.xai.management.key") : L10n.text("panel.paste.this.service.s.api.key"), text: $secret)
                    .textFieldStyle(.roundedBorder).disabled(connecting)
                    .accessibilityLabel(selected == .xaiAPI ? L10n.text("panel.xai.management.key") : L10n.text("panel.0.api.key", selected.title))
                    .accessibilityIdentifier("ai-usage.api-key")
                if selected == .xaiAPI {
                    TextField(L10n.text("panel.team.id"), text: $teamID)
                        .textFieldStyle(.roundedBorder).disabled(connecting)
                        .accessibilityLabel(L10n.text("panel.xai.team.id"))
                        .accessibilityIdentifier("ai-usage.xai-team-id")
                    Text(L10n.text("panel.use.a.management.key.with.read.only"))
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    Button(configured.contains(selected) ? L10n.text("panel.validate.and.update.connection") : L10n.text("panel.validate.and.connect")) { connect() }
                        .buttonStyle(SettingsPillStyle(primary: true))
                        .disabled(connecting || secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (selected == .xaiAPI && teamID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                        .accessibilityIdentifier("ai-usage.verify-api")
                    if connecting { ProgressView().controlSize(.small) }
                    Spacer()
                    Link(L10n.text("panel.official.billing"), destination: APIUsageSource.dashboardURL(selected))
                    Link(L10n.text("panel.api.details"), destination: APIUsageSource.documentationURL(selected))
                }
                Text(L10n.text("panel.the.read.only.quota.api.is.validated"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 12) {
                    Link(L10n.text("panel.open.official.billing"), destination: APIUsageSource.dashboardURL(selected)).buttonStyle(SettingsPillStyle(primary: true))
                    Link(L10n.text("panel.view.api.details"), destination: APIUsageSource.documentationURL(selected))
                }
            }
            if let message { Text(message).font(.caption).foregroundStyle(theme.color(\.error)).textSelection(.enabled) }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.color(\.divider), in: RoundedRectangle(cornerRadius: 14))
    }

    private func connect() {
        let provider = selected
        let credential: String
        do {
            let key = try APIAccountCredentials.validated(secret)
            credential = provider == .xaiAPI ? try APIUsageSource.xaiCredential(key: key, teamID: teamID) : key
        }
        catch { message = error.localizedDescription; return }
        connecting = true
        message = nil
        connectionTask = Task { @MainActor in
            defer { connecting = false }
            do {
                let snapshot = try await APIUsageSource.fetch(provider: provider, credential: credential)
                try Task.checkCancellation()
                guard snapshot.isConnected else { throw AIUsageError.unavailable(L10n.text("panel.no.valid.quota.was.returned.check.the")) }
                try APIAccountCredentials.shared.save(credential, for: provider)
                secret = ""
                teamID = ""
                store.acceptAPIConnection(snapshot)
                dismiss()
            } catch is CancellationError {
                secret = ""
                teamID = ""
            } catch {
                // Only our vetted error messages reach the UI; never echo a server payload or key.
                message = error is AIUsageError || error is APIAccountCredentials.CredentialError
                    ? error.localizedDescription : L10n.text("panel.connection.failed.check.your.network.and.key")
            }
        }
    }

    private func subscription(_ provider: AIUsageProvider, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                AIUsageProviderLogo(provider: provider, size: 27).foregroundStyle(provider.usageTint)
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(theme.color(\.divider), in: RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain).disabled(connecting)
    }

    private func openApplication(_ filename: String) {
        let url = URL(fileURLWithPath: "/Applications").appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else { message = L10n.text("panel.install.and.sign.in.to.the.official") }
    }
}
