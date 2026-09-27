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
        let style = BotStyle(skill: 0.4, startSpot: 0.5, finishSpot: 0.7, holdDepth: 20, timingSlack: 0, penaltyDirection: 1)
        var driver = BotDriver(seat: 0, raceSeed: race.setup.raceSeed, style: style)
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
        let style = BotStyle(skill: 0.4, startSpot: 0.5, finishSpot: 0.7, holdDepth: 20, timingSlack: 0, penaltyDirection: 1)
        var driver = BotDriver(seat: 0, raceSeed: race.setup.raceSeed, style: style)
        for _ in 0..<(10 * Race.tickRate) {
            driver.drive(race)
            race.step()
        }
        #expect(race.boats[0].autohelm?.target == .groove(.upwind))
        #expect(race.heldInputs[0].rudder == 0)
    }

    /// The bot suite's profiles (#231): the baseline sails the groove only; the tactician leaves it.
    @Test func profilesSetWhatTheBotPlays() {
        let baseline = Tactics(profile: .baseline, skill: 0.9)
        let tactician = Tactics(profile: .tactician, skill: 0.1)
        #expect(!baseline.replanes && !baseline.heatsUpInLulls && !baseline.pinchesToFetch)
        #expect(!baseline.seeksPuffs && !baseline.seeksClearAir && !baseline.covers)
        #expect(baseline.downwindShiftThreshold == nil && baseline.anticipation == 0)
        #expect(tactician.replanes && tactician.heatsUpInLulls && tactician.pinchesToFetch)
        #expect(tactician.seeksPuffs && tactician.seeksClearAir && tactician.covers)
        #expect(tactician.corridor > baseline.corridor)
        // A profile's play doesn't come from the bot's skill; a live bot's does.
        #expect(Tactics(profile: .baseline, skill: 0.1) == baseline)
        #expect(Tactics(profile: nil, skill: 0.4).headerThreshold == nil)
        #expect(Tactics(profile: nil, skill: 0.9).headerThreshold != nil)
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
