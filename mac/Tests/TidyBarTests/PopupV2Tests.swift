import AppKit
import SwiftUI
import Testing
@testable import TidyBar

extension TidyBarTests {
    @MainActor @Test func repeatedStatusClicksToggleOneReusablePanelAndDismissOutsideOrEscape() throws {
        _ = NSApplication.shared
        let store = AIUsageStore(applyDisplayFilters: false, fetcher: { _ in throw AIUsageError.signedOut })
        store.snapshots = UsageSnapshotFixture.snapshots
        let controller = AIUsageMenuBarController(store: store, onOpenUsage: {})
        defer { controller.stop() }
        // The sandbox cannot register with the system status bar. Use the same NSButton target/action
        // dispatch with a real anchor window, without changing the user's menu bar.
        let anchorWindow = NSWindow(contentRect: NSRect(x: -1000, y: -1000, width: 40, height: 30),
                                    styleMask: [.borderless], backing: .buffered, defer: false)
        anchorWindow.isReleasedWhenClosed = false
        defer { anchorWindow.close() }
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 40, height: 30))
        button.target = controller
        button.action = #selector(AIUsageMenuBarController.statusItemClicked(_:))
        anchorWindow.contentView = button
        let panel = controller.panel
        let otherController = AIUsageMenuBarController(store: store, onOpenUsage: {})
        #expect(otherController.panel === panel) // The popup instance is shared across all owners.
        func visiblePanels() -> Int {
            NSApp.windows.filter { $0.identifier?.rawValue == "ai-usage.panel" && $0.isVisible }.count
        }
        for _ in 0..<3 {
        button.performClick(nil)
            #expect(panel.isVisible)
            #expect(visiblePanels() == 1)
            // Mouse-down on the anchor is ignored, leaving mouse-up to close the popup.
            let anchor = try #require(button.window).convertToScreen(button.convert(button.bounds, to: nil))
            controller.dismissForClick(at: NSPoint(x: anchor.midX, y: anchor.midY))
            #expect(panel.isVisible)
            button.performClick(nil)
            #expect(!panel.isVisible)
            #expect(visiblePanels() == 0)
            #expect(controller.panel === panel)
        }
        button.performClick(nil)
        controller.dismissForClick(at: NSPoint(x: panel.frame.minX - 100, y: panel.frame.minY - 100))
        #expect(!panel.isVisible)
        button.performClick(nil)
        panel.cancelOperation(nil)
        #expect(!panel.isVisible)
        #expect(!panel.isOpaque && panel.backgroundColor == .clear)
        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)
        #expect(menu.items.contains { $0.action == #selector(AIUsageMenuBarController.toggleCollectionBar) })
    }

    @MainActor @Test func standaloneWindowsHaveRealTrafficLightsAndResizeWithContent() throws {
        _ = NSApplication.shared
        let window = StandaloneWindow.make()
        defer { window.close() }
        for flag: NSWindow.StyleMask in [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] {
            #expect(window.styleMask.contains(flag))
        }
        #expect(window.titlebarAppearsTransparent)
        #expect(window.titleVisibility == .hidden)
        #expect(window.contentMinSize == NSSize(width: 680, height: 460))
        for button: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            #expect(try #require(window.standardWindowButton(button)).isHidden == false)
            #expect(try #require(window.standardWindowButton(button)).isEnabled)
        }
        let chrome = SettingsChrome(section: .constant(.general), approximateGlass: true) { Text("Resize fixture") }
        let hosting = StandaloneWindow.hostingView(chrome)
        window.contentView = hosting
        window.setContentSize(NSSize(width: 800, height: 540))
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.frame.size == NSSize(width: 800, height: 540))
        // Use the real titlebar layout at both the minimum and resized window sizes.
        for size in [StandaloneWindow.minimumSize, NSSize(width: 800, height: 540)] {
            window.setContentSize(size)
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            let outer = CGPath(roundedRect: CGRect(origin: .zero, size: hosting.bounds.size),
                               cornerWidth: 26, cornerHeight: 26, transform: nil)
            let sidebar = CGPath(roundedRect: CGRect(x: 8, y: 8, width: 186, height: hosting.bounds.height - 16),
                                 cornerWidth: 22, cornerHeight: 22, transform: nil)
            for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                let button = try #require(window.standardWindowButton(type))
                var rect = button.convert(button.bounds, to: hosting)
                if !hosting.isFlipped { rect.origin.y = hosting.bounds.height - rect.maxY }
                #expect(rect.minX >= 19 && rect.minY >= 19)
                // The sidebar search starts at 8 + 14 + 44pt, below the native toolbar.
                #expect(rect.maxY < 66)
                for point in [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                              CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)] {
                    #expect(outer.contains(point) && sidebar.contains(point))
                }
            }
        }
    }

    @MainActor @Test func settingsContentFillsResizedWindowAndLongPagesScroll() throws {
        _ = NSApplication.shared
        let window = StandaloneWindow.make()
        defer { window.close() }
        let probe = NSView()
        window.contentView = StandaloneWindow.hostingView(
            SettingsChrome(section: .constant(.general), approximateGlass: true) {
                GeometryReader { geometry in
                    WindowLayoutProbe(view: probe).frame(width: geometry.size.width, height: geometry.size.height)
                }
            })
        var previous: NSRect?
        for size in [NSSize(width: 680, height: 460), NSSize(width: 960, height: 680)] {
            window.setContentSize(size)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            let hosting = try #require(window.contentView)
            hosting.superview?.layoutSubtreeIfNeeded()
            let rect = probe.convert(probe.bounds, to: hosting)
            #expect(rect.width > 400 && rect.height > 300)
            #expect(rect.maxX <= hosting.bounds.maxX && rect.maxY <= hosting.bounds.maxY)
            if let previous {
                #expect(abs(rect.minX - previous.minX) < 1) // Fixed sidebar width.
                #expect(abs(rect.width - previous.width - 280) < 1)
                #expect(abs(rect.height - previous.height - 220) < 1)
            }
            previous = rect
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("settings-resize-" + UUID().uuidString)
        let settings = SettingsStore(url: directory.appendingPathComponent("settings.json"))
        let usage = AIUsageStore(applyDisplayFilters: false, fetcher: { _ in throw AIUsageError.signedOut })
        window.setContentSize(StandaloneWindow.minimumSize)
        window.contentView = StandaloneWindow.hostingView(
            SettingsView(store: settings, section: .general, usageStore: usage, approximateGlass: true))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let hosting = try #require(window.contentView)
        hosting.superview?.layoutSubtreeIfNeeded()
        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
        }
        let scroll = try #require(scrollViews(in: hosting).first { ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height + 100 })
        let document = try #require(scroll.documentView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.height - scroll.contentView.bounds.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(scroll.contentView.bounds.minY > 100)
    }

    @MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["SG_PREVIEW_DIR"] != nil))
    func r8NativeWindowPreviews() throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["SG_PREVIEW_DIR"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = SettingsStore(url: directory.appendingPathComponent("native-settings-unused-fixture.json"))
        let usage = AIUsageStore(applyDisplayFilters: false, fetcher: { _ in throw AIUsageError.signedOut })
        usage.snapshots = UsageSnapshotFixture.snapshots
        for size in [NSSize(width: 680, height: 460), NSSize(width: 960, height: 680)] {
            let window = StandaloneWindow.make(size: size)
            defer { window.close() }
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = StandaloneWindow.hostingView(
                SettingsView(store: settings, usageStore: usage, approximateGlass: true)
                    .environment(\.appTheme, .light).environment(\.colorScheme, .light))
            window.setContentSize(size)
            try Self.cacheWindow(window, size: size, to: directory.appendingPathComponent("settings-window-\(Int(size.width))x\(Int(size.height)).png"))
        }
        let panel = AIUsagePanel()
        defer { panel.close() }
        let height = AIUsagePopoverView.height(for: 3)
        panel.setContentSize(NSSize(width: AIUsagePopoverView.width, height: height))
        panel.appearance = NSAppearance(named: .aqua)
        panel.contentView = NSHostingView(rootView: AIUsagePopoverView(store: usage, now: UsageSnapshotFixture.now,
            height: height, onOpenUsage: {}, scrollable: false, themeOverride: .light, approximateGlass: true))
        try Self.cacheWindow(panel, size: NSSize(width: AIUsagePopoverView.width, height: height), to: directory.appendingPathComponent("panel-light.png"))
    }

    /// Capture the frame view, including AppKit's actual titlebar buttons, entirely offscreen.
    @MainActor static func cacheWindow(_ window: NSWindow, size: NSSize, to url: URL) throws {
        _ = NSApplication.shared
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        let frameView = try #require(window.contentView?.superview)
        frameView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        #expect(frameView.bounds.size == size)
        if window.styleMask.contains(.titled) {
            // The sandboxed test helper cannot activate. AppKit's native highlight state
            // preserves the real button colors for this offscreen window capture.
            for button: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(button)?.highlight(true)
            }
        }
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(frameView.bounds.width * 2), pixelsHigh: Int(frameView.bounds.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = frameView.bounds.size
        frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
        if window.styleMask.contains(.titled) {
            var red = 0, yellow = 0, green = 0
            for y in 0..<80 {
                for x in 0..<180 {
                    let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    if color.redComponent > 0.8 && color.greenComponent < 0.75 && color.blueComponent < 0.75 { red += 1 }
                    if color.redComponent > 0.8 && color.greenComponent > 0.75 && color.blueComponent < 0.5 { yellow += 1 }
                    if color.greenComponent > 0.8 && color.redComponent < 0.75 && color.blueComponent < 0.5 { green += 1 }
                }
            }
            #expect(red > 20 && yellow > 20 && green > 20, "Capture must include real native traffic lights")
        }
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}

private struct WindowLayoutProbe: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
