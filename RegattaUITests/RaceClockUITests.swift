import XCTest

final class RaceClockUITests: RaceUITestCase {
    /// The race clock's tick goes up over a second of real time. Each read of the tick is one look at the clock
    /// (`watch`), tried again for up to 60 s if it times out: a timed-out query took about 45 s to fail in CI, so a
    /// shorter deadline would end on that look. With the launch and the second between the reads, the waits add up
    /// to 151 s, under the 3.5 min a test's waits get (`RaceUITestCase`).
    @MainActor func testRaceClockAdvancesAfterAutostart() throws {
        let app = launchRace()
        let clock = app.staticTexts["race-clock"]
        let first = try tick(of: clock)
        Thread.sleep(forTimeInterval: 1)
        let second = try tick(of: clock)

        attachScreenshot(named: "race-clock")
        XCTAssertGreaterThan(second, first, "race clock did not advance in 1 s")
    }

    /// The tick the clock shows, from its value in the first look that doesn't throw. Reading `clock.value`
    /// records a timed-out query as a failure, which ends the test.
    @MainActor private func tick(of clock: XCUIElement) throws -> Int {
        let look = watch(clock, until: .now.addingTimeInterval(60)) { _ in true }
        let snapshot = try XCTUnwrap(look.last, "no race clock")
        let value = try XCTUnwrap(snapshot.value as? String, "race clock has no accessibility value")
        return try XCTUnwrap(Int(value), "race clock value \(value) is not a tick")
    }
}
