/// One boat as the umpire records her on one tick (#92): what the escape simulation sails her on from, and
/// what the rules read to say who had to keep clear then. Taken after the boats have moved and the overlaps
/// have been updated, before contacts: the world each incident is judged on.
public struct RecordedBoat: Sendable, Equatable {
    /// What the dynamics move.
    public var state: BoatDynamics.State
    /// The rudder her helm asked for (`Boat.desiredRudder`) and her held ease (`BoatInput.ease`): how she was
    /// steering, which the simulation sails her on with past now.
    public var desiredRudder: Double
    public var ease: Bool
    /// What steers her while the held rudder is centred (ADR 0007).
    public var autohelm: Autohelm?
    public var isTacking: Bool
    public var status: BoatStatus
    public var penaltyTurnsOwed: Int
    public var penaltyProgress: Double
    /// Where the wind she sailed in this tick blew from (`Boat.sailingWind`), radians.
    public var windDirection: Double
    /// The sailing wind's speed this tick, before any shadow (`Boat.sailingWind`), m/s.
    public var windSpeed: Double
    /// Her wind shadow this tick (`Boat.shadow`): with `windSpeed`, what her polar read (`Boat.polarWindSpeed(in:)`).
    public var shadow: Double
    /// The wind speed her autohelm's grooves read this tick (`Boat.averagedWindSpeed`, never nil once the race
    /// has stepped), m/s.
    public var grooveWindSpeed: Double
    /// The current that carried her this tick, m/s.
    public var current: Vec2

    /// `boat` as she is now, holding `ease`.
    public init(_ boat: Boat, ease: Bool) {
        state = BoatDynamics.State(position: boat.position, heading: boat.heading, speed: boat.speed, rudder: boat.rudder,
                                   boomSide: boat.boomSide, isPlaning: boat.isPlaning, spinnaker: boat.spinnaker)
        desiredRudder = boat.desiredRudder
        self.ease = ease
        autohelm = boat.autohelm
        isTacking = boat.isTacking
        status = boat.status
        penaltyTurnsOwed = boat.penaltyTurnsOwed
        penaltyProgress = boat.penaltyProgress
        windDirection = boat.sailingWind.direction
        windSpeed = boat.sailingWind.speed
        shadow = boat.shadow
        grooveWindSpeed = boat.averagedWindSpeed ?? boat.sailingWind.speed * boat.shadow
        current = boat.current
    }

    /// Her as seat `id`'s boat, with only the recorded fields set: every one the rules (`Rules.obligation`),
    /// the near-miss sweep and the dynamics read: the sailing wind and her shadow as they were.
    public func boat(id: Int) -> Boat {
        var boat = Boat(id: id, isPlayer: false, colorIndex: 0, position: state.position, heading: state.heading,
                        speed: state.speed, boomSide: state.boomSide)
        boat.rudder = state.rudder
        boat.desiredRudder = desiredRudder
        boat.isPlaning = state.isPlaning
        boat.spinnaker = state.spinnaker
        boat.autohelm = autohelm
        boat.isTacking = isTacking
        boat.status = status
        boat.penaltyTurnsOwed = penaltyTurnsOwed
        boat.penaltyProgress = penaltyProgress
        boat.sailingWind = Wind(direction: windDirection, speed: windSpeed)
        boat.shadow = shadow
        boat.averagedWindSpeed = grooveWindSpeed
        boat.current = current
        return boat
    }
}

/// Two boats' recorded track through now (#92), oldest first, one entry a tick: each boat as the umpire
/// recorded her (`RecordedBoat`) and whether they were overlapped as of the last point of certainty. What
/// `Rules.judge` reads, through `EscapeSimulation`; the race builds it from `UmpireState`, a test by hand.
public struct PairTrack: Sendable, Equatable {
    public let seats: SeatPair
    /// The lower seat's boat, by tick.
    public var low: [RecordedBoat]
    /// The higher seat's boat, by tick.
    public var high: [RecordedBoat]
    /// Overlapped as of the last point of certainty, by tick.
    public var overlapped: [Bool]

    public init(seats: SeatPair, low: [RecordedBoat], high: [RecordedBoat], overlapped: [Bool]) {
        precondition(low.count == high.count && high.count == overlapped.count, "a pair track has one entry a tick")
        self.seats = seats
        self.low = low
        self.high = high
        self.overlapped = overlapped
    }

    /// Ticks recorded, the last being now.
    public var count: Int { overlapped.count }

    /// `seat`'s recorded boat `k` ticks after the first.
    func recorded(_ seat: Int, _ k: Int) -> RecordedBoat { seat == seats.low ? low[k] : high[k] }

    /// `recorded(seat, k)` as her boat (`RecordedBoat.boat(id:)`).
    func boat(_ seat: Int, _ k: Int) -> Boat { recorded(seat, k).boat(id: seat) }
}

/// The escape simulation (#9, #92): whether the boat that had to keep clear could have, sailing her best
/// manoeuvre with the real boat dynamics. It judges *room* under rules 15 and 16.1: a right-of-way boat that
/// has just acquired right of way (15), or changes course (16.1), must give the other room to keep clear, and
/// if no manoeuvre would have kept her clear, the right-of-way boat broke that rule and the other is exonerated
/// (43.1(b)). The authoritative race's alone: a prediction never runs it (ADR 0005).
///
/// - The keep-clear boat is sailed on from her recorded state by each of the rules configuration's
///   `escape.candidates` in turn (fixed order, first escape wins: deterministic by construction, ADR 0002),
///   held for `escape.horizon`: a centred rudder is her autohelm, which follows the shifts as it did (#219).
///   Each tick she sails in the wind and water she recorded that tick, which the race sampled from its
///   `WindField` and `CurrentField` at her (shadow included), through `BoatDynamics.advance`: sailed on her own
///   inputs she follows her own track to the bit. Past now, the last tick's.
/// - The right-of-way boat follows her recorded track (her autohelm's turns included: a turn following a
///   shift is a course change like any other, #228), and past now sails on as she was steering, her held
///   rudder or her autohelm, in the wind and water of now: a luff under way goes on.
/// - A candidate escapes when, on every tick, the hulls neither touch nor would be hit by the right-of-way
///   boat's near-miss sweep (`RulesConfig.NearMissSweep.hits`): kept clear as the umpire calls it (#88).
///   Other boats, marks and land aren't in it: room is between the pair.
public struct EscapeSimulation: Sendable {
    public let track: PairTrack
    public let escape: RulesConfig.Escape
    /// `escape.changesCourse`, radians a second.
    public let changesCourse: Double
    public let sweep: RulesConfig.NearMissSweep
    public let boatClass: BoatClass

    /// Nil for a rules configuration with no "changes course" test (schema 1 to 3): no escape simulation.
    public init?(track: PairTrack, rules: RulesConfig, boatClass: BoatClass) {
        guard let changesCourse = rules.incidents.escape.changesCourse else { return nil }
        self.track = track
        escape = rules.incidents.escape
        self.changesCourse = changesCourse
        sweep = rules.incidents.nearMissSweep
        self.boatClass = boatClass
    }

    /// The call for an incident whose Section A (or rule 21) call is `obligation` (`Rules.obligation`): the
    /// right-of-way boat breaks rule 15 or 16.1 instead, the keep-clear boat exonerated (43.1(b)), when she
    /// took the other's room; otherwise `obligation`. Ticks are counted back from now, the track's last.
    ///
    /// - When the keep-clear boat began to have to keep clear is read off the track: the first tick of the
    ///   run through now on which `Rules.obligation` names her, or none if it names her all the way back.
    /// - Rule 15: right of way acquired within `escape.initially`, not because of the keep-clear boat's own
    ///   actions (her tack or gybe, starting to tack, to take a penalty or to return: rule 15's "unless"), and
    ///   no escape from `escape.startTickOffset` ticks after it.
    /// - Rule 16.1: the right-of-way boat's heading turns faster than `changesCourse` on a tick since she
    ///   had right of way, late enough that the simulation from the first such tick plus the offset reaches
    ///   now; no escape from there against her track, and an escape had she held her course from the tick
    ///   before it (first seen in the step to now, so no tick to answer in before it: clear of that course
    ///   now, and an escape from now, #273). Without that, the keep-clear boat was failing to keep clear
    ///   anyway, and her course change (avoiding contact, say) took nothing from her.
    func verdict(_ obligation: Verdict, course: CourseLayout) -> Verdict {
        let keepClear = obligation.offender, rightOfWay = obligation.victim
        let last = track.count - 1
        guard last >= 1, track.seats == SeatPair(keepClear, rightOfWay) else { return obligation }
        let hull = boatClass.hull
        let horizon = RulesConfig.ticks(escape.horizon), offset = escape.startTickOffset
        func obliged(_ k: Int) -> Int? {
            Rules.obligation(track.boat(track.seats.low, k), track.boat(track.seats.high, k),
                             overlapped: track.overlapped[k], course: course, hull: hull)?.offender
        }
        var since = last
        while since > 0, obliged(since - 1) == keepClear { since -= 1 }
        let acquired = since > 0 ? since : nil

        if let acquired, last - acquired <= RulesConfig.ticks(escape.initially),
           !isOwnAction(of: keepClear, at: acquired, course: course),
           !canEscape(keepClear, from: acquired + offset - 1, of: rightOfWay) {
            return Verdict(rule: .acquiringRightOfWay, offender: rightOfWay, victim: keepClear, exonerated: [keepClear])
        }

        let first = max(acquired ?? 1, last - horizon - offset + 1, 1)
        guard first <= last, let change = (first...last).first(where: { turnRate(of: rightOfWay, at: $0) > changesCourse })
        else { return obligation }
        let start = change + offset - 1
        guard !canEscape(keepClear, from: start, of: rightOfWay),
              canEscape(keepClear, from: start, of: rightOfWay, heldFrom: change - 1)
        else { return obligation }
        return Verdict(rule: .changingCourse, offender: rightOfWay, victim: keepClear, exonerated: [keepClear])
    }

    /// Radians a second `seat`'s heading turned through the step to tick `k` (k ≥ 1).
    private func turnRate(of seat: Int, at k: Int) -> Double {
        abs(wrapAngle(track.recorded(seat, k).state.heading - track.recorded(seat, k - 1).state.heading))
            * Double(Race.tickRate)
    }

    /// Whether `seat` herself changed who had to keep clear through the step to tick `k`: she began to tack,
    /// her boom crossed, or she began to take a penalty or to return (rule 21).
    private func isOwnAction(of seat: Int, at k: Int, course: CourseLayout) -> Bool {
        let before = track.boat(seat, k - 1), after = track.boat(seat, k)
        return (after.isTacking && !before.isTacking) || after.boomSide != before.boomSide
            || (after.isTakingPenalty && !before.isTakingPenalty)
            || (course.isReturning(after) && !course.isReturning(before))
    }

    /// `seat`'s boat on each of `ticks` (ascending, from one recorded): recorded through now, then sailed on
    /// from now as she was steering (her held rudder or her autohelm, and her ease) in the wind and water of now.
    private func path(of seat: Int, over ticks: ClosedRange<Int>) -> [Boat] {
        let last = track.count - 1
        let now = track.recorded(seat, last)
        var ahead = now.boat(id: seat)
        return ticks.map { k in
            guard k > last else { return track.boat(seat, k) }
            sail(&ahead, ease: now.ease, in: now)
            return ahead
        }
    }

    /// `seat`'s boat on each of `ticks` had she held her course from tick `k`: in a straight line at her
    /// velocity over the ground then.
    private func path(of seat: Int, heldFrom k: Int, over ticks: ClosedRange<Int>) -> [Boat] {
        let held = track.boat(seat, k)
        return ticks.map { tick in
            var ahead = held
            ahead.position += held.velocityOverGround * (Double(tick - k) * Race.dt)
            return ahead
        }
    }

    /// Whether any candidate sails `seat` clear of `other` on every tick of the horizon after tick `start`,
    /// from her recorded state then: `other` on her `path`, or had she held her course from tick `heldFrom`.
    /// If `start` isn't before now, she had no tick to answer in before the incident: against `other`'s path,
    /// no escape; against her held course (#273), `seat` must be clear of it on her own `path` from now through
    /// `start` (just now, with an offset of 1), and a candidate escape from there.
    private func canEscape(_ seat: Int, from start: Int, of other: Int, heldFrom: Int? = nil) -> Bool {
        let last = track.count - 1
        guard start >= 0, start < last || heldFrom != nil else { return false }
        // Her own path from now through `start`: the ticks she can't answer in from the incident on.
        let waiting = start < last ? [] : path(of: seat, over: last...start)
        let ticks = (start + 1 - waiting.count)...(start + RulesConfig.ticks(escape.horizon))
        let outline = boatClass.hull.outline
        let others = heldFrom.map { path(of: other, heldFrom: $0, over: ticks) } ?? path(of: other, over: ticks)
        let otherHulls = others.map { $0.hull(outline: outline) }
        // The other's sweep on each tick, worked out the first time `seat` comes within its reach.
        var swept = [RulesConfig.NearMissSweep.Swept?](repeating: nil, count: others.count)
        // Kept clear on the `n`th of `ticks` as the umpire calls it: no contact, and no hit by the other's sweep.
        func isClear(_ boat: Boat, on n: Int) -> Bool {
            if Collision.penetration(boat.hull(outline: outline), otherHulls[n]) != nil { return false }
            guard sweep.canReach(others[n], boat, hull: boatClass.hull) else { return true }
            if swept[n] == nil { swept[n] = sweep.swept(others[n], hull: boatClass.hull) }
            return !sweep.hits(swept[n]!, boat, hull: boatClass.hull)
        }
        guard waiting.enumerated().allSatisfy({ isClear($1, on: $0) }) else { return false }
        let from = waiting.last ?? track.boat(seat, start)
        let environments = ticks.dropFirst(waiting.count).map { track.recorded(seat, min($0, last)) }
        return escape.candidates.contains { candidate in
            var boat = from
            let rudder = candidate.rudderValue
            if abs(rudder) > Autohelm.deadBand {
                boat.autohelm = nil
                boat.desiredRudder = rudder
            } else if boat.autohelm == nil {
                let environment = environments[0]
                boat.sailingWind = Wind(direction: environment.windDirection, speed: environment.windSpeed)
                boat.shadow = environment.shadow
                boat.averagedWindSpeed = environment.grooveWindSpeed
                boat.autohelm = Autohelm.engage(sailingAngle: boat.sailingAngle, tws: environment.grooveWindSpeed,
                                                boatClass: boatClass).autohelm
            }
            for n in environments.indices {
                sail(&boat, ease: candidate.ease, in: environments[n])
                if !isClear(boat, on: waiting.count + n) { return false }
            }
            return true
        }
    }

    /// One tick of `boat` in the wind and water `environment` recorded, as `Race` sails her: the autohelm's
    /// rudder, the dynamics, and the tap it may be sailing ending as the boom crosses.
    private func sail(_ boat: inout Boat, ease: Bool, in environment: RecordedBoat) {
        boat.sailingWind = Wind(direction: environment.windDirection, speed: environment.windSpeed)
        boat.shadow = environment.shadow
        boat.averagedWindSpeed = environment.grooveWindSpeed
        boat.current = environment.current
        let tws = boat.polarWindSpeed(in: boatClass)
        if let helm = boat.autohelm {
            boat.desiredRudder = helm.rudder(sailingAngle: boat.sailingAngle, boomSide: boat.boomSide, tws: tws,
                                             grooveTWS: environment.grooveWindSpeed, boatClass: boatClass)
        }
        let moved = BoatDynamics.advance(
            BoatDynamics.State(position: boat.position, heading: boat.heading, speed: boat.speed, rudder: boat.rudder,
                               boomSide: boat.boomSide, isPlaning: boat.isPlaning, spinnaker: boat.spinnaker),
            control: BoatDynamics.Control(rudder: boat.desiredRudder, ease: ease, sailing: true),
            env: BoatDynamics.Environment(windDirection: boat.sailingWind.direction, windSpeed: tws, current: boat.current,
                                          shadow: boat.speedShadow(in: boatClass)),
            boatClass: boatClass, dt: Race.dt)
        if moved.boomSide != boat.boomSide { boat.autohelm?.isTapping = false }
        boat.position = moved.position
        boat.heading = moved.heading
        boat.speed = moved.speed
        boat.rudder = moved.rudder
        boat.boomSide = moved.boomSide
        boat.isPlaning = moved.isPlaning
        boat.spinnaker = moved.spinnaker
    }
}

/// The umpire's recorded track (#92): each boat's `RecordedBoat` and each pair's overlap as of the last point
/// of certainty, tick by tick, over the last `capacity` ticks (`RulesConfig.Escape.recordedTicks`). Fixed-size
/// ring buffers, one per boat and one for the overlaps, each tick in its slot; filled in seat order on every
/// tick the authoritative race steps, so a replay rebuilds it bit for bit (ADR 0002). A tick that doesn't
/// follow the last recorded one (an import) starts it afresh.
struct EscapeRecorder: Sendable, Equatable {
    private var capacity = 0
    /// The newest tick recorded.
    private var newestTick = 0
    /// Ticks recorded, at most `capacity`.
    private var count = 0
    /// By seat, then by slot.
    private var boats: [[RecordedBoat]] = []
    /// By slot: each pair's overlap, by `OverlapTracker.index`.
    private var overlaps: [[Bool]] = []

    /// Records tick `tick`'s boats, their held inputs and the overlaps (by `OverlapTracker.index`).
    mutating func record(tick: Int, boats fleet: [Boat], inputs: [BoatInput], overlaps certain: [Bool], capacity size: Int) {
        if count == 0 || tick != newestTick + 1 || size != capacity || fleet.count != boats.count {
            self = EscapeRecorder()
            capacity = max(size, 1)
            boats = fleet.indices.map { Array(repeating: RecordedBoat(fleet[$0], ease: inputs[$0].ease), count: capacity) }
            overlaps = Array(repeating: certain, count: capacity)
        }
        let slot = self.slot(tick)
        for seat in fleet.indices { boats[seat][slot] = RecordedBoat(fleet[seat], ease: inputs[seat].ease) }
        overlaps[slot] = certain
        newestTick = tick
        count = min(count + 1, capacity)
    }

    /// Seats `a` and `b`'s track over every tick recorded, through the newest; nil if nothing is.
    func track(_ a: Int, _ b: Int) -> PairTrack? {
        guard count > 0, boats.indices.contains(a), boats.indices.contains(b) else { return nil }
        let pair = SeatPair(a, b)
        let slots = (newestTick - count + 1...newestTick).map(slot)
        let index = OverlapTracker.index(pair.low, pair.high, seats: boats.count)
        return PairTrack(seats: pair, low: slots.map { boats[pair.low][$0] }, high: slots.map { boats[pair.high][$0] },
                         overlapped: slots.map { overlaps[$0][index] })
    }

    private func slot(_ tick: Int) -> Int { ((tick % capacity) + capacity) % capacity }
}
