import XCTest

/// The race HUD (#114, #15): the clock, place, ground wind, minimap and one notice line, and nothing else, inside the
/// race rect at every size `RaceViewportPolicy` gives it (#107).
final class HUDUITests: RaceUITestCase {
    /// Every element the HUD shows, by accessibility identifier.
    static let elements = ["race-clock", "race-place", "race-wind", "race-minimap", "race-notice"]

    override func tearDown() {
        super.tearDown()
        MainActor.assumeIsolated { XCUIDevice.shared.orientation = .portrait }
    }

    /// The HUD is the clock, place, wind, minimap and notice line (#15): none of the instrument strip, target pill,
    /// penalty banner or shadow readout it replaced.
    @MainActor func testHUDElementsAreClockPlaceWindMinimapNotice() throws {
        let app = launchRace()
        for id in Self.elements {
            XCTAssertTrue(app.descendants(matching: .any)[id].waitForExistence(timeout: 10), "no \(id)")
        }
        let wind = app.descendants(matching: .any)["race-wind"]
        XCTAssertNotNil(wind.label.firstMatch(of: /^\d+ kn, from \d{1,3}°$/), "wind reads \"\(wind.label)\"")
        for gone in ["Speed", "Wind angle", "Dirty air", "Start line", "PENALTY"] {
            XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", gone)).firstMatch.exists,
                           "the HUD still shows \"\(gone)\"")
        }
        attachScreenshot(named: "hud-elements")
    }

    /// On iPad, portrait and landscape (letterboxed, #107): every HUD element inside the race rect, and the clock,
    /// wind and minimap clear of each other.
    @MainActor func testHUDInsideWindowAtTwoIPadSizes() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("the iPad sizes need an iPad") }
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let app = launchRace()
            let viewport = app.otherElements["race-viewport"]
            XCTAssertTrue(viewport.waitForExistence(timeout: 60), "no race viewport")
            let race = viewport.frame
            var frames: [String: CGRect] = [:]
            for id in Self.elements {
                let element = app.descendants(matching: .any)[id]
                XCTAssertTrue(element.waitForExistence(timeout: 10), "no \(id)")
                frames[id] = element.frame
                XCTAssertTrue(race.contains(element.frame), "\(id) \(element.frame) is outside the race rect \(race) in \(orientation.rawValue)")
            }
            let top = ["race-clock", "race-wind", "race-minimap"]
            for (i, a) in top.enumerated() {
                for b in top[(i + 1)...] {
                    XCTAssertFalse(frames[a]!.intersects(frames[b]!), "\(a) \(frames[a]!) overlaps \(b) \(frames[b]!)")
                }
            }
            attachScreenshot(named: "hud-ipad-\(orientation == .portrait ? "portrait" : "landscape")")
            app.terminate()
        }
    }
}
