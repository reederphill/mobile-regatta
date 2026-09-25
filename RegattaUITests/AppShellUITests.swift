import XCTest

/// The app shell (#108): the home screen, its pushed pages, and the race sequence as a full-screen cover.
final class AppShellUITests: RaceUITestCase {
    private static let toolbarPages = [
        ("toolbar-profile", "page-profile"),
        ("toolbar-myboat", "page-myboat"),
        ("toolbar-help", "page-help"),
        ("toolbar-settings", "page-settings"),
    ]

    override func tearDown() {
        super.tearDown()
        MainActor.assumeIsolated { XCUIDevice.shared.orientation = .portrait }
    }

    /// Launches to the home screen: `-uitesting`, then `extra`.
    @MainActor @discardableResult private func launchHome(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        app.launchArguments = ["-uitesting"] + extra
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["home"].firstMatch.waitForExistence(timeout: 30), "no home screen")
        return app
    }

    @MainActor func testToolbarItemsPushTheirPagesAndBack() {
        let app = launchHome()
        for (item, page) in Self.toolbarPages + [("practice", "page-practiceSetup")] {
            let button = app.buttons[item]
            XCTAssertTrue(button.waitForExistence(timeout: 10), "no \(item)")
            button.tap()
            let pushed = app.descendants(matching: .any)[page].firstMatch
            XCTAssertTrue(pushed.waitForExistence(timeout: 10), "\(item) didn't push \(page)")

            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(pushed.waitForNonExistence(timeout: 10), "back didn't pop \(page)")
            XCTAssertTrue(app.buttons["race-online"].waitForExistence(timeout: 10), "back didn't return home from \(page)")
        }
    }

    @MainActor func testRaceCoverCannotBeSwipedDown() {
        let app = launchRace()
        let cover = app.descendants(matching: .any)["race-cover"].firstMatch
        XCTAssertTrue(cover.waitForExistence(timeout: 10), "no race cover")

        let top = cover.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let bottom = cover.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        top.press(forDuration: 0.05, thenDragTo: bottom, withVelocity: .fast, thenHoldForDuration: 0)
        cover.swipeDown(velocity: .fast)
        Thread.sleep(forTimeInterval: 1.5)

        XCTAssertTrue(cover.exists, "the race cover was dismissed")
        XCTAssertTrue(app.staticTexts["race-clock"].exists, "the race clock went away")
        XCTAssertFalse(app.buttons["race-online"].isHittable, "home is showing through the race")
    }

    @MainActor func testAutostartPresentsTheRaceCover() {
        let app = launchRace()
        XCTAssertTrue(app.descendants(matching: .any)["race-cover"].firstMatch.exists, "-autostart's race isn't in the cover")
    }

    /// Quit to menu ends the race sequence and returns to the home screen.
    @MainActor func testQuitToMenuReturnsHome() {
        let app = launchRace()
        let pause = app.buttons["race-pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 10), "no pause button")
        pause.tap()
        app.buttons["Quit to menu"].tap()
        XCTAssertTrue(app.buttons["race-online"].waitForExistence(timeout: 10), "quitting didn't return home")
        XCTAssertTrue(app.descendants(matching: .any)["race-cover"].firstMatch.waitForNonExistence(timeout: 10))
    }

    /// Menus follow the system appearance: pale chart blue in light mode, navy in dark (`ChromePalette.background`).
    @MainActor func testHomeRendersInLightAndDark() throws {
        for appearance in ["light", "dark"] {
            let app = launchHome(["-appearance", appearance])
            for id in ["race-online", "practice"] + Self.toolbarPages.map(\.0) {
                XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 10), "no \(id) in \(appearance) mode")
            }
            XCTAssertTrue(app.descendants(matching: .any)["lobby-panel"].firstMatch.exists, "no lobby panel in \(appearance) mode")
            attachScreenshot(named: "home-\(appearance)")

            let screen = try XCTUnwrap(PixelImage(pngData: XCUIScreen.main.screenshot().pngRepresentation))
            let background = screen[screen.width / 2, screen.height * 9 / 10]
            let brightness = (Int(background.r) + Int(background.g) + Int(background.b)) / 3
            if appearance == "light" {
                XCTAssertGreaterThan(brightness, 180, "the light home background is \(background)")
            } else {
                XCTAssertLessThan(brightness, 60, "the dark home background is \(background)")
            }
            app.terminate()
        }
    }

    /// iPad windows in portrait and landscape: every toolbar item and home panel sits inside the window.
    @MainActor func testHomeFitsIPadPortraitAndLandscape() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPhone runs portrait only") }
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let app = launchHome()
            let window = app.windows.firstMatch.frame
            XCTAssertEqual(window.width > window.height, orientation.isLandscape, "the app didn't launch in \(orientation.rawValue)")

            for id in ["race-online", "practice"] + Self.toolbarPages.map(\.0) {
                let button = app.buttons[id]
                XCTAssertTrue(button.waitForExistence(timeout: 10), "no \(id)")
                XCTAssertTrue(button.isHittable, "\(id) isn't hittable")
                XCTAssertTrue(window.contains(button.frame), "\(id) \(button.frame) is clipped by the window \(window)")
            }
            for id in ["home", "lobby-panel"] {
                let panel = app.descendants(matching: .any)[id].firstMatch
                XCTAssertTrue(panel.exists, "no \(id)")
                XCTAssertTrue(window.contains(panel.frame), "\(id) \(panel.frame) is clipped by the window \(window)")
            }
            attachScreenshot(named: "home-ipad-\(orientation.isLandscape ? "landscape" : "portrait")")
            app.terminate()
        }
    }
}
