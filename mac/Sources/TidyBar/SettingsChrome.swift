import SwiftUI

// Order here is also the navigation contract exercised by SettingsV2Tests.
enum SettingsSection: String, CaseIterable, Identifiable {
    case subscriptions, addons, layout, bar, panel, widgets, appearance, presets, automation, hotkeys, general
    static let addonPages: [Self] = [.layout, .bar, .panel, .widgets, .appearance, .presets, .automation, .hotkeys]
    static let sidebarPages: [Self] = [.subscriptions] + addonPages + [.general]
    var id: String { rawValue }
    var title: String {
        L10n.text(titleKey)
    }
    var titleKey: String {
        switch self {
        case .subscriptions: return "settings.subscriptions"
        case .addons: return "settings.addons"
        case .layout: return "settings.menu.bar.layout"
        case .bar: return "settings.collection.bar"
        case .panel: return "settings.panel"
        case .appearance: return "settings.appearance"
        case .presets: return "settings.presets"
        case .automation: return "settings.automation"
        case .widgets: return "settings.widgets"
        case .hotkeys: return "settings.shortcuts"
        case .general: return "settings.general"
        }
    }
    var icon: String {
        switch self {
        case .subscriptions: return "gauge.with.needle"
        case .addons: return "menubar.rectangle"
        case .layout: return "menubar.rectangle"
        case .bar: return "tray.full.fill"
        case .panel: return "rectangle.topthird.inset.filled"
        case .appearance: return "paintpalette.fill"
        case .presets: return "square.3.layers.3d"
        case .automation: return "bolt.fill"
        case .widgets: return "square.grid.2x2.fill"
        case .hotkeys: return "keyboard.fill"
        case .general: return "gearshape"
        }
    }
    var color: Color {
        switch self {
        case .subscriptions: return Color(themeHex: "#34C759")
        case .addons: return Color(themeHex: "#007AFF")
        case .layout: return Color(themeHex: "#007AFF")
        case .bar: return Color(themeHex: "#FF9500")
        case .panel: return Color(themeHex: "#30B0C7")
        case .appearance: return Color(themeHex: "#FF2D55")
        case .presets: return Color(themeHex: "#AF52DE")
        case .automation: return Color(themeHex: "#FF9500")
        case .widgets: return Color(themeHex: "#34C759")
        case .hotkeys, .general: return Color(themeHex: "#8E8E93")
        }
    }
    var caption: String {
        let key: String
        switch self {
        case .subscriptions: key = "settings.subscriptions.caption"
        case .addons: key = "settings.addons.caption"
        case .layout: key = "settings.keep.frequently.used.icons.visible.and.collect"
        case .bar: key = "settings.choose.how.to.expand.and.when.to"
        case .panel: key = "settings.panel.caption"
        case .appearance: key = "settings.set.a.menu.bar.background.and.corners"
        case .presets: key = "settings.presets.caption"
        case .automation: key = "settings.switch.presets.automatically.by.app.time.or"
        case .widgets: key = "settings.add.a.clock.calendar.music.or.weather"
        case .hotkeys: key = "settings.shortcuts.caption"
        case .general: key = "settings.manage.startup.and.settings.files"
        }
        return L10n.text(key)
    }
}

struct SettingsIcon: View {
    var section: SettingsSection
    var size: CGFloat = 20
    var body: some View {
        Image(systemName: section.icon).font(.system(size: size * 0.65, weight: .semibold))
            .foregroundStyle(.white).frame(width: size, height: size)
            .background {
                if section == .subscriptions {
                    LinearGradient(colors: [section.color, Color(themeHex: "#30B0C7")], startPoint: .top, endPoint: .bottom)
                } else { section.color }
            }
            .clipShape(RoundedRectangle(cornerRadius: size * 0.28))
            .accessibilityHidden(true)
    }
}

struct SettingsGlass: View {
    @Environment(\.colorScheme) private var scheme
    var radius: CGFloat = 26
    var approximate = false
    var sidebar = false
    var prominent = false
    var body: some View {
        let dark = scheme == .dark
        let shape = RoundedRectangle(cornerRadius: radius)
        Group {
            if approximate {
                shape.fill(prominent ? (dark ? Color(themeHex: "#1E1E22") : Color(themeHex: "#F6F6FA")).opacity(0.99)
                           : sidebar ? (dark ? Color(themeHex: "#16161C").opacity(0.86) : .white.opacity(0.75))
                           : (dark ? Color(themeHex: "#1E1E22").opacity(0.78) : Color(themeHex: "#F6F6FA").opacity(0.78)))
            } else if prominent {
                shape.fill(.regularMaterial)
                    .overlay(shape.fill((dark ? Color(themeHex: "#1E1E22") : Color(themeHex: "#F6F6FA")).opacity(0.96)))
            } else if #available(macOS 26.0, *) {
                Color.clear.glassEffect(.regular, in: shape)
            } else { shape.fill(.ultraThinMaterial) }
        }
        .overlay(shape.strokeBorder(.black.opacity(dark ? 0.6 : 0.18), lineWidth: 0.5))
        .overlay(shape.inset(by: 0.5).strokeBorder(
            LinearGradient(colors: [.white.opacity(dark ? 0.32 : 0.95), .white.opacity(dark ? 0.05 : 0.25)],
                           startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
    }
}

/// Inactive offscreen windows draw native switches gray, even when their binding is on.
struct SettingsSwitchStyle: ToggleStyle {
    var approximate = false
    @Environment(\.controlSize) private var size
    func makeBody(configuration: Configuration) -> some View {
        if approximate {
            let height: CGFloat = size == .mini ? 16 : 20
            HStack {
                configuration.label
                Spacer(minLength: 8)
                Button { configuration.isOn.toggle() } label: {
                    Capsule().fill(configuration.isOn ? Color.green : Color.gray.opacity(0.35))
                        .frame(width: height * 2.2, height: height)
                        .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                            Circle().fill(.white).frame(width: height - 3, height: height - 3).padding(1.5)
                        }
                }.buttonStyle(.plain)
            }
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch)
            }
        } else {
            Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch).tint(.green)
        }
    }
}

/// Shared defaults for settings pages and their sheets; navigation and vendor tiles
/// keep their explicit plain button styles.
struct SettingsControlStyle: ViewModifier {
    var approximate = false
    func body(content: Content) -> some View {
        content
            .toggleStyle(SettingsSwitchStyle(approximate: approximate))
            .pickerStyle(.menu)
            .buttonStyle(SettingsPillStyle())
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
    }
}

struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12, content: content).padding(.bottom, 2)
        }
    }
}

struct SettingsChrome<Content: View>: View {
    @Binding var section: SettingsSection
    var approximateGlass = false
    @ViewBuilder var content: () -> Content
    @State private var search = ""
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                // Reserve the native titlebar button area; AppKit draws the traffic lights.
                Spacer().frame(height: 44)
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10))
                    TextField(L10n.text("settings.search"), text: $search).textFieldStyle(.plain).font(.system(size: 11.5))
                }.foregroundStyle(.tertiary).padding(.horizontal, 9).frame(height: 24)
                    .background(.white.opacity(scheme == .dark ? 0.12 : 0.45), in: Capsule()).padding(.bottom, 6)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        nav(.subscriptions)
                        Button { section = .addons } label: { heading(L10n.text("settings.addons")) }
                            .buttonStyle(.plain).accessibilityIdentifier("settings.nav.addons")
                        ForEach(SettingsSection.addonPages.filter(matches)) { nav($0) }
                        heading(L10n.text("settings.general"))
                        nav(.general)
                    }
                }.scrollIndicators(.hidden)
            }
            .padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 8)
            .frame(width: 186).frame(maxHeight: .infinity)
            .background { SettingsGlass(radius: 22, approximate: approximateGlass, sidebar: true) }
            .padding(8)
            VStack(alignment: .leading, spacing: 0) {
                Text(section.title).font(.system(size: 20, weight: .bold)).tracking(-0.3)
                Text(section.caption).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 2).padding(.bottom, 12)
                content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }.padding(.top, 24).padding(.leading, 12).padding(.trailing, 22).padding(.bottom, 16)
        }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .foregroundStyle(scheme == .dark ? .white : .black)
        .background { SettingsGlass(approximate: approximateGlass) }
        .clipShape(RoundedRectangle(cornerRadius: 26))
        .ignoresSafeArea(.container, edges: .top)
    }
    private func matches(_ page: SettingsSection) -> Bool {
        search.isEmpty || page.title.localizedCaseInsensitiveContains(search) || page.caption.localizedCaseInsensitiveContains(search)
    }
    private func heading(_ title: String) -> some View {
        Text(title).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.tertiary)
            .padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 3)
    }
    @ViewBuilder private func nav(_ page: SettingsSection) -> some View {
        if matches(page) {
            Button { section = page } label: {
                HStack(spacing: 7) {
                    SettingsIcon(section: page)
                    Text(page.title).font(.system(size: 12.5, weight: section == page ? .semibold : .regular))
                    Spacer(minLength: 0)
                }.padding(.horizontal, 8).frame(height: 28)
                    .background((scheme == .dark ? Color.white : .black).opacity(section == page ? (scheme == .dark ? 0.12 : 0.08) : 0),
                                in: RoundedRectangle(cornerRadius: 9))
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("settings.nav.\(page.rawValue)")
        }
    }
}

struct SettingsGroup<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: () -> Content
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title { Text(title).font(.system(size: 12, weight: .semibold)) }
            content()
        }.font(.system(size: 11.5)).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(scheme == .dark ? 0.08 : 0.38), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(scheme == .dark ? 0.1 : 0.14), lineWidth: 0.5))
    }
}

struct SettingsAddonsView: View {
    var navigate: (SettingsSection) -> Void
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(spacing: 0) {
            ForEach(SettingsSection.addonPages) { page in
                if page != SettingsSection.addonPages.first { Divider() }
                Button { navigate(page) } label: {
                    HStack(spacing: 10) {
                        SettingsIcon(section: page, size: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(page.title).font(.system(size: 13, weight: .semibold))
                            Text(page.caption).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
                    }.padding(.horizontal, 12).frame(height: 45.5).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }.background(.white.opacity(scheme == .dark ? 0.08 : 0.38), in: RoundedRectangle(cornerRadius: 14))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.14), lineWidth: 0.5))
    }
}

/// All independent app windows share native controls and a transparent titlebar.
enum StandaloneWindow {
    static let minimumSize = NSSize(width: 680, height: 460)
    static let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]

    @MainActor static func hostingView<Content: View>(_ view: Content) -> NSHostingView<Content> {
        let hosting = NSHostingView(rootView: view)
        // NSWindow owns the size. SwiftUI's fitting size must not resize or constrain it.
        hosting.sizingOptions = []
        return hosting
    }

    @MainActor static func make(size: NSSize = minimumSize) -> NSWindow {
        let size = NSSize(width: max(size.width, minimumSize.width), height: max(size.height, minimumSize.height))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: styleMask,
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Native toolbar spacing keeps the traffic lights inside the content's rounded corners.
        window.toolbar = NSToolbar(identifier: "AI SubGauge Settings")
        window.toolbarStyle = .unified
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        window.setContentSize(size)
        window.contentMinSize = minimumSize
        return window
    }
}

@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var section: SettingsSection
    init(section: SettingsSection = .subscriptions) { self.section = section }
}

/// Every settings entry point uses this owner and the same observed selection.
@MainActor
final class SettingsWindowController {
    let navigation = SettingsNavigation()
    private(set) var window: NSWindow?
    private let store: SettingsStore
    private let engine: MenuEngine
    private let usageStore: AIUsageStore
    private let approximateGlass: Bool

    init(store: SettingsStore, engine: MenuEngine, usageStore: AIUsageStore? = nil, approximateGlass: Bool = false) {
        self.store = store
        self.engine = engine
        self.usageStore = usageStore ?? .shared
        self.approximateGlass = approximateGlass
    }

    func show(_ section: SettingsSection = .subscriptions) {
        PopupManager.shared.dismiss()
        navigation.section = section
        if window == nil {
            let window = StandaloneWindow.make()
            window.identifier = NSUserInterfaceItemIdentifier("ai-subgauge.settings")
            window.title = L10n.text("app.name")
            window.contentView = StandaloneWindow.hostingView(SettingsView(store: store, engine: engine,
                usageStore: usageStore, approximateGlass: approximateGlass, navigation: navigation)
                .appThemed().environment(\.locale, L10n.locale))
            window.isMovableByWindowBackground = true
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        // Attaching/ordering an NSHostingView can reset AppKit's content constraints.
        window?.contentMinSize = StandaloneWindow.minimumSize
    }
}
