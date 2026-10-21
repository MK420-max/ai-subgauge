import AppKit
import Combine
import SwiftUI

@MainActor
final class AppActions {
    static let shared = AppActions()
    weak var engine: MenuEngine?
    var onSettings: (() -> Void)?
    var onSearch: (() -> Void)?
    var onToggle: (() -> Void)?
    func showSettings() { onSettings?() }
    func showSearch() { onSearch?() }
    func toggle() { onToggle?() }
}

@main
struct TidyBarMain {
    @MainActor static func main() {
        do {
            try L10n.configure(arguments: CommandLine.arguments)
            if let directory = try PreviewRenderer.directory(arguments: CommandLine.arguments) {
                try PreviewRenderer.render(to: directory, theme: PreviewRenderer.theme(arguments: CommandLine.arguments))
                return
            }
        } catch {
            fputs(L10n.text("menu.ai.subgauge.development.preview.failed"), stderr)
            exit(1)
        }
        let app = NSApplication.shared
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
    private var settingsWindow: NSWindow?
    private var searchPanel: SearchPanel?
    private var subscriptions = Set<AnyCancellable>()
    private var spacerItems: [NSStatusItem] = []
    private var groupItems: [NSStatusItem] = []
    private var observers: [NSObjectProtocol] = []
    private var eventMonitors: [Any] = []
    private var timer: Timer?
    private var lastInteraction = Date()
    private var hoverStarted: Date?
    private var wasHovering = false
    private var menuDepth = 0
    private var extrasSignature = ""
    private var stopping = false
    private var lastOrder: [String] = []
    private var presetGeneration = 0
    private var presetBaseline: LayoutPreset?
    private var pendingPresetTarget: LayoutPreset?

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
        AppActions.shared.onSettings = { [weak self] in self?.showSettings() }
        AppActions.shared.onSearch = { [weak self] in self?.showSearch(all: true) }
        AppActions.shared.onToggle = { [weak self] in self?.toggle() }
        lastOrder = store.config.order
        installMenu()
        installStatusItem()
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
        engine.start(); appearance.start(); widgets.start()
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
        engine.$isExpanded.sink { [weak self] expanded in
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
        statusItem.button?.target = self; statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func statusClicked() {
        lastInteraction = Date()
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = contextMenu(); statusItem.menu = menu; statusItem.button?.performClick(nil); statusItem.menu = nil
        } else if NSApp.currentEvent?.modifierFlags.contains(.option) == true { showSearch(all: true) }
        else { toggle() }
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
        add(menu, L10n.text("menu.settings"), #selector(settingsAction), key: ",")
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
        showSettings()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Notification.Name("tidyBarShowAIUsage"), object: nil)
        }
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
        alert.informativeText = L10n.text("menu.ai.subgauge.1.2.0.all.features")
        alert.addButton(withTitle: L10n.text("common.ok"))
        alert.runModal()
    }

    private func showSettings() {
        guard store != nil, engine != nil else { return }
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 730), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = L10n.text("app.name")
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(store: store, engine: engine).appThemed().environment(\.locale, L10n.locale))
            window.minSize = NSSize(width: 900, height: 620)
            window.center(); settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil)
        engine.refresh()
    }

    private func toggle() {
        lastInteraction = Date()
        if store.config.useFloatingBar {
            if searchPanel?.isVisible == true { searchPanel?.orderOut(nil) }
            else { showSearch(all: false) }
        } else { engine.toggle() }
    }

    private func showSearch(all: Bool, group: String? = nil) {
        engine.refresh()
        if searchPanel == nil { searchPanel = SearchPanel() }
        guard let panel = searchPanel else { return }
        panel.contentView = NSHostingView(rootView: SearchContent(store: store, engine: engine, showAll: all, group: group, dismiss: { [weak panel] in panel?.orderOut(nil) }).environment(\.locale, L10n.locale))
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let screen {
            let width = min(560, screen.visibleFrame.width - 24)
            panel.setContentSize(NSSize(width: width, height: min(480, screen.visibleFrame.height - 60)))
            panel.setFrameTopLeftPoint(NSPoint(x: min(screen.visibleFrame.maxX - width - 12, max(screen.visibleFrame.minX + 12, mouse.x - width / 2)), y: screen.visibleFrame.maxY - 10))
        }
        NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil)
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
            spacerItems.append(item)
        }
        for name in names {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "com.mike.aisubgauge.group.\(name)"
            item.button?.setAccessibilityIdentifier("com.mike.aisubgauge.group.\(name)")
            item.button?.title = name; item.button?.toolTip = L10n.text("menu.open.0.group", name)
            item.button?.target = self; item.button?.action = #selector(groupClicked(_:))
            groupItems.append(item)
        }
    }
    @objc private func groupClicked(_ sender: NSStatusBarButton) { showSearch(all: true, group: sender.title) }

    private func installEvents() {
        for (name, delta) in [(NSMenu.didBeginTrackingNotification, 1), (NSMenu.didEndTrackingNotification, -1)] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }; self.menuDepth = max(0, self.menuDepth + delta); self.lastInteraction = Date()
                }
            })
        }
        let mask: NSEvent.EventTypeMask = [.scrollWheel, .leftMouseUp, .rightMouseUp, .keyDown]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in self?.handleEvent(event) }) { eventMonitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in self?.handleEvent(event); return event }) { eventMonitors.append(monitor) }
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        timer?.tolerance = 0.08
    }

    private func handleEvent(_ event: NSEvent) {
        if event.type != .scrollWheel { lastInteraction = Date() }
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
              point.y >= screen.frame.maxY - max(25, screen.safeAreaInsets.top), point.x > screen.frame.midX else { return }
        if event.type == .scrollWheel, store.config.revealOnScroll, abs(event.scrollingDeltaY) > 1 { if event.scrollingDeltaY > 0 {
            if store.config.useFloatingBar { showSearch(all: false) } else if !engine.isExpanded { engine.toggle() }
        } else { engine.collapse(); searchPanel?.orderOut(nil) } }
        if event.type == .leftMouseUp, store.config.revealOnEmptyClick {
            let primaryTop = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
            let cg = CGPoint(x: point.x, y: primaryTop - point.y)
            let onItem = engine.items.contains { $0.frame.insetBy(dx: -3, dy: -3).contains(cg) }
            if !onItem { toggle() }
        }
    }

    private func tick() {
        let point = NSEvent.mouseLocation
        let onBar = NSScreen.screens.contains { $0.frame.contains(point) && point.y >= $0.frame.maxY - max(25, $0.safeAreaInsets.top) && point.x > $0.frame.midX }
        let overPanel = searchPanel.map { $0.isVisible && $0.frame.contains(point) } ?? false
        if onBar || overPanel { lastInteraction = Date() }
        if store.config.revealOnHover && onBar {
            if hoverStarted == nil { hoverStarted = Date() }
            if !wasHovering, Date().timeIntervalSince(hoverStarted!) > 0.55 {
                wasHovering = true
                if searchPanel?.isVisible != true {
                    if store.config.useFloatingBar { showSearch(all: false) } else if !engine.isExpanded { engine.toggle() }
                }
            }
        } else { hoverStarted = nil; wasHovering = false }
        let delay = store.config.autoHideDelay
        if delay > 0, Date().timeIntervalSince(lastInteraction) > delay, !engine.isBusy, menuDepth == 0 {
            searchPanel?.orderOut(nil)
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
            case "hide": engine?.collapse(); searchPanel?.orderOut(nil)
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

private final class SearchPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 560, height: 480), styleMask: [.titled, .fullSizeContentView, .closable, .utilityWindow], backing: .buffered, defer: false)
        title = L10n.text("app.name")
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false; hidesOnDeactivate = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
    }
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

private struct SearchContent: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var engine: MenuEngine
    let showAll: Bool
    var group: String?
    let dismiss: () -> Void
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool
    private var entries: [MenuEntry] {
        engine.items.filter { entry in
            let rule = store.config.rules[entry.bundleID] ?? ItemRule()
            return (showAll || rule.zone == .hidden) && (group == nil || rule.group == group)
                && (query.isEmpty || "\(entry.name) \(entry.title) \(entry.bundleID) \(rule.group)".localizedCaseInsensitiveContains(query))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(group.map { L10n.text("menu.search.0.group", $0) } ?? (showAll ? L10n.text("menu.search.all.icons.190") : L10n.text("menu.search.collected.icons")), text: $query)
                    .textFieldStyle(.plain).focused($focused).onSubmit { if !entries.isEmpty { open(entries[min(selection, entries.count - 1)]) } }
                Button { AppActions.shared.showSettings() } label: { Image(systemName: "gearshape") }.buttonStyle(.plain).help(L10n.text("menu.open.settings"))
            }.font(.title3).padding(.top, 5)
            Divider()
            if !engine.accessibilityGranted {
                HStack { Text(L10n.text("menu.allow.accessibility.access.to.identify.and.open")).font(.caption); Button(L10n.text("menu.allow.access")) { engine.requestAccessibility() } }
            }
            if let error = engine.lastError { Text(error).font(.caption).foregroundStyle(.orange) }
            if entries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray").font(.system(size: 38)).foregroundStyle(.tertiary)
                    Text(query.isEmpty ? L10n.text("menu.no.collected.icons.yet") : L10n.text("menu.no.matching.icons.found")).foregroundStyle(.secondary)
                    if query.isEmpty { Button(L10n.text("menu.open.layout.settings")) { AppActions.shared.showSettings() } }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                Button { open(entry) } label: {
                                    HStack(spacing: 12) {
                                        if let image = entry.icon { Image(nsImage: image).resizable().scaledToFit().frame(width: 26, height: 26) }
                                        else { Image(systemName: "app.dashed").frame(width: 26, height: 26) }
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(entry.name).fontWeight(.medium)
                                            if store.config.showLabels && !entry.title.isEmpty && entry.title != entry.name { Text(entry.title).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                        }
                                        Spacer()
                                        Text((store.config.rules[entry.bundleID]?.zone ?? .visible).title).font(.caption).foregroundStyle(.secondary)
                                        Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
                                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(index == selection ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
                                }.buttonStyle(.plain).id(index)
                                    .contextMenu {
                                        ForEach(ItemZone.allCases) { zone in Button(zone.title) { engine.setZone(zone, for: entry.bundleID) } }
                                    }
                            }
                        }
                    }.onChange(of: selection) { _, value in proxy.scrollTo(value) }
                }
            }
            Divider()
            HStack {
                Text(L10n.text("menu.0.icons.select.return.open.esc.close", entries.count)).font(.caption).foregroundStyle(.secondary)
                Spacer(); Button(L10n.text("common.done")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(18)
        .background {
            ZStack {
                Rectangle().fill(.regularMaterial)
                if store.config.style.enabled { BarSurface(style: store.config.style) }
            }
        }
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in selection = 0 }
        .onKeyPress(.downArrow) { selection = min(max(0, entries.count - 1), selection + 1); return .handled }
        .onKeyPress(.upArrow) { selection = max(0, selection - 1); return .handled }
    }
    private func open(_ entry: MenuEntry) { dismiss(); engine.activate(entry) }
}
