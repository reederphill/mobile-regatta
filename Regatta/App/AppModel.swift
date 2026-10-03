import Foundation
import Observation
import RegattaCore
import RegattaServices

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
        #if DEBUG
        /// The debug tuning panel (#232): Debug builds only.
        case tuning
        #endif
    }

    /// Sheets are only for small, brief things (#25).
    enum Sheet: String, Identifiable {
        /// Game Center sign-in.
        case signIn
        /// A lobby player's boat card.
        case boatCard

        var id: Self { self }
    }

    /// What the race sequence shows.
    enum Race {
        /// A practice race, or a render fixture, sailed on the device.
        case practice(GameSession)
        /// An online race, from joining to its close (#68).
        case online(OnlineLaunch)
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
    /// The device's settings (#110): the Settings page's rows, saved to `defaults` as they change.
    var deviceSettings: DeviceSettings {
        didSet {
            guard deviceSettings != oldValue else { return }
            deviceSettings.save(to: defaults)
            haptics.isOn = deviceSettings.haptics
            controls.update(deviceSettings, launchOptions: launchOptions)
            analytics.setSharing(deviceSettings.sharesUsageData)
        }
    }
    /// Every race's haptics, on while Settings' Haptics is (#110): set here once per change, not read per haptic.
    @ObservationIgnored let haptics: GatedHaptics
    /// Every race's steering scheme (#112), camera, auto zoom and pinch multiplier (#113, #322): Settings', or `-scheme`'s and `-camera`'s
    /// over them; set here once per change.
    @ObservationIgnored let controls: ControlSettings
    /// Where `deviceSettings` lives.
    @ObservationIgnored let defaults: UserDefaults
    /// Usage analytics (#128), on while Settings' Share usage data is.
    @ObservationIgnored let analytics: Analytics
    /// The race the cover shows, while `phase` is `.raceSequence`.
    private(set) var race: Race?
    /// The practice race the cover shows, if it's one.
    var session: GameSession? {
        if case .practice(let session) = race { session } else { nil }
    }
    /// Home's notice slot. Nothing posts one yet.
    var notice: Notice?
    /// Home's last-race slot. Filled once results are kept (#24).
    var lastRace: LastRace?

    let launchOptions: LaunchOptions
    #if DEBUG
    /// The debug tuning panel's values (#232): the files the next practice race sails and the look it's drawn
    /// with. Kept on the device, except in UI tests, which sail the bundled files as bundled.
    let tuning: TuningModel
    #endif
    @ObservationIgnored private let sceneState: SceneState

    /// `sceneState` locks the orientation while the race sequence shows (G5).
    init(sceneState: SceneState = SceneState(), launchOptions: LaunchOptions = .current, defaults: UserDefaults = .standard,
         analytics: Analytics = .discarding()) {
        self.sceneState = sceneState
        self.analytics = analytics
        self.launchOptions = launchOptions
        self.defaults = defaults
        let deviceSettings = DeviceSettings(defaults: defaults)
        self.deviceSettings = deviceSettings
        haptics = GatedHaptics(isOn: deviceSettings.haptics)
        controls = ControlSettings(deviceSettings, launchOptions: launchOptions)
        #if DEBUG
        tuning = TuningModel(store: launchOptions.uiTesting ? .inMemory : .standard)
        #endif
        sceneState.isRaceSequenceShowing = false
        controls.savesZoomMultiplier = { [weak self] multiplier in self?.deviceSettings.zoomMultiplier = multiplier }
    }

    /// The rule numbers this device has seen called (#23), kept with hint progress in `defaults`: Reset hints clears it.
    /// UI tests keep it in memory, a race's own, so every run reads the same words.
    var rulesSeen: RuleSeenStore { launchOptions.uiTesting ? RuleSeenStore() : RuleSeenStore(defaults: defaults) }

    /// Settings' Reset hints: every hint shows again, and so do the plain words of every rule call (#25, #23).
    func resetHints() {
        DeviceSettings.resetHints(in: defaults)
    }

    /// Back to the bare home screen: pops every page and dismisses the sheet.
    func dismissAll() {
        path = []
        sheet = nil
    }

    /// Shows `race` in the race sequence, replacing any race there. The one way into a race, whether it's a
    /// practice race, a restart, a launch argument or an online race. The pushed pages stay under the cover, so
    /// quitting a practice race returns to its setup.
    func startRaceSequence(_ race: Race) {
        archiveRace()
        sheet = nil
        self.race = race
        phase = .raceSequence
    }

    /// Shows the practice race `session` in the race sequence.
    func startRaceSequence(_ session: GameSession) {
        startRaceSequence(.practice(session))
    }

    /// A practice race on the current settings.
    func startPractice() {
        startRaceSequence(practiceSession(config: launchOptions.raceConfig(from: settings)))
    }

    /// A practice race on `config`, sailed on the tuning panel's files and drawn with its look in a Debug build
    /// (#232): tuned values apply at the next race start, never during one.
    func practiceSession(config: RaceConfig) -> GameSession {
        #if DEBUG
        var config = config
        config.files = tuning.practiceFiles()
        let session = GameSession(config: config, timescale: launchOptions.timescale, haptics: haptics, controls: controls,
                                  rulesSeen: rulesSeen)
        tuning.attach(session, files: config.files)
        return session
        #else
        return GameSession(config: config, timescale: launchOptions.timescale, haptics: haptics, controls: controls,
                           rulesSeen: rulesSeen)
        #endif
    }

    /// Quits the race sequence back to the menus.
    func endRaceSequence() {
        archiveRace()
        phase = .home
        race = nil
    }

    /// Keeps a practice race sailed on tuned copies, with them beside its log, as it leaves (#232, ADR 0004).
    private func archiveRace() {
        #if DEBUG
        if let session { tuning.archive(session) }
        #endif
    }
}
