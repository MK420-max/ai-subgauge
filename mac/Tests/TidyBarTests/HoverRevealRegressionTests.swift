import AppKit
import Testing
@testable import TidyBar

extension TidyBarTests {
    @MainActor @Test func ownStatusItemsNeverTriggerHoverReveal() {
        _ = NSApplication.shared
        let manager = PopupManager()
        // Quota, collection, spacer, group and widget providers share this path.
        let frames = [53.0, 24, 10, 40, 30].enumerated().map { index, width in
            NSRect(x: 100 + Double(index) * 100, y: 100, width: width, height: 24)
        }
        frames.forEach { frame in manager.registerStatusFrames { [frame] } }
        for frame in frames {
            for x in [frame.minX + 1, frame.midX, frame.maxX - 1] {
                var hover = HoverReveal()
                for now in [0.0, 0.4, 0.8, 1.2, 4] {
                    let reveal = hover.update(point: NSPoint(x: x, y: frame.midY), statusFrames: manager.statusFrames(),
                        popupKind: nil, lastStatusActionTime: nil, now: now, menuDepth: 0)
                    #expect(!reveal)
                    #expect(hover.hoverStarted == nil)
                }
            }
        }
    }

    @MainActor @Test func visiblePopupSurvivesHoverOnMenuBarBlank() {
        _ = NSApplication.shared
        let manager = PopupManager()
        defer { manager.dismiss() }
        for kind in [PopupManager.Kind.quota, .drawer, .search] {
            manager.present(kind, toggle: false) { _ in }
            var hover = HoverReveal()
            for now in [0.0, 0.4, 0.8, 1.2, 4] {
                if hover.update(point: NSPoint(x: 180, y: 110), statusFrames: manager.statusFrames(),
                    popupKind: manager.kind, lastStatusActionTime: nil, now: now, menuDepth: 0) {
                    manager.present(.drawer, toggle: false) { _ in }
                }
                #expect(manager.kind == kind)
                #expect(manager.panel.isVisible)
                #expect(hover.hoverStarted == nil)
            }
        }
    }

    @Test func blankAndThirdPartyHoverStillRevealExactlyOnce() {
        // Only this app's frames are excluded; third-party positions remain eligible.
        for point in [NSPoint(x: 180, y: 110), NSPoint(x: 250, y: 110)] {
            var hover = HoverReveal()
            var reveals = 0
            for now in [0.0, 0.4, 0.55, 0.8, 1.2, 1.6, 2.4, 4] {
                if hover.update(point: point, statusFrames: [NSRect(x: 100, y: 100, width: 53, height: 24)],
                    popupKind: now == 1.2 ? .drawer : nil, lastStatusActionTime: nil, now: now, menuDepth: 0) { reveals += 1 }
                #expect(reveals == (now > 0.55 ? 1 : 0))
            }
            // Leaving the menu bar resets the value in tick(), enabling a new visit.
            hover = HoverReveal()
            let initial = hover.update(point: point, statusFrames: [], popupKind: nil,
                lastStatusActionTime: nil, now: 5, menuDepth: 0)
            let nextVisit = hover.update(point: point, statusFrames: [], popupKind: nil,
                lastStatusActionTime: nil, now: 5.8, menuDepth: 0)
            #expect(!initial && nextVisit)
        }
    }

    @MainActor @Test func recentStatusActionDelaysHoverAndStartsFreshDwell() {
        _ = NSApplication.shared
        var now = 100.0
        let manager = PopupManager(now: { now })
        manager.recordStatusItemAction()
        #expect(manager.lastStatusActionTime == now)
        var hover = HoverReveal()
        for time in [100.0, 100.8, 100.999, 101, 101.4, 101.6, 102] {
            now = time
            let reveal = hover.update(point: NSPoint(x: 180, y: 110), statusFrames: [], popupKind: nil,
                lastStatusActionTime: manager.lastStatusActionTime, now: now, menuDepth: 0)
            #expect(reveal == (time == 101.6))
            if time < 101 { #expect(hover.hoverStarted == nil) }
        }
    }

    @MainActor @Test func hoverFramesFollowReorderingAndReleaseOldPositions() {
        _ = NSApplication.shared
        let manager = PopupManager()
        var quotaFrame = NSRect(x: 100, y: 100, width: 53, height: 24)
        var collectionFrame = NSRect(x: 200, y: 100, width: 24, height: 24)
        manager.registerStatusFrames { [quotaFrame] }
        manager.registerStatusFrames { [collectionFrame] }
        quotaFrame.origin.x = 300
        collectionFrame.origin.x = 400
        for (x, expected) in [(110.0, true), (210, true), (310, false), (410, false)] {
            var hover = HoverReveal()
            let initial = hover.update(point: NSPoint(x: x, y: 110), statusFrames: manager.statusFrames(),
                popupKind: nil, lastStatusActionTime: nil, now: 0, menuDepth: 0)
            #expect(!initial)
            let afterDwell = hover.update(point: NSPoint(x: x, y: 110), statusFrames: manager.statusFrames(),
                popupKind: nil, lastStatusActionTime: nil, now: 0.8, menuDepth: 0)
            #expect(afterDwell == expected)
        }
        // A status item moving under an already dwelling cursor cancels that dwell.
        var hover = HoverReveal()
        let initial = hover.update(point: NSPoint(x: 510, y: 110), statusFrames: manager.statusFrames(),
            popupKind: nil, lastStatusActionTime: nil, now: 0, menuDepth: 0)
        #expect(!initial)
        quotaFrame.origin.x = 500
        let afterMove = hover.update(point: NSPoint(x: 510, y: 110), statusFrames: manager.statusFrames(),
            popupKind: nil, lastStatusActionTime: nil, now: 0.8, menuDepth: 0)
        #expect(!afterMove)
        #expect(hover.hoverStarted == nil)
    }

    @MainActor @Test func hoverUsesLiveAXFramesWhenConvertedFrameIsMissing() {
        _ = NSApplication.shared
        let manager = PopupManager()
        let button = HoverAXFrameButton(frame: .zero)
        button.axFrame = NSRect(x: 100, y: 100, width: 53, height: 24)
        _ = manager.registerStatusButton(button)
        #expect(PopupManager.screenFrame(button) == nil)
        for x in [100.0, 300] {
            button.axFrame.origin.x = x
            var hover = HoverReveal()
            for now in [0.0, 0.8, 2] {
                let reveal = hover.update(point: NSPoint(x: x + 10, y: 110), statusFrames: manager.statusFrames(),
                    popupKind: nil, lastStatusActionTime: nil, now: now, menuDepth: 0)
                #expect(!reveal)
            }
        }
        var hover = HoverReveal()
        let initial = hover.update(point: NSPoint(x: 110, y: 110), statusFrames: manager.statusFrames(),
            popupKind: nil, lastStatusActionTime: nil, now: 0, menuDepth: 0)
        #expect(!initial)
        let afterMove = hover.update(point: NSPoint(x: 110, y: 110), statusFrames: manager.statusFrames(),
            popupKind: nil, lastStatusActionTime: nil, now: 0.8, menuDepth: 0)
        #expect(afterMove)
    }

    @Test func trackingMenuCancelsHoverUntilFreshDwell() {
        var hover = HoverReveal()
        for (now, depth) in [(0.0, 0), (0.4, 1), (0.8, 2), (1.2, 1), (1.6, 0), (2, 0), (2.4, 0)] {
            let reveal = hover.update(point: NSPoint(x: 180, y: 110), statusFrames: [], popupKind: nil,
                lastStatusActionTime: nil, now: now, menuDepth: depth)
            #expect(reveal == (now == 2.4))
            if depth > 0 { #expect(hover.hoverStarted == nil) }
        }
    }
}

@MainActor
private final class HoverAXFrameButton: NSButton {
    var axFrame = NSRect.zero
    override func accessibilityFrame() -> NSRect { axFrame }
}
