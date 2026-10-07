import Foundation
import Observation
import RegattaBots
import RegattaCore
import RegattaServices
import UIKit

/// Hosts one race's driver and bridges it to SwiftUI: HUD snapshots, the notice slot (#114),
/// haptics and results. It never holds a `Race`: a practice race is a `PracticeDriver`, an online one
/// an `OnlineDriver`.
///
/// Notices come only from the events the driver drains. Online those are the server's alone (#18, #68):
/// the prediction's own rule calls, OCS, penalties and finishes never reach here, so none is shown
/// before the server calls it.
@Observable
final class GameSession {
    let driver: any RaceDriver
    let scene: GameScene
    /// Names and bot marks, kept outside the simulation (#60).
    let roster: FleetRoster
    /// The colour-vision filter `RaceView` draws the race through: scene, HUD and letterbox under one matrix
    /// (#22, #111). `-vision`'s in Debug builds, or a render fixture's. Never the scene's own `SKScene.filter`:
    /// SpriteKit filters a scene over its frame, which a scaled or moved camera doesn't follow, so the view's
    /// right and bottom edges went unfiltered.
    var vision: VisionFilter

    /// The race sails tuned copies of its files, or is drawn with tuned render values: the TUNED badge (#232,
    /// Debug builds).
    var isTuned = false

    var hud = HUDState()
    /// The one notice line under the top readouts (#114), what `noticeSlot` shows now.
    private(set) var notice: Notice?
    /// The results (#132): built once you're done (`playerDone`), and rebuilt as the race ticks on behind them.
    private(set) var results: RaceResultViewModel?
    /// The results sheet is up (#24): `resultsDelay` after your own finish, at once on your DSQ or the race's close.
    private(set) var showsResults = false
    /// How long after your finish horn the results slide up, in wall-clock seconds (#24: "About 3 s").
    static let resultsDelay: TimeInterval = 3
    var isPaused = false
    /// You're done racing: finished, disqualified, or the race closed.
    var playerDone = false
    /// The race's results, from its `raceClosed` (#86); nil until then, and online, where the close has none yet.
    @ObservationIgnored private var closedResults: RaceResults?
    /// Each seat's completed penalty turns (`penaltyServed`): the Your race card's outcomes (#132).
    @ObservationIgnored private var servedTurns: [Int: Int] = [:]
    /// When your finish horn sounded, wall-clock, until the results show.
    @ObservationIgnored private var finishedAt: Date?
    /// The tick `results` was built at, so they're rebuilt once a tick, not every display frame.
    @ObservationIgnored private var resultsTick: Int?
    /// Told once with the final results as the race closes (#132): the home screen's Last race.
    @ObservationIgnored var onResultsFinal: ((RaceResultViewModel) -> Void)?
    /// The practice race's bot tier, nil a Mixed fleet: what your finish counts at in the practice history (#235).
    @ObservationIgnored var practiceTier: BotTier?
    /// A race from the practice setup (#235): your finish goes into the practice history. A launch argument's or an
    /// online race doesn't.
    @ObservationIgnored var recordsPracticeHistory = false
    /// The Ease button is held (#99, #112): the scene sends it with the rudder every frame.
    var isEasing = false
    /// The tiller's track and knob while a tiller drag is held (#112): the scene sets it, `RaceView` draws it.
    var tillerKnob: SteeringInterpreter.TillerKnob?
    /// This is the player's first race: the halves edge labels show (#23), and the results offer Race online and Help
    /// (#24). #134 sets it; nothing does yet.
    var isFirstRace = false

    /// Which buttons the results show (#24).
    enum ResultsButtons: Equatable {
        /// Home, Change setup and Sail again.
        case practice
        /// Race online (primary) and Help.
        case firstRace
        /// An online race with the server's results (#133): Race again (primary, re-queues) and Home.
        case online
    }

    /// An online race's results from the server's stream (#133), nil for practice and for a Debug dev-instant race,
    /// which has no hand-off and keeps the live frame's standings and its own loop.
    var onlineResults: OnlineResults? {
        didSet {
            onlineResults?.onChange = { [weak self] in
                guard let self else { return }
                resultsTick = nil
                refreshResults()
            }
        }
    }

    var resultsButtons: ResultsButtons {
        onlineResults != nil ? .online : Self.resultsButtons(isFirstRace: isFirstRace)
    }

    static func resultsButtons(isFirstRace: Bool) -> ResultsButtons { isFirstRace ? .firstRace : .practice }
    /// The device's steering scheme, live (#112, #131).
    let controls: ControlSettings

    /// The live leaderboard shows the whole fleet (#268): a tap opens it, and it closes on the next tap or after
    /// `leaderboardOpenSeconds` of wall-clock time.
    private(set) var isLeaderboardExpanded = false
    @ObservationIgnored private var leaderboardOpenedAt: Date?
    static let leaderboardOpenSeconds: TimeInterval = 5

    @ObservationIgnored private var noticeSlot = NoticeSlot()
    /// The rule calls whose dashed lines the scene draws (#123): every call drained, yours or not, or a frozen
    /// fixture's replayed ones. The scene holds them.
    var ruleCalls: RuleCallLines { scene.ruleCalls }
    /// The rule cues and Turn notice show (#123): always in a race, only where a render fixture asks.
    @ObservationIgnored private var showsRuleCues = true
    /// The minimap's pressure, sampled every couple of seconds rather than every refresh (#289, #114).
    @ObservationIgnored private let minimapField = MinimapField()
    /// The clock notices are timed by: wall-clock time, so a notice reads for its seconds at any timescale.
    @ObservationIgnored var now: () -> Date = { .now }
    /// Driver events into notices and cues (#124).
    @ObservationIgnored private var presenter: RaceEventPresenter
    /// The race's hints (#129); nil shows none (tests and render fixtures).
    @ObservationIgnored private let hints: HintEngine?
    /// The hints' thresholds (#129): the debug tuning panel's, live.
    var hintTuning: HintTuning {
        get { hints?.thresholds ?? .standard }
        set { hints?.thresholds = newValue }
    }
    /// Told once per hint as it retires, with how (#128's `hint_retired`): `AppModel` logs it.
    @ObservationIgnored var onHintRetired: ((String, HintRetirement) -> Void)?
    /// Every cue the presenter plays, after its haptic and sound: for tests.
    @ObservationIgnored var onCue: ((RaceCue) -> Void)?
    /// The race's sounds (#126): the committee's sequence, your boat's moments and the ambience, gated by Settings'
    /// Effects (`AppModel.sound`).
    @ObservationIgnored private var sound: RaceSound
    /// The plain words posted and not yet shown or dropped, by notice id: what each teaches (`settleMarks`).
    @ObservationIgnored private var pendingMarks: [Int: [SeenMark]] = [:]
    @ObservationIgnored private var toldUpdateRequired = false
    /// Every haptic goes through here, so Settings' Haptics off silences them all (#110).
    @ObservationIgnored private let haptics: any Haptics
    /// The Tack/Gybe button's hold and release (#222).
    @ObservationIgnored private var tackHold = TackHold()

    /// A practice race on the device, your boat in `livery` (#136). `timescale` runs the simulation that many times real
    /// time (`-timescale`, for tests).
    convenience init(config: RaceConfig, timescale: Double = 1, haptics: any Haptics = SilentHaptics(),
                     sound: any SoundOutput = SilentSoundOutput(), controls: ControlSettings = ControlSettings(),
                     rulesSeen: RuleSeenStore = RuleSeenStore(), livery: Livery = FleetLiveries.yours,
                     hints: HintEngine? = nil) {
        let driver = PracticeDriver(config: config, timescale: timescale, livery: livery)
        self.init(driver: driver, roster: driver.roster, haptics: haptics, sound: sound, controls: controls,
                  rulesSeen: rulesSeen, hints: hints)
    }

    /// An online race (#68).
    convenience init(online driver: OnlineDriver, haptics: any Haptics = SilentHaptics(),
                     sound: any SoundOutput = SilentSoundOutput(), controls: ControlSettings = ControlSettings(),
                     rulesSeen: RuleSeenStore = RuleSeenStore(), hints: HintEngine? = nil) {
        self.init(driver: driver, roster: driver.roster, haptics: haptics, sound: sound, controls: controls,
                  rulesSeen: rulesSeen, hints: hints)
    }

    /// A render fixture (#62): `log` replayed to the fixture's freeze tick and frozen there, drawn from
    /// its camera through its vision filter, with its laylines and ladder lines (#122) or the app's defaults.
    convenience init(fixture: RenderFixture, log: RaceLog) throws {
        let driver = try FixtureDriver(log: log, freezeTick: fixture.freezeTick, seat: fixture.hud?.seat)
        self.init(driver: driver, roster: driver.roster)
        // It drains no events: its rule-call lines are the replay's calls. Off unless the fixture asks (#123).
        for call in driver.ruleCalls { scene.ruleCalls.add(call) }
        showsRuleCues = fixture.ruleCues ?? false
        scene.showsRuleCues = showsRuleCues
        if !showsRuleCues {
            noticeSlot.setLive(.penalty, text: nil, at: now())
            notice = noticeSlot.current(at: now())
        }
        scene.cameraOverride = fixture.cameraMode
        let defaults = DeviceSettings()
        scene.cueOverride = (laylines: fixture.laylines ?? defaults.laylines,
                             ladderLines: fixture.ladderLines ?? defaults.ladderLines)
        vision = fixture.vision
        showsHUDInFixture = fixture.hud != nil
        // The board only where the fixture asks for it (#268), held open if it says so: the session's controls are
        // its own here, never the app's.
        controls.showsLeaderboard = fixture.hud?.leaderboard != nil
        isLeaderboardExpanded = fixture.hud?.leaderboard == .expanded
        if let kind = fixture.hud?.notice {
            // A notice the replay can't make (it drains no events): shown for good, so the render holds still.
            noticeSlot.show(Notice(id: 0, kind: kind, text: Self.fixtureNoticeText(kind), posted: .distantPast,
                                   expires: .distantFuture))
            notice = noticeSlot.current(at: now())
        }
        if let id = fixture.hud?.hint {
            // A hint and its leader line (#129), shown for good: the fixture runs no hint engine.
            let hint = HintCatalogue.hint(id)
            noticeSlot.show(Notice(id: 0, kind: .hint, text: hint.text.text(for: controls.steering), posted: .distantPast,
                                   expires: .distantFuture, leader: HintLeader.fixtureTarget(id, world: driver.renderWorld)))
            notice = noticeSlot.current(at: now())
        }
    }

    // TODO-COPY (#171): `RaceEventPresenter` writes the real notices; a fixture's is a placeholder of a real length.
    static func fixtureNoticeText(_ kind: NoticeKind) -> String {
        "TODO-COPY \(kind.rawValue): room at the mark for the inside boat"
    }

    /// `rulesSeen`: which rule numbers this device has seen called, for plain words (#23). In memory by default, so
    /// tests and fixtures never write the device's; the app passes one over its defaults. `hints`: the race's hint
    /// engine (#129), nil for none, as tests and fixtures have; the app passes one over the device's progress.
    init(driver: any RaceDriver, roster: FleetRoster, haptics: any Haptics = SilentHaptics(),
         sound: any SoundOutput = SilentSoundOutput(), controls: ControlSettings = ControlSettings(),
         rulesSeen: RuleSeenStore = RuleSeenStore(), hints: HintEngine? = nil) {
        self.driver = driver
        self.hints = hints
        self.roster = roster
        self.haptics = haptics
        self.sound = RaceSound(output: sound)
        self.controls = controls
        let me = driver.myBoatIndex
        presenter = RaceEventPresenter(me: me, seen: rulesSeen) { roster.label(of: $0, playerSeat: me) }
        // `-vision` (Debug); a fixture sets its own after this.
        vision = LaunchOptions.current.raceVision
        scene = GameScene(driver: driver, roster: roster)
        scene.session = self
        hints?.onRetired = { [weak self] id, mode in self?.onHintRetired?(id.rawValue, mode) }
        // `-hideScene` (#361): a live race only; a render fixture always paints.
        scene.paintsWorld = driver.isFrozen || !LaunchOptions.current.hidesScene
        // `-cuesOnly` (#127): a UI test's cue-only render.
        scene.drawsCuesOnly = LaunchOptions.current.drawsCuesOnly
        // The minimap's first pressure sample (up to ~170 ms on first use, #310) waits for the scene's first HUD
        // refresh, off the race's construction; a frozen fixture takes it here, as its render holds still.
        // The first refresh posts the steering hint at once (#129); a frozen fixture shows only the notice it names.
        refreshHUD(samplesPressure: driver.isFrozen)
    }

    /// A render fixture that draws the HUD over its scene (#114).
    var showsFixtureHUD: Bool { driver.isFrozen && showsHUDInFixture }
    @ObservationIgnored private var showsHUDInFixture = false

    /// The halves' faint "‹ Port / Starboard ›" edge labels show in the first race only, and only in halves (#23).
    var showsEdgeLabels: Bool { Self.showsEdgeLabels(isFirstRace: isFirstRace, steering: controls.steering) }

    static func showsEdgeLabels(isFirstRace: Bool, steering: DeviceSettings.Steering) -> Bool {
        isFirstRace && steering == .halves
    }

    /// One tack/gybe tap. With `-demo` a bot sails your seat, and the driver refuses it. No haptic (#112).
    @discardableResult func tackOrGybe() -> Bool {
        driver.tap(.tackGybe)
    }

    /// The Tack/Gybe button goes down at wall-clock `time`: the tap that starts the tack or gybe, unless the boat is
    /// already in one (#222).
    func pressTack(at time: Double) {
        guard tackHold.press(at: time, inManoeuvre: TackHold.isInManoeuvre(myBoat)) else { return }
        if !tackOrGybe() { tackHold.pressRefused() }
    }

    /// The Tack/Gybe button comes up at wall-clock `time`: after a hold, the roll, if the boat is still in the tack
    /// the press began. The sim times it against the boom crossing (#263).
    func releaseTack(at time: Double) {
        guard tackHold.release(at: time, inTack: TackHold.isInTack(myBoat)) else { return }
        tackOrGybe()
    }

    /// The Ease button is held or let go (#99).
    func setEase(_ easing: Bool) {
        if isEasing && !easing {
            easeReleases.count += 1
            easeReleases.knots = knots(metresPerSecond: myBoat.speed)
        }
        isEasing = easing
    }

    /// VoiceOver's Ease (#112): an accessibility action can't hold, so the first activation holds Ease and the
    /// second lets it go.
    func toggleEase() {
        setEase(!isEasing)
    }

    /// How many times Ease has been let go, and your boat's speed in knots the moment it last was: UI tests read it
    /// (`race-ease-release`), since a test's press returns only after the release, with the boat already speeding up.
    @ObservationIgnored private(set) var easeReleases = (count: 0, knots: 0.0)

    private var myBoat: Boat { driver.currentFrame.boats[driver.myBoatIndex] }

    /// Pauses a race that can pause; one that can't (online) keeps running. Either way the overlay takes the
    /// touches: steering and Ease let go.
    func setPaused(_ paused: Bool) {
        isPaused = paused && driver.isPausable
        releaseControls()
        // The ambience stops with the race and ramps back in as it resumes (`refreshHUD`).
        if isPaused { sound.silence() }
    }

    /// Lets go of steering and Ease, and tells the held buttons (`controlReleases`): an overlay is taking the touches,
    /// the pause menu or Help (#135), which an online race keeps running under with the rudder centred.
    func releaseControls() {
        isEasing = false
        scene.resetInput()
        controlReleases += 1
    }

    /// How many times the controls have been let go (`releaseControls`): Ease and Tack/Gybe let go on each.
    private(set) var controlReleases = 0

    /// The app went to the background (`SceneState.phase`, #25): a practice race pauses, so the pause menu is up on
    /// return. Not a finished race or a render fixture; an online race keeps running (#141).
    func pauseForBackground() {
        guard driver.isPausable, !driver.isFrozen, !playerDone, !isPaused else { return }
        setPaused(true)
    }

    func refreshHUD() { refreshHUD(samplesPressure: true) }

    /// The scene steps the live race for the first time (`GameScene.update`): the notice slot's clock starts again
    /// from here (#129). The steering hint is posted as the race is set up, before its clock shows, and setting up
    /// and presenting the scene can take seconds; its time on screen starts once the race does. Once a session.
    func sceneStarted() {
        guard !hasSceneStarted else { return }
        hasSceneStarted = true
        noticeSlot.restartClock(at: now())
    }
    @ObservationIgnored private var hasSceneStarted = false

    /// A tap on the place or the live leaderboard (#268): opens it to the whole fleet, or closes it.
    func toggleLeaderboard() {
        isLeaderboardExpanded.toggle()
        leaderboardOpenedAt = isLeaderboardExpanded ? now() : nil
    }

    /// Closes the open leaderboard once it has been open its seconds; a frozen fixture's stays open.
    private func closeLeaderboardIfDue() {
        guard isLeaderboardExpanded, !driver.isFrozen, let opened = leaderboardOpenedAt,
              now().timeIntervalSince(opened) >= Self.leaderboardOpenSeconds else { return }
        isLeaderboardExpanded = false
        leaderboardOpenedAt = nil
    }

    private func refreshHUD(samplesPressure: Bool) {
        let world = driver.renderWorld
        let roster = roster
        var hud = HUDState(world: world) { roster[$0].isBot }
        hud.pressureImage = samplesPressure ? minimapField.refresh(world) : minimapField.image
        self.hud = hud
        if !driver.isFrozen {
            // The ambience follows what the HUD shows: the ground wind before shadow, your speed, your eased sail.
            // It fades once you're done.
            let me = driver.myBoatIndex
            let input = AmbienceInput(windKnots: hud.windKnots, boatKnots: knots(metresPerSecond: myBoat.speed),
                                      isEasing: world.ease(ofSeat: me))
            sound.stepAmbience(playerDone ? nil : input, at: now())
        }
        // Your owed penalty turn's countdown (#123), live in the slot while you owe one.
        let penalty = showsRuleCues ? PenaltyReadout(frame: driver.currentFrame, seat: driver.myBoatIndex) : nil
        noticeSlot.setLive(.penalty, text: penalty?.noticeText, at: now())
        let current = noticeSlot.current(at: now())
        settleMarks()
        if current != notice { notice = current }
        refreshHints(world)
        closeLeaderboardIfDue()
        refreshResults()
        // The RTT warning (#18, #68): once as it starts.
        if let lag = presenter.lag(isWarning: driver.lagWarning) { post(lag.kind, lag.text) }
        if let online = driver as? OnlineDriver, case .updateRequired = online.connection, !toldUpdateRequired {
            toldUpdateRequired = true
            post(.latency, "Update Regatta to race online. This race can't reconnect.")
        }
    }

    /// Settles the hint showing and posts the next one due (#129), on the driver's frame. Not in a frozen fixture.
    private func refreshHints(_ world: RenderWorld) {
        guard let hints, !driver.isFrozen else { return }
        let next = hints.refresh(world: world, slot: noticeSlot, now: now(), hintsOn: controls.showsHints,
                                 showsLaylines: controls.showsLaylines, isFirstRace: isFirstRace)
        // The first race's steering hint, held until you steer (owner ruling 2026-10-05).
        if let held = hints.takeDownDue() {
            noticeSlot.takeDown(held, at: now())
            let current = noticeSlot.current(at: now())
            if current != notice { notice = current }
        }
        guard let next else { return }
        let id = noticeSlot.nextID
        post(.hint, next.hint.text.text(for: controls.steering), leader: next.leader, held: next.held)
        hints.posted(next.hint.id, noticeID: id, held: next.held)
    }

    func consume(_ events: [RaceEvent]) {
        // Every call draws its line (#123), bystanders' too; what you read and feel is the presenter's (#124).
        for event in events {
            if case .ruleCall(let call) = event.kind { scene.ruleCalls.add(call) }
        }
        let presentation = presenter.present(events, autohelmHolding: myBoat.autohelm != nil)
        for notice in presentation.notices { post(notice.kind, notice.text, marks: notice.marks) }
        var cues = presentation.cues
        if let tick = presenter.sequenceCue(raceTime: driver.currentFrame.time) { cues.append(tick) }
        // One haptic a batch, the strongest: a contact and its call arrive on the same tick.
        HapticPattern.strongest(of: cues)?.play(on: haptics)
        // The committee's sequence on the race clock, and your boat's moments (#126).
        sound.play(cues: cues, raceTime: driver.currentFrame.time)
        if let onCue { cues.forEach(onCue) }
        let me = driver.myBoatIndex
        hints?.consume(events, me: me, hintsOn: controls.showsHints)
        for event in events {
            switch event.kind {
            case .penaltyServed(let seat):
                servedTurns[seat, default: 0] += 1
            case .finished(me, _):
                finishForPlayer(showsAt: now().addingTimeInterval(Self.resultsDelay))
            case .disqualified(me, _):
                finishForPlayer(showsAt: nil)
            case .raceClosed(let results):
                if !results.rows.isEmpty { closedResults = results }
                finishForPlayer(showsAt: nil)
                resultsTick = nil
                refreshResults()
                if let final = self.results, final.isFinal { onResultsFinal?(final) }
            default:
                break
            }
        }
    }

    /// You're done: the results build now and show at `showsAt`, or at once when nil. A later call can only bring
    /// the sheet forward (the close after your finish).
    private func finishForPlayer(showsAt: Date?) {
        if !playerDone {
            playerDone = true
            isEasing = false
            finishedAt = showsAt
        }
        if showsAt == nil { finishedAt = nil; showsResults = true }
        refreshResults()
    }

    /// Rebuilds the results once a tick while you're done, and slides them up once their delay has passed.
    private func refreshResults() {
        if onlineResults?.isCancelled == true {
            // A cancelled race has no results: the sheet goes (#24; Home's notice is #141's).
            results = nil
            showsResults = false
            finishedAt = nil
            return
        }
        guard playerDone else { return }
        if resultsTick != driver.currentFrame.tick || results == nil {
            results = makeResults()
            resultsTick = driver.currentFrame.tick
        }
        if !showsResults, let finishedAt, now() >= finishedAt {
            showsResults = true
            self.finishedAt = nil
        }
    }

    /// The results to keep for the home screen's Last race as you leave the race (#132): nil when you weren't done
    /// (left mid-race) or it's a render fixture. Before the close, a snapshot with boats still sailing placed by
    /// distance (ruling 4).
    func resultsToKeep() -> RaceResultViewModel? {
        guard playerDone, !driver.isFrozen else { return nil }
        return makeResults().leftBeforeClose()
    }

    private func post(_ kind: NoticeKind, _ text: String, marks: [SeenMark] = [], leader: HintTarget? = nil,
                      held: Bool = false) {
        if !marks.isEmpty { pendingMarks[noticeSlot.nextID] = marks }
        notice = noticeSlot.post(kind, text, at: now(), leader: leader, held: held)
        settleMarks()
    }

    /// Plain words are seen once their notice shows, and stay unseen if the slot drops it stale (#23, #114).
    private func settleMarks() {
        for (id, marks) in pendingMarks {
            if noticeSlot.showing?.id == id {
                presenter.shown(marks)
            } else if !noticeSlot.waiting.contains(where: { $0.id == id }) {
                presenter.dropped(marks)
            } else {
                continue
            }
            pendingMarks[id] = nil
        }
    }

    private func makeResults() -> RaceResultViewModel {
        let frame = driver.currentFrame
        let me = driver.myBoatIndex
        let liveries = driver.liveries
        let live = frame.standings.map { seat in
            let boat = frame.boats[seat]
            return RaceResultViewModel.LiveStanding(
                seat: seat, status: boat.status, place: boat.place,
                finishTick: boat.finishTime.map { Int(($0 * Double(Race.tickRate)).rounded()) })
        }
        let entrants = frame.boats.indices.map { seat in
            RaceResultViewModel.Entrant(name: roster.name(of: seat, playerSeat: me), isBot: roster[seat].isBot,
                                        livery: liveries[seat], isRival: roster[seat].isRival)
        }
        // Online, the server's results once its stream has a report (#133); until then the live frame.
        if let online = onlineResults?.model(entrants: entrants, livery: liveries[me]) { return online }
        return RaceResultViewModel(results: closedResults, live: live, entrants: entrants, mySeat: me,
                                   incidents: driver.incidents, served: servedTurns)
    }
}

func ordinal(_ n: Int) -> String {
    let suffix: String
    switch (n % 10, n % 100) {
    case (_, 11...13): suffix = "th"
    case (1, _): suffix = "st"
    case (2, _): suffix = "nd"
    case (3, _): suffix = "rd"
    default: suffix = "th"
    }
    return "\(n)\(suffix)"
}

func formatClock(_ seconds: Double) -> String {
    // Count down in whole seconds remaining, count up in whole seconds elapsed.
    let total = Int(seconds < 0 ? (-seconds).rounded(.up) : seconds.rounded(.down))
    let sign = seconds < 0 ? "-" : ""
    return String(format: "%@%d:%02d", sign, total / 60, total % 60)
}
