/// What the umpire remembers through a race: held by the authoritative race only (`Race.Mode`), never
/// by a prediction, and never sent to clients or carried in a `WorldSnapshot`.
///
/// Its incident memory (#88): each pair's open incident, one per pair until the boats separate by the rules
/// configuration's `incidents.separation`. Its rule 18 memory (#91): each pair's record at the mark they are
/// both racing to, and each boat's presence in that mark's zone. Its recorded track (#92): every boat over the
/// last few seconds, what the escape simulation reads (`EscapeSimulation`). Its protest matching (#94):
/// which incident a protest is about, read from the race's incident index, so it holds no state of its own
/// and survives an import. Its rule 17 memory (#345): each pair's record of a leeward boat that came up from
/// clear astern (`ProperCourseRecord`).
public struct UmpireState: Sendable, Equatable {
    /// Each pair's open incident, by id: opened by a contact or a near miss, closed when the pair
    /// separates. Looked up by pair, never iterated (ADR 0002).
    private var openIncidents: [SeatPair: Int] = [:]
    /// Rule 18 between each pair at the mark they are both racing to, from the tick the first of them reaches
    /// its zone until it no longer applies between them there (`MarkRoomPair`). Looked up by pair, never
    /// iterated (ADR 0002).
    private var markRoomPairs: [SeatPair: MarkRoomPair] = [:]
    /// Each racing boat's presence in the zone of the mark she is racing to (`ZonePresence`), by seat. Looked
    /// up by seat, never iterated (ADR 0002).
    private var zonePresence: [Int: ZonePresence] = [:]
    /// Every boat and every pair's overlap over the last `RulesConfig.Escape.recordedTicks` ticks (#92): fixed-size
    /// ring buffers, filled in seat order, read by pair. Kept apart from the rule 18 memory: room to keep clear
    /// is judged from the boats alone.
    private var recorder = EscapeRecorder()
    /// Rule 44.1(a) (#90): each boat whose touch of a mark of her leg cost her a turn, by seat, with the seats
    /// within the incident separation of her when she touched it that haven't separated from her since, in
    /// seat order. A foul she commits against one of them is the same incident, and costs no further turn.
    /// Looked up by seat, never iterated (ADR 0002). Kept through an import, as the open incidents are: the
    /// next tick forgets the neighbours that have separated (`Race.forgetSeparatedMarkTouches`).
    private var markTouchNeighbours: [Int: [Int]] = [:]
    /// Rule 17 (#345): each pair's record while it holds (`ProperCourseRecord`). Looked up by pair, never iterated
    /// (ADR 0002). Forgotten at an import, with the recorded track it is opened from.
    private var properCourseRecords: [SeatPair: ProperCourseRecord] = [:]

    public init() {}

    // MARK: - Recorded track (#92)

    /// Records tick `tick`: each boat as she is now with her held input's ease (`inputs`, by seat) and each
    /// pair's overlap as of the last point of certainty (`overlaps`, by `OverlapTracker.index`), keeping the
    /// last `ticks` ticks.
    mutating func record(tick: Int, boats: [Boat], inputs: [BoatInput], overlaps: [Bool], keeping ticks: Int) {
        recorder.record(tick: tick, boats: boats, inputs: inputs, overlaps: overlaps, capacity: ticks)
    }

    /// Seats `a` and `b`'s recorded track, oldest first through the newest tick recorded; nil before any.
    public func track(_ a: Int, _ b: Int) -> PairTrack? { recorder.track(a, b) }

    /// Forgets the recorded track and the rule 17 records read from it: after an import (`Race.importSnapshot`) the
    /// boats' past isn't the one it holds.
    mutating func forgetTrack() {
        recorder = EscapeRecorder()
        properCourseRecords = [:]
    }

    /// The id of the incident open between `pair`'s boats, if they haven't separated since it opened.
    func openIncident(_ pair: SeatPair) -> Int? { openIncidents[pair] }

    /// Holds incident `id` open for `pair` until they separate.
    mutating func open(_ id: Int, for pair: SeatPair) { openIncidents[pair] = id }

    /// Forgets `pair`'s open incident: they have separated.
    mutating func close(_ pair: SeatPair) { openIncidents[pair] = nil }

    /// Keeps only the open incidents that are still their pair's latest in `incidents`: after an import
    /// (`Race.importSnapshot`) replaces the race's incidents, one the new index doesn't end on can't be open.
    mutating func keepOpenIncidents(in incidents: IncidentIndex) {
        var kept: [SeatPair: Int] = [:]
        for pair in incidents.pairs {
            if let id = openIncidents[pair], incidents.latest(between: pair.low, and: pair.high)?.id == id {
                kept[pair] = id
            }
        }
        openIncidents = kept
    }

    // MARK: - Rule 44.1(a) (#90)

    /// The seats a mark touch that cost seat `seat` a turn shares an incident with: those within the separation
    /// of her at the touch that haven't separated from her since. Empty when she has none.
    func markTouchNeighbours(of seat: Int) -> [Int] { markTouchNeighbours[seat] ?? [] }

    /// Sets the seats seat `seat`'s mark touch shares an incident with (`markTouchNeighbours(of:)`), in seat
    /// order: a new touch's, or what is left of them. None forgets her touch.
    mutating func setMarkTouchNeighbours(_ seats: [Int], of seat: Int) {
        markTouchNeighbours[seat] = seats.isEmpty ? nil : seats
    }

    // MARK: - Protests (#94)

    /// The incident seat `protester`'s protest of `protested` at tick `tick` is about: the pair's latest
    /// incident, when its last activity (its opening, or the last boat contact recorded in it) was no more than
    /// `window` ticks before the protest, inclusive at both ends, the same tick matching. Nil otherwise: "no
    /// call". Reads `incidents`, the race's index, which a snapshot carries, so nothing here is lost at an
    /// import. The race matches a protest after its tick's calls (`Race.step`), so an incident opened on the
    /// protest's own tick is in `incidents` and matches.
    func matchProtest(by protester: Int, of protested: Int, atTick tick: Int, window: Int,
                      in incidents: IncidentIndex) -> Int? {
        guard let incident = incidents.latest(between: protester, and: protested) else { return nil }
        let lastActivity = max(incident.tick, incidents.lastContactTick(inIncident: incident.id) ?? incident.tick)
        let since = tick - lastActivity
        return (0...window).contains(since) ? incident.id : nil
    }

    // MARK: - Rule 17 (#345)

    /// The rule 17 record between `pair`'s boats, while it holds: which of them is the leeward boat held to her
    /// proper course, against which windward boat.
    public func properCourse(_ pair: SeatPair) -> ProperCourseRecord? { properCourseRecords[pair] }

    /// Sets `pair`'s rule 17 record, or forgets it: for tests, which place boats by snapshot (forgetting the umpire's
    /// memory) and need a record without sailing one up from astern. The next update ends it unless it holds.
    mutating func setProperCourse(_ record: ProperCourseRecord?, for pair: SeatPair) { properCourseRecords[pair] = record }

    /// One tick of rule 17 (#345), after the boats have moved, the overlaps and rule 18 have been updated and the
    /// tick recorded (`record`), in seat-pair order. Nothing under a rules configuration without rule 17's limits.
    ///
    /// - A record opens for seats `a` < `b`, both racing, on the tick their overlap (as of the last point of
    ///   certainty) begins, when rule 11 holds between them (same tack, neither tacking: `Rules.rightOfWay`), rule
    ///   18 isn't in force between them (`ProperCourseTick.isMarkRoomInForce`), their hulls are within the limits'
    ///   `distance` now and on the tick the hulls first showed the overlap, and on the tick before that (the last
    ///   point of certainty back), on the same tack and neither tacking, the leeward boat was clear astern of the
    ///   windward one (`Rules.isClearAstern`): she made the overlap. Not if the windward boat came up from astern,
    ///   or neither was astern (an overlap through a boat between, or one from another tack).
    /// - It holds while both are racing, overlapped as of the last point of certainty within `distance`, rule 11
    ///   still on the same windward boat, and rule 18 not in force; it ends for good on the first tick any fails
    ///   (separation, a tack, rule 18 taking over). A new overlap from clear astern opens a new one.
    mutating func updateProperCourse(_ tick: ProperCourseTick) {
        guard let limits = tick.rules.incidents.properCourse else { return }
        let hull = tick.boatClass.hull
        let reach = limits.distance.metres(hullLength: hull.length)
        let margin = RulesConfig.ticks(tick.rules.incidents.lastPointOfCertainty)
        let anyRecord = !properCourseRecords.isEmpty
        let n = tick.boats.count
        for a in 0..<n {
            for b in (a + 1)..<n {
                let pair = SeatPair(a, b)
                let (boatA, boatB) = (tick.boats[a], tick.boats[b])
                // The hulls are no further apart than the centres less a hull length.
                let near = (boatA.position - boatB.position).length - hull.length <= reach
                if anyRecord, let held = properCourseRecords[pair] {
                    if !(near && holds(held, a, b, tick, reach: reach)) { properCourseRecords[pair] = nil }
                    continue
                }
                guard near, let record = opens(a, b, tick, reach: reach, margin: margin) else { continue }
                properCourseRecords[pair] = record
            }
        }
    }

    /// Whether the rule 11 relation of seats `a` < `b` now (as `updateProperCourse` reads it) has `windward` keeping
    /// clear of the other within `reach` metres, both racing, rule 18 not in force.
    private func isRule11(_ a: Int, _ b: Int, _ tick: ProperCourseTick, reach: Double) -> RightOfWay? {
        let (boatA, boatB) = (tick.boats[a], tick.boats[b])
        guard boatA.status == .racing, boatB.status == .racing, tick.overlaps.isOverlapped(a, b),
              !tick.isMarkRoomInForce(a, b, umpire: self),
              let right = Rules.rightOfWay(boatA, boatB, overlapped: true, hull: tick.boatClass.hull),
              right.rule == .windwardLeeward,
              Collision.distance(convex: tick.hulls[a], simplePolygon: tick.hulls[b]) <= reach
        else { return nil }
        return right
    }

    private func holds(_ record: ProperCourseRecord, _ a: Int, _ b: Int, _ tick: ProperCourseTick, reach: Double) -> Bool {
        isRule11(a, b, tick, reach: reach)?.keepClear == record.windward
    }

    private func opens(_ a: Int, _ b: Int, _ tick: ProperCourseTick, reach: Double, margin: Int) -> ProperCourseRecord? {
        let index = OverlapTracker.index(a, b, seats: tick.boats.count)
        guard tick.overlaps.isOverlapped(a, b), recorder.overlapped(index, ticksBack: 1) == false,
              let right = isRule11(a, b, tick, reach: reach)
        else { return nil }
        let windward = right.keepClear, leeward = windward == a ? b : a
        guard let leewardBefore = recorder.recorded(leeward, ticksBack: margin),
              let windwardBefore = recorder.recorded(windward, ticksBack: margin),
              let leewardFirst = recorder.recorded(leeward, ticksBack: margin - 1),
              let windwardFirst = recorder.recorded(windward, ticksBack: margin - 1)
        else { return nil }
        let (now, l, w) = (tick.boats, leewardBefore.boat(id: leeward), windwardBefore.boat(id: windward))
        let outline = tick.boatClass.hull.outline
        guard l.boomSide == now[leeward].boomSide, w.boomSide == now[windward].boomSide, !l.isTacking, !w.isTacking,
              Rules.isClearAstern(l, of: w, hull: tick.boatClass.hull),
              Collision.distance(convex: leewardFirst.boat(id: leeward).hull(outline: outline),
                                 simplePolygon: windwardFirst.boat(id: windward).hull(outline: outline)) <= reach
        else { return nil }
        return ProperCourseRecord(leeward: leeward, windward: windward, tick: tick.tick)
    }

    // MARK: - Rule 18 (#91)

    /// The rule 18 record between `pair`'s boats (`MarkRoomRecord`): which of them is entitled to mark-room
    /// from the other now, or nil when neither is.
    public func markRoom(_ pair: SeatPair) -> MarkRoomRecord? {
        guard let state = markRoomPairs[pair], let owed = state.owed else { return nil }
        return MarkRoomRecord(mark: state.mark.name, entitled: owed.entitled, owing: owed.owing, rule: owed.rule,
                              firstInZone: state.firstInZone, overlappedAtZoneEntry: state.overlappedAtZoneEntry)
    }

    /// One tick of rule 18 (#91), after the boats have moved and the overlaps have been updated: each boat's
    /// presence in her mark's zone, then each pair's record, in seat order. Returns the notices of the records
    /// made this tick (`RaceEvent.Kind.markRoomNotice`), in seat-pair order.
    ///
    /// - A boat is in the zone from the tick any part of her hull reaches it; she has left it once all of it
    ///   has been out for the last point of certainty, so a hull skimming the circle doesn't flicker.
    /// - 18.2(a): when the first of a pair reaches the zone of the mark they are both racing to
    ///   (`CourseLayout.markZone(of:hull:)`), if they are overlapped as of the last point of certainty (18.2(e))
    ///   the outside boat owes the inside one (`Rules.insideBoat`: on the other's side towards the mark)
    ///   mark-room; otherwise the one that hasn't reached it owes the other. Not on opposite tacks on a beat (18.1(a)). An overlap gained
    ///   or broken later changes nothing (18.2(b)).
    /// - A record ends when mark-room has been given (`RulesConfig.MarkRoomGiven`, `MarkRoomPair.isRoomGiven`),
    ///   when the entitled boat passes head to wind (her boom crossing with the wind forward of the beam), or
    ///   when she has left the zone. The pair's memory ends with it when both have left the mark astern (their
    ///   legs moved on), when neither has been in its zone for the last point of certainty (18.1), or when
    ///   either stops racing.
    /// - 18.2(c): with no record, overlapped (as of the last point of certainty) while rule 18 applies between
    ///   them (`Rules.markRoomApplies`), the outside boat owes the inside one; never once mark-room has been
    ///   given, when rule 18 no longer applies between them.
    /// - 18.3: a boat that passes head to wind from port to starboard in the zone of a mark left to port loses
    ///   18.2 against a boat on starboard fetching it (`Rules.isFetchingOnStarboard`: sailing the groove, she
    ///   would pass to windward of it): the pair's record ends, and 18.2 no longer applies between them. If that
    ///   boat has been on starboard since entering the zone, the tacker owes her mark-room once that boat is
    ///   overlapped inside the tacker (RRS 18.3(b): "if the other boat becomes overlapped inside her"). A tacker
    ///   that ends up inside is owed nothing: 18.2 no longer applies between them.
    mutating func updateMarkRoom(_ tick: MarkRoomTick) -> [RaceEvent.Kind] {
        let margin = RulesConfig.ticks(tick.rules.incidents.lastPointOfCertainty)
        updateZonePresence(tick, margin: margin)
        // By seat, and whether any pair holds a record yet: most pairs, most ticks, are nowhere near a zone.
        let presence = tick.boats.indices.map { zonePresence[$0] }
        let anyPair = !markRoomPairs.isEmpty
        var notices: [RaceEvent.Kind] = []
        let n = tick.boats.count
        for a in 0..<n {
            for b in (a + 1)..<n {
                let pair = SeatPair(a, b)
                var began: MarkRoomPair.Owed?
                if anyPair, var state = markRoomPairs[pair] {
                    let holds = state.advance(a, b, tick, margin: margin, presence: { presence[$0] }, began: &began)
                    markRoomPairs[pair] = holds ? state : nil
                } else if presence[a] != nil || presence[b] != nil,
                          let state = MarkRoomPair.begin(a, b, tick, presence: { presence[$0] }) {
                    markRoomPairs[pair] = state
                    began = state.owed
                }
                if let began, let mark = markRoomPairs[pair]?.mark.name {
                    notices.append(.markRoomNotice(boat: began.entitled, entitledOver: began.owing, mark: mark))
                }
            }
        }
        return notices
    }

    /// Each seat's `ZonePresence` for this tick: begun on the tick any part of her hull is in the zone of the
    /// mark she is racing to, ended once all of it has been out for `margin` ticks, or at once when she is
    /// racing to another mark or not racing.
    private mutating func updateZonePresence(_ tick: MarkRoomTick, margin: Int) {
        for seat in tick.boats.indices {
            guard let zone = tick.zones[seat] else {
                zonePresence[seat] = nil
                continue
            }
            let starboard = tick.boats[seat].tack == .starboard
            if var held = zonePresence[seat], held.mark == zone.mark.name {
                held.ticksOut = zone.isIn ? 0 : held.ticksOut + 1
                held.starboardSinceEntry = held.starboardSinceEntry && starboard
                zonePresence[seat] = held.ticksOut >= margin ? nil : held
            } else {
                zonePresence[seat] = zone.isIn
                    ? ZonePresence(mark: zone.mark.name, enteredTick: tick.tick, starboardSinceEntry: starboard, ticksOut: 0)
                    : nil
            }
        }
    }
}

/// Rule 17 between one pair (#345): `leeward` became overlapped to leeward of `windward` from clear astern within
/// two hull lengths (the rules configuration's `incidents.properCourse.distance`), so while it holds she shall not
/// sail above her proper course (`ProperCourse`). Held by `UmpireState` (`updateProperCourse`); umpire memory only,
/// never in a snapshot, on the wire or in the digest.
public struct ProperCourseRecord: Sendable, Equatable {
    public let leeward: Int
    public let windward: Int
    /// The tick it opened.
    public let tick: Int

    public init(leeward: Int, windward: Int, tick: Int) {
        self.leeward = leeward
        self.windward = windward
        self.tick = tick
    }
}

/// What the umpire's rule 17 update reads on one tick (`UmpireState.updateProperCourse`): the race after the boats
/// have moved and the overlaps and rule 18 have been updated, before contacts.
struct ProperCourseTick {
    let tick: Int
    let boats: [Boat]
    /// Each boat's hull, world coordinates.
    let hulls: [[Vec2]]
    /// Whether rule 18 applies between each pair now (`Rules.markRoomApplies`), by `OverlapTracker.index`.
    let markRoomApplies: [Bool]
    let overlaps: OverlapTracker
    let rules: RulesConfig
    let boatClass: BoatClass

    /// Whether rule 18 is in force between seats `a` < `b` now: it applies between them, or `umpire` holds a
    /// rule 18 record naming them. Rule 17 doesn't apply then (#343).
    func isMarkRoomInForce(_ a: Int, _ b: Int, umpire: UmpireState) -> Bool {
        markRoomApplies[OverlapTracker.index(a, b, seats: boats.count)] || umpire.markRoom(SeatPair(a, b)) != nil
    }
}

/// What the umpire's rule 18 update reads on one tick (`UmpireState.updateMarkRoom`): the race after the
/// boats have moved and the overlaps have been updated, before contacts.
struct MarkRoomTick {
    let tick: Int
    let boats: [Boat]
    /// Each seat's boat before this tick's move: a boom that has crossed since, with the wind forward of the
    /// beam, has passed head to wind.
    let previous: [Boat]
    /// Each boat's hull, world coordinates.
    let hulls: [[Vec2]]
    /// Each boat's `MarkZone`, by seat.
    let zones: [MarkZone?]
    /// Whether rule 18 applies between each pair now (`Rules.markRoomApplies`), by `OverlapTracker.index`.
    let markRoomApplies: [Bool]
    let overlaps: OverlapTracker
    let course: CourseLayout
    let rules: RulesConfig
    let boatClass: BoatClass

    /// Whether `seat` passed head to wind this tick: her boom crossed with the wind forward of the beam (the
    /// tick `Race` sets `isTacking` and announces `tacked`).
    func passedHeadToWind(_ seat: Int) -> Bool {
        boats[seat].boomSide != previous[seat].boomSide && boats[seat].twa < .pi / 2
    }

    /// Whether rule 18 applies between seats `a` < `b` now.
    func markRoomApplies(_ a: Int, _ b: Int) -> Bool {
        markRoomApplies[OverlapTracker.index(a, b, seats: boats.count)]
    }
}

/// A boat in the zone of the mark she is racing to, as the umpire holds it (#91): from the tick any part of
/// her hull reached it until all of it has been out for the last point of certainty.
struct ZonePresence: Sendable, Equatable {
    /// The mark's name.
    let mark: String
    /// The tick she reached the zone: the first of a pair to reach it is the first by this.
    let enteredTick: Int
    /// On starboard tack every tick since (18.3).
    var starboardSinceEntry: Bool
    /// Ticks in a row all of her hull has been out of the zone.
    var ticksOut: Int
}

/// Rule 18 between one pair of boats at one mark (#91): the zone-entry record 18.2(a) fixes as the first of
/// them reaches its zone, who owes whom mark-room now, and what ends it. Held by `UmpireState` until rule 18
/// no longer applies between them there.
struct MarkRoomPair: Sendable, Equatable {
    /// Who owes whom mark-room, under which rule.
    struct Owed: Sendable, Equatable {
        let entitled: Int
        let owing: Int
        /// `.givingMarkRoom` (18.2) or `.tackingInTheZone` (18.3).
        let rule: RacingRule
    }

    /// A tack from port to starboard in the zone (18.3): 18.2 no longer applies between the pair.
    struct TackInZone: Sendable, Equatable {
        let tacker: Int
        /// The other boat had been on starboard since entering the zone: the tacker owes her mark-room once
        /// that boat is overlapped inside the tacker (18.3(b)). No record when the tacker is the inside boat.
        let protectsOther: Bool
    }

    let mark: CourseLayout.Mark
    let side: RoundingSide
    let firstInZone: Int
    let overlappedAtZoneEntry: Bool
    /// The lower and the higher seat's leg index as the first reached the zone: each has left the mark astern
    /// once hers has moved on.
    let lowLeg: Int
    let highLeg: Int
    var owed: Owed?
    /// Mark-room has been given: rule 18 no longer applies between them at this mark (18.1).
    var roomGiven = false
    var tackInZone: TackInZone?
    /// Whether the entitled boat has been in the zone since `owed` began: only then can she leave it.
    var entitledHasBeenIn = false
    /// Ticks in a row all of the entitled boat's hull has been out of the zone, once she has been in it.
    var entitledTicksOut = 0
    /// Ticks in a row neither boat's hull has been in the zone: rule 18 applies only while one is (18.1).
    var ticksNeitherIn = 0

    /// The record 18.2(a) makes for seats `a` < `b` on `tick`, if they are racing to the same mark and either
    /// is in its zone (`presence`); nil otherwise. The first in the zone is the first by `enteredTick`, and of
    /// two that reached it on one tick the one nearer the mark.
    static func begin(_ a: Int, _ b: Int, _ tick: MarkRoomTick, presence: (Int) -> ZonePresence?) -> MarkRoomPair? {
        guard let za = tick.zones[a], let zb = tick.zones[b], za.mark == zb.mark else { return nil }
        let pa = presence(a).flatMap { $0.mark == za.mark.name ? $0 : nil }
        let pb = presence(b).flatMap { $0.mark == zb.mark.name ? $0 : nil }
        let (boatA, boatB) = (tick.boats[a], tick.boats[b])
        let nearer = za.distance <= zb.distance ? a : b
        let first: Int
        switch (pa, pb) {
        case let (pa?, pb?): first = pa.enteredTick == pb.enteredTick ? nearer : pa.enteredTick < pb.enteredTick ? a : b
        case (.some, nil): first = a
        case (nil, .some): first = b
        case (nil, nil): return nil
        }
        let overlapped = tick.overlaps.isOverlapped(a, b)
        var state = MarkRoomPair(mark: za.mark, side: za.side, firstInZone: first, overlappedAtZoneEntry: overlapped,
                                 lowLeg: boatA.legIndex, highLeg: boatB.legIndex)
        if !Rules.onOppositeTacksOnABeat(boatA, boatB, course: tick.course, onABeat: tick.rules.onABeat) {
            let entitled = overlapped
                ? Rules.insideBoat(boatA, boatB, side: za.side, aDistance: za.distance, bDistance: zb.distance) : first
            state.owed = Owed(entitled: entitled, owing: entitled == a ? b : a, rule: .givingMarkRoom)
            state.entitledHasBeenIn = entitled == a ? za.isIn : zb.isIn
        }
        return state
    }

    /// One tick for seats `a` < `b` (see `UmpireState.updateMarkRoom`): false once rule 18 has ended between
    /// them at this mark. Sets `began` to a record it makes.
    mutating func advance(_ a: Int, _ b: Int, _ tick: MarkRoomTick, margin: Int, presence: (Int) -> ZonePresence?,
                          began: inout Owed?) -> Bool {
        let (boatA, boatB) = (tick.boats[a], tick.boats[b])
        guard boatA.status == .racing, boatB.status == .racing else { return false }
        if boatA.legIndex > lowLeg && boatB.legIndex > highLeg { return false }
        let radius = tick.course.zoneRadius
        let aDistance = Collision.distance(convex: tick.hulls[a], to: mark.position)
        let bDistance = Collision.distance(convex: tick.hulls[b], to: mark.position)
        let (aIn, bIn) = (aDistance <= radius, bDistance <= radius)
        ticksNeitherIn = aIn || bIn ? 0 : ticksNeitherIn + 1
        if ticksNeitherIn >= margin { return false }

        if let current = owed {
            if current.entitled == a ? aIn : bIn {
                entitledHasBeenIn = true
                entitledTicksOut = 0
            } else if entitledHasBeenIn {
                entitledTicksOut += 1
            }
            if tick.passedHeadToWind(current.entitled) || entitledTicksOut >= margin {
                owed = nil
            } else if isRoomGiven(current, a, b, tick, entitledDistance: current.entitled == a ? aDistance : bDistance) {
                owed = nil
                roomGiven = true
            }
        }

        // 18.3, at a mark left to port: a boat that tacked onto starboard in the zone, and one on starboard
        // fetching the mark.
        if side == .port {
            for (tacker, other, tackerIn) in [(a, b, aIn), (b, a, bIn)]
            where tackerIn && tick.passedHeadToWind(tacker) && tick.boats[tacker].tack == .starboard {
                let fetching = tick.boats[other]
                guard fetching.tack == .starboard,
                      Rules.isFetchingOnStarboard(fetching, mark: mark.position, boatClass: tick.boatClass)
                else { continue }
                let since = presence(other).map { $0.mark == mark.name && $0.starboardSinceEntry } ?? false
                tackInZone = TackInZone(tacker: tacker, protectsOther: since)
                owed = nil
            }
        }

        // A record from an overlap: 18.3's inside overlap, or 18.2(c) once 18.2(a) no longer applies.
        guard owed == nil, !roomGiven, tick.zones[a]?.mark == mark, tick.markRoomApplies(a, b),
              tick.overlaps.isOverlapped(a, b)
        else { return true }
        let inside = Rules.insideBoat(boatA, boatB, side: side, aDistance: aDistance, bDistance: bDistance)
        let outside = inside == a ? b : a
        if let tackInZone {
            guard tackInZone.protectsOther, outside == tackInZone.tacker else { return true }
            owed = Owed(entitled: inside, owing: outside, rule: .tackingInTheZone)
        } else {
            owed = Owed(entitled: inside, owing: outside, rule: .givingMarkRoom)
        }
        entitledHasBeenIn = inside == a ? aIn : bIn
        entitledTicksOut = 0
        began = owed
        return true
    }

    /// The rules configuration's mark-room-given test (`RulesConfig.MarkRoomGiven`, a builder value): the
    /// entitled boat has passed the mark (crossed the first rounding stage of the leg she was on as the first
    /// reached the zone, or left that leg) with her hull within `roundingDistance` of it and at least
    /// `clearance` between her hull and the other's. Never at the finish line's ends, which have no stages: a
    /// boat passing one finishes, and a ghost has no rights.
    private func isRoomGiven(_ owed: Owed, _ a: Int, _ b: Int, _ tick: MarkRoomTick, entitledDistance: Double) -> Bool {
        let entitled = tick.boats[owed.entitled]
        let leg = owed.entitled == a ? lowLeg : highLeg
        let passed = entitled.legIndex > leg || (entitled.legIndex == leg && entitled.roundingStage >= 1)
        let given = tick.rules.markRoomGiven
        let hullLength = tick.boatClass.hull.length
        guard passed, entitledDistance <= given.roundingDistance.metres(hullLength: hullLength) else { return false }
        let apart = Collision.distance(convex: tick.hulls[owed.entitled], simplePolygon: tick.hulls[owed.owing])
        return apart >= given.clearance.metres(hullLength: hullLength)
    }
}
