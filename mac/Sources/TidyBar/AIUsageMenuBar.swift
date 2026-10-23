import AppKit
import Combine
import SwiftUI

/// App-local preference, shared by the settings checkbox and status-item owner.
enum AIUsageMenuBarPreference {
    enum PercentagePlacement: String, CaseIterable {
        case arcTop, beside
        var titleKey: String { "settings.percentagePlacement.\(rawValue)" }
    }
    static let key = "aiUsage.showInMenuBar"
    static let percentageKey = "aiUsage.showPercentageInMenuBar"
    static let placementKey = "aiUsage.percentagePlacement"
    static var isEnabled: Bool { isEnabled(defaults: .standard) }
    static func isEnabled(defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }
    static var showsPercentage: Bool { showsPercentage(defaults: .standard) }
    static func showsPercentage(defaults: UserDefaults) -> Bool {
        defaults.object(forKey: percentageKey) as? Bool ?? true
    }
    static func percentagePlacement(defaults: UserDefaults = .standard) -> PercentagePlacement {
        defaults.string(forKey: placementKey).flatMap(PercentagePlacement.init(rawValue:)) ?? .arcTop
    }
}

@MainActor
enum AIUsageBrand {
    static var previewResources: URL?
    private static var icons: [AIUsageProvider: NSImage] = [:]

    static func image(for provider: AIUsageProvider) -> NSImage {
        if let image = icons[provider] { return image }
        let filename: String?
        let asset: String
        switch provider {
        case .codex: filename = "ChatGPT.app"; asset = "openai"
        case .claude: filename = "Claude.app"; asset = "anthropic"
        case .grok: filename = "Grok Bot.app"; asset = "xai"
        case .openaiAPI: filename = nil; asset = "openai"
        case .anthropicAPI: filename = nil; asset = "anthropic"
        case .geminiAPI: filename = nil; asset = "gemini"
        case .xaiAPI: filename = nil; asset = "xai"
        case .deepseekAPI: filename = nil; asset = "deepseek"
        case .openrouterAPI: filename = nil; asset = "openrouter"
        case .kimiAPI: filename = nil; asset = "kimi"
        case .minimaxAPI: filename = nil; asset = "minimax"
        }
        let candidates = [URL(fileURLWithPath: "/Applications", isDirectory: true),
                          FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)]
        let installed = (previewResources == nil ? filename : nil).flatMap { name in
            candidates.map { $0.appendingPathComponent(name) }.first { FileManager.default.fileExists(atPath: $0.path) }
        }
        let image: NSImage
        if let installed {
            image = NSWorkspace.shared.icon(forFile: installed.path)
            image.isTemplate = false
        } else if provider == .grok, let grok = grokImage() {
            image = grok
        } else if let url = (previewResources ?? Bundle.main.resourceURL?.appendingPathComponent("ProviderLogos"))?.appendingPathComponent(asset + ".png"),
                  let bundled = NSImage(contentsOf: url) {
            image = bundled
            image.isTemplate = ["openai", "anthropic", "xai", "openrouter", "kimi"].contains(asset)
        } else {
            image = NSImage(systemSymbolName: "cpu", accessibilityDescription: provider.title) ?? NSImage(size: NSSize(width: 16, height: 16))
            image.isTemplate = true
        }
        icons[provider] = image
        return image
    }

    static func menuImage(for provider: AIUsageProvider, size: CGFloat = 16) -> NSImage {
        let original = image(for: provider)
        let copy = (original.copy() as? NSImage) ?? original
        copy.size = NSSize(width: size, height: size)
        return copy
    }

    static func panelImage(for provider: AIUsageProvider) -> NSImage {
        if provider == .grok, let icon = grokImage() { return icon }
        let filename: String
        switch provider {
        case .claude: filename = "claude.png"
        case .grok: filename = "grok.png"
        default: return image(for: provider)
        }
        let icon = NSImage(contentsOf: SharedResources.url(filename, directory: "logos")) ?? image(for: provider)
        icon.isTemplate = provider == .grok
        return icon
    }

    static func grokImage(privateURL: URL = SharedResources.url("grokbot.png", directory: "private-logos"),
                          fallbackURL: URL = SharedResources.url("grok.png", directory: "logos")) -> NSImage? {
        if let image = NSImage(contentsOf: privateURL) { return image }
        let image = NSImage(contentsOf: fallbackURL)
        image?.isTemplate = true
        return image
    }
}

@MainActor
struct AIUsageProviderLogo: View {
    var provider: AIUsageProvider
    var size: CGFloat = 28
    var body: some View {
        Image(nsImage: AIUsageBrand.image(for: provider))
            .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityLabel(L10n.text("menu.0.logo", provider.title))
    }
}

@MainActor
final class AIUsageMenuBarController: NSObject, NSMenuDelegate {
    private let store: AIUsageStore
    private let onOpenUsage: () -> Void
    private let running = RunningAIStore()
    private var statusItem: NSStatusItem?
    private var statusButtonRegistration: UUID?
    private var appearanceObservation: NSKeyValueObservation?
    private var subscriptions: Set<AnyCancellable> = []
    private var timer: Timer?
    private var started = false
    var panel: AIUsagePanel { PopupManager.shared.panel }
    var themeOverride: AppTheme?
    private var presentationSnapshots: [AIUsageSnapshot] {
        store.menuBarDisplaySnapshots
    }

    init(store: AIUsageStore, onOpenUsage: @escaping () -> Void) {
        self.store = store
        self.onOpenUsage = onOpenUsage
        super.init()
    }

    func start(observeRunning: Bool = true) {
        guard !started else { return }
        started = true
        running.$active.sink { [weak self] active in self?.store.runningProviders = active }.store(in: &subscriptions)
        store.$runningProviders.sink { [weak self] _ in Task { @MainActor in self?.update() } }.store(in: &subscriptions)
        if observeRunning { running.start() }
        store.$snapshots.sink { [weak self] _ in Task { @MainActor in self?.update() } }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).sink { [weak self] _ in
            Task { @MainActor in self?.update() }
        }.store(in: &subscriptions)
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in Task { @MainActor in self?.update() } }
        update()
    }

    func stop() {
        started = false
        running.stop()
        timer?.invalidate(); timer = nil
        subscriptions.removeAll()
        removeStatusItem()
    }

    private func removeStatusItem() {
        closePanel()
        if let statusButtonRegistration { PopupManager.shared.unregisterStatusFrames(statusButtonRegistration) }
        statusButtonRegistration = nil
        appearanceObservation = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    private func update() {
        guard started else { return }
        // Keep one app entry when quota display is off.
        let preferences = store.subscriptionPreferences
        let idle = !AIUsageMenuBarPreference.isEnabled(defaults: preferences.defaults) || presentationSnapshots.isEmpty
        let image = idle ? AppBrand.idleImage() : QuotaMenuImage.image(
            snapshots: presentationSnapshots,
            showPercentage: AIUsageMenuBarPreference.showsPercentage(defaults: preferences.defaults),
            colorsByQuota: preferences.colorsByQuota,
            placement: AIUsageMenuBarPreference.percentagePlacement(defaults: preferences.defaults))
        let length = image.size.width
        if statusItem == nil {
            let autosaveName = (Bundle.main.bundleIdentifier ?? "com.mike.aisubgauge") + ".ai-usage"
            let positionKey = "NSStatusItem Preferred Position " + autosaveName
            if UserDefaults.standard.object(forKey: positionKey) == nil {
                UserDefaults.standard.set(0, forKey: positionKey)
            }
            let item = NSStatusBar.system.statusItem(withLength: length)
            item.autosaveName = autosaveName
            item.button?.setAccessibilityIdentifier("com.mike.aisubgauge.ai-usage")
            item.button?.setAccessibilityLabel(L10n.text("menu.ai.remaining.quota"))
            item.button?.target = self
            item.button?.action = #selector(statusItemClicked(_:))
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            item.isVisible = true
            statusItem = item
            if let button = item.button { statusButtonRegistration = PopupManager.shared.registerStatusButton(button) }
            appearanceObservation = item.button?.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.update() }
            }
        }
        statusItem?.button?.image = image
        statusItem?.button?.needsDisplay = true
        statusItem?.button?.imageScaling = .scaleProportionallyDown
        statusItem?.length = length
        statusItem?.button?.contentTintColor = idle ? .secondaryLabelColor : nil
        let now = Date()
        var tooltip: [String] = [L10n.text("menu.ai.account.quota.click.or.right.click")]
        for connected in presentationSnapshots {
            let provider = connected.provider
            let snapshot: AIUsageSnapshot? = connected
            let window = snapshot?.windows.first { Self.remaining($0.remainingPercent) != nil }
            let value = Self.displayValue(connected)
            let cached = Self.isCached(snapshot, now: now)
            var line = L10n.text("menu.0.1.remaining", provider.title, value)
            if let window { line += L10n.text("common.parenthesized", window.title) }
            if snapshot?.error != nil { line += L10n.text("menu.refresh.failed.please.try.again.later") }
            else if cached { line += L10n.text("menu.cached") }
            if let date = snapshot?.updatedAt { line += L10n.text("menu.updated") + Self.date(date) }
            if let source = snapshot?.source { line += L10n.text("menu.source") + source }
            tooltip.append(line)
        }
        statusItem?.button?.title = ""
        statusItem?.button?.imagePosition = .imageOnly
        statusItem?.button?.toolTip = idle ? L10n.text("idle.tooltip") : tooltip.joined(separator: "\n")
        if PopupManager.shared.kind == .quota, panel.isVisible { updatePanel() }
    }

    @objc func statusItemClicked(_ button: NSButton) {
        PopupManager.shared.recordStatusItemAction()
        let event = StatusItemApplication.actionEvent
        guard PopupManager.shared.consume(event) else { return }
        if event?.modifierFlags.contains(.option) == true {
            AppActions.shared.showSearch()
        } else if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            PopupManager.shared.dismiss()
            guard let item = statusItem else { return }
            let menu = NSMenu(); menu.delegate = self
            item.menu = menu; button.performClick(nil); item.menu = nil
        } else {
            togglePanel(relativeTo: button)
        }
    }

    func togglePanel(relativeTo button: NSView) {
        PopupManager.shared.present(.quota, anchor: button) { panel in
            updatePanel()
            let anchor = PopupManager.screenFrame(button) ?? .zero
            let visible = (button.window?.screen ?? NSScreen.main)?.visibleFrame ?? anchor
            let x = min(max(visible.minX + 8, anchor.midX - panel.frame.width / 2), visible.maxX - panel.frame.width - 8)
            panel.setFrameTopLeftPoint(NSPoint(x: x, y: min(visible.maxY, anchor.minY) - 6))
        }
    }

    var statusWindowFrame: CGRect? {
        guard let frame = statusButtonFrame, let top = NSScreen.screens.first?.frame.maxY else { return nil }
        return CGRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height)
    }
    var statusButtonFrame: NSRect? { PopupManager.screenFrame(statusItem?.button) }

    private func updatePanel() {
        let mode = themeOverride ?? AppTheme.resolve(preference: UserDefaults.standard.string(forKey: AppTheme.preferenceKey),
            systemDark: NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        let available = (statusItem?.button?.window?.screen?.visibleFrame.height ?? 700) - 50
        let height = max(194, min(600, min(available, AIUsagePopoverView.height(for: store.subscriptionDisplaySnapshots.count))))
        panel.appearance = NSAppearance(named: mode == .dark ? .darkAqua : .aqua)
        panel.setContentSize(NSSize(width: AIUsagePopoverView.width, height: height))
        let view = AIUsagePopoverView(store: store, now: Date(), height: height,
            onOpenUsage: { [weak self] in self?.openUsage() }, themeOverride: mode,
            onOpenPanelSettings: { [weak self] in self?.openPanelSettings() })
        if let hosting = panel.contentView as? NSHostingView<AIUsagePopoverView> { hosting.rootView = view }
        else { panel.contentView = NSHostingView(rootView: view) }
    }

    func dismissForClick(at point: NSPoint) { PopupManager.shared.dismissForClick(at: point) }
    func closePanel() { PopupManager.shared.dismiss(.quota) }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        populateMenu(menu)
    }

    private func populateMenu(_ menu: NSMenu) {
        let now = Date()
        func info(_ text: String, indent: Int = 0) {
            let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            item.indentationLevel = indent
            menu.addItem(item)
        }
        for (index, connected) in store.displaySnapshots.enumerated() {
            let provider = connected.provider
            if index > 0 { menu.addItem(.separator()) }
            let snapshot: AIUsageSnapshot? = connected
            let cache = Self.isCached(snapshot, now: now)
            let heading = NSMenuItem(title: provider.title + (snapshot?.error != nil ? L10n.text("menu.refresh.failed") : cache ? L10n.text("menu.cached") : snapshot?.isConnected == true ? L10n.text("menu.connected") : L10n.text("menu.not.connected")), action: nil, keyEquivalent: "")
            heading.image = AIUsageBrand.menuImage(for: provider)
            menu.addItem(heading)
            if let plan = snapshot?.plan { info(L10n.text("menu.plan") + plan, indent: 1) }
            if let balance = snapshot?.balance { info(L10n.text("menu.balance") + balance, indent: 1) }
            if let snapshot, !snapshot.windows.isEmpty {
                for window in snapshot.windows {
                    info(L10n.text("menu.0.1.remaining", window.title, Self.percent(window.remainingPercent)), indent: 1)
                    info(L10n.text("panel.resetPrefix") + (window.resetsAt.map(Self.date) ?? L10n.text("common.notProvided")), indent: 2)
                }
            } else { info(L10n.text("menu.remaining.quota"), indent: 1) }
            info(L10n.text("panel.updateLine", cache ? L10n.text("panel.cacheUpdated") : L10n.text("panel.updated"), snapshot?.updatedAt.map(Self.date) ?? L10n.text("status.notUpdated")), indent: 1)
            info(L10n.text("panel.sourcePrefix") + (snapshot?.source ?? L10n.text("status.notConnected")), indent: 1)
            if let error = snapshot?.error, !error.isEmpty { info(L10n.text("error.refreshPrefix") + error, indent: 1) }
            if let snapshot {
                let expired = snapshot.expiresAt.map { now >= $0 }
                    ?? (snapshot.updatedAt.map { now.timeIntervalSince($0) > 300 } ?? false)
                if expired { info(L10n.text("menu.the.cache.has.expired.refresh.to.confirm"), indent: 1) }
            }
        }
        menu.addItem(.separator())
        let providers = NSMenuItem(title: L10n.text("settings.providers"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for provider in AIUsageProvider.allCases {
            let row = NSMenuItem(title: provider.title, action: #selector(toggleProvider(_:)), keyEquivalent: "")
            row.target = self; row.representedObject = provider.rawValue
            row.state = store.selectedProviders.contains(provider.rawValue) ? .on : .off
            submenu.addItem(row)
        }
        let automatic = NSMenuItem(title: L10n.text("settings.providers.automatic"), action: #selector(resetProviders), keyEquivalent: "")
        automatic.target = self; submenu.addItem(.separator()); submenu.addItem(automatic)
        providers.submenu = submenu; menu.addItem(providers)
        let always = NSMenuItem(title: L10n.text("settings.alwaysShowAll"), action: #selector(toggleAlways), keyEquivalent: "")
        always.target = self; always.state = UserDefaults.standard.bool(forKey: AIVisibilityPreferences.alwaysShowKey) ? .on : .off
        menu.addItem(always)
        if AppActions.shared.engine?.accessibilityGranted == false {
            let permission = NSMenuItem(title: CollectionAccess.message, action: #selector(openCollectionAccessibility), keyEquivalent: "")
            permission.target = self; menu.addItem(permission)
        }
        for (title, action) in [(L10n.text("menu.toggleCollection"), #selector(toggleCollection)),
                                (L10n.text("menu.open.collection.bar"), #selector(toggleCollectionBar)),
                                (L10n.text("menu.search.all.icons"), #selector(searchCollection)),
                                (L10n.text("menu.collectionSettings"), #selector(openCollectionSettings))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; menu.addItem(item)
        }
        let settings = NSMenuItem(title: L10n.text("menu.settings"), action: #selector(openSettings), keyEquivalent: "")
        settings.target = self; menu.addItem(settings)
        let diagnostics = NSMenuItem(title: L10n.text("menu.diagnostics"), action: #selector(exportDiagnostics), keyEquivalent: "")
        diagnostics.target = self; menu.addItem(diagnostics)
        let quit = NSMenuItem(title: L10n.text("menu.quit"), action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
        let refresh = NSMenuItem(title: store.isRefreshing ? L10n.text("menu.refreshing") : L10n.text("menu.refreshAll"), action: #selector(refreshAll), keyEquivalent: "")
        refresh.target = self; refresh.isEnabled = !store.isRefreshing; menu.addItem(refresh)
        let open = NSMenuItem(title: L10n.text("menu.open.ai.usage"), action: #selector(openUsage), keyEquivalent: "")
        open.target = self; menu.addItem(open)
    }

    @objc func toggleCollection() {
        guard let engine = AppActions.shared.engine, engine.requireCollectionAccessibility() else { return }
        PopupManager.shared.dismiss()
        engine.toggle()
    }
    @objc func toggleCollectionBar() { AppActions.shared.toggle() }
    @objc func openCollectionSettings() { PopupManager.shared.dismiss(); AppActions.shared.showCollectionSettings() }
    @objc func openCollectionAccessibility() { CollectionAccess.openSettings() }
    @objc private func searchCollection() { AppActions.shared.showSearch() }

    @objc private func toggleProvider(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, let provider = AIUsageProvider(rawValue: key) else { return }
        AIVisibilityPreferences.setSelected(!store.selectedProviders.contains(key), provider: provider)
        update()
    }
    @objc private func resetProviders() { UserDefaults.standard.removeObject(forKey: AIVisibilityPreferences.selectionKey); update() }
    @objc private func toggleAlways() {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: AIVisibilityPreferences.alwaysShowKey), forKey: AIVisibilityPreferences.alwaysShowKey)
        update()
    }
    @objc private func openSettings() { closePanel(); AppActions.shared.showSettings() }
    func openPanelSettings() { closePanel(); AppActions.shared.showSettings(.panel) }
    @objc private func exportDiagnostics() { DiagnosticsPreview.shared.show(snapshots: store.snapshots) }
    @objc private func quitApp() { NSApp.terminate(nil) }
    @objc private func refreshAll() { store.refresh() }
    @objc private func openUsage() { closePanel(); onOpenUsage() }

    static func statusTitle(_ snapshot: AIUsageSnapshot) -> String {
        displayValue(snapshot) + (snapshot.error != nil ? " ⚠︎" : "")
    }

    static func displayValue(_ snapshot: AIUsageSnapshot) -> String {
        guard snapshot.isConnected, snapshot.error == nil else { return L10n.text("common.unknown") }
        if let window = snapshot.windows.first(where: { remaining($0.remainingPercent) != nil }) {
            return percent(window.remainingPercent)
        }
        if snapshot.provider.isAPIAccount, snapshot.isConnected, snapshot.error == nil,
           let balance = snapshot.balance, !balance.isEmpty { return balance }
        return L10n.text("common.unknown")
    }

    static func remaining(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (0...100).contains(value) else { return nil }
        return value
    }
    static func percent(_ value: Double?) -> String {
        guard let value = remaining(value) else { return L10n.text("common.unknown") }
        return value.formatted(.number.precision(.fractionLength(0))) + "%"
    }
    static func isCached(_ snapshot: AIUsageSnapshot?, now: Date) -> Bool {
        guard let snapshot, snapshot.updatedAt != nil else { return false }
        return snapshot.source == GrokUsageSource.source || snapshot.error != nil || !snapshot.isConnected
            || isExpired(snapshot, now: now)
    }
    static func isExpired(_ snapshot: AIUsageSnapshot, now: Date) -> Bool {
        snapshot.expiresAt.map { now >= $0 } ?? (snapshot.updatedAt.map { now.timeIntervalSince($0) > 300 } ?? false)
    }
    static func date(_ value: Date) -> String {
        let format = DateFormatter()
        format.locale = L10n.locale; format.timeZone = .current
        format.dateFormat = L10n.text("format.dateTime")
        return format.string(from: value)
    }
}

/// One reusable window; the SwiftUI glass is the panel's only visible shell.
final class AIUsagePanel: NSPanel {
    var onDismiss: (() -> Void)?
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: AIUsagePopoverView.width, height: 283),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        identifier = NSUserInterfaceItemIdentifier("ai-usage.panel")
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onDismiss?() }
}
