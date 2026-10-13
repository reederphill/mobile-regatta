import UIKit
import XCTest

/// The planing cue (#492): a bot race on the default files down the first run, the HUD with its instruments. On the
/// plane with room to spare, your speed tile yellow under dark figures and your two stern-corner wakes at their
/// longest, another planing boat's in the picture; and later on the same run at the edge of the plane, run deeper
/// until your apparent wind is nearly gone, the wakes near their shortest. Through every vision filter (#22) in
/// `RenderFixtureFilterUITests`. In a file of its own beside `RenderFixtureUITests`, as the boat-side cues' are.
extension RenderFixtureUITests {
    @objc @MainActor func testPlaningCueMatchesReferences() throws {
        try assertAllMatchReferences(["planing", "planing-edge"])
    }
}
