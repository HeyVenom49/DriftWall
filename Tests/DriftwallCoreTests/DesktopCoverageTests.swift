import CoreGraphics
import Testing
@testable import DriftwallCore

@Suite("Desktop coverage")
struct DesktopCoverageTests {
    /// A 1512 × 982 screen with a 33-point menu bar and a 70-point Dock (top-left origin).
    let usable = CGRect(x: 0, y: 33, width: 1512, height: 879)

    @Test func zoomedWindowCoversTheDesktop() {
        #expect(DesktopCoverage.isCovered(usable, by: [usable]))
    }

    @Test func noWindowsMeansVisible() {
        #expect(!DesktopCoverage.isCovered(usable, by: []))
    }

    @Test func partlyCoveredDesktopIsVisible() {
        let left = CGRect(x: 0, y: 33, width: 900, height: 879)
        #expect(!DesktopCoverage.isCovered(usable, by: [left]))
    }

    @Test func sideBySideWindowsCoverTogether() {
        let left = CGRect(x: 0, y: 33, width: 756, height: 879)
        let right = CGRect(x: 756, y: 33, width: 756, height: 879)
        #expect(DesktopCoverage.isCovered(usable, by: [left, right]))
    }

    @Test func aVisibleGapKeepsPlaying() {
        let left = CGRect(x: 0, y: 33, width: 600, height: 879)
        let right = CGRect(x: 900, y: 33, width: 612, height: 879)
        #expect(!DesktopCoverage.isCovered(usable, by: [left, right]))
    }

    @Test func windowsOnAnotherDisplayDontCount() {
        let elsewhere = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        #expect(!DesktopCoverage.isCovered(usable, by: [elsewhere]))
    }

    @Test func windowsSlightlyShortOfTheEdgesStillCover() {
        // Zoomed windows can stop a point or two short of the usable area's edges.
        #expect(DesktopCoverage.isCovered(usable, by: [usable.insetBy(dx: 2, dy: 2)]))
    }

    @Test func emptyAreaIsNeverCovered() {
        #expect(!DesktopCoverage.isCovered(.zero, by: [usable]))
    }
}
