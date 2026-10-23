import UIKit
import XCTest

/// The profile (#139) as an off-water gallery (`MenuGalleryView`): an established player's page, pushed as from home,
/// on a fixed livery. In a file of its own beside `RenderFixtureUITests`, as My boat's is. CI records the reference;
/// the owner approved the look from local screenshots first.
extension RenderFixtureUITests {
    @objc @MainActor func testProfileMatchesReferences() throws {
        try assertAllMatchReferences(["profile"])
    }
}
