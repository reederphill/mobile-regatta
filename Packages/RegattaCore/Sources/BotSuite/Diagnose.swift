import Foundation
import RegattaBots
import RegattaCore

// `regatta-botsuite --diagnose` (#471): why boats start late, what a penalty turn costs them and why they don't
// finish. It watches a race from the harness, as `RaceTally` does: the race's public state after each tick and that
// tick's events. It reads no bot and changes nothing a bot sees or does, so a race sails the same with it or without
// it (`BotSuiteDiagnoseTests.observingLeavesTheRaceBitIdentical`). This file is what one race gives: one
// `BoatDiagnosis` a boat, and the rules that name a cause from it. `DiagnoseReport.swift` pools them into the tables.

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
    /// From the call to 30° into the first turn; nil if she never got there.
    public var secondsToStarted: Double?
    /// From there to owing nothing.
    public var secondsTurning: Double?
    /// From owing nothing to 90 % of her target speed (`RaceObserver.targetSpeed`); nil if she was called again
    /// first, left the water, or took longer than `RaceObserver.recoverySeconds`.
    public var secondsRecovering: Double?
    /// Its started turns given up, by cause.
    public var resets: [ResetCause: Int] = [:]
    /// Each turn served: seconds from its clock (the call, or the turn before it served) to served.
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

/// What `--diagnose` saw of one boat in one race.
public struct BoatDiagnosis: Hashable, Sendable {
    public var tier: BotTier
    public var start: StartObservation
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

    private let rate = Race.tickRate
    private let line: CourseLayout.Line
    private let lineDirection: Vec2
    private let legs: Int
    private let noGo: Double
    private let hullLength: Double

    private var starts: [StartObservation]
    private var startTicks: [Int?]
    private var episodes: [[PenaltyEpisode]]
    private var turnsOwed: [Int]
    private var turnsServed: [Int]

    /// The episode each seat has open: its first call's tick, the current turn's clock, and its started turn, if any.
    private struct Open {
        var callTick: Int
        var clockTick: Int
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

    public init(race: Race) {
        let count = race.boats.count
        line = race.course.startLine
        lineDirection = (line.committee.position - line.pin.position).normalized
        legs = race.course.legs.count
        noGo = BoatDynamics.noGoAngle(race.boatClass.polar)
        hullLength = race.boatClass.hull.length
        starts = Array(repeating: StartObservation(), count: count)
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
        for event in events { record(event, race) }
        for (seat, boat) in race.boats.enumerated() {
            defer { progress[seat] = boat.penaltyProgress }
            guard !boat.isGhost else { continue }
            lastOnWaterTick[seat] = tick
            if startTicks[seat] == nil { recordStart(seat, boat, race) }
            if var turn = open[seat], turn.isStarted, !turn.heldOver, boat.penaltyProgress != 0,
               race.heldInputs[seat].rudderValue * (boat.penaltyProgress < 0 ? -1 : 1) >= Self.heldOverRudder {
                turn.heldOver = true
                open[seat] = turn
            }
            recordRecovery(seat, boat, race)
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
        switch event.kind {
        case .ocsNotice(let seat): starts[seat].ocs = true
        case .started(let seat):
            if startTicks[seat] == nil { startTicks[seat] = tick }
        case .ruleCall(let call) where call.turnsOwed > 0: recordCall(call.offender, race)
        case .markTouch(let seat, _):
            lastTouchTick[seat] = tick
            recordCall(seat, race)
        case .obstructionContact(let seat, _): lastTouchTick[seat] = tick
        case .penaltyStarted(let seat):
            guard var turn = open[seat] else { break }
            if turn.startedTick == nil { turn.startedTick = tick }
            turn.isStarted = true
            turn.heldOver = false
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
            turnsServed[seat] += 1
            episodes[seat][index].turnsServed += 1
            episodes[seat][index].turnSeconds.append(seconds(tick - turn.clockTick))
            turn.clockTick = tick
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
        case .tacked(let seat), .gybed(let seat):
            guard startTicks[seat] == nil, !race.boats[seat].isTakingPenalty,
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
        if var turn = open[seat] {
            turn.owed += 1
            open[seat] = turn
            episodes[seat][episodes[seat].count - 1].calls += 1
            return
        }
        let boat = race.boats[seat]
        let phase = PenaltyPhase.at(tick: race.tick, status: boat.status, leg: boat.legIndex, legs: legs)
        episodes[seat].append(PenaltyEpisode(phase: phase, callSeconds: seconds(race.tick)))
        open[seat] = Open(callTick: race.tick, clockTick: race.tick)
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

    private func seconds(_ ticks: Int) -> Double { Double(ticks) / Double(rate) }

    /// Each seat's diagnosis once the race is sailed; `tiers` are the seats' tiers.
    public func boats(of race: Race, tiers: [BotTier]) -> [BoatDiagnosis] {
        race.boats.indices.map { seat in
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
            diagnosis.turnsOwed = turnsOwed[seat]
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
        let boats = sailed.flatMap { race in observer?.boats(of: race, tiers: result.seats.map(\.tier)) } ?? []
        return (result, RaceDiagnosis(cell: cell, boats: boats))
    }
}
