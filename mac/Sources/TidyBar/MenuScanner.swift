import AppKit
import ApplicationServices
import MenuBarShim

struct MenuEntry: Identifiable {
    var id: String
    var bundleID: String
    var name: String
    var title: String
    var frame: CGRect
    var icon: NSImage?
    var isRunning: Bool
    var canMove: Bool
}

/// All AX calls run on MenuEngine's serial worker, including interaction.
final class MenuScanner: @unchecked Sendable {
    struct Snapshot {
        var items: [MenuEntry]
        var hasActiveMenu: Bool
        var freshIDs: Set<String> = []
        var hostedIDs: Set<String> = []
        var systemOverflowIDs: Set<String> = []
    }
    private var elements: [String: AXUIElement] = [:]
    private var lastEntries: [String: MenuEntry] = [:]
    private var lastHostedIDs = Set<String>()
    private var ownerPIDs = Set<pid_t>()
    private var checkedPIDs = Set<pid_t>()
    private var extraOwnerPIDs = Set<pid_t>()
    private var lastFullSweep = Date.distantPast
    private let menuStateLock = NSLock()
    private var lastMenuState = false
    private var lastMenuProbe: Date?
    private var lastMenuEvidence: [String: Any] = [:]
    private var lastActivationProbe: [String: Any] = [:]
    var ownStatusFrames: [CGRect] = []
    private var lastHostDiagnostic: [String: Any] = [:]
    private var lastGeometryEvidence: [String: [[String: Any]]] = [:]

    func scan(probeActiveMenu: Bool = true) -> Snapshot {
        guard AXIsProcessTrusted() else { elements.removeAll(); lastEntries.removeAll(); lastHostedIDs.removeAll(); ownerPIDs.removeAll(); return Snapshot(items: [], hasActiveMenu: false) }
        let apps = NSWorkspace.shared.runningApplications
        let byPID = Self.applicationsByPID(apps)
        var found: [String: MenuEntry] = [:]
        var ax: [String: AXUIElement] = [:]
        var counts: [String: Int] = [:]
        var hostedIDs = Set<String>()
        var geometryEvidence: [String: [[String: Any]]] = [:]
        var systemOverflowIDs = Set<String>()
        let requiresHostedSlot = true
        func append(_ element: AXUIElement, owner: NSRunningApplication, fallbackFrame: CGRect? = nil, forceZeroFrame: Bool = false, hostEvidence: [String: Any]? = nil) {
            guard let bundle = owner.bundleIdentifier, text(element, "AXRole") != "AXApplication" else { return }
            AXUIElementSetMessagingTimeout(element, 0.2)
            let identifier = text(element, "AXIdentifier")
            let label = [text(element, "AXTitle"), text(element, "AXDescription"), text(element, "AXHelp")].first { !$0.isEmpty } ?? ""
            let stable = identifier.isEmpty || identifier.hasPrefix("_NS:") ? "状态图标" : identifier
            let base = bundle + "::" + stable
            let sourceFrame = rect(element)
            if var evidence = hostEvidence {
                evidence["sourceAXFrame"] = sourceFrame.map(NSStringFromRect) ?? "unavailable"
                evidence["sourceAXRole"] = text(element, "AXRole")
                geometryEvidence[base, default: []].append(evidence)
            }
            var frame = fallbackFrame ?? sourceFrame ?? .zero
            if !isInMenuBar(frame) { frame = fallbackFrame.flatMap { isInMenuBar($0) ? $0 : nil } ?? .zero }
            if forceZeroFrame { frame = .zero }
            if let existing = found[base], (!identifier.isEmpty || existing.frame.intersects(frame)) {
                if fallbackFrame != nil { hostedIDs.insert(base) }
                return
            }
            let count = counts[base, default: 0]
            counts[base] = count + 1
            let id = count == 0 ? base : base + "::" + String(count)
            found[id] = MenuEntry(id: id, bundleID: bundle, name: (["com.apple.MenuBarAgent", "com.apple.systemuiserver"].contains(bundle) && !label.isEmpty) ? label : owner.localizedName ?? bundle,
                                  title: label, frame: frame, icon: owner.icon,
                                  isRunning: !owner.isTerminated, canMove: !identifier.isEmpty)
            ax[id] = element
            if hostEvidence != nil && forceZeroFrame { systemOverflowIDs.insert(id) }
            if fallbackFrame != nil { hostedIDs.insert(id) }
        }
        // On macOS 27, MenuBarAgent hosts the bar and its slot's content belongs to the source app.
        if let agent = apps.first(where: { $0.bundleIdentifier == "com.apple.MenuBarAgent" }) {
            let appAX = AXUIElementCreateApplication(agent.processIdentifier)
            AXUIElementSetMessagingTimeout(appAX, 0.25)
            let windows = children(appAX, attribute: "AXWindows")
            var hosts: [(index: Int, frame: CGRect, slots: [(element: AXUIElement, frame: CGRect, content: AXUIElement?, pid: pid_t)])] = []
            for (index, window) in windows.enumerated() {
                guard let windowFrame = rect(window) else { continue }
                let slots = children(window).compactMap { slot -> (AXUIElement, CGRect, AXUIElement?, pid_t)? in
                    guard let frame = rect(slot), frame.width > 0, frame.height > 0 else { return nil }
                    let content = children(slot).first
                    var pid: pid_t = 0
                    if let content { AXUIElementGetPid(content, &pid) }
                    return (slot, frame, content, pid)
                }
                hosts.append((index, windowFrame, slots))
            }
            var selected = Set<Int>()
            var displays = [CGDirectDisplayID](repeating: 0, count: 32)
            var count: UInt32 = 0
            if CGGetActiveDisplayList(UInt32(displays.count), &displays, &count) == .success {
                for display in displays.prefix(Int(count)) {
                    let screen = CGDisplayBounds(display)
                    let onScreen = hosts.filter { $0.frame.intersects(screen) }
                    let layouts = Dictionary(uniqueKeysWithValues: onScreen.map { ($0.index, $0.slots.map { HostedSlotGeometry(pid: $0.pid, frame: $0.frame) }) })
                    let ownSlots = Dictionary(uniqueKeysWithValues: onScreen.map { ($0.index, $0.slots.filter { $0.pid == ProcessInfo.processInfo.processIdentifier }.map { $0.frame }) })
                    if let index = Self.selectHostedWindow(layouts: layouts, ownSlots: ownSlots, ownFrames: ownStatusFrames) { selected.insert(index) }
                }
            }
            let cgWindows = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
                .filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == agent.processIdentifier }
            func windowFields(_ window: [String: Any]) -> [String: Any] {
                ["windowID": window[kCGWindowNumber as String] ?? -1, "onScreen": window[kCGWindowIsOnscreen as String] ?? false,
                 "layer": window[kCGWindowLayer as String] ?? -1, "alpha": window[kCGWindowAlpha as String] ?? -1,
                 "bounds": window[kCGWindowBounds as String] ?? [:], "ownerPID": agent.processIdentifier]
            }
            let hostFields: [[String: Any]] = hosts.map { host in
                let privateWindow = STMenuBarShim.windowDiagnostics(for: windows[host.index])
                let windowID = (privateWindow["windowID"] as? NSNumber)?.uint32Value
                let match = cgWindows.first { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID }
                return ["index": host.index, "frame": NSStringFromRect(host.frame), "selected": selected.contains(host.index),
                 "rawGeometry": rawGeometry(windows[host.index]), "role": text(windows[host.index], "AXRole"),
                 "hidden": (value(windows[host.index], "AXHidden") as? NSNumber).map { String($0.boolValue) } ?? "unavailable",
                 "focused": (value(windows[host.index], "AXFocused") as? NSNumber).map { String($0.boolValue) } ?? "unavailable",
                 "windowNumber": (value(windows[host.index], "AXWindowNumber") as? NSNumber)?.intValue ?? -1,
                 "privateWindow": privateWindow, "cgWindow": match.map(windowFields) ?? ["matched": false],
                 "slots": host.slots.map { slot -> [String: Any] in
                    ["pid": slot.pid, "frame": NSStringFromRect(slot.frame), "rawGeometry": rawGeometry(slot.element),
                     "role": text(slot.element, "AXRole"), "contentRole": slot.content.map { text($0, "AXRole") } ?? "none",
                     "sourceAXFrame": slot.content.flatMap { rect($0) }.map(NSStringFromRect) ?? "unavailable",
                     "overflowButton": slot.content == nil ? ["title": text(slot.element, "AXTitle"), "description": text(slot.element, "AXDescription"),
                         "identifier": text(slot.element, "AXIdentifier"), "expanded": (value(slot.element, "AXExpanded") as? NSNumber)?.intValue ?? -1,
                         "value": (value(slot.element, "AXValue") as? NSNumber)?.intValue ?? -1] : [:]]
                 }]
            }
            menuStateLock.lock()
            lastHostDiagnostic = ["ownStatusFrame": ownStatusFrames.first.map(NSStringFromRect) ?? "unavailable",
                                  "ownStatusFrames": ownStatusFrames.map(NSStringFromRect), "windows": hostFields,
                                  "agentCGWindows": cgWindows.map(windowFields)]
            menuStateLock.unlock()
            for host in hosts where selected.contains(host.index) {
                let chevron = host.slots.first { $0.content == nil || $0.pid == 0 }?.frame
                for (slotIndex, slot) in host.slots.enumerated() {
                    guard let content = slot.content, let owner = byPID[slot.pid] else { continue }
                    let otherFrames = host.slots.enumerated().filter { $0.offset != slotIndex }.map { $0.element.frame }
                    let actionable = Self.hostedSlotIsDistinct(slot.frame, others: otherFrames)
                    let evidence: [String: Any] = ["hostIndex": host.index, "hostFrame": NSStringFromRect(host.frame), "slotIndex": slotIndex,
                        "slotFrame": NSStringFromRect(slot.frame), "slotRawGeometry": rawGeometry(slot.element),
                        "distinctSlot": actionable, "overflowChevron": chevron.map(NSStringFromRect) ?? "none",
                        "leftOfChevron": chevron.map { slot.frame.minX < $0.minX } ?? false]
                    if text(content, "AXRole") == "AXApplication" {
                        guard let extras = element(content, "AXExtrasMenuBar") else { continue }
                        let candidates = children(extras).filter { text($0, "AXRole") != "AXApplication" }
                        if candidates.count == 1, let candidate = candidates.first {
                            append(candidate, owner: owner, fallbackFrame: actionable ? slot.frame : nil, forceZeroFrame: !actionable, hostEvidence: evidence)
                        } else {
                            let matches = candidates.filter { candidate in
                                guard let frame = rect(candidate) else { return false }
                                return frame.intersection(slot.frame).width > min(frame.width, slot.frame.width) * 0.5
                            }
                            if matches.count == 1, let candidate = matches.first { append(candidate, owner: owner, fallbackFrame: actionable ? slot.frame : nil, forceZeroFrame: !actionable, hostEvidence: evidence) }
                        }
                        continue
                    }
                    let candidate = slot.pid == agent.processIdentifier ? (children(content).first ?? content) : content
                    guard text(candidate, "AXRole") != "AXApplication" else { continue }
                    append(candidate, owner: owner, fallbackFrame: actionable ? slot.frame : nil, forceZeroFrame: !actionable, hostEvidence: evidence)
                }
            }
        }
        let hostedBundles = Set(found.values.map(\.bundleID))
        let fullSweep = Date().timeIntervalSince(lastFullSweep) > 45
        if fullSweep { lastFullSweep = Date() }
        let livePIDs = Set(apps.map(\.processIdentifier))
        checkedPIDs.formIntersection(livePIDs)
        extraOwnerPIDs.formIntersection(livePIDs)
        for app in apps {
            guard let bundle = app.bundleIdentifier, !hostedBundles.contains(bundle) else { continue }
            guard fullSweep || !checkedPIDs.contains(app.processIdentifier) || extraOwnerPIDs.contains(app.processIdentifier) else { continue }
            checkedPIDs.insert(app.processIdentifier)
            let appAX = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appAX, 0.15)
            guard let extras = element(appAX, "AXExtrasMenuBar") else { continue }
            extraOwnerPIDs.insert(app.processIdentifier)
            let entries = children(extras)
            if entries.isEmpty {
                let id = bundle + "::应用菜单栏图标"
                found[id] = MenuEntry(id: id, bundleID: bundle, name: app.localizedName ?? bundle,
                                      title: L10n.text("layout.app.menu.bar.icon.no.clickable.position"), frame: .zero,
                                      icon: app.icon, isRunning: true, canMove: false)
            } else { for item in entries { append(item, owner: app, forceZeroFrame: requiresHostedSlot) } }
        }
        // Keep hidden identities while their owner is alive; no stale coordinates may be clicked.
        let runningBundles = Set(apps.compactMap(\.bundleIdentifier))
        let freshOwnerBundles = Set(found.values.filter { ax[$0.id] != nil }.map(\.bundleID))
        for (id, old) in lastEntries where found[id] == nil && runningBundles.contains(old.bundleID) && !freshOwnerBundles.contains(old.bundleID) {
            var cached = old
            cached.frame = .zero
            found[id] = cached
        }
        elements = ax
        lastHostedIDs = hostedIDs
        lastGeometryEvidence = geometryEvidence
        lastEntries = found
        ownerPIDs = Set(found.values.compactMap { entry in apps.first { $0.bundleIdentifier == entry.bundleID }?.processIdentifier })
        return Snapshot(items: found.values.sorted { lhs, rhs in
            if lhs.frame.minY != rhs.frame.minY { return lhs.frame.minY < rhs.frame.minY }
            if lhs.frame.minX != rhs.frame.minX { return lhs.frame.minX < rhs.frame.minX }
            return lhs.id < rhs.id
        }, hasActiveMenu: probeActiveMenu ? hasActiveMenu() : false, freshIDs: Set(ax.keys), hostedIDs: hostedIDs, systemOverflowIDs: systemOverflowIDs)
    }

    // Workspace snapshots may contain the same process more than once.
    // Keep the first owner, consistent with the source ordering used elsewhere in this scan.
    static func applicationsByPID(_ applications: [NSRunningApplication]) -> [pid_t: NSRunningApplication] {
        Dictionary(applications.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func diagnosticSnapshot() -> [[String: Any]] {
        updateHostHitEvidence()
        return lastEntries.values.sorted { $0.id < $1.id }.map { entry in
            let ax = elements[entry.id]
            var pid: pid_t = 0
            var attributes: CFArray?
            if let ax { AXUIElementGetPid(ax, &pid); AXUIElementCopyAttributeNames(ax, &attributes) }
            let ownerItemCount = lastEntries.values.filter { $0.bundleID == entry.bundleID && elements[$0.id] != nil }.count
            return ["id": entry.id, "bundleID": entry.bundleID, "name": entry.name,
                    "title": entry.title, "frame": NSStringFromRect(entry.frame),
                    "sourcePID": pid, "axIdentifier": ax.map { text($0, "AXIdentifier") } ?? "",
                    "axRole": ax.map { text($0, "AXRole") } ?? "", "sourceAXFrame": ax.flatMap { rect($0) }.map(NSStringFromRect) ?? "unavailable",
                    "axTitle": ax.map { text($0, "AXTitle") } ?? "",
                    "axDescription": ax.map { text($0, "AXDescription") } ?? "",
                    "axHelp": ax.map { text($0, "AXHelp") } ?? "",
                    "axAttributes": attributes as? [String] ?? [], "ownerItemCount": ownerItemCount,
                    "identitySource": entry.id.contains("::状态图标") ? L10n.text("layout.app.identity.fallback") : L10n.text("layout.accessibility.identifier"),
                    "canMove": entry.canMove, "hasFreshAXElement": ax != nil, "hasCurrentHostedSlot": lastHostedIDs.contains(entry.id),
                    "geometryEvidence": lastGeometryEvidence[entry.id] ?? []]
        }
    }

    func activate(id: String) -> String? {
        _ = scan()
        guard let entry = lastEntries[id], let ax = elements[id], entry.frame.width > 0,
              !["AXApplication", "AXMenuBar", "AXMenu"].contains(text(ax, "AXRole")) else {
            return L10n.text("layout.the.icon.is.not.currently.in.a")
        }
        let press = AXUIElementPerformAction(ax, kAXPressAction as CFString)
        if press == .success { return nil }
        // Some owners open their menu but return cannotComplete while tracking it.
        for _ in 0..<3 {
            Thread.sleep(forTimeInterval: 0.08)
            var candidates = [ax]
            var pid: pid_t = 0
            if AXUIElementGetPid(ax, &pid) == .success {
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, 0.1)
                if let extras = element(app, "AXExtrasMenuBar") {
                    let ownerItems = children(extras)
                    let identifier = text(ax, "AXIdentifier")
                    candidates += ownerItems.filter { ownerItems.count == 1 || CFEqual($0, ax) || (!identifier.isEmpty && text($0, "AXIdentifier") == identifier) }
                }
            }
            let probes = candidates.map(itemMenuProbe)
            let active = probes.contains { $0.active }
            menuStateLock.lock()
            lastActivationProbe = ["targetID": id, "pressResult": press.rawValue, "confirmedMenuOpen": active,
                                   "time": ISO8601DateFormatter().string(from: Date()), "items": probes.map { $0.fields }]
            menuStateLock.unlock()
            if active { _ = hasActiveMenu(); return nil }
        }
        guard press == .actionUnsupported || press == .notImplemented else {
            return AXIsProcessTrusted() ? L10n.text("layout.the.icon.action.was.not.confirmed.accessibility", press.rawValue) : L10n.text("layout.accessibility.access.was.revoked.allow.it.again")
        }
        let point = CGPoint(x: entry.frame.midX, y: entry.frame.midY)
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            return L10n.text("layout.could.not.create.a.menu.bar.click")
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return nil
    }

    func tryExpandSystemOverflow(screens: [CGRect], isCancelled: () -> Bool) -> (point: CGPoint?, diagnostic: [String: Any]) {
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess(),
              let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first else {
            return (nil, ["attempted": false, "reason": "permissionOrAgentUnavailable"])
        }
        let show: Set<String> = ["显示隐藏菜单栏项目", "Show Hidden Menu Bar Items"]
        let labels = show.union(["隐藏菜单栏项目", "Hide Hidden Menu Bar Items"])
        let app = AXUIElementCreateApplication(agent.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var buttons: [(ax: AXUIElement, frame: CGRect, label: String)] = []
        for window in children(app, attribute: "AXWindows") {
            for button in children(window) where text(button, "AXRole") == "AXButton" && children(button).isEmpty {
                var pid: pid_t = 0
                guard AXUIElementGetPid(button, &pid) == .success, pid == agent.processIdentifier,
                      let label = [text(button, "AXTitle"), text(button, "AXDescription")].first(where: { labels.contains($0) }),
                      let frame = rect(button), frame.width > 0, frame.height > 0, isInMenuBar(frame),
                      screens.contains(where: { $0.contains(frame) }) else { continue }
                buttons.append((button, frame, label))
            }
        }
        guard let button = buttons.first(where: { show.contains($0.label) }), buttons.allSatisfy({ $0.frame == button.frame }) else {
            return (nil, ["attempted": false, "reason": "nativeShowButtonMissingOrAmbiguous", "candidateCount": buttons.count])
        }
        var actions: CFArray?
        let actionResult = AXUIElementCopyActionNames(button.ax, &actions)
        let actionNames = actions as? [String] ?? []
        let supportsPress = actionResult == .success && actionNames.contains(kAXPressAction as String)
        let menuActive = hasActiveMenu()
        let menuProbe = activeMenuDiagnostics()
        let modifierFlags = CGEventSource.flagsState(.hidSystemState)
        let blockingModifiers = modifierFlags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        let leftPressed = CGEventSource.buttonState(.hidSystemState, button: .left)
        let rightPressed = CGEventSource.buttonState(.hidSystemState, button: .right)
        var diagnostic: [String: Any] = ["attempted": false, "frame": NSStringFromRect(button.frame), "label": button.label,
            "actionCopyResult": actionResult.rawValue, "actions": actionNames, "supportsAXPress": supportsPress,
            "hasActiveMenu": menuActive, "activeMenuEvidence": menuProbe["evidence"] ?? [:], "menuProbeTime": menuProbe["lastProbe"] ?? "",
            "modifierFlags": modifierFlags.rawValue, "blockingModifierFlags": blockingModifiers.rawValue,
            "leftPressed": leftPressed, "rightPressed": rightPressed]
        // Native chevron identity is verified above; action advertisement is diagnostic only.
        guard !menuActive, blockingModifiers.isEmpty, !leftPressed, !rightPressed else {
            diagnostic["reason"] = "interactionActive"
            return (nil, diagnostic)
        }
        let point = CGPoint(x: button.frame.midX, y: button.frame.midY)
        guard let moved = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else {
            diagnostic["reason"] = "mouseEventUnavailable"
            return (nil, diagnostic)
        }
        guard !isCancelled() else { diagnostic["reason"] = "cancelledBeforeWarp"; return (nil, diagnostic) }
        let warp = CGWarpMouseCursorPosition(point)
        guard warp == .success else { diagnostic["reason"] = "cursorWarpFailed"; diagnostic["warpResult"] = warp.rawValue; return (nil, diagnostic) }
        moved.flags = []; moved.post(tap: .cghidEventTap)
        diagnostic["pointerMoved"] = true
        Thread.sleep(forTimeInterval: 0.06)
        guard !isCancelled() else { diagnostic["reason"] = "cancelledBeforePress"; return (point, diagnostic) }
        diagnostic["attemptedWithoutAdvertisement"] = !supportsPress
        let result = AXUIElementPerformAction(button.ax, kAXPressAction as CFString)
        diagnostic["attempted"] = true
        diagnostic["pressResult"] = result.rawValue
        guard result == .actionUnsupported || result == .notImplemented else { return (point, diagnostic) }

        // Only an explicitly unsupported press may reach this single native-click fallback.
        let fallbackMenuActive = hasActiveMenu()
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.1)
        var hit: AXUIElement?
        let hitResult = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit)
        var hitPID: pid_t = 0
        if let hit { AXUIElementSetMessagingTimeout(hit, 0.1); AXUIElementGetPid(hit, &hitPID) }
        let hitRole = hit.map { text($0, "AXRole") } ?? ""
        let hitLabel = hit.flatMap { item in [text(item, "AXTitle"), text(item, "AXDescription")].first(where: { labels.contains($0) }) } ?? ""
        let hitFrame = hit.flatMap { rect($0) }
        let hitChildren = hit.map { children($0).count } ?? -1
        let flags = CGEventSource.flagsState(.hidSystemState)
        let left = CGEventSource.buttonState(.hidSystemState, button: .left)
        let right = CGEventSource.buttonState(.hidSystemState, button: .right)
        let current = CGEvent(source: nil)?.location
        let pointerUnchanged = current.map { abs($0.x - point.x) < 1 && abs($0.y - point.y) < 1 } ?? false
        var fallback: [String: Any] = ["hitResult": hitResult.rawValue, "hitPID": hitPID, "hitRole": hitRole, "hitLabel": hitLabel,
            "hitFrame": hitFrame.map(NSStringFromRect) ?? "unavailable", "hitChildCount": hitChildren,
            "hasActiveMenu": fallbackMenuActive, "modifierFlags": flags.rawValue, "leftPressed": left, "rightPressed": right,
            "pointerUnchanged": pointerUnchanged, "cancelled": isCancelled(), "hidClickSent": false]
        let decision = Self.overflowFallbackDecision(pressResult: result, hitResult: hitResult, hitPID: hitPID,
            agentPID: agent.processIdentifier, role: hitRole, label: hitLabel, frame: hitFrame, expectedFrame: button.frame)
        if decision == .waitForLayout {
            fallback["reason"] = "alreadyExpanded"
            diagnostic["hidFallback"] = fallback
            return (point, diagnostic)
        }
        guard decision == .click, hitChildren == 0, !fallbackMenuActive,
              flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty,
              !left, !right, pointerUnchanged, !isCancelled(), AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            fallback["reason"] = "freshNativeHitOrInteractionRejected"
            diagnostic["hidFallback"] = fallback
            return (point, diagnostic)
        }
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            fallback["reason"] = "mouseEventUnavailable"
            diagnostic["hidFallback"] = fallback
            return (point, diagnostic)
        }
        down.flags = []; up.flags = []
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        down.setIntegerValueField(.mouseEventButtonNumber, value: 0)
        up.setIntegerValueField(.mouseEventButtonNumber, value: 0)
        guard !isCancelled() else { fallback["reason"] = "cancelledBeforeHID"; diagnostic["hidFallback"] = fallback; return (point, diagnostic) }
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.03)
        up.post(tap: .cghidEventTap)
        fallback["hidClickSent"] = true
        fallback["reason"] = "strictNativeClickSent"
        diagnostic["hidFallback"] = fallback
        return (point, diagnostic)
    }

    enum OverflowFallbackDecision: Equatable { case refuse, waitForLayout, click }

    static func overflowFallbackDecision(pressResult: AXError, hitResult: AXError, hitPID: pid_t, agentPID: pid_t,
                                         role: String, label: String, frame: CGRect?, expectedFrame: CGRect) -> OverflowFallbackDecision {
        if pressResult == .success || pressResult == .cannotComplete { return .waitForLayout }
        guard pressResult == .actionUnsupported || pressResult == .notImplemented,
              hitResult == .success, hitPID == agentPID, role == "AXButton", let frame,
              frame.width > 0, frame.height > 0, frame == expectedFrame else { return .refuse }
        if ["隐藏菜单栏项目", "Hide Hidden Menu Bar Items"].contains(label) { return .waitForLayout }
        return ["显示隐藏菜单栏项目", "Show Hidden Menu Bar Items"].contains(label) ? .click : .refuse
    }

    struct DragUndo {
        let source: String
        let left: String?
        let right: String?
        let sourceFrame: CGRect
        let targetFrame: CGRect
        let start: CGPoint
        let end: CGPoint
        var lastPointerPosition: CGPoint
    }

    // Quartz and AX both use global display points with a top-left origin.
    static func commandDragPoints(source: CGRect, target: CGRect, before: Bool, screens: [CGRect]) -> (CGPoint, CGPoint)? {
        guard [source, target].allSatisfy({ $0.minX.isFinite && $0.minY.isFinite && $0.width.isFinite && $0.height.isFinite && $0.width > 4 && $0.height > 4 && $0.height <= 60 }),
              abs(source.midY - target.midY) < 2,
              source.maxX <= target.minX + 1 || target.maxX <= source.minX + 1,
              screens.contains(where: { screen in
                  [source, target].allSatisfy { screen.contains($0) && $0.minY >= screen.minY && $0.maxY <= screen.minY + 60 }
              }) else { return nil }
        return (CGPoint(x: source.midX, y: source.midY),
                CGPoint(x: before ? target.minX + 2 : target.maxX - 2, y: source.midY))
    }

    func commandDrag(sourceID: String, targetID: String, before: Bool, screens: [CGRect]) -> (undo: DragUndo?, error: String?) {
        let snapshot = scan()
        guard CGPreflightPostEventAccess(), AXIsProcessTrusted() else { return (nil, L10n.text("layout.native.dragging.requires.accessibility.and.event.posting")) }
        guard !snapshot.hasActiveMenu else { return (nil, L10n.text("layout.a.menu.is.still.open.native.dragging")) }
        let physicalFlags = CGEventSource.flagsState(.hidSystemState)
        guard physicalFlags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty,
              !CGEventSource.buttonState(.hidSystemState, button: .left), !CGEventSource.buttonState(.hidSystemState, button: .right) else {
            return (nil, L10n.text("layout.release.the.mouse.and.modifier.keys.before"))
        }
        guard sourceID != targetID, lastHostedIDs.contains(sourceID), lastHostedIDs.contains(targetID),
              let source = lastEntries[sourceID], let target = lastEntries[targetID],
              let (start, end) = Self.commandDragPoints(source: source.frame, target: target.frame, before: before, screens: screens) else {
            return (nil, L10n.text("layout.the.drag.source.or.target.has.no"))
        }
        let bar = snapshot.items.filter { lastHostedIDs.contains($0.id) && $0.frame.width > 0 && abs($0.frame.midY - start.y) < 2 }.sorted { $0.frame.midX < $1.frame.midX }
        guard let index = bar.firstIndex(where: { $0.id == sourceID }), let eventSource = CGEventSource(stateID: .privateState),
              let down = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left),
              let up = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left),
              let moveToStart = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: start, mouseButton: .left),
              let commandDown = CGEvent(keyboardEventSource: eventSource, virtualKey: 55, keyDown: true),
              let commandUp = CGEvent(keyboardEventSource: eventSource, virtualKey: 55, keyDown: false) else { return (nil, L10n.text("layout.could.not.create.a.native.drag.event")) }
        var undo = DragUndo(source: sourceID, left: index > 0 ? bar[index - 1].id : nil, right: index + 1 < bar.count ? bar[index + 1].id : nil,
                            sourceFrame: source.frame, targetFrame: target.frame, start: start, end: end, lastPointerPosition: start)
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        down.setIntegerValueField(.mouseEventButtonNumber, value: 0)
        up.setIntegerValueField(.mouseEventButtonNumber, value: 0)
        down.setDoubleValueField(.mouseEventPressure, value: 1)
        up.setDoubleValueField(.mouseEventPressure, value: 0)
        var releasePoint = start
        defer {
            up.location = releasePoint; up.flags = .maskCommand; up.post(tap: .cghidEventTap)
            commandUp.flags = []; commandUp.post(tap: .cghidEventTap)
        }
        // Pre-positioning updates WindowServer's hit target before the modifier drag.
        moveToStart.flags = []; moveToStart.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.06)
        commandDown.flags = .maskCommand; commandDown.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.08)
        down.flags = .maskCommand; down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.12)
        for step in 1...16 {
            let fraction = CGFloat(step) / 16
            let point = CGPoint(x: start.x + (end.x - start.x) * fraction, y: start.y)
            guard let drag = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left) else {
                return (undo, L10n.text("layout.native.drag.event.creation.was.interrupted.the"))
            }
            drag.flags = .maskCommand
            drag.setIntegerValueField(.mouseEventButtonNumber, value: 0)
            drag.setDoubleValueField(.mouseEventPressure, value: 1)
            drag.setIntegerValueField(.mouseEventDeltaX, value: Int64(point.x.rounded() - releasePoint.x.rounded()))
            drag.setIntegerValueField(.mouseEventDeltaY, value: 0)
            drag.post(tap: .cghidEventTap)
            releasePoint = point
            undo.lastPointerPosition = point
            Thread.sleep(forTimeInterval: 0.02)
        }
        Thread.sleep(forTimeInterval: 0.12)
        return (undo, nil)
    }

    func activeMenuDiagnostics() -> [String: Any] {
        menuStateLock.lock()
        defer { menuStateLock.unlock() }
        return ["active": lastMenuState, "lastProbe": lastMenuProbe.map { ISO8601DateFormatter().string(from: $0) } ?? L10n.text("layout.not.checked.yet"),
                "ageSeconds": lastMenuProbe.map { Date().timeIntervalSince($0) } ?? -1, "activation": lastActivationProbe, "hosts": lastHostDiagnostic, "evidence": lastMenuEvidence]
    }

    func hasActiveMenu() -> Bool {
        let result = detectActiveMenu()
        menuStateLock.lock()
        lastMenuState = result
        lastMenuProbe = Date()
        menuStateLock.unlock()
        return result
    }

    private func itemMenuProbe(_ item: AXUIElement) -> (active: Bool, fields: [String: Any]) {
        let selected = (value(item, "AXSelected") as? NSNumber)?.boolValue ?? false
        let expanded = (value(item, "AXExpanded") as? NSNumber)?.boolValue ?? false
        var active = Self.menuIsTracking(selected: selected, expanded: expanded, frame: nil, visibleChildren: 0, selectedChildren: 0)
        let menus: [[String: Any]] = children(item).filter { text($0, "AXRole") == "AXMenu" }.map { menu in
            let frame = rect(menu)
            let visible = children(menu, attribute: "AXVisibleChildren").count
            let selectedChildren = children(menu, attribute: "AXSelectedChildren").count
            active = active || Self.menuIsTracking(selected: false, expanded: false, frame: frame, visibleChildren: visible, selectedChildren: selectedChildren)
            return ["frame": frame.map(NSStringFromRect) ?? "unavailable", "visibleChildren": visible, "selectedChildren": selectedChildren]
        }
        return (active, ["selected": selected, "expanded": expanded, "menus": menus])
    }

    private func recordMenuEvidence(pid: pid_t, reason: String, ax: AXUIElement) -> Bool {
        let fields: [String: Any] = ["ownerPID": pid, "reason": reason, "role": text(ax, "AXRole"), "frame": rect(ax).map(NSStringFromRect) ?? "unavailable"]
        menuStateLock.lock(); lastMenuEvidence = fields; menuStateLock.unlock()
        return true
    }

    private func detectActiveMenu() -> Bool {
        menuStateLock.lock(); lastMenuEvidence = [:]; menuStateLock.unlock()
        var pids = ownerPIDs
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier { pids.insert(pid) }
        for pid in pids {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.1)
            if let extras = element(app, "AXExtrasMenuBar") {
                for item in children(extras) {
                    let selected = (value(item, "AXSelected") as? NSNumber)?.boolValue ?? false
                    let expanded = (value(item, "AXExpanded") as? NSNumber)?.boolValue ?? false
                    if Self.menuIsTracking(selected: selected, expanded: expanded, frame: nil, visibleChildren: 0, selectedChildren: 0) { return recordMenuEvidence(pid: pid, reason: "extras selected/expanded", ax: item) }
                    for menu in children(item) where text(menu, "AXRole") == "AXMenu" {
                        if Self.menuIsTracking(selected: false, expanded: false, frame: rect(menu),
                                               visibleChildren: children(menu, attribute: "AXVisibleChildren").count,
                                               selectedChildren: children(menu, attribute: "AXSelectedChildren").count) { return recordMenuEvidence(pid: pid, reason: "extras menu visible/selected", ax: menu) }
                    }
                }
            }
            if let focused = element(app, "AXFocusedUIElement") {
                var current: AXUIElement? = focused
                for _ in 0..<5 {
                    guard let value = current else { break }
                    if ["AXMenu", "AXPopover"].contains(text(value, "AXRole")) { return recordMenuEvidence(pid: pid, reason: "focused ancestor", ax: value) }
                    current = element(value, "AXParent")
                }
            }
            for window in children(app, attribute: "AXWindows") {
                if ["AXMenu", "AXPopover"].contains(text(window, "AXRole")) || text(window, "AXSubrole").contains("Popover") { return recordMenuEvidence(pid: pid, reason: "window role", ax: window) }
                if let menu = children(window).first(where: { ["AXMenu", "AXPopover"].contains(text($0, "AXRole")) }) { return recordMenuEvidence(pid: pid, reason: "window child role", ax: menu) }
            }
        }
        return false
    }
    // Closed NSMenus may retain their entire AX subtree with a zero-sized frame.
    static func menuIsTracking(selected: Bool, expanded: Bool, frame: CGRect?, visibleChildren: Int, selectedChildren: Int) -> Bool {
        if selected || expanded || selectedChildren > 0 { return true }
        guard let frame, frame.width.isFinite, frame.height.isFinite, frame.width > 1, frame.height > 1 else { return false }
        return visibleChildren > 0
    }

    struct HostedSlotGeometry: Equatable {
        let pid: pid_t
        let frame: CGRect
    }

    static func selectHostedWindow(layouts: [Int: [HostedSlotGeometry]], ownSlots: [Int: [CGRect]], ownFrames: [CGRect]) -> Int? {
        if layouts.count == 1 && ownFrames.isEmpty { return layouts.keys.first }
        guard !ownFrames.isEmpty else { return nil }
        let matching = layouts.keys.filter { index in
            ownFrames.allSatisfy { ownFrame in
                (ownSlots[index] ?? []).contains { abs($0.minX - ownFrame.minX) <= 3 && abs($0.midY - ownFrame.midY) <= 20 }
            }
        }.sorted()
        guard let first = matching.first else { return nil }
        func canonical(_ slots: [HostedSlotGeometry]) -> [HostedSlotGeometry] {
            slots.sorted { left, right in
                if left.pid != right.pid { return left.pid < right.pid }
                let a = [left.frame.minX, left.frame.minY, left.frame.width, left.frame.height]
                let b = [right.frame.minX, right.frame.minY, right.frame.width, right.frame.height]
                return a.lexicographicallyPrecedes(b)
            }
        }
        let reference = canonical(layouts[first] ?? [])
        return matching.allSatisfy { canonical(layouts[$0] ?? []) == reference } ? first : nil
    }

    static func hostedSlotIsDistinct(_ frame: CGRect, others: [CGRect]) -> Bool {
        frame.width > 0 && frame.height > 0 && !others.contains { other in
            abs(other.midY - frame.midY) < 2 && frame.intersection(other).width > 1
        }
    }

    // Explicit diagnostic export only: never use hit evidence to relax movement checks.
    private func updateHostHitEvidence() {
        guard AXIsProcessTrusted() else { return }
        menuStateLock.lock(); var diagnostic = lastHostDiagnostic; menuStateLock.unlock()
        guard var windows = diagnostic["windows"] as? [[String: Any]] else { return }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.05)
        let deadline = Date().addingTimeInterval(2)
        for index in windows.indices {
            guard var slots = windows[index]["slots"] as? [[String: Any]] else { continue }
            let indices = slots.indices.sorted { left, right in
                let a = (slots[left]["overflowButton"] as? [String: Any])?.isEmpty == false
                let b = (slots[right]["overflowButton"] as? [String: Any])?.isEmpty == false
                return a && !b
            }
            for slotIndex in indices {
                guard Date() < deadline, let frameString = slots[slotIndex]["frame"] as? String else { break }
                let frame = NSRectFromString(frameString)
                let isChevron = (slots[slotIndex]["overflowButton"] as? [String: Any])?.isEmpty == false
                slots[slotIndex]["centerHit"] = hitEvidence(at: CGPoint(x: frame.midX, y: frame.midY), system: system, deadline: deadline, includeChevronLabels: isChevron)
            }
            windows[index]["slots"] = slots
        }
        diagnostic["windows"] = windows
        diagnostic["hitEvidenceTime"] = ISO8601DateFormatter().string(from: Date())
        diagnostic["hitEvidenceBudgetExhausted"] = Date() >= deadline
        menuStateLock.lock(); lastHostDiagnostic = diagnostic; menuStateLock.unlock()
    }

    private func hitEvidence(at point: CGPoint, system: AXUIElement, deadline: Date, includeChevronLabels: Bool) -> [String: Any] {
        guard point.x.isFinite, point.y.isFinite else { return ["error": "invalid point"] }
        var hit: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit)
        var chain: [[String: Any]] = []
        var seen: [AXUIElement] = []
        while let current = hit, chain.count < 4, Date() < deadline {
            if seen.contains(where: { CFEqual($0, current) }) { break }
            seen.append(current)
            AXUIElementSetMessagingTimeout(current, 0.03)
            var pid: pid_t = 0
            AXUIElementGetPid(current, &pid)
            let role = text(current, "AXRole")
            var fields: [String: Any] = ["pid": pid, "role": role, "identifier": text(current, "AXIdentifier")]
            if includeChevronLabels && chain.isEmpty && role == "AXButton",
               NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.MenuBarAgent" {
                fields["title"] = text(current, "AXTitle")
                fields["description"] = text(current, "AXDescription")
            }
            chain.append(fields)
            hit = element(current, "AXParent")
        }
        return ["point": NSStringFromPoint(point), "result": result.rawValue, "chain": chain]
    }

    private func rawGeometry(_ ax: AXUIElement) -> [String: Any] {
        var result: [String: Any] = [:]
        if let p = value(ax, "AXPosition"), CFGetTypeID(p) == AXValueGetTypeID() {
            var point = CGPoint.zero
            if AXValueGetValue(p as! AXValue, .cgPoint, &point) { result["position"] = NSStringFromPoint(point) }
        }
        if let s = value(ax, "AXSize"), CFGetTypeID(s) == AXValueGetTypeID() {
            var size = CGSize.zero
            if AXValueGetValue(s as! AXValue, .cgSize, &size) { result["size"] = NSStringFromSize(size) }
        }
        return result
    }

    private func isInMenuBar(_ frame: CGRect) -> Bool {
        guard frame.width > 0, frame.height > 0, frame.height <= 60 else { return false }
        var displays = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(displays.count), &displays, &count) == .success else { return false }
        return displays.prefix(Int(count)).contains { display in
            let screen = CGDisplayBounds(display)
            return frame.midX >= screen.minX && frame.midX <= screen.maxX && frame.minY >= screen.minY - 1 && frame.maxY <= screen.minY + 60
        }
    }
    private func value(_ ax: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, name as CFString, &result) == .success else { return nil }
        return result
    }
    private func text(_ ax: AXUIElement, _ name: String) -> String { value(ax, name) as? String ?? "" }
    private func element(_ ax: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = value(ax, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private func children(_ ax: AXUIElement, attribute: String = "AXChildren") -> [AXUIElement] { value(ax, attribute) as? [AXUIElement] ?? [] }
    private func rect(_ ax: AXUIElement) -> CGRect? {
        guard let p = value(ax, "AXPosition"), let s = value(ax, "AXSize"), CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
}
