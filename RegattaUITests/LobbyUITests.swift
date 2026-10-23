import XCTest

/// The lobby on Home (#142, #17, #25, #34) on the fake services: quick-chat, Report and Block on a long-press, the
/// boat card, the composer's locked, muted and not-sent states, the hidden panel for a restricted player or Hide lobby
/// chat, and the silence while she is racing. CI only, like every UI test. The panel's matrix, the feed and the
/// composer are unit-tested (`LobbyPanelStateTests`, `LobbyFeedTests`, `LobbyModelTests`).
///
/// Every scenario's lobby opens on the same lines (`ServiceSet`'s story): a gun, Kestrel, Tern, the winner, Skua,
/// Petrel and Wren's "one more?" last (`fake-7`).
final class LobbyUITests: XCTestCase {
    /// Wren's line, the newest: the one the menus and the card use.
    private static let wrensLine = "lobby-line-fake-7"

    @MainActor private func launch(_ scenario: String, reset: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        app.launchArguments = ["-uitesting", "-fakeServices", scenario] + (reset ? ["-resetSettings"] : [])
        app.launch()
        return app
    }

    @MainActor private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// Launches `scenario` and waits for the open lobby's lines.
    @MainActor private func openLobby(_ scenario: String) -> XCUIApplication {
        let app = launch(scenario)
        XCTAssertTrue(element(app, "lobby-feed").waitForExistence(timeout: 30), "the lobby didn't open on \(scenario)")
        XCTAssertTrue(element(app, Self.wrensLine).waitForExistence(timeout: 20), "no line by Wren")
        return app
    }

    /// Waits up to `timeout` for `element` to be gone.
    @MainActor private func waitForGone(_ element: XCUIElement, timeout: TimeInterval = 10, _ message: String) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: timeout), .completed, message)
    }

    /// Long-presses Wren's line and taps `action` in its menu.
    @MainActor private func longPressWren(_ app: XCUIApplication, _ action: String) {
        element(app, Self.wrensLine).press(forDuration: 1.2)
        let button = app.buttons[action]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "no \(action) in Wren's menu")
        button.tap()
    }

    /// The texts reading `text` exactly.
    @MainActor private func texts(_ app: XCUIApplication, _ text: String) -> XCUIElementQuery {
        app.staticTexts.matching(NSPredicate(format: "label == %@", text))
    }

    // MARK: The ticket's five

    /// Quick-chat posts at once, before free text unlocks: her "gg" joins Tern's, under her name.
    @MainActor func testQuickChatPosts() {
        let app = openLobby("joinable")
        let before = texts(app, "gg").count
        let gg = app.buttons["lobby-quick-gg"]
        XCTAssertTrue(gg.isEnabled, "quick-chat is off before the first race")
        gg.tap()
        let posted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == %d", before + 1), object: texts(app, "gg"))
        XCTAssertEqual(XCTWaiter().wait(for: [posted], timeout: 10), .completed, "her gg never showed")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Sailor'")).firstMatch.exists, "no line under her name")
    }

    /// Report has no confirm: Wren's line goes at once, and the others stay.
    @MainActor func testReportHidesTheMessage() {
        let app = openLobby("joinable")
        longPressWren(app, "Report")
        waitForGone(element(app, Self.wrensLine), "the reported line still shows")
        XCTAssertTrue(element(app, "lobby-line-fake-6").exists, "the report took Petrel's line too")
        XCTAssertTrue(element(app, "lobby-line-fake-1").exists, "the report took the gun line")
    }

    /// Block confirms, then every line by Wren goes, and Settings' Blocked players lists her.
    @MainActor func testBlockRemovesTheSendersLines() {
        let app = openLobby("joinable")
        longPressWren(app, "Block Wren")
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Block'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "no Block confirm")
        confirm.tap()
        waitForGone(element(app, Self.wrensLine), "Wren's line still shows after the block")
        XCTAssertFalse(app.staticTexts["Wren"].exists, "a line by Wren still shows")
        XCTAssertTrue(element(app, "lobby-line-fake-6").exists, "the block took Petrel's line too")

        app.buttons["toolbar-settings"].tap()
        let blocked = element(app, "settings-blockedPlayers")
        XCTAssertTrue(blocked.waitForExistence(timeout: 20), "no Blocked players in Settings")
        blocked.tap()
        XCTAssertTrue(element(app, "page-blockedPlayers").waitForExistence(timeout: 20), "Blocked players didn't open")
        XCTAssertTrue(element(app, "blockedPlayers-unblock-G:fake-2").waitForExistence(timeout: 20), "Wren isn't in Blocked players")
    }

    /// A player Game Center keeps from chat sees the leaderboard panel, and no chat: no feed, no quick-chat, no field.
    @MainActor func testRestrictedSeesTheLeaderboardPanel() {
        for scenario in ["communication-restricted", "underage"] {
            let app = launch(scenario)
            XCTAssertTrue(element(app, "lobby-hidden").waitForExistence(timeout: 30), "no hidden panel on \(scenario)")
            XCTAssertTrue(element(app, "lobby-leaderboard").waitForExistence(timeout: 10), "no Leaderboard row on \(scenario)")
            XCTAssertFalse(element(app, "lobby-feed").exists, "\(scenario) sees the feed")
            XCTAssertFalse(element(app, "lobby-quick-gg").exists, "\(scenario) sees quick-chat")
            XCTAssertFalse(element(app, "lobby-field").exists, "\(scenario) sees the field")
        }
    }

    /// From fleet lock until her own finish the lobby says she's racing: no lines, no composer (`rejoinable`, the
    /// race she dropped out of still running).
    @MainActor func testLobbyIsSilentDuringTheRace() {
        let app = launch("rejoinable")
        XCTAssertTrue(element(app, "lobby-silent").waitForExistence(timeout: 30), "no silent panel during the race")
        XCTAssertFalse(element(app, "lobby-feed").exists, "the feed shows during the race")
        XCTAssertFalse(element(app, "lobby-composer").exists, "the composer shows during the race")
        XCTAssertFalse(element(app, "lobby-quick-gg").exists, "quick-chat shows during the race")
    }

    // MARK: The brief's others

    /// Before her first online race the field is off and quick-chat is on (G5).
    @MainActor func testFreeTextLockedUntilFirstRace() {
        let app = openLobby("joinable")
        let field = element(app, "lobby-field")
        XCTAssertTrue(field.exists, "no field")
        XCTAssertFalse(field.isEnabled, "the field is on before the first race")
        XCTAssertTrue(app.buttons["lobby-quick-gg"].isEnabled, "quick-chat is off before the first race")
    }

    /// A post the filter blocks comes back to her alone, greyed and marked "Not sent" (G7).
    @MainActor func testBlockedPostIsGreyedNotSent() {
        let app = openLobby("lobby-free-text")
        let field = element(app, "lobby-field")
        XCTAssertTrue(field.isEnabled, "the field is off with free text open")
        field.tap()
        field.typeText("badword")
        app.buttons["lobby-send"].tap()
        XCTAssertTrue(element(app, "lobby-not-sent").waitForExistence(timeout: 10), "no Not sent on the blocked post")
        XCTAssertTrue(app.staticTexts["badword"].exists, "the blocked post isn't shown to her")
    }

    /// A muted player is told until when, and can't post (G10).
    @MainActor func testMutedShowsItsEnd() {
        let app = openLobby("lobby-muted")
        let muted = element(app, "lobby-muted")
        XCTAssertTrue(muted.waitForExistence(timeout: 10), "no muted notice")
        let label = muted.label + " " + muted.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
        XCTAssertTrue(label.contains("Muted until "), "the muted notice reads \(label)")
        XCTAssertFalse(app.buttons["lobby-quick-gg"].isEnabled, "quick-chat is on while muted")
        XCTAssertFalse(element(app, "lobby-field").isEnabled, "the field is on while muted")
    }

    /// Settings' Hide lobby chat takes the chat off Home for the hidden panel, and no feed (G12).
    @MainActor func testHideLobbyChatShowsTheHiddenPanel() {
        let app = launch("joinable", reset: true)
        addTeardownBlock {
            MainActor.assumeIsolated {
                let app = XCUIApplication()
                if app.state != .notRunning { app.terminate() }
                app.launchArguments = ["-uitesting", "-resetSettings"]
                app.launch()
                app.terminate()
            }
        }
        XCTAssertTrue(element(app, "lobby-feed").waitForExistence(timeout: 30), "the lobby didn't open")
        app.buttons["toolbar-settings"].tap()
        let toggle = app.switches["settings-hidesLobbyChat"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 20), "no Hide lobby chat")
        // The Lobby section is below the fold (CI's iPhone 17: the switch at y 1034 in an 874 pt window), and a
        // coordinate tap doesn't scroll to its element: scrolled into view first, or the tap lands on nothing.
        for _ in 0..<6 where !toggle.isHittable {
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(toggle.isHittable, "Hide lobby chat didn't scroll into view")
        let before = toggle.value as? String
        for _ in 1...2 where toggle.value as? String == before {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", before ?? ""), object: toggle)],
                               timeout: 5)
        }
        XCTAssertEqual(toggle.value as? String, "1", "Hide lobby chat didn't switch on")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(element(app, "lobby-hidden").waitForExistence(timeout: 20), "no hidden panel with Hide lobby chat on")
        XCTAssertFalse(element(app, "lobby-feed").exists, "the feed shows with Hide lobby chat on")
    }

    /// Wren's chip and name open her boat card: her current boat's render and sail number, nickname, rating, Report
    /// player and Block (G14).
    @MainActor func testBoatCardOpensFromTheChip() {
        let app = openLobby("joinable")
        element(app, Self.wrensLine + "-sailor").tap()
        XCTAssertTrue(element(app, "sheet-boatCard").waitForExistence(timeout: 20), "no boat card")
        XCTAssertTrue(element(app, "boatCard-sail").waitForExistence(timeout: 20), "no sail number on the card")
        XCTAssertEqual(element(app, "boatCard-sail").label, "Sail 112")
        XCTAssertEqual(element(app, "boatCard-nickname").label, "Wren")
        XCTAssertEqual(element(app, "boatCard-rating").value as? String, "1610")
        XCTAssertFalse(element(app, "boatCard-provisional").exists, "an established rating has the Provisional badge")
        XCTAssertTrue(element(app, "boatCard-render").exists, "no render")
        XCTAssertTrue(app.buttons["boatCard-report"].exists, "no Report player")
        XCTAssertTrue(app.buttons["boatCard-block"].exists, "no Block")
    }
}
