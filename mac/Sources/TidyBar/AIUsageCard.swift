import AppKit
import SwiftUI

struct AIUsageCard: View {
    @Environment(\.appTheme) private var themeMode
    private var theme: ThemePalette { ThemeCatalog.shared.palette(themeMode) }
    var provider: AIUsageProvider
    var snapshot: AIUsageSnapshot?
    var now: Date
    var isRefreshing: Bool
    var refresh: () -> Void
    var remove: () -> Void
    private var secondary: Color { theme.color(\.textSecondary) }

    private var name: String { provider.title }
    private var tint: Color { provider.usageTint }
    private var expired: Bool {
        if let expiresAt = snapshot?.expiresAt { return now >= expiresAt }
        return snapshot?.updatedAt.map { now.timeIntervalSince($0) > 300 } ?? false
    }
    private var cached: Bool {
        guard let snapshot else { return false }
        return expired || (snapshot.updatedAt != nil && (snapshot.source == GrokUsageSource.source || !snapshot.isConnected || snapshot.error != nil))
    }
    private var badge: (title: String, color: Color) {
        guard let snapshot else { return (L10n.text("status.notConnected"), secondary) }
        if snapshot.error != nil { return (L10n.text("status.refreshFailed"), theme.color(\.demo)) }
        if expired { return (L10n.text("panel.cache.expired"), theme.color(\.demo)) }
        if cached { return (L10n.text("status.cached"), theme.color(\.demo)) }
        if !snapshot.isConnected { return (L10n.text("status.notConnected"), secondary) }
        if snapshot.updatedAt == nil { return (L10n.text("panel.update.time.unknown"), theme.color(\.demo)) }
        return (L10n.text("status.connected"), tint)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            HStack(alignment: .top, spacing: 14) {
                detail(label: L10n.text("panel.plan"), value: snapshot?.plan)
                Rectangle().fill(theme.color(\.divider)).frame(width: 1, height: 30)
                detail(label: L10n.text("panel.balance"), value: snapshot?.balance)
            }
            Divider().overlay(theme.color(\.divider))
            if let snapshot, !snapshot.windows.isEmpty {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(snapshot.windows) { window in
                        AIUsageWindowRow(window: window, tint: tint, now: now)
                    }
                }
            } else if snapshot?.balance?.isEmpty != false {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(L10n.text("panel.remainingQuota")).font(.callout).foregroundStyle(secondary)
                        Spacer()
                        Text(L10n.text("common.unknown")).font(.system(size: 27, weight: .semibold, design: .rounded)).foregroundStyle(secondary)
                    }
                    Capsule().fill(theme.color(\.barTrack)).frame(height: 5).accessibilityHidden(true)
                    Text(snapshot?.isConnected == true ? L10n.text("panel.this.service.has.not.provided.a.quota") : (snapshot?.wasConfigured == true || snapshot?.updatedAt != nil) ? L10n.text("panel.actual.remaining.quota.and.reset.times.appear") : L10n.text("panel.connect.to.see.actual.remaining.quota.and"))
                        .font(.caption).foregroundStyle(secondary)
                }
            }
            if let status = snapshot?.status, !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(status).font(.caption).foregroundStyle(secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            } else if snapshot == nil {
                Text(L10n.text("panel.this.service.is.not.connected.yet.refresh"))
                    .font(.caption).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error = PanelQuotaText.refreshError(snapshot) {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.circle")
                    Text(error).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }.font(.caption).foregroundStyle(theme.color(\.error))
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.color(\.error).opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
            }
            Divider().overlay(theme.color(\.divider))
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: cached ? "clock.badge.exclamationmark" : "clock")
                    if let date = snapshot?.updatedAt {
                        Text("\(cached ? L10n.text("panel.cacheUpdated") : L10n.text("panel.updated")) \(AIUsageDateText.date(date))")
                    } else { Text(L10n.text("panel.no.update.time.available.yet")) }
                }.foregroundStyle(cached ? theme.color(\.demo) : secondary)
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "link")
                    Text(L10n.text("panel.source", source)).lineLimit(3).help(source).textSelection(.enabled)
                }.foregroundStyle(secondary)
            }.font(.system(size: 10))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(theme.color(\.surface), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(theme.color(\.divider), lineWidth: 1))
    }

    private var source: String {
        guard let source = snapshot?.source, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return L10n.text("status.notConnected") }
        return source
    }
    private var header: some View {
        HStack(spacing: 10) {
            AIUsageProviderLogo(provider: provider, size: 30).foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(provider.usageDisplayName).font(.system(size: 17, weight: .semibold))
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .accessibilityIdentifier("ai-usage.card.\(provider.rawValue)")
                    Text(provider.isAPIAccount ? L10n.text("account.api") : L10n.text("panel.subscription")).font(.system(size: 9, weight: .medium))
                        .foregroundStyle(secondary).padding(.horizontal, 5).padding(.vertical, 3)
                        .background(theme.color(\.divider), in: Capsule())
                }
                HStack(spacing: 5) {
                    Circle().fill(badge.color).frame(width: 5, height: 5)
                    Text(badge.title).font(.system(size: 10)).foregroundStyle(badge.color)
                }
            }
            Spacer(minLength: 2)
            Button(action: refresh) { Image(systemName: "arrow.clockwise").font(.system(size: 12)) }
                .buttonStyle(.plain).foregroundStyle(secondary).disabled(isRefreshing)
                .padding(5).contentShape(Rectangle())
                .help(L10n.text("panel.refresh.0.usage", name)).accessibilityLabel(L10n.text("panel.refresh.0.usage", name))
                .accessibilityIdentifier("ai-usage.refresh.\(provider.rawValue)")
            if provider.isAPIAccount {
                Menu {
                    Link(L10n.text("panel.open.official.billing"), destination: APIUsageSource.dashboardURL(provider))
                    Button(L10n.text("panel.remove.api.account"), role: .destructive, action: remove)
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize().frame(width: 18)
                    .help(L10n.text("panel.api.account.options")).accessibilityLabel(L10n.text("panel.0.account.options", name))
            }
        }
    }
    private func detail(label: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 10)).foregroundStyle(secondary)
            Text(value.flatMap { $0.isEmpty ? nil : $0 } ?? L10n.text("common.unknown"))
                .font(.system(size: 12, weight: .medium)).monospacedDigit()
                .lineLimit(2).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AIUsageWindowRow: View {
    @Environment(\.appTheme) private var themeMode
    private var theme: ThemePalette { ThemeCatalog.shared.palette(themeMode) }
    var window: AIUsageWindow
    var tint: Color
    var now: Date
    private var remaining: Double? {
        guard let value = window.remainingPercent, value.isFinite, (0...100).contains(value) else { return nil }
        return value
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(window.title).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.color(\.textSecondary))
                Spacer(minLength: 2)
                if let remaining {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(remaining, format: .number.precision(.fractionLength(0)))
                            .font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text(L10n.text("panel.remaining.95")).font(.system(size: 10)).foregroundStyle(theme.color(\.textSecondary))
                    }
                } else {
                    Text(L10n.text("common.unknown")).font(.system(size: 26, weight: .semibold, design: .rounded)).foregroundStyle(theme.color(\.textSecondary))
                }
            }
            GeometryReader { geometry in
                Capsule().fill(theme.color(\.barTrack))
                    .overlay(alignment: .leading) {
                        if let remaining {
                            Capsule().fill(ThemeCatalog.shared.quotaColor(remaining)).frame(width: geometry.size.width * remaining / 100)
                        }
                    }
            }.frame(height: 5).accessibilityHidden(true)
            if let reset = window.resetsAt {
                VStack(alignment: .leading, spacing: 3) {
                    Text(AIUsageDateText.reset(reset, now: now))
                        .foregroundStyle(reset <= now ? theme.color(\.demo) : theme.color(\.textSecondary))
                    Text(AIUsageDateText.date(reset)).foregroundStyle(theme.color(\.textSecondary))
                }.font(.system(size: 10)).monospacedDigit()
            } else { Text(L10n.text("panel.reset.time.not.provided")).font(.system(size: 10)).foregroundStyle(theme.color(\.textSecondary)) }
            if remaining == nil { Text(L10n.text("panel.remaining.quota.not.provided")).font(.system(size: 10)).foregroundStyle(theme.color(\.textSecondary)) }
        }
        .accessibilityElement(children: .combine)
    }
}

private enum AIUsageDateText {
    static func date(_ value: Date) -> String {
        let format = DateFormatter()
        format.locale = L10n.locale
        format.timeZone = .current
        format.dateFormat = L10n.text("format.dateTime")
        return format.string(from: value)
    }
    static func reset(_ value: Date, now: Date) -> String {
        let seconds = value.timeIntervalSince(now)
        guard seconds > 0 else { return L10n.text("panel.the.reset.time.has.arrived.refresh.to") }
        let minutes = max(1, Int(ceil(seconds / 60)))
        let days = minutes / 1440
        let hours = (minutes % 1440) / 60
        let remainder = minutes % 60
        if days > 0 { return L10n.text("panel.resets.in.0.days.1.hours", days, hours) }
        if hours > 0 { return L10n.text("panel.resets.in.0.hours.1.minutes", hours, remainder) }
        return L10n.text("panel.resets.in.0.minutes", remainder)
    }
}

extension AIUsageProvider {
    var usageDisplayName: String { title.hasSuffix(" API") ? String(title.dropLast(4)) : title }
    var usageTint: Color { Color(themeHex: ThemeCatalog.shared.providers[rawValue]!) }

}

