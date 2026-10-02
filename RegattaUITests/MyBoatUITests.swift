import XCTest

/// My boat (#136): the livery editor and shop. UI tests keep My boat's livery in a suite of their own, emptied at
/// launch (`MyBoatDefaults`), starting from the fixed livery (plain skiff, sky-blue deck, white sail, 207); a relaunch
/// passes `-keepMyBoat` to keep what was saved.
final class MyBoatUITests: RaceUITestCase {
    /// Launches with `-uitesting` and `extra`; opens My boat from home unless `extra` already opens it.
    @MainActor private func openMyBoat(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        app.launchArguments = ["-uitesting"] + extra
        app.launch()
        if !extra.contains("-myBoat") {
            let item = app.buttons["toolbar-myboat"]
            XCTAssertTrue(item.waitForExistence(timeout: 30), "no My boat on the home screen")
            item.tap()
        }
        XCTAssertTrue(app.descendants(matching: .any)["page-myboat"].firstMatch.waitForExistence(timeout: 20),
                      "My boat didn't open")
        return app
    }

    /// `id`, scrolled into view: the page's grids are lazy, so a row below the fold isn't there until scrolled to.
    @MainActor private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        let element = app.descendants(matching: .any)[id].firstMatch
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5), "no \(id)")
        return element
    }

    @MainActor private func action(_ app: XCUIApplication) -> XCUIElement {
        let action = app.buttons["myboat-action"]
        XCTAssertTrue(action.waitForExistence(timeout: 10), "no My boat button")
        return action
    }

    /// Replaces the sail number with `text`.
    @MainActor private func type(_ text: String, in app: XCUIApplication) {
        let field = element("myboat-number", in: app)
        field.tap()
        let old = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: max(old.count, 6)) + text)
    }

    /// Change colours and the number, Save, relaunch: they're kept.
    @MainActor func testColoursAndNumberPersistAcrossRelaunch() {
        var app = openMyBoat()
        XCTAssertEqual(action(app).label, "Saved")
        element("myboat-colour-deck-lavender", in: app).tap()
        element("myboat-colour-sail-off-white", in: app).tap()
        type("42", in: app)
        XCTAssertEqual(action(app).label, "Save")
        action(app).tap()
        XCTAssertEqual(action(app).label, "Saved", "Save didn't save")

        app.terminate()
        app = openMyBoat(["-keepMyBoat"])
        XCTAssertEqual(element("myboat-colour-deck-lavender", in: app).value as? String, "selected", "the deck colour wasn't kept")
        XCTAssertEqual(element("myboat-colour-sail-off-white", in: app).value as? String, "selected", "the sail colour wasn't kept")
        XCTAssertEqual(element("myboat-number", in: app).value as? String, "42", "the sail number wasn't kept")
        XCTAssertEqual(action(app).label, "Saved")
    }

    /// A paid design you don't own can be tried on: the button is Buy, never Save, and leaving keeps your livery.
    @MainActor func testUnownedDesignShowsBuyAndCannotBeSaved() {
        var app = openMyBoat()
        element("myboat-design-skiff-stars", in: app).tap()
        XCTAssertEqual(element("myboat-design-skiff-stars", in: app).value as? String, "selected")
        XCTAssertTrue(action(app).label.hasPrefix("Buy $"), "an unowned design's button is \(action(app).label)")
        // Change a colour too: still Buy, not Save.
        element("myboat-colour-deck-lavender", in: app).tap()
        XCTAssertTrue(action(app).label.hasPrefix("Buy $"), "an unowned design's button is \(action(app).label)")

        app.terminate()
        app = openMyBoat(["-keepMyBoat"])
        XCTAssertEqual(element("myboat-design-skiff-plain", in: app).value as? String, "selected",
                       "the unowned design was saved")
        XCTAssertNotEqual(element("myboat-design-skiff-stars", in: app).value as? String, "selected")
    }

    /// `-myBoat <design>` (the Try it deep link) opens on that design; numbers 0 and 10000 are refused. Letters
    /// can't be typed on the number pad, so `MyBoatModelTests.sailNumberRejectsZeroTenThousandLettersAndEmpty`
    /// covers them.
    @MainActor func testSailNumberRangeRejectedAndDeepLinkSelectsDesign() {
        let app = openMyBoat(["-myBoat", "skiff-stripe"])
        XCTAssertEqual(element("myboat-design-skiff-stripe", in: app).value as? String, "selected",
                       "-myBoat didn't select its design")
        XCTAssertEqual(action(app).label, "Save", "a free design tried on is Save")
        for text in ["0", "10000"] {
            type(text, in: app)
            XCTAssertEqual(element("myboat-number", in: app).value as? String, text, "the typed number was changed")
            XCTAssertTrue(app.descendants(matching: .any)["myboat-number-hint"].firstMatch.waitForExistence(timeout: 5),
                          "\(text) shows no hint")
            XCTAssertFalse(action(app).isEnabled, "\(text) can be saved")
        }
        type("12", in: app)
        XCTAssertTrue(action(app).isEnabled, "12 can't be saved")
    }
}
