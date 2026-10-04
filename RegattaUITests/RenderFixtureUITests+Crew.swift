import UIKit
import XCTest

/// The skiff's sailors (#120) through your first tack in the fleet race, boat-up, each frozen settled and diffed
/// against its reference: `crew-tack-1` out on the wire to starboard about 1.5 s before, `crew-tack-2` sitting in
/// head to wind, `crew-tack-3` crossing just after the boom, `crew-tack-4` out on the new side close-hauled. The
/// app's `CrewPoseTests.crewTackFixturesShowTheTack` pins what each tick draws. In a file of its own beside
/// `RenderFixtureUITests`, as the cues' are.
extension RenderFixtureUITests {
    @objc @MainActor func testCrewTackMatchesReferences() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad,
                      "render references are recorded on iPhone 17 only; the iPad run doesn't compare them")
        // Every render compares before a failure ends the test, so each one that moved (or has no reference yet)
        // reaches render-actuals in one CI run.
        continueAfterFailure = true
        defer { continueAfterFailure = false }
        for n in 1...4 {
            try assertMatchesReference("crew-tack-\(n)")
        }
    }
}
