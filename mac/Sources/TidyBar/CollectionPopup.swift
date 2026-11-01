import AppKit
import SwiftUI

struct SearchContent: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var engine: MenuEngine
    let showAll: Bool
    var group: String?
    let dismiss: () -> Void
    var approximateGlass = false
    @Environment(\.colorScheme) private var scheme
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
                Button { dismiss(); AppActions.shared.showCollectionSettings() } label: { Image(systemName: "gearshape") }.buttonStyle(.plain).help(L10n.text("menu.open.settings"))
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
                    if query.isEmpty { Button(L10n.text("menu.open.layout.settings")) { dismiss(); AppActions.shared.showLayoutSettings() } }
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
                                            if store.config.showLabels || showAll { Text(entry.name).fontWeight(.medium).lineLimit(1) }
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
        .foregroundStyle(scheme == .dark ? Color.white : .black)
        .panelSurface(dark: scheme == .dark, approximate: approximateGlass)
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in selection = 0 }
        .onKeyPress(.downArrow) { selection = min(max(0, entries.count - 1), selection + 1); return .handled }
        .onKeyPress(.upArrow) { selection = max(0, selection - 1); return .handled }
    }
    private func open(_ entry: MenuEntry) { dismiss(); engine.activate(entry) }
}
