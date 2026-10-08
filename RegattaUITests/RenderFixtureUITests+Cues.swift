import UIKit
import XCTest

/// The boat-side cues (#122): the bot race on the default files in course-up, ladder lines on, your autohelm
/// pinching up the first beat: the yellow laylines, the faint ladder lines, your vermillion vane with its groove tick
/// and pinch arc, the sail's lifted luff, and the orange edge arrow to the windward mark off screen; plus a frame
/// footing later up the beat. Through every vision filter (#22) in `RenderFixtureFilterUITests`. In a file of its own
/// beside `RenderFixtureUITests`, as the camera's are.
extension RenderFixtureUITests {
    @objc @MainActor func testBoatCuesMatchReferences() throws {
        try assertAllMatchReferences(["cues", "cues-footed"])
    }
}
