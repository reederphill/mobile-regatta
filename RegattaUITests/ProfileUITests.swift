import XCTest

/// The profile (#139, #25) on the fake services, pushed from Home's toolbar: signed in, the rating with its
/// provisional badge, races, wins, the next earned design's "n / N races", your livery and the leaderboard; signed
/// out, only Game Center's sign-in prompt, which brings the profile in. CI only, like every UI test. The page's
/// states and rows are unit-tested (`ProfilePageStateTests`, `ProfileModelTests`).
final class ProfileUITests: XCTestCase {
    /// Launches on `scenario`'s fakes and pushes the profile from Home's toolbar.
    @MainActor private func openProfile(_ scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        app.launchArguments = ["-uitesting", "-fakeServices", scenario]
        app.launch()
        let button = app.buttons["toolbar-profile"]
        XCTAssertTrue(button.waitForExistence(timeout: 30), "no Profile in Home's toolbar")
        button.tap()
        XCTAssertTrue(element(app, "page-profile").waitForExistence(timeout: 20), "Profile didn't push its page")
        XCTAssertTrue(app.navigationBars["Profile"].exists, "the page isn't titled Profile")
        return app
    }

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// Waits for `id` to read `value` (the number rows carry theirs as the accessibility value).
    @MainActor private func expect(_ app: XCUIApplication, _ id: String, value: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let row = element(app, id)
        XCTAssertTrue(row.waitForExistence(timeout: 20), "no \(id)", file: file, line: line)
        XCTAssertEqual(row.value as? String, value, id, file: file, line: line)
    }

    /// The ticket's first acceptance: a new player, signed in (`joinable`).
    @MainActor func testSignedInNewPlayerShowsRatingBadgeRacesWinsProgressRenderLeaderboard() {
        let app = openProfile("joinable")
        expect(app, "profile-rating", value: "1500")
        XCTAssertEqual(element(app, "profile-nickname").label, "Sailor")
        XCTAssertTrue(element(app, "profile-provisional").exists, "no Provisional badge on a new player's 1500")
        expect(app, "profile-races", value: "0")
        expect(app, "profile-wins", value: "0")
        let progress = element(app, "profile-progress")
        XCTAssertTrue(progress.exists, "no Next design row")
        XCTAssertTrue((progress.value as? String)?.contains("0 / 10 races") == true, "progress reads \(String(describing: progress.value))")
        XCTAssertTrue(element(app, "profile-render").exists, "no livery render")
        let leaderboard = app.buttons["profile-leaderboard"]
        XCTAssertTrue(leaderboard.exists, "no Leaderboard row")
        XCTAssertTrue(leaderboard.isEnabled, "the Leaderboard row is disabled")
    }

    /// An established rating has no badge (`profile-established`: 1586, 32 races, 4 wins, next at 50).
    @MainActor func testEstablishedPlayerShowsNoBadge() {
        let app = openProfile("profile-established")
        expect(app, "profile-rating", value: "1586")
        XCTAssertFalse(element(app, "profile-provisional").exists, "an established rating has the Provisional badge")
        expect(app, "profile-races", value: "32")
        expect(app, "profile-wins", value: "4")
        let progress = element(app, "profile-progress")
        XCTAssertTrue((progress.value as? String)?.contains("32 / 50 races") == true, "progress reads \(String(describing: progress.value))")
    }

    /// The ticket's second acceptance: signed out, only the sign-in prompt and no rating; Sign in (the scripted
    /// Game Center sign-in, then the terms) brings the profile in.
    @MainActor func testSignedOutShowsOnlyTheSignInPrompt() {
        let app = openProfile("signed-out")
        let signIn = app.buttons["profile-sign-in"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 20), "no Sign in on a signed-out profile")
        for id in ["profile-rating", "profile-provisional", "profile-races", "profile-wins", "profile-progress", "profile-render",
                   "profile-leaderboard", "profile-nickname"] {
            XCTAssertFalse(element(app, id).exists, "\(id) shows signed out")
        }

        signIn.tap()
        // Signed in, the terms come first, as the lobby area's Sign in has it.
        let agree = app.buttons["terms-agree"]
        XCTAssertTrue(agree.waitForExistence(timeout: 15), "no terms sheet after signing in")
        agree.tap()
        XCTAssertTrue(element(app, "profile-rating").waitForExistence(timeout: 20), "the sign-in didn't bring the profile in")
        XCTAssertFalse(signIn.exists, "the sign-in prompt stayed after signing in")
    }

    /// A suspension shows its end in Race online's words; a ban says racing is closed.
    @MainActor func testSuspensionShowsItsEnd() {
        for (scenario, prefix) in [("suspended", "Racing paused until "), ("suspended-permanent", "Racing closed")] {
            let app = openProfile(scenario)
            let notice = element(app, "profile-suspension")
            XCTAssertTrue(notice.waitForExistence(timeout: 20), "no suspension notice on \(scenario)")
            XCTAssertTrue(notice.label.hasPrefix(prefix), "\(scenario)'s notice reads \(notice.label)")
            XCTAssertTrue(element(app, "profile-rating").exists, "the rest of the profile is gone on \(scenario)")
        }
    }
}
