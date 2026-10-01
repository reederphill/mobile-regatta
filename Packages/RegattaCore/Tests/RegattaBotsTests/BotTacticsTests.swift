import Testing
@testable import RegattaCore
@testable import RegattaBots

/// #290: a tactician reads the pressure over the race area (`SeatView.PressureMap`) and weighs it against the shift.
/// #234: a live bot plays the boats around her (`BotBrain+Fleet.swift`): she covers, lee-bows, tacks on a boat's wind and
/// holds her lane, as willing as her engagement and as well as her skill, every tack clear (rules 13 and 15).
@Suite struct BotTacticsTests {
    /// Seat 0's view in `BotBrainTests.beatingRace`, on starboard up the first beat, with its pressure map made
    /// from `pressure`: the pressure at a place from how far right of her it is, and how far up the course, metres.
    /// No puff or lull on the water, so the pressure alone is what she reads.
    static func view(seed: UInt64 = 290, _ pressure: (_ across: Double, _ along: Double) -> Pressure) throws -> SeatView {
        let race = try BotBrainTests.beatingRace(seed: seed, offGroove: 0)
        var view = race.seatView(for: 0)
        let area = race.course.raceArea
        let columns = SeatView.PressureMap.gridColumns, rows = SeatView.PressureMap.gridRows
        let right = Vec2.heading(area.axis).rightPerp, up = Vec2.heading(area.axis)
        var nodes: [Pressure] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let offset = SeatView.PressureMap.position(column: column, row: row, area, columns, rows) - view.own.position
                nodes.append(pressure(offset.dot(right), offset.dot(up)))
            }
        }
        view.puffs = []
        view.pressure = SeatView.PressureMap(area: area, tick: view.tick, columns: columns, rows: rows, nodes: nodes)
        return view
    }

    /// The tack `profile`'s bot beats on from starboard in `view`, the shift neutral: the wind she reads is the
    /// course's own direction, turning no way.
    static func tack(_ profile: BotProfile, _ view: SeatView) -> Tack {
        var brain = BotBrain(style: BotStyle(skill: 0.9, startSpot: 0.5, finishSpot: 0.7, timingSlack: 0, penaltyDirection: 1),
                             profile: profile)
        brain.observe(view.own, view)
        brain.senses.direction = view.course.axis
        brain.senses.directionRate = 0
        return brain.upwindTack(view.own, view, planned: .starboard)
    }

    /// Given a clear pressure side and a neutral shift, the tactician heads for the pressure: on starboard, sailing
    /// left, with more pressure to the right she tacks onto port; with it on the left she holds on. The baseline
    /// never reads it, and nor does she tack in even pressure.
    @Test func goesToThePressure() throws {
        let area = try BotBrainTests.beatingRace(seed: 290, offGroove: 0).course.raceArea
        let right = try Self.view { across, _ in Pressure(factor: 1 + 0.3 * across / area.halfWidth, turn: 0) }
        let left = try Self.view { across, _ in Pressure(factor: 1 - 0.3 * across / area.halfWidth, turn: 0) }
        let even = try Self.view { _, _ in Pressure(factor: 1, turn: 0) }
        #expect(Self.tack(.tactician, even) == .starboard)
        #expect(Self.tack(.tactician, right) == .port)
        #expect(Self.tack(.tactician, left) == .starboard)
        #expect(Self.tack(.baseline, right) == .starboard)
    }

    /// A pressure lane along the wind to her right, 300 m wide and as strong as the conditions draw one, its near edge
    /// 100 m off, the shift neutral: the wind in it veers on one edge and backs on the other (CONTEXT.md, "Pressure
    /// lane"). On starboard, the tactician tacks onto port to enter it when its near edge backs, lifting her on port;
    /// when that edge veers, which would head her on port, she holds on, though the lane's pressure is the same.
    @Test func takesTheLiftingEdge() throws {
        func lane(backingNearEdge: Bool) throws -> SeatView {
            try Self.view { across, _ in
                let d = (across - 250) / 150
                guard abs(d) < 1 else { return Pressure(factor: 1, turn: 0) }
                let f = (1 - d * d) * (1 - d * d)
                // The bend peaks at 6°, where f·d does, at d = 1/√5.
                let bend = deg2rad(6) * f * d / 0.2862
                return Pressure(factor: 1 + 0.15 * f, turn: backingNearEdge ? bend : -bend)
            }
        }
        let lifting = try lane(backingNearEdge: true)
        let heading = try lane(backingNearEdge: false)
        // Near edge: d < 0, so a backing (negative) turn there with `bend` as it is.
        let nearEdge = lifting.pressure!.sample(at: lifting.own.position + Vec2.heading(lifting.course.axis).rightPerp * 180)!
        #expect(nearEdge.turn < 0 && nearEdge.factor > 1)
        #expect(Self.tack(.tactician, lifting) == .port)
        #expect(Self.tack(.tactician, heading) == .starboard)
        #expect(Self.tack(.baseline, lifting) == .starboard)
    }

    // MARK: - Fleet tactics (#234)

    /// Open water a third of the way up seed `seed`'s first beat after the gun, nobody placed yet, the seats as given,
    /// in a steady wind: the wind there at the gun, held, so no shift plays a part in what a bot does there. The wind,
    /// the best upwind in it, and the boats' hull length.
    struct Scene {
        let race: Race
        let wind: Double
        let up: PolarTable.Optimum
        let centre: Vec2
        let length: Double

        init(seats: [SeatKind] = [.bot, .bot], seed: UInt64) {
            let drawn = botRace(seats: seats, seed: seed)
            for _ in 0..<(drawn.setup.startSequenceTicks + Race.tickRate) { drawn.step() }
            let c = drawn.course
            centre = c.startLine.centre + c.upwind * (c.beat * 0.35)
            let wind = drawn.groundWind(at: centre)
            race = try! Race(setup: drawn.setup, files: RaceFiles(resolving: drawn.setup),
                             mode: .authoritative(windSeed: WindSeed(seed &* 0x9E37_79B9_7F4A_7C15 &+ 1)), current: nil, wind: { _ in wind })
            for _ in 0..<(race.setup.startSequenceTicks + Race.tickRate) { race.step() }
            self.wind = wind.direction
            up = race.boatClass.polar.bestUpwind(tws: wind.speed)
            length = race.boatClass.hull.length
        }

        /// Close-hauled on `tack`.
        func beat(_ tack: Tack) -> Double { tack == .starboard ? wind - up.twa : wind + up.twa }

        /// `seat`'s boat beating on `tack` at `position`, at her best upwind speed (`speed` of it).
        func beating(_ tack: Tack, at position: Vec2, speed: Double = 1) -> BotConductTests.Placement {
            BotConductTests.Placement(position: position, heading: beat(tack), speed: up.speed * speed)
        }

        /// Where a boat is `ahead` hull lengths ahead of one beating on starboard at `position` and `leeward` to leeward
        /// of her (negative: to windward).
        func offStarboardBoat(at position: Vec2, ahead: Double, leeward: Double) -> Vec2 {
            let forward = Vec2.heading(beat(.starboard))
            return position + (forward * ahead - forward.rightPerp * leeward) * length
        }

        /// Places the seats as `placements` say, racing on the first leg, as `BotConductTests.place` does.
        func place(_ placements: [BotConductTests.Placement]) throws {
            var snapshot = race.exportSnapshot()
            for (seat, placement) in placements.enumerated() {
                let relative = wrapAngle(wind - placement.heading)
                snapshot.seats[seat].boat.position = placement.position
                snapshot.seats[seat].boat.heading = placement.heading
                snapshot.seats[seat].boat.speed = placement.speed
                snapshot.seats[seat].boat.boomSide = relative >= 0 ? .port : .starboard
                snapshot.seats[seat].boat.status = .racing
                snapshot.seats[seat].boat.legIndex = 0
                snapshot.seats[seat].boat.roundingStage = 0
                snapshot.seats[seat].boat.autohelm = Autohelm(target: .angle(abs(relative)))
                snapshot.seats[seat].boat.rudder = 0
                snapshot.seats[seat].boat.isTacking = false
                // Nothing owed from the start sequence the boats drifted through unhelmed.
                snapshot.seats[seat].boat.penaltyTurnsOwed = 0
                snapshot.seats[seat].boat.penaltyProgress = 0
                snapshot.seats[seat].boat.penaltyClockTick = nil
                snapshot.seats[seat].boat.queuedPenaltyCallTicks = []
                snapshot.seats[seat].heldInput = .neutral
            }
            try race.importSnapshot(snapshot)
            _ = race.drainEvents()
        }
    }

    /// A live bot at the helm of `seat`, at `skill`, with `engagement`, meaning to sail `planned`.
    static func pilot(seat: Int, _ race: Race, skill: Double = 0.9, engagement: Double = 1, planned: Tack) -> BotConductTests.Pilot {
        var pilot = BotConductTests.Pilot(seat: seat, plannedTack: planned, race: race, skill: skill)
        var style = BotConductTests.skill1
        style.skill = skill
        style.engagement = engagement
        pilot.brain = BotBrain(style: style, seed: UInt64(seat + 1))
        pilot.brain.plannedTack = planned
        return pilot
    }

    /// What happened sailing `race` for `seconds` with `pilot` at seat 0's helm, `others` at theirs, and nobody at the
    /// rest (their autohelms hold their angles; `taps` tack them, seconds from now): the tick seat 0 tapped first, if she
    /// did, every event, and `each` after every step.
    static func sail(_ race: Race, _ pilot: BotConductTests.Pilot, seconds: Double, taps: [(seat: Int, at: Double)] = [],
                     others: [BotConductTests.Pilot] = [], each: (Race) -> Void = { _ in }) -> (tapped: Int?, kinds: [RaceEvent.Kind]) {
        var pilot = pilot
        var others = others
        var tapped: Int?
        var kinds: [RaceEvent.Kind] = []
        let start = race.tick
        for _ in 0..<Int(seconds * Double(Race.tickRate)) where !race.isOver {
            for tap in taps where race.tick - start == Int(tap.at * Double(Race.tickRate)) {
                race.tap(.tackGybe, seat: tap.seat, atTick: race.tick + 1)
            }
            if pilot.drive(race)?.tap != nil, tapped == nil { tapped = race.tick }
            for i in others.indices { _ = others[i].drive(race) }
            race.step()
            each(race)
            kinds += race.drainEvents().map(\.kind)
        }
        return (tapped, kinds)
    }

    /// Seat 1 beating on starboard, a National bot sailing her own race (engagement 0): she keeps clear as the rules
    /// have her, and plays no boat.
    static func victim(_ race: Race) -> BotConductTests.Pilot {
        Self.pilot(seat: 1, race, engagement: 0, planned: .starboard)
    }

    static let fleetSeeds: [UInt64] = [3, 11, 20]

    /// #234 acceptance: a National bot ahead covers a boat that tacks away (#223: "a bot ahead covers a boat that tacks
    /// away within a few seconds"). Both beating on starboard, seat 1 three lengths behind seat 0 and two and a half to
    /// windward, nobody at her helm, tacks onto port: the National bot tacks with her within a few seconds; a Club bot
    /// (skill 0.4) later, if at all (#223: "a Club bot covers badly and late"); one sailing her own race (engagement 0)
    /// not at all. No rule call.
    @Test func coversABoatThatTacksAway() throws {
        for seed in Self.fleetSeeds {
            func cover(skill: Double, engagement: Double) throws -> Double? {
                let scene = Scene(seed: seed)
                let c = scene.race.course
                let behind = scene.centre - c.upwind * (3 * scene.length) + c.right * (2.5 * scene.length)
                try scene.place([scene.beating(.starboard, at: scene.centre), scene.beating(.starboard, at: behind)])
                var tackedAt: Int?
                let sailed = Self.sail(scene.race, Self.pilot(seat: 0, scene.race, skill: skill, engagement: engagement,
                                                             planned: .starboard),
                                       seconds: 10, taps: [(1, 0.5)]) { race in
                    if tackedAt == nil && race.boats[1].tack == .port { tackedAt = race.tick }
                }
                #expect(BotConductTests.calls(sailed.kinds).isEmpty, "seed \(seed): \(BotConductTests.calls(sailed.kinds))")
                let tacked = try #require(tackedAt, "seed \(seed): seat 1 never tacked")
                // A tack within 6 s of hers; any later is for something else (a layline, the corridor).
                return sailed.tapped.map { Double($0 - tacked) / Double(Race.tickRate) }.flatMap { $0 < 6 ? $0 : nil }
            }
            let national = try #require(try cover(skill: 0.9, engagement: 1), "seed \(seed): the National bot never covered")
            #expect(national > 0 && national < 4, "seed \(seed): covered \(national) s after she tacked")
            let club = try cover(skill: 0.4, engagement: 1)
            #expect(club.map { $0 > national } ?? true, "seed \(seed): Club covered \(club ?? -1) s after, National \(national) s")
            #expect(try cover(skill: 0.9, engagement: 0) == nil, "seed \(seed): sailing her own race, she doesn't cover")
        }
    }

    /// A port bot (seat 0, National) beating at seat 1, a bot beating on starboard sailing her own race, from `ahead` hull
    /// lengths ahead of her and 3.5 to leeward, in seat 1's frame: what happened over `seconds`, and the closest they came.
    static func portMeetsStarboard(seed: UInt64, ahead: Double, engagement: Double = 1, seconds: Double = 12) throws
        -> (tapped: Int?, kinds: [RaceEvent.Kind], race: Race, closest: Double, backwinded: Bool, tacked: (ahead: Double, leeward: Double)?) {
        let scene = Scene(seed: seed)
        let port = scene.offStarboardBoat(at: scene.centre, ahead: ahead, leeward: 3.5)
        try scene.place([scene.beating(.port, at: port), scene.beating(.starboard, at: scene.centre)])
        var closest = Double.infinity
        var backwinded = false
        var tacked: (ahead: Double, leeward: Double)?
        let sailed = Self.sail(scene.race, Self.pilot(seat: 0, scene.race, engagement: engagement, planned: .port),
                               seconds: seconds, others: [Self.victim(scene.race)]) { race in
            closest = min(closest, (race.boats[0].position - race.boats[1].position).length / scene.length)
            if race.boats[0].tack == .starboard, let cone = race.shadowCone(ofSeat: 0),
               cone.isInBackwind(race.boats[1].position) { backwinded = true }
            if tacked == nil, race.boats[0].tack == .starboard, !race.boats[0].isTacking {
                let offset = race.boats[0].position - race.boats[1].position
                let forward = race.boats[1].forward
                tacked = (offset.dot(forward) / scene.length, offset.dot(-forward.rightPerp) / scene.length)
            }
        }
        return (sailed.tapped, sailed.kinds, scene.race, closest, backwinded, tacked)
    }

    /// #234 acceptance (the owner, 2026-09-29: "lee-bow when she can just cross, duck when she can't"): a National port
    /// bot meeting a starboard boat she can just cross (her track crossing a little over 2 lengths ahead of her, passing
    /// clear of her as she keeps clear) tacks onto her lee bow: on starboard ahead of her and to leeward, the starboard
    /// boat in her backwind. One she can't cross (a length ahead) she ducks, holding port. No rule call either way. In a
    /// steady wind, so a header on starboard doesn't hold her off it (`fleetPlay`).
    @Test func leeBowsInsteadOfDuckingWhenPossible() throws {
        for seed in Self.fleetSeeds {
            let lee = try Self.portMeetsStarboard(seed: seed, ahead: 5.8)
            #expect(BotConductTests.calls(lee.kinds).isEmpty, "seed \(seed): \(BotConductTests.calls(lee.kinds))")
            let tacked = try #require(lee.tacked, "seed \(seed): she didn't lee-bow")
            #expect(tacked.ahead > 1 && tacked.ahead < 3, "seed \(seed): her tack done, she's \(tacked.ahead) L ahead of her")
            #expect(tacked.leeward > 0 && tacked.leeward < 1.5, "seed \(seed): and \(tacked.leeward) L to leeward")
            #expect(lee.backwinded, "seed \(seed): the starboard boat sat in her backwind")
            #expect(lee.closest > 1, "seed \(seed): she came within \(lee.closest) L")

            let duck = try Self.portMeetsStarboard(seed: seed, ahead: 4.5, seconds: 7)
            #expect(BotConductTests.calls(duck.kinds).isEmpty, "seed \(seed): \(BotConductTests.calls(duck.kinds))")
            #expect(duck.tapped == nil && duck.race.boats[0].tack == .port, "seed \(seed): she can't cross, so ducks")
        }
    }

    /// A port bot (seat 0, National) crossing well ahead of seat 1, a bot beating on starboard sailing her own race, from
    /// 7 hull lengths ahead and 2 to leeward of her in her frame (crossing about 5 lengths ahead of her); or, `together` false, the same with seat 0 400 m off to
    /// leeward. Seat 1's metres made good along her heading over `seconds`, and the rest.
    static func crossingAhead(seed: UInt64, together: Bool, seconds: Double = 16) throws
        -> (tapped: Int?, kinds: [RaceEvent.Kind], madeGood: Double, shadowed: Bool, closest: Double, length: Double) {
        let scene = Scene(seed: seed)
        var port = scene.offStarboardBoat(at: scene.centre, ahead: 7, leeward: 2)
        if !together { port = port - Vec2.heading(scene.wind) * 400 }
        try scene.place([scene.beating(.port, at: port), scene.beating(.starboard, at: scene.centre)])
        let from = scene.race.boats[1].position
        let course = scene.race.boats[1].forward
        var shadowed = false
        var closest = Double.infinity
        let sailed = Self.sail(scene.race, Self.pilot(seat: 0, scene.race, planned: .port), seconds: seconds,
                               others: [Self.victim(scene.race)]) { race in
            if let cone = race.shadowCone(ofSeat: 0), cone.factor(at: race.boats[1].position) < 1 { shadowed = true }
            closest = min(closest, (race.boats[0].position - race.boats[1].position).length / scene.length)
        }
        return (sailed.tapped, sailed.kinds, (scene.race.boats[1].position - from).dot(course), shadowed, closest, scene.length)
    }

    /// #234 acceptance (#101: "#234's tack-on-wind and lee-bow are made as the keep-clear or tacking boat and must still
    /// complete clear"): a National port bot crossing ahead of a starboard boat tacks on her wind, onto starboard, and
    /// the starboard boat sits in her wind shadow; her tack completes clear, with no rule 13 or 15 call, nor any other.
    @Test func tackOnWindCompletesClear() throws {
        for seed in Self.fleetSeeds {
            let sailed = try Self.crossingAhead(seed: seed, together: true)
            #expect(sailed.tapped != nil, "seed \(seed): she didn't tack on her wind")
            #expect(sailed.shadowed, "seed \(seed): the starboard boat never sat in her shadow")
            #expect(BotConductTests.calls(sailed.kinds).isEmpty, "seed \(seed): \(BotConductTests.calls(sailed.kinds))")
            #expect(sailed.closest > 1, "seed \(seed): she came within \(sailed.closest) L")
        }
    }

    /// #234 acceptance (#220: cover, tack on wind and lee-bow pay when the shadow costs 0.7–1.5 L): the starboard boat a
    /// National bot tacks on the wind of loses half a hull length or more over the 16 s against her twin, the same boat
    /// in the same water with the port boat 400 m off.
    @Test func tackOnWindCostsTheVictimAtLeastHalfAHullLength() throws {
        for seed in Self.fleetSeeds {
            let victim = try Self.crossingAhead(seed: seed, together: true)
            let twin = try Self.crossingAhead(seed: seed, together: false)
            #expect(victim.tapped != nil, "seed \(seed): she didn't tack on her wind")
            let lost = (twin.madeGood - victim.madeGood) / victim.length
            #expect(lost >= 0.5, "seed \(seed): she cost her \(lost) L")
        }
    }

    /// #234 acceptance: in clear air with a boat in her backwind (the lee-bow's geometry, `LeeBowTests`: 1.6 lengths
    /// astern of her and 0.6 to windward), a National bot holds her lane on a header past her threshold that would
    /// tack her with no boat there; a header past twice her threshold tacks her all the same.
    @Test func holdsItsLane() throws {
        for seed in Self.fleetSeeds {
            func tack(header: Double, neighbour: Bool) throws -> Tack {
                let scene = Scene(seed: seed)
                var behind = scene.offStarboardBoat(at: scene.centre, ahead: -1.6, leeward: -0.6)
                if !neighbour { behind = behind + Vec2.heading(scene.wind) * 400 }
                try scene.place([scene.beating(.starboard, at: scene.centre), scene.beating(.starboard, at: behind)])
                scene.race.step()
                var view = scene.race.seatView(for: 0)
                view.puffs = []
                view.pressure = nil
                #expect(view.own.shadow == 1, "seed \(seed): she's in clear air")
                var brain = Self.pilot(seat: 0, scene.race, planned: .starboard).brain
                brain.observe(view.own, view)
                let threshold = try #require(brain.tactics.headerThreshold)
                // Headed on starboard: backed.
                brain.senses.direction = view.course.axis - header * threshold
                brain.senses.directionRate = 0
                return brain.upwindTack(view.own, view, planned: .starboard)
            }
            #expect(try tack(header: 1.5, neighbour: false) == .port, "seed \(seed): the header tacks her alone")
            #expect(try tack(header: 1.5, neighbour: true) == .starboard, "seed \(seed): she holds her lane")
            #expect(try tack(header: 2.5, neighbour: true) == .port, "seed \(seed): a big header tacks her all the same")
        }
    }

    /// #234 acceptance (#223: "targets by tactical value only, blind to human or bot"): a port bot meeting a starboard
    /// boat she can lee-bow, with another starboard boat near, chooses the same target, and decides the same, whichever
    /// of the two a human sails.
    @Test func targetIgnoresHumanFlag() throws {
        func play(_ seats: [SeatKind]) throws -> (play: BotBrain.FleetPlay?, decision: BotDecision) {
            let scene = Scene(seats: seats, seed: 9)
            let starboard = scene.centre
            let other = scene.offStarboardBoat(at: starboard, ahead: -1, leeward: -4)
            let port = scene.offStarboardBoat(at: starboard, ahead: 3.2, leeward: 1)
            try scene.place([scene.beating(.port, at: port), scene.beating(.starboard, at: starboard),
                             scene.beating(.starboard, at: other)])
            let view = scene.race.seatView(for: 0)
            var brain = Self.pilot(seat: 0, scene.race, planned: .port).brain
            brain.observe(view.own, view)
            let play = brain.fleetPlay(view.own, view, planned: .port, headed: 0, threshold: deg2rad(5)) { _ in false }
            var deciding = Self.pilot(seat: 0, scene.race, planned: .port).brain
            return (play, deciding.decide(view))
        }
        let a = try play([.bot, .bot, .human])
        let b = try play([.bot, .human, .bot])
        #expect(a.play != nil, "she has a target")
        #expect(a.play == b.play)
        #expect(a.decision == b.decision)
        #expect(try play([.bot, .bot, .bot]).play == a.play)
    }
}
