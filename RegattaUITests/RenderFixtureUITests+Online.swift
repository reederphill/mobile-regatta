import UIKit
import XCTest

/// The online race sequence (#141): the race menu, "Race continues", over the `fleet` race at `hud-racing`'s moment,
/// the water reading through it; Home with Rejoin race and its race clock in Race online's place; and Home with a
/// Last race row whose rating is in (`MenuGalleryView`). The briefing-to-race cross-fade is not a render. In a file
/// of its own beside `RenderFixtureUITests`, as the queue's are. CI records the references; the owner approved the
/// look from local screenshots first.
extension RenderFixtureUITests {
    @objc @MainActor func testOnlineSequenceMatchesReferences() throws {
        try assertAllMatchReferences(["online-menu", "home-rejoin", "home-last-race-rating"])
    }
}
