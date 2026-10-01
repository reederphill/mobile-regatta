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

    @ObservationIgnored private var noticeSlot = NoticeSlot()
    /// The minimap's pressure, sampled every couple of seconds rather than every refresh (#289, #114).
    @ObservationIgnored private let minimapField = MinimapField()
    /// The clock notices are timed by: wall-clock time, so a notice reads for its seconds at any timescale.
    @ObservationIgnored var now: () -> Date = { .now }
    @ObservationIgnored private var lastCountdownSecond = Int.max
    @ObservationIgnored private var toldUpdateRequired = false
    /// Every haptic goes through here, so Settings' Haptics off silences them all (#110).
    @ObservationIgnored private let haptics: any Haptics
    /// The Tack/Gybe button's hold and release (#222).
    @ObservationIgnored private var tackHold = TackHold()

    /// A practice race on the device. `timescale` runs the simulation that many times real time
    /// (`-timescale`, for tests).
    convenience init(config: RaceConfig, timescale: Double = 1, haptics: any Haptics = GatedHaptics(),
                     controls: ControlSettings = ControlSettings()) {
        let driver = PracticeDriver(config: config, timescale: timescale)
        self.init(driver: driver, roster: driver.roster, haptics: haptics, controls: controls)
    }

    /// An online race (#68).
    convenience init(online driver: OnlineDriver, haptics: any Haptics = GatedHaptics(),
                     controls: ControlSettings = ControlSettings()) {
        self.init(driver: driver, roster: driver.roster, haptics: haptics, controls: controls)
    }

    /// A render fixture (#62): `log` replayed to the fixture's freeze tick and frozen there, drawn from
    /// its camera through its vision filter.
    convenience init(fixture: RenderFixture, log: RaceLog) throws {
        let driver = try FixtureDriver(log: log, freezeTick: fixture.freezeTick, seat: fixture.hud?.seat)
        self.init(driver: driver, roster: driver.roster)
        scene.cameraOverride = fixture.cameraMode
        vision = fixture.vision
        showsHUDInFixture = fixture.hud != nil
        if let kind = fixture.hud?.notice {
            // A notice the replay can't make (it drains no events): shown for good, so the render holds still.
            noticeSlot.show(Notice(id: 0, kind: kind, text: Self.fixtureNoticeText(kind), posted: .distantPast,
                                   expires: .distantFuture))
            notice = noticeSlot.current(at: now())
        }
    }

    // TODO-COPY (#124): `RaceEventPresenter` writes the real notices; a fixture's is a placeholder of a real length.
    static func fixtureNoticeText(_ kind: NoticeKind) -> String {
        "TODO-COPY \(kind.rawValue): room at the mark for the inside boat"
    }

    init(driver: any RaceDriver, roster: FleetRoster, haptics: any Haptics = GatedHaptics(),
         controls: ControlSettings = ControlSettings()) {
        self.driver = driver
        self.roster = roster
        self.haptics = haptics
        self.controls = controls
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

    private func refreshHUD(samplesPressure: Bool) {
        let world = driver.renderWorld
        let roster = roster
        var hud = HUDState(world: world) { roster[$0].isBot }
        hud.pressureImage = samplesPressure ? minimapField.refresh(world) : minimapField.image
        self.hud = hud
        let current = noticeSlot.current(at: now())
        if current != notice { notice = current }
        if playerDone { results = makeResults() }
        if let online = driver as? OnlineDriver, case .updateRequired = online.connection, !toldUpdateRequired {
            toldUpdateRequired = true
            post(.latency, "Update Regatta to race online. This race can't reconnect.")
        }
    }

    func consume(_ events: [RaceEvent]) {
        for event in events { handle(event) }
        let time = driver.currentFrame.time
        if time < 0 {
            let second = Int(ceil(-time))
            if second != lastCountdownSecond {
                lastCountdownSecond = second
                if second <= 5 || second == 10 || second == 30 { haptics.impact(intensity: 0.5) }
            }
        }
    }

    // MARK: - Events

    private func handle(_ event: RaceEvent) {
        let me = driver.myBoatIndex
        func name(_ i: Int) -> String { roster.label(of: i, playerSeat: me) }

        // Only the ticket's notice kinds reach the slot (#114); the gun, a start, a rounding, a finish and a served
        // penalty are felt, not read.
        switch event.kind {
        case .gun:
            haptics.impact(intensity: 1)
        case .ocsNotice(let b) where b == me:
            post(.ocs, "Rule 29.1 — OCS. You were over at the gun: dip back below the line, then start.")
            haptics.notify(.error)
        case .ruleCall(let call) where call.offender == me:
            post(.ruleCall, "Rule \(call.rule.rawValue) — \(call.rule.title). Your foul on \(name(call.victim)): spin a 360°.")
            haptics.notify(.error)
        case .ruleCall(let call) where call.victim == me:
            post(.ruleCall, "Rule \(call.rule.rawValue) — \(call.rule.title). \(name(call.offender)) fouled you and must spin.")
            haptics.impact(intensity: 0.8)
        case .ruleCall:
            // A call between two other boats posts nothing (#114): it would take your notices' slot and hold back
            // your hints for a foul you weren't in.
            break
        case .markTouch(let b, let mark) where b == me:
            post(.ruleCall, "Rule 31 — you hit the \(mark). Spin a 360°.")
            haptics.notify(.warning)
        case .penaltyServed(let b) where b == me:
            haptics.notify(.success)
        case .rounded(let b, _) where b == me:
            haptics.impact(intensity: 0.6)
        case .finished(let b, _) where b == me:
            haptics.notify(.success)
            finishForPlayer()
        case .disqualified(let b, _) where b == me:
            haptics.notify(.error)
            finishForPlayer()
        case .raceClosed:
            finishForPlayer()
        default:
            break
        }
    }

    private func finishForPlayer() {
        guard !playerDone else { return }
        playerDone = true
        isEasing = false
        results = makeResults()
    }

    private func post(_ kind: NoticeKind, _ text: String) {
        notice = noticeSlot.post(kind, text, at: now())
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
                // Once the race has closed, a boat still racing is placed by distance to finish (#86).
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
