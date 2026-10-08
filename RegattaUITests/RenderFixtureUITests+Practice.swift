import UIKit
import XCTest

/// The practice setup page on a fresh install's choices and the pause menu at the device defaults (#131), as off-water
/// galleries (`MenuGalleryView`). In a file of its own beside `RenderFixtureUITests`, as the briefing's are. CI records
/// the references; the owner approves them before adoption.
extension RenderFixtureUITests {
    @objc @MainActor func testPracticeMenusMatchReferences() throws {
        try assertAllMatchReferences(["practice-setup", "pause-menu"])
    }
}
