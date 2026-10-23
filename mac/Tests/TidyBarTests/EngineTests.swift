import AppKit
import ApplicationServices
import Testing
@testable import TidyBar

extension TidyBarTests {
@Suite
final class EngineTests {
    @MainActor
    @Test
    func testAllowlistRetainsNewAppsDiscoveredOwnersAndOwnEntry() {
        let allowed = MenuEngine.allowedIDs(running: ["visible", "hidden", "newly-launched"],
                                            discovered: ["hosted-owner", "hidden"],
                                            own: "self", hidden: ["hidden", "self", "not-running"])
        #expect(allowed == ["visible", "newly-launched", "hosted-owner", "self"])
    }

    @MainActor
    @Test
    func testAllowlistDoesNotInventStoppedHiddenApps() {
        #expect(MenuEngine.allowedIDs(running: [], discovered: [], own: "self", hidden: ["stopped"]) == ["self"])
    }

    @MainActor
    @Test
    func testCollectionRequiresTheRunningCopyToMatchLaunchServices() {
        let installed = URL(fileURLWithPath: "/Applications/AI SubGauge.app", isDirectory: true)
        let development = URL(fileURLWithPath: "/tmp/build/dist/AI SubGauge.app", isDirectory: true)
        #expect(MenuEngine.collectionPreservesOwnEntry(bundleURL: installed, resolvedURL: installed))
        #expect(!MenuEngine.collectionPreservesOwnEntry(bundleURL: development, resolvedURL: installed))
        #expect(!MenuEngine.collectionPreservesOwnEntry(bundleURL: installed, resolvedURL: development))
        #expect(!MenuEngine.collectionPreservesOwnEntry(bundleURL: installed, resolvedURL: nil))
        #expect(!MenuEngine.collectionPreservesOwnEntry(bundleURL: URL(fileURLWithPath: "/tmp/.build/debug"), resolvedURL: installed))
    }

    @MainActor
    @Test
    func testCollectionRecognizesAnAliasOfTheSameApp() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TidyBar-own-entry-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = directory.appendingPathComponent("AI SubGauge.app", isDirectory: true)
        let alias = directory.appendingPathComponent("Alias.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: app)
        #expect(MenuEngine.collectionPreservesOwnEntry(bundleURL: alias, resolvedURL: app))
        #expect(MenuEngine.collectionPreservesOwnEntry(bundleURL: app, resolvedURL: alias))
    }

    private func entry(_ identity: String = "CPU", bundle: String = "com.test.stats") -> MenuEntry {
        MenuEntry(id: bundle + "::" + identity, bundleID: bundle, name: "测试图标", title: "测试",
                  frame: CGRect(x: 100, y: 0, width: 24, height: 24), icon: nil, isRunning: true, canMove: true)
    }

    @MainActor
    @Test
    func testPositionResolverRequiresExactUniqueExistingIdentity() {
        let key = "app:com.test.stats:CPU"
        #expect(MenuEngine.positionKey(for: entry(), positions: [key: 3]) == key)
        #expect(MenuEngine.positionKey(for: entry(), positions: ["app:com.test.stats:CPU-Mini": 3]) == nil)
        #expect(MenuEngine.positionKey(for: entry(), positions: ["app:com.other.stats:CPU": 3]) == nil)
        #expect(MenuEngine.positionKey(for: entry(), positions: ["com.test.stats": 3]) == nil)
        #expect(MenuEngine.positionKey(for: entry(), positions: [key: 3, "com.test.stats::CPU": 4]) == nil)
        #expect(MenuEngine.positionKey(for: entry("CPU::1"), positions: [key: 3]) == nil)
        #expect(MenuEngine.positionKey(for: entry("状态图标"), positions: ["com.test.stats::状态图标": 3]) == nil)
    }

    @MainActor
    @Test
    func testPositionResolverRejectsNonnumericAndInvalidPositions() {
        let key = "app:com.test.stats:CPU"
        for number in [NSNumber(value: true), NSNumber(value: -1), NSNumber(value: Double.nan), NSNumber(value: Double.infinity)] {
            #expect(MenuEngine.positionKey(for: entry(), positions: [key: number]) == nil)
        }
        #expect(MenuEngine.positionKey(for: entry(), positions: [key: 0]) == key)
        #expect(MenuEngine.positionKey(for: entry(), positions: [key: 575.5]) == key)
    }

    @MainActor
    @Test
    func testSystemModuleMappingDoesNotGuessUnknownModule() {
        let clock = entry("com.apple.menuextra.clock", bundle: "com.apple.MenuBarAgent")
        #expect(MenuEngine.positionKey(for: clock, positions: ["module:Clock": 1]) == "module:Clock")
        let unknown = entry("com.apple.menuextra.unknown", bundle: "com.apple.MenuBarAgent")
        #expect(MenuEngine.positionKey(for: unknown, positions: ["module:Clock": 1]) == nil)
        #expect(MenuEngine.positionKey(for: clock, positions: ["module:Clock": 1, clock.id: 2]) == nil)
    }
    @Test
    func testMenuTrackingKeepsOpenExtrasAndReleasesClosedMenuTrees() {
        #expect(MenuScanner.menuIsTracking(selected: true, expanded: false, frame: nil, visibleChildren: 0, selectedChildren: 0))
        #expect(MenuScanner.menuIsTracking(selected: false, expanded: false, frame: CGRect(x: -300, y: -100, width: 100, height: 50), visibleChildren: 2, selectedChildren: 0))
        #expect(!(MenuScanner.menuIsTracking(selected: false, expanded: false, frame: CGRect(x: 0, y: 982, width: 0, height: 0), visibleChildren: 10, selectedChildren: 0)))
        #expect(!(MenuScanner.menuIsTracking(selected: false, expanded: false, frame: nil, visibleChildren: 0, selectedChildren: 0)))
        #expect(!(MenuScanner.menuIsTracking(selected: false, expanded: false, frame: CGRect(x: 100, y: 34, width: 100, height: 50), visibleChildren: 0, selectedChildren: 0)))
    }

    @MainActor
    @Test
    func testObservedStatusOwnerNamespaceRequiresSingleItemAndSingleExistingKey() {
        let fixture = entry("状态图标", bundle: "com.mike.aisubgauge.fixture")
        let key = "status:com.mike.aisubgauge.fixture::TidyBarTestFixture"
        #expect(MenuEngine.positionKey(for: fixture, positions: [key: 575.5], ownerItemCount: 1) == key)
        #expect(MenuEngine.positionKey(for: fixture, positions: [key: 575.5], ownerItemCount: 2) == nil)
        #expect(MenuEngine.positionKey(for: fixture, positions: [key: 575.5]) == nil)
        #expect(MenuEngine.positionKey(for: fixture, positions: [key: 575.5, "status:com.mike.aisubgauge.fixture::Second": 300], ownerItemCount: 1) == nil)
        #expect(MenuEngine.positionKey(for: fixture, positions: ["status:com.mike.aisubgauge.fixture.other::Item-0": 575.5], ownerItemCount: 1) == nil)
        let main = entry("com.mike.aisubgauge.main", bundle: "com.mike.aisubgauge")
        #expect(MenuEngine.positionKey(for: main, positions: ["status:com.mike.aisubgauge::com.mike.aisubgauge.main": 217]) == "status:com.mike.aisubgauge::com.mike.aisubgauge.main")
    }

    @MainActor
    @Test
    func testPositionPermutationPreservesRealPointSlotsAndGaps() throws {
        let original: [String: NSNumber] = ["a": 575.5, "b": 294.5, "c": 217, "d": 217, "clock": 0]
        let changed = try MenuEngine.assigningExistingSlots(["b", "a", "c", "d", "clock"], positions: original)
        #expect(changed["b"] == 575.5)
        #expect(changed["a"] == 294.5)
        #expect(changed["c"] == 217)
        #expect(changed["d"] == 217)
        #expect(changed["clock"] == 0)
        #expect(throws: (any Error).self) { try MenuEngine.assigningExistingSlots(["b", "a"], positions: original) }
        for (identity, key) in [("focusmode", "module:FocusModes"), ("controlcenter", "module:BentoBox-0"), ("airdrop", "module:AirDrop")] {
            #expect(MenuEngine.positionKey(for: entry("com.apple.menuextra." + identity, bundle: "com.apple.MenuBarAgent"), positions: [key: 294.5]) == key)
        }
    }

    @MainActor
    @Test
    func testBackupMergePreservesNewKeysAndDoesNotRecreateDeletedKeys() {
        let backup: [String: NSNumber] = ["shared": 575.5, "deleted": 294.5, "unchanged": 0]
        let current: [String: NSNumber] = ["shared": 294.5, "new-weather": 463.5, "unchanged": 0]
        let merged = MenuEngine.mergePositions(backup: backup, current: current)
        #expect(merged["shared"] == 575.5)
        #expect(merged["new-weather"] == 463.5)
        #expect(merged["unchanged"] == 0)
        #expect(merged["deleted"] == nil)
        #expect(Set(merged.keys) == Set(current.keys))
        #expect(MenuEngine.mergePositions(backup: [:], current: current) == current)
    }

    @Test
    func testPresentationIntentRejectsOldCollapseAfterShowAndCoalescesIdleRequests() {
        var intent = MenuPresentationIntent()
        intent.expand()
        intent.collapse()
        let oldProbe = intent.generation
        #expect(intent.acceptsCollapse(oldProbe))
        for _ in 0..<20 { intent.collapse() }
        #expect(intent.generation == oldProbe)
        intent.expand()
        #expect(!(intent.acceptsCollapse(oldProbe)))
        #expect(intent.expanded)
        intent.collapse()
        let secondProbe = intent.generation
        intent.cancelCollapse(actualExpanded: false)
        #expect(!(intent.acceptsCollapse(secondProbe)))
        #expect(!(intent.collapseRequested))
    }

    @Test
    func testFastTogglePreservesUserIntentWhileCollapseProbeIsOutstanding() {
        var intent = MenuPresentationIntent()
        #expect(intent.toggle() == true)
        #expect(intent.toggle() == false)
        let collapseInFlight = intent.generation
        #expect(intent.toggle() == true)
        #expect(!(intent.acceptsCollapse(collapseInFlight)))
        #expect(intent.toggle() == false)
        #expect(intent.acceptsCollapse(intent.generation))
        intent.completeCollapse()
        #expect(!(intent.collapseRequested))
    }

    @MainActor
    @Test
    func testArrowParticipantsUseRealPointOrderAndSkipUnmappedOrCachedGhosts() {
        var left = entry("CPU", bundle: "com.test.left")
        left.frame = CGRect(x: 700, y: 4, width: 24, height: 24)
        var hidden = entry("状态图标", bundle: "com.test.hidden")
        hidden.frame = .zero
        var ghost = entry("CPU", bundle: "com.test.ghost")
        ghost.frame = .zero
        var unknown = entry("状态图标", bundle: "com.test.unknown")
        unknown.canMove = false
        unknown.frame = .zero
        let positions: [String: NSNumber] = ["status:com.test.left::CPU": 575.5,
                                            "status:com.test.hidden::Item-0": 294.5,
                                            "status:com.test.ghost::CPU": 700]
        let sorted = MenuEngine.orderedMovableEntries([unknown, hidden, ghost, left], positions: positions,
                                                     freshIDs: [unknown.id, hidden.id, left.id])
        #expect(sorted.map(\.id) == [left.id, hidden.id])
    }

    @MainActor
    @Test
    func testWritePreflightRejectsLockedOverflowGhostAndCrossDisplayParticipants() {
        var a = entry("A", bundle: "com.test.a")
        var b = entry("B", bundle: "com.test.b")
        a.frame = CGRect(x: 100, y: 4, width: 24, height: 24)
        b.frame = CGRect(x: 200, y: 4, width: 24, height: 24)
        let ids = [a.id, b.id]
        let primary = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let secondary = CGRect(x: 1000, y: 0, width: 1000, height: 800)
        #expect(MenuEngine.layoutParticipantsVisible(ids, entries: [a, b], freshIDs: Set(ids), screens: [primary, secondary]))
        #expect(!(MenuEngine.layoutParticipantsVisible(ids, entries: [a, b], freshIDs: [a.id], screens: [primary])))
        b.frame = .zero
        #expect(!(MenuEngine.layoutParticipantsVisible(ids, entries: [a, b], freshIDs: Set(ids), screens: [primary])))
        a.frame = .zero
        #expect(!(MenuEngine.layoutParticipantsVisible(ids, entries: [a, b], freshIDs: Set(ids), screens: [primary])))
        a.frame = CGRect(x: 100, y: 4, width: 24, height: 24)
        b.frame = CGRect(x: 1200, y: 4, width: 24, height: 24)
        #expect(!(MenuEngine.layoutParticipantsVisible(ids, entries: [a, b], freshIDs: Set(ids), screens: [primary, secondary])))
    }

    @MainActor
    @Test
    func testSavedOrderReportsFailureWhenEngineIsStopped() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TidyBar-order-callback-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = MenuEngine(store: SettingsStore(url: directory.appendingPathComponent("settings.json")))
        var results = 0
        engine.applySavedOrder { result in
            results += 1
            if case .success = result { Issue.record("未运行的引擎不得报告排序成功") }
        }
        #expect(results == 1)
    }

    @MainActor
    @Test
    func testActiveOwnerUsesActualNestedAppPathInsteadOfNamespaceGuessing() {
        let front = URL(fileURLWithPath: "/Applications/Lark.app", isDirectory: true)
        let nested = front.appendingPathComponent("Contents/Frameworks/Lark Helper.app", isDirectory: true)
        #expect(MenuEngine.ownerBelongsToFrontmost(ownerBundleID: "com.larksuite.larkApp.helper", ownerURL: nested,
                                                       frontBundleID: "com.larksuite.larkApp", frontURL: front))
        for path in ["/Applications/Lark.app-copy/Contents/Lark Helper.app", "/Applications/Lark Helper.app", "/Applications/Lark.app/../Other.app"] {
            #expect(!(MenuEngine.ownerBelongsToFrontmost(ownerBundleID: "com.larksuite.larkApp.helper", ownerURL: URL(fileURLWithPath: path),
                                                            frontBundleID: "com.larksuite.larkApp", frontURL: front)))
        }
        #expect(!(MenuEngine.ownerBelongsToFrontmost(ownerBundleID: "helper", ownerURL: nil, frontBundleID: "root", frontURL: front)))
        #expect(!(MenuEngine.ownerBelongsToFrontmost(ownerBundleID: "helper", ownerURL: nested, frontBundleID: "root", frontURL: nil)))
        #expect(MenuEngine.ownerBelongsToFrontmost(ownerBundleID: "same", ownerURL: nil, frontBundleID: "same", frontURL: nil))
    }

    @MainActor
    @Test
    func testAdjacentArrowDoesNotRequireUnrelatedOverflowAndOnlyChangesItsTwoSlots() throws {
        var overflow = entry("Overflow", bundle: "com.test.overflow")
        overflow.frame = .zero
        var source = entry("Source", bundle: "com.test.source")
        source.frame = CGRect(x: 200, y: 4, width: 24, height: 24)
        var target = entry("Target", bundle: "com.test.target")
        target.frame = CGRect(x: 300, y: 4, width: 24, height: 24)
        let unrelated = entry("Other", bundle: "com.test.other")
        let entries = [overflow, source, target, unrelated]
        let plan = try #require(MenuEngine.arrowMovePlan(in: entries, sourceID: source.id, offset: 1))
        #expect(plan.participants.map(\.id) == [source.id, target.id])
        #expect(plan.order == [target.id, source.id])
        #expect(MenuEngine.layoutParticipantsVisible(plan.order, entries: entries, freshIDs: Set(entries.map(\.id)),
                                                          screens: [CGRect(x: 0, y: 0, width: 1000, height: 800)]))
        let positions: [String: NSNumber] = ["overflow": 700, "source": 575.5, "target": 294.5, "other": 0]
        let result = try MenuEngine.reorderParticipants(["target", "source"], positions: positions)
        #expect(result["source"] == 294.5)
        #expect(result["target"] == 575.5)
        #expect(result["overflow"] == positions["overflow"])
        #expect(result["other"] == positions["other"])
        #expect(MenuEngine.arrowMovePlan(in: entries, sourceID: overflow.id, offset: -1) == nil)
    }

    @Test
    func testCommandDragStaysInActualSameScreenMenuBarAndRejectsUnsafeGeometry() throws {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let source = CGRect(x: 200, y: 4, width: 24, height: 24)
        let target = CGRect(x: 300, y: 4, width: 30, height: 24)
        let before = try #require(MenuScanner.commandDragPoints(source: source, target: target, before: true, screens: [screen]))
        let after = try #require(MenuScanner.commandDragPoints(source: source, target: target, before: false, screens: [screen]))
        #expect(before.0 == CGPoint(x: 212, y: 16))
        #expect(before.1 == CGPoint(x: 302, y: 16))
        #expect(after.1 == CGPoint(x: 328, y: 16))
        for invalid in [CGRect.zero, source, CGRect(x: 300, y: 300, width: 24, height: 24), CGRect(x: 990, y: 4, width: 24, height: 24), CGRect(x: 1300, y: 4, width: 24, height: 24)] {
            #expect(MenuScanner.commandDragPoints(source: source, target: invalid, before: true, screens: [screen, CGRect(x: 1000, y: 0, width: 1000, height: 800)]) == nil)
        }
        let secondScreen = CGRect(x: -1000, y: -800, width: 1000, height: 800)
        #expect(MenuScanner.commandDragPoints(source: CGRect(x: -800, y: -796, width: 24, height: 24), target: CGRect(x: -700, y: -796, width: 24, height: 24), before: true, screens: [secondScreen]) != nil)
    }

    @MainActor
    @Test
    func testNativeSingleMoveKeepsTheSelectedFixtureAsDragSourceInBothDirections() throws {
        let fixture = "fixture", inputMethod = "input-method", helper = "helper"
        let right = try #require(MenuEngine.nativeSourceMove(in: [inputMethod, fixture], sourceID: fixture))
        #expect(right.source == fixture)
        #expect(right.target == inputMethod)
        #expect(!(right.before))
        let left = try #require(MenuEngine.nativeSourceMove(in: [fixture, inputMethod], sourceID: fixture))
        #expect(left.source == fixture)
        #expect(left.target == inputMethod)
        #expect(left.before)
        let across = try #require(MenuEngine.nativeSourceMove(in: [inputMethod, helper, fixture], sourceID: fixture))
        #expect(across.target == helper)
        #expect(!(across.before))
        #expect(MenuEngine.nativeSourceMove(in: [inputMethod, helper], sourceID: fixture) == nil)
        #expect(MenuEngine.nativeSourceMove(in: [fixture, fixture], sourceID: fixture) == nil)
    }

    @Test
    func testHostedWindowSelectionRequiresOneActualLayoutAndDoesNotMergeMirrors() {
        let a = CGRect(x: 100, y: 0, width: 30, height: 33)
        let b = CGRect(x: 300, y: 0, width: 30, height: 33)
        let x = MenuScanner.HostedSlotGeometry(pid: 11, frame: a)
        let y = MenuScanner.HostedSlotGeometry(pid: 22, frame: b)
        #expect(MenuScanner.selectHostedWindow(layouts: [0: [x], 1: [y]], ownSlots: [0: [a], 1: [b]], ownFrames: [b]) == 1)
        #expect(MenuScanner.selectHostedWindow(layouts: [0: [x], 1: [y]], ownSlots: [0: [b], 1: [b]], ownFrames: [b]) == nil)
        #expect(MenuScanner.selectHostedWindow(layouts: [0: [x], 1: [y]], ownSlots: [:], ownFrames: []) == nil)
        #expect(MenuScanner.selectHostedWindow(layouts: [0: [x], 1: [x]], ownSlots: [0: [b], 1: [b]], ownFrames: [b]) == 0)
        #expect(MenuScanner.selectHostedWindow(layouts: [4: [x]], ownSlots: [:], ownFrames: []) == 4)
        #expect(MenuScanner.selectHostedWindow(layouts: [0: [x, y], 1: [y, x]], ownSlots: [0: [b], 1: [b]], ownFrames: [b]) == 0)
        let swappedOwners = [MenuScanner.HostedSlotGeometry(pid: y.pid, frame: a), MenuScanner.HostedSlotGeometry(pid: x.pid, frame: b)]
        #expect(MenuScanner.selectHostedWindow(layouts: [0: [x, y], 1: swappedOwners], ownSlots: [0: [b], 1: [b]], ownFrames: [b]) == nil)
    }

    @MainActor
    @Test
    func testStackedOverflowIsNotAnActionableSlotEvenWithNonzeroScreenCoordinates() {
        let fixture = CGRect(x: 848.5, y: 0, width: 72, height: 33)
        let inputMethod = CGRect(x: 884.5, y: 0, width: 36, height: 33)
        #expect(!(MenuScanner.hostedSlotIsDistinct(fixture, others: [inputMethod])))
        #expect(!(MenuScanner.hostedSlotIsDistinct(inputMethod, others: [fixture])))
        let expandedFixture = CGRect(x: 571.5, y: 0, width: 72, height: 33)
        let expandedInputMethod = CGRect(x: 535.5, y: 0, width: 36, height: 33)
        #expect(MenuScanner.hostedSlotIsDistinct(expandedFixture, others: [expandedInputMethod]))
        var a = entry("fixture"), b = entry("input-method")
        a.frame = fixture; b.frame = inputMethod
        #expect(!(MenuEngine.layoutParticipantsVisible([a.id, b.id], entries: [a, b], freshIDs: [a.id, b.id], screens: [CGRect(x: 0, y: 0, width: 1500, height: 1000)])))
    }

    @MainActor
    @Test
    func testOptionalInactiveSystemModuleDoesNotBlockAvailableItemsOrDiscardStoredOrder() {
        let clock = entry("com.apple.menuextra.clock", bundle: "com.apple.MenuBarAgent")
        let inactive = "com.apple.MenuBarAgent::com.apple.menuextra.airdrop"
        let ordinary = "com.test.running::missing-status-item"
        let order = [inactive, ordinary, clock.id]
        let result = MenuEngine.savedOrderAvailability(order, entries: [clock], running: ["com.apple.MenuBarAgent", "com.test.running"], freshIDs: [clock.id])
        #expect(result.inactiveSystem == [inactive])
        #expect(result.pending == [ordinary])
        #expect(order == [inactive, ordinary, clock.id])
        let notDiscovered = MenuEngine.savedOrderAvailability(order, entries: [], running: ["com.apple.MenuBarAgent", "com.test.running"], freshIDs: [])
        #expect(notDiscovered.pending == order)
        let appeared = entry("com.apple.menuextra.airdrop", bundle: "com.apple.MenuBarAgent")
        #expect(MenuEngine.savedOrderAvailability([inactive, clock.id], entries: [clock, appeared], running: ["com.apple.MenuBarAgent"], freshIDs: [clock.id, appeared.id]).inactiveSystem.isEmpty)
    }

    @MainActor
    @Test
    func testOverflowReadinessMessageDoesNotAssertTheDesktopIsLocked() {
        let overflow = MenuEngine.unavailableLayoutMessage(["a"], systemOverflowIDs: ["a"])
        #expect(overflow.contains("位于系统隐藏区"))
        #expect(!(overflow.contains("解锁")))
        let unknown = MenuEngine.unavailableLayoutMessage(["a", "b"], systemOverflowIDs: ["a"])
        #expect(!(unknown.contains("这些图标位于系统隐藏区")))
        #expect(!(unknown.contains("解锁")))
    }

    @MainActor
    @Test
    func testConfirmedOrderAcknowledgementSkipsOnlyItsOwnSingleObserverEcho() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(url: directory.appendingPathComponent("settings.json"))
        let engine = MenuEngine(store: store)
        let moved = ["com.test::moved", "com.test::target"]
        engine.persistConfirmedOrder(moved)
        #expect(store.config.order == moved)
        #expect(engine.consumePersistedOrder(moved))
        #expect(!(engine.consumePersistedOrder(moved)))
        let anotherMove = moved.reversed().map { $0 }
        engine.persistConfirmedOrder(anotherMove)
        #expect(!(engine.consumePersistedOrder(["com.test::imported"])))
        #expect(!(engine.consumePersistedOrder(anotherMove)))
    }

    @Test
    func testAllOwnStatusAnchorsMustMatchTheSameHostedWindow() {
        let main = CGRect(x: 1213, y: 0, width: 38, height: 33)
        let collapsedAI = CGRect(x: 970, y: 0, width: 125, height: 33)
        let expandedAI = CGRect(x: 400, y: 0, width: 125, height: 33)
        let layouts = [0: [MenuScanner.HostedSlotGeometry(pid: 10, frame: main), MenuScanner.HostedSlotGeometry(pid: 10, frame: collapsedAI)],
                       1: [MenuScanner.HostedSlotGeometry(pid: 10, frame: main), MenuScanner.HostedSlotGeometry(pid: 10, frame: expandedAI)]]
        let slots = [0: [main, collapsedAI], 1: [main, expandedAI]]
        #expect(MenuScanner.selectHostedWindow(layouts: layouts, ownSlots: slots, ownFrames: [main]) == nil)
        #expect(MenuScanner.selectHostedWindow(layouts: layouts, ownSlots: slots, ownFrames: [main, expandedAI]) == 1)
        #expect(MenuScanner.selectHostedWindow(layouts: layouts, ownSlots: slots, ownFrames: [main, collapsedAI]) == 0)
        #expect(MenuScanner.selectHostedWindow(layouts: layouts, ownSlots: slots, ownFrames: [main, CGRect(x: 800, y: 0, width: 125, height: 33)]) == nil)
        #expect(MenuScanner.selectHostedWindow(layouts: [0: layouts[0]!], ownSlots: [0: slots[0]!], ownFrames: [main, expandedAI]) == nil)
    }

    @Test
    func testOverflowClickFallbackRequiresExplicitUnsupportedAndExactFreshNativeShowHit() {
        let frame = CGRect(x: 874.5, y: 1, width: 17.5, height: 30)
        func decision(_ press: AXError = .actionUnsupported, hit: AXError = .success, pid: pid_t = 10,
                      role: String = "AXButton", label: String = "显示隐藏菜单栏项目", hitFrame: CGRect? = CGRect(x: 874.5, y: 1, width: 17.5, height: 30)) -> MenuScanner.OverflowFallbackDecision {
            MenuScanner.overflowFallbackDecision(pressResult: press, hitResult: hit, hitPID: pid, agentPID: 10,
                role: role, label: label, frame: hitFrame, expectedFrame: frame)
        }
        #expect(decision() == .click)
        #expect(decision(.notImplemented, label: "Show Hidden Menu Bar Items") == .click)
        #expect(decision(.success) == .waitForLayout)
        #expect(decision(.cannotComplete) == .waitForLayout)
        #expect(decision(label: "隐藏菜单栏项目") == .waitForLayout)
        #expect(decision(label: "Hide Hidden Menu Bar Items") == .waitForLayout)
        #expect(decision(.apiDisabled) == .refuse)
        #expect(decision(hit: .cannotComplete) == .refuse)
        #expect(decision(pid: 20) == .refuse)
        #expect(decision(role: "AXMenuBar") == .refuse)
        #expect(decision(label: "Other button") == .refuse)
        #expect(decision(hitFrame: nil) == .refuse)
        #expect(decision(hitFrame: .zero) == .refuse)
        #expect(decision(hitFrame: frame.offsetBy(dx: 1, dy: 0)) == .refuse)
    }

}
}
