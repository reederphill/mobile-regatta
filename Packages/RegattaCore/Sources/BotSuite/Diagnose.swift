import Foundation
import RegattaBots
import RegattaCore

// `regatta-botsuite --diagnose` (#471): why boats start late, what a penalty turn costs them and why they don't
// finish. It watches a race from the harness, as `RaceTally` does: the race's public state after each tick and that
// tick's events. It reads no bot and changes nothing a bot sees or does, so a race sails the same with it or without
// it (`BotSuiteDiagnoseTests.observingLeavesTheRaceBitIdentical`). This file is what one race gives: one
// `BoatDiagnosis` a boat, and the rules that name a cause from it. `DiagnoseReport.swift` pools them into the tables.
// Her mark roundings against the ideal path (#511) are scored in `Roundings.swift`.

/// Why a boat started late: one primary cause a boat, the first that holds in this order (`LateCause.of`), as
/// #471's re-trace ranked them. A boat with two causes counts under the first.
///
/// 1. `penalty`: she owed a penalty turn for 3 s or more of the 40 s before the gun until her start, or for any of it
///    with a pre-start penalty still unserved 30 s before the gun.
/// 2. `ocs`: over the line at the gun, and returning.
/// 3. `irons`: 4 s or more in irons (`BotRaceHarness.ironsSpeed`, inside the no-go zone, owing nothing) in the last 20 s.
/// 4. `cannotFetchPin`: 3 s or more of the last 10 s on starboard below the line where a close-hauled course
///    (45° to the line) passes outside the pin.
/// 5. `port`: on port tack 20 s before the gun.
/// 6. `lateTurn`: a tack or gybe inside the last 20 s.
/// 7. `keepingClear`: 3 s or more of the last 15 s as the boat rules 10–13 name to keep clear of a boat within
///    `RaceObserver.keepClearLengths`, owing nothing.
/// 8. `slow`: none of those, and at the gun within 5 s of the line at her target speed: she was there and not moving.
/// 9. `deep`: none of those, and further from the line than that at the gun.
/// 10. `other`: not on the water at the gun.
///
/// Each window ends at her start, or 40 s after the gun.
public enum LateCause: String, CaseIterable, Codable, Hashable, Sendable {
    case penalty, ocs, irons, cannotFetchPin, port, lateTurn, keepingClear, slow, deep, other

    public var label: String {
        switch self {
        case .penalty: "penalty turn before the start"
        case .ocs: "OCS and returning"
        case .irons: "in irons"
        case .cannotFetchPin: "couldn't fetch the pin on starboard"
        case .port: "on port inside 20 s"
        case .lateTurn: "tacking/gybing late"
        case .keepingClear: "keeping clear / held up"
        case .slow: "slow acceleration"
        case .deep: "too far from the line at the gun"
        case .other: "other"
        }
    }

    /// A start later than this, seconds after the gun, has a cause; the tables count those over 5 s and over 10 s.
    public static let onTimeSeconds = 3.0
    static let penaltySeconds = 3.0
    static let ironsSeconds = 4.0
    static let cannotFetchSeconds = 3.0
    static let keepingClearSeconds = 3.0
    /// Seconds from the line at her target speed, at the gun, within which a late boat was slow rather than deep.
    static let slowSecondsFromLine = 5.0

    /// The primary cause of `start`, or nil for a boat that started within `onTimeSeconds` of the gun.
    public static func of(_ start: StartObservation) -> LateCause? {
        if let seconds = start.startSeconds, seconds <= onTimeSeconds { return nil }
        if start.penaltySeconds >= penaltySeconds || (start.preStartPenaltyUnserved && start.penaltySeconds > 0) { return .penalty }
        if start.ocs { return .ocs }
        if start.ironsSeconds >= ironsSeconds { return .irons }
        if start.cannotFetchSeconds >= cannotFetchSeconds { return .cannotFetchPin }
        if start.onPortAtTwentySeconds { return .port }
        if start.lateTurns > 0 { return .lateTurn }
        if start.keepingClearSeconds >= keepingClearSeconds { return .keepingClear }
        guard let gun = start.atGun else { return .other }
        return gun.metresBelowLine / max(gun.targetSpeed, BotRaceHarness.ironsSpeed) <= slowSecondsFromLine ? .slow : .deep
    }
}

/// What the observer saw of a boat's start: the inputs of `LateCause.of`. Seconds are counted over the ticks from 40 s
/// before the gun (or the later bound each names) until she started, or 40 s after the gun.
public struct StartObservation: Hashable, Sendable {
    /// Her start, seconds after the gun; nil if she never started.
    public var startSeconds: Double?
    /// She was told she was over the line at the gun.
    public var ocs = false
    /// Seconds she owed a penalty turn.
    public var penaltySeconds = 0.0
    /// A penalty called before her start was unserved 30 s before the gun or later.
    public var preStartPenaltyUnserved = false
    /// Seconds in irons in the last 20 s.
    public var ironsSeconds = 0.0
    /// Seconds of the last 10 s on starboard below the line, not fetching the pin.
    public var cannotFetchSeconds = 0.0
    public var onPortAtTwentySeconds = false
    /// Her tacks and gybes inside the last 20 s, penalty turns aside.
    public var lateTurns = 0
    /// Seconds of the last 15 s as the keep-clear boat of a boat close by, owing nothing.
    public var keepingClearSeconds = 0.0
    /// Where she was at the gun; nil if she wasn't on the water.
    public var atGun: AtGun?

    public struct AtGun: Hashable, Sendable {
        /// Metres below the line (negative: on the course side).
        public var metresBelowLine: Double
        /// Her polar speed at the gun for the wind she had, close-hauled or freer, shadow in. Metres per second.
        public var targetSpeed: Double

        public init(metresBelowLine: Double, targetSpeed: Double) {
            self.metresBelowLine = metresBelowLine
            self.targetSpeed = targetSpeed
        }
    }

    public init(startSeconds: Double? = nil) { self.startSeconds = startSeconds }
}

/// Where in the race a penalty episode's first call was made.
public enum PenaltyPhase: String, CaseIterable, Codable, Hashable, Sendable {
    case preStart, firstBeat, laterLegs, lastLeg

    public var label: String {
        switch self {
        case .preStart: "pre-start"
        case .firstBeat: "first beat"
        case .laterLegs: "later legs"
        case .lastLeg: "last leg"
        }
    }

    /// Before the gun or before her start it is the pre-start, whatever leg the race gives her.
    public static func at(tick: Int, status: BoatStatus, leg: Int, legs: Int) -> PenaltyPhase {
        if tick < 0 || status != .racing { return .preStart }
        if leg >= legs - 1 { return .lastLeg }
        return leg == 0 ? .firstBeat : .laterLegs
    }
}

/// Why a penalty turn she had started (30° in) went back to nothing (`RaceEvent.Kind.penaltyReset`: a tick she
/// drove turned her against it), read from the rudder she held on that tick, what she had turned and the boats
/// round her. The first that holds:
///
/// 1. `steeredOff`: her rudder against the turn, but under half over, or on a turn she had never held the rudder
///    half over for and was under `ResetObservation.turningDegrees` into: she was steering a course, not turning.
///    Sailing on with the turn put off, 30° of a bear-away or a luff counts as its start, and steering back gives
///    it up.
/// 2. `gaveUpForBoat`: her rudder at least half over the other way with a boat within
///    `ResetObservation.closeLengths`: she gave the turn up to keep clear (rule 21.2) and turned it the other way.
/// 3. `reversed`: the same with no boat that close: she reversed her own turn in clear water.
/// 4. `letGo`: her rudder centred: she had stopped turning and her heading fell back (on a class with the autohelm,
///    its swing back as she took the helm again, #350).
/// 5. `other`: her rudder still the turn's way and her heading went back all the same.
///
/// The race itself never gives a turn up: a missed deadline is a disqualification, not a restart.
public enum ResetCause: String, CaseIterable, Codable, Hashable, Sendable {
    case reversed, gaveUpForBoat, steeredOff, letGo, other

    public var label: String {
        switch self {
        case .reversed: "reversed"
        case .gaveUpForBoat: "for a boat"
        case .steeredOff: "steered off"
        case .letGo: "let go"
        case .other: "other"
        }
    }

    public static func of(_ reset: ResetObservation) -> ResetCause {
        guard reset.rudder * reset.direction < 0 else { return reset.rudder == 0 ? .letGo : .other }
        guard reset.wasTurning, abs(reset.rudder) >= RaceObserver.heldOverRudder else { return .steeredOff }
        return reset.nearestBoatLengths <= ResetObservation.closeLengths ? .gaveUpForBoat : .reversed
    }
}

/// A started turn's reset as the observer saw it: the input of `ResetCause.of`.
public struct ResetObservation: Hashable, Sendable {
    /// The rudder she held on the tick of the reset, −1…1 (`BoatInput.rudderValue`).
    public var rudder: Double
    /// The way the turn went: 1 to starboard, −1 to port.
    public var direction: Double
    /// How far into the turn she was the tick before, degrees.
    public var degreesIn: Double
    /// Whether she had held the rudder at least half over the turn's way on any tick since it started.
    public var heldOver: Bool
    /// The nearest boat on the water, centre to centre, hull lengths; infinite with none.
    public var nearestBoatLengths: Double

    /// A turn further in than this was being turned, whatever her rudder did.
    public static let turningDegrees = 60.0
    /// A boat within this many hull lengths, centre to centre, is one she gives a turn up for: as close as the boat
    /// a late starter keeps clear of (`RaceObserver.keepClearLengths`).
    public static let closeLengths = RaceObserver.keepClearLengths

    public var wasTurning: Bool { heldOver || degreesIn >= Self.turningDegrees }

    public init(rudder: Double, direction: Double, degreesIn: Double, heldOver: Bool, nearestBoatLengths: Double = .infinity) {
        self.rudder = rudder
        self.direction = direction
        self.degreesIn = degreesIn
        self.heldOver = heldOver
        self.nearestBoatLengths = nearestBoatLengths
    }
}

/// One penalty episode: from a call on a boat owing nothing until she owes nothing again, is disqualified, or the
/// race ends. Calls made meanwhile stack into it.
public struct PenaltyEpisode: Hashable, Sendable {
    public enum Outcome: String, Codable, Hashable, Sendable { case served, disqualified, open }

    public var phase: PenaltyPhase
    /// Its first call, seconds after the gun (negative before it).
    public var callSeconds: Double
    /// The calls in it that cost a turn, the first included.
    public var calls = 1
    public var turnsServed = 0
    public var outcome = Outcome.open
    /// From the call to 30° into the first turn (under a `tackAndGybe` penalty, #487: its first counting crossing);
    /// nil if she never got there.
    public var secondsToStarted: Double?
    /// From there to owing nothing.
    public var secondsTurning: Double?
    /// From owing nothing to 90 % of her target speed (`RaceObserver.targetSpeed`); nil if she was called again
    /// first, left the water, or took longer than `RaceObserver.recoverySeconds`.
    public var secondsRecovering: Double?
    /// Its started turns given up, by cause (a `fullCircle` penalty's: under `tackAndGybe` a reset is a recross or a
    /// rounding's void, counted below).
    public var resets: [ResetCause: Int] = [:]
    /// Under a `tackAndGybe` penalty (#487): her crossings back over a counting crossing (`penaltyReset` on a tick she
    /// tacked or gybed), and the first crossings voided by a rounding (`penaltyReset` on a tick she didn't).
    public var recrosses = 0
    public var roundingVoids = 0
    /// The calls in it made while she was taking a penalty (`Boat.isTakingPenalty`, rule 21.2's window): calls on a
    /// boat turning.
    public var callsWhileTurning = 0
    /// Each turn served: seconds from its clock's start (the call, or the turn before it served; under a `tackAndGybe`
    /// penalty, #487, a turn that became current while she was rounding starts its clock once she is clear of the mark)
    /// to served. The wait for a pending clock is not counted here: it is in `secondsToStarted`, which runs from the
    /// call.
    public var turnSeconds: [Double] = []

    public init(phase: PenaltyPhase, callSeconds: Double) {
        self.phase = phase
        self.callSeconds = callSeconds
    }
}

/// Why a boat didn't finish, the first that holds:
///
/// 1. `missedPenalty`: disqualified for a penalty turn not started or not completed in time.
/// 2. `other`: disqualified otherwise, or never started.
/// 3. `stuck`: under 30 m made towards the finish in her last 90 s, with 10 s or more of them at the race area's
///    edge or a mark or obstruction touched in her last 120 s; `other` if she stalled anywhere else.
/// 4. `afterThreeTurns`, `afterOneOrTwoTurns`, `noTurns`: sailing when the finish window closed, by the penalty turns
///    she had served.
public enum NonFinishCause: String, CaseIterable, Codable, Hashable, Sendable {
    case missedPenalty, noTurns, afterOneOrTwoTurns, afterThreeTurns, stuck, other

    public var label: String {
        switch self {
        case .missedPenalty: "DSQ: missed penalty"
        case .noTurns: "out of the window, no turns"
        case .afterOneOrTwoTurns: "out of the window after 1-2 turns"
        case .afterThreeTurns: "out of the window after 3+ turns"
        case .stuck: "stuck at a mark or the edge"
        case .other: "other"
        }
    }

    static let stalledMetres = 30.0
    static let edgeSeconds = 10.0

    /// Nil for a boat that finished.
    public static func of(_ finish: FinishObservation) -> NonFinishCause? {
        switch finish.status {
        case .finished: return nil
        case .dsq: return finish.missedPenalty ? .missedPenalty : .other
        case .prestart, .ocs: return .other
        case .racing: break
        }
        if let made = finish.metresMadeInLast90Seconds, made < stalledMetres {
            return finish.edgeSeconds >= edgeSeconds || finish.touchedLate ? .stuck : .other
        }
        if finish.turnsServed >= 3 { return .afterThreeTurns }
        return finish.turnsServed >= 1 ? .afterOneOrTwoTurns : .noTurns
    }
}

/// How a boat's race ended: the input of `NonFinishCause.of`.
public struct FinishObservation: Hashable, Sendable {
    public var status: BoatStatus
    /// Disqualified for a missed penalty deadline (`Race.missedStart`, `Race.missedComplete`).
    public var missedPenalty = false
    /// Metres of course left at the end; 0 for a finisher.
    public var metresToGo = 0.0
    public var turnsServed = 0
    /// Metres she made towards the finish in her last 90 s on the water; nil if she wasn't out that long.
    public var metresMadeInLast90Seconds: Double?
    /// Seconds of those 90 at the race area's edge (`BotRaceHarness.edgeMargin`).
    public var edgeSeconds = 0.0
    /// She touched a mark or an obstruction in her last 120 s.
    public var touchedLate = false

    public init(status: BoatStatus) { self.status = status }
}

/// What the observer saw of a boat's planing off the wind (#462): her seconds running and off the plane, her gybes,
/// and her falls off the plane. Running is racing at `RaceObserver.runningTWA` or broader, owing no penalty turn, in a
/// wind whose downwind groove planes (the polar's speed there at the class's `onSpeed` or more).
public struct PlaningObservation: Hashable, Sendable {
    public var runSeconds = 0.0
    /// Of them, off the plane.
    public var offSeconds = 0.0
    /// Her gybes racing, penalty turns aside.
    public var gybes = 0
    /// Of them, those with a fall off the plane from `RaceObserver.gybeFallWindow.before` seconds before the boom
    /// crossed to `after` seconds after it.
    public var gybesWithAFall = 0
    /// Her falls off the plane while running.
    public var falls = 0
    /// Of them, by what took her off (`Cause`), a gybe's first.
    public var fallsByCause: [Cause: Int] = [:]

    /// What took her off the plane, the first that holds: a `gybe` (her boom crossed within
    /// `RaceObserver.gybeFallWindow` of it); `rounding`: within `RaceObserver.roundingSeconds` after she rounded a
    /// mark onto the leg (bearing away before she is up to speed); too little apparent wind with the rudder near centre (the class's
    /// `apparentWind`), sailing more than `RaceObserver.deepDegrees` deeper than the groove of her wind (`deep`) or not
    /// (`lull`: the wind dropped, or a boat's shadow took it); else `slow`: her speed (a turn, a boat, a mark).
    public enum Cause: String, CaseIterable, Codable, Hashable, Sendable { case gybe, rounding, deep, lull, slow }
    /// Of them, those she was still running for `RaceObserver.backOnSeconds` after, or back on the plane sooner: the
    /// ones that show whether she got back on.
    public var fallsWatched = 0
    /// Of those, back on the plane within `RaceObserver.backOnSeconds`.
    public var fallsBackOn = 0
    /// Seconds off the plane for each fall that ended back on it while she ran.
    public var secondsOff: [Double] = []

    public init() {}
}

/// A leg of the course by how it is sailed: from where it starts to its mark, up the course's axis (a beat), down
/// it (a run) or across (the reach to the offset mark); the first beat and the run to the finish apart, as the start
/// ends on the one and the finish window closes on the other.
public enum LegKind: String, CaseIterable, Codable, Hashable, Sendable {
    case firstBeat, beat, reach, run, lastRun

    public var label: String {
        switch self {
        case .firstBeat: "first beat"
        case .beat: "later beats"
        case .reach: "reaches"
        case .run: "runs"
        case .lastRun: "last run"
        }
    }

    /// The kinds of `course`'s legs, by leg index.
    static func kinds(of course: CourseLayout) -> [LegKind] {
        let legs = course.legs
        return legs.indices.map { index in
            let from = index == 0 ? course.startLine.centre : course.targetPosition(for: legs[index - 1])
            let made = (course.targetPosition(for: legs[index]) - from).dot(course.upwind)
            if made > course.beat / 4 { return index == 0 ? .firstBeat : .beat }
            if made < -course.beat / 4 { return index == legs.count - 1 ? .lastRun : .run }
            return .reach
        }
    }
}

/// What the observer saw of a boat on one leg she began (#462): where the boats that miss the finish window lose
/// their time, and to what.
public struct LegObservation: Hashable, Sendable {
    public var kind: LegKind
    /// Seconds after the first boat of her race onto the leg that she came onto it; the first leg's is her start's
    /// after the first start.
    public var secondsBehind: Double
    /// Her seconds on it; nil when she did not sail it to its end.
    public var seconds: Double?
    /// Those over the fastest boat's on the leg in her race.
    public var secondsLost: Double?
    /// The penalty turns she was given on it.
    public var turns = 0
    /// Her falls off the plane (`PlaningObservation.falls`) and her gybes on it, penalty turns aside.
    public var falls = 0
    public var gybes = 0
    /// Rule calls against her on it, by rule (`RacingRule.rawValue`), and her mark touches under "31".
    public var calls: [String: Int] = [:]

    public init(kind: LegKind, secondsBehind: Double) {
        self.kind = kind
        self.secondsBehind = secondsBehind
    }
}

/// What `--diagnose` saw of one boat in one race.
/// Where she waited before the gun and how she turned (#477, report-only), each whole second she was on the water.
public struct StartPlanObservation: Hashable, Sendable {
    /// Seconds of the last 30 s before the gun; of those, 2–5 hull lengths below the line (the band), the band's on
    /// starboard, and on starboard anywhere.
    public var lastThirtySeconds = 0
    public var bandSeconds = 0
    public var bandStarboardSeconds = 0
    public var starboardSeconds = 0
    /// In the band on starboard: hull lengths below the line, metres per second, and the share of her target speed
    /// (`RaceObserver.targetSpeed`), a sample a second.
    public var bandStarboardDepths: [Double] = []
    public var bandStarboardSpeeds: [Double] = []
    public var bandStarboardPolarShares: [Double] = []
    /// Seconds of the last 40 s before the gun on starboard 2–8 hull lengths below the line, and of those with her sheets
    /// eased (her held input's `ease`).
    public var deepStarboardSeconds = 0
    public var deepStarboardEasedSeconds = 0
    /// Her tacks from port onto starboard in the last 60 s before the gun, penalty turns aside: hull lengths below the line
    /// at each, and those with a starboard boat within 3 hull lengths ahead or abeam to windward.
    public var portTackDepths: [Double] = []
    public var portTacksCrowded = 0
    /// Her turns from starboard onto port before the gun, penalty turns aside: the turn at the pin end of a lap.
    public var pinEndTurns = 0
    /// Seconds of the last 40 s before the gun 2–8 hull lengths below the line on either tack, and of those under the
    /// start plan's tacking floor (`HandTackTable.startTackingSpeed` of close-hauled speed, #477 PR 2); the same of the
    /// seconds she waited eased (her held input's `ease`).
    public var waitWindowSeconds = 0
    public var waitWindowBelowFloorSeconds = 0
    public var waitEasedSeconds = 0
    public var waitEasedBelowFloorSeconds = 0
    /// Her tacks before the gun, penalty turns aside: seconds from each to 0.9 of her close-hauled speed (#477 PR 2), those
    /// she eased again before it (waiting on, not costed), and those not back to it by the gun or her next turn.
    public var waitTackRecoveries: [Double] = []
    public var waitTacksEased = 0
    public var waitTacksUnrecovered = 0

    public init() {}
}

public struct BoatDiagnosis: Hashable, Sendable {
    public var tier: BotTier
    /// A live bot's tactics skill and handling skill, as tiers (`AxesSummary.init(live:)`'s buckets); nil for any other
    /// seat.
    public var skill: BotTier?
    public var hand: BotTier?
    /// The legs she began, in order.
    public var legs: [LegObservation] = []
    public var start: StartObservation
    /// Where she waited before the gun (#477).
    public var plan = StartPlanObservation()
    public var planing = PlaningObservation()
    /// The mark roundings she sailed to their leg's end, in order (#511).
    public var roundings: [RoundingObservation] = []
    public var episodes: [PenaltyEpisode] = []
    /// The penalty turns she was given in the race: her rule calls that cost one, and her mark touches.
    public var turnsOwed = 0
    public var finish: FinishObservation

    public init(tier: BotTier, start: StartObservation, finish: FinishObservation) {
        self.tier = tier
        self.start = start
        self.finish = finish
    }
}

/// Watches one race for `--diagnose`. Call `record` once after each `race.step()` with the events it emitted, then
/// `boats(tiers:)`.
public struct RaceObserver {
    /// The start's windows, seconds either side of the gun (`LateCause`).
    static let startWindowSeconds = 40
    static let ironsWindowSeconds = 20
    static let cannotFetchWindowSeconds = 10
    static let keepingClearWindowSeconds = 15
    static let portCheckSeconds = 20
    static let lateTurnWindowSeconds = 20
    /// A pre-start penalty unserved this many seconds before the gun makes her late by itself.
    static let unservedBeforeGunSeconds = 30.0
    /// A boat this many hull lengths off, centre to centre, is close by: the rules' two lengths between hulls, and
    /// about half a hull at each end.
    static let keepClearLengths = 3.0
    /// She has recovered from a turn at this share of her target speed ...
    static let recoveredShare = 0.9
    /// ... looked for this long after it, seconds, and only against a target over this, metres per second.
    static let recoverySeconds = 60
    static let recoveryMinimumTarget = 0.3
    /// Rudder at least this far over the turn's way: she is turning it (`ResetObservation.heldOver`).
    static let heldOverRudder = 0.5
    static let finishWindowSeconds = 90
    static let touchWindowSeconds = 120
    /// Running, for the planing table (#462): this far off the wind or broader, radians.
    static let runningTWA = deg2rad(100)
    /// A fall off the plane is a gybe's from this long before her boom crosses to this long after it, seconds.
    static let gybeFallWindow = (before: 3.0, after: 8.0)
    /// A fall she is back on the plane from within this, seconds, is one she recovered from.
    static let backOnSeconds = 15.0
    /// A fall for want of apparent wind this far deeper than the groove, degrees, is one for sailing too deep.
    static let deepDegrees = 3.0
    /// A fall this long after she rounded a mark, seconds, is the rounding's.
    static let roundingSeconds = 15.0

    private let rate = Race.tickRate
    private let line: CourseLayout.Line
    private let lineDirection: Vec2
    private let legs: Int
    private let noGo: Double
    private let hullLength: Double
    /// The race's penalty is a tack and a gybe (#487, fleet-rules@6): a reset is a recross or a rounding's void.
    private let tackAndGybe: Bool
    /// Each seat's last tick a turn was served, and the seats that tacked or gybed on the tick being recorded.
    private var servedTick: [Int?]
    private var crossedNow: Set<Int> = []

    private var starts: [StartObservation]
    private var plans: [StartPlanObservation]
    /// The tick of her last tack before the gun not yet back to 0.9 of close-hauled speed (#477 PR 2).
    private var planTackTicks: [Int?]
    private var startTicks: [Int?]
    private var episodes: [[PenaltyEpisode]]
    private var turnsOwed: [Int]
    private var turnsServed: [Int]

    /// The episode each seat has open: its first call's tick, the current turn's clock (nil while it is pending, #487),
    /// and its started turn, if any.
    private struct Open {
        var callTick: Int
        var clockTick: Int?
        var startedTick: Int?
        var isStarted = false
        var heldOver = false
        var owed = 1
    }
    private var open: [Open?]
    /// Each seat's last served episode still looked at for her recovery: its index and the tick it was served.
    private var recovering: [(episode: Int, servedTick: Int)?]
    /// Each seat's penalty progress after the tick before, radians (`Boat.penaltyProgress`).
    private var progress: [Double]

    private var disqualified: [String?]
    private var lastTouchTick: [Int?]
    private var lastOnWaterTick: [Int]
    /// Each seat's metres to the finish and whether she was at the edge, once a second for her last
    /// `finishWindowSeconds` on the water, as rings indexed by the second.
    private var metresToGo: [[Double]]
    private var atEdge: [[Bool]]
    private var samples: [Int]

    private var planing: [PlaningObservation]
    private var wasPlaning: [Bool]
    private var wasRunning: [Bool]
    /// The tick of each seat's fall off the plane she has not yet got back on from, while she runs.
    private var fallTick: [Int?]
    private var fallTicks: [[Int]]
    /// Each fall's cause but for a gybe's, which is known only once her boom has crossed.
    private var fallCauses: [[PlaningObservation.Cause]]
    /// Each seat's leg after the tick before, and the tick she came onto it.
    private var onLeg: [(index: Int, sinceTick: Int)]
    private var gybeTicks: [[Int]]

    /// A leg a seat began: the ticks she came onto it and left it, and what happened on it (`LegObservation`).
    private struct LegLog {
        var entry: Int
        var end: Int?
        var turns = 0
        var falls = 0
        var gybes = 0
        var calls: [String: Int] = [:]
    }
    private var legLog: [[LegLog]]
    private let legKinds: [LegKind]
    /// Each seat's mark roundings against the ideal path (#511).
    private var roundings: [RoundingScorer]

    public init(race: Race) {
        let count = race.boats.count
        line = race.course.startLine
        lineDirection = (line.committee.position - line.pin.position).normalized
        legs = race.course.legs.count
        noGo = BoatDynamics.noGoAngle(race.boatClass.polar)
        hullLength = race.boatClass.hull.length
        tackAndGybe = race.rules.raceFormat.penalty.turn == .tackAndGybe
        servedTick = Array(repeating: nil, count: count)
        starts = Array(repeating: StartObservation(), count: count)
        plans = Array(repeating: StartPlanObservation(), count: count)
        planTackTicks = Array(repeating: nil, count: count)
        startTicks = Array(repeating: nil, count: count)
        episodes = Array(repeating: [], count: count)
        turnsOwed = Array(repeating: 0, count: count)
        turnsServed = Array(repeating: 0, count: count)
        open = Array(repeating: nil, count: count)
        recovering = Array(repeating: nil, count: count)
        progress = race.boats.map(\.penaltyProgress)
        disqualified = Array(repeating: nil, count: count)
        lastTouchTick = Array(repeating: nil, count: count)
        lastOnWaterTick = Array(repeating: race.tick, count: count)
        metresToGo = Array(repeating: Array(repeating: 0, count: Self.finishWindowSeconds + 1), count: count)
        atEdge = Array(repeating: Array(repeating: false, count: Self.finishWindowSeconds + 1), count: count)
        samples = Array(repeating: 0, count: count)
        planing = Array(repeating: PlaningObservation(), count: count)
        wasPlaning = race.boats.map(\.isPlaning)
        wasRunning = Array(repeating: false, count: count)
        fallTick = Array(repeating: nil, count: count)
        fallTicks = Array(repeating: [], count: count)
        fallCauses = Array(repeating: [], count: count)
        onLeg = race.boats.map { ($0.legIndex, race.tick) }
        gybeTicks = Array(repeating: [], count: count)
        legLog = Array(repeating: [], count: count)
        legKinds = LegKind.kinds(of: race.course)
        roundings = Array(repeating: RoundingScorer(course: race.course, polar: race.boatClass.polar), count: count)
    }

    /// One tick of a boat's legs: her first begins at her start, each next as she rounds onto it, the last ends at her
    /// finish.
    private mutating func recordLeg(_ seat: Int, _ boat: Boat, _ tick: Int) {
        guard let start = startTicks[seat] else { return }
        if legLog[seat].isEmpty { legLog[seat].append(LegLog(entry: start)) }
        while let last = legLog[seat].indices.last, legLog[seat][last].end == nil {
            if boat.status == .finished {
                legLog[seat][last].end = tick
            } else if boat.status == .racing, boat.legIndex > last, last + 1 < legs {
                legLog[seat][last].end = tick
                legLog[seat].append(LegLog(entry: tick))
            } else {
                break
            }
        }
    }

    /// Something on the leg `seat` is sailing, if she is on one.
    private mutating func onHerLeg(_ seat: Int, _ change: (inout LegLog) -> Void) {
        guard let last = legLog[seat].indices.last, legLog[seat][last].end == nil else { return }
        change(&legLog[seat][last])
    }

    /// Her polar speed for the wind she has at the angle she sails, close-hauled if she points higher, with her
    /// shadow in: what she would be doing sailing well. Metres per second.
    static func targetSpeed(of boat: Boat, in boatClass: BoatClass) -> Double {
        let tws = boat.polarWindSpeed(in: boatClass)
        let twa = max(boat.twa, boatClass.polar.bestUpwind(tws: tws).twa)
        return boatClass.polar.speed(twa: twa, tws: tws) * boat.speedShadow(in: boatClass)
    }

    public mutating func record(_ race: Race, events: [RaceEvent]) {
        let tick = race.tick
        crossedNow = Set(events.compactMap { event -> Int? in
            switch event.kind {
            case .tacked(let seat), .gybed(let seat): seat
            default: nil
            }
        })
        for event in events { record(event, race) }
        for (seat, boat) in race.boats.enumerated() {
            defer { progress[seat] = boat.penaltyProgress }
            recordLeg(seat, boat, tick)
            guard !boat.isGhost else { continue }
            lastOnWaterTick[seat] = tick
            if startTicks[seat] == nil { recordStart(seat, boat, race) }
            if tick < 0, tick.isMultiple(of: rate) { recordPlan(seat, boat, race) }
            recordPlanTackRecovery(seat, boat, race)
            if var turn = open[seat], turn.clockTick == nil, let clock = boat.penaltyClockTick {
                turn.clockTick = clock // a pending clock started, clear of the mark (#487)
                open[seat] = turn
            }
            if var turn = open[seat], turn.isStarted, !turn.heldOver, boat.penaltyProgress != 0,
               race.heldInputs[seat].rudderValue * (boat.penaltyProgress < 0 ? -1 : 1) >= Self.heldOverRudder {
                turn.heldOver = true
                open[seat] = turn
            }
            recordRecovery(seat, boat, race)
            recordPlaning(seat, boat, race)
            if boat.status == .racing {
                roundings[seat].record(RoundingSample(tick: tick, position: boat.position, windDirection: boat.windDirection,
                                                      tws: boat.polarWindSpeed(in: race.boatClass), leg: boat.legIndex,
                                                      stage: boat.roundingStage))
            }
            if tick.isMultiple(of: rate) {
                let slot = samples[seat] % (Self.finishWindowSeconds + 1)
                metresToGo[seat][slot] = race.distanceToFinish(of: boat)
                atEdge[seat][slot] = race.course.raceArea.inset(boat.position) < BotRaceHarness.edgeMargin
                samples[seat] += 1
            }
        }
    }

    private mutating func record(_ event: RaceEvent, _ race: Race) {
        let tick = race.tick
        recordPlanTurn(event, race)
        switch event.kind {
        case .ocsNotice(let seat): starts[seat].ocs = true
        case .started(let seat):
            if startTicks[seat] == nil { startTicks[seat] = tick }
        case .ruleCall(let call) where call.turnsOwed > 0:
            onHerLeg(call.offender) { $0.calls[call.rule.rawValue, default: 0] += 1 }
            recordCall(call.offender, race)
        case .markTouch(let seat, _):
            lastTouchTick[seat] = tick
            onHerLeg(seat) { $0.calls[RacingRule.touchingMark.rawValue, default: 0] += 1 }
            recordCall(seat, race)
        case .obstructionContact(let seat, _): lastTouchTick[seat] = tick
        case .penaltyStarted(let seat):
            guard var turn = open[seat] else { break }
            if turn.startedTick == nil { turn.startedTick = tick }
            turn.isStarted = true
            turn.heldOver = false
            open[seat] = turn
        case .penaltyReset(let seat) where tackAndGybe:
            // A recross (a crossing back on this tick) or a rounding's void (#487). A recross in her first owed turn
            // leaves the turn started, the other way: it is started while she has a crossing.
            guard var turn = open[seat] else { break }
            let index = episodes[seat].count - 1
            if crossedNow.contains(seat) { episodes[seat][index].recrosses += 1 } else { episodes[seat][index].roundingVoids += 1 }
            turn.isStarted = race.boats[seat].penaltyFirstCrossing != nil
            open[seat] = turn
        case .penaltyReset(let seat):
            guard var turn = open[seat], turn.isStarted else { break }
            let boats = race.boats
            let nearest = boats.indices.filter { $0 != seat && !boats[$0].isGhost }
                .map { (boats[$0].position - boats[seat].position).length }.min() ?? .infinity
            let reset = ResetObservation(rudder: race.heldInputs[seat].rudderValue, direction: progress[seat] < 0 ? -1 : 1,
                                         degreesIn: abs(rad2deg(progress[seat])), heldOver: turn.heldOver,
                                         nearestBoatLengths: nearest / hullLength)
            episodes[seat][episodes[seat].count - 1].resets[ResetCause.of(reset), default: 0] += 1
            turn.isStarted = false
            open[seat] = turn
        case .penaltyServed(let seat):
            guard var turn = open[seat] else { break }
            let index = episodes[seat].count - 1
            servedTick[seat] = tick
            turnsServed[seat] += 1
            episodes[seat][index].turnsServed += 1
            episodes[seat][index].turnSeconds.append(seconds(tick - (turn.clockTick ?? tick)))
            turn.clockTick = tackAndGybe ? race.boats[seat].penaltyClockTick : tick
            turn.owed -= 1
            // Served without the 30° announced (carried over from the turn before): started when it was served.
            if turn.startedTick == nil { turn.startedTick = tick }
            guard turn.owed <= 0 else {
                open[seat] = turn
                break
            }
            let started = turn.startedTick ?? tick
            episodes[seat][index].outcome = .served
            episodes[seat][index].secondsToStarted = seconds(started - turn.callTick)
            episodes[seat][index].secondsTurning = seconds(tick - started)
            open[seat] = nil
            recovering[seat] = (index, tick)
        case .gybed(let seat) where race.boats[seat].status == .racing && !race.boats[seat].isTakingPenalty:
            planing[seat].gybes += 1
            gybeTicks[seat].append(tick)
            onHerLeg(seat) { $0.gybes += 1 }
        case .tacked(let seat), .gybed(let seat):
            // Under a `tackAndGybe` penalty (#487) the crossing that served a turn is the turn's too.
            guard startTicks[seat] == nil, !race.boats[seat].isTakingPenalty, !(tackAndGybe && servedTick[seat] == tick),
                  tick >= -Self.lateTurnWindowSeconds * rate, tick < Self.startWindowSeconds * rate else { break }
            starts[seat].lateTurns += 1
        case .disqualified(let seat, let reason):
            disqualified[seat] = reason
            if open[seat] != nil {
                episodes[seat][episodes[seat].count - 1].outcome = .disqualified
                open[seat] = nil
            }
        default: break
        }
    }

    /// A call that cost `seat` a turn: it opens an episode if she owed nothing, and stacks into the open one if not.
    private mutating func recordCall(_ seat: Int, _ race: Race) {
        turnsOwed[seat] += 1
        onHerLeg(seat) { $0.turns += 1 }
        if var turn = open[seat] {
            turn.owed += 1
            open[seat] = turn
            episodes[seat][episodes[seat].count - 1].calls += 1
            if race.boats[seat].isTakingPenalty { episodes[seat][episodes[seat].count - 1].callsWhileTurning += 1 }
            return
        }
        let boat = race.boats[seat]
        let phase = PenaltyPhase.at(tick: race.tick, status: boat.status, leg: boat.legIndex, legs: legs)
        episodes[seat].append(PenaltyEpisode(phase: phase, callSeconds: seconds(race.tick)))
        open[seat] = Open(callTick: race.tick, clockTick: tackAndGybe ? race.boats[seat].penaltyClockTick : race.tick)
        recovering[seat] = nil
    }

    /// One tick of a boat that hasn't started, inside the start's window.
    private mutating func recordStart(_ seat: Int, _ boat: Boat, _ race: Race) {
        let tick = race.tick
        guard tick >= -Self.startWindowSeconds * rate, tick < Self.startWindowSeconds * rate else { return }
        let step = 1 / Double(rate)
        let owes = boat.penaltyTurnsOwed > 0
        if owes { starts[seat].penaltySeconds += step }
        if tick >= -Self.ironsWindowSeconds * rate, !owes, boat.twa < noGo, boat.speed < BotRaceHarness.ironsSpeed {
            starts[seat].ironsSeconds += step
        }
        let below = -line.side(boat.position)
        if tick >= -Self.cannotFetchWindowSeconds * rate, boat.status == .prestart, boat.tack == .starboard, below > 0,
           (boat.position - line.pin.position).dot(lineDirection) < below {
            starts[seat].cannotFetchSeconds += step
        }
        if tick >= -Self.keepingClearWindowSeconds * rate, !owes, keepsClearOfABoatCloseBy(seat, race) {
            starts[seat].keepingClearSeconds += step
        }
        if tick == -Self.portCheckSeconds * rate { starts[seat].onPortAtTwentySeconds = boat.tack == .port }
        if tick == 0 {
            starts[seat].atGun = .init(metresBelowLine: below, targetSpeed: Self.targetSpeed(of: boat, in: race.boatClass))
        }
    }

    /// One second before the gun of where she waits (#477, `StartPlanObservation`).
    private mutating func recordPlan(_ seat: Int, _ boat: Boat, _ race: Race) {
        let tick = race.tick
        let depth = -line.side(boat.position) / hullLength
        let starboard = boat.tack == .starboard
        if tick >= -Self.planBandWindowSeconds * rate {
            plans[seat].lastThirtySeconds += 1
            if starboard { plans[seat].starboardSeconds += 1 }
            if depth >= 2, depth <= 5 {
                plans[seat].bandSeconds += 1
                if starboard {
                    plans[seat].bandStarboardSeconds += 1
                    plans[seat].bandStarboardDepths.append(depth)
                    plans[seat].bandStarboardSpeeds.append(boat.speed)
                    let target = Self.targetSpeed(of: boat, in: race.boatClass)
                    if target > 0 { plans[seat].bandStarboardPolarShares.append(boat.speed / target) }
                }
            }
        }
        if tick >= -Self.planEasedWindowSeconds * rate, starboard, boat.status == .prestart, depth >= 2, depth <= 8 {
            plans[seat].deepStarboardSeconds += 1
            if race.heldInputs[seat].ease { plans[seat].deepStarboardEasedSeconds += 1 }
        }
        if tick >= -Self.planEasedWindowSeconds * rate, boat.status == .prestart, !boat.isTakingPenalty, depth >= 2, depth <= 8 {
            let below = boat.speed < Self.closeHauledSpeed(of: boat, in: race.boatClass) * HandTackTable.startTackingSpeed
            let eased = race.heldInputs[seat].ease
            plans[seat].waitWindowSeconds += 1
            if below { plans[seat].waitWindowBelowFloorSeconds += 1 }
            if eased { plans[seat].waitEasedSeconds += 1 }
            if eased, below { plans[seat].waitEasedBelowFloorSeconds += 1 }
        }
    }

    /// Her close-hauled speed in the wind she has, m/s (`BotBrain.closeHauledSpeed`).
    static func closeHauledSpeed(of boat: Boat, in boatClass: BoatClass) -> Double {
        boatClass.polar.bestUpwind(tws: boat.polarWindSpeed(in: boatClass)).speed * boat.speedShadow(in: boatClass)
    }

    /// Each tick of a tack before the gun until she is back to `planTackRecoveredShare` of close-hauled speed (#477 PR 2):
    /// the seconds it took, or unrecovered at the gun.
    private mutating func recordPlanTackRecovery(_ seat: Int, _ boat: Boat, _ race: Race) {
        guard let from = planTackTicks[seat] else { return }
        if race.tick >= 0 {
            plans[seat].waitTacksUnrecovered += 1
            planTackTicks[seat] = nil
        } else if race.tick > from, abs(boat.twa) < .pi / 2, boat.status == .prestart,
                  boat.speed >= Self.closeHauledSpeed(of: boat, in: race.boatClass) * Self.planTackRecoveredShare {
            plans[seat].waitTackRecoveries.append(Double(race.tick - from) / Double(rate))
            planTackTicks[seat] = nil
        } else if race.tick > from + rate, race.heldInputs[seat].ease || boat.status != .prestart {
            plans[seat].waitTacksEased += 1
            planTackTicks[seat] = nil
        }
    }

    /// Back to speed after a tack before the gun: this share of close-hauled speed (#477 Step 0's criterion).
    static let planTackRecoveredShare = 0.9

    /// A tack or gybe before the gun (#477): from port onto starboard in the last 60 s, where she tacked and who was
    /// there; from starboard onto port, the turn at the pin end.
    private mutating func recordPlanTurn(_ event: RaceEvent, _ race: Race) {
        let seat: Int, tacked: Bool
        switch event.kind {
        case .tacked(let s): (seat, tacked) = (s, true)
        case .gybed(let s): (seat, tacked) = (s, false)
        default: return
        }
        let boat = race.boats[seat]
        guard race.tick < 0, boat.status == .prestart, !boat.isTakingPenalty, !(tackAndGybe && servedTick[seat] == race.tick)
        else { return }
        if planTackTicks[seat] != nil { plans[seat].waitTacksUnrecovered += 1 }
        planTackTicks[seat] = tacked ? race.tick : nil
        guard boat.tack == .starboard else {
            plans[seat].pinEndTurns += 1
            return
        }
        guard tacked, race.tick >= -Self.planTackWindowSeconds * rate else { return }
        plans[seat].portTackDepths.append(-line.side(boat.position) / hullLength)
        let forward = Vec2.heading(boat.heading), upwind = Vec2.heading(boat.windDirection)
        let crowded = race.boats.indices.contains { other in
            let them = race.boats[other]
            guard other != seat, !them.isGhost, them.tack == .starboard else { return false }
            let offset = them.position - boat.position
            guard offset.length <= hullLength * Self.keepClearLengths else { return false }
            let ahead = offset.dot(forward)
            return ahead > hullLength / 2 || (ahead > -hullLength / 2 && offset.dot(upwind) > 0)
        }
        if crowded { plans[seat].portTacksCrowded += 1 }
    }

    /// The start plan's windows (#477), seconds before the gun.
    static let planBandWindowSeconds = 30
    static let planEasedWindowSeconds = 40
    static let planTackWindowSeconds = 60

    /// Whether rules 10–13 name `seat` to keep clear of a boat within `keepClearLengths` of her.
    private func keepsClearOfABoatCloseBy(_ seat: Int, _ race: Race) -> Bool {
        let boats = race.boats
        let reach = hullLength * Self.keepClearLengths
        return boats.indices.contains { other in
            other != seat && !boats[other].isGhost && (boats[other].position - boats[seat].position).length <= reach
                && race.rightOfWay(seat, other)?.keepClear == seat
        }
    }

    private mutating func recordRecovery(_ seat: Int, _ boat: Boat, _ race: Race) {
        guard let (episode, servedTick) = recovering[seat] else { return }
        guard boat.penaltyTurnsOwed == 0, race.tick - servedTick <= Self.recoverySeconds * rate else {
            recovering[seat] = nil
            return
        }
        let target = Self.targetSpeed(of: boat, in: race.boatClass)
        guard target > Self.recoveryMinimumTarget, boat.speed >= Self.recoveredShare * target else { return }
        episodes[seat][episode].secondsRecovering = seconds(race.tick - servedTick)
        recovering[seat] = nil
    }

    /// One tick of a boat's planing (#462, `PlaningObservation`).
    private mutating func recordPlaning(_ seat: Int, _ boat: Boat, _ race: Race) {
        defer { wasPlaning[seat] = boat.isPlaning }
        guard let tuning = race.boatClass.planing else { return }
        if boat.legIndex != onLeg[seat].index { onLeg[seat] = (boat.legIndex, race.tick) }
        let tws = boat.polarWindSpeed(in: race.boatClass)
        let running = boat.status == .racing && boat.penaltyTurnsOwed == 0 && boat.twa >= Self.runningTWA
            && race.boatClass.polar.bestDownwind(tws: tws).speed >= tuning.onSpeed
        defer { wasRunning[seat] = running }
        let step = 1 / Double(rate)
        if let fell = fallTick[seat] {
            let off = seconds(race.tick - fell)
            if boat.isPlaning || !running {
                if boat.isPlaning { planing[seat].secondsOff.append(off) }
                if boat.isPlaning || off >= Self.backOnSeconds {
                    planing[seat].fallsWatched += 1
                    if boat.isPlaning, off <= Self.backOnSeconds { planing[seat].fallsBackOn += 1 }
                }
                fallTick[seat] = nil
            }
        }
        guard running else { return }
        planing[seat].runSeconds += step
        if !boat.isPlaning { planing[seat].offSeconds += step }
        if wasPlaning[seat], wasRunning[seat], !boat.isPlaning {
            planing[seat].falls += 1
            onHerLeg(seat) { $0.falls += 1 }
            fallTick[seat] = race.tick
            fallTicks[seat].append(race.tick)
            var cause = PlaningObservation.Cause.slow
            if let wind = tuning.apparentWind, abs(boat.rudder) <= wind.rudderWithin,
               BoatClass.PlaningTuning.apparentWindSpeed(twa: boat.twa, speed: boat.speed, tws: tws) < wind.offSpeed(tws: tws) {
                let groove = race.boatClass.polar.bestDownwind(tws: tws).twa
                cause = boat.twa > groove + deg2rad(Self.deepDegrees) ? .deep : .lull
            }
            if onLeg[seat].index > 0, seconds(race.tick - onLeg[seat].sinceTick) <= Self.roundingSeconds { cause = .rounding }
            fallCauses[seat].append(cause)
        }
    }

    private func seconds(_ ticks: Int) -> Double { Double(ticks) / Double(rate) }

    /// Each seat's diagnosis once the race is sailed; `tiers` are the seats' tiers.
    public func boats(of race: Race, tiers: [BotTier]) -> [BoatDiagnosis] {
        // Each leg's first boat onto it and its fastest boat, of this race.
        let first = legKinds.indices.map { leg in legLog.compactMap { leg < $0.count ? $0[leg].entry : nil }.min() }
        let fastest = legKinds.indices.map { leg in
            legLog.compactMap { log in leg < log.count ? log[leg].end.map { $0 - log[leg].entry } : nil }.min()
        }
        return race.boats.indices.map { seat in
            let boat = race.boats[seat]
            var start = starts[seat]
            start.startSeconds = startTicks[seat].map(seconds)
            let windowEnd = min(start.startSeconds ?? .infinity, Double(Self.startWindowSeconds))
            start.preStartPenaltyUnserved = episodes[seat].contains { episode in
                guard episode.phase == .preStart, episode.callSeconds < windowEnd else { return false }
                guard episode.outcome == .served, let wait = episode.secondsToStarted, let turning = episode.secondsTurning else { return true }
                return episode.callSeconds + wait + turning > -Self.unservedBeforeGunSeconds
            }
            var finish = FinishObservation(status: boat.status)
            finish.missedPenalty = disqualified[seat] == Race.missedStart || disqualified[seat] == Race.missedComplete
            finish.metresToGo = boat.status == .finished ? 0 : race.distanceToFinish(of: boat)
            finish.turnsServed = turnsServed[seat]
            let size = Self.finishWindowSeconds + 1
            if samples[seat] >= size {
                // The ring's next slot holds the oldest sample, 90 s before the newest.
                let newest = (samples[seat] - 1) % size, oldest = samples[seat] % size
                finish.metresMadeInLast90Seconds = metresToGo[seat][oldest] - metresToGo[seat][newest]
                finish.edgeSeconds = Double(atEdge[seat].filter { $0 }.count)
            }
            finish.touchedLate = lastTouchTick[seat].map { lastOnWaterTick[seat] - $0 < Self.touchWindowSeconds * rate } ?? false
            var diagnosis = BoatDiagnosis(tier: tiers[seat], start: start, finish: finish)
            diagnosis.episodes = episodes[seat]
            diagnosis.plan = plans[seat]
            diagnosis.planing = planing[seat]
            diagnosis.roundings = roundings[seat].observations()
            if let fell = fallTick[seat], seconds(race.tick - fell) >= Self.backOnSeconds { diagnosis.planing.fallsWatched += 1 }
            let window = Self.gybeFallWindow
            func isGybes(_ fall: Int, _ gybe: Int) -> Bool {
                seconds(fall - gybe) >= -window.before && seconds(fall - gybe) <= window.after
            }
            diagnosis.planing.gybesWithAFall = gybeTicks[seat].filter { gybe in fallTicks[seat].contains { isGybes($0, gybe) } }.count
            for (fall, cause) in zip(fallTicks[seat], fallCauses[seat]) {
                let cause = gybeTicks[seat].contains { isGybes(fall, $0) } ? .gybe : cause
                diagnosis.planing.fallsByCause[cause, default: 0] += 1
            }
            diagnosis.turnsOwed = turnsOwed[seat]
            diagnosis.legs = legLog[seat].enumerated().map { leg, log in
                var seen = LegObservation(kind: legKinds[leg], secondsBehind: seconds(log.entry - (first[leg] ?? log.entry)))
                if let end = log.end {
                    seen.seconds = seconds(end - log.entry)
                    seen.secondsLost = seconds(end - log.entry - (fastest[leg] ?? end - log.entry))
                }
                seen.turns = log.turns
                seen.falls = log.falls
                seen.gybes = log.gybes
                seen.calls = log.calls
                return seen
            }
            return diagnosis
        }
    }
}

/// One race's diagnoses, seat by seat.
public struct RaceDiagnosis: Hashable, Sendable {
    public var cell: BotRaceCell
    public var boats: [BoatDiagnosis]

    public init(cell: BotRaceCell, boats: [BoatDiagnosis]) {
        self.cell = cell
        self.boats = boats
    }
}

extension BotRaceHarness {
    /// `run(_:)` with a `RaceObserver` watching: the same race and the same result, and what the observer saw.
    public static func runDiagnosed(_ cell: BotRaceCell) throws -> (result: RaceResult, diagnosis: RaceDiagnosis) {
        var observer: RaceObserver?
        var sailed: Race?
        let result = try run(cell, cautiousSeats: cell.cautiousSeats, seatSkills: cell.seatSkills) { race, events in
            if observer == nil {
                observer = RaceObserver(race: race)
                sailed = race
            }
            observer?.record(race, events: events)
        }
        var boats = sailed.flatMap { race in observer?.boats(of: race, tiers: result.seats.map(\.tier)) } ?? []
        // The live mix's live bots by their two skills, as `AxesSummary.init(live:)` buckets them.
        if cell.profileMix == .live {
            for (seat, metrics) in result.seats.enumerated() where boats.indices.contains(seat) && metrics.profile == nil && !metrics.cautious {
                guard let handling = metrics.handling else { continue }
                boats[seat].skill = BotTier.holding(skill: metrics.skill)
                boats[seat].hand = AxesSummary.handlingTier(handling)
            }
        }
        return (result, RaceDiagnosis(cell: cell, boats: boats))
    }
}
