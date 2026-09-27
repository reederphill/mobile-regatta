import Foundation
import Testing
@testable import RegattaCore

/// Two boats put together for the umpire's tests (#88): a two-seat race (`placedRace`, ilca-dinghy@3) in a
/// steady 10 kn wind from the course's axis, with no current.
enum IncidentFixture {
    static let noCurrent = CurrentField(current: nil, tideStateAtGun: 0)
    static let speed = 3.0
    static let knots = 10.0

    static func wind(_ race: Race) -> GroundWind {
        GroundWind(direction: wrapAngle(race.course.axis), speed: metresPerSecond(knots: knots))
    }

    static func race() throws -> Race {
        let probe = try placedRace(current: noCurrent) { _, _ in }
        let wind = wind(probe)
        return try placedRace(current: noCurrent, wind: { _ in wind }) { _, _ in }
    }

    /// A prediction of `race` (`Race.Mode.prediction`) in the same wind, holding its world.
    static func prediction(of race: Race) throws -> Race {
        let wind = wind(race)
        let prediction = try Race(setup: race.setup, files: race.files, mode: .prediction(revealedWindKeys: []),
                                  current: noCurrent, wind: { _ in wind })
        try prediction.importSnapshot(race.exportSnapshot())
        return prediction
    }

    /// Half way up the first beat: far from every mark.
    static func midBeat(_ race: Race) -> Vec2 {
        race.course.startLine.centre + race.course.upwind * (race.course.beat / 2)
    }

    /// Starboard tack, `offWind` radians to her port side of the wind (π/4 close-hauled, π/2 a beam reach).
    static func starboard(_ race: Race, offWind: Double) -> Double { wrapAngle(race.course.axis - offWind) }

    /// The centre-to-centre distance abeam that leaves `gap` metres between a hull and one to its starboard
    /// turned `converging` radians towards it.
    static func abeam(gap: Double, converging: Double, hull: BoatClass.Hull) -> Double {
        let a = Boat(id: 0, isPlayer: false, colorIndex: 0, position: .zero, heading: 0, speed: 0)
        func distance(_ d: Double) -> Double {
            let b = Boat(id: 1, isPlayer: false, colorIndex: 1, position: Vec2(d, 0), heading: -converging, speed: 0)
            return Collision.distance(convex: a.hull(outline: hull.outline), simplePolygon: b.hull(outline: hull.outline))
        }
        var (lo, hi) = (0.0, 20.0)
        for _ in 0..<60 {
            let mid = (lo + hi) / 2
            if distance(mid) < gap { lo = mid } else { hi = mid }
        }
        return hi
    }

    /// The metres between the two boats' hulls, 0 if they touch.
    static func gap(_ race: Race) -> Double {
        let outline = race.boatClass.hull.outline
        return Collision.distance(convex: race.boats[0].hull(outline: outline), simplePolygon: race.boats[1].hull(outline: outline))
    }

    /// Jumps `race` to `tick` with both boats racing on leg 0, on starboard tack at `speed`, owing no penalty,
    /// rudders centred: seat 0 at `at` heading `heading`, and seat 1 to windward of her, her centre `abeam`
    /// metres off seat 0's on seat 0's starboard side, `converging` radians further off the wind (towards
    /// her). They are overlapped as of the last point of certainty, and not yet touching as far as the race
    /// knows. `edit` has the last word.
    static func place(_ race: Race, tick: Int, at: Vec2, heading: Double, abeam: Double, converging: Double = 0,
                      edit: (inout WorldSnapshot) -> Void = { _ in }) throws {
        try jump(race, to: tick) { snapshot in
            for seat in 0..<2 {
                var boat = snapshot.seats[seat].boat
                placeRacing(&boat, leg: 0, at: at)
                boat.heading = heading
                boat.boomSide = .port
                boat.speed = speed
                boat.rudder = 0
                boat.desiredRudder = 0
                boat.autohelm = nil
                boat.isTacking = false
                boat.penaltyTurnsOwed = 0
                boat.penaltyProgress = 0
                boat.penaltyClockTick = nil
                boat.queuedPenaltyCallTicks = []
                if seat == 1 {
                    boat.position = at + Vec2.heading(heading).rightPerp * abeam
                    boat.heading = heading - converging
                }
                snapshot.seats[seat].boat = boat
                snapshot.seats[seat].heldInput = .neutral
            }
            snapshot.touchingBoats = []
            snapshot.overlaps = [.init(pair: .init(0, 1), isOverlapped: true, changeTicks: 0)]
            edit(&snapshot)
        }
    }

    /// Side by side on a beam reach mid-beat, hulls overlapping by 0.3 m: they touch on the next step.
    static func touching(_ race: Race, tick: Int, at: Vec2? = nil, edit: (inout WorldSnapshot) -> Void = { _ in }) throws {
        try place(race, tick: tick, at: at ?? midBeat(race), heading: starboard(race, offWind: .pi / 2),
                  abeam: race.boatClass.hull.beam - 0.3, edit: edit)
    }

    /// Side by side on a beam reach, `gap` metres between the hulls.
    static func apart(_ race: Race, tick: Int, at: Vec2, gap: Double) throws {
        let hull = race.boatClass.hull
        try place(race, tick: tick, at: at, heading: starboard(race, offWind: .pi / 2),
                  abeam: abeam(gap: gap, converging: 0, hull: hull))
    }

    static func calls(_ events: [RaceEvent]) -> [RuleCall] {
        events.compactMap { if case .ruleCall(let call) = $0.kind { call } else { nil } }
    }

    static func contacts(_ events: [RaceEvent]) -> [SeatPair] {
        events.compactMap { if case .contact(let pair) = $0.kind { pair } else { nil } }
    }
}

/// #88 acceptance: one incident per pair until they separate by 2 hull lengths (#9), held in the umpire's
/// memory alone; ghosts are in none.
@Suite struct IncidentTests {
    typealias F = IncidentFixture

    /// Touching twice within 2 L is one incident and one call; separated to 3 L, a touch is a new incident
    /// and a second call.
    @Test func touchesWithinSeparationAreOneCall() throws {
        let race = try F.race()
        let length = race.boatClass.hull.length
        let pair = SeatPair(0, 1)

        try F.touching(race, tick: 300)
        race.step()
        var events = race.drainEvents()
        #expect(F.contacts(events) == [pair])
        let first = try #require(F.calls(events).first)
        #expect(F.calls(events).count == 1)
        #expect(first.rule == .windwardLeeward && first.offender == 1 && first.victim == 0)
        #expect(race.umpire?.openIncident(pair) == first.incidentId)

        // A hull length apart: still the same incident.
        try F.apart(race, tick: race.tick, at: race.boats[0].position, gap: length)
        race.step()
        #expect(F.gap(race) > length / 2 && F.gap(race) < 2 * length)
        events = race.drainEvents()
        #expect(F.contacts(events).isEmpty && F.calls(events).isEmpty)
        #expect(race.umpire?.openIncident(pair) == first.incidentId)

        // Touching again inside it: a contact, but no second call.
        try F.touching(race, tick: race.tick, at: race.boats[0].position)
        race.step()
        events = race.drainEvents()
        #expect(F.contacts(events) == [pair])
        #expect(F.calls(events).isEmpty)
        #expect(race.incidents.count == 1)

        // Three hull lengths apart: they have separated, and the incident closes.
        try F.apart(race, tick: race.tick, at: race.boats[0].position, gap: 3 * length)
        race.step()
        #expect(F.gap(race) > 2 * length)
        #expect(race.umpire?.openIncident(pair) == nil)
        #expect(F.calls(race.drainEvents()).isEmpty)

        // A touch now is a new incident, called.
        try F.touching(race, tick: race.tick, at: race.boats[0].position)
        race.step()
        events = race.drainEvents()
        #expect(F.contacts(events) == [pair])
        let second = try #require(F.calls(events).first)
        #expect(F.calls(events).count == 1)
        #expect(second.incidentId == first.incidentId + 1 && second.offender == 1)
        #expect(race.incidents.count == 2)
        #expect(race.incidents.incidents(between: 0, and: 1).map(\.id) == [first.incidentId, second.incidentId])
        #expect(race.umpire?.openIncident(pair) == second.incidentId)
    }

    /// A ghost (finished or DSQ) can't be touched and nearly hits nobody: no contact, no incident, no call,
    /// whichever of the pair she is.
    @Test func ghostContactOpensNoIncident() throws {
        for status in [BoatStatus.finished, .dsq] {
            for ghost in [0, 1] {
                for nearMiss in [false, true] {
                    let race = try F.race()
                    let ghostly = { (snapshot: inout WorldSnapshot) in
                        snapshot.seats[ghost].boat.status = status
                        if status == .finished {
                            snapshot.seats[ghost].boat.place = 1
                            snapshot.seats[ghost].boat.finishTime = 5
                            snapshot.firstFinishTime = 5
                        }
                    }
                    if nearMiss {
                        let converging = deg2rad(30)
                        try F.place(race, tick: 300, at: F.midBeat(race), heading: F.starboard(race, offWind: .pi / 2),
                                    abeam: F.abeam(gap: 0.8, converging: converging, hull: race.boatClass.hull),
                                    converging: converging, edit: ghostly)
                    } else {
                        try F.touching(race, tick: 300, edit: ghostly)
                    }
                    race.step()
                    let events = race.drainEvents()
                    let label = "\(status), ghost \(ghost), \(nearMiss ? "near miss" : "hulls overlapping")"
                    #expect(F.contacts(events).isEmpty, "\(label)")
                    #expect(F.calls(events).isEmpty, "\(label)")
                    #expect(race.incidents.count == 0, "\(label)")
                    #expect(race.boats.allSatisfy { $0.penaltyTurnsOwed == 0 }, "\(label)")
                    #expect(race.umpire?.openIncident(SeatPair(0, 1)) == nil, "\(label)")
                }
            }
        }
    }

    /// Which incidents are open is the umpire's memory (`UmpireState`), the authoritative race's alone:
    /// none of it is in the world. A race importing the world holds none open, so it calls a touch the race
    /// it came from, still inside the incident, doesn't; and a prediction has no umpire at all.
    @Test func incidentMemoryLivesInUmpireStateOnly() throws {
        let race = try F.race()
        let pair = SeatPair(0, 1)
        try F.touching(race, tick: 300)
        race.step()
        let first = try #require(F.calls(race.drainEvents()).first)
        #expect(race.umpire?.openIncident(pair) == first.incidentId)

        let world = race.exportSnapshot()
        let fields = Mirror(reflecting: world).children.compactMap(\.label)
        #expect(!fields.contains { ["umpire", "openIncidents", "foulMemory", "lastFoul"].contains($0) })
        #expect(!Mirror(reflecting: race).children.contains { $0.label == "lastFoul" })

        let copy = try F.race()
        try copy.importSnapshot(world)
        #expect(copy.umpire == UmpireState())
        #expect(copy.umpire?.openIncident(pair) == nil)
        #expect(copy.incidents == race.incidents)
        #expect(try F.prediction(of: race).umpire == nil)

        // They touch again, well inside 2 L.
        for sailing in [race, copy] { try F.touching(sailing, tick: race.tick, at: race.boats[0].position) }
        race.step()
        copy.step()
        let original = race.drainEvents(), imported = copy.drainEvents()
        #expect(F.contacts(original) == [pair] && F.contacts(imported) == [pair])
        #expect(F.calls(original).isEmpty, "the umpire holds the incident open")
        #expect(F.calls(imported).map(\.incidentId) == [first.incidentId + 1], "the world never did")
    }
}
