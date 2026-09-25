import XCTest

final class RaceClockUITests: RaceUITestCase {
    @MainActor func testRaceClockAdvancesAfterAutostart() throws {
        let app = launchRace()
        let clock = app.staticTexts["race-clock"]
        let first = try tick(of: clock)
        Thread.sleep(forTimeInterval: 1)
        let second = try tick(of: clock)

        attachScreenshot(named: "race-clock")
        XCTAssertGreaterThan(second, first, "race clock did not advance in 1 s")
    }

    @MainActor private func tick(of clock: XCUIElement) throws -> Int {
        let value = try XCTUnwrap(clock.value as? String, "race clock has no accessibility value")
        return try XCTUnwrap(Int(value), "race clock value \(value) is not a tick")
    }
}
