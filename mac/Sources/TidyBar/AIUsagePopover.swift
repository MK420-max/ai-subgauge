import SwiftUI

/// Visibility and account data remain owned by AIUsageStore.
struct AIUsagePopoverView: View {
    @ObservedObject var store: AIUsageStore
    var now: Date
    var height: CGFloat
    var onOpenUsage: () -> Void
    var scrollable = true
    var themeOverride: AppTheme?
    // ImageRenderer cannot sample a window's backdrop. Only offline previews use this tint.
    var approximateGlass = false
    var onOpenPanelSettings: (() -> Void)?
    @AppStorage(AppTheme.preferenceKey) private var preference = "system"
    @Environment(\.colorScheme) private var systemScheme

    static let width: CGFloat = 360
    static let rowHeight: CGFloat = 65
    static func height(for count: Int) -> CGFloat { 88 + CGFloat(max(1, count)) * rowHeight }

    var body: some View {
        let mode = themeOverride ?? AppTheme.resolve(preference: preference, systemDark: systemScheme == .dark)
        AIUsagePanelContent(store: store, now: now, onOpenUsage: onOpenUsage,
                            onOpenPanelSettings: onOpenPanelSettings ?? onOpenUsage,
                            scrollable: scrollable, approximateGlass: approximateGlass)
            .frame(width: Self.width, height: height)
            .environment(\.appTheme, mode)
            .environment(\.colorScheme, mode.colorScheme)
            .environment(\.locale, L10n.locale)
    }
}

private struct AIUsagePanelContent: View {
    @ObservedObject var store: AIUsageStore
    var now: Date
    var onOpenUsage: () -> Void
    var onOpenPanelSettings: () -> Void
    var scrollable: Bool
    var approximateGlass: Bool
    @Environment(\.appTheme) private var mode
    private var dark: Bool { mode == .dark }
    private var secondary: Color { (dark ? Color(themeHex: "#EBEBF5") : Color(themeHex: "#3C3C43")).opacity(0.66) }
    private var separator: Color { dark ? .white.opacity(0.1) : Color(themeHex: "#3C3C43").opacity(0.14) }
    private var snapshots: [AIUsageSnapshot] { store.subscriptionDisplaySnapshots }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(L10n.text("app.name")).font(.system(size: 15, weight: .bold)).tracking(-0.2)
                Text(L10n.text("panel.remainingQuota")).font(.system(size: 11)).foregroundStyle(secondary)
                Spacer(minLength: 0)
                if store.isRefreshing {
                    ProgressView().controlSize(.mini)
                        .accessibilityLabel(L10n.text("panel.refreshing.usage"))
                }
                Text(L10n.text("panel.quotaWindows")).font(.system(size: 11)).foregroundStyle(secondary)
            }
            .lineLimit(1).minimumScaleFactor(0.8)
            .padding(.horizontal, 8).frame(height: 33)
            if scrollable {
                ScrollView { rows }.scrollIndicators(.hidden)
            } else {
                rows
                Spacer(minLength: 0)
            }
            PanelActions(updated: updated, refreshing: store.isRefreshing, dark: dark,
                         refresh: { store.refresh() }, onOpenUsage: onOpenPanelSettings,
                         onToggleCollection: { AppActions.shared.toggle() })
            .padding(.top, 8).frame(height: 35)
        }
        .padding(10).foregroundStyle(dark ? .white : .black)
        .panelSurface(dark: dark, approximate: approximateGlass)
    }

    private var updated: String {
        let time = snapshots.compactMap(\.updatedAt).min().map { date in
            let formatter = DateFormatter()
            formatter.locale = L10n.locale
            formatter.dateFormat = L10n.text("panel.timeFormat")
            return formatter.string(from: date)
        } ?? L10n.text("status.notUpdated")
        return L10n.text("panel.updatedTime", time)
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(Array(snapshots.enumerated()), id: \.element.id) { index, snapshot in
                if index > 0 { Rectangle().fill(separator).frame(height: 0.5) }
                AIUsagePanelRow(snapshot: snapshot, now: now, onOpenUsage: onOpenUsage,
                                refresh: { store.refresh(provider: snapshot.provider) }, isRefreshing: store.isRefreshing)
                    .frame(height: AIUsagePopoverView.rowHeight - (index > 0 ? 0.5 : 0))
            }
            if snapshots.isEmpty {
                Text(L10n.text("idle.title")).font(.system(size: 13))
                    .foregroundStyle(secondary).frame(height: AIUsagePopoverView.rowHeight)
            }
        }
        .frame(maxWidth: .infinity)
        .panelGroup(dark: dark)
    }
}

/// Shared panel-v2 shell for every custom menu-bar popup.
extension View {
    func panelSurface(dark: Bool, approximate: Bool = false) -> some View {
        background { PanelGlass(dark: dark, approximate: approximate) }
            .clipShape(RoundedRectangle(cornerRadius: 30))
            .overlay {
                RoundedRectangle(cornerRadius: 30).strokeBorder(.black.opacity(dark ? 0.6 : 0.18), lineWidth: 0.5)
                RoundedRectangle(cornerRadius: 30).inset(by: 0.75)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(dark ? 0.32 : 0.95),
                                                          .white.opacity(dark ? 0.08 : 0.25)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
            }
    }

    func panelGroup(dark: Bool) -> some View {
        background(.white.opacity(dark ? 0.08 : 0.38), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20)
                .strokeBorder(dark ? .white.opacity(0.1) : Color(themeHex: "#3C3C43").opacity(0.14), lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 20))
    }
}

private struct PanelGlass: View {
    var dark: Bool
    var approximate: Bool
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 30)
        if approximate {
            shape.fill(dark ? Color(themeHex: "#16161C").opacity(0.34) : .white.opacity(0.22))
        } else if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: shape)
        } else {
            shape.fill(.ultraThinMaterial)
        }
    }
}

struct PanelActions: View {
    var updated: String
    var refreshing: Bool
    var dark: Bool
    var refresh: () -> Void
    var onOpenUsage: () -> Void
    var onToggleCollection: () -> Void = { AppActions.shared.toggle() }

    var body: some View {
        HStack(spacing: 3) {
            Text(updated).font(.system(size: 10)).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.75).padding(.leading, 6).help(updated)
            Spacer(minLength: 0)
            Button(action: refresh) { Label(L10n.text("panel.refresh"), systemImage: "arrow.clockwise") }
                .disabled(refreshing).accessibilityIdentifier("ai-usage.popover-refresh")
            Button(action: onToggleCollection) { Label(L10n.text("panel.collection"), systemImage: "tray") }
                .accessibilityIdentifier("ai-usage.popover-collection")
            Button(action: onOpenUsage) { Label(L10n.text("panel.settings"), systemImage: "gearshape") }
                .accessibilityIdentifier("ai-usage.popover-open-settings")
            Button { NSApp.terminate(nil) } label: { Label(L10n.text("windows.quit"), systemImage: "power") }
                .accessibilityIdentifier("ai-usage.popover-quit")
        }
        .labelStyle(PanelActionLabelStyle())
        .buttonStyle(PanelButtonStyle(dark: dark))
    }
}

private struct PanelActionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.icon.frame(width: 10)
            configuration.title
        }
    }
}

private struct PanelButtonStyle: ButtonStyle {
    var dark: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 10, weight: .medium))
            .fixedSize().padding(.horizontal, 4).frame(height: 26)
            .background(.white.opacity(configuration.isPressed ? 0.3 : dark ? 0.12 : 0.45), in: Capsule())
            .overlay(Capsule().strokeBorder(dark ? .white.opacity(0.1) : .black.opacity(0.08), lineWidth: 0.5))
            .contentShape(Capsule())
    }
}

private struct AIUsagePanelRow: View {
    @AppStorage(SubscriptionPreferences.colorKey) private var colorsByQuota = true
    var snapshot: AIUsageSnapshot
    var now: Date
    var onOpenUsage: () -> Void
    var refresh: () -> Void
    var isRefreshing: Bool
    @Environment(\.appTheme) private var mode
    private var dark: Bool { mode == .dark }
    private var secondary: Color { (dark ? Color(themeHex: "#EBEBF5") : Color(themeHex: "#3C3C43")).opacity(0.66) }
    private var window: AIUsageWindow? {
        snapshot.windows.first { AIUsageMenuBarController.remaining($0.remainingPercent) != nil } ?? snapshot.windows.first
    }
    private var subtitle: String? { PanelQuotaText.status(snapshot, now: now) }

    var body: some View {
        HStack(spacing: 10) {
            QuotaArcView(provider: snapshot.provider, percent: PanelQuotaData.remaining(window, in: snapshot), dark: dark)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(snapshot.provider.usageDisplayName).font(.system(size: 13, weight: .semibold))
                        .layoutPriority(1)
                    if let plan = snapshot.plan, !plan.isEmpty {
                        Text(plan).font(.system(size: 10)).foregroundStyle(secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background((dark ? Color.white : Color(themeHex: "#787880")).opacity(dark ? 0.12 : 0.14), in: Capsule())
                            .help(plan)
                    }
                }.lineLimit(1).minimumScaleFactor(0.75)
                Text(subtitle ?? PanelQuotaText.compactReset(window?.resetsAt, now: now))
                    .font(.system(size: 11)).foregroundStyle(snapshot.error == nil ? secondary : .red)
                    .lineLimit(1).truncationMode(.tail)
                    .help(subtitle ?? PanelQuotaText.compactReset(window?.resetsAt, now: now))
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 5) {
                quota(L10n.text("quota.fiveHours"), window: PanelQuotaData.window(.fiveHours, in: snapshot))
                quota(L10n.text("quota.weekly"), window: PanelQuotaData.window(.weekly, in: snapshot))
            }
        }
        .padding(.leading, 10).padding(.trailing, 12)
        .accessibilityElement(children: .combine)
        .contextMenu {
            // Extra windows, account status and source remain accessible without crowding the row.
            Text(snapshot.provider.title)
            if !snapshot.status.isEmpty { Text(snapshot.status) }
            if let subtitle { Text(subtitle) }
            if let balance = snapshot.balance { Text(L10n.text("menu.balance") + balance) }
            ForEach(snapshot.windows) { window in
                Text(L10n.text("menu.0.1.remaining", window.title,
                               AIUsageMenuBarController.percent(PanelQuotaData.remaining(window, in: snapshot))))
                Text(PanelQuotaText.reset(window.resetsAt, now: now))
            }
            Text(L10n.text("panel.source", snapshot.source))
            Divider()
            Button(L10n.text("panel.refresh"), action: refresh).disabled(isRefreshing)
            Button(L10n.text("panel.settings"), action: onOpenUsage)
        }
    }

    private func quota(_ title: String, window: AIUsageWindow?) -> some View {
        let percent = PanelQuotaData.remaining(window, in: snapshot)
        return HStack(spacing: 6) {
            Text(title).font(.system(size: 11)).foregroundStyle(secondary)
                .lineLimit(1).fixedSize().frame(width: 40, alignment: .leading)
            ZStack(alignment: .leading) {
                Capsule().fill(Color(themeHex: "#787880").opacity(dark ? 0.36 : 0.18))
                if let percent {
                    Capsule().fill(Color(nsColor: QuotaMenuImage.fillColor(percent: percent, colorsByQuota: colorsByQuota, foreground: dark ? .white : .black)))
                        .frame(width: 52 * percent / 100)
                }
            }.frame(width: 52, height: 4).accessibilityHidden(true)
            Text(percent.map { AIUsageMenuBarController.percent($0) } ?? L10n.text("common.unknown"))
                .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                .frame(width: 28, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Match actual window identities/titles; never treat another quota as a missing five-hour window.
@MainActor
enum PanelQuotaData {
    enum WindowKind { case fiveHours, weekly }
    static func window(_ kind: WindowKind, in snapshot: AIUsageSnapshot) -> AIUsageWindow? {
        snapshot.windows.first { window in
            switch kind {
            case .fiveHours:
                return window.id == "five_hour" || window.title == L10n.text("quota.fiveHours")
                    || window.title.hasSuffix(" · " + L10n.text("quota.fiveHours"))
            case .weekly:
                return ["seven_day", "grok.weekly"].contains(window.id) || window.title == L10n.text("quota.weekly")
                    || window.title.hasSuffix(" · " + L10n.text("quota.weekly"))
            }
        }
    }
    static func remaining(_ window: AIUsageWindow?, in snapshot: AIUsageSnapshot) -> Double? {
        guard snapshot.isConnected, snapshot.error == nil else { return nil }
        return AIUsageMenuBarController.remaining(window?.remainingPercent)
    }
}

enum PanelQuotaText {
    static func refreshError(_ snapshot: AIUsageSnapshot?) -> String? {
        guard let error = snapshot?.error, !error.isEmpty else { return nil }
        return L10n.text("error.refresh", error)
    }

    @MainActor static func status(_ snapshot: AIUsageSnapshot, now: Date) -> String? {
        if let error = refreshError(snapshot) { return error }
        if !snapshot.isConnected { return snapshot.status.isEmpty ? L10n.text("status.notConnected") : snapshot.status }
        if AIUsageMenuBarController.isExpired(snapshot, now: now) { return L10n.text("panel.cache.expired") }
        if AIUsageMenuBarController.isCached(snapshot, now: now) { return L10n.text("status.cached") }
        if snapshot.windows.isEmpty { return snapshot.status.isEmpty ? L10n.text("panel.resetUnknown") : snapshot.status }
        return nil
    }

    static func compactReset(_ date: Date?, now: Date) -> String {
        guard let date else { return L10n.text("panel.resetUnknown") }
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return L10n.text("panel.resetDue") }
        let minutes = max(1, Int(ceil(seconds / 60)))
        if minutes >= 1440 { return L10n.text("panel.resetDaysShort", minutes / 1440) }
        if minutes >= 60 { return L10n.text("panel.resetHoursShort", minutes / 60) }
        return L10n.text("panel.resetMinutes", minutes)
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
