import Testing
import RegattaCore
@testable import RegattaBots

@Suite struct BotBrainTests {
    /// A race with seat 0 a bot beating up the first leg on starboard, clear of every mark and boat and well
    /// inside her corridor to the mark, `offGroove` radians further off the wind than her groove with nobody
    /// holding her rudder; seat 1, nobody's, far off to one side.
    static func beatingRace(seed: UInt64, offGroove: Double) throws -> Race {
        let race = botRace(seats: [.bot, .human], seed: seed)
        let c = race.course
        let lineCentre = (c.startLine.pin.position + c.startLine.committee.position) * 0.5
        var snapshot = race.exportSnapshot()
        for seat in 0..<2 {
            snapshot.seats[seat].boat.status = .racing
            snapshot.seats[seat].boat.speed = 3
            snapshot.seats[seat].boat.autohelm = nil
            snapshot.seats[seat].heldInput = .neutral
        }
        let groove = race.boatClass.polar.bestUpwind(tws: race.windSetup.baseStrength).twa
        snapshot.seats[0].boat.position = lineCentre + c.upwind * (c.beat * 0.3) + c.right * 40
        snapshot.seats[0].boat.heading = c.axis - (groove + offGroove)
        snapshot.seats[0].boat.boomSide = .port
        snapshot.seats[1].boat.position = lineCentre + c.upwind * (c.beat * 0.3) - c.right * 150
        try race.importSnapshot(snapshot)
        return race
    }

    /// #231 acceptance: a bot steers to its target wind angle, then centres the rudder and leaves her to the
    /// autohelm (ADR 0007). Once she's on it, the rudder it holds is 0 until a decision changes the aim: no
    /// heading tracking between decisions, however the wind moves under her.
    @Test func botCentresRudderOnTarget() throws {
        let race = try Self.beatingRace(seed: 5, offGroove: deg2rad(20))
        // Skill 0.4: a bot that doesn't tack on headers, so nothing changes her aim, the starboard groove.
        let style = BotStyle(skill: 0.4, startSpot: 0.5, finishSpot: 0.7, timingSlack: 0, penaltyDirection: 1)
        var driver = BotDriver(seat: 0, raceSeed: race.setup.raceSeed, style: style,
                               weaknesses: .none(skill: style.skill)) // the mechanism alone, no misjudged grooves (#102)
        var decisions: [BotDecision] = []
        var headings: [(tick: Int, heading: Double)] = []
        for _ in 0..<(25 * Race.tickRate) {
            if let decision = driver.drive(race) { decisions.append(decision) }
            race.step()
            headings.append((race.tick, race.boats[0].heading))
        }
        #expect(decisions.allSatisfy { $0.tap == nil }, "she stays on starboard")
        #expect(decisions.first.map { $0.input.rudder != 0 } == true, "she steers up to the groove first")
        let centred = try #require(decisions.firstIndex { $0.input.rudder == 0 }, "she centres the rudder")
        let held = decisions[centred...].filter { $0.input.rudder != 0 }
        #expect(held.isEmpty, "rudder held after centring: \(held.map(\.input.rudder))")
        #expect(race.heldInputs[0].rudder == 0)
        #expect(race.boats[0].autohelm?.target == .groove(.upwind), "the autohelm snapped to the groove and holds it")

        // The race logged no held input for her after the centring: the autohelm sailed her from then on.
        let log = try #require(race.log)
        let centredTick = log.inputs.filter { $0.seat == 0 }.map(\.tick).max() ?? 0
        #expect(centredTick < race.tick - 20 * Race.tickRate, "last input at tick \(centredTick), race at \(race.tick)")
        // And the wind moved her heading while the rudder stayed centred.
        let afterCentring = headings.filter { $0.tick > centredTick }.map(\.heading)
        #expect((afterCentring.max() ?? 0) - (afterCentring.min() ?? 0) > deg2rad(0.1))
    }

    /// Off the groove by less than the autohelm's snap, she still centres on it: close to the groove, the
    /// autohelm takes it over (ADR 0007).
    @Test func botLetsTheAutohelmSnapToTheGroove() throws {
        let race = try Self.beatingRace(seed: 6, offGroove: deg2rad(2))
        let style = BotStyle(skill: 0.4, startSpot: 0.5, finishSpot: 0.7, timingSlack: 0, penaltyDirection: 1)
        var driver = BotDriver(seat: 0, raceSeed: race.setup.raceSeed, style: style,
                               weaknesses: .none(skill: style.skill)) // the mechanism alone, no misjudged grooves (#102)
        for _ in 0..<(10 * Race.tickRate) {
            driver.drive(race)
            race.step()
        }
        #expect(race.boats[0].autohelm?.target == .groove(.upwind))
        #expect(race.heldInputs[0].rudder == 0)
    }

    /// #82: the race area's edge is folded into keeping clear, as a mark is. Seat 0, close-hauled on port,
    /// must keep clear of seat 1 on starboard, crossing ahead of her in four seconds. In open water she
    /// ducks, bearing away by the least turn that passes astern of seat 1 (`racingKeepClear`, #101); with the
    /// race area's side a little to leeward, the duck would sail her into it, so she turns off it to the
    /// nearest heading that stays in the area. Nowhere near the edge, she ducks as ever.
    @Test func keepingClearNearTheEdgeTurnsOffIt() throws {
        func evasive(inFromTheSide inward: Double) throws -> (heading: Double?, duck: Double, view: SeatView) {
            let race = botRace(seats: [.bot, .human], seed: 7)
            let c = race.course
            let wind = race.seatView(for: 0).own.windDirection
            let speed = 3.0
            let port = Vec2.heading(wind + deg2rad(45)) * speed, starboard = Vec2.heading(wind - deg2rad(45)) * speed
            let position = c.raceArea.centre + c.right * (c.raceArea.halfWidth - inward)
            var snapshot = race.exportSnapshot()
            for seat in 0..<2 {
                snapshot.seats[seat].boat.status = .racing
                snapshot.seats[seat].boat.speed = speed
                snapshot.seats[seat].boat.autohelm = nil
                snapshot.seats[seat].heldInput = .neutral
            }
            snapshot.seats[0].boat.position = position
            snapshot.seats[0].boat.heading = wind + deg2rad(45)
            snapshot.seats[0].boat.boomSide = .starboard
            // Where she'll be in 4 s, seat 1 will be too.
            snapshot.seats[1].boat.position = position + (port - starboard) * 4
            snapshot.seats[1].boat.heading = wind - deg2rad(45)
            snapshot.seats[1].boat.boomSide = .port
            try race.importSnapshot(snapshot)
            let view = race.seatView(for: 0)
            #expect(view.own.tack == .port && view.others[0].rightOfWay?.keepClear == 0)
            let brain = BotBrain(style: BotStyle(skill: 0.5, startSpot: 0.5, finishSpot: 0.7, timingSlack: 0, penaltyDirection: 1))
            // Her give-way manoeuvre under rule 10, the edge aside.
            let duck = brain.racingKeepClear(view.own, view, from: view.others[0], rule: .portStarboard,
                                             desired: view.own.heading, lookahead: brain.keepClearLookahead)
            return (brain.evasiveHeading(view.own, view, desired: view.own.heading), duck, view)
        }
        /// Her sailing angle on `heading`, off the wind.
        func offWind(_ heading: Double, _ view: SeatView) -> Double { wrapAngle(heading - view.own.windDirection) }
        /// Whether sailing `heading` keeps her in the race area as far ahead as a bot looks for its edge.
        func staysIn(_ heading: Double, _ view: SeatView) -> Bool {
            let ahead = max(view.own.speed, 1) * BotBrain.edgeLookahead + view.boatClass.hull.length
            return view.course.isInRaceArea(view.own.position + Vec2.heading(heading) * ahead)
        }

        let open = try evasive(inFromTheSide: 150)
        #expect(open.heading == open.duck, "in open water she ducks")
        #expect(offWind(open.duck, open.view) > offWind(open.view.own.heading, open.view) + deg2rad(20),
                "the duck bears her away")

        let near = try evasive(inFromTheSide: 12)
        #expect(staysIn(near.view.own.heading, near.view), "her own course stays in the area")
        #expect(!staysIn(near.duck, near.view), "the duck would sail her into the side")
        let heading = try #require(near.heading)
        #expect(staysIn(heading, near.view))
        // Turned off the edge from the duck to the nearest heading, of the 10° steps she tries either way, that stays
        // in; on her own tack, and never into the no-go zone.
        let angle = offWind(heading, near.view), step = deg2rad(10)
        #expect(angle >= deg2rad(38) - 1e-9 && angle <= .pi)
        let steps = Int((abs(angle - offWind(near.duck, near.view)) / step).rounded())
        #expect(steps >= 1)
        for nearer in 0..<steps {
            for way in [-1.0, 1.0] {
                #expect(!staysIn(near.duck + way * Double(nearer) * step, near.view), "a nearer heading stays in")
            }
        }
    }

    /// The bot suite's profiles (#231): the baseline sails the groove only; the tactician leaves it.
    @Test func profilesSetWhatTheBotPlays() throws {
        let baseline = Tactics(profile: .baseline, skill: 0.9)
        let tactician = Tactics(profile: .tactician, skill: 0.1)
        #expect(!baseline.replanes && !baseline.heatsUpInLulls && !baseline.pinchesToFetch)
        #expect(!baseline.seeksPuffs && !baseline.seeksClearAir && !baseline.covers)
        #expect(baseline.downwindShiftThreshold == nil && baseline.anticipation == 0)
        #expect(tactician.replanes && tactician.heatsUpInLulls && tactician.pinchesToFetch)
        #expect(tactician.seeksPuffs && tactician.seeksClearAir && tactician.covers)
        #expect(tactician.corridor > baseline.corridor)
        // #238: the blip-tacker is the baseline tacking on every header past 3°, the wobble's size (#221).
        var blipTacker = Tactics(profile: .blipTacker, skill: 0.9)
        #expect(blipTacker.headerThreshold == deg2rad(3))
        blipTacker.headerThreshold = baseline.headerThreshold
        #expect(blipTacker == baseline)
        // A profile's play doesn't come from the bot's skill; a live bot's does.
        #expect(Tactics(profile: .baseline, skill: 0.1) == baseline)
        // #102: a live bot plays shifts at any skill, the smaller ones the more skilled she is.
        let club = try #require(Tactics(profile: nil, skill: 0.4).headerThreshold)
        let national = try #require(Tactics(profile: nil, skill: 0.9).headerThreshold)
        #expect(national < club)
    }

    /// Beating to the windward mark (rounded to port), a boat below the starboard layline aims first at the
    /// lead point down that layline, right of the mark, not straight at the fetch point: a port track there
    /// would run over the mark. On the layline she aims at the fetch point itself, and so does a boat on
    /// starboard close in whose course clears the mark by the room she needs: she holds on and rounds,
    /// rather than tack out to a lead point abeam of her and tack back.
    @Test func belowTheLaylineSheAimsAtItsLeadPoint() {
        let mark = Vec2(0, 0)
        let upwind = Vec2.heading(0)
        let fetch = mark + upwind.rightPerp * 6 + upwind * 4
        let wind = 0.0
        let groove = deg2rad(42)
        let room = 4.5
        func approach(from position: Vec2, on tack: Tack) -> Vec2 {
            BotBrain.windwardApproach(from: position, tack: tack, mark: mark, room: room, fetch: fetch, wind: wind,
                                      groove: groove, upwind: upwind)
        }
        let starboardCloseHauled = Vec2.heading(wind - groove)

        // Straight below the mark, well short of the starboard layline, on either tack.
        let lead = approach(from: mark - upwind * 300, on: .port)
        #expect(approach(from: mark - upwind * 300, on: .starboard) == lead)
        #expect(lead != fetch, "she doesn't sail straight at the fetch point")
        #expect(((lead - fetch).length - BotBrain.laylineLead).magnitude < 1e-9, "\(BotBrain.laylineLead) m from it")
        #expect((lead - mark).dot(upwind.rightPerp) > 6, "right of the mark and the fetch point")
        #expect((fetch - lead).dot(upwind) > 0, "below the fetch point")
        #expect(wrapAngle((fetch - lead).bearing - starboardCloseHauled.bearing).magnitude < 1e-9,
                "on the starboard layline: close-hauled on starboard from it fetches the mark")

        // On the starboard layline, below the lead point: the fetch point.
        #expect(approach(from: fetch - starboardCloseHauled * 200, on: .starboard) == fetch)

        // Close in, just below the lead point and inside the layline, the lead point is almost abeam. On
        // starboard with her course clearing the mark by `room` or more, she holds on for the fetch point; on
        // port, or on a starboard course that would pass the mark closer, she sails for the lead point.
        let inside = lead - starboardCloseHauled * 1.5
        let lays = inside - starboardCloseHauled.rightPerp * 1.5
        let short = inside - starboardCloseHauled.rightPerp * 4
        #expect(-(mark - lays).dot(starboardCloseHauled.rightPerp) > room)
        #expect(-(mark - short).dot(starboardCloseHauled.rightPerp) < room)
        #expect(approach(from: lays, on: .starboard) == fetch, "she lays the mark: she holds on and rounds")
        #expect(approach(from: lays, on: .port) == lead)
        #expect(approach(from: short, on: .starboard) == lead, "her course passes too close to the mark")
    }

    /// Off the plane in a breeze, the skiff heads up until she can plane, well above the downwind groove;
    /// in a wind too light to plane at any angle, she doesn't.
    @Test func offThePlaneSheHeadsUpToPlane() throws {
        let skiff = try BoatClassFile.bundled(id: "skiff", version: 1).content
        let knots = 0.514444
        let deep = Autohelm.grooveAngle(.downwind, tws: 12 * knots, boatClass: skiff)
        let angle = try #require(BotBrain.planingAngle(tws: 12 * knots, deepest: deep, skiff))
        #expect(angle < deep - skiff.steering.autohelm.downwindSnap)
        #expect(angle >= skiff.planing!.fromTWA)
        #expect(BotBrain.planingAngle(tws: 5 * knots, deepest: deep, skiff) == nil)
    }
}
