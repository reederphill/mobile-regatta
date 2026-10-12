import UIKit
import XCTest

/// The queue (#140): its bar above a pushed page (the practice setup, `MenuGalleryView`) waiting with others, alone,
/// in a hold and as the lock banner; its chip over a race with the HUD moved down under it; and the locked fleet's
/// briefing with its Leave bar, the takeover's frame (`BriefingGalleryView`). Every one is frozen at a fixed moment.
/// In a file of its own beside `RenderFixtureUITests`, as the briefing's are. CI records the references; the owner
/// approved the look from local screenshots first.
extension RenderFixtureUITests {
    @objc @MainActor func testQueueBarMatchesReferences() throws {
        try assertAllMatchReferences(["queue-bar-waiting", "queue-bar-alone", "queue-bar-hold", "queue-bar-lock-soon",
                                      "queue-chip", "briefing-online-leave"])
    }
}
