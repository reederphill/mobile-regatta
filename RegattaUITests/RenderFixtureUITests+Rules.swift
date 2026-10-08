import UIKit
import XCTest

/// The rule cues (#123) on the fleet bot race in course-up, through every vision filter (#22): `rules-call` a few
/// seconds after two calls, with their orange dashed lines and rule-number badges, your penalty arc counting the
/// complete deadline and red glows round the boats you keep clear of while turning (21.2); `rules-penalty` before your
/// turn is started, the arc counting the start deadline, red and green glows, and the HUD's "Turn" notice. In a file
/// of its own beside `RenderFixtureUITests`, as the cues' are.
///
/// Three fixtures to a test: each is a launch of about 20 s on CI's render job, and the twelve in one test ran
/// 210-265 s against the 300 s allowance (#408).
extension RenderFixtureUITests {
    @objc @MainActor func testRuleCallCuesMatchReferences() throws {
        try assertRuleCuesMatchReferences(["rules-call", "rules-call-deuteranopia", "rules-call-protanopia"])
    }

    @objc @MainActor func testRuleCallCuesUnderFiltersMatchReferences() throws {
        try assertRuleCuesMatchReferences(["rules-call-tritanopia", "rules-call-greyscale", "rules-call-washout"])
    }

    @objc @MainActor func testPenaltyCuesMatchReferences() throws {
        try assertRuleCuesMatchReferences(["rules-penalty", "rules-penalty-deuteranopia", "rules-penalty-protanopia"])
    }

    @objc @MainActor func testPenaltyCuesUnderFiltersMatchReferences() throws {
        try assertRuleCuesMatchReferences(["rules-penalty-tritanopia", "rules-penalty-greyscale", "rules-penalty-washout"])
    }

    /// Every render compares before a failure ends the test, so each one that moved (or has no reference yet)
    /// reaches render-actuals in one CI run.
    @MainActor private func assertRuleCuesMatchReferences(_ names: [String], file: StaticString = #filePath,
                                                          line: UInt = #line) throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad,
                      "render references are recorded on iPhone 17 only; the iPad run doesn't compare them")
        continueAfterFailure = true
        defer { continueAfterFailure = false }
        for name in names {
            try assertMatchesReference(name, file: file, line: line)
        }
    }
}
