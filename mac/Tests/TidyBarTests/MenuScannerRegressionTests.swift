import AppKit
import Testing
@testable import TidyBar

extension TidyBarTests {
@Suite
final class MenuScannerRegressionTests {
    @Test
    func testSelfPIDIsExcludedBeforeReadingContent() {
        #expect(!MenuScanner.shouldScanPID(42, selfPID: 42))
        #expect(MenuScanner.shouldScanPID(43, selfPID: 42))
        #expect(MenuScanner.shouldScanPID(0, selfPID: 42))
        #expect(MenuScanner.shouldScanPID(nil, selfPID: 42))
        #expect(MenuScanner.shouldScanPID(0, selfPID: 0))
    }

    @Test
    func testOverflowSelectionAndDiagnosticsExcludeSelfWithOrWithoutContent() {
        for hasContent in [false, true] {
            #expect(!MenuScanner.isOverflowSlot(pid: 42, hasContent: hasContent, selfPID: 42))
            #expect(MenuScanner.isOverflowSlot(pid: 0, hasContent: hasContent, selfPID: 42))
        }
        #expect(MenuScanner.isOverflowSlot(pid: 43, hasContent: false, selfPID: 42))
        #expect(!MenuScanner.isOverflowSlot(pid: 43, hasContent: true, selfPID: 42))
    }

    @Test
    func testSelfSlotsStillSelectHostUsingOnlyPIDAndAgentSlotFrames() {
        let own = CGRect(x: 800, y: 0, width: 80, height: 33)
        let stale = CGRect(x: 700, y: 0, width: 22, height: 33)
        let layouts: [Int: [MenuScanner.HostedSlotGeometry]] = [
            0: [.init(pid: 42, frame: stale), .init(pid: 43, frame: own)],
            1: [.init(pid: 42, frame: own), .init(pid: 43, frame: stale)]
        ]
        let ownSlots = layouts.mapValues { slots in
            slots.filter { !MenuScanner.shouldScanPID($0.pid, selfPID: 42) }.map(\.frame)
        }
        #expect(MenuScanner.selectHostedWindow(layouts: layouts, ownSlots: ownSlots, ownFrames: [own]) == 1)
        #expect(layouts[1]?.filter { MenuScanner.shouldScanPID($0.pid, selfPID: 42) }.map(\.pid) == [43])
    }

    @Test
    func testRepeatedProcessIDsDoNotTrapAndKeepFirstOwner() {
        let first = NSRunningApplication.current
        // This snapshot trapped in scan's uniqueKeysWithValues initializer.
        let owners = MenuScanner.applicationsByPID([first, first, first])
        #expect(owners.count == 1)
        #expect(owners[first.processIdentifier] === first)
    }

    @Test
    func testSingleApplicationRetainsItsPIDAndOwner() {
        let app = NSRunningApplication.current
        let owners = MenuScanner.applicationsByPID([app])
        #expect(Set(owners.keys) == [app.processIdentifier])
        #expect(owners[app.processIdentifier] === app)
    }

    @Test
    func testEmptyApplicationSnapshotHasNoOwners() {
        #expect(MenuScanner.applicationsByPID([]).isEmpty)
    }
}
}
