import UIKit
import XCTest

/// Help (#135) as off-water galleries (`MenuGalleryView`): its topics, and the symbol legend drawn by the race's own
/// renderer. The text topics have no references: their copy changes in #171. CI records the references; the owner
/// approves them before adoption.
extension RenderFixtureUITests {
    @objc @MainActor func testHelpMatchesReferences() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad,
                      "render references are recorded on iPhone 17 only; the iPad run doesn't compare them")
        continueAfterFailure = true
        defer { continueAfterFailure = false }
        for name in ["help", "help-symbols"] {
            try assertMatchesReference(name)
        }
    }
}
