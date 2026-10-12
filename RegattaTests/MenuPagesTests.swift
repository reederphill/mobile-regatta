import RegattaProtocol
import RegattaServices
import SwiftUI
import Testing
import UIKit
@testable import Regatta

/// The home screen's pushed pages and the menu colours they draw with.
@MainActor @Suite struct MenuPagesTests {
    /// UIKit resolves a dynamic colour on whatever thread asks for it. A main-actor trait closure traps there
    /// (`dispatch_assert_queue`, Swift 6's isolation check) and takes the app down.
    @Test func menuColoursResolveOffTheMainThread() async {
        let colours: [(UIColor, light: UInt32, dark: UInt32)] = [
            (UIColor(ChromePalette.background), 0xDCEBF5, 0x0B1F33),
            (UIColor(ChromePalette.text), 0x0E2A47, 0xE8F1F8),
            (UIColor(ChromePalette.tint), 0x1B4F82, 0x7FB3E0),
            (UIColor(ChromePalette.surface), 0xFFFFFF, 0x13304D),
            (UIColor(ChromePalette.errorText), 0xC8102E, 0xFF7A7A),
        ]
        for (colour, light, dark) in colours {
            let resolved = await Task.detached {
                (Self.rgb(colour.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))),
                 Self.rgb(colour.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))))
            }.value
            #expect(resolved.0 == light)
            #expect(resolved.1 == dark)
        }
    }

    /// A race she dropped out of still runs (#141): Rejoin race stands in Race online's place, queued or not, with
    /// the race clock counted on from the service's reading.
    @Test func rejoinEntryReplacesRaceOnline() {
        let read = Date(timeIntervalSinceReferenceDate: 5000)
        let entry = OnlineRaceController.RejoinEntry(tick: 761 * 30, readAt: read)
        #expect(HomeView.raceSlot(rejoin: nil, entry: .ready) == .raceOnline)
        #expect(HomeView.raceSlot(rejoin: nil, entry: .settling) == .raceOnline, "off, but there")
        #expect(HomeView.raceSlot(rejoin: nil, entry: .queued) == .none, "the bar is Race online's place")
        #expect(HomeView.raceSlot(rejoin: nil, entry: nil) == .raceOnline)
        for queue in [RaceOnlineEntry.ready, .settling, .queued, nil] {
            #expect(HomeView.raceSlot(rejoin: entry, entry: queue) == .rejoin(entry))
        }
        #expect(entry.clock(at: read) == "12:41")
        #expect(entry.clock(at: read.addingTimeInterval(20)) == "13:01")
        #expect(entry.spoken(at: read) == "Rejoin race, 12 minutes 41 seconds into the race")
        #expect(HomeFixture.rejoin.rejoin?.clock(at: RenderFixture.QueueFixture.moment) == "12:41")
    }

    /// Home's Last race badge is the rating change alone (#141), with its sign; pending, unrated and practice
    /// races show none.
    @Test func lastRaceRowShowsTheRatingChangeOnly() throws {
        let last = try #require(FakeServiceScenario.onlineRace(rated: true).lastRace)
        let rated = RaceResultViewModel(lastRace: last, livery: FleetLiveries.yours)
        #expect(rated.summary == "3 of 6")
        #expect(rated.ratingBadge?.text == "+12" && rated.ratingBadge?.spoken == "Rating plus 12")
        #expect(HomeFixture.lastRaceRating.lastRace == rated)

        let pending = RaceResultViewModel(lastRace: LastRace(report: last.report, rating: nil), livery: FleetLiveries.yours)
        #expect(pending.ratingBadge == nil, "a pending rating shows a badge")

        let lost = RatingChange(raceID: last.report.raceID,
                                outcome: .rated(before: Rating(value: 1500, isProvisional: false),
                                                after: Rating(value: 1492, isProvisional: false)))
        let down = RaceResultViewModel(lastRace: LastRace(report: last.report, rating: lost), livery: FleetLiveries.yours)
        #expect(down.ratingBadge?.text == "\u{2212}8" && down.ratingBadge?.spoken == "Rating minus 8")

        let unrated = try #require(FakeServiceScenario.onlineRace(rated: false).lastRace)
        #expect(RaceResultViewModel(lastRace: unrated, livery: FleetLiveries.yours).ratingBadge == nil)
    }

    /// The online race menu (#141): "Race continues", with Resume, the practice menu's toggles, Help and Leave race,
    /// and never Restart or Tuning, whatever its race offers.
    @Test func onlineStyleHasNoRestartOrTuning() {
        #expect(PauseMenu.rows(style: .online, hasToggles: true, hasHelp: true, canRestart: true, canTune: true)
            == [.resume, .toggles, .help, .leave])
        #expect(PauseMenu.rows(style: .practice, hasToggles: true, hasHelp: true, canRestart: true, canTune: true)
            == [.resume, .toggles, .help, .restart, .tuning, .leave])
        #expect(PauseMenu.rows(style: .practice, hasToggles: false, hasHelp: false, canRestart: false, canTune: false)
            == [.resume, .leave])
        #expect(PauseMenu.title(.online) == "Race continues" && PauseMenu.title(.practice) == "Paused")
        #expect(LeaveConfirm.consequence(isBeforeGun: true) == "A bot takes your seat.")
        #expect(LeaveConfirm.consequence(isBeforeGun: false) == "You'll be scored as retired.")
    }

    /// Pushing Practice shows its setup (the fleet stepper and the bot tier's segmented picker), and the main thread
    /// settles, after the push, after the setup changes and after popping back.
    @Test func practiceSetupPushesAndSettles() throws {
        let (window, model) = try host()
        defer { window.isHidden = true }

        model.path.append(.practiceSetup)
        #expect(settle(window), "the main thread didn't settle after pushing practice setup")
        #expect(subviews(of: UIStepper.self, in: window).count == 1, "no fleet stepper")
        #expect(subviews(of: UISegmentedControl.self, in: window).count == 1, "no bot tier picker")

        model.practiceSetup.fleetSize = 16
        model.practiceSetup.botTier = .national
        model.practiceSetup.venue = "fellmere"
        model.practiceSetup.conditions = .named("light-and-patchy")
        defer { model.practiceSetup = PracticeSetup() } // the test host's device keeps it
        #expect(settle(window), "the main thread didn't settle after changing the setup")

        model.path.removeAll()
        #expect(settle(window), "the main thread didn't settle after popping practice setup")
        #expect(subviews(of: UIStepper.self, in: window).isEmpty)
    }

    /// The app's root controller in a new window on the app's scene, settled on the home screen.
    private func host() throws -> (UIWindow, AppModel) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let controller = RootHostingController(sceneState: SceneState(), screenSize: CGSize(width: 402, height: 874))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        #expect(settle(window), "the home screen didn't settle")
        return (window, controller.rootView.model)
    }

    /// Lays the window out and spins the main run loop for about a second, past a push's animation. False if a
    /// spin took far longer than it should, as it does when a view update loops.
    private func settle(_ window: UIWindow) -> Bool {
        for _ in 0..<20 {
            let start = Date()
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            if Date().timeIntervalSince(start) > 2 { return false }
        }
        return true
    }

    private func subviews<V: UIView>(of type: V.Type, in view: UIView) -> [V] {
        view.subviews.flatMap { ($0 as? V).map { [$0] } ?? [] + subviews(of: type, in: $0) }
    }

    private nonisolated static func rgb(_ colour: UIColor) -> UInt32 {
        var (red, green, blue, alpha) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
        colour.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let byte = { (value: CGFloat) in UInt32((value * 255).rounded()) }
        return byte(red) << 16 | byte(green) << 8 | byte(blue)
    }
}
