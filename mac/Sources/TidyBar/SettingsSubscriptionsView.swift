import AppKit
import SwiftUI

struct SettingsSubscriptionsView: View {
    @ObservedObject var store: AIUsageStore
    @Binding var adding: Bool
    var approximateGlass = false
    @State private var accountError: String?
    @State private var details = false
    @Environment(\.colorScheme) private var scheme
    private var snapshots: [AIUsageSnapshot] { store.subscriptionPreferences.sorted(store.visibleSnapshots) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SettingsGroup(title: L10n.text("settings.menuBarDisplay")) {
                    SettingsPercentageControls()
                }.toggleStyle(SettingsSwitchStyle(approximate: approximateGlass)).controlSize(.small)
                VStack(spacing: 0) {
                    ForEach(Array(snapshots.enumerated()), id: \.element.id) { index, snapshot in
                        if index > 0 { Divider() }
                        subscription(snapshot)
                    }
                    if snapshots.isEmpty {
                        Text(L10n.text("settings.subscriptions.empty")).font(.system(size: 12)).foregroundStyle(.secondary)
                            .padding(20).frame(maxWidth: .infinity)
                    }
                }
                .background(.white.opacity(scheme == .dark ? 0.08 : 0.38), in: RoundedRectangle(cornerRadius: 14))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.14), lineWidth: 0.5))
                HStack(spacing: 8) {
                    Button { adding = true } label: { Label(L10n.text("settings.addSubscription"), systemImage: "plus") }
                        .buttonStyle(SettingsPillStyle(primary: true)).accessibilityIdentifier("settings.add-subscription")
                    Button(L10n.text("settings.refreshNow")) { store.refresh() }
                        .buttonStyle(SettingsPillStyle()).disabled(store.isRefreshing)
                    Spacer(minLength: 0)
                    Text(updated).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                }
                DisclosureGroup(L10n.text("settings.accountDetails"), isExpanded: $details) {
                    VStack(alignment: .leading, spacing: 12) {
                        SettingsGroup { AIProviderVisibilityView(store: store) }
                        TimelineView(.periodic(from: .now, by: 60)) { timeline in
                            ForEach(snapshots) { snapshot in
                                AIUsageCard(provider: snapshot.provider, snapshot: snapshot, now: timeline.date,
                                            isRefreshing: store.isRefreshing, refresh: { store.refresh(provider: snapshot.provider) },
                                            remove: { remove(snapshot.provider) })
                            }
                        }
                        Text(L10n.text("panel.times.use.your.local.time.zone.0", TimeZone.current.identifier))
                            .font(.caption).foregroundStyle(.secondary)
                        if let accountError { Text(accountError).font(.caption).foregroundStyle(.red) }
                    }.padding(.top, 8)
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(.bottom, 2)
        }
        .sheet(isPresented: $adding) { AddSubscriptionSheet(store: store) }
    }

    private func subscription(_ snapshot: AIUsageSnapshot) -> some View {
        let percent = snapshot.windows.compactMap { PanelQuotaData.remaining($0, in: snapshot) }.first
        return HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal").font(.system(size: 10)).foregroundStyle(.tertiary)
                .frame(width: 8, height: 26).contentShape(Rectangle())
                .draggable(snapshot.provider.rawValue)
                .accessibilityLabel(L10n.text("settings.drag.handle.for.0", snapshot.provider.title))
            QuotaArcView(provider: snapshot.provider, percent: percent, size: 26, dark: scheme == .dark, showPercentage: false)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(snapshot.provider.usageDisplayName).font(.system(size: 13, weight: .semibold))
                    if let plan = snapshot.plan, !plan.isEmpty {
                        Text(plan).font(.system(size: 10)).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.primary.opacity(0.08), in: Capsule())
                    }
                }.lineLimit(1).minimumScaleFactor(0.75)
                HStack(spacing: 4) {
                    Circle().fill(snapshot.error != nil ? .red : snapshot.isConnected ? .green : .gray).frame(width: 4.5, height: 4.5)
                    Text(Self.status(snapshot, percent: percent)).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true).help(Self.status(snapshot, percent: percent))
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Toggle(L10n.text("settings.subscriptionMenuBar"), isOn: Binding(
                get: { store.subscriptionPreferences.showsInMenuBar(snapshot.provider) },
                set: {
                    store.objectWillChange.send()
                    store.subscriptionPreferences.setShowsInMenuBar($0, provider: snapshot.provider)
                }))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .toggleStyle(SettingsSwitchStyle(approximate: approximateGlass)).controlSize(.mini).fixedSize()
                .accessibilityIdentifier("settings.subscription-visible.\(snapshot.provider.rawValue)")
        }.padding(.horizontal, 12).frame(height: 51.5).contentShape(Rectangle())
            .dropDestination(for: String.self) { values, location in
                guard values.count == 1, let provider = AIUsageProvider(rawValue: values[0]),
                      snapshots.contains(where: { $0.provider == provider }) else { return false }
                store.objectWillChange.send()
                if snapshot.id == snapshots.last?.id && location.y > 51.5 / 2 {
                    return store.subscriptionPreferences.move(provider, after: snapshot.provider)
                }
                return store.subscriptionPreferences.move(provider, before: snapshot.provider)
            }
    }
    static func status(_ snapshot: AIUsageSnapshot, percent: Double?) -> String {
        if let error = snapshot.error { return L10n.text("error.refresh", error) }
        guard snapshot.isConnected else { return snapshot.status.isEmpty ? L10n.text("status.notConnected") : snapshot.status }
        let method: String
        if snapshot.provider.isAPIAccount { method = L10n.text("settings.login.api") }
        else if snapshot.source == ClaudeWebUsage.source { method = L10n.text("settings.login.web") }
        else if snapshot.provider == .grok { method = L10n.text("settings.login.account") }
        else { method = L10n.text("settings.login.cli") }
        return L10n.text("settings.subscriptionStatus", L10n.text("status.connected"), method,
                         AIUsageMenuBarController.percent(percent))
    }
    private var updated: String {
        let time = snapshots.compactMap(\.updatedAt).min().map { date in
            let format = DateFormatter()
            format.locale = L10n.locale; format.dateFormat = L10n.text("panel.timeFormat")
            return format.string(from: date)
        } ?? L10n.text("status.notUpdated")
        return L10n.text("panel.updatedTime", time)
    }
    private func remove(_ provider: AIUsageProvider) {
        do {
            try APIAccountCredentials.shared.remove(for: provider)
            accountError = nil
            store.disconnectAPIAccount(provider)
        } catch { accountError = error.localizedDescription }
    }
}

struct SettingsPillStyle: ButtonStyle {
    var primary = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium)).fixedSize()
            .padding(.horizontal, 14).frame(height: 26)
            .background(primary ? Color(themeHex: scheme == .dark ? "#0A84FF" : "#007AFF")
                        : .white.opacity(scheme == .dark ? 0.12 : 0.45), in: Capsule())
            .foregroundStyle(primary ? .white : .primary)
            .overlay(Capsule().strokeBorder(.primary.opacity(primary ? 0 : 0.12), lineWidth: 0.5))
            .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.7 : 1)
    }
}

struct SettingsDisplayPreferences: View {
    var approximateGlass = false
    @AppStorage(AIUsageMenuBarPreference.key) private var showMenuBar = true
    @AppStorage(SubscriptionPreferences.colorKey) private var colors = true
    @AppStorage(SubscriptionPreferences.refreshKey) private var refresh = 2
    var body: some View {
        SettingsGroup(title: L10n.text("settings.quotaDisplay")) {
            Toggle(L10n.text("panel.show.remaining.quota.in.the.menu.bar"), isOn: $showMenuBar)
            SettingsPercentageControls()
            Toggle(L10n.text("settings.colorByQuota"), isOn: $colors)
            Picker(L10n.text("settings.refreshInterval"), selection: $refresh) {
                ForEach(SubscriptionPreferences.refreshOptions, id: \.self) { minutes in
                    Text(L10n.text("settings.refreshMinutes", minutes)).tag(minutes)
                }
            }
        }.toggleStyle(SettingsSwitchStyle(approximate: approximateGlass)).controlSize(.small)
            .pickerStyle(.menu)
    }
}

struct SettingsPercentageControls: View {
    @AppStorage(AIUsageMenuBarPreference.percentageKey) private var percentage = true
    @AppStorage(AIUsageMenuBarPreference.placementKey) private var placement = AIUsageMenuBarPreference.PercentagePlacement.arcTop.rawValue

    var body: some View {
        Toggle(L10n.text("panel.showPercentageInMenuBar"), isOn: $percentage)
            .accessibilityIdentifier("ai-usage.menu-bar-percentage")
        Picker(L10n.text("settings.percentagePlacement"), selection: $placement) {
            ForEach(AIUsageMenuBarPreference.PercentagePlacement.allCases, id: \.rawValue) { option in
                Text(L10n.text(option.titleKey)).tag(option.rawValue)
            }
        }
        .pickerStyle(.menu)
        .disabled(!percentage)
        .accessibilityIdentifier("ai-usage.percentage-placement")
    }
}

struct SubscriptionVendor: Identifiable {
    var id: String
    var name: String
    var logo: String
    var provider: AIUsageProvider?
    static let all: [Self] = [
        .init(id: "codex", name: "Codex / OpenAI", logo: "openai.svg", provider: .codex),
        .init(id: "claude", name: "Claude", logo: "claude.svg", provider: .claude),
        .init(id: "grok", name: "Grok Bot", logo: "grok.svg", provider: .grok),
        .init(id: "gemini", name: "Gemini", logo: "googlegemini.svg", provider: .geminiAPI),
        .init(id: "copilot", name: "GitHub Copilot", logo: "githubcopilot.svg"),
        .init(id: "cursor", name: "Cursor", logo: "cursor.svg"),
        .init(id: "deepseek", name: "DeepSeek", logo: "deepseek.svg", provider: .deepseekAPI),
        .init(id: "perplexity", name: "Perplexity", logo: "perplexity.svg"),
        .init(id: "mistral", name: "Mistral", logo: "mistralai.svg"),
        .init(id: "qwen", name: "Qwen", logo: "qwen.svg"),
        .init(id: "kimi", name: "Kimi", logo: "kimi.svg", provider: .kimiAPI)
    ]
}

struct AddSubscriptionSheet: View {
    @ObservedObject var store: AIUsageStore
    @State private var selected: String?
    @State private var connecting: AIUsageProvider?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Group {
            if let connecting {
                AIAccountConnectionSheet(store: store, initialProvider: connecting)
            } else {
                SubscriptionVendorGrid(connected: Set(store.snapshots.filter(\.isConnected).map(\.provider)), selected: $selected,
                                       cancel: { dismiss() }, proceed: {
                    connecting = SubscriptionVendor.all.first { $0.id == selected }?.provider
                })
            }
        }.modifier(SettingsControlStyle())
    }
}

struct SubscriptionVendorGrid: View {
    var approximateGlass = false
    var connected: Set<AIUsageProvider>
    @Binding var selected: String?
    var cancel: () -> Void
    var proceed: () -> Void
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.text("settings.addSubscription")).font(.system(size: 15, weight: .bold))
            Text(L10n.text("settings.chooseVendor")).font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.top, 2).padding(.bottom, 10)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(SubscriptionVendor.all) { vendor in
                    Button { selected = vendor.id } label: {
                        VStack(spacing: 5) {
                            Image(nsImage: logo(vendor)).resizable().scaledToFit().frame(width: 26, height: 26)
                            Text(vendor.name).font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                        }.frame(maxWidth: .infinity).frame(height: 66)
                            .background(.white.opacity(scheme == .dark ? 0.08 : 0.38), in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(
                                selected == vendor.id ? Color.accentColor : .primary.opacity(0.14), lineWidth: selected == vendor.id ? 1.5 : 0.5))
                            .overlay(alignment: .topTrailing) {
                                if let provider = vendor.provider, connected.contains(provider) {
                                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.green).padding(6)
                                }
                            }
                    }.buttonStyle(.plain).disabled(vendor.provider == nil)
                        .help(vendor.provider == nil ? L10n.text("settings.comingSoon") : vendor.name)
                        .accessibilityLabel(vendor.provider == nil ? vendor.name + " · " + L10n.text("settings.comingSoon") : vendor.name)
                        .accessibilityIdentifier("settings.vendor.\(vendor.id)")
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button(L10n.text("common.cancel"), action: cancel).buttonStyle(SettingsPillStyle()).keyboardShortcut(.cancelAction)
                Button(L10n.text("settings.continue"), action: proceed).buttonStyle(SettingsPillStyle(primary: true))
                    .disabled(selected == nil).keyboardShortcut(.defaultAction)
            }.padding(.top, 14)
        }.padding(16).frame(width: 420)
            .background { SettingsGlass(radius: 24, approximate: approximateGlass, prominent: true) }
    }
    private func logo(_ vendor: SubscriptionVendor) -> NSImage {
        let image = NSImage(contentsOf: SharedResources.url(vendor.logo, directory: "logos/subscriptions"))!
        image.isTemplate = true
        return image
    }
}
