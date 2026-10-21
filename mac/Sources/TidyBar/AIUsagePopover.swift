import SwiftUI

/// One compact row per visible provider; visibility remains owned by AIUsageStore.
struct AIUsagePopoverView: View {
    @ObservedObject var store: AIUsageStore
    var now: Date
    var height: CGFloat
    var onOpenUsage: () -> Void
    var scrollable = true
    var themeOverride: AppTheme?

    static let width: CGFloat = 440
    static func height(for count: Int) -> CGFloat { 116 + CGFloat(max(1, count)) * 78 }

    var body: some View {
        AIUsagePanelContent(store: store, now: now, onOpenUsage: onOpenUsage, scrollable: scrollable)
            .frame(width: Self.width, height: height)
            .appThemed(themeOverride)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .environment(\.locale, L10n.locale)
    }
}

private struct AIUsagePanelContent: View {
    @ObservedObject var store: AIUsageStore
    var now: Date
    var onOpenUsage: () -> Void
    var scrollable: Bool
    @Environment(\.appTheme) private var mode
    private var theme: ThemePalette { ThemeCatalog.shared.palette(mode) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(nsImage: AppBrand.logo(mode)).resizable().interpolation(.high)
                    .frame(width: 24, height: 24).accessibilityHidden(true)
                Text(L10n.text("app.name")).font(.system(size: 16, weight: .semibold))
                Spacer()
                if store.isRefreshing {
                    ProgressView().controlSize(.small).accessibilityLabel(L10n.text("panel.refreshing.usage"))
                }
            }.padding(.horizontal, 18).frame(height: 52)
            divider
            if scrollable {
                ScrollView { rows }.scrollIndicators(.hidden)
            } else {
                rows
                Spacer(minLength: 0)
            }
            divider
            HStack(spacing: 10) {
                Button(L10n.text("panel.settings"), action: onOpenUsage)
                    .accessibilityIdentifier("ai-usage.popover-open-settings")
                Button { store.refresh() } label: { Text(L10n.text("panel.refresh")) }
                    .disabled(store.isRefreshing)
                    .accessibilityIdentifier("ai-usage.popover-refresh")
            }
            .buttonStyle(PanelButtonStyle(theme: theme))
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(theme.color(\.panelBorder), lineWidth: 1))
    }

    private var snapshots: [AIUsageSnapshot] {
        let order: [AIUsageProvider] = [.codex, .grok, .claude] + AIUsageProvider.allCases.filter(\.isAPIAccount)
        return store.displaySnapshots.sorted { order.firstIndex(of: $0.provider)! < order.firstIndex(of: $1.provider)! }
    }
    private var divider: some View { theme.color(\.divider).frame(height: 1) }
    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(Array(snapshots.enumerated()), id: \.element.id) { index, snapshot in
                if index > 0 { divider }
                AIUsagePanelRow(snapshot: snapshot, now: now)
            }
            if store.displaySnapshots.isEmpty {
                Text(L10n.text("idle.title")).font(.system(size: 13))
                    .foregroundStyle(theme.color(\.textSecondary)).frame(height: 77)
            }
        }
    }
}

private struct PanelButtonStyle: ButtonStyle {
    var theme: ThemePalette
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14, weight: .medium))
            .frame(maxWidth: .infinity).frame(height: 38)
            .background(theme.color(configuration.isPressed ? \.buttonBorder : \.buttonFill), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.color(\.buttonBorder), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct AIUsagePanelRow: View {
    var snapshot: AIUsageSnapshot
    var now: Date
    @Environment(\.appTheme) private var mode
    private var theme: ThemePalette { ThemeCatalog.shared.palette(mode) }
    private var window: AIUsageWindow? { snapshot.windows.first }
    private var remaining: Double? { AIUsageMenuBarController.remaining(window?.remainingPercent) }
    private var subtitle: String? {
        if let error = PanelQuotaText.refreshError(snapshot) { return error }
        if snapshot.source == L10n.text("demo.offline.demo") { return L10n.text("demo.label") }
        if AIUsageMenuBarController.isExpired(snapshot, now: now) { return L10n.text("panel.cache.expired") }
        if AIUsageMenuBarController.isCached(snapshot, now: now) { return L10n.text("status.cached") }
        if window == nil { return snapshot.status.isEmpty ? nil : snapshot.status }
        return nil
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: AIUsageBrand.panelImage(for: snapshot.provider))
                .resizable().interpolation(.high).scaledToFit().frame(width: 30, height: 30)
                .frame(width: 38, height: 38)
                .background(theme.color(\.surface), in: RoundedRectangle(cornerRadius: 10))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 6) {
                Text(snapshot.provider == .grok ? L10n.text("panel.provider.grok") : snapshot.provider.usageDisplayName).font(.system(size: 16, weight: .medium))
                    .lineLimit(1).minimumScaleFactor(0.8)
                GeometryReader { geometry in
                    Capsule().fill(theme.color(\.barTrack)).overlay(alignment: .leading) {
                        if let remaining {
                            Capsule().fill(ThemeCatalog.shared.quotaColor(remaining))
                                .frame(width: geometry.size.width * remaining / 100)
                        }
                    }
                }.frame(height: 7).accessibilityHidden(true)
                if let subtitle {
                    Text(subtitle).font(.system(size: 9))
                        .foregroundStyle(theme.color(snapshot.error == nil ? \.demo : \.error))
                        .lineLimit(1).help(subtitle)
                }
            }
            VStack(alignment: .trailing, spacing: 5) {
                Text(remaining.map { L10n.text("panel.quotaLeft", AIUsageMenuBarController.percent($0)) }
                     ?? snapshot.balance ?? L10n.text("common.unknown"))
                    .font(.system(size: 14, weight: .medium))
                Text(PanelQuotaText.reset(window?.resetsAt, now: now))
                    .font(.system(size: 11)).foregroundStyle(theme.color(\.textSecondary))
            }.monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                .frame(width: 132, alignment: .trailing)
        }.padding(.horizontal, 18).frame(height: 77)
            .accessibilityElement(children: .combine)
    }
}

enum PanelQuotaText {
    static func refreshError(_ snapshot: AIUsageSnapshot?) -> String? {
        guard let error = snapshot?.error, !error.isEmpty else { return nil }
        return L10n.text("error.refresh", error)
    }

    static func reset(_ date: Date?, now: Date) -> String {
        guard let date else { return L10n.text("panel.resetUnknown") }
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return L10n.text("panel.resetDue") }
        let minutes = max(1, Int(ceil(seconds / 60)))
        if minutes >= 1440 { return L10n.text("panel.resetDaysHours", minutes / 1440, minutes % 1440 / 60) }
        if minutes >= 60 { return L10n.text("panel.resetHoursMinutes", minutes / 60, minutes % 60) }
        return L10n.text("panel.resetMinutes", minutes)
    }
}
