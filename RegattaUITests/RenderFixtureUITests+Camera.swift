import UIKit
import XCTest

/// The race camera (#113): course-up and boat-up, auto zoom on, each frozen settled and diffed against its
/// reference. In a file of its own beside `RenderFixtureUITests`; XCTest runs them as that class's tests (`@objc`, so
/// discovery finds them in an extension).
extension RenderFixtureUITests {
    /// The prestart fleet in course-up: the course axis (9° off north in this log) at the top, the start line
    /// framed; and the light and patchy fleet at the water fixture's tick in boat-up: your heading (64°) at the top.
    /// One launch (`assertAllMatchReferences`).
    @objc @MainActor func testCamerasMatchReferences() throws {
        try assertAllMatchReferences(["course-up", "boat-up"])
    }
}
