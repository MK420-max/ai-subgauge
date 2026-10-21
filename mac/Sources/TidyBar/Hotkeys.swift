import AppKit
import Carbon
import SwiftUI

@MainActor
final class HotkeyController: ObservableObject {
    static weak var shared: HotkeyController?
    @Published var error: String?
    private var references: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var actions: [UInt32: () -> Void] = [:]
    private let store: SettingsStore
    private let engine: MenuEngine
    private var previous: AppConfig?
    private var recording = false

    init(store: SettingsStore, engine: MenuEngine) {
        self.store = store; self.engine = engine; Self.shared = self
        var specification = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var key = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
            guard result == noErr else { return result }
            let owner = Unmanaged<HotkeyController>.fromOpaque(context).takeUnretainedValue()
            let id = key.id
            DispatchQueue.main.async { owner.actions[id]?() }
            return noErr
        }, 1, &specification, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func update() {
        guard !recording else { return }
        let config = store.config
        if let previous, previous.hotkeyCode == config.hotkeyCode, previous.hotkeyModifiers == config.hotkeyModifiers,
           previous.searchHotkeyCode == config.searchHotkeyCode, previous.searchHotkeyModifiers == config.searchHotkeyModifiers,
           previous.presetHotkeys == config.presetHotkeys, previous.itemHotkeys == config.itemHotkeys,
           previous.presets == config.presets { return }
        previous = config
        unregister()
        error = nil
        register(id: 1, key: config.hotkeyCode, modifiers: config.hotkeyModifiers, name: L10n.text("shortcuts.expand.collapse")) { AppActions.shared.toggle() }
        register(id: 2, key: config.searchHotkeyCode, modifiers: config.searchHotkeyModifiers, name: L10n.text("shortcuts.search.icons")) { AppActions.shared.showSearch() }
        var index: UInt32 = 100
        for preset in config.presets {
            if let binding = config.presetHotkeys[preset.id.uuidString] {
                register(id: index, key: binding.keyCode, modifiers: binding.modifiers, name: L10n.text("shortcuts.preset.0", preset.name)) { [weak self] in
                    guard let self, let latest = self.store.config.presets.first(where: { $0.id == preset.id }) else { return }
                    self.store.applyPreset(latest)
                }
                index += 1
            }
        }
        for (id, binding) in config.itemHotkeys.sorted(by: { $0.key < $1.key }) {
            register(id: index, key: binding.keyCode, modifiers: binding.modifiers, name: L10n.text("shortcuts.icon.shortcut")) { [weak self] in
                guard let self, let entry = self.engine.items.first(where: { $0.id == id }) else { return }
                self.engine.activate(entry)
            }
            index += 1
        }
    }

    func suspendForRecording() {
        guard !recording else { return }
        recording = true
        unregister()
    }

    func resumeAfterRecording() {
        guard recording else { return }
        recording = false
        previous = nil
        update()
    }

    private func register(id: UInt32, key: UInt32, modifiers: UInt32, name: String, action: @escaping () -> Void) {
        guard modifiers != 0 else { return }
        var reference: EventHotKeyRef?
        let result = RegisterEventHotKey(key, modifiers, EventHotKeyID(signature: 0x4D544944, id: id), GetApplicationEventTarget(), 0, &reference)
        if result == noErr, let reference { references.append(reference); actions[id] = action }
        else { error = L10n.text("shortcuts.could.not.register.0.the.shortcut.may", name, result) }
    }

    private func unregister() {
        references.forEach { UnregisterEventHotKey($0) }; references.removeAll(); actions.removeAll()
    }
    func stop() { unregister(); if let handler { RemoveEventHandler(handler) }; handler = nil }
}

struct HotkeySettingsView: View {
    @ObservedObject var store: SettingsStore
    var body: some View {
        Form {
            Section(L10n.text("shortcuts.global.shortcuts")) {
                shortcutRow(L10n.text("shortcuts.expand.collapse.collection.bar"), id: "global.toggle", binding: Binding(get: { Shortcut(keyCode: store.config.hotkeyCode, modifiers: store.config.hotkeyModifiers) }, set: { store.config.hotkeyCode = $0.keyCode; store.config.hotkeyModifiers = $0.modifiers }))
                shortcutRow(L10n.text("shortcuts.search.all.menu.bar.icons"), id: "global.search", binding: Binding(get: { Shortcut(keyCode: store.config.searchHotkeyCode, modifiers: store.config.searchHotkeyModifiers) }, set: { store.config.searchHotkeyCode = $0.keyCode; store.config.searchHotkeyModifiers = $0.modifiers }))
                Text(L10n.text("shortcuts.click.the.shortcut.field.and.press.a")).font(.caption).foregroundStyle(.secondary)
                if let controller = HotkeyController.shared { HotkeyStatusView(controller: controller) }
            }
            Section(L10n.text("shortcuts.preset.shortcuts")) {
                if store.config.presets.isEmpty { Text(L10n.text("shortcuts.save.a.preset.to.assign.a.switching")).foregroundStyle(.secondary) }
                ForEach(store.config.presets) { preset in
                    shortcutRow(preset.name, id: "preset.\(preset.id.uuidString)", binding: Binding(get: { store.config.presetHotkeys[preset.id.uuidString] ?? Shortcut(keyCode: 0, modifiers: 0) }, set: { store.config.presetHotkeys[preset.id.uuidString] = $0 }))
                }
            }
            Section(L10n.text("shortcuts.individual.icon.shortcuts")) {
                if let engine = AppActions.shared.engine {
                    ForEach(engine.items) { entry in
                        shortcutRow(entry.name, id: "item.\(entry.id)", binding: Binding(get: { store.config.itemHotkeys[entry.id] ?? Shortcut(keyCode: 0, modifiers: 0) }, set: { store.config.itemHotkeys[entry.id] = $0 }))
                    }
                }
                Text(L10n.text("shortcuts.temporarily.show.and.open.this.icon.directly")).font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    private func shortcutRow(_ name: String, id: String, binding: Binding<Shortcut>) -> some View {
        HStack {
            Text(name).accessibilityIdentifier("shortcut-row.\(id)")
            Spacer()
            ShortcutRecorder(shortcut: binding, identifier: id, name: name).frame(width: 150, height: 28)
            Button(L10n.text("shortcuts.clear")) { binding.wrappedValue.modifiers = 0 }.buttonStyle(.borderless)
                .accessibilityIdentifier("shortcut-clear.\(id)")
                .accessibilityLabel(L10n.text("shortcuts.clear.the.shortcut.for.0", name))
        }
    }
}

private struct HotkeyStatusView: View {
    @ObservedObject var controller: HotkeyController
    var body: some View {
        if let error = controller.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
        else { Label(L10n.text("shortcuts.shortcut.active"), systemImage: "checkmark.circle").foregroundStyle(.secondary) }
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: Shortcut
    let identifier: String
    let name: String
    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.target = button
        button.action = #selector(RecorderButton.beginRecording(_:))
        button.setAccessibilityIdentifier("shortcut-recorder.\(identifier)")
        button.setAccessibilityLabel(L10n.text("shortcuts.set.the.shortcut.for.0", name))
        button.setAccessibilityHelp(L10n.text("shortcuts.press.the.button.to.record.press.escape"))
        button.change = { shortcut = $0 }
        return button
    }
    func updateNSView(_ view: RecorderButton, context: Context) {
        view.setAccessibilityIdentifier("shortcut-recorder.\(identifier)")
        view.setAccessibilityLabel(L10n.text("shortcuts.set.the.shortcut.for.0", name))
        view.shortcut = shortcut
        view.change = { shortcut = $0 }
        if !view.recording { view.title = Self.label(shortcut) }
    }

    static func label(_ shortcut: Shortcut) -> String {
        guard shortcut.modifiers != 0 else { return L10n.text("shortcuts.not.set") }
        let modifiers = shortcut.modifiers
        let prefix = (modifiers & UInt32(controlKey) != 0 ? "⌃" : "") + (modifiers & UInt32(optionKey) != 0 ? "⌥" : "") + (modifiers & UInt32(shiftKey) != 0 ? "⇧" : "") + (modifiers & UInt32(cmdKey) != 0 ? "⌘" : "")
        let keys: [UInt32: String] = [0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"−",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",36:"↩",37:"L",38:"J",39:"'",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",47:".",48:"⇥",49:L10n.text("shortcuts.space"),50:"`",51:"⌫",53:"⎋",122:"F1",120:"F2",99:"F3",118:"F4",96:"F5",97:"F6",98:"F7",100:"F8",101:"F9",109:"F10",103:"F11",111:"F12",123:"←",124:"→",125:"↓",126:"↑"]
        return prefix + (keys[shortcut.keyCode] ?? L10n.text("shortcuts.key.0", shortcut.keyCode))
    }
}

private final class RecorderButton: NSButton {
    var shortcut = Shortcut(keyCode: 0, modifiers: 0)
    var change: ((Shortcut) -> Void)?
    var recording = false
    private var resignKeyObserver: NSObjectProtocol?
    deinit {
        if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
    }
    override var acceptsFirstResponder: Bool { true }
    @objc func beginRecording(_ sender: Any?) {
        guard !recording, window?.makeFirstResponder(self) == true else { return }
        HotkeyController.shared?.suspendForRecording()
        recording = true
        title = L10n.text("shortcuts.press.a.shortcut")
        if let window {
            resignKeyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finishRecording() }
            }
        }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }
    override func resignFirstResponder() -> Bool {
        finishRecording()
        return super.resignFirstResponder()
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { finishRecording() }
        super.viewWillMove(toWindow: newWindow)
    }
    private func finishRecording() {
        if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
        resignKeyObserver = nil
        guard recording else { return }
        recording = false
        title = ShortcutRecorder.label(shortcut)
        HotkeyController.shared?.resumeAfterRecording()
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { window?.makeFirstResponder(nil); return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .option, .control]).isEmpty else { title = L10n.text("shortcuts.include.or"); return }
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        shortcut = Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        change?(shortcut)
        finishRecording()
        window?.makeFirstResponder(nil)
    }
}
