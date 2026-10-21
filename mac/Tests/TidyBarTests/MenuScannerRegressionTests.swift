import AppKit
import Testing
@testable import TidyBar

extension TidyBarTests {
@Suite
final class MenuScannerRegressionTests {
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
