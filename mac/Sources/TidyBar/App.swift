import AppKit
import Combine
import SwiftUI

@MainActor
final class AppActions {
    static let shared = AppActions()
    weak var engine: MenuEngine?
    var onSettings: ((SettingsSection) -> Void)?
    var onSearch: (() -> Void)?
    var onToggle: (() -> Void)?
    func showSettings(_ section: SettingsSection = .subscriptions) { onSettings?(section) }
    func showSearch() { onSearch?() }
    var onCollectionSettings: (() -> Void)?
    func showCollectionSettings() { onCollectionSettings?() }
    func showLayoutSettings() {
        showSettings(.layout)
    }
    func startCollection(_ engine: MenuEngine, observeSystem: Bool = true) {
        self.engine = engine
        engine.start(observeSystem: observeSystem)
    }
    func toggle() {
        guard engine?.requireCollectionAccessibility() != false else { return }
        onToggle?()
    }
}

@main
struct TidyBarMain {
    @MainActor static func main() {
        let app = StatusItemApplication.shared
        do {
            try L10n.configure(arguments: CommandLine.arguments)
            #if DEBUG
            if CommandLine.arguments.contains("--ui-preview") || Bundle.main.bundleIdentifier == "com.mike.aisubgauge.ui-v2" {
                UIPreviewApp.run()
                return
            }
            if let directory = try PreviewRenderer.directory(arguments: CommandLine.arguments) {
                try PreviewRenderer.render(to: directory, theme: PreviewRenderer.theme(arguments: CommandLine.arguments))
                return
            }
            #endif
        } catch {
            fputs(L10n.text("menu.ai.subgauge.development.preview.failed"), stderr)
            exit(1)
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var store: SettingsStore!
    private var engine: MenuEngine!
    private var appearance: AppearanceController!
    private let themeController = ThemeController()
    private var widgets: WidgetController!
    private var usageMenuBar: AIUsageMenuBarController?
    private var automation: AutomationController!
    private var hotkeys: HotkeyController!
    private var statusItem: NSStatusItem!
    private var settingsController: SettingsWindowController?
    private var searchPanel: AIUsagePanel? {
        let manager = PopupManager.shared
        return manager.kind == .drawer || manager.kind == .search ? manager.panel : nil
    }
    private var subscriptions = Set<AnyCancellable>()
    private var spacerItems: [NSStatusItem] = []
    private var groupItems: [NSStatusItem] = []
    private var statusFramesRegistration: UUID?
    private var observers: [NSObjectProtocol] = []
    private var eventMonitors: [Any] = []
    private var timer: Timer?
    private var lastInteraction = Date()
    private var hoverReveal = HoverReveal()
    private var menuDepth = 0
    private var extrasSignature = ""
    private var stopping = false
    private var lastOrder: [String] = []
    private var presetGeneration = 0
    private var presetBaseline: LayoutPreset?
    private var pendingPresetTarget: LayoutPreset?

    init(settingsController: SettingsWindowController? = nil, engine: MenuEngine? = nil) {
        self.settingsController = settingsController
        self.engine = engine
        self.store = engine?.store
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let duplicate = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == Bundle.main.bundleIdentifier && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard !duplicate else {
            NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == Bundle.main.bundleIdentifier && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }?.activate()
            NSApp.terminate(nil); return
        }
        themeController.start()
        let migrationWarnings = AppMigration.runAtLaunch()
        store = SettingsStore()
        if !migrationWarnings.isEmpty { store.error = migrationWarnings.joined(separator: "\n") }
        engine = MenuEngine(store: store)
        appearance = AppearanceController(store: store)
        widgets = WidgetController(store: store)
        automation = AutomationController(store: store)
        hotkeys = HotkeyController(store: store, engine: engine)
        AppActions.shared.engine = engine
        AppActions.shared.onSettings = { [weak self] section in self?.showSettings(section) }
        AppActions.shared.onSearch = { [weak self] in self?.showSearch(all: true) }
        AppActions.shared.onToggle = { [weak self] in self?.toggle() }
        AppActions.shared.onCollectionSettings = { [weak self] in self?.collectionSettingsAction() }
        lastOrder = store.config.order
        installMenu()
        installStatusItem()
        statusFramesRegistration = PopupManager.shared.registerStatusFrames { [weak self] in
            guard let self else { return [] }
            return ([self.statusItem] + self.spacerItems + self.groupItems).flatMap { PopupManager.statusButtonFrames($0?.button) }
        }
        engine.ownStatusFrameProvider = { [weak self] in
            guard let button = self?.statusItem?.button, let window = button.window,
                  let top = NSScreen.screens.first?.frame.maxY else { return nil }
            let frame = window.frame
            guard frame.width > 0, frame.height > 0 else { return nil }
            return CGRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height)
        }
        engine.ownStatusFramesProvider = { [weak self] in
            var frames: [CGRect] = []
            if let frame = self?.engine.ownStatusFrameProvider?() { frames.append(frame) }
            if let frame = self?.usageMenuBar?.statusWindowFrame { frames.append(frame) }
            return frames
        }
        AppActions.shared.startCollection(engine)
        appearance.start(); widgets.start()
        ClaudeWebConnection.shared.restoreExistingSession()
        AIUsageStore.shared.start()
        usageMenuBar = AIUsageMenuBarController(store: AIUsageStore.shared, onOpenUsage: { [weak self] in self?.usageAction() })
        usageMenuBar?.start()
        store.$config.dropFirst().debounce(for: .milliseconds(250), scheduler: RunLoop.main).sink { [weak self] _ in
            guard let self, !self.stopping else { return }
            self.engine.applyVisibility(); self.appearance.update(); self.widgets.update(); self.hotkeys.update(); self.updateExtras()
            if self.lastOrder != self.store.config.order {
                self.lastOrder = self.store.config.order
                if !self.engine.consumePersistedOrder(self.lastOrder) { self.engine.applySavedOrder() }
            }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .tidyBarPresetApplied, object: store).sink { [weak self] notification in
            guard let self, !self.stopping else { return }
            guard let previous = notification.userInfo?["previousLayout"] as? LayoutPreset else { return }
            self.applyPreset(previous: previous, id: notification.userInfo?["presetID"] as? UUID)
        }.store(in: &subscriptions)
        engine.$isExpanded.removeDuplicates().sink { [weak self] expanded in
            self?.statusItem?.button?.image = NSImage(systemSymbolName: expanded ? "tray.full.fill" : "tray.2", accessibilityDescription: L10n.text("app.name"))
        }.store(in: &subscriptions)
        automation.start()
        hotkeys.update()
        updateExtras()
        installEvents()
        if !UserDefaults.standard.bool(forKey: "hasOpenedSettings") || CommandLine.arguments.contains("--settings") {
            UserDefaults.standard.set(true, forKey: "hasOpenedSettings")
            showSettings()
        }
        if CommandLine.arguments.contains("--diagnostics") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.writeDiagnostics() }
        }
        if !store.config.order.isEmpty && presetGeneration == 0 { engine.applySavedOrder() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopping = true
        PopupManager.shared.dismiss()
        if let statusFramesRegistration { PopupManager.shared.unregisterStatusFrames(statusFramesRegistration) }
        statusFramesRegistration = nil
        timer?.invalidate()
        eventMonitors.forEach { NSEvent.removeMonitor($0) }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        subscriptions.removeAll()
        themeController.stop()
        AIUsageStore.shared.stop()
        ClaudeWebConnection.shared.stop()
        GrokBuildConnection.shared.stop()
        usageMenuBar?.stop()
        automation?.stop(); hotkeys?.stop(); widgets?.stop(); appearance?.stop(); engine?.stop()
    }

    private func applyPreset(previous: LayoutPreset, id: UUID?) {
        presetGeneration += 1
        let generation = presetGeneration
        let previousIsPending = pendingPresetTarget.map {
            $0.rules == previous.rules && $0.order == previous.order && $0.style == previous.style
        } ?? false
        let baseline = previousIsPending ? (presetBaseline ?? previous) : previous
        presetBaseline = baseline
        let target = store.config
        pendingPresetTarget = LayoutPreset(name: L10n.text("menu.applying"), rules: target.rules, order: target.order, style: target.style)
        lastOrder = target.order
        engine.applyVisibility()
        engine.applySavedOrder { [weak self] result in
            guard let self, !self.stopping, generation == self.presetGeneration else { return }
            self.presetBaseline = nil
            self.pendingPresetTarget = nil
            guard case .failure(let error) = result else { return }
            if let id { self.automation.presetApplicationFailed(id: id, message: error.localizedDescription) }
            // A newer manual edit owns the layout and must not be overwritten by an old failure.
            guard self.store.config.rules == target.rules, self.store.config.order == target.order,
                  self.store.config.style == target.style else { return }
            var restored = self.store.config
            restored.rules = baseline.rules
            restored.order = baseline.order
            restored.style = baseline.style
            self.lastOrder = baseline.order
            self.store.config = restored
            self.engine.applyVisibility()
            self.appearance.update()
            self.engine.lastError = L10n.text("menu.the.preset.could.not.be.fully.applied") + error.localizedDescription
            self.engine.applySavedOrder()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSettings(); return true }

    private func installMenu() {
        let menu = NSMenu()
        let application = NSMenuItem()
        let submenu = NSMenu()
        submenu.addItem(withTitle: L10n.text("menu.about.ai.subgauge"), action: #selector(about), keyEquivalent: "")
        submenu.addItem(.separator())
        submenu.addItem(withTitle: L10n.text("menu.settings"), action: #selector(settingsAction), keyEquivalent: ",")
        submenu.addItem(withTitle: L10n.text("menu.search.icons"), action: #selector(searchAction), keyEquivalent: "f")
        submenu.addItem(withTitle: L10n.text("menu.ai.usage"), action: #selector(usageAction), keyEquivalent: "")
        submenu.addItem(.separator())
        submenu.addItem(withTitle: L10n.text("menu.hide.ai.subgauge"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        submenu.addItem(withTitle: L10n.text("menu.quit"), action: #selector(quit), keyEquivalent: "q")
        submenu.items.filter { $0.action != #selector(NSApplication.hide(_:)) }.forEach { $0.target = self }
        application.submenu = submenu; menu.addItem(application)
        let edit = NSMenuItem(); edit.title = L10n.text("menu.edit")
        let editMenu = NSMenu(title: L10n.text("menu.edit"))
        for (title, selector, key) in [(L10n.text("menu.undo"), "undo:", "z"), (L10n.text("menu.cut"), "cut:", "x"), (L10n.text("menu.copy"), "copy:", "c"), (L10n.text("menu.paste"), "paste:", "v"), (L10n.text("menu.select.all"), "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
        }
        edit.submenu = editMenu; menu.addItem(edit); NSApp.mainMenu = menu
    }

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "com.mike.aisubgauge.main"
        statusItem.button?.image = NSImage(systemSymbolName: "tray.2", accessibilityDescription: L10n.text("app.name"))
        statusItem.button?.toolTip = L10n.text("menu.ai.subgauge.click.to.expand.right.click")
        statusItem.button?.setAccessibilityIdentifier("com.mike.aisubgauge.main")
        statusItem.button?.target = self; statusItem.button?.action = #selector(statusClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc func statusClicked(_ button: NSButton) {
        PopupManager.shared.recordStatusItemAction()
        let event = StatusItemApplication.actionEvent
        guard PopupManager.shared.consume(event) else { return }
        lastInteraction = Date()
        if event?.type == .rightMouseUp {
            PopupManager.shared.dismiss()
            let menu = contextMenu(); statusItem.menu = menu; statusItem.button?.performClick(nil); statusItem.menu = nil
        } else if event?.modifierFlags.contains(.option) == true { showSearch(all: true, anchor: button) }
        else { toggle(anchor: button) }
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu(title: L10n.text("app.name")); menu.delegate = self
        add(menu, L10n.text("menu.open.collection.bar"), #selector(searchHiddenAction))
        add(menu, L10n.text("menu.search.all.icons"), #selector(searchAction))
        add(menu, engine.isExpanded ? L10n.text("menu.collapse.menu.bar") : L10n.text("menu.expand.menu.bar"), #selector(expandAction))
        add(menu, L10n.text("menu.temporarily.show.all.including.always.hidden"), #selector(showAllAction))
        add(menu, L10n.text("menu.ai.usage"), #selector(usageAction))
        if !store.config.presets.isEmpty {
            let item = NSMenuItem(title: L10n.text("menu.apply.preset"), action: nil, keyEquivalent: "")
            let presets = NSMenu()
            for preset in store.config.presets {
                let row = NSMenuItem(title: preset.name, action: #selector(presetAction(_:)), keyEquivalent: ""); row.target = self; row.representedObject = preset.id.uuidString
                presets.addItem(row)
            }
            item.submenu = presets; menu.addItem(item)
        }
        menu.addItem(.separator())
        add(menu, L10n.text("menu.settings"), #selector(collectionSettingsAction), key: ",")
        add(menu, L10n.text("menu.about.ai.subgauge"), #selector(about))
        add(menu, L10n.text("menu.quit.and.restore.all.icons"), #selector(quit), key: "q")
        return menu
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; menu.addItem(item)
    }
    func menuWillOpen(_ menu: NSMenu) { menuDepth += 1 }
    func menuDidClose(_ menu: NSMenu) { menuDepth = max(0, menuDepth - 1); lastInteraction = Date() }
    @objc private func settingsAction() { showSettings() }
    @objc private func usageAction() {
        showSettings(.subscriptions)
    }
    @objc private func collectionSettingsAction() {
        showSettings(.bar)
    }
    @objc private func searchAction() { showSearch(all: true) }
    @objc private func searchHiddenAction() { showSearch(all: false) }
    @objc private func expandAction() { engine.toggle(); lastInteraction = Date() }
    @objc private func showAllAction() { engine.showAll(); lastInteraction = Date() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func presetAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let preset = store.config.presets.first(where: { $0.id.uuidString == id }) else { return }
        store.applyPreset(preset)
    }
    @objc private func about() {
        let alert = NSAlert()
        alert.messageText = L10n.text("app.name")
        alert.informativeText = L10n.text("menu.ai.subgauge.1.2.0.all.features", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? AppIdentifiers.version)
        alert.addButton(withTitle: L10n.text("common.ok"))
        alert.runModal()
    }

    private func showSettings(_ section: SettingsSection = .subscriptions) {
        if settingsController == nil {
            guard let store, let engine else { return }
            settingsController = SettingsWindowController(store: store, engine: engine)
        }
        settingsController?.show(section)
        engine?.refresh()
    }

    private func toggle(anchor: NSView? = nil) {
        lastInteraction = Date()
        guard engine.requireCollectionAccessibility() else { return }
        if store.config.useFloatingBar { showSearch(all: false, anchor: anchor) }
        else { PopupManager.shared.dismiss(); engine.toggle() }
    }

    private func showSearch(all: Bool, group: String? = nil, toggle: Bool = true, anchor: NSView? = nil) {
        guard engine.requireCollectionAccessibility() else { return }
        engine.refresh()
        PopupManager.shared.present(all ? .search : .drawer, anchor: anchor ?? statusItem?.button, toggle: toggle) { panel in
            let mode = AppTheme.resolve(preference: UserDefaults.standard.string(forKey: AppTheme.preferenceKey),
                systemDark: NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
            panel.appearance = NSAppearance(named: mode == .dark ? .darkAqua : .aqua)
            panel.contentView = StandaloneWindow.hostingView(SearchContent(store: store, engine: engine, showAll: all, group: group,
                dismiss: { PopupManager.shared.dismiss() }).environment(\.appTheme, mode)
                .environment(\.colorScheme, mode.colorScheme).environment(\.locale, L10n.locale))
            let mouse = NSEvent.mouseLocation
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
                let width = min(480, screen.visibleFrame.width - 24)
                panel.setContentSize(NSSize(width: width, height: min(400, screen.visibleFrame.height - 60)))
                panel.setFrameTopLeftPoint(NSPoint(x: min(screen.visibleFrame.maxX - width - 12,
                    max(screen.visibleFrame.minX + 12, mouse.x - width / 2)), y: screen.visibleFrame.maxY - 10))
            }
        }
        lastInteraction = Date()
    }

    private func updateExtras() {
        let names = Set(store.config.rules.values.map(\.group).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }).sorted()
        let signature = "\(names)|\(store.config.spacerWidths)"
        guard signature != extrasSignature else { return }
        extrasSignature = signature
        spacerItems.forEach { NSStatusBar.system.removeStatusItem($0) }; spacerItems.removeAll()
        groupItems.forEach { NSStatusBar.system.removeStatusItem($0) }; groupItems.removeAll()
        for (index, width) in store.config.spacerWidths.enumerated() {
            let item = NSStatusBar.system.statusItem(withLength: width)
            item.autosaveName = "com.mike.aisubgauge.spacer.\(index)"
            item.button?.setAccessibilityIdentifier("com.mike.aisubgauge.spacer.\(index)")
            item.button?.title = "│"; item.button?.contentTintColor = .tertiaryLabelColor
            item.button?.toolTip = L10n.text("menu.spacer.hold.to.drag.its.position")
            item.button?.target = self; item.button?.action = #selector(spacerClicked(_:))
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            spacerItems.append(item)
        }
        for name in names {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "com.mike.aisubgauge.group.\(name)"
            item.button?.setAccessibilityIdentifier("com.mike.aisubgauge.group.\(name)")
            item.button?.title = name; item.button?.toolTip = L10n.text("menu.open.0.group", name)
            item.button?.target = self; item.button?.action = #selector(groupClicked(_:))
            item.button?.sendAction(on: [.leftMouseUp])
            groupItems.append(item)
        }
    }
    @objc private func groupClicked(_ sender: NSStatusBarButton) {
        PopupManager.shared.recordStatusItemAction()
        guard PopupManager.shared.consume(StatusItemApplication.actionEvent) else { return }
        showSearch(all: true, group: sender.title, anchor: sender)
    }

    @objc private func spacerClicked(_ sender: NSStatusBarButton) {
        PopupManager.shared.recordStatusItemAction()
    }

    private func installEvents() {
        for (name, delta) in [(NSMenu.didBeginTrackingNotification, 1), (NSMenu.didEndTrackingNotification, -1)] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }; self.menuDepth = max(0, self.menuDepth + delta); self.lastInteraction = Date()
                }
            })
        }
        let mask: NSEvent.EventTypeMask = [.scrollWheel, .leftMouseUp, .rightMouseUp, .keyDown]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in self?.handleEvent(event, source: .global) }) { eventMonitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in self?.handleEvent(event, source: .local); return event }) { eventMonitors.append(monitor) }
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        timer?.tolerance = 0.08
    }

    private func handleEvent(_ event: NSEvent, source: PopupManager.EventSource) {
        if event.type != .scrollWheel { lastInteraction = Date() }
        let point = PopupManager.screenPoint(event)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
              point.y >= screen.frame.maxY - max(25, screen.safeAreaInsets.top), point.x > screen.frame.midX else { return }
        if event.type == .scrollWheel, store.config.revealOnScroll, abs(event.scrollingDeltaY) > 1 { if event.scrollingDeltaY > 0 {
            if store.config.useFloatingBar { showSearch(all: false, toggle: false) } else if !engine.isExpanded { engine.toggle() }
        } else { engine.collapse(); closeCollectionPanel() } }
        if event.type == .leftMouseUp, store.config.revealOnEmptyClick {
            let primaryTop = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
            let cg = CGPoint(x: point.x, y: primaryTop - point.y)
            // Our buttons use live registered frames rather than the scanner's last snapshot.
            let ownBundle = Bundle.main.bundleIdentifier ?? AppIdentifiers.bundleID
            let onItem = engine.items.contains { $0.bundleID != ownBundle && $0.frame.insetBy(dx: -3, dy: -3).contains(cg) }
            PopupManager.shared.handleEmptyClick(event, at: point, onScannedItem: onItem, source: source) { [weak self] in
                guard let self, !self.stopping, self.store.config.revealOnEmptyClick else { return }
                self.toggle()
            }
        }
    }

    private func closeCollectionPanel() {
        if searchPanel != nil { PopupManager.shared.dismiss() }
    }

    private func tick() {
        let point = NSEvent.mouseLocation
        let onBar = NSScreen.screens.contains { $0.frame.contains(point) && point.y >= $0.frame.maxY - max(25, $0.safeAreaInsets.top) && point.x > $0.frame.midX }
        let overPanel = searchPanel.map { $0.isVisible && $0.frame.contains(point) } ?? false
        if onBar || overPanel { lastInteraction = Date() }
        if store.config.revealOnHover && onBar {
            let manager = PopupManager.shared
            if hoverReveal.update(point: point, statusFrames: manager.statusFrames(), popupKind: manager.kind,
                                  lastStatusActionTime: manager.lastStatusActionTime,
                                  now: ProcessInfo.processInfo.systemUptime, menuDepth: menuDepth) {
                if store.config.useFloatingBar { showSearch(all: false, toggle: false) } else if !engine.isExpanded { engine.toggle() }
            }
        } else { hoverReveal = HoverReveal() }
        let delay = store.config.autoHideDelay
        if delay > 0, Date().timeIntervalSince(lastInteraction) > delay, !engine.isBusy, menuDepth == 0 {
            closeCollectionPanel()
            if engine.isExpanded { engine.collapse() }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "macshouna" {
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            switch url.host {
            case "focus": automation?.setFocus(query.first { $0.name == "name" }?.value)
            case "preset":
                let name = query.first { $0.name == "name" }?.value
                let id = query.first { $0.name == "id" }?.value
                if let preset = store?.config.presets.first(where: { $0.name == name || $0.id.uuidString == id }) { store.applyPreset(preset) }
            case "search": showSearch(all: true)
            case "toggle": toggle()
            case "show": engine?.showAll(); lastInteraction = Date()
            case "hide": engine?.collapse(); closeCollectionPanel()
            case "settings": showSettings()
            case "usage": usageAction()
            case "diagnostics": writeDiagnostics()
            default: break
            }
        }
    }

    private func writeDiagnostics() {
        DiagnosticsPreview.shared.show(snapshots: AIUsageStore.shared.snapshots)
    }

    nonisolated static func diagnosticsData(_ output: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: DiagnosticsRedactor.value(output), options: [.prettyPrinted, .sortedKeys])
    }

}
