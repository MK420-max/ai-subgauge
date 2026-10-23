import AppKit
import os

/// currentEvent can outlive sendEvent (including during AXPress). Only this scope
/// identifies an event that is actually dispatching a button action now.
@MainActor
final class StatusItemApplication: NSApplication {
    private static var eventSource: (() -> NSEvent?)?
    static var actionEvent: NSEvent? { eventSource?() }

    override func sendEvent(_ event: NSEvent) {
        // NSButton may fetch mouse-up in its tracking loop while sendEvent is
        // still handling mouse-down. Read that current event only inside dispatch.
        Self.dispatch(event, currentEvent: { self.currentEvent ?? event }) { super.sendEvent(event) }
    }

    static func dispatch(_ event: NSEvent, currentEvent: (() -> NSEvent?)? = nil, action: () -> Void) {
        let previous = eventSource
        let startingEvent = currentEvent?()
        eventSource = {
            guard let tracked = currentEvent?(), tracked !== startingEvent else { return event }
            return tracked
        }
        defer { eventSource = previous }
        action()
    }
}

/// One physical panel and one dismissal lifecycle for quota, collection and search.
@MainActor
final class PopupManager {
    enum Kind { case quota, drawer, search }
    enum EventSource: String { case local, global }
    static let shared = PopupManager()
    nonisolated static let emptyClickDelay: TimeInterval = 0.15
    private static let emptyClickLogger = Logger(subsystem: "com.mike.aisubgauge", category: "emptyClick")
    let panel = AIUsagePanel()
    var kind: Kind? { panel.isVisible ? presentedKind : nil }
    private var presentedKind: Kind?
    private var statusFrameProviders: [UUID: () -> [NSRect]] = [:]
    private weak var anchor: NSView?
    private var monitors: [Any] = []
    private var handledEvents: [EventID] = []
    private var pendingEmptyClicks: Set<EventID> = []
    private var statusActionGeneration = 0
    private(set) var lastStatusActionTime: TimeInterval?
    private let now: () -> TimeInterval
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, action in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay) { action() }
         }) {
        self.now = now
        self.schedule = schedule
    }

    private struct EventID: Hashable {
        let number: Int
        let timestamp: TimeInterval
        init(_ event: NSEvent) {
            number = event.eventNumber; timestamp = event.timestamp
        }
    }

    static func screenFrame(_ view: NSView?) -> NSRect? {
        guard let view, let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    static func statusButtonFrames(_ view: NSView?) -> [NSRect] {
        guard let view else { return [] }
        // Both AppKit's conversion and AX use screen coordinates. Hosted status
        // items may expose the correct position only through AX.
        return [screenFrame(view), view.accessibilityFrame()].compactMap { $0 }.filter { !$0.isEmpty }
    }

    static func screenPoint(_ event: NSEvent) -> NSPoint {
        event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? event.locationInWindow
    }

    @discardableResult
    func registerStatusFrames(_ provider: @escaping () -> [NSRect]) -> UUID {
        let id = UUID()
        statusFrameProviders[id] = provider
        return id
    }

    func unregisterStatusFrames(_ id: UUID) {
        statusFrameProviders[id] = nil
    }

    func registerStatusButton(_ button: NSView) -> UUID {
        registerStatusFrames { [weak button] in
            Self.statusButtonFrames(button)
        }
    }

    func recordStatusItemAction() {
        statusActionGeneration += 1
        lastStatusActionTime = now()
    }

    private static func isStatusWindow(_ window: NSWindow?) -> Bool {
        guard let window, let statusWindowClass = NSClassFromString("NSStatusBarWindow") else { return false }
        return window.isKind(of: statusWindowClass)
    }

    @discardableResult func consume(_ event: NSEvent?) -> Bool {
        guard let event, event.type == .leftMouseUp || event.type == .rightMouseUp else { return true }
        let id = EventID(event)
        guard !handledEvents.contains(id) else { return false }
        handledEvents.append(id)
        // Only explicit mouse events enter this cache. Independent AX/keyboard actions
        // have no mouse ID; no elapsed-time threshold suppresses a subsequent click.
        DispatchQueue.main.async { [weak self] in self?.handledEvents.removeAll { $0 == id } }
        return true
    }

    func isStatusClick(at point: NSPoint) -> Bool {
        statusFrames().contains { $0.contains(point) }
    }

    func statusFrames() -> [NSRect] {
        statusFrameProviders.values.flatMap { $0() } + Self.statusButtonFrames(anchor)
    }

    private func logEmptyClick(at point: NSPoint, source: EventSource, windowClass: String,
                               frames: [NSRect], onScannedItem: Bool, decision: String) {
        // Only geometry and class names are public. No titles, account data,
        // window descriptions or event payloads enter this diagnostic.
        let frameCoordinates = frames.map { NSStringFromRect($0) }.joined(separator: "; ")
        Self.emptyClickLogger.notice("point=\(NSStringFromPoint(point), privacy: .public) source=\(source.rawValue, privacy: .private) windowClass=\(windowClass, privacy: .public) frames=[\(frameCoordinates, privacy: .public)] onScannedItem=\(onScannedItem, privacy: .private) decision=\(decision, privacy: .private)")
    }

    /// Returns true when a blank-click candidate was queued, not when it toggled.
    @discardableResult
    func handleEmptyClick(_ event: NSEvent, at point: NSPoint, onScannedItem: Bool,
                          source: EventSource = .local, toggle: @escaping () -> Void) -> Bool {
        let frames = statusFrames()
        let windowClass = event.window.map { NSStringFromClass(type(of: $0)) } ?? "nil"
        let id = EventID(event)
        let decision: String
        if event.type != .leftMouseUp { decision = "skip-event-type" }
        else if onScannedItem { decision = "skip-scanned-item" }
        else if Self.isStatusWindow(event.window) { decision = "skip-status-window" }
        else if frames.contains(where: { $0.contains(point) }) { decision = "skip-status-frame" }
        else if let lastStatusActionTime, now() - lastStatusActionTime <= Self.emptyClickDelay { decision = "skip-recent-status-action" }
        else if handledEvents.contains(id) || pendingEmptyClicks.contains(id) { decision = "skip-duplicate-event" }
        else { decision = "defer" }
        logEmptyClick(at: point, source: source, windowClass: windowClass,
                      frames: frames, onScannedItem: onScannedItem, decision: decision)
        guard decision == "defer" else { return false }

        // Keep this separate from consume: a local/global monitor can arrive
        // before the button action, which must still be allowed to run.
        pendingEmptyClicks.insert(id)
        let generation = statusActionGeneration
        schedule(Self.emptyClickDelay) { [weak self] in
            guard let self else { return }
            self.pendingEmptyClicks.remove(id)
            let currentFrames = self.statusFrames()
            let finalDecision: String
            if self.statusActionGeneration != generation { finalDecision = "cancel-status-action" }
            else if currentFrames.contains(where: { $0.contains(point) }) { finalDecision = "cancel-status-frame" }
            else if !self.consume(event) { finalDecision = "cancel-consumed-event" }
            else { finalDecision = "toggle" }
            self.logEmptyClick(at: point, source: source, windowClass: windowClass,
                              frames: currentFrames, onScannedItem: onScannedItem, decision: finalDecision)
            if finalDecision == "toggle" { toggle() }
        }
        return true
    }

    func present(_ kind: Kind, anchor: NSView? = nil, event: NSEvent? = nil,
                 toggle: Bool = true, prepare: (AIUsagePanel) -> Void) {
        guard consume(event) else { return }
        if toggle, let visibleKind = self.kind, self.anchor === anchor,
           anchor != nil || visibleKind == kind { dismiss(); return }
        dismiss()
        presentedKind = kind
        self.anchor = anchor
        prepare(panel)
        panel.onDismiss = { [weak self] in self?.dismiss() }
        panel.makeKeyAndOrderFront(nil)
        installMonitors()
    }

    func dismiss(_ kind: Kind? = nil) {
        if let kind, presentedKind != kind { return }
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        panel.orderOut(nil)
        presentedKind = nil
        panel.onDismiss = nil
        anchor = nil
    }

    func dismissForClick(at point: NSPoint) {
        guard panel.isVisible, !panel.frame.contains(point), !isStatusClick(at: point) else { return }
        dismiss()
    }

    func dismissForClick(_ event: NSEvent) {
        guard !Self.isStatusWindow(event.window) else { return }
        dismissForClick(at: Self.screenPoint(event))
    }

    private func installMonitors() {
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] event in
            self?.dismissForClick(event)
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [clicks, .keyDown], handler: { [weak self] event in
            if event.type == .keyDown {
                if event.keyCode == 53 { self?.dismiss(); return nil }
            } else { self?.dismissForClick(event) }
            return event
        }) { monitors.append(monitor) }
    }
}
