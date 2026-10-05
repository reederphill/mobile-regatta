import Foundation
import Observation
import RegattaBots
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
        /// Your last race's results, reopened from home's Last race (#24, #132): large, with Close only.
        case lastRace

        var id: Self { self }
    }

    /// What the race sequence shows.
    enum Race {
        /// A practice race, or a render fixture, sailed on the device.
        case practice(GameSession)
        /// An online race, from joining to its close (#68).
        case online(OnlineLaunch)
        /// The briefing before a race (#130), and the race it leads to: Ready (practice) or the countdown (online)
        /// starts `config`, the same seed and files the briefing showed.
        case briefing(BriefingModel, RaceConfig)
    }

    /// A message at the top of the home screen.
    struct Notice: Equatable {
        var title: String
        var message: String
    }

    private(set) var phase: Phase = .home {
        didSet { sceneState.isRaceSequenceShowing = phase == .raceSequence }
    }
    var path: [Page] = []
    var sheet: Sheet?
    /// The practice setup (#131), kept on the device as it changes: the last choices are the next race's.
    var practiceSetup: PracticeSetup {
        didSet {
            guard practiceSetup != oldValue else { return }
            practiceSetup.save(to: practiceDefaults)
        }
    }
    /// Where `practiceSetup` lives: `defaults`, or in UI tests a suite emptied at each launch, so every test starts
    /// from the defaults.
    @ObservationIgnored let practiceDefaults: UserDefaults
    /// The practice race the race sequence shows or briefs, as set up, before the tuning panel's files: what Restart
    /// replays.
    @ObservationIgnored private(set) var practiceConfig: RaceConfig?
    /// The device's settings (#110): the Settings page's rows, saved to `defaults` as they change.
    var deviceSettings: DeviceSettings {
        didSet {
            guard deviceSettings != oldValue else { return }
            deviceSettings.save(to: defaults)
            haptics.isOn = deviceSettings.haptics
            sound.isOn = deviceSettings.effects
            music.isOn = deviceSettings.music
            controls.update(deviceSettings, launchOptions: launchOptions)
            analytics.setSharing(deviceSettings.sharesUsageData)
        }
    }
    /// Every race's haptics, on while Settings' Haptics is (#110): set here once per change, not read per haptic.
    @ObservationIgnored let haptics: GatedHaptics
    /// Every race's sounds, on while Settings' Effects is (#126): set here once per change, like `haptics`.
    @ObservationIgnored let sound: GatedSound
    /// The menus' music, on while Settings' Music is (#126): `menuMusic` unless a test replaces it.
    @ObservationIgnored let music: GatedMenuMusic
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
    /// The briefing the cover shows, if it's one.
    var briefing: BriefingModel? {
        if case .briefing(let briefing, _) = race { briefing } else { nil }
    }
    /// The menus' music (#126): playing from launch and on returning home, faded out as a briefing starts (#130) or a
    /// race starts without one. `music`, unless a test replaces it.
    @ObservationIgnored var menuMusic: any MenuMusic
    /// Home's notice slot. Nothing posts one yet.
    var notice: Notice?
    /// Your last race's results, home's Last race row (#24, #132): kept as a practice race closes, or as you leave one
    /// you were done in, and replaced only by the next such race. Kept on the device across launches (ruling 6).
    var lastRace: RaceResultViewModel? {
        didSet {
            guard lastRace != oldValue, let lastRace else { return }
            LastRaceStore(defaults: practiceDefaults).save(lastRace)
        }
    }

    /// Your livery (#136, #21): what your boat wears in practice races and briefings, kept on the device as it changes
    /// (`LiveryStore`). #162 sets it from the server's copy on sign-in.
    var myLivery: Livery {
        didSet {
            guard myLivery != oldValue else { return }
            LiveryStore(defaults: myBoatDefaults).save(myLivery)
            if myBoat.saved != myLivery { myBoat.load(myLivery) }
        }
    }
    /// My boat's editor and shop (#136): here, not on the page, so a purchase outlives the page.
    let myBoat: MyBoatModel
    /// After fleet lock (#25): My boat's controls are inert until the race is over. #140 sets it.
    var isLiveryLocked = false {
        didSet { myBoat.isFleetLocked = isLiveryLocked }
    }
    /// Where `myLivery`, the stub's owned designs and the completed races live (`MyBoatDefaults`).
    @ObservationIgnored let myBoatDefaults: UserDefaults

    let launchOptions: LaunchOptions
    #if DEBUG
    /// The debug tuning panel's values (#232): the files the next practice race sails and the look it's drawn
    /// with. Kept on the device, except in UI tests, which sail the bundled files as bundled.
    let tuning: TuningModel
    #endif
    @ObservationIgnored private let sceneState: SceneState

    /// `sceneState` locks the orientation while the race sequence shows (G5).
    /// `store` sells paid designs (#136): the app's stub (`StubStoreService`) unless given.
    /// `audio` plays the sounds and music (#126): silent unless given, so tests never touch the audio engine.
    init(sceneState: SceneState = SceneState(), launchOptions: LaunchOptions = .current, defaults: UserDefaults = .standard,
         store: (any StoreService)? = nil, analytics: Analytics = .discarding(), audio: AppAudio = .silent) {
        self.sceneState = sceneState
        self.analytics = analytics
        self.launchOptions = launchOptions
        self.defaults = defaults
        if launchOptions.uiTesting && launchOptions.resetSettings {
            for key in DeviceSettings.Key.allCases { defaults.removeObject(forKey: key.rawValue) }
        }
        let deviceSettings = DeviceSettings(defaults: defaults)
        self.deviceSettings = deviceSettings
        if launchOptions.uiTesting, let suite = UserDefaults(suiteName: Self.uiTestingPracticeSuite) {
            suite.removePersistentDomain(forName: Self.uiTestingPracticeSuite)
            practiceDefaults = suite
        } else {
            practiceDefaults = defaults
        }
        practiceSetup = PracticeSetup(defaults: practiceDefaults)
        lastRace = LastRaceStore(defaults: practiceDefaults).load()
        let myBoatDefaults = MyBoatDefaults.defaults(for: launchOptions, standard: defaults)
        self.myBoatDefaults = myBoatDefaults
        let boatClass = RaceFiles.defaults.boatClass.ref.id
        let completed = CompletedRacesStore(defaults: myBoatDefaults)
        // UI tests only, and into their own suite: never into the app's defaults, where it would unlock earned designs.
        if launchOptions.uiTesting, let races = launchOptions.completedRaces { completed.count = races }
        // UI tests start from the fixed livery, so every run draws the same boat.
        let myLivery = LiveryStore(defaults: myBoatDefaults)
            .load(boatClass: boatClass, fallback: launchOptions.uiTesting ? FleetLiveries.yours : nil)
        self.myLivery = myLivery
        let store = store ?? StubStoreService(boatClass: boatClass, defaults: .init(myBoatDefaults))
        // What you own as the stub keeps it, now, so a bought design never reads Buy until the stream catches up.
        myBoat = MyBoatModel(saved: myLivery, owned: StubStoreService.owned(in: myBoatDefaults),
                             completedRaces: completed.count, store: store)
        haptics = GatedHaptics(isOn: deviceSettings.haptics)
        sound = GatedSound(output: audio.effects, isOn: deviceSettings.effects)
        let music = GatedMenuMusic(output: audio.music, isOn: deviceSettings.music)
        self.music = music
        menuMusic = music
        controls = ControlSettings(deviceSettings, launchOptions: launchOptions)
        #if DEBUG
        tuning = TuningModel(store: launchOptions.uiTesting ? .inMemory : .standard)
        #endif
        sceneState.isRaceSequenceShowing = false
        controls.savesZoomMultiplier = { [weak self] multiplier in self?.deviceSettings.zoomMultiplier = multiplier }
        myBoat.onSave = { [weak self] livery in self?.myLivery = livery }
        sound.isSceneActive = sceneState.isActive
        sceneState.onPhaseChange = { [weak self] isActive in self?.sceneChanged(isActive: isActive) }
        music.play()
    }

    /// Opens My boat (#136) from home, with `design` tried on if given: results' Try it (#133, #24) and `-myBoat`.
    func openMyBoat(trying design: DesignID? = nil) {
        sheet = nil
        myBoat.open(trying: design)
        path = [.myBoat]
    }

    /// The UI tests' practice setup suite.
    static let uiTestingPracticeSuite = "com.phillreeder.regatta.uitesting.practice"

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
    /// practice race, a restart, a launch argument or an online race. The pushed pages stay under the cover until
    /// the race sequence routes elsewhere (`leaveRace`, `changeSetup`).
    /// A practice or online race fades the menu music; a briefing fades it itself as it begins (#130).
    func startRaceSequence(_ race: Race) {
        archiveRace()
        sound.setAmbience(.silent)
        switch race {
        case .practice, .online: menuMusic.fadeOut()
        case .briefing: break
        }
        sheet = nil
        self.race = race
        phase = .raceSequence
    }

    /// Shows the practice race `session` in the race sequence.
    func startRaceSequence(_ session: GameSession) {
        startRaceSequence(.practice(session))
    }

    /// The pause menu's Restart (#25): the same race again, same seeds and setup, straight to the gun's countdown with
    /// no briefing. The tuning panel's files apply afresh, as at any race start.
    func restartPractice() {
        guard let practiceConfig else { return }
        startRaceSequence(session(tuned: tuned(practiceConfig)))
    }

    /// The results' Sail again: a new race on the practice setup, on a new seed, through its briefing.
    func sailAgain() {
        beginPractice()
    }

    /// The results' Change setup: back to the practice setup page (#25).
    func changeSetup() {
        endRaceSequence()
        path = [.practiceSetup]
    }

    /// The pause menu's Leave race (practice: no warning) and the results' Menu: home (#25).
    func leaveRace() {
        endRaceSequence()
        dismissAll()
    }

    /// A practice race on `config`, sailed on the tuning panel's files and drawn with its look in a Debug build
    /// (#232): tuned values apply at the next race start, never during one.
    /// A launch argument's race (`-autostart`, `-demo`, `-perf`): not from the practice setup, so it never goes into
    /// the practice history (#235).
    func practiceSession(config: RaceConfig) -> GameSession {
        practiceConfig = config
        practiceRecordsHistory = false
        return session(tuned: tuned(config))
    }

    /// `config` on the tuning panel's boat class and rules in a Debug build (#232), at the setup's venue and conditions
    /// unless the panel tuned or picked the conditions (`TuningModel.practiceFiles(over:)`); as it is otherwise.
    func tuned(_ config: RaceConfig) -> RaceConfig {
        #if DEBUG
        var config = config
        config.files = tuning.practiceFiles(over: config.files)
        return config
        #else
        return config
        #endif
    }

    /// A practice race on `config`, whose files are already the tuning panel's (`tuned(_:)`).
    private func session(tuned config: RaceConfig) -> GameSession {
        let session = GameSession(config: config, timescale: launchOptions.timescale, haptics: haptics, sound: sound,
                                  controls: controls, rulesSeen: rulesSeen, livery: myLivery)
        #if DEBUG
        tuning.attach(session, files: config.files)
        #endif
        session.practiceTier = config.botTier
        session.recordsPracticeHistory = practiceRecordsHistory
        session.onResultsFinal = { [weak self, weak session] results in
            self?.keepAsLastRace(results, from: session)
        }
        return session
    }

    /// The practice setup's Start (#25, #130): the briefing for a race on the setup, on a new seed, which waits for
    /// Ready.
    /// Its rivals' skill comes from your practice history (#235): none without one.
    /// Sail again leaves a race you're done in before its close: your finish there counts first, so this race's rivals
    /// know it.
    func beginPractice() {
        if let session, let kept = session.resultsToKeep() { recordPracticeFinish(kept, from: session) }
        let history = PracticeHistoryStore(defaults: practiceDefaults).load()
        startBriefing(config: launchOptions.raceConfig(from: practiceSetup,
                                                        rivalSkill: practiceSetup.rivalSkill(history: history)),
                      mode: .practice, recordsHistory: true)
    }

    /// Shows the briefing for a practice race on `config` (on the tuning panel's files in a Debug build), resolved
    /// once so the briefing and the race it leads to sail the same files. `mode` `.online` is the online briefing's
    /// countdown, which #141 wires to the online race; here it leads to a practice race on `config`.
    /// Only the practice setup's races (`beginPractice`, and Restart of one) go into the practice history (#235), not
    /// `-briefing`'s.
    func startBriefing(config: RaceConfig, mode: BriefingModel.Mode) {
        startBriefing(config: config, mode: mode, recordsHistory: false)
    }

    private func startBriefing(config: RaceConfig, mode: BriefingModel.Mode, recordsHistory: Bool) {
        practiceConfig = config
        practiceRecordsHistory = recordsHistory
        let config = tuned(config)
        startRaceSequence(.briefing(briefingModel(config: config, mode: mode), config))
    }

    /// The briefing for `config`, whose files are already resolved for the race.
    func briefingModel(config: RaceConfig, mode: BriefingModel.Mode) -> BriefingModel {
        let setup = config.setup
        let files: RaceFiles
        do {
            files = try RaceFiles(resolving: setup, from: config.files.catalog)
        } catch {
            preconditionFailure("a practice setup names files it can resolve: \(error)")
        }
        let mySeat = setup.seats.firstIndex(of: .human) ?? 0
        // The briefing's countdown runs at `-timescale` too, so a UI test can sail through it quickly.
        let origin = Date()
        let timescale = launchOptions.timescale
        return BriefingModel(setup: setup, files: files, mySeat: mySeat, mode: mode,
                             liveries: FleetLiveries(setup: setup, mySeat: mySeat, mine: myLivery), menuMusic: menuMusic,
                             rivals: config.rivalSeats,
                             now: { origin.addingTimeInterval(Date().timeIntervalSince(origin) * timescale) })
    }

    /// The briefing's Ready, or its countdown run out: the race it briefed.
    func finishBriefing() {
        guard case .briefing(_, let config) = race else { return }
        startRaceSequence(session(tuned: config))
    }

    /// The scene's phase changed (#126): the ambience is silent while the scene isn't active, online races included,
    /// and the music plays on again as it's active, if the system stopped it meanwhile.
    func sceneChanged(isActive: Bool) {
        sound.isSceneActive = isActive
        if isActive { music.resume() }
    }

    /// Quits the race sequence back to the menus, where the music fades back in (#126).
    func endRaceSequence() {
        archiveRace()
        sound.setAmbience(.silent)
        phase = .home
        race = nil
        menuMusic.play()
    }

    /// Home's Last race takes `results` unless you retired from that race (#132): a RET leaves the one before. Your
    /// finish in `session` goes into the practice history the rivals' skill is set from (#235), once per race.
    private func keepAsLastRace(_ results: RaceResultViewModel, from session: GameSession?) {
        if results.keepsAsLastRace { lastRace = results }
        recordPracticeFinish(results, from: session)
    }

    /// The race whose finish the practice history last took (#235): a race closes (`onResultsFinal`) and is left
    /// (`archiveRace`), and counts once.
    @ObservationIgnored private weak var recordedSession: GameSession?

    /// `practiceConfig` came from the practice setup, so its races go into the practice history (#235); a launch
    /// argument's race doesn't.
    @ObservationIgnored private var practiceRecordsHistory = false

    /// Adds your finish in `session`'s race to the practice history (#235, `RaceResultViewModel.practiceFinish`), at
    /// that race's tier, once per race.
    private func recordPracticeFinish(_ results: RaceResultViewModel, from session: GameSession?) {
        guard let session, session.recordsPracticeHistory, session !== recordedSession,
              let finish = results.practiceFinish(tier: session.practiceTier) else { return }
        recordedSession = session
        let store = PracticeHistoryStore(defaults: practiceDefaults)
        store.save(Rivals.recording(finish, in: store.load()))
    }

    /// Keeps a practice race sailed on tuned copies, with them beside its log, as it leaves (#232, ADR 0004); and its
    /// results for home's Last race if you were done in it (#132).
    private func archiveRace() {
        if let session, let kept = session.resultsToKeep() { keepAsLastRace(kept, from: session) }
        #if DEBUG
        if let session { tuning.archive(session) }
        #endif
    }
}

/// Home's Last race (#24, #132): the last race's results as JSON in the practice defaults, so UI tests, which empty
/// those at launch, start with none.
struct LastRaceStore {
    let defaults: UserDefaults
    static let key = "lastRace"

    func load() -> RaceResultViewModel? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(RaceResultViewModel.self, from: data)
    }

    func save(_ results: RaceResultViewModel) {
        guard let data = try? JSONEncoder().encode(results) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// Your practice history (#235): your recent practice finishes, oldest first (`Rivals.kept` of them), as JSON in the
/// practice defaults, so UI tests, which empty those at launch, start with none and race without rivals.
struct PracticeHistoryStore {
    let defaults: UserDefaults
    static let key = "practiceHistory"

    func load() -> [PracticeFinish] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([PracticeFinish].self, from: data)) ?? []
    }

    func save(_ history: [PracticeFinish]) {
        guard let data = try? JSONEncoder().encode(history) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
