import XCTest

extension XCTestCase {
    /// Attaches a PNG of the screen to the test's result bundle, kept whether the test passes or fails.
    @MainActor func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(data: XCUIScreen.main.screenshot().pngRepresentation, uniformTypeIdentifier: "public.png")
        attachment.name = "\(name).png"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
