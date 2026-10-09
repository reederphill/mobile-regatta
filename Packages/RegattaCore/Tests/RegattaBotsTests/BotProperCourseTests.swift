import Foundation
import Testing
@testable import RegattaCore
@testable import RegattaBots

/// #346: a bot held to her proper course under rule 17 (#345) sails within it by construction. She learns she is
/// restricted from her seat's proper-course notice alone (`OwnBoat.properCourse`), and her aim is limited to the
/// tolerance's edge (`BotBrain.properCourseLimited`); a bot not restricted steers as she did before.
extension BotConductTests {
    /// A reach in a uniform scripted wind that shifts at `shiftTick`: seat 0 (leeward) on the leg from the windward
    /// mark to the offset mark, below the windward mark and clear of both zones, sailing straight at the offset mark (her proper course), her autohelm
    /// holding that wind angle; seat 1 parallel to her, `abeam` hull lengths to windward (centres), overlapped.
    /// At `shiftTick` the wind turns `shift` radians so that her held angle, still held, is carried that far closer
    /// to the wind than the bearing to the mark: above her proper course. With `restricted`, seat 0 gets the rule 17
    /// record against seat 1, as if she had come up from astern (placing by snapshot forgets the umpire's memory).
    /// With `fromMark`, she is placed that many hull lengths short of the offset mark on the same line instead. With
    /// `ahead`, seat 1 is also that many hull lengths ahead of her (centres), not overlapped: she is clear astern.
    struct Reach {
        let race: Race
        let leg: Int
        let shiftTick: Int

        init(seed: UInt64, shift: Double, restricted: Bool, abeam: Double = 2, fromMark: Double? = nil,
             ahead: Double = 0) throws {
            let probe = botRace(seats: [.bot, .bot], seed: seed)
            let c = probe.course
            let leg = try #require(c.legs.firstIndex(of: .round(CourseLayout.offsetIndex)))
            let windward = c.elements[CourseLayout.windwardIndex].marks[0].position
            let mark = c.elements[CourseLayout.offsetIndex].marks[0].position
            // Below the leg, well clear of both marks' zones: the offset mark a reach away, a little above abeam.
            let approach = (mark - windward).normalized
            let far = mark - approach * ((mark - windward).length + 11) - c.upwind * 35
            // `fromMark` hull lengths short of the mark on the same line, in its zone: where rule 18 takes over.
            let at = fromMark.map { mark + (far - mark).normalized * (probe.boatClass.hull.length * $0) } ?? far
            let heading = (mark - at).bearing
            let base = GroundWind(direction: wrapAngle(c.axis), speed: metresPerSecond(knots: 10))
            // On starboard (the wind over her starboard side, boom to port) a wind turned clockwise turns her
            // clockwise too, holding her angle, towards the wind's old direction: closer to the wind than the mark.
            let starboard = wrapAngle(base.direction - heading) >= 0
            let shifted = GroundWind(direction: wrapAngle(base.direction + (starboard ? shift : -shift)), speed: base.speed)
            let shiftTick = 3 * Race.tickRate
            race = try Race(setup: probe.setup, files: probe.files, mode: .authoritative(windSeed: WindSeed(seed)),
                            current: CurrentField(current: nil, tideStateAtGun: 0),
                            wind: { $0 >= shiftTick ? shifted : base })
            self.leg = leg
            self.shiftTick = shiftTick
            for _ in 0..<(race.setup.startSequenceTicks + Race.tickRate) { race.step() }

            let length = race.boatClass.hull.length
            let forward = Vec2.heading(heading)
            let toWindward = starboard ? forward.rightPerp : -forward.rightPerp
            let angle = abs(wrapAngle(base.direction - heading))
            let speed = race.boatClass.polar.speed(twa: angle, tws: base.speed)
            var snapshot = race.exportSnapshot()
            for seat in 0..<2 {
                var boat = snapshot.seats[seat].boat
                boat.position = seat == 0 ? at : at + toWindward * (length * abeam) + forward * (length * ahead)
                boat.heading = heading
                boat.speed = speed
                boat.boomSide = starboard ? .port : .starboard
                boat.status = .racing
                boat.legIndex = leg
                boat.roundingStage = 0
                boat.autohelm = Autohelm(target: .angle(angle))
                boat.rudder = 0
                boat.desiredRudder = 0
                boat.isTacking = false
                snapshot.seats[seat].boat = boat
                snapshot.seats[seat].heldInput = .neutral
            }
            snapshot.touchingBoats = []
            snapshot.overlaps = [.init(pair: .init(0, 1), isOverlapped: ahead == 0, changeTicks: 0)]
            try race.importSnapshot(snapshot)
            _ = race.drainEvents()
            if restricted {
                race.umpire?.setProperCourse(ProperCourseRecord(leeward: 0, windward: 1),
                                             for: SeatPair(0, 1))
            }
        }

        /// Seat 0's sailing angle now: her heading's angle off the wind she sails in.
        var leewardAngle: Double { abs(wrapAngle(race.boats[0].sailingWind.direction - race.boats[0].heading)) }

        /// Sails both bots at skill 1 for `seconds`, seat 0's with the proper-course limit unless `limit` is false:
        /// every event, and `each` after every step.
        func sail(seconds: Double, limit: Bool = true, each: (Race) -> Void = { _ in }) -> [RaceEvent.Kind] {
            var pilots = [0, 1].map { Pilot(seat: $0, plannedTack: nil, race: race) }
            pilots[0].brain.limitsProperCourse = limit
            var kinds: [RaceEvent.Kind] = []
            for _ in 0..<Int(seconds * Double(Race.tickRate)) where !race.isOver {
                for i in pilots.indices { _ = pilots[i].drive(race) }
                race.step()
                each(race)
                kinds += race.drainEvents().map(\.kind)
            }
            return kinds
        }

        /// Every decision seat 0's bot makes over `seconds`, with the proper-course limit unless `limit` is false.
        func decisions(seconds: Double, limit: Bool) -> [BotDecision] {
            var pilots = [0, 1].map { Pilot(seat: $0, plannedTack: nil, race: race) }
            pilots[0].brain.limitsProperCourse = limit
            var decisions: [BotDecision] = []
            for _ in 0..<Int(seconds * Double(Race.tickRate)) where !race.isOver {
                if let decision = pilots[0].drive(race) { decisions.append(decision) }
                _ = pilots[1].drive(race)
                race.step()
                _ = race.drainEvents()
            }
            return decisions
        }
    }

    /// The shift that carries her held angle above her proper course: past the reach's tolerance (8°) by 4°.
    static let reachShift = deg2rad(12)
    /// Seeds the reach is sailed on.
    static let reachSeeds: [UInt64] = [1, 2, 3]

    /// #346 acceptance: a restricted leeward bot on a reach in a shift that carries her held angle above the bearing
    /// to the mark (her proper course) does not steer above proper course plus tolerance: from a couple of seconds
    /// after the shift, while the notice is told her, her sailing angle is never closer to the wind than the edge.
    /// The same bot without the limit stays above it, so the limit is what bears her away.
    @Test(arguments: reachSeeds)
    func restrictedLeewardBotOnAReachInAHeaderStaysWithinProperCourse(seed: UInt64) throws {
        let reach = try Reach(seed: seed, shift: Self.reachShift, restricted: true)
        let settled = reach.shiftTick + 2 * Race.tickRate
        var restrictedTicks = 0
        var worst = Double.infinity
        let kinds = reach.sail(seconds: 8) { race in
            guard race.tick >= settled, let notice = race.seatView(for: 0).own.properCourse else { return }
            restrictedTicks += 1
            worst = min(worst, reach.leewardAngle - notice.edgeSailingAngle)
        }
        #expect(restrictedTicks >= 3 * Race.tickRate, "the record held \(restrictedTicks) ticks after the shift settled")
        #expect(worst >= 0, "she sailed \(rad2deg(-worst))° above her proper course's edge")
        #expect(!Self.calls(kinds).contains { $0.hasPrefix("17 ") }, "\(Self.calls(kinds))")

        let free = try Reach(seed: seed, shift: Self.reachShift, restricted: true)
        var above = 0
        _ = free.sail(seconds: 8, limit: false) { race in
            guard race.tick >= settled, let notice = race.seatView(for: 0).own.properCourse else { return }
            if free.leewardAngle < notice.edgeSailingAngle { above += 1 }
        }
        #expect(above > 0, "without the limit she never sailed above the edge: the scenario tests nothing")
    }

    /// #346 acceptance: a bot not restricted (no rule 17 record open: the overlap was placed, not made from astern)
    /// steers as today: no notice is told her, and every decision she makes is the one she makes with the limit left
    /// out.
    @Test(arguments: reachSeeds)
    func botNotRestrictedSteersAsToday(seed: UInt64) throws {
        let limited = try Reach(seed: seed, shift: Self.reachShift, restricted: false)
        var notices = 0
        let withLimit = limited.decisions(seconds: 8, limit: true)
        let free = try Reach(seed: seed, shift: Self.reachShift, restricted: false)
        let withoutLimit = free.decisions(seconds: 8, limit: false)
        for seat in 0..<2 where limited.race.seatView(for: seat).own.properCourse != nil { notices += 1 }
        #expect(notices == 0)
        #expect(limited.race.umpire?.properCourse(SeatPair(0, 1)) == nil)
        #expect(!withLimit.isEmpty && withLimit == withoutLimit)
        #expect(limited.race.boats.map(\.position) == free.race.boats.map(\.position)
                && limited.race.boats.map(\.heading) == free.race.boats.map(\.heading))
    }

    /// #337 round 4: clear astern of a boat close ahead on a reach, in a header that carries her held angle above the
    /// bearing to the mark, a bot already sails no higher than her proper course before any overlap (no notice yet):
    /// one that made the overlap to leeward above it, too close for the windward boat to keep clear at once, was
    /// called under rule 17 on that tick (seed 2, mixed 16, seat 7 in `BotRule17SuiteTests`). Without the limit she
    /// stays above it.
    @Test(arguments: reachSeeds)
    func clearAsternOnAReachSailsWithinProperCourseBeforeTheOverlap(seed: UInt64) throws {
        let reach = try Reach(seed: seed, shift: Self.reachShift, restricted: false, abeam: 0.5, ahead: 2)
        let settled = reach.shiftTick + 2 * Race.tickRate
        func properAngle(_ race: Race) -> Double? {
            race.boats[0].properCourse(on: race.course, boatClass: race.boatClass)?.sailingAngle
        }
        func astern(_ race: Race) -> Bool {
            race.seatView(for: 0).others[0].rightOfWay == RightOfWay(keepClear: 0, rule: .clearAstern)
        }
        var asternTicks = 0
        var worst = Double.infinity
        let kinds = reach.sail(seconds: 6) { race in
            guard race.tick >= settled, astern(race), let proper = properAngle(race) else { return }
            #expect(race.seatView(for: 0).own.properCourse == nil)
            asternTicks += 1
            worst = min(worst, reach.leewardAngle - proper)
        }
        #expect(asternTicks >= 2 * Race.tickRate, "clear astern \(asternTicks) ticks after the shift settled")
        #expect(worst >= -deg2rad(1), "she sailed \(rad2deg(-worst))° above her proper course while clear astern")
        #expect(!Self.calls(kinds).contains { $0.hasPrefix("17 ") }, "\(Self.calls(kinds))")

        let free = try Reach(seed: seed, shift: Self.reachShift, restricted: false, abeam: 0.5, ahead: 2)
        var above = 0
        _ = free.sail(seconds: 6, limit: false) { race in
            guard race.tick >= settled, astern(race), let proper = properAngle(race) else { return }
            if free.leewardAngle < proper - deg2rad(8) { above += 1 }
        }
        #expect(above > 0, "without the limit she never sailed above her proper course's edge: the scenario tests nothing")
    }

    // MARK: - The limiter

    /// A view of seat 0 on the reach, restricted (rule 17 record open) unless `restricted` is false.
    static func reachView(restricted: Bool = true) throws -> SeatView.OwnBoat {
        try Reach(seed: 1, shift: 0, restricted: restricted).race.seatView(for: 0).own
    }

    /// `properCourseLimited` alone: no notice, her aim unchanged; an aim whose held angle may sit inside the edge
    /// plus the margin is borne away to it plus her slack, the groove dropped; one already far enough off the wind,
    /// unchanged; a reach's wide slack narrowed so her held angle can't drift past the edge.
    @Test func properCourseLimitHoldsHerAimWithinTheEdge() throws {
        let free = try Self.reachView(restricted: false)
        #expect(free.properCourse == nil)
        let pinch = Aim(angle: deg2rad(30), tack: free.tack)
        #expect(BotBrain.properCourseLimited(pinch, free) == pinch)

        let own = try Self.reachView()
        let notice = try #require(own.properCourse)
        let lowest = notice.edgeSailingAngle + BotBrain.properCourseMargin
        // Pinched well above the edge: borne away to the edge, the margin and her slack, as an angle.
        var groove = Aim.groove(.upwind, tack: own.tack, angle: notice.edgeSailingAngle - deg2rad(10))
        groove.ease = true
        let limited = BotBrain.properCourseLimited(groove, own)
        #expect(abs(limited.angle - (lowest + deg2rad(1.5))) < 1e-12)
        #expect(limited.groove == nil && limited.tack == own.tack && limited.ease && limited.tolerance == deg2rad(1.5))
        // The aim's own slack, when tighter, is what she keeps clear of the edge by.
        let tight = BotBrain.properCourseLimited(Aim(angle: lowest - 0.1, tack: own.tack, tolerance: deg2rad(0.5)), own)
        #expect(abs(tight.angle - (lowest + deg2rad(0.5))) < 1e-12 && tight.tolerance == deg2rad(0.5))
        // At her proper course with the default slack: nothing to do.
        let proper = Aim(angle: notice.sailingAngle, tack: own.tack)
        #expect(BotBrain.properCourseLimited(proper, own) == proper)
        // A reach aim just inside the edge, whose 5° slack would let her held angle drift past it: same angle,
        // slack narrowed.
        let wide = Aim(angle: lowest + deg2rad(2), tack: own.tack, tolerance: BotBrain.reachTolerance)
        let narrowed = BotBrain.properCourseLimited(wide, own)
        #expect(narrowed.angle == wide.angle && narrowed.tolerance == deg2rad(1.5))
        // Deep downwind: unchanged, whichever tack.
        let deep = Aim.groove(.downwind, tack: own.tack == .port ? .starboard : .port, angle: deg2rad(150))
        #expect(BotBrain.properCourseLimited(deep, own) == deep)
    }
}

extension SeatViewTests {
    /// #346 acceptance: the proper-course notice is set and cleared with the rule 17 record. Told the leeward boat
    /// alone, while the record holds, carrying the umpire's proper course for her (`Boat.properCourse`) and the rules
    /// file's tolerance for the leg; gone once the record ends, by separation or by the umpire forgetting it; never
    /// in a prediction, which holds no umpire.
    @Test func properCourseNoticeIsSetAndClearedWithTheRecord() throws {
        let reach = try BotConductTests.Reach(seed: 1, shift: 0, restricted: false)
        let race = reach.race
        #expect(race.seatView(for: 0).own.properCourse == nil && race.seatView(for: 1).own.properCourse == nil)

        race.umpire?.setProperCourse(ProperCourseRecord(leeward: 0, windward: 1), for: SeatPair(0, 1))
        let notice = try #require(race.seatView(for: 0).own.properCourse)
        #expect(race.seatView(for: 1).own.properCourse == nil)
        let proper = try #require(race.boats[0].properCourse(on: race.course, boatClass: race.boatClass))
        let limits = try #require(race.rules.incidents.properCourse)
        #expect(proper.kind == .reach)
        #expect(notice == SeatView.ProperCourseNotice(windward: [1], sailingAngle: proper.sailingAngle,
                                                      heading: proper.heading, tolerance: limits.tolerance(.reach)))
        #expect(notice.edgeSailingAngle == proper.edgeSailingAngle(tolerance: limits.reachRunTolerance))

        // It holds tick by tick while the record does, following her proper course.
        for _ in 0..<Race.tickRate {
            race.step()
            let record = race.umpire?.properCourse(SeatPair(0, 1))
            let view = race.seatView(for: 0).own.properCourse
            #expect((record != nil) == (view != nil))
            if view != nil {
                let now = try #require(race.boats[0].properCourse(on: race.course, boatClass: race.boatClass))
                #expect(view?.heading == now.heading && view?.sailingAngle == now.sailingAngle)
            }
        }
        #expect(race.umpire?.properCourse(SeatPair(0, 1)) != nil, "the record held through a second's sailing")

        // A prediction holds no umpire: no notice.
        let prediction = try Race(setup: race.setup, files: race.files, mode: .prediction(revealedWindKeys: []),
                                  current: CurrentField(current: nil, tideStateAtGun: 0),
                                  wind: { _ in GroundWind(direction: wrapAngle(race.course.axis), speed: 5) })
        try prediction.importSnapshot(race.exportSnapshot())
        #expect(prediction.seatView(for: 0).own.properCourse == nil)

        // Separated beyond two lengths: the record ends, and the notice with it.
        var snapshot = race.exportSnapshot()
        let away = Vec2.heading(race.boats[1].heading).rightPerp * (race.boatClass.hull.length * 6)
        snapshot.seats[1].boat.position = race.boats[1].position + away * (race.boats[0].boomSide == .port ? 1 : -1)
        try race.importSnapshot(snapshot)
        race.umpire?.setProperCourse(ProperCourseRecord(leeward: 0, windward: 1), for: SeatPair(0, 1))
        #expect(race.seatView(for: 0).own.properCourse != nil)
        race.step()
        #expect(race.umpire?.properCourse(SeatPair(0, 1)) == nil)
        #expect(race.seatView(for: 0).own.properCourse == nil)

        // Forgotten by the umpire (an import): gone too.
        race.umpire?.setProperCourse(ProperCourseRecord(leeward: 0, windward: 1), for: SeatPair(0, 1))
        try race.importSnapshot(race.exportSnapshot())
        #expect(race.seatView(for: 0).own.properCourse == nil)
    }

    /// #346: the notice ends with the record when the windward boat tacks away (#345's tack end path): two boats
    /// beating on starboard a hull length apart, seat 0 to leeward held to her proper course against seat 1; seat 1
    /// puts her helm hard up through the wind. On the first tick the record is gone she is tacking (or on port), and
    /// the pair are still overlapped within two lengths: it's the tack that ended it.
    @Test func properCourseNoticeClearsOnATack() throws {
        let water = BotConductTests.Water(seed: 3)
        let heading = water.beat(.starboard)
        let forward = Vec2.heading(heading)
        let race = try BotConductTests.place(water, [
            .init(position: water.centre, heading: heading, speed: water.up.speed),
            .init(position: water.centre + forward.rightPerp * water.length - forward * water.length * 0.2,
                  heading: heading, speed: water.up.speed),
        ]) { snapshot in
            snapshot.touchingBoats = []
            snapshot.overlaps = [.init(pair: .init(0, 1), isOverlapped: true, changeTicks: 0)]
        }
        race.umpire?.setProperCourse(ProperCourseRecord(leeward: 0, windward: 1), for: SeatPair(0, 1))
        #expect(race.seatView(for: 0).own.properCourse?.windward == [1])
        // Hard to starboard: on starboard tack, towards the wind and through it.
        _ = race.apply(BoatInput(rudder: 1.0), seat: 1, atTick: race.tick + 1)
        var ended: (tacked: Bool, near: Bool)?
        for _ in 0..<(5 * Race.tickRate) where ended == nil {
            race.step()
            _ = race.drainEvents()
            if race.umpire?.properCourse(SeatPair(0, 1)) == nil {
                #expect(race.seatView(for: 0).own.properCourse == nil)
                ended = (race.boats[1].isTacking || race.boats[1].boomSide != race.boats[0].boomSide,
                         (race.boats[0].position - race.boats[1].position).length - water.length <= 2 * water.length
                             && race.overlaps.isOverlapped(0, 1))
            } else {
                #expect(race.seatView(for: 0).own.properCourse != nil)
            }
        }
        let end = try #require(ended, "the record outlasted the windward boat's tack")
        #expect(end.tacked && end.near)
    }

    /// #346: the notice ends with the record when rule 18 takes over (#345's rule 18 end path): the pair a length
    /// and a half short of the offset mark, in its zone, still overlapped on the same tack within two lengths.
    @Test func properCourseNoticeClearsWhenRule18TakesOver() throws {
        let reach = try BotConductTests.Reach(seed: 1, shift: 0, restricted: true, abeam: 1.5, fromMark: 1.5)
        let race = reach.race
        let length = race.boatClass.hull.length
        #expect(race.seatView(for: 0).own.properCourse?.windward == [1])
        #expect(race.seatView(for: 0).own.zone != nil && race.seatView(for: 1).own.zone != nil)
        race.step()
        _ = race.drainEvents()
        #expect(race.umpire?.properCourse(SeatPair(0, 1)) == nil)
        #expect(race.seatView(for: 0).own.properCourse == nil)
        #expect(race.overlaps.isOverlapped(0, 1) && race.boats[0].boomSide == race.boats[1].boomSide
            && !race.boats.contains(where: \.isTacking)
            && (race.boats[0].position - race.boats[1].position).length - length <= 2 * length)

        // The same pair clear of the zone keeps the record over that tick: it is rule 18 that ended it.
        let clear = try BotConductTests.Reach(seed: 1, shift: 0, restricted: true, abeam: 1.5)
        clear.race.step()
        #expect(clear.race.seatView(for: 0).own.properCourse != nil)
    }
}
