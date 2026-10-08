import UIKit
import XCTest

/// The chart (#115): each new venue's race area, land, landmarks, shallows, marks and line, north up over the whole
/// course and race area, frozen in the sequence and diffed against its reference (each also through tritanopia, in
/// `RenderFixtureFilterUITests`). In a file of its own beside `RenderFixtureUITests`; XCTest runs it as that class's
/// test (`@objc`, so discovery finds it in an extension).
extension RenderFixtureUITests {
    /// Hollin Bay: one bay of land with its clubhouse, lighthouse and tree clump. Saltings Reach: the only venue with
    /// a current, so the only one with shallows; the current itself never drawn. Fellmere: four pieces of land sharing
    /// diagonals, one fill with no seam, relief from their shape alone. One launch (`assertAllMatchReferences`).
    @objc @MainActor func testChartsMatchReferences() throws {
        try assertAllMatchReferences(["chart-hollin-bay", "chart-saltings-reach", "chart-fellmere"])
    }
}
