import XCTest

/// What the server and the session say on Home (#161), on the fake services: the line under Race online for a
/// suspension, the cooldown, a refusal and an update, with no tap; an unreachable server and a sign-in that failed,
/// said under a button that tries again, and in the lobby area with Try again; the wait for the session; and an I agree
/// that couldn't be saved. CI only, like every UI test. The lines and the gate are unit-tested
/// (`RestrictionLinesTests`, `OnlineSessionWiringTests`).
final class OnlineRestrictionUITests: XCTestCase {
    @MainActor private func launch(_ scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        app.launchArguments = ["-uitesting", "-fakeServices", scenario]
        app.launch()
        return app
    }

    /// Waits for `element` to match `format`, a predicate over its attributes.
    @MainActor private func wait(on element: XCUIElement, _ format: String, with arguments: [Any] = [], timeout: TimeInterval = 15,
                                 _ message: String) {
        let matched = XCTNSPredicateExpectation(predicate: NSPredicate(format: format, argumentArray: arguments), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [matched], timeout: timeout), .completed, "\(message): \(element.label)")
    }

    /// Race online, once it is disabled with `line` under it.
    @MainActor private func closedRaceOnline(_ app: XCUIApplication, line: String) -> XCUIElement {
        let raceOnline = app.buttons["race-online"]
        XCTAssertTrue(raceOnline.waitForExistence(timeout: 20), "no Race online")
        wait(on: raceOnline, "isEnabled == false AND label CONTAINS %@", with: [line], "Race online isn't closed under \"\(line)\"")
        return raceOnline
    }

    /// A suspension, with its day or for good: Race online closed, and practice as ever.
    @MainActor func testASuspensionClosesRaceOnlineAndPracticeStillOpens() {
        var app = launch("suspended")
        _ = closedRaceOnline(app, line: "Racing paused until ")
        XCTAssertTrue(app.staticTexts["Lobby"].exists, "a suspension from racing closed the lobby area")
        app.buttons["practice"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["page-practiceSetup"].firstMatch.waitForExistence(timeout: 20),
                      "Practice didn't open for a suspended player")

        app = launch("suspended-permanent")
        _ = closedRaceOnline(app, line: "Racing closed")
    }

    /// The cooldown counts down under a closed Race online.
    @MainActor func testTheCooldownCountsDown() {
        let app = launch("cooldown")
        let raceOnline = closedRaceOnline(app, line: "Cooling off ")
        let first = raceOnline.label
        wait(on: raceOnline, "label CONTAINS 'Cooling off ' AND label != %@", with: [first], "the cooldown stands still")
    }

    /// A refusal she isn't told the reason of, and a build the server no longer takes.
    @MainActor func testARefusalAndAnUpdateCloseRaceOnline() {
        _ = closedRaceOnline(launch("cannot-race"), line: "Can't race online right now")
        _ = closedRaceOnline(launch("update-required"), line: "Update to race online")
    }

    /// An unreachable server: nothing up front; after a tap, the line under a Race online that still taps, and the
    /// lobby area's Try again.
    @MainActor func testAnUnreachableServerIsSaidAfterATap() {
        let app = launch("unreachable")
        let raceOnline = app.buttons["race-online"]
        XCTAssertTrue(raceOnline.waitForExistence(timeout: 20), "no Race online")
        XCTAssertTrue(raceOnline.isEnabled, "Race online is closed before any tap")
        XCTAssertFalse(raceOnline.label.contains("Can't reach the server"), "the server is called unreachable before a tap")
        XCTAssertFalse(app.buttons["lobby-retry"].exists, "Try again before a tap")
        raceOnline.tap()

        wait(on: raceOnline, "isEnabled == true AND label CONTAINS %@", with: ["Can't reach the server"], "no line after the tap failed")
        let retry = app.buttons["lobby-retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10), "no Try again in the lobby area")
        XCTAssertTrue(app.staticTexts["Can't reach the server"].exists, "the lobby area doesn't say why")
        retry.tap()
        // Still away: the line and Try again stand once the try is over.
        wait(on: raceOnline, "isEnabled == true AND label CONTAINS %@", with: ["Can't reach the server"], "Try again lost the line")
        XCTAssertTrue(retry.waitForExistence(timeout: 10), "Try again went away with the server still unreachable")
        XCTAssertFalse(app.buttons["terms-agree"].exists, "a tap with no session went on to the terms")
    }

    /// A sign-in the server refuses: said under a Race online that still taps, and in the lobby area with Try again.
    @MainActor func testASignInTheServerRefusesIsSaid() {
        let app = launch("session-failed")
        let raceOnline = app.buttons["race-online"]
        XCTAssertTrue(raceOnline.waitForExistence(timeout: 20), "no Race online")
        raceOnline.tap()
        wait(on: raceOnline, "isEnabled == true AND label CONTAINS %@", with: ["Couldn't sign in"], "no line after the sign-in was refused")
        let retry = app.buttons["lobby-retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10), "no Try again in the lobby area")
        XCTAssertTrue(app.staticTexts["Couldn't sign in"].exists, "the lobby area doesn't say why")
        XCTAssertFalse(app.buttons["lobby-sign-in"].exists, "the lobby area asks a signed-in player to sign in to Game Center")
        retry.tap()
        // Refused again: the line and Try again stand, and nothing goes on to the terms.
        wait(on: raceOnline, "isEnabled == true AND label CONTAINS %@", with: ["Couldn't sign in"], "Try again lost the line")
        XCTAssertTrue(retry.waitForExistence(timeout: 10), "Try again went away with the sign-in still refused")
        XCTAssertFalse(app.buttons["terms-agree"].exists, "a tap with no session went on to the terms")
    }

    /// A tap that waits for the session: Race online can't be tapped again, and says nothing yet.
    @MainActor func testATapWaitingForTheSessionClosesRaceOnline() {
        let app = launch("connecting")
        let raceOnline = app.buttons["race-online"]
        XCTAssertTrue(raceOnline.waitForExistence(timeout: 20), "no Race online")
        XCTAssertTrue(raceOnline.isEnabled, "Race online is closed before the tap")
        raceOnline.tap()
        wait(on: raceOnline, "isEnabled == false", "Race online still taps while the session opens")
        XCTAssertFalse(raceOnline.label.contains("Can't reach the server"), "a wait reads as a failure")
    }

    /// An I agree that can't be saved: the sheet stays and says so; closed and reopened, it has forgotten.
    @MainActor func testAnAgreeThatCannotBeSavedKeepsTheSheet() {
        let app = launch("terms-save-failed")
        XCTAssertTrue(app.buttons["race-online"].waitForExistence(timeout: 20), "no Race online")
        app.buttons["race-online"].tap()
        let agree = app.buttons["terms-agree"]
        XCTAssertTrue(agree.waitForExistence(timeout: 10), "no terms sheet after signing in")
        let failed = app.staticTexts["terms-save-failed"]
        XCTAssertFalse(failed.exists, "the sheet opens with the line")
        agree.tap()
        XCTAssertTrue(failed.waitForExistence(timeout: 10), "no line after the save failed")
        XCTAssertEqual(failed.label, "Couldn't save. Try again.")
        XCTAssertTrue(agree.exists, "the sheet went away on a save that failed")
        XCTAssertFalse(app.alerts["Online racing is on its way"].exists, "a save that failed went on to the queue")

        app.buttons["terms-close"].tap()
        XCTAssertTrue(agree.waitForNonExistence(timeout: 10), "Close didn't close the sheet")
        let reopen = app.buttons["lobby-terms"]
        XCTAssertTrue(reopen.waitForExistence(timeout: 10), "no Review terms after closing the sheet")
        reopen.tap()
        XCTAssertTrue(agree.waitForExistence(timeout: 10), "Review terms didn't reopen the sheet")
        XCTAssertFalse(failed.exists, "the reopened sheet kept the last one's line")
    }
}
