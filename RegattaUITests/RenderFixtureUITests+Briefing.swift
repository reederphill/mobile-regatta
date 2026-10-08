import UIKit
import XCTest

/// The briefing (#130): a venue with current, with its current line, and a venue without current, both
/// practice briefings frozen at their start (`BriefingGalleryView`), and a practice briefing with rivals (#235). In a file of its own beside
/// `RenderFixtureUITests`, as the camera's are. CI records the references; the owner approves them before adoption.
extension RenderFixtureUITests {
    @objc @MainActor func testBriefingMatchesReferences() throws {
        try assertAllMatchReferences(["briefing-current", "briefing-steady", "briefing-rival"])
    }
}
