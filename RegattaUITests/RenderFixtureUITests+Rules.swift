import UIKit
import XCTest

/// The rule cues (#123) on the fleet bot race in course-up: `rules-call` a few seconds after two calls, with their
/// orange dashed lines and rule-number badges, your penalty arc counting the complete deadline and red glows round the
/// boats you keep clear of while turning (21.2); `rules-penalty` before your turn is started, the arc counting the
/// start deadline, red and green glows, and the HUD's "Turn" notice; `rules-ring` (#517) another boat taking a
/// penalty, her plain orange ring in place of a green glow. The first two through every vision filter (#22) in
/// `RenderFixtureFilterUITests`; fleet-rules@6's arc with its tack and gybe marks (#489) unfiltered. In a file of its
/// own beside `RenderFixtureUITests`, as the cues' are.
extension RenderFixtureUITests {
    @objc @MainActor func testRuleCuesMatchReferences() throws {
        try assertAllMatchReferences(["rules-call", "rules-penalty", "rules-ring"])
    }

    /// The fleet-rules@6 penalty arc (#489) on its own scenes: `rules-turn` just called (one 40 s countdown, the tack
    /// and gybe marks both grey), `rules-turn-tack` the tack made (the screen-up half lit, its barb showing the turn's
    /// way), `rules-turn-gybe` the gybe made first (the screen-down half). Each with the HUD's one-countdown Turn notice.
    @objc @MainActor func testTackAndGybePenaltyArcMatchesReferences() throws {
        try assertAllMatchReferences(["rules-turn", "rules-turn-tack", "rules-turn-gybe"])
    }
}
