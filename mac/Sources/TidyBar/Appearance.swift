import AppKit
import SwiftUI
import ApplicationServices

extension Color {
    init(tidyHex: String) {
        let hex = tidyHex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let value = UInt64(hex, radix: 16) ?? 0x24324B
        self.init(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
    var tidyHex: String {
        let color = NSColor(self).usingColorSpace(.deviceRGB) ?? .black
        return String(format: "#%02X%02X%02X", Int((color.redComponent * 255).rounded()), Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
    }
}

struct AppearanceMetrics: Equatable {
    var menuHeight: CGFloat
    var extensionHeight: CGFloat
    var shadowPadding: CGFloat
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    var shapeHeight: CGFloat { menuHeight + extensionHeight }
    var panelHeight: CGFloat { shapeHeight + shadowPadding }
}

enum AppearanceGeometry {
    static func metrics(menuHeight: CGFloat, style: BarStyle) -> AppearanceMetrics {
        let radius = max(0, CGFloat(style.cornerRadius))
        let extended = style.roundUnderMenuBar == true
        return AppearanceMetrics(menuHeight: max(0, menuHeight), extensionHeight: extended ? radius : 0,
                                 shadowPadding: style.shadow ? 12 : 0,
                                 topRadius: (style.roundTop ?? true) ? radius : 0,
                                 bottomRadius: (extended || (style.roundBottom ?? true)) ? radius : 0)
    }

    static func surfaceMetrics(containerHeight: CGFloat, menuHeight: CGFloat?, style: BarStyle) -> AppearanceMetrics {
        if let menuHeight { return metrics(menuHeight: menuHeight, style: style) }
        // Floating/search backgrounds fill their host. Under-menu extension and
        // dedicated shadow padding apply only to a physical menu bar surface.
        var backgroundStyle = style
        backgroundStyle.roundUnderMenuBar = false
        backgroundStyle.shadow = false
        return metrics(menuHeight: containerHeight, style: backgroundStyle)
    }

    static func panelFrame(screenFrame: CGRect, menuHeight: CGFloat, style: BarStyle) -> CGRect {
        let height = metrics(menuHeight: menuHeight, style: style).panelHeight
        return CGRect(x: screenFrame.minX, y: screenFrame.maxY - height, width: screenFrame.width, height: height)
    }

    static func borderColor(style: BarStyle, dark: Bool) -> String {
        dark && !(style.linkBorderColors ?? true) ? (style.darkBorderColor ?? style.borderColor) : style.borderColor
    }

    static func gradientColors(style: BarStyle, dark: Bool) -> [(color: String, location: Double)] {
        let first = dark && style.useDarkStyle ? style.darkColor : style.color
        guard style.gradient else { return [(first, 0), (first, 1)] }
        guard let stops = style.gradientStops, stops.count >= 2 else { return [(first, 0), (style.endColor, 1)] }
        return stops.enumerated().map { index, stop in
            (index == 0 && dark && style.useDarkStyle ? style.darkColor : stop.color, stop.location)
        }
    }

    static func splitWidths(width: CGFloat, notchWidth: CGFloat, notchCenter: CGFloat? = nil) -> (left: CGFloat, gap: CGFloat, right: CGFloat) {
        let total = max(0, width)
        let gap = min(total, max(16, notchWidth))
        let center = notchCenter ?? total / 2
        let left = min(max(0, center - gap / 2), total - gap)
        return (left, gap, total - gap - left)
    }

    static func shouldHideDecoration(presentationOptions: NSApplication.PresentationOptions, autoHidePreference: Bool) -> Bool {
        autoHidePreference || presentationOptions.contains(.autoHideMenuBar) || presentationOptions.contains(.hideMenuBar)
    }
}

/// The same surface renders in the preview and the noninteractive desktop panels.
struct BarSurface: View {
    var style: BarStyle
    var notchWidth: CGFloat = 0
    var notchCenter: CGFloat? = nil
    var menuHeight: CGFloat? = nil
    @Environment(\.colorScheme) private var colorScheme
    private var fill: LinearGradient {
        let stops = AppearanceGeometry.gradientColors(style: style, dark: colorScheme == .dark)
            .map { Gradient.Stop(color: Color(tidyHex: $0.color), location: CGFloat($0.location)) }
        return LinearGradient(gradient: Gradient(stops: stops), startPoint: .leading, endPoint: .trailing)
    }
    private func capsule(metrics: AppearanceMetrics) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: metrics.topRadius, bottomLeadingRadius: metrics.bottomRadius,
                                           bottomTrailingRadius: metrics.bottomRadius, topTrailingRadius: metrics.topRadius)
        return shape.fill(fill)
            .overlay(shape.strokeBorder(Color(tidyHex: AppearanceGeometry.borderColor(style: style, dark: colorScheme == .dark)), lineWidth: style.borderWidth))
            .shadow(color: .black.opacity(style.shadow ? 0.3 : 0), radius: style.shadow ? 3 : 0, y: 1)
    }
    var body: some View {
        GeometryReader { geometry in
            let metrics = AppearanceGeometry.surfaceMetrics(containerHeight: geometry.size.height, menuHeight: menuHeight, style: style)
            ZStack(alignment: .top) {
                if style.split {
                    let widths = AppearanceGeometry.splitWidths(width: geometry.size.width, notchWidth: notchWidth, notchCenter: notchCenter)
                    HStack(spacing: widths.gap) {
                        capsule(metrics: metrics).frame(width: widths.left)
                        capsule(metrics: metrics).frame(width: widths.right)
                    }.frame(height: metrics.shapeHeight)
                } else { capsule(metrics: metrics).frame(height: metrics.shapeHeight) }
                if style.hideNotch && notchWidth > 0 {
                    Color.black.frame(width: min(geometry.size.width, notchWidth), height: metrics.menuHeight)
                        .position(x: notchCenter ?? geometry.size.width / 2, y: metrics.menuHeight / 2)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .opacity(min(0.3, max(0, style.opacity)))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

@MainActor
final class AppearanceController {
    private let store: SettingsStore
    private var panels: [NSPanel] = []
    private var observations: [NSObjectProtocol] = []
    private var timer: Timer?
    init(store: SettingsStore) { self.store = store }
    func start() {
        guard observations.isEmpty else { return }
        observations.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.update() } })
        observations.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.update() } })
        update()
    }
    func stop() {
        timer?.invalidate(); timer = nil
        for observer in observations { NotificationCenter.default.removeObserver(observer); NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observations.removeAll()
        panels.forEach { $0.close() }; panels.removeAll()
    }
    func update() {
        panels.forEach { $0.close() }; panels.removeAll()
        guard store.config.style.enabled else { timer?.invalidate(); timer = nil; return }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in Task { @MainActor in self?.refreshVisibility() } }
            timer?.tolerance = 0.3
        }
        for screen in NSScreen.screens {
            let menuHeight = max(24, screen.safeAreaInsets.top)
            let rect = AppearanceGeometry.panelFrame(screenFrame: screen.frame, menuHeight: menuHeight, style: store.config.style)
            let panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            let leftArea = screen.auxiliaryTopLeftArea
            let rightArea = screen.auxiliaryTopRightArea
            let notch = leftArea.flatMap { left in rightArea.map { right in max(0, right.minX - left.maxX) } } ?? 0
            let notchCenter: CGFloat? = leftArea.flatMap { left in rightArea.map { right in (left.maxX + right.minX) / 2 - screen.frame.minX } }
            panel.contentView = NSHostingView(rootView: BarSurface(style: store.config.style, notchWidth: notch, notchCenter: notchCenter, menuHeight: menuHeight))
            panels.append(panel)
        }
        refreshVisibility()
    }
    private func refreshVisibility() {
        guard !panels.isEmpty else { return }
        // Keep automatic menu hiding useful: no persistent colored strip remains
        // when macOS hides its menu. Decoration resumes after auto-hide is disabled.
        if AppearanceGeometry.shouldHideDecoration(presentationOptions: NSApplication.shared.currentSystemPresentationOptions,
                                                   autoHidePreference: UserDefaults.standard.bool(forKey: "_HIHideMenuBar")) {
            panels.filter(\.isVisible).forEach { $0.orderOut(nil) }
            return
        }
        // Full-screen windows use the entire display, including its menu bar region.
        // Maximized ordinary windows start below that region and remain decorated.
        var focusedFullScreenFrame: CGRect?
        if AXIsProcessTrusted(), let front = NSWorkspace.shared.frontmostApplication {
            let application = AXUIElementCreateApplication(front.processIdentifier)
            AXUIElementSetMessagingTimeout(application, 0.1)
            var rawWindow: CFTypeRef?
            if AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &rawWindow) == .success,
               let rawWindow, CFGetTypeID(rawWindow) == AXUIElementGetTypeID() {
                let window = unsafeBitCast(rawWindow, to: AXUIElement.self)
                AXUIElementSetMessagingTimeout(window, 0.1)
                var fullScreen: CFTypeRef?
                if AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullScreen) == .success,
                   (fullScreen as? Bool) == true {
                    var rawPosition: CFTypeRef?; var rawSize: CFTypeRef?
                    AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &rawPosition)
                    AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &rawSize)
                    if let rawPosition, let rawSize, CFGetTypeID(rawPosition) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID() {
                        var position = CGPoint.zero; var size = CGSize.zero
                        AXValueGetValue(unsafeBitCast(rawPosition, to: AXValue.self), .cgPoint, &position)
                        AXValueGetValue(unsafeBitCast(rawSize, to: AXValue.self), .cgSize, &size)
                        focusedFullScreenFrame = CGRect(origin: position, size: size)
                    }
                }
            }
        }
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        for panel in panels {
            let screen = NSScreen.screens.first { abs($0.frame.maxY - panel.frame.maxY) < 1 && abs($0.frame.minX - panel.frame.minX) < 1 }
            guard let screen else { if panel.isVisible { panel.orderOut(nil) }; continue }
            let primaryHeight = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
            let target = CGRect(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height)
            let fullScreen = windows.contains { window in
                guard (window[kCGWindowLayer as String] as? Int) == 0,
                      (window[kCGWindowOwnerPID as String] as? Int32) != ProcessInfo.processInfo.processIdentifier,
                      let dict = window[kCGWindowBounds as String] as? [String: Any],
                      let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary) else { return false }
                return abs(bounds.minX - target.minX) < 2 && abs(bounds.minY - target.minY) < 2 && abs(bounds.width - target.width) < 2 && abs(bounds.height - target.height) < 2
            }
            let focusedFullScreen = focusedFullScreenFrame.map { $0.intersection(target).width > target.width / 2 && $0.intersection(target).height > target.height / 2 } ?? false
            if fullScreen || focusedFullScreen {
                if panel.isVisible { panel.orderOut(nil) }
            } else if !panel.isVisible { panel.orderFrontRegardless() }
        }
    }
}

struct AppearanceSettingsView: View {
    @ObservedObject var store: SettingsStore
    private func color(_ key: WritableKeyPath<BarStyle, String>) -> Binding<Color> {
        Binding(get: { Color(tidyHex: store.config.style[keyPath: key]) }, set: { store.config.style[keyPath: key] = $0.tidyHex })
    }
    private func optionalBool(_ key: WritableKeyPath<BarStyle, Bool?>, fallback: Bool) -> Binding<Bool> {
        Binding(get: { store.config.style[keyPath: key] ?? fallback }, set: { store.config.style[keyPath: key] = $0 })
    }
    private var customGradient: Binding<Bool> {
        Binding(get: { store.config.style.gradientStops != nil }, set: { enabled in
            store.config.style.gradientStops = enabled ? [GradientColorStop(color: store.config.style.color, location: 0), GradientColorStop(color: store.config.style.endColor, location: 1)] : nil
        })
    }
    private func gradientColor(_ id: UUID) -> Binding<Color> {
        Binding(get: { Color(tidyHex: store.config.style.gradientStops?.first { $0.id == id }?.color ?? store.config.style.color) }, set: { value in
            guard var stops = store.config.style.gradientStops, let index = stops.firstIndex(where: { $0.id == id }) else { return }
            stops[index].color = value.tidyHex
            store.config.style.gradientStops = stops
        })
    }
    private func gradientLocation(_ id: UUID) -> Binding<Double> {
        Binding(get: { store.config.style.gradientStops?.first { $0.id == id }?.location ?? 0 }, set: { value in
            guard var stops = store.config.style.gradientStops, let index = stops.firstIndex(where: { $0.id == id }) else { return }
            let lower = index == 0 ? 0 : stops[index - 1].location
            let upper = index == stops.count - 1 ? 1 : stops[index + 1].location
            stops[index].location = min(upper, max(lower, value))
            store.config.style.gradientStops = stops
        })
    }
    private func addGradientStop() {
        guard var stops = store.config.style.gradientStops, stops.count < 8 else { return }
        let index = (0..<(stops.count - 1)).max { stops[$0 + 1].location - stops[$0].location < stops[$1 + 1].location - stops[$1].location } ?? 0
        let location = (stops[index].location + stops[index + 1].location) / 2
        stops.insert(GradientColorStop(color: "#FFFFFF", location: location), at: index + 1)
        store.config.style.gradientStops = stops
    }
    private func removeGradientStop(_ id: UUID) {
        guard var stops = store.config.style.gradientStops, stops.count > 2 else { return }
        stops.removeAll { $0.id == id }
        store.config.style.gradientStops = stops
    }
    private var darkBorderColor: Binding<Color> {
        Binding(get: { Color(tidyHex: store.config.style.darkBorderColor ?? store.config.style.borderColor) },
                set: { store.config.style.darkBorderColor = $0.tidyHex })
    }
    private var preview: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [.indigo.opacity(0.35), .pink.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing)
            ZStack(alignment: .top) {
                BarSurface(style: store.config.style, notchWidth: 36, menuHeight: 30)
                    .frame(height: AppearanceGeometry.metrics(menuHeight: 30, style: store.config.style).panelHeight)
                HStack {
                    Image(systemName: "apple.logo"); Text(L10n.text("appearance.finder.file.edit.view")); Spacer()
                    Image(systemName: "wifi"); Image(systemName: "battery.75percent"); Text(L10n.text("appearance.sat.10.24"))
                }.font(.system(size: 12)).padding(.horizontal, 12).frame(height: 30)
            }.padding(.horizontal, 12).padding(.top, 18)
        }.frame(height: max(90, AppearanceGeometry.metrics(menuHeight: 30, style: store.config.style).panelHeight + 30))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    var body: some View {
        SettingsPage {
            SettingsGroup(title: L10n.text("appearance.menu.bar.preview")) {
                preview
                Text(L10n.text("appearance.the.preview.uses.the.same.appearance.as")).font(.caption).foregroundStyle(.secondary)
            }
            SettingsGroup(title: L10n.text("appearance.background")) {
                Toggle(L10n.text("appearance.enable.custom.appearance"), isOn: $store.config.style.enabled)
                ColorPicker(L10n.text("appearance.background.color"), selection: color(\.color), supportsOpacity: false)
                Toggle(L10n.text("appearance.gradient.background"), isOn: $store.config.style.gradient)
                if store.config.style.gradient {
                    Toggle(L10n.text("appearance.custom.multicolor.gradient"), isOn: customGradient)
                    if let stops = store.config.style.gradientStops {
                        ForEach(Array(stops.enumerated()), id: \.element.id) { index, stop in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    ColorPicker(L10n.text("appearance.color.stop.0", index + 1), selection: gradientColor(stop.id), supportsOpacity: false)
                                    Button(L10n.text("appearance.remove")) { removeGradientStop(stop.id) }.disabled(stops.count <= 2)
                                }
                                HStack {
                                    Text(L10n.text("appearance.position"))
                                    Slider(value: gradientLocation(stop.id), in: 0...1)
                                    Text(stop.location, format: .percent.precision(.fractionLength(0))).monospacedDigit().frame(width: 42)
                                }
                            }
                        }
                        Button(L10n.text("appearance.add.color.stop")) { addGradientStop() }.disabled(stops.count >= 8)
                        Text(L10n.text("appearance.supports.2.to.8.color.stops.ordered")).font(.caption).foregroundStyle(.secondary)
                    } else { ColorPicker(L10n.text("appearance.gradient.end.color"), selection: color(\.endColor), supportsOpacity: false) }
                }
                HStack { Text(L10n.text("appearance.tint.opacity")); Slider(value: Binding(get: { min(0.3, max(0, store.config.style.opacity)) }, set: { store.config.style.opacity = $0 }), in: 0...0.3); Text(min(0.3, max(0, store.config.style.opacity)), format: .percent.precision(.fractionLength(0))).monospacedDigit().frame(width: 44) }
                Toggle(L10n.text("appearance.split.into.left.and.right.capsules"), isOn: $store.config.style.split)
                Toggle(L10n.text("appearance.use.black.behind.the.notch"), isOn: $store.config.style.hideNotch)
            }
            SettingsGroup(title: L10n.text("appearance.outline")) {
                HStack { Text(L10n.text("appearance.corner.radius")); Slider(value: $store.config.style.cornerRadius, in: 0...50); Text("\(Int(store.config.style.cornerRadius))") }
                Toggle(L10n.text("appearance.round.top.corners"), isOn: optionalBool(\.roundTop, fallback: true))
                Toggle(L10n.text("appearance.round.bottom.corners"), isOn: optionalBool(\.roundBottom, fallback: true)).disabled(store.config.style.roundUnderMenuBar == true)
                Toggle(L10n.text("appearance.round.below.the.menu.bar"), isOn: optionalBool(\.roundUnderMenuBar, fallback: false))
                if store.config.style.roundUnderMenuBar == true {
                    Text(L10n.text("appearance.extends.the.bottom.edge.below.the.menu")).font(.caption).foregroundStyle(.secondary)
                }
                HStack { Text(L10n.text("appearance.border.width")); Slider(value: $store.config.style.borderWidth, in: 0...10); Text(store.config.style.borderWidth, format: .number.precision(.fractionLength(1))) }
                ColorPicker((store.config.style.linkBorderColors ?? true) ? L10n.text("appearance.border.color") : L10n.text("appearance.light.border.color"), selection: color(\.borderColor), supportsOpacity: false)
                Toggle(L10n.text("appearance.soft.shadow"), isOn: $store.config.style.shadow)
            }
            SettingsGroup(title: L10n.text("appearance.dark.mode")) {
                Toggle(L10n.text("appearance.change.background.color.with.system.dark.mode"), isOn: $store.config.style.useDarkStyle)
                if store.config.style.useDarkStyle {
                    ColorPicker(L10n.text("appearance.dark.background.color"), selection: color(\.darkColor), supportsOpacity: false)
                    if store.config.style.gradient { Text(L10n.text("appearance.the.dark.background.color.replaces.the.first")).font(.caption).foregroundStyle(.secondary) }
                }
                Toggle(L10n.text("appearance.use.the.same.border.in.light.and"), isOn: optionalBool(\.linkBorderColors, fallback: true))
                if store.config.style.linkBorderColors == false { ColorPicker(L10n.text("appearance.dark.border.color"), selection: darkBorderColor, supportsOpacity: false) }
            }
        }
    }
}
