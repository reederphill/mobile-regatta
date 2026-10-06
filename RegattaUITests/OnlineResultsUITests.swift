import XCTest

/// The online results (#133, #24) on the fake results stream (`-fakeServices online-results`, `-onlineResults`): the
/// sheet over the race's dark chrome, fed by the scenario's paced stream, a boat finishing every 1.5 s, then the close,
/// then the rating. A harness, not a sailed race: the session's use of the stream is unit-tested
/// (`OnlineResultsTests`), and the end-to-end through a real server is #163's. CI only, like every UI test.
final class OnlineResultsUITests: XCTestCase {
    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        app.launchArguments = ["-uitesting", "-fakeServices", "online-results", "-onlineResults", "-completedRaces", "9"]
        app.launch()
        return app
    }

    /// Rows fill in live: boats still racing read "Sailing" and turn into results as they finish; your rating reads
    /// pending through the close and turns into the pushed change.
    @MainActor func testRowsFillInLiveAndRatingGoesFromPendingToPushed() throws {
        let app = launch()
        XCTAssertTrue(app.staticTexts["race-results"].waitForExistence(timeout: 30), "the online results never came up")
        let rows = app.descendants(matching: .any).matching(identifier: "results-row")
        XCTAssertEqual(rows.count, 6, "the six boats aren't all listed")
        let sailing = app.staticTexts.matching(NSPredicate(format: "label == %@", "Sailing"))
        XCTAssertGreaterThan(sailing.count, 0, "no boat reads Sailing while the race runs")
        let rating = app.staticTexts["results-rating"]
        XCTAssertTrue(rating.waitForExistence(timeout: 10), "no rating under your row")
        XCTAssertEqual(rating.label, "Rating pending")

        // The close: nobody sails any more, and the rows are all scored.
        let filled = NSPredicate(format: "count == 0")
        expectation(for: filled, evaluatedWith: sailing)
        waitForExpectations(timeout: 20)
        XCTAssertEqual(rows.count, 6)

        let pushed = NSPredicate(format: "label == %@", "+12 → 1512")
        expectation(for: pushed, evaluatedWith: rating)
        waitForExpectations(timeout: 15)
        XCTAssertTrue(app.staticTexts["results-provisional"].exists, "no provisional tag on a provisional rating")
        XCTAssertTrue(app.descendants(matching: .any)["results-yourRace"].exists, "no Your race card for the call against you")
        // The earned design has no art yet (#169): no line, though this race is the tenth.
        XCTAssertFalse(app.descendants(matching: .any)["results-earned"].exists, "the earned line shows an undrawn design")
        XCTAssertTrue(app.buttons["results-raceAgain"].exists && app.buttons["results-menu"].exists)
    }

    /// Race again joins the queue and goes home.
    @MainActor func testRaceAgainGoesHome() throws {
        let app = launch()
        let raceAgain = app.buttons["results-raceAgain"]
        XCTAssertTrue(raceAgain.waitForExistence(timeout: 30), "no Race again")
        raceAgain.tap()
        XCTAssertTrue(app.staticTexts["race-results"].waitForNonExistence(timeout: 10), "the results stayed up")
        XCTAssertTrue(app.buttons["toolbar-myboat"].waitForExistence(timeout: 10), "Race again didn't go home")
    }
}
