import UIKit
import XCTest

/// The skiff's spinnaker (#311), each state on a fixture of its own on the default class, the HUD with its
/// instruments: your kite hoisting mid-way after the windward mark, its pole running out with it; dropping mid-way
/// before the leeward gate; and collapsed by the lee, another boat's kite up for contrast. Through every vision filter
/// (#22) in `RenderFixtureFilterUITests`. In a file of its own beside `RenderFixtureUITests`, as the planing cue's is.
extension RenderFixtureUITests {
    @objc @MainActor func testSpinnakerStatesMatchReferences() throws {
        try assertAllMatchReferences(["spinnaker-hoist", "spinnaker-drop", "spinnaker-lee"])
    }
}
