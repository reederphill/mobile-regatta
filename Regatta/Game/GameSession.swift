import Foundation
import Observation
import RegattaBots
import RegattaCore
import UIKit

struct ResultRow: Identifiable {
    let id: Int
    let place: String
    let name: String
    let detail: String
    let colorIndex: Int
    let isPlayer: Bool
    /// Marked with the bot glyph (#19).
    let isBot: Bool
}

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
    var results: [ResultRow] = []
    var isPaused = false
    var playerDone = false
    /// The Ease button is held (#99, #112): the scene sends it with the rudder every frame.
    var isEasing = false
    /// The tiller's track and knob while a tiller drag is held (#112): the scene sets it, `RaceView` draws it.
    var tillerKnob: SteeringInterpreter.TillerKnob?
    /// This is the player's first race: the halves edge labels show (#23). #134 sets it; nothing does yet.
    var isFirstRace = false
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
    /// Every cue the presenter plays, for #126's audio. Nothing sets it yet.
    @ObservationIgnored var onCue: ((RaceCue) -> Void)?
    /// The plain words posted and not yet shown or dropped, by notice id: what each teaches (`settleMarks`).
    @ObservationIgnored private var pendingMarks: [Int: [SeenMark]] = [:]
    @ObservationIgnored private var toldUpdateRequired = false
    /// Every haptic goes through here, so Settings' Haptics off silences them all (#110).
    @ObservationIgnored private let haptics: any Haptics
    /// The Tack/Gybe button's hold and release (#222).
    @ObservationIgnored private var tackHold = TackHold()

    /// A practice race on the device. `timescale` runs the simulation that many times real time
    /// (`-timescale`, for tests).
    convenience init(config: RaceConfig, timescale: Double = 1, haptics: any Haptics = GatedHaptics(),
                     controls: ControlSettings = ControlSettings(), rulesSeen: RuleSeenStore = RuleSeenStore()) {
        let driver = PracticeDriver(config: config, timescale: timescale)
        self.init(driver: driver, roster: driver.roster, haptics: haptics, controls: controls, rulesSeen: rulesSeen)
    }

    /// An online race (#68).
    convenience init(online driver: OnlineDriver, haptics: any Haptics = GatedHaptics(),
                     controls: ControlSettings = ControlSettings(), rulesSeen: RuleSeenStore = RuleSeenStore()) {
        self.init(driver: driver, roster: driver.roster, haptics: haptics, controls: controls, rulesSeen: rulesSeen)
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
    }

    // TODO-COPY (#171): `RaceEventPresenter` writes the real notices; a fixture's is a placeholder of a real length.
    static func fixtureNoticeText(_ kind: NoticeKind) -> String {
        "TODO-COPY \(kind.rawValue): room at the mark for the inside boat"
    }

    /// `rulesSeen`: which rule numbers this device has seen called, for plain words (#23). In memory by default, so
    /// tests and fixtures never write the device's; the app passes one over its defaults.
    init(driver: any RaceDriver, roster: FleetRoster, haptics: any Haptics = GatedHaptics(),
         controls: ControlSettings = ControlSettings(), rulesSeen: RuleSeenStore = RuleSeenStore()) {
        self.driver = driver
        self.roster = roster
        self.haptics = haptics
        self.controls = controls
        let me = driver.myBoatIndex
        presenter = RaceEventPresenter(me: me, seen: rulesSeen) { roster.label(of: $0, playerSeat: me) }
        // `-vision` (Debug); a fixture sets its own after this.
        vision = LaunchOptions.current.raceVision
        scene = GameScene(driver: driver, roster: roster)
        scene.session = self
        // The minimap's first pressure sample (up to ~170 ms on first use, #310) waits for the scene's first HUD
        // refresh, off the race's construction; a frozen fixture takes it here, as its render holds still.
        refreshHUD(samplesPressure: driver.isFrozen)
        // A frozen fixture shows only the notice it names.
        if !driver.isFrozen { post(.hint, Self.startHint(controls.steering)) }
    }

    // TODO-COPY (#171): #129's scheme-aware hints replace this.
    static func startHint(_ steering: DeviceSettings.Steering) -> String {
        switch steering {
        case .halves: "Hold the left or right side of the screen to steer. Be below the line at the gun."
        case .tiller: "Touch anywhere and slide sideways to steer. Be below the line at the gun."
        }
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
        isEasing = false
        scene.resetInput()
    }

    func refreshHUD() { refreshHUD(samplesPressure: true) }

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
        // Your owed penalty turn's countdown (#123), live in the slot while you owe one.
        let penalty = showsRuleCues ? PenaltyReadout(frame: driver.currentFrame, seat: driver.myBoatIndex) : nil
        noticeSlot.setLive(.penalty, text: penalty?.noticeText, at: now())
        let current = noticeSlot.current(at: now())
        settleMarks()
        if current != notice { notice = current }
        closeLeaderboardIfDue()
        if playerDone { results = makeResults() }
        // The RTT warning (#18, #68): once as it starts.
        if let lag = presenter.lag(isWarning: driver.lagWarning) { post(lag.kind, lag.text) }
        if let online = driver as? OnlineDriver, case .updateRequired = online.connection, !toldUpdateRequired {
            toldUpdateRequired = true
            post(.latency, "Update Regatta to race online. This race can't reconnect.")
        }
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
        if let onCue { cues.forEach(onCue) }
        let me = driver.myBoatIndex
        for event in events {
            switch event.kind {
            case .finished(me, _), .disqualified(me, _), .raceClosed:
                finishForPlayer()
            case .rollHit(seat: me):
                // Your roll tack's result is read as well as seen (#222, `BoatNode`'s ring); the presenter plays its haptic.
                // TODO-COPY (#124): `RaceEventPresenter` owns the words.
                post(.roll, "Roll tack: clean")
            case .rollMissed(seat: me):
                post(.roll, "Roll tack: missed")
            default:
                break
            }
        }
    }

    private func finishForPlayer() {
        guard !playerDone else { return }
        playerDone = true
        isEasing = false
        results = makeResults()
    }

    private func post(_ kind: NoticeKind, _ text: String, marks: [SeenMark] = []) {
        if !marks.isEmpty { pendingMarks[noticeSlot.nextID] = marks }
        notice = noticeSlot.post(kind, text, at: now())
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

    private func makeResults() -> [ResultRow] {
        let frame = driver.currentFrame
        let me = driver.myBoatIndex
        return frame.standings.enumerated().map { rank, i in
            let b = frame.boats[i]
            let place: String
            let detail: String
            switch b.status {
            case .finished:
                place = "\(b.place ?? rank + 1)"
                detail = formatClock(b.finishTime ?? 0)
            case .dsq:
                place = "DSQ"
                detail = "Unserved penalty"
            case .racing:
                // Once the race has closed, a boat still racing is placed by ladder distance (#86, #267).
                place = "\(rank + 1)"
                detail = frame.isOver ? "By distance" : "Racing · leg \(b.legIndex + 1)"
            case .prestart, .ocs:
                place = frame.isOver ? "OCS" : "\(rank + 1)"
                detail = "Not started"
            }
            return ResultRow(id: b.id, place: place, name: roster.name(of: i, playerSeat: me), detail: detail,
                             colorIndex: b.colorIndex, isPlayer: i == me, isBot: roster[i].isBot)
        }
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
