import XCTest

/// Race online's gate (#138) on the fake services: Game Center's sign-in (the fake signs in at once), the Terms of
/// Use sheet, then the queue's stand-in, the stub alert, until #140. Declining keeps the sheet a tap away in the
/// lobby area; a version bump asks again; a multiplayer-restricted player gets practice races only. CI only, like
/// every UI test. The gating matrix itself is unit-tested (`OnlineAccessTests`, `OnlineStatusTests`).
final class OnlineGateUITests: XCTestCase {
    @MainActor private func launch(_ scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        app.launchArguments = ["-uitesting", "-fakeServices", scenario]
        app.launch()
        return app
    }

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// Signed out: Race online → sign-in → the terms sheet → I agree → the stub alert.
    @MainActor func testRaceOnlineSignsInThenTermsThenQueue() {
        let app = launch("signed-out")
        XCTAssertTrue(app.staticTexts["Sign in to Game Center to chat"].waitForExistence(timeout: 20), "no signed-out lobby panel")
        let raceOnline = app.buttons["race-online"]
        XCTAssertTrue(raceOnline.isEnabled, "Race online is disabled signed out")
        raceOnline.tap()

        let agree = app.buttons["terms-agree"]
        XCTAssertTrue(agree.waitForExistence(timeout: 10), "no terms sheet after signing in")
        XCTAssertTrue(app.buttons["terms-close"].exists, "no Close on the terms sheet")
        agree.tap()
        XCTAssertTrue(app.alerts["Online racing is on its way"].waitForExistence(timeout: 10), "I agree didn't go on to the queue")
    }

    /// Closing the sheet declines: no queue; the lobby area asks for the terms and reopens the sheet.
    @MainActor func testDecliningLeavesTheReopenInTheLobby() {
        let app = launch("signed-out")
        XCTAssertTrue(app.buttons["race-online"].waitForExistence(timeout: 20))
        app.buttons["race-online"].tap()
        let close = app.buttons["terms-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10), "no terms sheet after signing in")
        close.tap()
        XCTAssertTrue(app.buttons["terms-close"].waitForNonExistence(timeout: 10), "Close didn't close the sheet")
        XCTAssertFalse(app.alerts["Online racing is on its way"].exists, "declining went on to the queue")

        XCTAssertTrue(app.staticTexts["Accept the terms to chat and race online"].waitForExistence(timeout: 10))
        let reopen = app.buttons["lobby-terms"]
        XCTAssertTrue(reopen.exists, "no Review terms in the lobby area")
        reopen.tap()
        let agree = app.buttons["terms-agree"]
        XCTAssertTrue(agree.waitForExistence(timeout: 10), "Review terms didn't reopen the sheet")
        agree.tap()
        XCTAssertTrue(agree.waitForNonExistence(timeout: 10))
        XCTAssertFalse(app.alerts["Online racing is on its way"].exists, "the lobby's sheet went on to the queue")
        XCTAssertFalse(app.buttons["lobby-terms"].exists, "the terms are still due after I agree")
    }

    /// A version bump: signed in, accepted version 1, version 2 current. Race online shows the sheet again.
    @MainActor func testVersionBumpShowsTheSheetAgain() {
        let app = launch("terms-bump")
        XCTAssertTrue(app.buttons["lobby-terms"].waitForExistence(timeout: 20), "the bump doesn't ask in the lobby area")
        app.buttons["race-online"].tap()
        XCTAssertTrue(app.buttons["terms-agree"].waitForExistence(timeout: 10), "no terms sheet on a version bump")
        XCTAssertEqual(app.staticTexts["terms-version"].label, "Version 2")
        app.buttons["terms-agree"].tap()
        XCTAssertTrue(app.alerts["Online racing is on its way"].waitForExistence(timeout: 10))
    }

    /// Game Center's multiplayer restriction: Race online disabled, "Practice races only".
    @MainActor func testMultiplayerRestrictedIsPracticeOnly() {
        let app = launch("multiplayer-restricted")
        let raceOnline = app.buttons["race-online"]
        XCTAssertTrue(raceOnline.waitForExistence(timeout: 20))
        let restricted = NSPredicate(format: "isEnabled == false")
        expectation(for: restricted, evaluatedWith: raceOnline)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(raceOnline.label.contains("Practice races only"), "no reason under Race online: \(raceOnline.label)")
        XCTAssertTrue(element(app, "lobby-panel").exists)
    }
}
