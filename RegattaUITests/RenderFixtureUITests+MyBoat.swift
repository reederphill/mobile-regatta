import UIKit
import XCTest

/// My boat (#136) as off-water galleries (`MenuGalleryView`): a free design saved, and a starter after fleet lock.
/// Paid and earned designs have no art until #169, which brings back the shop fixture. Each fixture carries its own
/// livery, so none reads the device's. CI records the references; the owner approves them before adoption.
extension RenderFixtureUITests {
    @objc @MainActor func testMyBoatMatchesReferences() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad,
                      "render references are recorded on iPhone 17 only; the iPad run doesn't compare them")
        continueAfterFailure = true
        defer { continueAfterFailure = false }
        for name in ["my-boat", "my-boat-locked"] {
            try assertMatchesReference(name)
        }
    }
}
