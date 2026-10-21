import AppKit
import ServiceManagement
import SwiftUI

private enum SettingsSection: String, CaseIterable, Identifiable {
    case layout, bar, appearance, presets, automation, widgets, usage, hotkeys, general
    var title: String {
        switch self {
        case .layout: return L10n.text("settings.menu.bar.layout")
        case .bar: return L10n.text("settings.collection.bar")
        case .appearance: return L10n.text("settings.appearance")
        case .presets: return L10n.text("settings.presets")
        case .automation: return L10n.text("settings.automation")
        case .widgets: return L10n.text("settings.widgets")
        case .usage: return L10n.text("settings.ai.usage")
        case .hotkeys: return L10n.text("settings.shortcuts")
        case .general: return L10n.text("settings.general")
        }
    }
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .layout: return "menubar.rectangle"
        case .bar: return "tray.full"
        case .appearance: return "paintpalette"
        case .presets: return "square.stack.3d.up"
        case .automation: return "bolt"
        case .widgets: return "square.grid.2x2"
        case .usage: return "chart.bar.fill"
        case .hotkeys: return "keyboard"
        case .general: return "gearshape"
        }
    }
    var caption: String {
        switch self {
        case .layout: return L10n.text("settings.keep.frequently.used.icons.visible.and.collect")
        case .bar: return L10n.text("settings.choose.how.to.expand.and.when.to")
        case .appearance: return L10n.text("settings.set.a.menu.bar.background.and.corners")
        case .presets: return L10n.text("settings.save.layouts.and.appearance.for.different.work")
        case .automation: return L10n.text("settings.switch.presets.automatically.by.app.time.or")
        case .widgets: return L10n.text("settings.add.a.clock.calendar.music.or.weather")
        case .usage: return L10n.text("settings.view.ai.account.quota.reset.times.and")
        case .hotkeys: return L10n.text("settings.expand.and.find.menu.bar.icons.using")
        case .general: return L10n.text("settings.manage.startup.and.settings.files")
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var engine: MenuEngine
    @State private var section: SettingsSection? = .layout
    @AppStorage("Language") private var language = "system"
    @AppStorage(AppTheme.preferenceKey) private var themePreference = "system"
    @Environment(\.appTheme) private var themeMode
    private var theme: ThemePalette { ThemeCatalog.shared.palette(themeMode) }
    @State private var search = ""
    @State private var presetName = ""
    @State private var targetedZone: ItemZone?
    @State private var targetedEntryID: String?
    @State private var loginStatus = SMAppService.mainApp.status
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 9) {
                    Image(nsImage: AppBrand.logo(themeMode))
                        .resizable().interpolation(.high).frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.text("app.name")).font(.headline)
                        Text(L10n.text("settings.make.room.in.your.menu.bar")).font(.caption).foregroundStyle(theme.color(\.textSecondary))
                    }
                }.padding(.horizontal, 16).padding(.top, 20)
                List(SettingsSection.allCases, selection: $section) { item in
                    Label(item.title, systemImage: item.icon).tag(item)
                        .padding(.vertical, 4)
                }.listStyle(.sidebar)
                HStack(spacing: 6) {
                    Circle().fill(engine.available ? ThemeCatalog.shared.quotaColor(100) : theme.color(\.demo)).frame(width: 7, height: 7)
                    Text(engine.available ? L10n.text("settings.collection.service.ready") : L10n.text("settings.permission.setup.needed"))
                        .font(.caption).foregroundStyle(theme.color(\.textSecondary))
                }.padding(.horizontal, 16).padding(.bottom, 18)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 250)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                pageHeader
                Divider()
                if let error = store.error { message(error, symbol: "exclamationmark.triangle.fill", color: theme.color(\.error)) }
                if section != .usage, let error = engine.lastError { message(error, symbol: "exclamationmark.triangle.fill", color: theme.color(\.error)) }
                selectedContent
            }
            .padding(.top, 28)
            .background(theme.color(\.background).opacity(0.75))
        }
        .frame(minWidth: 900, minHeight: 620)
        .scrollContentBackground(.hidden)
        .onAppear { refreshLoginStatus() }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("tidyBarShowAIUsage"))) { _ in section = .usage }
        .onChange(of: scenePhase) { _, phase in if phase == .active { refreshLoginStatus() } }
    }

    private var pageHeader: some View {
        let current = section ?? .layout
        return VStack(alignment: .leading, spacing: 7) {
            Text(current.title).font(.system(size: 26, weight: .bold))
            Text(current.caption).font(.callout).foregroundStyle(theme.color(\.textSecondary))
        }.padding(26)
    }

    @ViewBuilder private var selectedContent: some View {
        switch section ?? .layout {
        case .layout: layoutPage
        case .bar: barPage
        case .appearance: AppearanceSettingsView(store: store)
        case .presets: presetsPage
        case .automation: AutomationSettingsView(store: store)
        case .widgets: WidgetSettingsView(store: store)
        case .usage: AIUsageView(store: AIUsageStore.shared)
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
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                TextField(L10n.text("settings.search.apps.icons.or.groups"), text: $search)
                    .textFieldStyle(.roundedBorder)
                Button { engine.refresh() } label: { Label(L10n.text("settings.refresh"), systemImage: "arrow.clockwise") }
                    .disabled(engine.isBusy)
                Button(engine.isExpanded ? L10n.text("settings.collapse") : L10n.text("settings.expand")) { engine.toggle() }
                Button(L10n.text("settings.show.all")) { engine.showAll() }
            }
            HStack {
                Label(L10n.text("settings.icon.order"), systemImage: "arrow.left.arrow.right")
                    .font(.callout).foregroundStyle(theme.color(\.textSecondary))
                Spacer()
                Button(L10n.text("settings.menu.bar.position.access")) { engine.openMenuBarAccess() }
                    .disabled(engine.isBusy)
                Button(L10n.text("settings.restore.latest.position.backup")) { engine.restoreLastLayoutBackup() }
                    .disabled(engine.isBusy)
            }
            if !engine.menuBarAccessGranted {
                Text(L10n.text("settings.before.reordering.icons.click.menu.bar.position"))
                    .font(.caption).foregroundStyle(theme.color(\.demo))
            }
            if !engine.accessibilityGranted || !engine.available {
                VStack(alignment: .leading, spacing: 9) {
                    Label(L10n.text("settings.permissions.and.system.support"), systemImage: "hand.raised.fill").font(.headline)
                    Text(L10n.text("settings.identifying.and.clicking.icons.requires.accessibility.access"))
                        .font(.callout).foregroundStyle(theme.color(\.textSecondary))
                    HStack {
                        Button(L10n.text("settings.allow.accessibility.access")) { engine.requestAccessibility() }
                    }
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.color(\.demo).opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
            if !engine.status.isEmpty {
                Text(engine.status).font(.caption).foregroundStyle(theme.color(\.textSecondary)).textSelection(.enabled)
            }
            Text(L10n.text("settings.multiple.icons.from.one.app.are.collected"))
                .font(.caption).foregroundStyle(theme.color(\.textSecondary))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(ItemZone.allCases) { zone in
                        zoneSection(zone)
                    }
                }
            }
        }.padding(22)
    }

    private func zoneSection(_ zone: ItemZone) -> some View {
        let entries = filteredItems.filter { (store.config.rules[$0.bundleID]?.zone ?? .visible) == zone }
        return VStack(alignment: .leading, spacing: 9) {
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
                }.background(theme.color(\.surface), in: RoundedRectangle(cornerRadius: 10))
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
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.caption).foregroundStyle(theme.color(\.textSecondary))
                .frame(width: 14, height: 28)
                .contentShape(Rectangle())
                .draggable(entry.id) {
                    Label(entry.name, systemImage: "line.3.horizontal")
                        .padding(8)
                }
                .help(L10n.text("settings.drag.to.a.zone.to.change.visibility"))
                .accessibilityIdentifier("menu-item.drag.\(entry.id)")
                .accessibilityLabel(L10n.text("settings.drag.handle.for.0", entry.name))
                .accessibilityHint(L10n.text("settings.drag.to.a.zone.to.change.collection"))
            Group {
                if let icon = entry.icon { Image(nsImage: icon).resizable().scaledToFit() }
                else { Image(systemName: "app.dashed").resizable().scaledToFit().foregroundStyle(theme.color(\.textSecondary)) }
            }.frame(width: 25, height: 25).padding(.top, 3)
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name).font(.system(size: 13, weight: .semibold))
                        if isSystemFixed(entry.bundleID) {
                            Text(entry.bundleID == "com.mike.aisubgauge" ? L10n.text("settings.collection.entry.stays.visible") : L10n.text("settings.system.item.stays.visible")).font(.caption).foregroundStyle(theme.color(\.textSecondary))
                        }
                        if !entry.title.isEmpty && entry.title != entry.name {
                            Text(entry.title).font(.caption).foregroundStyle(theme.color(\.textSecondary)).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    Picker(L10n.text("settings.visibility"), selection: Binding(
                        get: { store.config.rules[entry.bundleID]?.zone ?? .visible },
                        set: { engine.setZone($0, for: entry.bundleID) }
                    )) {
                        ForEach(ItemZone.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 118).disabled(isSystemFixed(entry.bundleID))
                        .accessibilityIdentifier("menu-item.zone.\(entry.id)")
                        .accessibilityLabel(L10n.text("settings.visibility.of.0", entry.name))
                    Button { engine.moveInList(entry, offset: -1) } label: { Image(systemName: "arrow.left") }
                        .help(L10n.text("settings.move.left")).disabled(!entry.canMove || engine.isBusy)
                        .accessibilityIdentifier("menu-item.move-left.\(entry.id)")
                        .accessibilityLabel(L10n.text("settings.move.0.left", entry.name))
                    Button { engine.moveInList(entry, offset: 1) } label: { Image(systemName: "arrow.right") }
                        .help(L10n.text("settings.move.right")).disabled(!entry.canMove || engine.isBusy)
                        .accessibilityIdentifier("menu-item.move-right.\(entry.id)")
                        .accessibilityLabel(L10n.text("settings.move.0.right", entry.name))
                    Button(L10n.text("settings.open")) { engine.activate(entry) }.disabled(!entry.isRunning)
                        .accessibilityIdentifier("menu-item.open.\(entry.id)")
                        .accessibilityLabel(L10n.text("settings.open.0", entry.name))
                }
                HStack(spacing: 14) {
                    TextField(L10n.text("settings.group.name.optional"), text: itemBinding(entry.bundleID, \.group, default: ""))
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 170)
                        .accessibilityIdentifier("menu-item.group.\(entry.id)")
                        .accessibilityLabel(L10n.text("settings.group.for.0", entry.name))
                    Toggle(L10n.text("settings.show.when.app.is.active"), isOn: itemBinding(entry.bundleID, \.showWhenActive, default: false))
                        .font(.caption)
                        .accessibilityIdentifier("menu-item.active.\(entry.id)")
                        .accessibilityLabel(L10n.text("settings.show.when.0.is.active", entry.name))
                }
            }
        }
        .padding(12)
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
        Form {
            Section(L10n.text("settings.expansion")) {
                Toggle(L10n.text("settings.use.a.separate.collection.bar"), isOn: $store.config.useFloatingBar)
                Text(L10n.text("settings.when.enabled.collected.icons.appear.below.the"))
                    .font(.caption).foregroundStyle(theme.color(\.textSecondary))
                Toggle(L10n.text("settings.show.icon.names"), isOn: $store.config.showLabels)
                Toggle(L10n.text("settings.expand.on.hover"), isOn: $store.config.revealOnHover)
                Toggle(L10n.text("settings.expand.when.scrolling.in.the.menu.bar"), isOn: $store.config.revealOnScroll)
                Toggle(L10n.text("settings.expand.when.clicking.an.empty.menu.bar"), isOn: $store.config.revealOnEmptyClick)
            }
            Section(L10n.text("settings.auto.collapse")) {
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
            Section(L10n.text("settings.spacers")) {
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
        }.formStyle(.grouped)
    }

    private var presetsPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                TextField(L10n.text("settings.preset.name.e.g.focused.work"), text: $presetName).textFieldStyle(.roundedBorder)
                Button(L10n.text("settings.save.current.layout")) {
                    let previous = store.config.presets.count
                    store.savePreset(name: presetName, order: engine.captureCurrentOrder())
                    if store.config.presets.count > previous && store.error == nil { presetName = "" }
                }.disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text(L10n.text("settings.presets.save.icon.zones.order.groups.and"))
                .font(.callout).foregroundStyle(theme.color(\.textSecondary))
            if store.config.presets.isEmpty {
                ContentUnavailableView(L10n.text("settings.no.presets.saved.yet"), systemImage: "square.stack.3d.up", description: Text(L10n.text("settings.organize.icons.in.menu.bar.layout.then")))
            } else {
                List {
                    ForEach(store.config.presets) { preset in
                        HStack(spacing: 14) {
                            Image(systemName: "square.stack.3d.up.fill").foregroundStyle(theme.color(\.accent))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(preset.name).font(.headline)
                                Text(L10n.text("settings.0.app.settings.1.order.records", preset.rules.count, preset.order.count))
                                    .font(.caption).foregroundStyle(theme.color(\.textSecondary))
                            }
                            Spacer()
                            Button(L10n.text("settings.apply")) { store.applyPreset(preset); engine.applyVisibility() }
                            Button(L10n.text("settings.delete"), role: .destructive) { store.deletePreset(preset.id) }
                        }.padding(.vertical, 7)
                    }
                }.listStyle(.inset)
            }
            Spacer(minLength: 0)
        }.padding(24)
    }

    private var generalPage: some View {
        Form {
            Section(L10n.text("settings.language")) {
                Picker(L10n.text("settings.language"), selection: $language) {
                    Text(L10n.text("settings.language.system")).tag("system")
                    Text(L10n.text("settings.language.en")).tag("en")
                    Text(L10n.text("settings.language.zhHans")).tag("zh-Hans")
                }
                Text(L10n.text("settings.language.restart")).font(.caption).foregroundStyle(theme.color(\.textSecondary))
            }
            Section(L10n.text("settings.theme")) {
                Picker(L10n.text("settings.theme"), selection: $themePreference) {
                    Text(L10n.text("settings.theme.system")).tag("system")
                    Text(L10n.text("settings.theme.light")).tag("light")
                    Text(L10n.text("settings.theme.dark")).tag("dark")
                }
            }
            Section(L10n.text("settings.startup")) {
                Toggle(L10n.text("settings.launch.at.login"), isOn: Binding(get: { loginStatus == .enabled }, set: setLoginEnabled))
                if loginStatus == .requiresApproval {
                    Text(L10n.text("settings.the.login.item.needs.system.approval.allow"))
                        .font(.caption).foregroundStyle(theme.color(\.demo))
                    Button(L10n.text("settings.open.login.items.settings")) { SMAppService.openSystemSettingsLoginItems() }
                }
                Text(L10n.text("settings.the.app.keeps.running.in.the.menu"))
                    .font(.caption).foregroundStyle(theme.color(\.textSecondary))
            }
            ProviderLoginConsentView()
            Section(L10n.text("settings.diagnostics")) {
                Button(L10n.text("menu.diagnostics")) { DiagnosticsPreview.shared.show(snapshots: AIUsageStore.shared.snapshots) }
            }
            Section(L10n.text("settings.settings.file")) {
                HStack {
                    Button(L10n.text("settings.export.settings.653")) { store.exportSettings() }
                    Button(L10n.text("settings.import.settings.654")) { store.importSettings(); refreshLoginStatus() }
                    Button(L10n.text("settings.show.in.finder")) { NSWorkspace.shared.activateFileViewerSelecting([store.url]) }
                }
                Text(L10n.text("settings.file.format.and.values.are.checked.before"))
                    .font(.caption).foregroundStyle(theme.color(\.textSecondary))
                Button(L10n.text("settings.save.settings.again")) { store.save() }
            }
            Section(L10n.text("settings.about")) {
                LabeledContent(L10n.text("settings.name"), value: L10n.text("app.name"))
                LabeledContent(L10n.text("settings.english.name"), value: L10n.text("app.name"))
                LabeledContent(L10n.text("settings.version"), value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? AppIdentifiers.version)
                Text(L10n.text("settings.all.features.are.available.without.an.activation"))
                    .font(.caption).foregroundStyle(theme.color(\.textSecondary))
            }
        }.formStyle(.grouped)
    }

    private func refreshLoginStatus() {
        loginStatus = SMAppService.mainApp.status
        let actual = loginStatus == .enabled
        if store.config.launchAtLogin != actual { store.config.launchAtLogin = actual }
    }

    private func setLoginEnabled(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            refreshLoginStatus()
        } catch {
            refreshLoginStatus()
            store.error = L10n.text("settings.could.not.change.the.login.item.0", error.localizedDescription)
        }
    }
}
