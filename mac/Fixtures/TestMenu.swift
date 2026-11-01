import AppKit

final class FixtureDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var item: NSStatusItem!
    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "TidyBarTestFixture"
        item.button?.title = "收纳测试"
        item.button?.toolTip = "仅用于Mac菜单栏收纳的实机验收"
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "测试菜单已打开", action: nil, keyEquivalent: "")
        let quit = NSMenuItem(title: "退出测试图标", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu.addItem(quit)
        item.menu = menu
        record("launched")
    }
    func menuWillOpen(_ menu: NSMenu) {
        record("menu-opened")
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { menu.cancelTracking() }
    }
    func menuDidClose(_ menu: NSMenu) { record("menu-closed") }
    private func record(_ event: String) {
        let url = URL(fileURLWithPath: "/tmp/macmenutidy-fixture-events.jsonl")
        let data = ("{\"event\":\"\(event)\",\"time\":\"\(ISO8601DateFormatter().string(from: Date()))\"}\n").data(using: .utf8)!
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: url) { defer { try? handle.close() }; _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data) }
    }
}

let application = NSApplication.shared
let delegate = FixtureDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
