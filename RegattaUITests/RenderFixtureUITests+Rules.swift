import UIKit
import XCTest

/// The rule cues (#123) on the fleet bot race in course-up: `rules-call` a few seconds after two calls, with their
/// orange dashed lines and rule-number badges, your penalty arc counting the complete deadline and red glows round the
/// boats you keep clear of while turning (21.2); `rules-penalty` before your turn is started, the arc counting the
/// start deadline, red and green glows, and the HUD's "Turn" notice. Through every vision filter (#22) in
/// `RenderFixtureFilterUITests`. In a file of its own beside `RenderFixtureUITests`, as the cues' are.
extension RenderFixtureUITests {
    @objc @MainActor func testRuleCuesMatchReferences() throws {
        try assertAllMatchReferences(["rules-call", "rules-penalty"])
    }
}
