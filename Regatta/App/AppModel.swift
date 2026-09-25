import Observation
import RegattaCore

/// The app's navigation state (#25): one home screen, pages pushed on it, brief sheets over it, and the race
/// sequence as a full-screen cover. There's no tab bar.
@Observable
final class AppModel {
    enum Phase: Equatable {
        /// The first-launch splash card and first race, before the home screen. Nothing enters it yet.
        case firstLaunch
        case home
        /// Briefing, race and results, in the full-screen cover.
        case raceSequence
    }

    /// Pages pushed on the home screen.
    enum Page: Hashable {
        case practiceSetup, myBoat, profile, help, settings
    }

    /// Sheets are only for small, brief things (#25).
    enum Sheet: String, Identifiable {
        /// Game Center sign-in.
        case signIn
        /// A lobby player's boat card.
        case boatCard

        var id: Self { self }
    }

    /// A message at the top of the home screen.
    struct Notice: Equatable {
        var title: String
        var message: String
    }

    /// The home screen's last-race entry (#24).
    struct LastRace: Equatable {
        var place: Int
        var fleetSize: Int
    }

    private(set) var phase: Phase = .home {
        didSet { sceneState.isRaceSequenceShowing = phase == .raceSequence }
    }
    var path: [Page] = []
    var sheet: Sheet?
    /// The practice race setup, kept between races.
    var settings = RaceSettings()
    /// The race the cover shows, while `phase` is `.raceSequence`.
    private(set) var session: GameSession?
    /// Home's notice slot. Nothing posts one yet.
    var notice: Notice?
    /// Home's last-race slot. Filled once results are kept (#24).
    var lastRace: LastRace?

    let launchOptions: LaunchOptions
    @ObservationIgnored private let sceneState: SceneState

    /// `sceneState` locks the orientation while the race sequence shows (G5).
    init(sceneState: SceneState = SceneState(), launchOptions: LaunchOptions = .current) {
        self.sceneState = sceneState
        self.launchOptions = launchOptions
        sceneState.isRaceSequenceShowing = false
    }

    /// Back to the bare home screen: pops every page and dismisses the sheet.
    func dismissAll() {
        path = []
        sheet = nil
    }

    /// Shows `session` in the race sequence, replacing any race there. The one way into a race, whether it's a
    /// practice race, a restart, a launch argument or (later) an online race. The pushed pages stay under the
    /// cover, so quitting a practice race returns to its setup.
    func startRaceSequence(_ session: GameSession) {
        sheet = nil
        self.session = session
        phase = .raceSequence
    }

    /// A practice race on the current settings.
    func startPractice() {
        startRaceSequence(GameSession(config: launchOptions.raceConfig(from: settings), timescale: launchOptions.timescale))
    }

    /// Quits the race sequence back to the menus.
    func endRaceSequence() {
        phase = .home
        session = nil
    }
}
