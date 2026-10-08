import UIKit
import XCTest

/// Liveries (#21, #119): each free skiff starter design's large render and chip, in fixed colours, on the water's
/// tone (`LiveryGalleryView`). The on-water scales, the open-water zoom and the pinch maximum, come with the boat's
/// livery (#372). In a file of its own beside `RenderFixtureUITests`, as the camera's are.
extension RenderFixtureUITests {
    @objc @MainActor func testLiveryAtThreeScalesMatchesReferences() throws {
        try assertAllMatchReferences(["livery-large"])
    }
}
