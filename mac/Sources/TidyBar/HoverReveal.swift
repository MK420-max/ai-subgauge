import Foundation

/// Hover timing uses the same monotonic clock as status-item actions.
struct HoverReveal {
    private(set) var hoverStarted: TimeInterval?
    private var wasHovering = false

    mutating func update(point: NSPoint, statusFrames: [NSRect], popupKind: PopupManager.Kind?,
                         lastStatusActionTime: TimeInterval?, now: TimeInterval, menuDepth: Int) -> Bool {
        guard menuDepth == 0, popupKind == nil,
              !statusFrames.contains(where: { $0.contains(point) }),
              lastStatusActionTime.map({ now - $0 >= 1 }) ?? true else {
            hoverStarted = nil
            return false
        }
        // Preserve the once-per-visit latch across popup visibility changes.
        // The caller resets this value when the cursor leaves the menu bar.
        guard !wasHovering else { return false }
        if hoverStarted == nil { hoverStarted = now }
        guard let hoverStarted, now - hoverStarted > 0.55 else { return false }
        wasHovering = true
        return true
    }
}
