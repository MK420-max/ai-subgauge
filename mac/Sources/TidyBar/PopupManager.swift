import AppKit

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
    static let shared = PopupManager()
    let panel = AIUsagePanel()
    var kind: Kind? { panel.isVisible ? presentedKind : nil }
    private var presentedKind: Kind?
    var statusFrames: () -> [NSRect] = { [] }
    private weak var anchor: NSView?
    private var monitors: [Any] = []
    private var handledEvents: [EventID] = []

    private struct EventID: Equatable {
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

    static func screenPoint(_ event: NSEvent) -> NSPoint {
        event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? event.locationInWindow
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
            || Self.screenFrame(anchor)?.contains(point) == true
    }

    @discardableResult
    func handleEmptyClick(_ event: NSEvent, at point: NSPoint, onScannedItem: Bool, toggle: () -> Void) -> Bool {
        guard event.type == .leftMouseUp, !onScannedItem, !isStatusClick(at: point), consume(event) else { return false }
        toggle()
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
