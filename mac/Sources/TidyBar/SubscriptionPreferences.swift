import Combine
import Foundation

/// Independent presentation preferences; never changes account selection or credentials.
struct SubscriptionPreferences {
    static let orderKey = "aiUsage.subscriptionOrder"
    static let hiddenKey = "aiUsage.menuBarHiddenProviders"
    static let colorKey = "aiUsage.colorByRemainingQuota"
    static let refreshKey = "aiUsage.refreshMinutes"
    static let refreshOptions = [1, 2, 5, 15, 30]
    var defaults: UserDefaults = .standard

    struct DisplayState: Equatable {
        let enabled: Bool
        let percentage: Bool
        let placement: AIUsageMenuBarPreference.PercentagePlacement
        let colors: Bool
        let order: [AIUsageProvider]
        let hidden: Set<String>
        let selection: [String: Bool]
        let alwaysShow: Bool
        let theme: AppTheme?
    }
    struct State: Equatable {
        let display: DisplayState
        let refreshMinutes: Int
    }
    var state: State {
        State(display: DisplayState(enabled: AIUsageMenuBarPreference.isEnabled(defaults: defaults),
            percentage: AIUsageMenuBarPreference.showsPercentage(defaults: defaults),
            placement: AIUsageMenuBarPreference.percentagePlacement(defaults: defaults), colors: colorsByQuota,
            order: order, hidden: Set(defaults.stringArray(forKey: Self.hiddenKey) ?? []),
            selection: AIVisibilityPreferences.selectionOverrides(defaults: defaults),
            alwaysShow: defaults.bool(forKey: AIVisibilityPreferences.alwaysShowKey),
            theme: defaults.string(forKey: AppTheme.preferenceKey).flatMap(AppTheme.init(rawValue:))),
            refreshMinutes: refreshMinutes)
    }
    /// Defaults notifications include AppKit autosave writes. Only effective app preferences matter.
    var changes: AnyPublisher<State, Never> {
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .map { _ in self.state }.prepend(state).removeDuplicates().eraseToAnyPublisher()
    }

    var order: [AIUsageProvider] {
        let saved = (defaults.stringArray(forKey: Self.orderKey) ?? []).compactMap(AIUsageProvider.init(rawValue:))
        var result: [AIUsageProvider] = []
        for provider in saved + AIUsageProvider.allCases where !result.contains(provider) { result.append(provider) }
        return result
    }
    func sorted(_ snapshots: [AIUsageSnapshot]) -> [AIUsageSnapshot] {
        order.compactMap { provider in snapshots.first { $0.provider == provider } }
    }
    @discardableResult func move(_ provider: AIUsageProvider, before target: AIUsageProvider) -> Bool {
        guard provider != target else { return false }
        var values = order.filter { $0 != provider }
        guard let index = values.firstIndex(of: target) else { return false }
        values.insert(provider, at: index)
        defaults.set(values.map(\.rawValue), forKey: Self.orderKey)
        return true
    }
    @discardableResult func move(_ provider: AIUsageProvider, after target: AIUsageProvider) -> Bool {
        guard provider != target else { return false }
        var values = order.filter { $0 != provider }
        guard let index = values.firstIndex(of: target) else { return false }
        values.insert(provider, at: index + 1)
        defaults.set(values.map(\.rawValue), forKey: Self.orderKey)
        return true
    }
    func showsInMenuBar(_ provider: AIUsageProvider) -> Bool {
        !(defaults.stringArray(forKey: Self.hiddenKey) ?? []).contains(provider.rawValue)
    }
    func setShowsInMenuBar(_ show: Bool, provider: AIUsageProvider) {
        var hidden = Set(defaults.stringArray(forKey: Self.hiddenKey) ?? [])
        if show { hidden.remove(provider.rawValue) } else { hidden.insert(provider.rawValue) }
        defaults.set(hidden.sorted(), forKey: Self.hiddenKey)
    }
    var colorsByQuota: Bool { defaults.object(forKey: Self.colorKey) as? Bool ?? true }
    var refreshMinutes: Int {
        let minutes = defaults.integer(forKey: Self.refreshKey)
        return Self.refreshOptions.contains(minutes) ? minutes : 2
    }
}
