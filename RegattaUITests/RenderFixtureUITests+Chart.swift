import UIKit
import XCTest

/// The chart (#115): each new venue's race area, land, landmarks, shallows, marks and line, north up over the whole
/// course and race area, plain and through tritanopia, frozen in the sequence and diffed against its reference. In a
/// file of its own beside `RenderFixtureUITests`; XCTest runs them as that class's tests (`@objc`, so discovery finds
/// them in an extension).
extension RenderFixtureUITests {
    /// Hollin Bay: one bay of land with its clubhouse, lighthouse and tree clump.
    @objc @MainActor func testChartHollinBayMatchesItsReferences() throws {
        try assertChartMatchesReferences("chart-hollin-bay")
    }

    /// Saltings Reach: the only venue with a current, so the only one with shallows; the current itself never drawn.
    @objc @MainActor func testChartSaltingsReachMatchesItsReferences() throws {
        try assertChartMatchesReferences("chart-saltings-reach")
    }

    /// Fellmere: four pieces of land sharing diagonals, one fill with no seam, relief from their shape alone.
    @objc @MainActor func testChartFellmereMatchesItsReferences() throws {
        try assertChartMatchesReferences("chart-fellmere")
    }

    /// The fixture and its tritanopia twin, each rendered and compared before any failure ends the test, so both
    /// reach render-actuals in one CI run. References are recorded on iPhone 17 only.
    @MainActor private func assertChartMatchesReferences(_ name: String, file: StaticString = #filePath,
                                                         line: UInt = #line) throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad,
                      "render references are recorded on iPhone 17 only; the iPad run doesn't compare them")
        continueAfterFailure = true
        defer { continueAfterFailure = false }
        for fixture in [name, "\(name)-tritanopia"] {
            try assertMatchesReference(fixture, file: file, line: line)
        }
    }
}
