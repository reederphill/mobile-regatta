import Foundation
import Testing
@testable import RegattaCore

/// Two boats set up for rule 17 (#345): `IncidentFixture`'s two-seat race (ilca-dinghy@3 in a steady 10 kn from the
/// course's axis, no current, the default rules fleet-rules@5), close-hauled on starboard mid-beat, where proper
/// course is the upwind groove. Seat 0 is the leeward boat, seat 1 the windward one.
enum Rule17Fixture {
    typealias F = IncidentFixture
    typealias E = EscapeFixture

    static let pair = SeatPair(0, 1)

    /// The upwind groove's sailing angle in the fixture's wind.
    static func groove(_ race: Race) -> Double {
        Autohelm.grooveAngle(.upwind, tws: metresPerSecond(knots: F.knots), boatClass: race.boatClass)
    }

    /// Jumps `race` to `tick` (300 by default) with both boats racing on leg 0 on starboard, owing nothing, rudders
    /// centred, each held by her autohelm at her angle: seat 0 (leeward) `leewardAbove` radians above the groove at
    /// `leewardSpeed`, seat 1 (windward) `windwardBelow` radians below it (towards seat 0) at `windwardSpeed`. Seat 1's
    /// centre is `ahead` metres ahead of seat 0's along seat 0's heading, and to windward of it by as much as leaves
    /// `gap` metres between the hulls (`gap` nil: `abeam` metres, centre to centre). Overlapped as of the last point
    /// of certainty when `overlapped`. `at` defaults to mid-beat; `edit` has the last word. Off the wind, `leg` is the
    /// leg both sail and `proper` the leeward boat's proper course there as a sailing angle, which takes the groove's
    /// place: the windward boat then holds `proper` less `windwardBelow` by her autohelm, not the groove.
    static func place(_ race: Race, tick: Int = 300, at: Vec2? = nil, leg: Int = 0, proper: Double? = nil,
                      leewardAbove: Double, windwardBelow: Double = 0,
                      gap: Double? = nil, abeam: Double = 0, ahead: Double = 0, leewardSpeed: Double = F.speed,
                      windwardSpeed: Double = F.speed, overlapped: Bool = true,
                      edit: (inout WorldSnapshot) -> Void = { _ in }) throws {
        let groove = proper ?? groove(race)
        let at = at ?? F.midBeat(race)
        let leewardAngle = groove - leewardAbove, windwardAngle = groove + windwardBelow
        let leewardHeading = F.starboard(race, offWind: leewardAngle)
        let forward = Vec2.heading(leewardHeading)
        let across = gap.map { F.abeam(gap: $0, converging: leewardAbove + windwardBelow, hull: race.boatClass.hull) } ?? abeam
        try jump(race, to: tick) { snapshot in
            for seat in 0..<2 {
                var boat = snapshot.seats[seat].boat
                placeRacing(&boat, leg: leg, at: at)
                boat.boomSide = .port
                boat.rudder = 0
                boat.desiredRudder = 0
                boat.isTacking = false
                boat.penaltyTurnsOwed = 0
                boat.penaltyProgress = 0
                boat.penaltyClockTick = nil
                boat.queuedPenaltyCallTicks = []
                if seat == 0 {
                    boat.heading = leewardHeading
                    boat.speed = leewardSpeed
                    boat.autohelm = Autohelm(target: .angle(leewardAngle))
                } else {
                    boat.position = at + forward.rightPerp * across + forward * ahead
                    boat.heading = F.starboard(race, offWind: windwardAngle)
                    boat.speed = windwardSpeed
                    boat.autohelm = windwardBelow == 0 && proper == nil ? Autohelm(target: .groove(.upwind)) : Autohelm(target: .angle(windwardAngle))
                }
                snapshot.seats[seat].boat = boat
                snapshot.seats[seat].heldInput = .neutral
            }
            snapshot.touchingBoats = []
            snapshot.overlaps = overlapped ? [.init(pair: .init(0, 1), isOverlapped: true, changeTicks: 0)] : []
            edit(&snapshot)
        }
    }

    /// Gives the pair the rule 17 record of seat 0 (leeward) against seat 1, as if she had come up from astern:
    /// placing by snapshot forgets the umpire's memory.
    static func record(_ race: Race) {
        race.umpire?.setProperCourse(ProperCourseRecord(leeward: 0, windward: 1), for: pair)
    }

    /// Seat 0 sailing up from clear astern and to leeward of seat 1, both on the groove: her bow `behind` metres behind
    /// a line abeam of seat 1's stern, her centre `abeam` metres to leeward of seat 1's, at `leewardSpeed` against seat
    /// 1's `windwardSpeed`. Swapped (`windwardFromAstern`), seat 1 comes up from astern to windward of seat 0.
    static func overtake(_ race: Race, abeam: Double, behind: Double = 0.3, leewardSpeed: Double = 4.5,
                         windwardSpeed: Double = 2.5, windwardFromAstern: Bool = false) throws {
        let length = race.boatClass.hull.length
        let back = length + behind
        try place(race, leewardAbove: 0, abeam: abeam, ahead: windwardFromAstern ? -back : back,
                  leewardSpeed: leewardSpeed, windwardSpeed: windwardSpeed, overlapped: false) { snapshot in
            snapshot.seats[0].boat.autohelm = Autohelm(target: .groove(.upwind))
        }
    }

    /// Steps `race` until `until` holds after a step, at most `ticks` steps; whether it did.
    @discardableResult
    static func sail(_ race: Race, within ticks: Int, until: (Race) -> Bool) -> Bool {
        for _ in 0..<ticks {
            race.step()
            _ = race.drainEvents()
            if until(race) { return true }
        }
        return false
    }

    static func record(of race: Race) -> ProperCourseRecord? { race.umpire?.properCourse(pair) }
}

/// #345 acceptance: rule 17. A leeward boat that came up from clear astern within two hull lengths is held to her
/// proper course; when she sails above it into the windward boat, and the windward boat would have been clear of her
/// proper-course path, rule 17 on her, the windward boat exonerated.
@Suite struct Rule17Tests {
    typealias R = Rule17Fixture
    typealias F = IncidentFixture
    typealias E = EscapeFixture

    // MARK: - The record

    /// Seat 0 comes up from clear astern 2.5 m to leeward (centres): the record opens on the tick the overlap is
    /// certain, naming her the leeward boat, and seat 0 is restricted against seat 1.
    @Test func recordOpensWhenLeewardOverlapsFromClearAsternWithinTwoLengths() throws {
        let race = try F.race()
        try R.overtake(race, abeam: 2.5)
        #expect(!Rules.isClearAstern(race.boats[1], of: race.boats[0], hull: race.boatClass.hull))
        #expect(Rules.isClearAstern(race.boats[0], of: race.boats[1], hull: race.boatClass.hull))
        var overlappedAt: Int?
        #expect(R.sail(race, within: 3 * Race.tickRate) { race in
            if overlappedAt == nil, race.overlaps.isOverlapped(0, 1) { overlappedAt = race.tick }
            return R.record(of: race) != nil
        })
        let record = try #require(R.record(of: race))
        #expect(record.leeward == 0 && record.windward == 1 && race.tick == overlappedAt)
        #expect(race.properCourseRestrictions(of: 0) == [1] && race.properCourseRestrictions(of: 1) == [])
        // A prediction holds no umpire, so no record.
        #expect(try F.prediction(of: race).properCourseRestrictions(of: 0) == [])
    }

    /// The windward boat makes the overlap from clear astern: no record.
    @Test func noRecordWhenWindwardMakesTheOverlap() throws {
        let race = try F.race()
        try R.overtake(race, abeam: 2.5, leewardSpeed: 2.5, windwardSpeed: 4.5, windwardFromAstern: true)
        #expect(Rules.isClearAstern(race.boats[1], of: race.boats[0], hull: race.boatClass.hull))
        R.sail(race, within: 3 * Race.tickRate) { race in race.overlaps.isOverlapped(0, 1) }
        #expect(race.overlaps.isOverlapped(0, 1))
        R.sail(race, within: Race.tickRate) { R.record(of: $0) != nil }
        #expect(R.record(of: race) == nil)
    }

    /// From clear astern but more than two hull lengths to leeward: overlapped, no record.
    @Test func noRecordBeyondTwoLengths() throws {
        let race = try F.race()
        let length = race.boatClass.hull.length
        try R.overtake(race, abeam: 2.6 * length + race.boatClass.hull.beam)
        R.sail(race, within: 3 * Race.tickRate) { race in race.overlaps.isOverlapped(0, 1) }
        #expect(race.overlaps.isOverlapped(0, 1) && F.gap(race) > 2 * length)
        R.sail(race, within: Race.tickRate) { R.record(of: $0) != nil }
        #expect(R.record(of: race) == nil)
    }

    /// Already side by side, neither ever astern of the other: no record, however long they sail overlapped.
    @Test func noRecordWhileAlreadyAbreast() throws {
        let race = try F.race()
        try R.place(race, leewardAbove: 0, gap: 1.5, overlapped: false)
        R.sail(race, within: 3 * Race.tickRate) { race in race.overlaps.isOverlapped(0, 1) }
        #expect(race.overlaps.isOverlapped(0, 1))
        R.sail(race, within: Race.tickRate) { R.record(of: $0) != nil }
        #expect(R.record(of: race) == nil)
    }

    /// The leeward boat ahead of the windward one, not clear astern of her, dropping back until they overlap: she
    /// didn't come up from clear astern, so no record, however long they sail overlapped.
    @Test func noRecordWhenLeewardWasAhead() throws {
        let race = try F.race()
        try R.overtake(race, abeam: 2.5, leewardSpeed: 1.5, windwardSpeed: F.speed, windwardFromAstern: true)
        #expect(!Rules.isClearAstern(race.boats[0], of: race.boats[1], hull: race.boatClass.hull))
        #expect(Rules.isClearAstern(race.boats[1], of: race.boats[0], hull: race.boatClass.hull))
        #expect(R.sail(race, within: 5 * Race.tickRate) { race in race.overlaps.isOverlapped(0, 1) })
        #expect(F.gap(race) <= 2 * race.boatClass.hull.length)
        R.sail(race, within: 2 * Race.tickRate) { R.record(of: $0) != nil }
        #expect(race.overlaps.isOverlapped(0, 1) && R.record(of: race) == nil)
    }

    /// A record opened by sailing up from astern.
    private func opened() throws -> Race {
        let race = try F.race()
        try R.overtake(race, abeam: 2.5)
        #expect(R.sail(race, within: 3 * Race.tickRate) { R.record(of: $0) != nil })
        return race
    }

    /// The leeward boat bears away: the record ends once they are more than two hull lengths apart (or no longer
    /// overlapped), and doesn't come back.
    @Test func recordEndsOnSeparation() throws {
        let race = try opened()
        let reach = 2 * race.boatClass.hull.length
        _ = race.apply(BoatInput(rudder: -0.6), seat: 0, atTick: race.tick + 1)
        #expect(R.sail(race, within: 10 * Race.tickRate) { R.record(of: $0) == nil })
        #expect(F.gap(race) > reach || !race.overlaps.isOverlapped(0, 1))
        _ = race.apply(BoatInput.neutral, seat: 0, atTick: race.tick + 1)
        R.sail(race, within: 2 * Race.tickRate) { R.record(of: $0) != nil }
        #expect(R.record(of: race) == nil)
    }

    /// The windward boat tacks away: the record ends as she begins her tack.
    @Test func recordEndsOnATack() throws {
        let race = try opened()
        _ = race.apply(BoatInput(rudder: 1.0), seat: 1, atTick: race.tick + 1)
        #expect(R.sail(race, within: 5 * Race.tickRate) { R.record(of: $0) == nil })
        #expect(race.boats[1].isTacking || race.boats[1].boomSide != .port)
        #expect(F.gap(race) <= 2 * race.boatClass.hull.length && race.overlaps.isOverlapped(0, 1))
    }

    /// Rule 18 taking over between the pair ends the record.
    @Test func recordEndsWhenRule18Applies() throws {
        let race = try opened()
        var umpire = try #require(race.umpire)
        let hulls = race.boats.map { $0.hull(outline: race.boatClass.hull.outline) }
        func tick(markRoom: Bool) -> ProperCourseTick {
            ProperCourseTick(tick: race.tick + 1, boats: race.boats, hulls: hulls, markRoomApplies: [markRoom],
                             overlaps: race.overlaps, rules: race.rules, boatClass: race.boatClass)
        }
        var held = umpire
        held.updateProperCourse(tick(markRoom: false))
        #expect(held.properCourse(R.pair) != nil)
        umpire.updateProperCourse(tick(markRoom: true))
        #expect(umpire.properCourse(R.pair) == nil)
    }

    // MARK: - The call

    /// The leeward boat sails 10° above the groove (outside the no-go zone, 30° here), converging on the windward boat
    /// 1.2 m off, who holds the groove.
    func converging(above: Double = deg2rad(10), record: Bool = true, rules: Int? = nil) throws -> (Race, E.Outcome?) {
        let race = try rules.map { try Rule17Tests.race(rules: $0) } ?? F.race()
        try R.place(race, leewardAbove: above, gap: 1.2)
        if record { R.record(race) }
        return (race, E.sailToCall(race, within: 10 * Race.tickRate))
    }

    /// The fixture's race (`IncidentFixture.race`) under fleet-rules@`version`.
    static func race(rules version: Int) throws -> Race {
        let wind = F.wind(try F.race())
        let rules = try RulesConfigFile.bundled(id: "fleet-rules", version: version)
        var catalog = RaceFileCatalog()
        try catalog.rulesConfigurations.add(rules)
        let boatClass = try BoatClassFile.bundled(id: Fixtures.classID, version: Fixtures.version).ref
        let setup = try RaceSetup(raceSeed: RaceSeed(3), seats: [.human, .human], laps: 2,
                                  startSequenceTicks: 60 * Race.tickRate, boatClass: boatClass,
                                  rulesConfiguration: rules.ref)
        let race = try Race(setup: setup, files: RaceFiles(resolving: setup, from: catalog),
                            mode: .authoritative(windSeed: WindSeed(3 &* 0x9E37_79B9_7F4A_7C15 &+ 1)), current: F.noCurrent,
                            wind: { _ in wind })
        for _ in 0..<10 { race.step() }
        #expect(race.course == (try F.race()).course)
        return race
    }

    /// Above proper course by more than the tolerance, into the windward boat holding her course: rule 17 on the
    /// leeward boat, the windward boat exonerated. Without the record, rule 11 on the windward boat.
    @Test func aboveProperCourseIntoAWindwardBoatClearOfItIsRule17() throws {
        let (race, called) = try converging()
        let outcome = try #require(called)
        #expect(outcome.call.rule == .properCourse && outcome.call.offender == 0 && outcome.call.victim == 1)
        #expect(outcome.exonerated == [1])
        #expect(race.boats[0].penaltyTurnsOwed == 1 && race.boats[1].penaltyTurnsOwed == 0)

        let (_, without) = try converging(record: false)
        let plain = try #require(without)
        #expect(plain.call.rule == .windwardLeeward && plain.call.offender == 1 && plain.exonerated.isEmpty)
    }

    /// The leeward boat above proper course, but the windward boat bears away into her, 20° below the groove: she
    /// would have hit the proper-course path too. Rule 11 on the windward boat, no rule 17.
    @Test func windwardSteeringIntoLeewardIsRule11() throws {
        let race = try F.race()
        try R.place(race, leewardAbove: deg2rad(8), windwardBelow: deg2rad(20), gap: 1.2)
        R.record(race)
        let outcome = try #require(E.sailToCall(race, within: 10 * Race.tickRate))
        #expect(outcome.call.rule == .windwardLeeward && outcome.call.offender == 1 && outcome.call.victim == 0)
        #expect(outcome.exonerated.isEmpty)
        #expect(race.boats[1].penaltyTurnsOwed == 1 && race.boats[0].penaltyTurnsOwed == 0)
    }

    /// The leeward boat 3° above the groove, inside the 5° beat tolerance, converging on the windward boat: no rule
    /// 17. Rule 11 on the windward boat.
    @Test func withinToleranceIsNoRule17() throws {
        let race = try F.race()
        try R.place(race, leewardAbove: deg2rad(3), gap: 0.4)
        R.record(race)
        let outcome = try #require(E.sailToCall(race, within: 20 * Race.tickRate))
        #expect(outcome.call.rule == .windwardLeeward && outcome.call.offender == 1)
        #expect(R.record(of: race) != nil, "the record held through the incident")
    }

    /// The leeward boat above proper course and dropping astern: the windward boat far faster, both projected on at
    /// their velocities she is clear astern within 4 s. Exempt: no rule 17, the incident goes to the rule 11 chain.
    /// At the leeward boat's speed she isn't, and it is rule 17.
    @Test func droppingAsternWithinTheWindowIsExempt() throws {
        func converge(windwardSpeed: Double) throws -> (Race, E.Outcome) {
            let race = try F.race()
            try R.place(race, leewardAbove: deg2rad(10), gap: 0.5, ahead: 0.1 * race.boatClass.hull.length,
                        windwardSpeed: windwardSpeed)
            R.record(race)
            return (race, try #require(E.sailToCall(race, within: 5 * Race.tickRate)))
        }
        let (race, exempt) = try converge(windwardSpeed: 7)
        #expect(exempt.call.rule == .windwardLeeward && exempt.call.offender == 1 && exempt.exonerated.isEmpty)
        // The window is what exempts her: on the incident's track with a one-tick window, rule 17.
        var rules = race.rules
        rules.incidents.properCourse?.promptlyAstern = Race.dt
        let track = try #require(race.umpire?.track(0, 1))
        let simulation = try #require(EscapeSimulation(track: track, rules: rules, boatClass: race.boatClass,
                                                       properCourse: R.record(of: race)))
        let obligation = Verdict(rule: .windwardLeeward, offender: 1, victim: 0)
        #expect(simulation.verdict(obligation, course: race.course).rule == .properCourse)

        let (_, control) = try converge(windwardSpeed: F.speed)
        #expect(control.call.rule == .properCourse && control.call.offender == 0 && control.exonerated == [1])
    }

    /// A hard luff above proper course into the windward boat: rule 16.1 under fleet-rules@4, which has no rule 17;
    /// under @5, rule 17 alone, one call and one penalty turn.
    @Test func rule17WinsOver16_1() throws {
        func luff(rules: Int) throws -> (Race, E.Outcome) {
            let race = try Rule17Tests.race(rules: rules)
            try R.place(race, leewardAbove: 0, gap: 0.6)
            R.record(race)
            _ = race.apply(BoatInput(rudder: 1.0), seat: 0, atTick: race.tick + 1)
            return (race, try #require(E.sailToCall(race, within: 3 * Race.tickRate)))
        }
        let (old, sixteen) = try luff(rules: 4)
        #expect(sixteen.call.rule == .changingCourse && sixteen.call.offender == 0 && sixteen.exonerated == [1])
        #expect(old.boats[0].penaltyTurnsOwed == 1)

        let (race, outcome) = try luff(rules: 5)
        #expect(outcome.call.rule == .properCourse && outcome.call.offender == 0 && outcome.exonerated == [1])
        #expect(race.incidents.incidents(between: 0, and: 1).count == 1)
        #expect(race.boats[0].penaltyTurnsOwed == 1 && race.boats[1].penaltyTurnsOwed == 0)
    }

    /// Near the windward mark, in its zone, rule 18 applies between the pair: the record ends, and the same
    /// converging leeward boat draws no rule 17.
    @Test func rule18InForceIsNoRule17() throws {
        let race = try F.race()
        let length = race.boatClass.hull.length
        let mark = race.course.elements[CourseLayout.windwardIndex].marks[0].position
        try R.place(race, at: mark - race.course.upwind * (2 * length) + race.course.right * (1.5 * length),
                    leewardAbove: deg2rad(10), gap: 1.2)
        R.record(race)
        // The record ends because rule 18 took over: on the tick it ends they are still overlapped within two
        // hull lengths, on the same tack.
        var endedOverlapped: Bool?
        let outcome = try #require(E.sailToCall(race, within: 5 * Race.tickRate) { race in
            guard endedOverlapped == nil, R.record(of: race) == nil else { return }
            endedOverlapped = race.overlaps.isOverlapped(0, 1) && F.gap(race) <= 2 * length
                && race.boats[0].boomSide == race.boats[1].boomSide && !race.boats.contains(where: \.isTacking)
        })
        #expect(endedOverlapped == true)
        #expect(outcome.call.rule != .properCourse, "\(outcome.call.rule)")
        #expect(R.record(of: race) == nil)
    }

    /// Before the gun there is no proper course: a boat that came up from astern to leeward and sails above the
    /// groove into the windward boat draws no rule 17, and no record opens.
    @Test func preStartLuffIsNoRule17() throws {
        let race = try F.race()
        let length = race.boatClass.hull.length
        try R.place(race, tick: -20 * Race.tickRate, leewardAbove: 0, abeam: 2.2, ahead: length + 0.3,
                    leewardSpeed: 4.5, windwardSpeed: 2.5, overlapped: false) { snapshot in
            for seat in 0..<2 { snapshot.seats[seat].boat.status = .prestart }
        }
        #expect(race.tick < 0)
        R.sail(race, within: 3 * Race.tickRate) { $0.overlaps.isOverlapped(0, 1) }
        #expect(race.overlaps.isOverlapped(0, 1) && R.record(of: race) == nil)
        _ = race.apply(BoatInput(rudder: 0.5), seat: 0, atTick: race.tick + 1)
        let outcome = try #require(E.sailToCall(race, within: 5 * Race.tickRate))
        #expect(outcome.call.rule != .properCourse, "\(outcome.call.rule)")
        #expect(R.record(of: race) == nil)
    }

    /// Sailed up from astern, then luffing above proper course into the windward boat: the whole chain, record and
    /// call, from the race alone. Rule 17 on the leeward boat, the windward boat exonerated.
    @Test func overtakeThenLuffIsRule17() throws {
        let race = try opened()
        R.sail(race, within: Race.tickRate / 2) { _ in false }
        _ = race.apply(BoatInput(rudder: 0.4), seat: 0, atTick: race.tick + 1)
        let outcome = try #require(E.sailToCall(race, within: 5 * Race.tickRate))
        #expect(outcome.call.rule == .properCourse && outcome.call.offender == 0 && outcome.call.victim == 1)
        #expect(outcome.exonerated == [1])
    }

    // MARK: - Off the wind

    /// Where to set the pair sailing on a reach (the leg to the offset mark, half way to it from the windward
    /// mark) or a run (the leg to the gate, half way down to it): the leg, the place, and the leeward boat's proper
    /// course there on starboard tack.
    static func offWind(_ kind: ProperCourse.Kind, _ race: Race) throws -> (leg: Int, at: Vec2, proper: ProperCourse) {
        let course = race.course
        let windward = course.elements[CourseLayout.windwardIndex].marks[0].position
        let leg: Int, at: Vec2
        switch kind {
        case .reach:
            leg = try #require(course.legs.firstIndex(of: .round(CourseLayout.offsetIndex)))
            at = (windward + course.elements[CourseLayout.offsetIndex].marks[0].position) / 2
        default:
            leg = try #require(course.legs.firstIndex(of: .round(CourseLayout.gateIndex)))
            at = windward - course.upwind * (course.beat / 2)
        }
        let proper = try #require(ProperCourse.of(position: at, boomSide: .port, status: .racing, legIndex: leg,
                                                  windDirection: course.axis, grooveTWS: metresPerSecond(knots: F.knots),
                                                  course: course, boatClass: race.boatClass))
        #expect(proper.kind == kind)
        return (leg, at, proper)
    }

    /// On a reach and on a run, through `Race.step`: the leeward boat 12° above her proper course, past the 8°
    /// tolerance, converging on the windward boat holding hers: rule 17 on her, the windward boat exonerated. At 6°,
    /// above by the beat's 5° but inside the 8°: no rule 17, rule 11 on the windward boat.
    @Test(arguments: [ProperCourse.Kind.reach, .run])
    func offTheWindToleranceIsEightDegrees(kind: ProperCourse.Kind) throws {
        func converge(above: Double, gap: Double, within seconds: Int) throws -> (Race, E.Outcome) {
            let race = try F.race()
            let (leg, at, proper) = try Rule17Tests.offWind(kind, race)
            try R.place(race, at: at, leg: leg, proper: proper.sailingAngle, leewardAbove: above, gap: gap)
            R.record(race)
            let limits = try #require(race.rules.incidents.properCourse)
            #expect(limits.tolerance(kind) == deg2rad(8))
            var sailed: [Bool] = []
            let outcome = try #require(E.sailToCall(race, within: seconds * Race.tickRate) { race in
                guard R.record(of: race) != nil,
                      let now = race.boats[0].properCourse(on: race.course, boatClass: race.boatClass)
                else { return }
                #expect(now.kind == kind)
                sailed.append(now.isAbove(sailingAngle: race.boats[0].sailingAngle, tolerance: limits.tolerance(kind)))
                #expect(now.isAbove(sailingAngle: race.boats[0].sailingAngle, tolerance: limits.beatTolerance))
            })
            #expect(R.record(of: race) != nil, "the record held through the incident")
            #expect(sailed.last == (above > limits.tolerance(kind)))
            return (race, outcome)
        }
        let (race, above) = try converge(above: deg2rad(12), gap: 1.2, within: 10)
        #expect(above.call.rule == .properCourse && above.call.offender == 0 && above.call.victim == 1)
        #expect(above.exonerated == [1])
        #expect(race.boats[0].penaltyTurnsOwed == 1 && race.boats[1].penaltyTurnsOwed == 0)

        let (_, within) = try converge(above: deg2rad(6), gap: 0.4, within: 20)
        #expect(within.call.rule == .windwardLeeward && within.call.offender == 1 && within.exonerated.isEmpty)
    }
}
