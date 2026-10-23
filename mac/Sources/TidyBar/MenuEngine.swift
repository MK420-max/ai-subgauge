import AppKit
import ApplicationServices
import Combine
import MenuBarShim
import os

struct MenuPresentationIntent {
    private(set) var expanded = false
    private(set) var generation = 0
    private(set) var collapseRequested = false

    mutating func expand() { expanded = true; collapseRequested = false; generation += 1 }
    mutating func collapse() {
        if expanded || !collapseRequested { generation += 1 }
        expanded = false
        collapseRequested = true
    }
    mutating func toggle() -> Bool {
        if expanded { collapse() } else { expand() }
        return expanded
    }
    mutating func cancelCollapse(actualExpanded: Bool) {
        expanded = actualExpanded; collapseRequested = false; generation += 1
    }
    mutating func completeCollapse() { collapseRequested = false }
    func acceptsCollapse(_ request: Int) -> Bool { collapseRequested && !expanded && generation == request }
}

@MainActor
final class MenuEngine: ObservableObject {
    let store: SettingsStore
    @Published var items: [MenuEntry] = []
    @Published var isExpanded = false {
        didSet {
            guard isExpanded != oldValue else { return }
            collectionLogger.info("Collection expanded=\(self.isExpanded, privacy: .public)")
            recordCollectionDiagnostics()
        }
    }
    @Published var accessibilityGranted = false
    @Published var isBusy = false
    @Published var lastError: String?
    @Published var status = L10n.text("layout.waiting.to.scan.the.menu.bar")
    var available: Bool { STMenuBarShim.isAvailable() }
    var menuBarAccessGranted: Bool { (try? grantedURL()) != nil }
    var ownStatusFrameProvider: (() -> CGRect?)?
    var ownStatusFramesProvider: (() -> [CGRect])?
    private func currentOwnStatusFrames() -> [CGRect] {
        if let provider = ownStatusFramesProvider { return provider() }
        if let frame = ownStatusFrameProvider?() { return [frame] }
        return []
    }
    private let scanner = MenuScanner()
    private let collectionLogger = Logger(subsystem: "com.mike.aisubgauge", category: "collection")
    private let accessibilityCheck: () -> Bool
    private var observesSystem = false
    private var lastCollectionDiagnostic: CollectionDiagnostic?
    private var lastRuleCounts: [String: Int]?
    private var lastAXTrusted: Bool?
    var onAccessibilityRequired: () -> Void = { CollectionAccess.showPrompt() }
    private let worker = DispatchQueue(label: "com.mike.aisubgauge.ax", qos: .userInitiated)
    private(set) var started = false
    private var scanning = false
    private var moving = false
    private var movementActivationPolicy: NSApplication.ActivationPolicy?
    private var movementPointerPlacement: CGPoint?
    private var overflowExpansionCancellation: Progress?
    private var activating = false
    private var presentation = MenuPresentationIntent()
    private var collapseProbeInFlight = false
    private var accessDiagnostic: [String: Any] = ["bookmarkExists": false, "resolveAttempted": false]
    private var accessDiagnosticData: Data?
    private var hasActiveMenu = false
    private var freshItemIDs = Set<String>()
    private var systemOverflowIDs = Set<String>()
    private var orderDiagnostic: [String: Any] = [:]
    private var savedOrderError: String?
    private var persistedOrderAwaitingObservation: [String]?
    private var pendingStartupOrder = false
    private var startupOrderRetried = false
    private var startupOrderRetryTask: Task<Void, Never>?
    private var waitingForStartupOrderRetry = false
    private var activeToken: AnyObject?
    private var pendingToken: AnyObject?
    private var visibilityError: String?
    private var activationError: String?
    private var errorBeforeVisibility: String?
    private var appliedIDs: Set<String>?
    private var desiredIDs: Set<String>?
    private var generation = 0
    private var lifecycle = 0
    private var moveGeneration = 0
    private var pendingSavedOrder = false
    private var pendingSavedOrderIDs: [String]?
    private var pendingSavedOrderCompletion: ((Result<Void, Error>) -> Void)?
    private var activeSavedOrderIDs: [String]?
    private var waitingForOrderVisibility = false
    private var pendingOrderVisibilityChecked = false
    private let lastBackupKey = "LastMenuBarLayoutBackup"
    private var pendingPositionRollback: (url: URL, original: [String: NSNumber], written: [String: NSNumber])?
    private var pendingGeneration: Int?
    private var applyTimeout: DispatchWorkItem?
    private var refreshTimer: Timer?
    private var collapseTimer: Timer?
    private var activationTask: Task<Void, Never>?
    private var activationGeneration = 0
    private var temporaryBundle: String?
    private var showEverything = false
    private var movementReveal = false
    private var observers: [NSObjectProtocol] = []
    private let bookmarkKey = "MenuBarAgentFileBookmark"

    init(store: SettingsStore, accessibilityCheck: @escaping () -> Bool = { AXIsProcessTrusted() }) {
        self.store = store
        self.accessibilityCheck = accessibilityCheck
    }

    func start(observeSystem: Bool = true) {
        guard !started else { return }
        started = true
        observesSystem = observeSystem
        collectionLogger.info("Collection engine started")
        lifecycle += 1
        // Offline lifecycle tests exercise startup without scanning or changing the host.
        guard observeSystem else { return }
        pendingSavedOrder = !store.config.order.isEmpty
        pendingSavedOrderIDs = store.config.order
        pendingStartupOrder = pendingSavedOrder
        startupOrderRetried = false
        recoverPendingLayout()
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh(); self?.applyVisibility() }
            })
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refreshTimer?.tolerance = 1
        refresh()
    }

    func stop() {
        started = false
        recordCollectionDiagnostics()
        observesSystem = false
        overflowExpansionCancellation?.cancel()
        if let policy = movementActivationPolicy { NSApp.setActivationPolicy(policy); movementActivationPolicy = nil }
        lifecycle += 1
        moveGeneration += 1
        generation += 1
        activationGeneration += 1
        activationTask?.cancel()
        activationTask = nil
        activating = false
        let queuedCompletion = pendingSavedOrderCompletion
        pendingSavedOrderCompletion = nil; pendingSavedOrderIDs = nil; pendingSavedOrder = false; pendingOrderVisibilityChecked = false
        startupOrderRetryTask?.cancel(); startupOrderRetryTask = nil; waitingForStartupOrderRetry = false; pendingStartupOrder = false
        queuedCompletion?(.failure(MoveFailure.message(L10n.text("layout.the.app.stopped.the.ordering.request.was"))))
        presentation.cancelCollapse(actualExpanded: false)
        isExpanded = false
        showEverything = false
        if let rollback = pendingPositionRollback {
            do { try Self.rollbackPositions(original: rollback.original, written: rollback.written, url: rollback.url) }
            catch { lastError = L10n.text("layout.could.not.restore.unconfirmed.ordering.on.exit") }
            pendingPositionRollback = nil
        }
        refreshTimer?.invalidate(); refreshTimer = nil
        collapseTimer?.invalidate(); collapseTimer = nil
        applyTimeout?.cancel(); applyTimeout = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        STMenuBarShim.invalidate(pendingToken)
        STMenuBarShim.invalidate(activeToken)
        pendingToken = nil; activeToken = nil; pendingGeneration = nil
        appliedIDs = nil; desiredIDs = nil; temporaryBundle = nil; movementReveal = false
        isBusy = false
        status = L10n.text("layout.all.menu.bar.icons.restored")
    }

    func refreshAccessibility() {
        let trusted = accessibilityCheck()
        if trusted != lastAXTrusted {
            collectionLogger.info("Collection AX trusted=\(trusted, privacy: .public)")
            lastAXTrusted = trusted
        }
        accessibilityGranted = trusted
        if accessibilityGranted && lastError == L10n.text("layout.allow.accessibility.access.in.system.settings.to") { lastError = nil }
        if accessibilityGranted && lastError == CollectionAccess.message { lastError = nil }
        recordCollectionDiagnostics()
    }

    private func recordCollectionDiagnostics() {
        guard observesSystem else { return }
        let diagnostic = CollectionDiagnostic(axTrusted: accessibilityGranted, postEventAccess: CGPreflightPostEventAccess(),
            rules: store.config.rules, engineRunning: started)
        if diagnostic.ruleCounts != lastRuleCounts {
            lastRuleCounts = diagnostic.ruleCounts
            collectionLogger.info("Collection rules total=\(self.store.config.rules.count, privacy: .public) hidden=\(diagnostic.ruleCounts["hidden", default: 0], privacy: .public) alwaysHidden=\(diagnostic.ruleCounts["alwaysHidden", default: 0], privacy: .public)")
        }
        if let previous = lastCollectionDiagnostic, diagnostic.hasSameState(as: previous) { return }
        do {
            try diagnostic.write(to: CollectionDiagnostic.defaultURL)
            lastCollectionDiagnostic = diagnostic
        }
        catch { collectionLogger.error("Could not write collection diagnostic") }
    }

    @discardableResult
    func requireCollectionAccessibility() -> Bool {
        refreshAccessibility()
        guard accessibilityGranted else {
            lastError = CollectionAccess.message
            onAccessibilityRequired()
            return false
        }
        return true
    }

    func refresh() {
        refreshAccessibility()
        guard accessibilityGranted else {
            freshItemIDs.removeAll()
            items = NSWorkspace.shared.runningApplications.compactMap { app in
                guard let bundle = app.bundleIdentifier, store.config.rules[bundle] != nil else { return nil }
                return MenuEntry(id: bundle + "::应用菜单栏图标", bundleID: bundle,
                                 name: app.localizedName ?? bundle, title: L10n.text("layout.saved.rules.accessibility.access.is.off.clicking"),
                                 frame: .zero, icon: app.icon, isRunning: true, canMove: false)
            }
            lastError = L10n.text("layout.allow.accessibility.access.in.system.settings.to")
            status = L10n.text("layout.accessibility.access.is.needed.saved.collection.rules")
            applyVisibility()
            return
        }
        guard !scanning else { return }
        scanning = true
        let epoch = lifecycle
        updateBusy()
        let ownStatusFrames = currentOwnStatusFrames()
        worker.async { [weak self, scanner] in
            scanner.ownStatusFrames = ownStatusFrames
            let snapshot = scanner.scan(probeActiveMenu: false)
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanning = false
                guard self.started, self.lifecycle == epoch else { self.updateBusy(); return }
                self.freshItemIDs = snapshot.freshIDs
                self.systemOverflowIDs = snapshot.systemOverflowIDs
                self.items = self.ordered(self.markMovability(snapshot.items))
                self.hasActiveMenu = snapshot.hasActiveMenu
                self.status = self.lastError ?? (self.items.isEmpty ? L10n.text("layout.no.menu.bar.icons.found.refresh.later") : L10n.text("layout.found.0.menu.bar.icons", self.items.count))
                self.updateBusy()
                self.applyVisibility()
                if self.pendingSavedOrder { self.drainSavedOrder() }
            }
        }
    }

    func toggle() {
        guard started, requireCollectionAccessibility() else { return }
        if presentation.toggle() {
            collapseTimer?.invalidate(); collapseTimer = nil
            if !isExpanded { showEverything = false }
            isExpanded = true
            applyVisibility()
        } else { requestCollapseProbe() }
    }
    func collapse() {
        guard started else { return }
        presentation.collapse()
        requestCollapseProbe()
    }
    private func requestCollapseProbe() {
        guard started, presentation.collapseRequested, !presentation.expanded,
              !collapseProbeInFlight, collapseTimer?.isValid != true else { return }
        guard isExpanded || showEverything || temporaryBundle != nil else { presentation.completeCollapse(); return }
        collapseProbeInFlight = true
        let request = presentation.generation
        worker.async { [weak self, scanner] in
            let active = scanner.hasActiveMenu()
            DispatchQueue.main.async {
                guard let self else { return }
                self.collapseProbeInFlight = false
                guard self.started else { return }
                guard self.presentation.acceptsCollapse(request) else {
                    // A newer collapse may have been requested while this obsolete probe ran.
                    if self.presentation.collapseRequested { self.requestCollapseProbe() }
                    return
                }
                self.hasActiveMenu = active
                if active { self.scheduleCollapseRetry(request: request); return }
                self.presentation.completeCollapse()
                self.isExpanded = false
                self.showEverything = false
                self.temporaryBundle = nil
                self.applyVisibility()
            }
        }
    }
    private func scheduleCollapseRetry(request: Int) {
        guard collapseTimer?.isValid != true else { return }
        collapseTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.collapseTimer = nil
                guard self.presentation.acceptsCollapse(request) else { return }
                self.requestCollapseProbe()
            }
        }
    }
    func showAll() {
        guard started, requireCollectionAccessibility() else { return }
        presentation.expand()
        collapseTimer?.invalidate(); collapseTimer = nil
        isExpanded = true
        showEverything = true
        temporaryBundle = nil
        applyVisibility()
    }

    func setZone(_ zone: ItemZone, for bundleID: String) {
        let protected: Set<String> = ["com.apple.MenuBarAgent", "com.apple.systemuiserver", "com.apple.controlcenter", Bundle.main.bundleIdentifier ?? "com.mike.aisubgauge"]
        guard zone == .visible || !protected.contains(bundleID) else {
            lastError = L10n.text("layout.system.controls.and.this.app.s.entry")
            return
        }
        var rule = store.config.rules[bundleID] ?? ItemRule()
        rule.zone = zone
        store.config.rules[bundleID] = rule
        showEverything = false
        applyVisibility()
    }

    static func ownerBelongsToFrontmost(ownerBundleID: String, ownerURL: URL?, frontBundleID: String?, frontURL: URL?) -> Bool {
        if let frontBundleID, ownerBundleID == frontBundleID { return true }
        guard let ownerURL, let frontURL, ownerURL.isFileURL, frontURL.isFileURL else { return false }
        let owner = ownerURL.standardizedFileURL.pathComponents
        let front = frontURL.standardizedFileURL.pathComponents
        return owner.count > front.count && owner.starts(with: front)
    }

    static func allowedIDs(running: Set<String>, discovered: Set<String>, own: String, hidden: Set<String>) -> Set<String> {
        running.union(discovered).union([own]).subtracting(hidden.subtracting([own]))
    }

    static func collectionPreservesOwnEntry(bundleURL: URL, resolvedURL: URL?) -> Bool {
        guard bundleURL.isFileURL, bundleURL.pathExtension == "app", let resolvedURL, resolvedURL.isFileURL else { return false }
        return bundleURL.standardizedFileURL.resolvingSymlinksInPath() == resolvedURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    func applyVisibility() {
        guard started else { return }
        recordCollectionDiagnostics()
        let front = NSWorkspace.shared.frontmostApplication
        let runningApplications = NSWorkspace.shared.runningApplications
        let activeOwners = Set(runningApplications.filter { app in
            Self.ownerBelongsToFrontmost(ownerBundleID: app.bundleIdentifier ?? "", ownerURL: app.bundleURL,
                                         frontBundleID: front?.bundleIdentifier, frontURL: front?.bundleURL)
        }.compactMap(\.bundleIdentifier))
        let protected: Set<String> = ["com.apple.MenuBarAgent", "com.apple.systemuiserver", "com.apple.controlcenter", Bundle.main.bundleIdentifier ?? "com.mike.aisubgauge"]
        let hidden = Set(store.config.rules.compactMap { bundle, rule -> String? in
            guard !protected.contains(bundle), bundle != temporaryBundle, !showEverything, !movementReveal,
                  !(rule.showWhenActive && activeOwners.contains(bundle)) else { return nil }
            return rule.zone == .alwaysHidden || (rule.zone == .hidden && !isExpanded) ? bundle : nil
        })
        let own = Bundle.main.bundleIdentifier ?? "com.mike.aisubgauge"
        let running = Set(runningApplications.compactMap(\.bundleIdentifier))
        let effectiveHidden = hidden.intersection(running.union(Set(items.map(\.bundleID))))
        let desired = effectiveHidden.isEmpty ? nil : Self.allowedIDs(running: running, discovered: Set(items.map(\.bundleID)), own: own, hidden: effectiveHidden)
        // Assessment mode resolves bundle IDs through LaunchServices. Allowing our ID
        // does not protect a different running copy (for example mac/dist vs /Applications).
        if desired != nil, !Self.collectionPreservesOwnEntry(bundleURL: Bundle.main.bundleURL,
                         resolvedURL: NSWorkspace.shared.urlForApplication(withBundleIdentifier: own)) {
            generation += 1
            applyTimeout?.cancel(); applyTimeout = nil
            STMenuBarShim.invalidate(pendingToken)
            STMenuBarShim.invalidate(activeToken)
            pendingToken = nil; activeToken = nil; pendingGeneration = nil
            appliedIDs = nil; desiredIDs = nil
            let message = L10n.text("layout.collection.requires.registered.app")
            setVisibilityError(message)
            status = message
            updateBusy()
            return
        }
        if desired == desiredIDs, pendingGeneration != nil { return }
        if desired == appliedIDs, pendingGeneration == nil {
            desiredIDs = desired
            if visibilityError != nil {
                setVisibilityError(nil)
                status = lastError ?? L10n.text("layout.menu.bar.collection.state.updated")
            }
            return
        }
        generation += 1
        desiredIDs = desired
        if pendingGeneration == nil { beginApply() }
    }

    private func beginApply() {
        guard started, pendingGeneration == nil else { return }
        guard let desired = desiredIDs else {
            STMenuBarShim.invalidate(activeToken)
            activeToken = nil; appliedIDs = nil
            setVisibilityError(nil)
            if lastError == nil { status = L10n.text("layout.all.menu.bar.icons.are.visible") }
            updateBusy()
            return
        }
        guard available else {
            setVisibilityError(L10n.text("layout.this.system.does.not.support.the.menu"))
            status = lastError ?? L10n.text("layout.collection.api.unavailable")
            return
        }
        let request = generation
        pendingGeneration = request
        updateBusy()
        let created = STMenuBarShim.activate(withAllowedBundleIdentifiers: desired.sorted(), allowedSystemItems: (0...255).map { NSNumber(value: $0) }) { [weak self] error in
            // Always defer, including synchronous exceptions, so pendingToken has been assigned.
            DispatchQueue.main.async { self?.finishApply(request: request, requestedIDs: desired, error: error) }
        }
        pendingToken = created as AnyObject?
        guard pendingToken != nil else {
            finishApply(request: request, requestedIDs: desired, error: NSError(domain: L10n.text("layout.menu.bar.collection"), code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.text("layout.the.system.could.not.create.a.menu")]))
            return
        }
        let timeout = DispatchWorkItem { [weak self] in
            self?.finishApply(request: request, requestedIDs: desired, error: NSError(domain: L10n.text("layout.menu.bar.collection"), code: 2, userInfo: [NSLocalizedDescriptionKey: L10n.text("layout.the.system.did.not.confirm.collection.within")]))
        }
        applyTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
    }

    private func finishApply(request: Int, requestedIDs: Set<String>, error: Error?) {
        guard pendingGeneration == request else { return }
        applyTimeout?.cancel(); applyTimeout = nil
        let candidate = pendingToken
        pendingToken = nil; pendingGeneration = nil
        if error == nil && request == generation {
            let old = activeToken
            activeToken = candidate
            appliedIDs = requestedIDs
            STMenuBarShim.invalidate(old)
            setVisibilityError(nil)
            status = lastError ?? (isExpanded ? L10n.text("layout.collected.icons.expanded") : L10n.text("layout.menu.bar.collection.applied"))
        } else {
            STMenuBarShim.invalidate(candidate)
            if request == generation {
                setVisibilityError(error?.localizedDescription ?? L10n.text("layout.the.collection.request.was.superseded"))
                status = lastError ?? L10n.text("layout.collection.request.incomplete")
            }
        }
        updateBusy()
        if request != generation { beginApply() }
    }

    private func setVisibilityError(_ message: String?) {
        if let message {
            if visibilityError == nil || lastError != visibilityError { errorBeforeVisibility = lastError }
            visibilityError = message
            lastError = message
        } else {
            if let previous = visibilityError, lastError == previous { lastError = errorBeforeVisibility }
            visibilityError = nil
            errorBeforeVisibility = nil
        }
    }

    func activate(_ entry: MenuEntry) {
        guard accessibilityGranted else { requestAccessibility(); return }
        activationTask?.cancel()
        activationGeneration += 1
        presentation.cancelCollapse(actualExpanded: isExpanded)
        collapseTimer?.invalidate(); collapseTimer = nil
        activating = true
        updateBusy()
        let ticket = activationGeneration
        temporaryBundle = entry.bundleID
        // A short, known menu bar gives the revealed status item room before fresh AX resolution.
        NSApp.activate(ignoringOtherApps: true)
        applyVisibility()
        activationTask = Task { [weak self] in
            guard let self else { return }
            defer { if ticket == self.activationGeneration { self.activating = false; self.updateBusy() } }
            // Activation confirmation and one layout cycle precede fresh AX resolution.
            for _ in 0..<60 {
                if Task.isCancelled || ticket != self.activationGeneration { return }
                if self.pendingGeneration == nil { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard !Task.isCancelled, ticket == self.activationGeneration else { return }
            if self.desiredIDs != self.appliedIDs {
                self.lastError = L10n.text("layout.the.icon.could.not.be.temporarily.shown")
                self.temporaryBundle = nil
                self.applyVisibility()
                return
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            let ownStatusFrames = self.currentOwnStatusFrames()
            let error: String? = await withCheckedContinuation { continuation in
                self.worker.async { [scanner = self.scanner] in
                    scanner.ownStatusFrames = ownStatusFrames
                    continuation.resume(returning: scanner.activate(id: entry.id))
                }
            }
            guard ticket == self.activationGeneration else { return }
            if let error { self.lastError = error; self.activationError = error }
            else if self.lastError == self.activationError { self.lastError = nil; self.activationError = nil }
            self.activating = false
            self.updateBusy()
            let delay = max(1, self.store.config.autoHideDelay)
            try? await Task.sleep(nanoseconds: UInt64(min(delay, 3600) * 1_000_000_000))
            while !Task.isCancelled && ticket == self.activationGeneration {
                let active: Bool = await withCheckedContinuation { continuation in
                    self.worker.async { [scanner = self.scanner] in continuation.resume(returning: scanner.hasActiveMenu()) }
                }
                if !active { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard !Task.isCancelled, ticket == self.activationGeneration else { return }
            self.temporaryBundle = nil
            self.applyVisibility()
        }
    }

    func visibilityDiagnostics() -> [String: Any] {
        ["applied": appliedIDs.map { $0.sorted() as Any } ?? NSNull(),
         "desired": desiredIDs.map { $0.sorted() as Any } ?? NSNull(),
         "temporaryBundle": temporaryBundle.map { $0 as Any } ?? NSNull(),
         "expanded": isExpanded, "desiredExpanded": presentation.expanded,
         "presentationGeneration": presentation.generation, "collapseProbeInFlight": collapseProbeInFlight,
         "collapseRequested": presentation.collapseRequested, "showEverything": showEverything,
         "pending": pendingGeneration.map { $0 as Any } ?? NSNull(), "generation": generation,
         "moving": moving, "activating": activating, "movementReveal": movementReveal,
         "scanner": scanner.activeMenuDiagnostics(), "access": positionAccessDiagnostics(), "savedOrder": orderDiagnostic]
    }

    func diagnosticSnapshot() async -> [[String: Any]] {
        let snapshot: [[String: Any]] = await withCheckedContinuation { continuation in
            worker.async { [scanner] in continuation.resume(returning: scanner.diagnosticSnapshot()) }
        }
        var positions: [String: NSNumber] = [:]
        if let url = try? grantedURL() {
            let accessing = url.startAccessingSecurityScopedResource()
            positions = (try? Self.readPositions(url)) ?? [:]
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        let entries = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return snapshot.map { row in
            var output = row
            if let id = row["id"] as? String, let entry = entries[id] {
                output["canMove"] = entry.canMove
                let key = Self.positionKey(for: entry, positions: positions, ownerItemCount: row["ownerItemCount"] as? Int)
                output["matchedPositionKey"] = key.map { $0 as Any } ?? NSNull()
                output["preferredPosition"] = key.flatMap { positions[$0] }.map { $0 as Any } ?? NSNull()
            }
            return output
        }
    }

    func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        CollectionAccess.openSettings()
        refresh()
    }
    private func updateBusy() { isBusy = scanning || pendingGeneration != nil || moving || activating }
    private func markMovability(_ entries: [MenuEntry]) -> [MenuEntry] {
        guard let url = try? grantedURL() else { return entries }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let positions = try? Self.readPositions(url) else { return entries }
        let counts = Dictionary(entries.map { ($0.bundleID, 1) }, uniquingKeysWith: +)
        return entries.map { entry in
            var updated = entry
            updated.canMove = Self.positionKey(for: entry, positions: positions, ownerItemCount: counts[entry.bundleID]) != nil
            return updated
        }
    }
    private func ordered(_ entries: [MenuEntry]) -> [MenuEntry] {
        let positions = Dictionary(store.config.order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        return entries.sorted {
            let a = positions[$0.id] ?? Int.max, b = positions[$1.id] ?? Int.max
            return a == b ? ($0.frame.minX == $1.frame.minX ? $0.id < $1.id : $0.frame.minX < $1.frame.minX) : a < b
        }
    }

    func openMenuBarAccess() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("layout.allow.menu.bar.icon.ordering")
        panel.message = L10n.text("layout.select.com.apple.menubar.plist.this.access")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = Self.menuBarURL.deletingLastPathComponent()
        panel.nameFieldStringValue = Self.menuBarURL.lastPathComponent
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.standardizedFileURL == Self.menuBarURL.standardizedFileURL else {
            lastError = L10n.text("layout.select.the.system.menu.bar.preferences.file"); return
        }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try BoundedFile.read(url, maximum: 5_000_000)
            let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
            _ = try? grantedURL()
            try savePositionStructureDiagnostic(data)
            do {
                _ = try Self.readPositions(url)
                recoverPendingLayout()
                lastError = nil
                status = L10n.text("layout.menu.bar.position.file.access.granted")
                items = markMovability(items)
            } catch {
                status = L10n.text("layout.menu.bar.file.access.granted.the.position")
                lastError = L10n.text("layout.file.access.granted") + error.localizedDescription + L10n.text("layout.position.structure.diagnostics.saved")
            }
        } catch { lastError = L10n.text("layout.could.not.read.the.menu.bar.position", error.localizedDescription) }
    }
    private func savePositionStructureDiagnostic(_ data: Data) throws {
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let root = plist as? [String: Any] else { throw MoveFailure.message(L10n.text("layout.the.menu.bar.preferences.root.format.is")) }
        func shape(_ value: Any) -> [String: Any] {
            if let map = value as? [String: Any] { return ["type": "dictionary", "entries": map.mapValues(shape)] }
            if let array = value as? [Any] { return ["type": "array", "elements": array.map(shape)] }
            if let number = value as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() { return ["type": "boolean"] }
                return ["type": "number", "value": number.doubleValue.isFinite ? number : L10n.text("layout.non.finite.number") as Any]
            }
            if value is String { return ["type": "string"] }
            if value is Data { return ["type": "data"] }
            if value is Date { return ["type": "date"] }
            return ["type": String(describing: type(of: value))]
        }
        let diagnostic: [String: Any] = ["topLevelKeys": root.keys.sorted(),
                                        "TrailingItemPreferredPositions": root["TrailingItemPreferredPositions"].map(shape) ?? ["type": "missing"]]
        let directory = store.url.deletingLastPathComponent()
        try PrivateFiles.write(JSONSerialization.data(withJSONObject: diagnostic, options: [.prettyPrinted, .sortedKeys]),
                               to: directory.appendingPathComponent("位置结构诊断.json"))
    }
    private static var menuBarURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar.plist")
    }
    private func grantedURL() throws -> URL {
        let bookmark = UserDefaults.standard.data(forKey: bookmarkKey)
        var diagnostic: [String: Any] = ["bookmarkExists": bookmark != nil, "resolveAttempted": bookmark != nil,
                                        "readAttempted": false, "readable": false, "bookmarkRefreshed": false]
        defer { saveAccessDiagnostic(diagnostic) }
        guard let bookmark else { throw MoveFailure.message(L10n.text("layout.click.menu.bar.access.and.select.the")) }
        var stale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
            diagnostic["bookmarkStale"] = stale
            diagnostic["resolvedExpectedFile"] = url.standardizedFileURL == Self.menuBarURL.standardizedFileURL
        } catch {
            diagnostic["resolveError"] = Self.errorDiagnostic(error)
            throw error
        }
        guard url.standardizedFileURL == Self.menuBarURL.standardizedFileURL else { throw MoveFailure.message(L10n.text("layout.menu.bar.access.points.to.another.file")) }
        let accessing = url.startAccessingSecurityScopedResource()
        diagnostic["securityScopeStarted"] = accessing
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        diagnostic["readAttempted"] = true
        do {
            _ = try BoundedFile.read(url, maximum: 5_000_000)
            diagnostic["readable"] = true
        } catch {
            diagnostic["readError"] = Self.errorDiagnostic(error)
            throw error
        }
        if stale {
            // Refresh only a still-readable authorized URL. Never substitute an ungranted path.
            do {
                let fresh = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                UserDefaults.standard.set(fresh, forKey: bookmarkKey)
                diagnostic["bookmarkRefreshed"] = true
            } catch { diagnostic["refreshError"] = Self.errorDiagnostic(error) }
        }
        return url
    }
    static func errorDiagnostic(_ error: Error) -> [String: Any] {
        let error = error as NSError
        let description = error.localizedDescription.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        return ["domain": error.domain, "code": error.code, "description": description]
    }
    private func saveAccessDiagnostic(_ diagnostic: [String: Any]) {
        accessDiagnostic = diagnostic
        guard let data = try? JSONSerialization.data(withJSONObject: diagnostic, options: [.prettyPrinted, .sortedKeys]), data != accessDiagnosticData else { return }
        do {
            let directory = store.url.deletingLastPathComponent()
            try PrivateFiles.write(data, to: directory.appendingPathComponent("位置访问诊断.json"))
            accessDiagnosticData = data
        } catch { accessDiagnostic["diagnosticWriteError"] = Self.errorDiagnostic(error) }
    }
    private func positionAccessDiagnostics() -> [String: Any] {
        _ = try? grantedURL()
        return accessDiagnostic
    }
    private enum MoveFailure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case let .message(value) = self { return value }; return nil }
    }
    private static func readPositions(_ url: URL) throws -> [String: NSNumber] {
        let plist = try PropertyListSerialization.propertyList(from: BoundedFile.read(url, maximum: 5_000_000), options: [], format: nil)
        guard let dictionary = plist as? [String: Any], let values = dictionary["TrailingItemPreferredPositions"] as? [String: NSNumber],
              !values.isEmpty, values.values.allSatisfy({ $0.doubleValue.isFinite && $0.doubleValue >= 0 && CFGetTypeID($0) != CFBooleanGetTypeID() }) else {
            throw MoveFailure.message(L10n.text("layout.the.system.position.table.is.missing.or"))
        }
        return values
    }
    static func positionKey(for entry: MenuEntry, positions: [String: NSNumber], ownerItemCount: Int? = nil) -> String? {
        let prefix = entry.bundleID + "::"
        guard entry.id.hasPrefix(prefix) else { return nil }
        let identity = String(entry.id.dropFirst(prefix.count))
        guard !identity.isEmpty, !identity.contains("::") else { return nil }
        func valid(_ number: NSNumber) -> Bool {
            CFGetTypeID(number) != CFBooleanGetTypeID() && number.doubleValue.isFinite && number.doubleValue >= 0
        }
        if identity == "状态图标" {
            guard ownerItemCount == 1 else { return nil }
            let namespace = "status:" + entry.bundleID + "::"
            let matches = positions.keys.filter { key in key.hasPrefix(namespace) && positions[key].map(valid) == true }
            return matches.count == 1 ? matches.first : nil
        }
        var candidates: Set<String> = [entry.id, entry.bundleID + ":" + identity,
                                       "app:" + entry.bundleID + ":" + identity, "status:" + entry.bundleID + "::" + identity,
                                       entry.bundleID + "." + identity, entry.bundleID + "/" + identity]
        if entry.bundleID == "com.apple.MenuBarAgent" {
            let moduleNames = ["clock": "Clock", "siri": "Siri", "controlcenter": "BentoBox-0", "audiovideo": "AudioVideoModule", "wifi": "WiFi", "sound": "Sound", "battery": "Battery", "bluetooth": "Bluetooth", "focusmode": "FocusModes", "airdrop": "AirDrop", "nowplaying": "NowPlaying"]
            let suffix = identity.components(separatedBy: ".").last?.lowercased() ?? ""
            if let module = moduleNames[suffix] { candidates.insert("module:" + module) }
        }
        let matches = positions.keys.filter { key in
            guard candidates.contains(key), let number = positions[key] else { return false }
            return valid(number)
        }
        return matches.count == 1 ? matches.first : nil
    }

    static func orderedMovableEntries(_ entries: [MenuEntry], positions: [String: NSNumber], freshIDs: Set<String>) -> [MenuEntry] {
        let actual = entries.filter { $0.isRunning && freshIDs.contains($0.id) }
        let counts = Dictionary(actual.map { ($0.bundleID, 1) }, uniquingKeysWith: +)
        var resolved = actual.compactMap { entry -> (MenuEntry, String, Double)? in
            guard entry.canMove, let key = positionKey(for: entry, positions: positions, ownerItemCount: counts[entry.bundleID]),
                  let position = positions[key]?.doubleValue else { return nil }
            return (entry, key, position)
        }
        let keyCounts = Dictionary(resolved.map { ($0.1, 1) }, uniquingKeysWith: +)
        let ties = Dictionary(grouping: resolved, by: { $0.2 })
        resolved.removeAll { item in
            guard keyCounts[item.1] == 1 else { return true }
            guard let tied = ties[item.2], tied.count > 1 else { return false }
            return !tied.allSatisfy { $0.0.frame.width > 0 && abs($0.0.frame.midY - item.0.frame.midY) < 2 }
        }
        return resolved.sorted { lhs, rhs in lhs.2 == rhs.2 ? lhs.0.frame.midX < rhs.0.frame.midX : lhs.2 > rhs.2 }.map { $0.0 }
    }

    static func arrowMovePlan(in entries: [MenuEntry], sourceID: String, offset: Int) -> (participants: [MenuEntry], order: [String])? {
        guard offset != 0, let index = entries.firstIndex(where: { $0.id == sourceID }) else { return nil }
        let destination = index + offset
        guard entries.indices.contains(destination) else { return nil }
        let lower = min(index, destination)
        let participants = Array(entries[lower...max(index, destination)])
        var order = participants.map(\.id)
        let moved = order.remove(at: index - lower)
        order.insert(moved, at: destination - lower)
        return (participants, order)
    }

    func moveInList(_ entry: MenuEntry, offset: Int) {
        guard offset != 0, !moving else { return }
        do {
            let url = try grantedURL()
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let positions = try Self.readPositions(url)
            let participating = Self.orderedMovableEntries(items, positions: positions, freshIDs: freshItemIDs)
            guard participating.contains(where: { $0.id == entry.id }) else {
                lastError = L10n.text("layout.this.icon.cannot.currently.be.uniquely.matched"); return
            }
            guard let plan = Self.arrowMovePlan(in: participating, sourceID: entry.id, offset: offset) else { return }
            let order = plan.order
            performPositionChange(required: plan.participants, expectedOrder: order, adjacent: false, saveGeometry: true, nativeSourceID: entry.id) { current, matches in
                let keys = try order.map { id -> String in
                    guard let key = matches[id] else { throw MoveFailure.message(L10n.text("layout.the.icons.involved.in.arrow.movement.have")) }
                    return key
                }
                return try Self.reorderParticipants(keys, positions: current)
            }
        } catch { lastError = error.localizedDescription }
    }
    func move(_ entry: MenuEntry, before target: MenuEntry) { performMove(entry, relativeTo: target, before: true) }

    private func performMove(_ entry: MenuEntry, relativeTo target: MenuEntry, before: Bool) {
        let expected = before ? [entry.id, target.id] : [target.id, entry.id]
        performPositionChange(required: [entry, target], expectedOrder: expected, adjacent: true, saveGeometry: true, nativeSourceID: entry.id) { positions, matches in
            guard let fromKey = matches[entry.id], let targetKey = matches[target.id] else { throw MoveFailure.message(L10n.text("layout.could.not.uniquely.match.the.movement.target")) }
            var keys = Self.sortedPositionKeys(positions)
            keys.removeAll { $0 == fromKey }
            guard let index = keys.firstIndex(of: targetKey) else { throw MoveFailure.message(L10n.text("layout.the.target.position.has.changed.refresh.and")) }
            keys.insert(fromKey, at: index + (before ? 0 : 1))
            return try Self.assigningExistingSlots(keys, positions: positions)
        }
    }

    func captureCurrentOrder() -> [String] {
        let url: URL
        do { url = try grantedURL() }
        catch { status = L10n.text("layout.position.file.access.is.not.granted.saved"); return store.config.order }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let positions = try Self.readPositions(url)
            let current = items.filter { $0.isRunning && freshItemIDs.contains($0.id) }
            let ownerCounts = Dictionary(current.map { ($0.bundleID, 1) }, uniquingKeysWith: +)
            var resolved = current.compactMap { entry -> (entry: MenuEntry, key: String, position: Double)? in
                guard let key = Self.positionKey(for: entry, positions: positions, ownerItemCount: ownerCounts[entry.bundleID]),
                      let position = positions[key]?.doubleValue else { return nil }
                return (entry, key, position)
            }
            let keyCounts = Dictionary(resolved.map { ($0.key, 1) }, uniquingKeysWith: +)
            resolved.removeAll { keyCounts[$0.key] != 1 }
            let tied = Dictionary(grouping: resolved, by: { $0.position })
            // Equal preferred positions do not establish an order. Use current real geometry
            // only when every participant in that tie is actually visible on the same bar.
            resolved.removeAll { candidate in
                guard let group = tied[candidate.position], group.count > 1 else { return false }
                return !group.allSatisfy { $0.entry.frame.width > 0 && abs($0.entry.frame.midY - candidate.entry.frame.midY) < 2 }
            }
            let result = resolved.sorted { lhs, rhs in
                lhs.position == rhs.position ? lhs.entry.frame.midX < rhs.entry.frame.midX : lhs.position > rhs.position
            }.map { $0.entry.id }
            status = result.isEmpty ? L10n.text("layout.no.menu.bar.items.have.a.determinable") : L10n.text("layout.read.the.actual.order.of.0.icons", result.count)
            return result
        } catch {
            status = L10n.text("layout.could.not.read.actual.menu.bar.positions")
            return store.config.order
        }
    }

    func persistConfirmedOrder(_ order: [String]) {
        guard store.config.order != order else { return }
        persistedOrderAwaitingObservation = order
        store.config.order = order
    }

    func consumePersistedOrder(_ order: [String]) -> Bool {
        let matches = persistedOrderAwaitingObservation == order
        persistedOrderAwaitingObservation = nil
        return matches
    }

    func applySavedOrder(completion: ((Result<Void, Error>) -> Void)? = nil) {
        guard started else { completion?(.failure(MoveFailure.message(L10n.text("layout.the.app.is.not.running.the.ordering")))); return }
        let order = store.config.order
        // Debounced configuration observers must not discard a preset's result callback.
        if completion == nil, pendingSavedOrder, pendingSavedOrderIDs == order { drainSavedOrder(); return }
        if completion == nil, !pendingSavedOrder, activeSavedOrderIDs == order { return }
        let previous = pendingSavedOrderCompletion
        startupOrderRetryTask?.cancel(); startupOrderRetryTask = nil; waitingForStartupOrderRetry = false
        pendingStartupOrder = false
        orderDiagnostic = [:]
        pendingSavedOrderIDs = order
        pendingSavedOrderCompletion = completion
        pendingSavedOrder = true
        pendingOrderVisibilityChecked = false
        if moving { moveGeneration += 1; overflowExpansionCancellation?.cancel() }
        previous?(.failure(MoveFailure.message(L10n.text("layout.the.ordering.request.was.superseded.and.cancelled"))))
        drainSavedOrder()
    }
    private func drainSavedOrder() {
        guard started, pendingSavedOrder, !moving, !scanning, !waitingForOrderVisibility, !waitingForStartupOrderRetry else { return }
        if !accessibilityGranted && accessibilityCheck() {
            refresh()
            return
        }
        if !pendingOrderVisibilityChecked {
            pendingOrderVisibilityChecked = true
            applyVisibility()
        }
        if pendingGeneration != nil {
            waitingForOrderVisibility = true
            let epoch = lifecycle
            Task { [weak self] in
                guard let self else { return }
                while self.started && self.lifecycle == epoch && self.pendingGeneration != nil {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                self.waitingForOrderVisibility = false
                if self.started { self.drainSavedOrder() }
            }
            return
        }
        let requestedOrder = pendingSavedOrderIDs ?? store.config.order
        let completion = pendingSavedOrderCompletion
        let startupRequest = pendingStartupOrder
        pendingStartupOrder = false
        pendingSavedOrder = false; pendingSavedOrderIDs = nil; pendingSavedOrderCompletion = nil; pendingOrderVisibilityChecked = false
        if visibilityError != nil || desiredIDs != appliedIDs {
            reportSavedOrderFailure(visibilityError ?? L10n.text("layout.menu.bar.visibility.is.unconfirmed.the.preset"), completion: completion)
            return
        }
        if requestedOrder.count > 1 && !accessibilityGranted {
            reportSavedOrderFailure(L10n.text("layout.applying.preset.order.requires.accessibility.access"), completion: completion)
            return
        }
        let known = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let availability = Self.savedOrderAvailability(requestedOrder, entries: items, running: running, freshIDs: freshItemIDs)
        let pendingReasons = Dictionary(availability.pending.map { id -> (String, String) in
            let owner = id.components(separatedBy: "::").first ?? ""
            let ownerHasCurrentItem = items.contains { $0.bundleID == owner && freshItemIDs.contains($0.id) }
            return (id, ownerHasCurrentItem ? "storedIdentityNotPresent" : "ownerStatusItemNotDiscovered")
        }, uniquingKeysWith: { first, _ in first })
        let nonHosted = requestedOrder.filter { known[$0]?.frame.width == 0 }
        let nonHostedReasons = Dictionary(nonHosted.map { id -> (String, String) in
            let owner = known[id]?.bundleID ?? ""
            let hiddenByApp = store.config.rules[owner].map { $0.zone == .alwaysHidden || ($0.zone == .hidden && !isExpanded) } ?? false
            return (id, systemOverflowIDs.contains(id) ? "systemOverflow" : hiddenByApp ? "applicationHidden" : "noCurrentHostedSlot")
        }, uniquingKeysWith: { first, _ in first })
        orderDiagnostic = ["requestedIDs": requestedOrder, "pendingIDs": availability.pending, "pendingReasons": pendingReasons,
                           "inactiveSystemModuleIDs": availability.inactiveSystem, "systemOverflowIDs": systemOverflowIDs.sorted(),
                           "nonHostedIDs": nonHosted, "nonHostedReasons": nonHostedReasons, "startupRetried": startupOrderRetried]
        if startupRequest && !startupOrderRetried && (!availability.pending.isEmpty || !availability.inactiveSystem.isEmpty) {
            startupOrderRetried = true
            pendingStartupOrder = true; pendingSavedOrder = true; pendingSavedOrderIDs = requestedOrder; pendingSavedOrderCompletion = completion
            waitingForStartupOrderRetry = true
            status = L10n.text("layout.waiting.for.the.menu.bar.layout.to")
            let epoch = lifecycle
            startupOrderRetryTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard !Task.isCancelled, let self, self.started, self.lifecycle == epoch else { return }
                self.waitingForStartupOrderRetry = false
                self.startupOrderRetryTask = nil
                self.refresh()
                self.drainSavedOrder()
            }
            return
        }
        guard availability.pending.isEmpty else {
            reportSavedOrderFailure(L10n.text("layout.0.icons.in.the.saved.order.have", availability.pending.count), completion: completion)
            return
        }
        let participating = requestedOrder.compactMap { known[$0] }.filter(\.isRunning)
        guard participating.count > 1 else {
            if lastError == savedOrderError { lastError = nil; savedOrderError = nil }
            if !availability.inactiveSystem.isEmpty { status = L10n.text("layout.available.icons.applied.0.system.items.are", availability.inactiveSystem.count) }
            completion?(.success(())); return
        }
        let order = participating.map(\.id)
        activeSavedOrderIDs = requestedOrder
        performPositionChange(required: participating, expectedOrder: order, adjacent: false, saveGeometry: false,
                              completion: { [weak self] result in
            guard let self else { completion?(.failure(MoveFailure.message(L10n.text("layout.ordering.cancelled")))); return }
            self.finishSavedOrder(result, completion: completion)
        }) { positions, matches in
            let requiredKeys = try order.map { id -> String in
                guard let key = matches[id] else { throw MoveFailure.message(L10n.text("layout.the.preset.contains.unmatched.menu.bar.icons")) }
                return key
            }
            return try Self.reorderParticipants(requiredKeys, positions: positions)
        }
    }

    static func savedOrderAvailability(_ order: [String], entries: [MenuEntry], running: Set<String>, freshIDs: Set<String>) -> (pending: [String], inactiveSystem: [String]) {
        let known = Set(entries.map(\.id))
        let agent = "com.apple.MenuBarAgent"
        let optionalModules: Set<String> = ["airdrop", "focusmode", "audiovideo", "battery", "wifi"]
        let agentResponded = entries.contains { $0.bundleID == agent && freshIDs.contains($0.id) }
        var pending: [String] = [], inactive: [String] = []
        for id in order where !known.contains(id) {
            guard let owner = id.components(separatedBy: "::").first, running.contains(owner) else { continue }
            if agentResponded && optionalModules.contains(where: { id == agent + "::com.apple.menuextra." + $0 }) { inactive.append(id) }
            else { pending.append(id) }
        }
        return (pending, inactive)
    }

    static func unavailableLayoutMessage(_ ids: [String], systemOverflowIDs: Set<String>) -> String {
        if !ids.isEmpty && Set(ids).isSubset(of: systemOverflowIDs) {
            return L10n.text("layout.these.icons.are.in.the.system.hidden")
        }
        return L10n.text("layout.icons.involved.in.ordering.have.no.usable")
    }

    private func reportSavedOrderFailure(_ message: String, completion: ((Result<Void, Error>) -> Void)?) {
        savedOrderError = message
        lastError = message
        status = message
        completion?(.failure(MoveFailure.message(message)))
    }

    private func finishSavedOrder(_ result: Result<Void, Error>, completion: ((Result<Void, Error>) -> Void)?) {
        if case .failure = result {
            activeSavedOrderIDs = nil
            completion?(result)
            return
        }
        // A successful position transaction must also confirm restoration of the preset's
        // visibility assertion after its temporary all-visible phase.
        waitingForOrderVisibility = true
        let epoch = lifecycle
        Task { [weak self] in
            guard let self else { completion?(.failure(MoveFailure.message(L10n.text("layout.preset.cancelled")))); return }
            while self.started && self.lifecycle == epoch && self.pendingGeneration != nil {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            self.waitingForOrderVisibility = false
            self.activeSavedOrderIDs = nil
            if !self.started || self.lifecycle != epoch { completion?(.failure(MoveFailure.message(L10n.text("layout.preset.cancelled")))) }
            else if self.visibilityError != nil || self.desiredIDs != self.appliedIDs {
                completion?(.failure(MoveFailure.message(self.visibilityError ?? L10n.text("layout.the.system.did.not.confirm.the.preset"))))
            } else {
                if self.lastError == self.savedOrderError { self.lastError = nil; self.savedOrderError = nil }
                if let inactive = self.orderDiagnostic["inactiveSystemModuleIDs"] as? [String], !inactive.isEmpty {
                    self.status = L10n.text("layout.available.icons.applied.0.system.items.are", inactive.count)
                }
                completion?(.success(()))
            }
            if self.pendingSavedOrder { self.drainSavedOrder() }
        }
    }

    func restoreLastLayoutBackup() {
        guard !moving else { lastError = L10n.text("layout.ordering.is.in.progress.restore.the.backup"); return }
        guard let path = UserDefaults.standard.string(forKey: lastBackupKey) else { lastError = L10n.text("layout.no.menu.bar.layout.backup.yet"); return }
        let backup = URL(fileURLWithPath: path).standardizedFileURL
        guard backup.deletingLastPathComponent() == Self.backupDirectory.standardizedFileURL else { lastError = L10n.text("layout.invalid.layout.backup.path"); return }
        do {
            let saved = try Self.readPositions(backup)
            performPositionChange(required: [], expectedOrder: [], adjacent: false, saveGeometry: false, restoring: true, restoreKeys: Set(saved.keys)) { positions, _ in
                guard !Set(positions.keys).isDisjoint(with: saved.keys) else { throw MoveFailure.message(L10n.text("layout.the.backup.has.no.existing.position.keys")) }
                return Self.mergePositions(backup: saved, current: positions)
            }
        } catch { lastError = L10n.text("layout.could.not.read.the.layout.backup.0", error.localizedDescription) }
    }

    static func mergePositions(backup: [String: NSNumber], current: [String: NSNumber]) -> [String: NSNumber] {
        var merged = current
        for (key, value) in backup where current[key] != nil { merged[key] = value }
        return merged
    }

    private static var backupDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.mike.aisubgauge/位置备份", isDirectory: true)
    }
    private static func sortedPositionKeys(_ positions: [String: NSNumber]) -> [String] {
        positions.keys.sorted {
            let a = positions[$0]?.doubleValue ?? 0, b = positions[$1]?.doubleValue ?? 0
            return a == b ? $0 < $1 : a > b
        }
    }
    static func reorderParticipants(_ desiredKeys: [String], positions: [String: NSNumber]) throws -> [String: NSNumber] {
        let participants = Set(desiredKeys)
        guard participants.count == desiredKeys.count, participants.isSubset(of: Set(positions.keys)) else { throw MoveFailure.message(L10n.text("layout.participating.position.keys.are.duplicated.or.no")) }
        var next = 0
        let keys = sortedPositionKeys(positions).map { key -> String in
            guard participants.contains(key) else { return key }
            defer { next += 1 }
            return desiredKeys[next]
        }
        return try assigningExistingSlots(keys, positions: positions)
    }

    static func assigningExistingSlots(_ keys: [String], positions: [String: NSNumber]) throws -> [String: NSNumber] {
        guard keys.count == positions.count, Set(keys) == Set(positions.keys) else { throw MoveFailure.message(L10n.text("layout.position.key.sets.differ.the.system.layout")) }
        let slots = sortedPositionKeys(positions).compactMap { positions[$0] }
        return Dictionary(uniqueKeysWithValues: zip(keys, slots))
    }
    static func layoutParticipantsVisible(_ ids: [String], entries: [MenuEntry], freshIDs: Set<String>, screens: [CGRect]) -> Bool {
        guard ids.count > 1, Set(ids).count == ids.count, Set(ids).isSubset(of: freshIDs) else { return false }
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let participants = ids.compactMap { byID[$0] }
        guard participants.count == ids.count, participants.allSatisfy({ $0.frame.width.isFinite && $0.frame.height.isFinite && $0.frame.width > 0 && $0.frame.height > 0 }) else { return false }
        guard participants.allSatisfy({ entry in
            !participants.contains { $0.id != entry.id && abs($0.frame.midY - entry.frame.midY) < 2 && $0.frame.intersection(entry.frame).width > 1 }
        }) else { return false }
        return screens.contains { screen in
            participants.allSatisfy { screen.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
        }
    }
    private static func activeScreenFrames() -> [CGRect] {
        var displays = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(displays.count), &displays, &count) == .success else { return [] }
        return displays.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    private static func geometryMatches(_ ids: [String], snapshot: [MenuEntry], adjacent: Bool) -> Bool {
        guard ids.count > 1 else { return false }
        let byID = Dictionary(snapshot.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let entries = ids.compactMap { byID[$0] }
        guard entries.count == ids.count, entries.allSatisfy({ $0.frame.width > 0 }),
              let first = entries.first, entries.allSatisfy({ abs($0.frame.midY - first.frame.midY) < 2 }) else { return false }
        for (left, right) in zip(entries, entries.dropFirst()) {
            guard left.frame.midX < right.frame.midX else { return false }
            if adjacent && snapshot.contains(where: { other in
                other.id != left.id && other.id != right.id && other.frame.width > 0 &&
                abs(other.frame.midY - left.frame.midY) < 2 && other.frame.midX > left.frame.midX && other.frame.midX < right.frame.midX
            }) { return false }
        }
        return true
    }
    private func freshSnapshot() async -> MenuScanner.Snapshot {
        let ownStatusFrames = currentOwnStatusFrames()
        let result: MenuScanner.Snapshot = await withCheckedContinuation { continuation in
            worker.async { [scanner] in
                scanner.ownStatusFrames = ownStatusFrames
                continuation.resume(returning: scanner.scan())
            }
        }
        systemOverflowIDs = result.systemOverflowIDs
        return result
    }

    private func nativeDrag(source: String, target: String, before: Bool) async -> (undo: MenuScanner.DragUndo?, error: String?) {
        let screens = Self.activeScreenFrames()
        let ownStatusFrames = currentOwnStatusFrames()
        let result: (undo: MenuScanner.DragUndo?, error: String?) = await withCheckedContinuation { continuation in
            worker.async { [scanner] in
                scanner.ownStatusFrames = ownStatusFrames
                continuation.resume(returning: scanner.commandDrag(sourceID: source, targetID: target, before: before, screens: screens))
            }
        }
        if let undo = result.undo { movementPointerPlacement = undo.lastPointerPosition }
        return result
    }

    static func nativeSourceMove(in order: [String], sourceID: String) -> (source: String, target: String, before: Bool)? {
        guard order.count > 1, Set(order).count == order.count, let index = order.firstIndex(of: sourceID) else { return nil }
        return (sourceID, order[index == 0 ? 1 : index - 1], index == 0)
    }

    private func performNativeOrder(_ order: [String], adjacent: Bool, ticket: Int, sourceID: String?) async throws -> [String] {
        let initial = await freshSnapshot()
        guard Self.layoutParticipantsVisible(order, entries: initial.items, freshIDs: initial.freshIDs, screens: Self.activeScreenFrames()) else {
            throw MoveFailure.message(L10n.text("layout.icons.involved.in.native.dragging.are.no"))
        }
        guard let participant = initial.items.first(where: { $0.id == order.first }),
              let screen = Self.activeScreenFrames().first(where: { $0.contains(participant.frame) }) else {
            throw MoveFailure.message(L10n.text("layout.the.native.drag.source.is.not.fully"))
        }
        let originalOrder = initial.items.filter { initial.freshIDs.contains($0.id) && $0.frame.width > 0 && screen.contains($0.frame) && abs($0.frame.midY - participant.frame.midY) < 2 }.sorted { $0.frame.midX < $1.frame.midX }.map(\.id)
        let recordURL = store.url.deletingLastPathComponent().appendingPathComponent("原生拖动记录.json")
        var record: [String: Any] = ["time": ISO8601DateFormatter().string(from: Date()), "state": L10n.text("layout.preparing.to.drag"), "originalOrder": originalOrder, "requestedOrder": order]
        var undo: [MenuScanner.DragUndo] = []
        var attempts: [[String: Any]] = []
        func saveRecord(_ state: String) throws {
            record["state"] = state; record["attempts"] = attempts
            try PrivateFiles.write(JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), to: recordURL)
        }
        try saveRecord(L10n.text("layout.preparing.to.drag"))
        do {
            for index in 0..<(sourceID == nil ? order.count - 1 : 1) {
                guard started, ticket == moveGeneration else { throw MoveFailure.message(L10n.text("layout.native.drag.cancelled")) }
                let current = await freshSnapshot()
                guard Self.layoutParticipantsVisible(order, entries: current.items, freshIDs: current.freshIDs, screens: Self.activeScreenFrames()) else {
                    throw MoveFailure.message(L10n.text("layout.an.icon.entered.overflow.or.left.the"))
                }
                let actual = current.items.filter { Set(order).contains($0.id) }.sorted { $0.frame.midX < $1.frame.midX }.map(\.id)
                let source: String, target: String, before: Bool
                if let sourceID {
                    if Self.geometryMatches(order, snapshot: current.items, adjacent: adjacent) { continue }
                    guard let move = Self.nativeSourceMove(in: order, sourceID: sourceID) else { throw MoveFailure.message(L10n.text("layout.the.native.drag.source.is.no.longer")) }
                    source = move.source; target = move.target; before = move.before
                } else {
                    if actual[index] == order[index] && !(adjacent && !Self.geometryMatches(order, snapshot: current.items, adjacent: true)) { continue }
                    source = order[index]
                    target = actual[index] == source ? order[index + 1] : actual[index]
                    before = true
                }
                attempts.append(["source": source, "target": target, "before": before])
                try saveRecord(L10n.text("layout.dragging"))
                let result = await nativeDrag(source: source, target: target, before: before)
                if let reversal = result.undo {
                    undo.append(reversal)
                    attempts[attempts.count - 1]["originalLeft"] = reversal.left ?? ""
                    attempts[attempts.count - 1]["originalRight"] = reversal.right ?? ""
                    attempts[attempts.count - 1]["sourceFrame"] = NSStringFromRect(reversal.sourceFrame)
                    attempts[attempts.count - 1]["targetFrame"] = NSStringFromRect(reversal.targetFrame)
                    attempts[attempts.count - 1]["start"] = NSStringFromPoint(reversal.start)
                    attempts[attempts.count - 1]["end"] = NSStringFromPoint(reversal.end)
                    attempts[attempts.count - 1]["eventTime"] = ISO8601DateFormatter().string(from: Date())
                }
                if let error = result.error { throw MoveFailure.message(error) }
                var verified = false
                var checks: [[[String: Any]]] = []
                for _ in 0..<8 {
                    try? await Task.sleep(nanoseconds: 125_000_000)
                    let snapshot = await freshSnapshot()
                    checks.append(order.map { id -> [String: Any] in
                        ["id": id, "frame": snapshot.items.first(where: { $0.id == id }).map { NSStringFromRect($0.frame) } ?? "missing",
                         "fresh": snapshot.freshIDs.contains(id), "hosted": snapshot.hostedIDs.contains(id)]
                    })
                    if Self.geometryMatches(before ? [source, target] : [target, source], snapshot: snapshot.items, adjacent: adjacent) { verified = true; break }
                }
                attempts[attempts.count - 1]["checks"] = checks
                attempts[attempts.count - 1]["eventFlags"] = CGEventFlags.maskCommand.rawValue
                attempts[attempts.count - 1]["clickState"] = 1
                attempts[attempts.count - 1]["prepositionMouse"] = true
                guard verified else { throw MoveFailure.message(L10n.text("layout.actual.icon.positions.failed.validation.after.command")) }
            }
            let result = await freshSnapshot()
            guard started, ticket == moveGeneration,
                  Self.layoutParticipantsVisible(order, entries: result.items, freshIDs: result.freshIDs, screens: Self.activeScreenFrames()),
                  Self.geometryMatches(order, snapshot: result.items, adjacent: adjacent) else {
                throw MoveFailure.message(L10n.text("layout.the.final.actual.order.failed.validation.after"))
            }
            freshItemIDs = result.freshIDs
            items = ordered(markMovability(result.items))
            try saveRecord(L10n.text("layout.actual.order.confirmed"))
            // Native preference persistence may lag behind the verified visible geometry.
            return result.items.filter { entry in result.freshIDs.contains(entry.id) && entry.frame.width > 0 && items.first(where: { $0.id == entry.id })?.canMove == true }.map(\.id)
        } catch {
            var recoveryError: String?
            if started {
                for reversal in undo.reversed() {
                    let target = reversal.right ?? reversal.left
                    guard let target else { recoveryError = L10n.text("layout.original.neighbors.no.longer.exist"); break }
                    let result = await nativeDrag(source: reversal.source, target: target, before: reversal.right != nil)
                    if let error = result.error { recoveryError = error; break }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
            let restored = await freshSnapshot()
            freshItemIDs = restored.freshIDs
            items = ordered(markMovability(restored.items))
            let recovered = recoveryError == nil && Self.geometryMatches(originalOrder, snapshot: restored.items, adjacent: false)
            record["error"] = error.localizedDescription
            record["recoveryError"] = recoveryError ?? ""
            try? saveRecord(recovered ? L10n.text("layout.original.relative.order.restored.after.failure") : L10n.text("layout.restoration.after.failure.unconfirmed"))
            throw MoveFailure.message(error.localizedDescription + (recovered ? L10n.text("layout.original.relative.order.restoration.confirmed") : L10n.text("layout.original.neighbor.order.restoration.is.unconfirmed.keep")))
        }
    }

    private func performPositionChange(required: [MenuEntry], expectedOrder: [String], adjacent: Bool,
                                       saveGeometry: Bool, restoring: Bool = false, restoreKeys: Set<String> = [], nativeSourceID: String? = nil,
                                       completion: ((Result<Void, Error>) -> Void)? = nil,
                                       revise: @escaping ([String: NSNumber], [String: String]) throws -> [String: NSNumber]) {
        guard !moving else { completion?(.failure(MoveFailure.message(L10n.text("layout.another.ordering.operation.is.running.try.again")))); return }
        guard accessibilityGranted else {
            lastError = L10n.text("layout.changing.order.requires.accessibility.access")
            completion?(.failure(MoveFailure.message(L10n.text("layout.changing.order.requires.accessibility.access"))))
            return
        }
        let previousFront = NSWorkspace.shared.frontmostApplication
        let previousPolicy = NSApp.activationPolicy()
        moving = true
        moveGeneration += 1
        let ticket = moveGeneration
        updateBusy()
        Task { [weak self] in
            guard let self else { completion?(.failure(MoveFailure.message(L10n.text("layout.ordering.cancelled")))); return }
            var outcome: Result<Void, Error> = .failure(MoveFailure.message(L10n.text("layout.ordering.cancelled")))
            var createdJournal = false
            var scopedURL: URL?
            var accessing = false
            var original: [String: NSNumber]?
            var written: [String: NSNumber]?
            var nativeOrder: [String]?
            var overflowPointerOrigin: CGPoint?
            self.movementPointerPlacement = nil
            self.orderDiagnostic.removeValue(forKey: "overflowExpansion")
            self.orderDiagnostic.removeValue(forKey: "layoutReadsBeforeExpansion")
            var activationDiagnostic: [String: Any] = ["previousPolicy": previousPolicy.rawValue,
                "policyBeforeSet": NSApp.activationPolicy().rawValue, "frontBeforeSet": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "",
                "isActiveBeforeSet": NSApp.isActive]
            defer {
                self.pendingPositionRollback = nil
                self.overflowExpansionCancellation?.cancel(); self.overflowExpansionCancellation = nil
                if accessing { scopedURL?.stopAccessingSecurityScopedResource() }
                if let origin = overflowPointerOrigin, let placed = self.movementPointerPlacement, let current = CGEvent(source: nil)?.location,
                   abs(current.x - placed.x) < 1, abs(current.y - placed.y) < 1,
                   !CGEventSource.buttonState(.hidSystemState, button: .left), !CGEventSource.buttonState(.hidSystemState, button: .right) {
                    CGWarpMouseCursorPosition(origin)
                    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: origin, mouseButton: .left)?.post(tap: .cghidEventTap)
                }
                self.movementPointerPlacement = nil
                // Capture focus before restoring accessory policy, which can change the front app.
                let stillFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
                activationDiagnostic["wasFrontAtFinish"] = stillFront
                if let policy = self.movementActivationPolicy {
                    activationDiagnostic["restorePolicyResult"] = NSApp.setActivationPolicy(policy)
                    self.movementActivationPolicy = nil
                }
                activationDiagnostic["policyAfterRestore"] = NSApp.activationPolicy().rawValue
                self.orderDiagnostic["activation"] = activationDiagnostic
                if stillFront, let previousFront, !previousFront.isTerminated, previousFront.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousFront.activate(options: []) }
                self.movementReveal = false
                self.applyVisibility()
                self.moving = false; self.updateBusy()
                completion?(outcome)
                if self.pendingSavedOrder { self.drainSavedOrder() }
            }
            guard self.started, ticket == self.moveGeneration else { return }
            if previousPolicy == .accessory {
                self.movementActivationPolicy = previousPolicy
                activationDiagnostic["setRegularResult"] = NSApp.setActivationPolicy(.regular)
                activationDiagnostic["policyImmediatelyAfterSet"] = NSApp.activationPolicy().rawValue
                // LaunchServices applies the policy asynchronously; request activation once afterward.
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard self.started, ticket == self.moveGeneration else { return }
            }
            activationDiagnostic["policyBeforeActivate"] = NSApp.activationPolicy().rawValue
            self.orderDiagnostic["activation"] = activationDiagnostic
            self.movementReveal = true
            NSApp.activate(ignoringOtherApps: true)
            self.applyVisibility()
            do {
                for _ in 0..<60 {
                    if self.pendingGeneration == nil { break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                guard self.started, ticket == self.moveGeneration, self.desiredIDs == self.appliedIDs else { throw MoveFailure.message(L10n.text("layout.temporary.icon.reveal.did.not.complete.movement")) }
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard self.started, ticket == self.moveGeneration else { throw MoveFailure.message(L10n.text("layout.layout.operation.cancelled")) }
                let front = NSWorkspace.shared.frontmostApplication
                activationDiagnostic["frontBeforeFresh"] = front?.bundleIdentifier ?? ""
                activationDiagnostic["isActiveBeforeFresh"] = NSApp.isActive
                activationDiagnostic["policyBeforeFresh"] = NSApp.activationPolicy().rawValue
                self.orderDiagnostic["activation"] = activationDiagnostic
                guard NSApp.isActive, front?.processIdentifier == ProcessInfo.processInfo.processIdentifier else {
                    throw MoveFailure.message(L10n.text("layout.the.app.menu.did.not.switch.click"))
                }
                var initial = await self.freshSnapshot()
                guard self.started, ticket == self.moveGeneration else { throw MoveFailure.message(L10n.text("layout.layout.operation.cancelled")) }
                var layoutReadAttempts = 1
                for _ in 0..<2 {
                    if Self.layoutParticipantsVisible(expectedOrder, entries: initial.items, freshIDs: initial.freshIDs, screens: Self.activeScreenFrames()) { break }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard self.started, ticket == self.moveGeneration else { throw MoveFailure.message(L10n.text("layout.layout.operation.cancelled")) }
                    initial = await self.freshSnapshot()
                    layoutReadAttempts += 1
                }
                guard self.started, ticket == self.moveGeneration else { throw MoveFailure.message(L10n.text("layout.layout.operation.cancelled")) }
                if !Self.layoutParticipantsVisible(expectedOrder, entries: initial.items, freshIDs: initial.freshIDs, screens: Self.activeScreenFrames()),
                   !Set(expectedOrder).isDisjoint(with: initial.systemOverflowIDs) {
                    self.orderDiagnostic["layoutReadsBeforeExpansion"] = layoutReadAttempts
                    guard let pointerOrigin = CGEvent(source: nil)?.location else { throw MoveFailure.message(L10n.text("layout.could.not.read.the.pointer.position.the")) }
                    overflowPointerOrigin = pointerOrigin
                    let screens = Self.activeScreenFrames()
                    let cancellation = Progress(totalUnitCount: 1)
                    self.overflowExpansionCancellation = cancellation
                    let expansion: (point: CGPoint?, diagnostic: [String: Any]) = await withCheckedContinuation { continuation in
                        self.worker.async { [scanner = self.scanner] in
                            continuation.resume(returning: scanner.tryExpandSystemOverflow(screens: screens, isCancelled: { cancellation.isCancelled }))
                        }
                    }
                    self.overflowExpansionCancellation = nil
                    self.movementPointerPlacement = expansion.point
                    self.orderDiagnostic["overflowExpansion"] = expansion.diagnostic
                    guard self.started, ticket == self.moveGeneration else { throw MoveFailure.message(L10n.text("layout.layout.operation.cancelled")) }
                    for _ in 0..<3 {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        guard self.started, ticket == self.moveGeneration else { throw MoveFailure.message(L10n.text("layout.layout.operation.cancelled")) }
                        initial = await self.freshSnapshot()
                        layoutReadAttempts += 1
                        guard self.started, ticket == self.moveGeneration else { throw MoveFailure.message(L10n.text("layout.layout.operation.cancelled")) }
                        if Self.layoutParticipantsVisible(expectedOrder, entries: initial.items, freshIDs: initial.freshIDs, screens: Self.activeScreenFrames()) { break }
                    }
                }
                if var expansion = self.orderDiagnostic["overflowExpansion"] as? [String: Any] {
                    expansion["finalReady"] = Self.layoutParticipantsVisible(expectedOrder, entries: initial.items, freshIDs: initial.freshIDs, screens: Self.activeScreenFrames())
                    self.orderDiagnostic["overflowExpansion"] = expansion
                }
                self.orderDiagnostic["layoutReadAttempts"] = layoutReadAttempts
                self.orderDiagnostic["initialPositions"] = initial.items.filter { expectedOrder.contains($0.id) }.map { ["id": $0.id, "frame": NSStringFromRect($0.frame)] }
                guard self.started, ticket == self.moveGeneration else { throw MoveFailure.message(L10n.text("layout.layout.operation.cancelled")) }
                self.freshItemIDs = initial.freshIDs
                self.items = self.ordered(self.markMovability(initial.items))
                if !restoring && !Self.layoutParticipantsVisible(expectedOrder, entries: initial.items, freshIDs: initial.freshIDs, screens: Self.activeScreenFrames()) {
                    let unavailable = expectedOrder.filter { id in !initial.freshIDs.contains(id) || initial.items.first(where: { $0.id == id })?.frame.width ?? 0 <= 0 }
                    self.orderDiagnostic["positionPendingIDs"] = unavailable.isEmpty ? expectedOrder : unavailable
                    self.orderDiagnostic["systemOverflowIDs"] = initial.systemOverflowIDs.sorted()
                    throw MoveFailure.message(Self.unavailableLayoutMessage(unavailable, systemOverflowIDs: initial.systemOverflowIDs))
                }
                if !restoring && Self.geometryMatches(expectedOrder, snapshot: initial.items, adjacent: adjacent) {
                    if saveGeometry { self.persistConfirmedOrder(self.captureCurrentOrder()) }
                    self.lastError = nil
                    self.status = L10n.text("layout.actual.menu.bar.order.already.matches.the")
                    outcome = .success(())
                    return
                }
                let url = try self.grantedURL()
                scopedURL = url
                accessing = url.startAccessingSecurityScopedResource()
                let positions = try Self.readPositions(url)
                var matches: [String: String] = [:]
                var missing: [String] = []
                let ownerCounts = Dictionary(initial.items.map { ($0.bundleID, 1) }, uniquingKeysWith: +)
                for entry in required {
                    if let key = Self.positionKey(for: entry, positions: positions, ownerItemCount: ownerCounts[entry.bundleID]) { matches[entry.id] = key }
                    else { missing.append(entry.name + (entry.title.isEmpty ? "" : "（" + entry.title + "）")) }
                }
                guard missing.isEmpty, Set(matches.values).count == matches.count else {
                    throw MoveFailure.message(L10n.text("layout.could.not.uniquely.match.existing.position.keys") + missing.joined(separator: "、"))
                }
                let revised = try revise(positions, matches)
                guard Set(revised.keys) == Set(positions.keys) else { throw MoveFailure.message(L10n.text("layout.the.layout.operation.tried.to.change.the")) }
                var verificationOrder = expectedOrder
                if restoring {
                    if revised == positions {
                        self.status = L10n.text("layout.existing.position.values.already.match.the.backup")
                        outcome = .success(())
                        return
                    }
                    let actual = initial.items.filter { initial.freshIDs.contains($0.id) && $0.frame.width > 0 }
                    let resolved = actual.compactMap { entry -> (String, String)? in
                        guard let key = Self.positionKey(for: entry, positions: revised, ownerItemCount: ownerCounts[entry.bundleID]), restoreKeys.contains(key) else { return nil }
                        return (entry.id, key)
                    }
                    guard resolved.count > 1, Set(resolved.map { $0.1 }).count == resolved.count else {
                        throw MoveFailure.message(L10n.text("layout.fewer.than.two.current.icons.exactly.match"))
                    }
                    let restoredValues = resolved.compactMap { revised[$0.1]?.doubleValue }
                    guard Set(restoredValues).count == restoredValues.count else {
                        throw MoveFailure.message(L10n.text("layout.backup.participants.share.a.position.slot.restoration"))
                    }
                    verificationOrder = resolved.sorted { (revised[$0.1]?.doubleValue ?? 0) > (revised[$1.1]?.doubleValue ?? 0) }.map { $0.0 }
                }
                guard Self.layoutParticipantsVisible(verificationOrder, entries: initial.items, freshIDs: initial.freshIDs, screens: Self.activeScreenFrames()) else {
                    throw MoveFailure.message(L10n.text("layout.icons.involved.in.restoration.are.hidden.or"))
                }
                if revised == positions && Self.geometryMatches(verificationOrder, snapshot: initial.items, adjacent: adjacent) {
                    self.status = L10n.text("layout.menu.bar.layout.already.matches.the.target"); outcome = .success(()); return
                }
                let backup = Self.backupDirectory.appendingPathComponent("菜单栏-\(UUID().uuidString).plist")
                try PrivateFiles.write(BoundedFile.read(url, maximum: 5_000_000), to: backup)
                guard try Self.readPositions(url) == positions else { throw MoveFailure.message(L10n.text("layout.the.system.position.table.just.changed.refresh")) }
                if !restoring { UserDefaults.standard.set(backup.path, forKey: self.lastBackupKey) }
                try self.saveLayoutJournal(original: positions, written: revised)
                createdJournal = true
                original = positions
                written = revised
                self.pendingPositionRollback = (url, positions, revised)
                try await Self.writePositionsConfirmed(revised, expected: positions, url: url) { self.started && ticket == self.moveGeneration }
                guard self.started, ticket == self.moveGeneration else { throw MoveFailure.message(L10n.text("layout.layout.operation.cancelled.restoring.original.positions")) }
                var confirmed = false
                for _ in 0..<12 {
                    guard self.started, ticket == self.moveGeneration else { throw MoveFailure.message(L10n.text("layout.layout.operation.cancelled.restoring.original.positions")) }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    let snapshot = await self.freshSnapshot()
                    guard self.started, ticket == self.moveGeneration else { throw MoveFailure.message(L10n.text("layout.layout.operation.cancelled.restoring.original.positions")) }
                    self.freshItemIDs = snapshot.freshIDs
                    self.items = self.ordered(self.markMovability(snapshot.items))
                    if Self.geometryMatches(verificationOrder, snapshot: snapshot.items, adjacent: adjacent) { confirmed = true; break }
                }
                if !confirmed {
                    // The agent may retain in-memory positions. End this file transaction before
                    // native dragging so its normal preference writes cannot be undone by our old journal.
                    try Self.rollbackPositions(original: positions, written: revised, url: url)
                    if createdJournal { try self.clearLayoutJournal(); createdJournal = false }
                    original = nil; written = nil; self.pendingPositionRollback = nil
                    self.status = L10n.text("layout.writing.the.position.file.did.not.reorder")
                    nativeOrder = try await self.performNativeOrder(verificationOrder, adjacent: adjacent, ticket: ticket, sourceID: nativeSourceID)
                }
                if saveGeometry { self.persistConfirmedOrder(nativeOrder ?? self.captureCurrentOrder()) }
                self.items = self.ordered(self.items)
                if createdJournal { try self.clearLayoutJournal() }
                self.lastError = nil
                outcome = .success(())
                self.status = nativeOrder != nil ? (restoring ? L10n.text("layout.native.dragging.restored.the.backup.icons.relative") : L10n.text("layout.native.dragging.passed.actual.icon.order.validation")) : (restoring ? L10n.text("layout.layout.backup.restored.and.actual.positions.verified") : L10n.text("layout.icon.order.moved.and.actual.positions.verified"))
            } catch {
                var restoration = ""
                if let original, let written, let url = scopedURL {
                    do {
                        try Self.rollbackPositions(original: original, written: written, url: url)
                        if createdJournal { try self.clearLayoutJournal() }
                    } catch { restoration = L10n.text("layout.could.not.restore.original.positions.keep.the") }
                }
                self.lastError = error.localizedDescription + restoration
                self.status = self.lastError ?? error.localizedDescription
                outcome = .failure(MoveFailure.message(error.localizedDescription + restoration))
            }
        }
    }
    private var layoutJournalURL: URL { store.url.deletingLastPathComponent().appendingPathComponent("布局事务.json") }
    private func saveLayoutJournal(original: [String: NSNumber], written: [String: NSNumber]) throws {
        guard !FileManager.default.fileExists(atPath: layoutJournalURL.path) else { throw MoveFailure.message(L10n.text("layout.an.unrestored.layout.transaction.exists.grant.position")) }
        let value: [String: Any] = ["version": 1, "original": original, "written": written]
        try PrivateFiles.write(JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), to: layoutJournalURL)
    }
    private func clearLayoutJournal() throws {
        if FileManager.default.fileExists(atPath: layoutJournalURL.path) { try FileManager.default.removeItem(at: layoutJournalURL) }
    }
    private func recoverPendingLayout() {
        guard FileManager.default.fileExists(atPath: layoutJournalURL.path) else { return }
        do {
            let value = try JSONSerialization.jsonObject(with: BoundedFile.read(layoutJournalURL, maximum: 5_000_000)) as? [String: Any]
            guard value?["version"] as? Int == 1, let original = value?["original"] as? [String: NSNumber], let written = value?["written"] as? [String: NSNumber],
                  !original.isEmpty, Set(original.keys) == Set(written.keys), original.values.allSatisfy({ CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue.isFinite && $0.doubleValue >= 0 }),
                  written.values.allSatisfy({ CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue.isFinite && $0.doubleValue >= 0 }) else {
                throw MoveFailure.message(L10n.text("layout.the.unfinished.layout.transaction.record.is.invalid"))
            }
            let url = try grantedURL()
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            try Self.rollbackPositions(original: original, written: written, url: url)
            try clearLayoutJournal()
            status = L10n.text("layout.the.last.unconfirmed.layout.transaction.was.restored")
        } catch { lastError = L10n.text("layout.unfinished.layout.restoration") + error.localizedDescription }
    }

    private static func rollbackPositions(original: [String: NSNumber], written: [String: NSNumber], url: URL) throws {
        let baseline = try readPositions(url)
        var restored = baseline
        for (key, previous) in original where baseline[key] != nil && baseline[key] == written[key] { restored[key] = previous }
        try writePositionsCoordinated(restored, expected: baseline, url: url)
        guard try readPositions(url) == restored else { throw MoveFailure.message(L10n.text("layout.restoration.readback.differs")) }
    }

    private static func writePositionsConfirmed(_ positions: [String: NSNumber], expected: [String: NSNumber], url: URL,
                                                shouldContinue: () -> Bool) async throws {
        guard shouldContinue() else { throw MoveFailure.message(L10n.text("layout.layout.write.cancelled")) }
        // A single writer prevents a late cfprefsd update from undoing a confirmed rollback.
        try writePositionsCoordinated(positions, expected: expected, url: url)
        for _ in 0..<10 {
            guard shouldContinue() else { throw MoveFailure.message(L10n.text("layout.layout.write.cancelled")) }
            if try readPositions(url) == positions { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        throw MoveFailure.message(L10n.text("layout.system.position.writes.failed.the.timed.readback"))
    }

    private static func writePositionsCoordinated(_ positions: [String: NSNumber], expected: [String: NSNumber], url: URL) throws {
        if positions == expected { return }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var writingError: Error?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            do {
                let originalData = try BoundedFile.read(coordinatedURL, maximum: 5_000_000)
                var format = PropertyListSerialization.PropertyListFormat.binary
                guard var root = try PropertyListSerialization.propertyList(from: originalData, options: [], format: &format) as? [String: Any],
                      let current = root["TrailingItemPreferredPositions"] as? [String: NSNumber], current == expected else {
                    throw MoveFailure.message(L10n.text("layout.the.system.position.table.changed.concurrently.other"))
                }
                root["TrailingItemPreferredPositions"] = positions
                let output = try PropertyListSerialization.data(fromPropertyList: root, format: format, options: 0)
                guard try BoundedFile.read(coordinatedURL, maximum: 5_000_000) == originalData else { throw MoveFailure.message(L10n.text("layout.another.process.is.updating.the.menu.bar")) }
                try output.write(to: coordinatedURL, options: .atomic)
            } catch { writingError = error }
        }
        if let coordinationError { throw coordinationError }
        if let writingError { throw writingError }
    }
}
