import UIKit
import XCTest

/// The lobby (#142, G15) as an off-water gallery (`MenuGalleryView`): Home with the lobby open on every kind of line
/// (`HomeFixture.lobby`). In a file of its own beside `RenderFixtureUITests`, as the profile's is. CI records the
/// reference; the owner approved the look from local screenshots first.
extension RenderFixtureUITests {
    @objc @MainActor func testLobbyMatchesReferences() throws {
        try assertAllMatchReferences(["lobby"])
    }
}
