import XCTest

/// Hints (#23, #129): the first race's first hint is the steering one, in the scheme in use, within 2 s. Under
/// `-uitesting` hint progress is kept in memory, so every race is a first. CI only.
final class HintUITests: RaceUITestCase {
    @MainActor func testFirstRaceShowsSteeringHintWithin2s() throws {
        let app = launchRace()
        let notice = app.descendants(matching: .any)["race-notice"]
        // The hint is posted as the race is set up, before its clock shows; it shows for about 4 s.
        let seen = watch(notice, every: 0.25, until: Date.now.addingTimeInterval(2)) { snapshot in
            "\(snapshot.value ?? "")" == "hint" && snapshot.label.contains("to steer")
        }
        XCTAssertTrue(seen.seen, "no steering hint within 2 s: \"\(seen.last?.label ?? "nothing")\"")
        XCTAssertTrue(seen.last?.label.contains("Settings") == true, "the first hint mentions Settings")
    }
}
