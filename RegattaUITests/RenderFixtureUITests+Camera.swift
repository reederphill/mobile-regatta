import UIKit
import XCTest

/// The race camera (#113): course-up and boat-up, auto framing on, each frozen settled and diffed against its
/// reference. In a file of its own beside `RenderFixtureUITests`; XCTest runs them as that class's tests (`@objc`, so
/// discovery finds them in an extension).
extension RenderFixtureUITests {
    /// The prestart fleet in course-up: the course axis (9° off north in this log) at the top, the start line
    /// framed.
    @objc @MainActor func testCourseUpMatchesItsReference() throws {
        try skipCameraReferenceOnIPad()
        try assertMatchesReference("course-up")
    }

    /// The light and patchy fleet at the water fixture's tick in boat-up: your heading (64°) at the top.
    @objc @MainActor func testBoatUpMatchesItsReference() throws {
        try skipCameraReferenceOnIPad()
        try assertMatchesReference("boat-up")
    }

    /// References are recorded on iPhone 17 only, as the other reference tests' are.
    @MainActor private func skipCameraReferenceOnIPad() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad,
                      "render references are recorded on iPhone 17 only; the iPad run doesn't compare them")
    }
}
