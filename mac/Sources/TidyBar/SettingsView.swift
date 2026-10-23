import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var engine: MenuEngine
    @ObservedObject var navigation: SettingsNavigation
    var section: SettingsSection {
        get { navigation.section }
        nonmutating set { navigation.section = newValue }
    }
    var usageStore: AIUsageStore = .shared
    var approximateGlass = false
    @State private var addingSubscription = false
    @AppStorage("Language") private var language = "system"
    @AppStorage(AppTheme.preferenceKey) private var themePreference = "system"
    @Environment(\.appTheme) private var themeMode
    private var theme: ThemePalette { ThemeCatalog.shared.palette(themeMode) }
    @State private var search = ""
    @State private var targetedZone: ItemZone?
    @State private var targetedEntryID: String?
    @State private var presetName = ""
    @State private var loginStatus = LoginItemService.main.status()
    @Environment(\.scenePhase) private var scenePhase

    init(store: SettingsStore, engine: MenuEngine? = nil, section: SettingsSection = .subscriptions,
         usageStore: AIUsageStore? = nil, approximateGlass: Bool = false, navigation: SettingsNavigation? = nil) {
        self.store = store
        self.engine = engine ?? MenuEngine(store: store)
        self.navigation = navigation ?? SettingsNavigation(section: section)
        self.usageStore = usageStore ?? .shared
        self.approximateGlass = approximateGlass
    }

    var body: some View {
        SettingsChrome(section: $navigation.section, approximateGlass: approximateGlass) {
            VStack(alignment: .leading, spacing: 0) {
                if let error = store.error { message(error, symbol: "exclamationmark.triangle.fill", color: theme.color(\.error)) }
                if section == .layout || section == .bar, let error = engine.lastError {
                    message(error, symbol: "exclamationmark.triangle.fill", color: theme.color(\.error))
                }
                selectedContent
                    .modifier(SettingsControlStyle(approximate: approximateGlass))
            }
        }
        .overlay {
            if addingSubscription {
                Color.black.opacity(0.12).clipShape(RoundedRectangle(cornerRadius: 26)).allowsHitTesting(false)
            }
        }
        .scrollContentBackground(.hidden)
        .onAppear { if !approximateGlass { refreshLoginStatus() } }
        .onChange(of: scenePhase) { _, phase in if phase == .active && !approximateGlass { refreshLoginStatus() } }
    }

    @ViewBuilder private var selectedContent: some View {
        switch section {
        case .subscriptions: SettingsSubscriptionsView(store: usageStore, adding: $addingSubscription, approximateGlass: approximateGlass)
        case .layout: layoutPage
        case .bar: barPage
        case .panel: ScrollView { SettingsDisplayPreferences(approximateGlass: approximateGlass) }
        case .addons: SettingsAddonsView { section = $0 }
        case .appearance: AppearanceSettingsView(store: store)
        case .presets: presetsPage
        case .automation: AutomationSettingsView(store: store)
        case .widgets: WidgetSettingsView(store: store)
        case .hotkeys: HotkeySettingsView(store: store)
        case .general: generalPage
        }
    }

    private func message(_ text: String, symbol: String, color: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.callout).foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12).background(color.opacity(0.08))
            .textSelection(.enabled)
    }

    private var filteredItems: [MenuEntry] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return engine.items.filter {
            needle.isEmpty || $0.name.localizedCaseInsensitiveContains(needle)
                || $0.title.localizedCaseInsensitiveContains(needle)
                || $0.bundleID.localizedCaseInsensitiveContains(needle)
                || (store.config.rules[$0.bundleID]?.group.localizedCaseInsensitiveContains(needle) ?? false)
        }
    }

    private var layoutPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SettingsGroup {
                    TextField(L10n.text("settings.search.apps.icons.or.groups"), text: $search).textFieldStyle(.roundedBorder)
                    HStack {
                        Button { engine.refresh() } label: { Label(L10n.text("settings.refresh"), systemImage: "arrow.clockwise") }.disabled(engine.isBusy)
                        Spacer(minLength: 0)
                        Button(engine.isExpanded ? L10n.text("settings.collapse") : L10n.text("settings.expand")) { engine.toggle() }
                        Button(L10n.text("settings.show.all")) { engine.showAll() }
                    }
                }
                SettingsGroup(title: L10n.text("settings.icon.order")) {
                    Button(L10n.text("settings.menu.bar.position.access")) { engine.openMenuBarAccess() }.disabled(engine.isBusy)
                    Button(L10n.text("settings.restore.latest.position.backup")) { engine.restoreLastLayoutBackup() }.disabled(engine.isBusy)
                    if !engine.menuBarAccessGranted {
                        Text(L10n.text("settings.before.reordering.icons.click.menu.bar.position")).foregroundStyle(.secondary)
                    }
                }
                if !engine.accessibilityGranted || !engine.available {
                    SettingsGroup(title: L10n.text("settings.permissions.and.system.support")) {
                        Text(L10n.text("settings.identifying.and.clicking.icons.requires.accessibility.access")).foregroundStyle(.secondary)
                        Button(L10n.text("settings.allow.accessibility.access")) { engine.requestAccessibility() }
                    }
                }
                if !engine.status.isEmpty { Text(engine.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                Text(L10n.text("settings.multiple.icons.from.one.app.are.collected")).font(.caption).foregroundStyle(.secondary)
                ForEach(ItemZone.allCases) { zoneSection($0) }
            }.padding(.bottom, 2)
        }
    }

    private func zoneSection(_ zone: ItemZone) -> some View {
        let entries = filteredItems.filter { (store.config.rules[$0.bundleID]?.zone ?? .visible) == zone }
        return SettingsGroup {
            HStack {
                Image(systemName: zone == .visible ? "eye" : zone == .hidden ? "tray" : "eye.slash")
                Text(zone.title).font(.headline)
                    .accessibilityIdentifier("menu-zone.\(zone.rawValue)")
                    .accessibilityHint(L10n.text("settings.drag.an.icon.s.handle.to.this", zone.title))
                Text("\(entries.count)").font(.caption).foregroundStyle(theme.color(\.textSecondary))
                Spacer()
            }
            if entries.isEmpty {
                Text(search.isEmpty ? L10n.text("settings.no.icons.yet") : L10n.text("settings.no.matching.icons"))
                    .font(.callout).foregroundStyle(theme.color(\.textSecondary))
                    .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.color(\.surface), in: RoundedRectangle(cornerRadius: 10))
            } else {
                VStack(spacing: 0) {
                    ForEach(entries) { entry in
                        itemRow(entry)
                        if entry.id != entries.last?.id { Divider().padding(.leading, 74) }
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(targetedZone == zone ? Color.accentColor : .clear, lineWidth: 2)
                .allowsHitTesting(false)
        }
        .dropDestination(for: String.self) { identifiers, _ in
            acceptZoneDrop(identifiers, zone: zone)
        } isTargeted: { targeted in
            if targeted { targetedZone = zone }
            else if targetedZone == zone { targetedZone = nil }
        }
    }

    private func itemRow(_ entry: MenuEntry) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
                    .contentShape(Rectangle()).draggable(entry.id) { Text(entry.name).padding(8) }
                    .accessibilityIdentifier("menu-item.drag.\(entry.id)")
                    .accessibilityLabel(L10n.text("settings.drag.handle.for.0", entry.name))
                Group {
                    if let icon = entry.icon { Image(nsImage: icon).resizable().scaledToFit() }
                    else { Image(systemName: "app.dashed").resizable().scaledToFit() }
                }.frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if isSystemFixed(entry.bundleID) {
                        Text(entry.bundleID == "com.mike.aisubgauge" ? L10n.text("settings.collection.entry.stays.visible") : L10n.text("settings.system.item.stays.visible"))
                            .font(.caption).foregroundStyle(.secondary)
                    } else if !entry.title.isEmpty && entry.title != entry.name {
                        Text(entry.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Picker(L10n.text("settings.visibility"), selection: Binding(
                    get: { store.config.rules[entry.bundleID]?.zone ?? .visible },
                    set: { engine.setZone($0, for: entry.bundleID) }
                )) { ForEach(ItemZone.allCases) { Text($0.title).tag($0) } }
                    .labelsHidden().frame(maxWidth: 160).disabled(isSystemFixed(entry.bundleID))
                    .accessibilityIdentifier("menu-item.zone.\(entry.id)")
                    .accessibilityLabel(L10n.text("settings.visibility.of.0", entry.name))
                Spacer(minLength: 0)
                Button { engine.moveInList(entry, offset: -1) } label: { Image(systemName: "arrow.left") }
                    .disabled(!entry.canMove || engine.isBusy).accessibilityIdentifier("menu-item.move-left.\(entry.id)")
                    .accessibilityLabel(L10n.text("settings.move.0.left", entry.name))
                Button { engine.moveInList(entry, offset: 1) } label: { Image(systemName: "arrow.right") }
                    .disabled(!entry.canMove || engine.isBusy).accessibilityIdentifier("menu-item.move-right.\(entry.id)")
                    .accessibilityLabel(L10n.text("settings.move.0.right", entry.name))
                Button(L10n.text("settings.open")) { engine.activate(entry) }.disabled(!entry.isRunning)
                    .accessibilityIdentifier("menu-item.open.\(entry.id)")
            }.controlSize(.small)
            TextField(L10n.text("settings.group.name.optional"), text: itemBinding(entry.bundleID, \.group, default: ""))
                .textFieldStyle(.roundedBorder).accessibilityIdentifier("menu-item.group.\(entry.id)")
            Toggle(L10n.text("settings.show.when.app.is.active"), isOn: itemBinding(entry.bundleID, \.showWhenActive, default: false))
                .font(.caption).accessibilityIdentifier("menu-item.active.\(entry.id)")
        }.padding(.vertical, 10)
        .contentShape(Rectangle())
        .background(targetedEntryID == entry.id ? Color.accentColor.opacity(0.08) : .clear)
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(targetedEntryID == entry.id ? Color.accentColor : .clear, lineWidth: 2)
                .allowsHitTesting(false)
        }
        .dropDestination(for: String.self) { identifiers, _ in
            acceptItemDrop(identifiers, before: entry.id)
        } isTargeted: { targeted in
            if targeted { targetedEntryID = entry.id }
            else if targetedEntryID == entry.id { targetedEntryID = nil }
        }
    }

    private func draggedEntry(_ identifiers: [String]) -> MenuEntry? {
        guard !engine.isBusy, identifiers.count == 1 else { return nil }
        return engine.items.first { $0.id == identifiers[0] && $0.isRunning }
    }

    private func canDrop(_ entry: MenuEntry, into zone: ItemZone) -> Bool {
        guard !isSystemFixed(entry.bundleID) || zone == .visible else {
            engine.lastError = L10n.text("settings.system.icons.and.the.collection.entry.must")
            return false
        }
        return true
    }

    private func acceptZoneDrop(_ identifiers: [String], zone: ItemZone) -> Bool {
        guard let source = draggedEntry(identifiers), canDrop(source, into: zone) else { return false }
        engine.setZone(zone, for: source.bundleID)
        return true
    }

    private func acceptItemDrop(_ identifiers: [String], before targetID: String) -> Bool {
        guard let source = draggedEntry(identifiers), source.id != targetID,
              let target = engine.items.first(where: { $0.id == targetID && $0.isRunning }) else { return false }
        let zone = store.config.rules[target.bundleID]?.zone ?? .visible
        guard canDrop(source, into: zone) else { return false }
        if (store.config.rules[source.bundleID]?.zone ?? .visible) != zone {
            engine.setZone(zone, for: source.bundleID)
        }
        engine.move(source, before: target)
        return true
    }

    private func isSystemFixed(_ bundleID: String) -> Bool {
        ["com.apple.MenuBarAgent", "com.apple.systemuiserver", "com.apple.controlcenter", "com.mike.aisubgauge"].contains(bundleID)
    }

    private func itemBinding<T>(_ key: String, _ path: WritableKeyPath<ItemRule, T>, default fallback: T) -> Binding<T> {
        Binding(get: { store.config.rules[key]?[keyPath: path] ?? fallback }, set: { value in
            var rule = store.config.rules[key] ?? ItemRule()
            rule[keyPath: path] = value
            store.config.rules[key] = rule
        })
    }

    private var barPage: some View {
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            if !engine.accessibilityGranted {
                SettingsGroup {
                    Text(CollectionAccess.message).fixedSize(horizontal: false, vertical: true)
                    Button(L10n.text("settings.allow.accessibility.access")) { engine.requestAccessibility() }
                }
            }
            SettingsGroup(title: L10n.text("settings.expansion")) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(L10n.text("settings.use.a.separate.collection.bar"), isOn: $store.config.useFloatingBar)
                    Text(L10n.text("settings.when.enabled.collected.icons.appear.below.the"))
                        .font(.caption).foregroundStyle(theme.color(\.textSecondary))
                }
                Toggle(L10n.text("settings.show.icon.names"), isOn: $store.config.showLabels)
                Toggle(L10n.text("settings.expand.on.hover"), isOn: $store.config.revealOnHover)
                Toggle(L10n.text("settings.expand.when.scrolling.in.the.menu.bar"), isOn: $store.config.revealOnScroll)
                Toggle(L10n.text("settings.expand.when.clicking.an.empty.menu.bar"), isOn: $store.config.revealOnEmptyClick)
            }
            SettingsGroup(title: L10n.text("settings.auto.collapse")) {
                HStack {
                    Text(L10n.text("settings.delay"))
                    Spacer()
                    Text(store.config.autoHideDelay == 0 ? L10n.text("settings.keep.expanded") : L10n.text("settings.0.seconds", Int(store.config.autoHideDelay)))
                        .monospacedDigit().foregroundStyle(theme.color(\.textSecondary))
                }
                Slider(value: $store.config.autoHideDelay, in: 0...120, step: 1)
                Text(L10n.text("settings.set.to.0.to.keep.expanded.collapse"))
                    .font(.caption).foregroundStyle(theme.color(\.textSecondary))
            }
            SettingsGroup(title: L10n.text("settings.spacers")) {
                ForEach(store.config.spacerWidths.indices, id: \.self) { index in
                    HStack {
                        Text(L10n.text("settings.spacer.0", index + 1))
                        Slider(value: $store.config.spacerWidths[index], in: 4...160, step: 2)
                        Text(L10n.text("settings.0.pt", Int(store.config.spacerWidths[index]))).monospacedDigit().frame(width: 58)
                        Button(L10n.text("settings.delete")) { store.config.spacerWidths.remove(at: index) }
                    }
                }
                Button(L10n.text("settings.add.spacer")) { store.config.spacerWidths.append(24) }
                    .disabled(store.config.spacerWidths.count >= 20)
                Text(L10n.text("settings.spacers.appear.as.separate.menu.bar.placeholders"))
                    .font(.caption).foregroundStyle(theme.color(\.textSecondary))
            }
          }.padding(.bottom, 2)
        }
    }

    private var presetsPage: some View {
        SettingsPage {
            SettingsGroup {
                TextField(L10n.text("settings.preset.name.e.g.focused.work"), text: $presetName).textFieldStyle(.roundedBorder)
                Button(L10n.text("settings.save.current.layout")) {
                    let previous = store.config.presets.count
                    store.savePreset(name: presetName, order: engine.captureCurrentOrder())
                    if store.config.presets.count > previous && store.error == nil { presetName = "" }
                }.disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text(L10n.text("settings.presets.save.icon.zones.order.groups.and"))
                    .font(.caption).foregroundStyle(theme.color(\.textSecondary))
            }
            if store.config.presets.isEmpty {
                SettingsGroup {
                    ContentUnavailableView(L10n.text("settings.no.presets.saved.yet"), systemImage: "square.stack.3d.up", description: Text(L10n.text("settings.organize.icons.in.menu.bar.layout.then")))
                }
            } else {
                ForEach(store.config.presets) { preset in
                    SettingsGroup {
                        HStack(spacing: 10) {
                            Image(systemName: "square.stack.3d.up.fill").foregroundStyle(theme.color(\.accent))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(preset.name).font(.headline)
                                Text(L10n.text("settings.0.app.settings.1.order.records", preset.rules.count, preset.order.count))
                                    .font(.caption).foregroundStyle(theme.color(\.textSecondary))
                            }
                            Spacer()
                        }
                        HStack {
                            Button(L10n.text("settings.apply")) { store.applyPreset(preset) }
                            Button(L10n.text("settings.delete"), role: .destructive) { store.deletePreset(preset.id) }
                        }
                    }
                }
            }
        }
    }

    private var generalPage: some View {
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            SettingsGroup(title: L10n.text("settings.language")) {
                Picker(L10n.text("settings.language"), selection: $language) {
                    Text(L10n.text("settings.language.system")).tag("system")
                    Text(L10n.text("settings.language.en")).tag("en")
                    Text(L10n.text("settings.language.zhHans")).tag("zh-Hans")
                }
                Text(L10n.text("settings.language.restart")).font(.caption).foregroundStyle(theme.color(\.textSecondary))
            }
            SettingsGroup(title: L10n.text("settings.theme")) {
                Picker(L10n.text("settings.theme"), selection: $themePreference) {
                    Text(L10n.text("settings.theme.system")).tag("system")
                    Text(L10n.text("settings.theme.light")).tag("light")
                    Text(L10n.text("settings.theme.dark")).tag("dark")
                }
            }
            SettingsGroup(title: L10n.text("settings.startup")) {
                Toggle(L10n.text("settings.launch.at.login"), isOn: Binding(get: { loginStatus == .enabled }, set: setLoginEnabled))
                if loginStatus == .requiresApproval {
                    Text(L10n.text("settings.the.login.item.needs.system.approval.allow"))
                        .font(.caption).foregroundStyle(theme.color(\.demo))
                    Button(L10n.text("settings.open.login.items.settings")) { SMAppService.openSystemSettingsLoginItems() }
                }
                Text(L10n.text("settings.the.app.keeps.running.in.the.menu"))
                    .font(.caption).foregroundStyle(theme.color(\.textSecondary))
            }
            SettingsGroup { ProviderLoginConsentView() }
            SettingsGroup(title: L10n.text("settings.diagnostics")) {
                Button(L10n.text("menu.diagnostics")) { DiagnosticsPreview.shared.show(snapshots: AIUsageStore.shared.snapshots) }
            }
            SettingsGroup(title: L10n.text("settings.settings.file")) {
                HStack {
                    Button(L10n.text("settings.export.settings.653")) { store.exportSettings() }
                    Button(L10n.text("settings.import.settings.654")) { store.importSettings(); refreshLoginStatus() }
                    Button(L10n.text("settings.show.in.finder")) { NSWorkspace.shared.activateFileViewerSelecting([store.url]) }
                }
                Text(L10n.text("settings.file.format.and.values.are.checked.before"))
                    .font(.caption).foregroundStyle(theme.color(\.textSecondary))
                Button(L10n.text("settings.save.settings.again")) { store.save() }
            }
            SettingsGroup(title: L10n.text("settings.about")) {
                LabeledContent(L10n.text("settings.name"), value: L10n.text("app.name"))
                LabeledContent(L10n.text("settings.english.name"), value: L10n.text("app.name"))
                LabeledContent(L10n.text("settings.version"), value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? AppIdentifiers.version)
                Text(L10n.text("settings.all.features.are.available.without.an.activation"))
                    .font(.caption).foregroundStyle(theme.color(\.textSecondary))
            }
          }.padding(.bottom, 2)
        }
    }

    private func refreshLoginStatus() {
        loginStatus = LoginItemService.main.status()
        let actual = loginStatus == .enabled
        if store.config.launchAtLogin != actual { store.config.launchAtLogin = actual }
    }

    private func setLoginEnabled(_ enabled: Bool) {
        do {
            try LoginItemService.main.setEnabled(enabled)
            refreshLoginStatus()
        } catch {
            refreshLoginStatus()
            store.error = L10n.text("settings.could.not.change.the.login.item.0", error.localizedDescription)
        }
    }
}
