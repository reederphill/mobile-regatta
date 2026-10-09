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
    /// in a steady wind: the wind's strength there at the gun, held, down the course's axis, so no shift plays a part in
    /// what a bot does there. The wind,
    /// the best upwind in it, and the boats' hull length.
    struct Scene {
        let race: Race
        let wind: Double
        let up: PolarTable.Optimum
        let centre: Vec2
        let length: Double

        /// `veer`: the wind veered that much off the course's axis, radians (#329): a header on port, a lift on starboard.
        /// `boatClass`: the class sailed (the default, skiff@6, unless told otherwise).
        init(seats: [SeatKind] = [.bot, .bot], seed: UInt64, veer: Double = 0,
             boatClass: FileRef = RaceFiles.defaults.boatClass.ref) {
            let drawn = botRace(seats: seats, seed: seed, boatClass: boatClass)
            for _ in 0..<(drawn.setup.startSequenceTicks + Race.tickRate) { drawn.step() }
            let c = drawn.course
            centre = c.startLine.centre + c.upwind * (c.beat * 0.35)
            // Its strength there at the gun, down the course's axis: neither tack lifted, so her own plan leans neither
            // way (a tack on a boat's wind must pay against it, `paysToTackOnWind`).
            let wind = GroundWind(direction: c.axis + veer, speed: drawn.groundWind(at: centre).speed)
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
            // Placed boats start in clean air (#377): no ribbons, headers or backwind from where they were.
            snapshot.ribbonPoints = []
            snapshot.emissionLevels = []
            snapshot.headers = []
            snapshot.backwind = BackwindSails()
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

    /// skiff@5, whose backwind is #298's trapezoid astern of her stern (#377): the class for the lee-bow's trapezoid
    /// gate (`FleetTactics.leeBowAstern`), which skiff@6's upwash zone doesn't read (`leeBowsInsteadOfDuckingWhenPossible`).
    static let trapezoidClass = try! BoatClassFile.bundled(id: "skiff", version: 5).ref

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

    /// What a port bot made of a starboard boat at her decisions, as `leeBowTarget`'s two gates read it: whether she
    /// could ever just cross her (`canJustCross`), and whether her tack would ever have landed her on her lee bow
    /// (`leeBowLands`), with and without her able to cross.
    struct LeeBowGates {
        var crossed = false
        var landedCrossing = false
        var landedNotCrossing = false
    }

    /// A port bot (seat 0, National) beating at seat 1, a bot beating on starboard sailing her own race, from `ahead` hull
    /// lengths ahead of her and 3.5 to leeward, in seat 1's frame: what happened over `seconds`, the closest they came,
    /// and how the lee-bow's gates read at seat 0's decisions on port (`LeeBowGates`, a twin of her brain looking on).
    /// `justTacked`: she tacked onto port `tackedAgo` seconds ago, well inside her tack interval (`Tactics.tackInterval`).
    static func portMeetsStarboard(seed: UInt64, ahead: Double, leeward: Double = 3.5, engagement: Double = 1,
                                   seconds: Double = 12, justTacked: Bool = false, tackedAgo: Double = 1,
                                   boatClass: FileRef = RaceFiles.defaults.boatClass.ref) throws
        -> (tapped: Int?, kinds: [RaceEvent.Kind], race: Race, closest: Double, backwinded: Bool,
            tacked: (ahead: Double, leeward: Double)?, gates: LeeBowGates, from: Int) {
        let scene = Scene(seed: seed, boatClass: boatClass)
        let port = scene.offStarboardBoat(at: scene.centre, ahead: ahead, leeward: leeward)
        try scene.place([scene.beating(.port, at: port), scene.beating(.starboard, at: scene.centre)])
        var closest = Double.infinity
        var backwinded = false
        var tacked: (ahead: Double, leeward: Double)?
        let from = scene.race.tick
        var pilot = Self.pilot(seat: 0, scene.race, engagement: engagement, planned: .port)
        if justTacked { pilot.brain.lastTackTime = scene.race.time - tackedAgo }
        var looking = pilot.brain
        var gates = LeeBowGates()
        let sailed = Self.sail(scene.race, pilot, seconds: seconds, others: [Self.victim(scene.race)]) { race in
            closest = min(closest, (race.boats[0].position - race.boats[1].position).length / scene.length)
            if race.boats[0].tack == .starboard, let cone = race.shadowCone(ofSeat: 0),
               cone.isInBackwind(race.boats[1].position) { backwinded = true }
            if tacked == nil, race.boats[0].tack == .starboard, !race.boats[0].isTacking {
                let offset = race.boats[0].position - race.boats[1].position
                let forward = race.boats[1].forward
                tacked = (offset.dot(forward) / scene.length, offset.dot(-forward.rightPerp) / scene.length)
            }
            // Her next decision's view (`Pilot.drive`), while she is still on port and not tacking.
            guard race.tick.isMultiple(of: BotDriver.decisionInterval) else { return }
            let view = race.seatView(for: 0)
            looking.observe(view.own, view)
            guard view.own.tack == .port, !race.boats[0].isTacking,
                  let other = view.others.first(where: { $0.seat == 1 }) else { return }
            let crosses = looking.canJustCross(view.own, view, other)
            let lands = looking.leeBowLands(view.own, view, other)
            gates.crossed = gates.crossed || crosses
            gates.landedCrossing = gates.landedCrossing || (crosses && lands)
            gates.landedNotCrossing = gates.landedNotCrossing || (!crosses && lands)
        }
        return (sailed.tapped, sailed.kinds, scene.race, closest, backwinded, tacked, gates, from)
    }

    /// #234 acceptance (the owner, 2026-09-29: "lee-bow when she can just cross, duck when she can't"): a National port
    /// bot meeting a starboard boat she can just cross (her track crossing a little over 2 lengths ahead of her, passing
    /// clear of her as she keeps clear) tacks onto her lee bow: on starboard ahead of her and to leeward, the starboard
    /// boat in her backwind. One she can't cross (a length ahead) she ducks, holding port. No rule call either way. In a
    /// steady wind, so a header on starboard doesn't hold her off it (`fleetPlay`).
    ///
    /// #329: the can-just-cross gate (`canJustCross`) is what separates the two, not a lee-bow that never fires: meeting
    /// the boat she can cross, her tack would land on its lee bow (`leeBowLands`) and she could cross it; meeting one 3.5
    /// lengths ahead and 2 to leeward she could never cross it, and she ducks.
    ///
    /// skiff@5's backwind is narrow and starts at her stern, so wherever her tack lands the boat in it she can also cross
    /// it (a 6 by 6 grid of starts, ahead 3 to 5.8 and leeward 1 to 3.5, on seeds 3, 11 and 20, found none that lands and
    /// can't cross): the gate no longer has a landing to refuse there, so the scene asserts she ducks, not that her tack
    /// would have landed (`LeeBowGates.landedNotCrossing` stays, as the grid's probe).
    /// #349 widened the grid (312 starts, 0.5 to 6.5 ahead and 0.5 to 4 to leeward, same seeds): 46 landings, every one
    /// crossable, so `canJustCross` stays as a safety gate that refuses nothing here today.
    ///
    /// #377: on skiff@6 the backwind's zone is the upwash beside her sail, run on 1.5 L astern of her stern (the owner's
    /// lengthening), and her gate is `FleetTactics.leeBowAbeam`. Without the run astern no crossing she could just make
    /// landed the starboard boat in it; with it she lee-bows again, from 5.5 L ahead (at 5.8 her forecast never lands seed 3's
    /// boat in the zone, and she sails on). On a probe grid (3–7 L ahead by 0.5, 1–3.5 L to leeward, seeds 3, 11
    /// and 20) 12 starts land crossable lee-bows, about 2.4 L ahead and 0.7 L to leeward once tacked, never closer than
    /// 1.7 L, no rule call; the same 12 with the zone a fan (renders review 2) and a wedge from a point at her mast (review 3). skiff@5's trapezoid (`trapezoidClass`, `FleetTactics.leeBowAstern`) lee-bows from 5.8 L as
    /// before.
    @Test func leeBowsInsteadOfDuckingWhenPossible() throws {
        for seed in Self.fleetSeeds {
            let trapezoid = try Self.portMeetsStarboard(seed: seed, ahead: 5.8, boatClass: Self.trapezoidClass)
            #expect(BotConductTests.calls(trapezoid.kinds).isEmpty, "seed \(seed): \(BotConductTests.calls(trapezoid.kinds))")
            #expect(trapezoid.tacked != nil && trapezoid.backwinded && trapezoid.gates.landedCrossing && trapezoid.closest > 1,
                    "seed \(seed): skiff@5 lee-bows from 5.8 L")
        }
        for seed in Self.fleetSeeds {
            let lee = try Self.portMeetsStarboard(seed: seed, ahead: 5.5)
            #expect(BotConductTests.calls(lee.kinds).isEmpty, "seed \(seed): \(BotConductTests.calls(lee.kinds))")
            let tacked = try #require(lee.tacked, "seed \(seed): she didn't lee-bow")
            #expect(tacked.ahead > 1 && tacked.ahead < 3.5, "seed \(seed): her tack done, she's \(tacked.ahead) L ahead of her")
            #expect(tacked.leeward > 0 && tacked.leeward < 1.5, "seed \(seed): and \(tacked.leeward) L to leeward")
            #expect(lee.backwinded, "seed \(seed): the starboard boat sat in her backwind")
            #expect(lee.closest > 1, "seed \(seed): she came within \(lee.closest) L")
            #expect(lee.gates.landedCrossing, "seed \(seed): she could cross and her tack would land")

            let duck = try Self.portMeetsStarboard(seed: seed, ahead: 4.5, seconds: 7)
            #expect(BotConductTests.calls(duck.kinds).isEmpty, "seed \(seed): \(BotConductTests.calls(duck.kinds))")
            #expect(duck.tapped == nil && duck.race.boats[0].tack == .port, "seed \(seed): she can't cross, so ducks")

            // #329: closer still, 3.5 lengths ahead and 2 to leeward, she can't cross her clear of her keep-clear
            // distance: she ducks.
            let gated = try Self.portMeetsStarboard(seed: seed, ahead: 3.5, leeward: 2, seconds: 7)
            #expect(BotConductTests.calls(gated.kinds).isEmpty, "seed \(seed): \(BotConductTests.calls(gated.kinds))")
            #expect(!gated.gates.crossed, "seed \(seed): she could never just cross her")
            #expect(gated.tapped == nil && gated.race.boats[0].tack == .port, "seed \(seed): so she ducks")
        }
    }

    /// #329 (the owner, 2026-10-01): a lee-bow answers a crossing, so it isn't held to her tack interval
    /// (`FleetTactics.leeBowInsideTackInterval`). The port bot of `leeBowsInsteadOfDuckingWhenPossible`, having tacked
    /// onto port a second before, still lee-bows the starboard boat she can just cross, clear and with no rule call. Her
    /// tack on a boat's wind is hers to choose, so it waits for the interval: crossing well ahead of the starboard boat
    /// a second after a tack (`crossingAhead`), she holds port past the chance. From 5.5 L ahead on skiff@6 (#377).
    @Test func leeBowAnswersInsideTheTackInterval() throws {
        #expect(BotBrain.FleetTactics.leeBowInsideTackInterval)
        let separation = BotBrain.FleetTactics.leeBowMinSeparation
        for seed in Self.fleetSeeds {
            // #337: a combative bot, her last tack `leeBowMinSeparation` ago, inside her interval.
            let lee = try Self.portMeetsStarboard(seed: seed, ahead: 5.5, seconds: 8, justTacked: true, tackedAgo: separation)
            #expect(BotConductTests.calls(lee.kinds).isEmpty, "seed \(seed): \(BotConductTests.calls(lee.kinds))")
            #expect(lee.tapped != nil, "seed \(seed): she didn't lee-bow inside her tack interval")
            #expect(lee.tacked != nil && lee.backwinded, "seed \(seed): the starboard boat sat in her backwind")
            #expect(lee.closest > 1, "seed \(seed): she came within \(lee.closest) L")

            // Her tack on a boat's wind is hers to choose: it waits for the interval. The same scene a second after a
            // tack, she holds port past the chance; outside her interval she takes it (the positive control, #338).
            let onWind = try Self.crossingAhead(seed: seed, together: true, seconds: 8, justTacked: true)
            #expect(onWind.tapped == nil, "seed \(seed): she tacked on her wind inside her tack interval")
            let free = try Self.crossingAhead(seed: seed, together: true, seconds: 8)
            #expect(free.tapped != nil, "seed \(seed): outside her interval she tacks on her wind")
        }
    }

    /// #337 acceptance (lee-bow): inside her tack interval only a combative bot lee-bows
    /// (`FleetTactics.leeBowExemptEngagement`); at the lee-bow's floor (`FleetTactics.leeBowEngagement`) she waits
    /// out the interval, as for any tack of her choosing. And not right after a tack (`leeBowMinSeparation`, #338
    /// review): a second after one, a combative bot holds port past the separation.
    @Test func leeBowsInsideTheIntervalOnlyCombative() throws {
        let separation = BotBrain.FleetTactics.leeBowMinSeparation
        for seed in Self.fleetSeeds {
            let combative = try Self.portMeetsStarboard(seed: seed, ahead: 5.5, seconds: 8, justTacked: true, tackedAgo: separation)
            #expect(combative.tapped != nil, "seed \(seed): combative, she lee-bows inside her interval")
            let floor = try Self.portMeetsStarboard(seed: seed, ahead: 5.5, engagement: BotBrain.FleetTactics.leeBowEngagement,
                                                   seconds: 8, justTacked: true, tackedAgo: separation)
            #expect(floor.tapped == nil, "seed \(seed): at the floor, she waits out her interval")
            // Outside her interval the floor bot lee-bows the same crossing (the positive control).
            let free = try Self.portMeetsStarboard(seed: seed, ahead: 5.5, engagement: BotBrain.FleetTactics.leeBowEngagement)
            #expect(free.tapped != nil, "seed \(seed): at the floor, outside her interval, she lee-bows")
            let back = try Self.portMeetsStarboard(seed: seed, ahead: 5.5, seconds: 8, justTacked: true, tackedAgo: 1)
            let early = back.tapped.map { Double($0 - back.from) / Double(Race.tickRate) < separation - 1 } ?? false
            #expect(!early, "seed \(seed): a second after a tack, she tacked again inside the separation")
        }
    }

    /// A port bot (seat 0, National) crossing well ahead of seat 1, a bot beating on starboard sailing her own race, from
    /// 7 hull lengths ahead and 2 to leeward of her in her frame (crossing about 5 lengths ahead of her); or, `together`
    /// false, the same with seat 0 400 m off to leeward. Seat 1's metres made good along her heading over `seconds`, and
    /// the rest. The wind veered `veer` off the course's axis: by default 2°, half a National bot's threshold, a header
    /// on port, so her plan leans to starboard and a tack on the starboard boat's wind pays in the scenes' 10–13 kn
    /// (#329's `FleetTactics.shadowCost`: plan neutral, it pays only in light air). `justTacked`: she tacked onto port a
    /// second ago, well inside her tack interval.
    static func crossingAhead(seed: UInt64, together: Bool, seconds: Double = 16, veer: Double = deg2rad(2),
                              justTacked: Bool = false) throws
        -> (tapped: Int?, kinds: [RaceEvent.Kind], madeGood: Double, shadowed: Bool, closest: Double, length: Double) {
        let scene = Scene(seed: seed, veer: veer)
        var port = scene.offStarboardBoat(at: scene.centre, ahead: 7, leeward: 2)
        if !together { port = port - Vec2.heading(scene.wind) * 400 }
        try scene.place([scene.beating(.port, at: port), scene.beating(.starboard, at: scene.centre)])
        let from = scene.race.boats[1].position
        let course = scene.race.boats[1].forward
        var shadowed = false
        var closest = Double.infinity
        var pilot = Self.pilot(seat: 0, scene.race, planned: .port)
        if justTacked { pilot.brain.lastTackTime = scene.race.time - 1 }
        let sailed = Self.sail(scene.race, pilot, seconds: seconds, others: [Self.victim(scene.race)]) { race in
            // Her ribbons over the starboard boat (#377).
            if race.wake.loss(of: 0, at: race.boats[1].position, tick: race.tick) > 0 { shadowed = true }
            closest = min(closest, (race.boats[0].position - race.boats[1].position).length / scene.length)
        }
        return (sailed.tapped, sailed.kinds, (scene.race.boats[1].position - from).dot(course), shadowed, closest, scene.length)
    }

    /// #234 acceptance (#101: "#234's tack-on-wind and lee-bow are made as the keep-clear or tacking boat and must still
    /// complete clear"): a National port bot crossing ahead of a starboard boat tacks on her wind, onto starboard, and
    /// the starboard boat sits in her wind shadow; her tack completes clear, with no rule 13 or 15 call, nor any other.
    /// #329: with her plan leaning to starboard (`crossingAhead`'s header on port), so the tack pays in these winds
    /// (`FleetTactics.shadowCost`, `FleetTacticsTuningTests.tackOnWindPayoffBinds`).
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

    /// #349: `tackOnWindTarget`'s position gate lets her tack on a boat's wind while she is still up to
    /// `FleetTactics.tackOnWindLeewardSlack` lengths to leeward of its track (skiff@5's swung cone covers it best there),
    /// and still while she is to windward of it, as before #349. Read straight off her first decision's view, port bot
    /// (seat 0, National) placed off a starboard boat (seat 1) in `crossingAhead`'s wind, her plan leaning by her full
    /// threshold so the tack always pays (`paysToTackOnWind`) and only the gate and the shadow forecast decide: 3.5 lengths
    /// ahead and 0.5 to leeward of its track she takes it; 3.5 ahead and 3 to leeward, past the slack, she doesn't (her
    /// ribbon misses it there too); 4 ahead and 0.05 to windward she takes it. #377: her shadow is her ribbon, which a
    /// fresh tack lays from nothing, so the forecast reaches less far astern than skiff@5's cone did (at 6.25 ahead,
    /// 0.90–0.94 now): the scenes moved closer (forecast 0.59–0.67 at 3.5 / 0.5, 0.63–0.66 at 4 / −0.05).
    @Test func tackOnWindGateAllowsOnlyTheSlackToLeeward() throws {
        for seed in Self.fleetSeeds {
            func target(ahead: Double, leeward: Double) throws -> Int? {
                let scene = Scene(seed: seed, veer: deg2rad(2))
                let port = scene.offStarboardBoat(at: scene.centre, ahead: ahead, leeward: leeward)
                try scene.place([scene.beating(.port, at: port), scene.beating(.starboard, at: scene.centre)])
                scene.race.step()
                let view = scene.race.seatView(for: 0)
                var brain = Self.pilot(seat: 0, scene.race, planned: .port).brain
                brain.observe(view.own, view)
                let threshold = try #require(brain.tactics.headerThreshold)
                return brain.tackOnWindTarget(view.own, view, lean: threshold, threshold: threshold)
            }
            #expect(try target(ahead: 3.5, leeward: 0.5) == 1, "seed \(seed): 0.5 L to leeward of his track, within the slack")
            #expect(try target(ahead: 3.5, leeward: 3) == nil, "seed \(seed): 3 L to leeward of his track, past the slack")
            #expect(try target(ahead: 4, leeward: -0.05) == 1, "seed \(seed): to windward of his track")
        }
    }


    /// #234 acceptance: in clear air with a boat on her tack astern and to windward of her (1.5 lengths astern and 2.5 to
    /// windward), a National bot holds her lane on a header past her threshold that would tack her with no boat there; a
    /// header past twice her threshold tacks her all the same, but like any fleet tactic's tack, never onto a board she
    /// has overstood, nor with the boat too close to tack clear of (in her backwind, 1.6 lengths astern and 0.6 to
    /// windward, `LeeBowTests`' geometry).
    @Test func holdsItsLane() throws {
        for seed in Self.fleetSeeds {
            func tack(header: Double, neighbour: Bool, close: Bool = false, overstood: Bool = false,
                      engagement: Double = 0.5) throws -> Tack {
                let scene = Scene(seed: seed)
                var behind = close ? scene.offStarboardBoat(at: scene.centre, ahead: -1.6, leeward: -0.6)
                    : scene.offStarboardBoat(at: scene.centre, ahead: -1.5, leeward: -2.5)
                if !neighbour { behind = behind + Vec2.heading(scene.wind) * 400 }
                try scene.place([scene.beating(.starboard, at: scene.centre), scene.beating(.starboard, at: behind)])
                scene.race.step()
                var view = scene.race.seatView(for: 0)
                view.puffs = []
                view.pressure = nil
                #expect(view.own.shadow == 1, "seed \(seed): she's in clear air")
                // #337: today's lane header, at the fleet's typical engagement (`holdsLaneHarderTheMoreCombative`).
                var brain = Self.pilot(seat: 0, scene.race, engagement: engagement, planned: .starboard).brain
                brain.observe(view.own, view)
                let threshold = try #require(brain.tactics.headerThreshold)
                // Headed on starboard: backed.
                brain.senses.direction = view.course.axis - header * threshold
                brain.senses.directionRate = 0
                return brain.upwindTack(view.own, view, planned: .starboard) { _ in overstood }
            }
            #expect(try tack(header: 1.5, neighbour: false) == .port, "seed \(seed): the header tacks her alone")
            #expect(try tack(header: 1.5, neighbour: true) == .starboard, "seed \(seed): she holds her lane")
            #expect(try tack(header: 2.5, neighbour: true) == .port, "seed \(seed): a big header tacks her all the same")
            #expect(try tack(header: 2.5, neighbour: true, overstood: true) == .starboard,
                    "seed \(seed): but not onto a board she has overstood")
            #expect(try tack(header: 2.5, neighbour: true, close: true) == .starboard,
                    "seed \(seed): nor with a boat too close to tack clear of")
            // #337: how hard she holds it is her engagement (`FleetTactics.laneHeaderScale`): a combative bot holds
            // against the header that tacks the fleet's typical one, and only a bigger one tacks her; a mild one (the
            // lane's floor) tacks on a header the typical one holds against.
            #expect(try tack(header: 2.5, neighbour: true, engagement: 1) == .starboard,
                    "seed \(seed): combative, she holds her lane against 2.5 times her threshold")
            #expect(try tack(header: 3.5, neighbour: true, engagement: 1) == .port, "seed \(seed): not against 3.5")
            #expect(try tack(header: 1.75, neighbour: true) == .starboard, "seed \(seed): typical, she holds against 1.75")
            #expect(try tack(header: 1.75, neighbour: true, engagement: BotBrain.FleetTactics.laneEngagement) == .port,
                    "seed \(seed): mild, 1.75 tacks her")
        }
    }

    // MARK: - How hard she plays (#337)

    /// #337 acceptance (cover): at the same scene, a boat 1.5 lengths behind her and 2.5 abeam that she saw tack onto
    /// port, a bot at engagement 1 still covers it 6 s on; one at the cover's floor (`FleetTactics.coverEngagement`)
    /// has let it go (`FleetTactics.coverLateScale`), though she covers it as soon as she's seen it tack.
    @Test func coversLaterTheMoreCombative() throws {
        for seed in Self.fleetSeeds {
            func target(engagement: Double, tackedAgo: Double) throws -> Int? {
                let scene = Scene(seed: seed)
                let c = scene.race.course
                let behind = scene.centre - c.upwind * (1.5 * scene.length) + c.right * (2.5 * scene.length)
                try scene.place([scene.beating(.starboard, at: scene.centre), scene.beating(.port, at: behind)])
                let view = scene.race.seatView(for: 0)
                var brain = Self.pilot(seat: 0, scene.race, skill: 1, engagement: engagement, planned: .starboard).brain
                brain.observe(view.own, view)
                brain.fleet.bySeat[1] = .init(tack: .port, tackedAt: view.time - tackedAgo, timing: 0)
                #expect(brain.tactics.coversTackers)
                return brain.coverTackTarget(view.own, view)
            }
            let floor = BotBrain.FleetTactics.coverEngagement
            #expect(try target(engagement: 1, tackedAgo: 6) == 1, "seed \(seed): combative, she covers 6 s on")
            #expect(try target(engagement: 0.5, tackedAgo: 6) == 1, "seed \(seed): typical, within today's 8 s")
            #expect(try target(engagement: floor, tackedAgo: 6) == nil, "seed \(seed): mild, too late")
            #expect(try target(engagement: floor, tackedAgo: 2.5) == 1, "seed \(seed): mild, she covers it fresh")
            #expect(try target(engagement: 0.5, tackedAgo: 10) == nil, "seed \(seed): typical, 10 s is too late")
            #expect(try target(engagement: 1, tackedAgo: 10) == 1, "seed \(seed): combative, not yet")
        }
    }

    /// #337 acceptance (tack on wind): the same tack, leaving the boat at the same shadow factor in the same wind, pays
    /// a bot at engagement 1 (she reckons she holds the boat there longer, `FleetTactics.shadowHeldScale`) and not one
    /// at the tactic's floor (`FleetTactics.tackOnWindEngagement`), nor the fleet's typical one, whose reckoning is
    /// today's (`tackOnWindPayoffBinds`).
    @Test func tackOnWindPaysTheCombativeSooner() {
        func pays(_ engagement: Double) -> Bool {
            var style = BotConductTests.skill1
            style.engagement = engagement
            let tactics = Tactics(profile: nil, skill: 0.9, style: style)
            #expect(tactics.tacksOnWind)
            return BotBrain.paysToTackOnWind(windSpeed: 10 * 0.514444, factor: 0.72, lean: 0, threshold: deg2rad(4),
                                             shadowHeld: tactics.shadowHeld)
        }
        #expect(pays(1))
        #expect(!pays(BotBrain.FleetTactics.tackOnWindEngagement))
        #expect(!BotBrain.paysToTackOnWind(windSpeed: 10 * 0.514444, factor: 0.72, lean: 0, threshold: deg2rad(4)))
    }

    /// #337: every scale gives today's (#338's) value at the fleet's typical engagement, and the profiles (the tactician
    /// fully engaged among them) and the cautious bot pin today's, whatever their engagement; the ramp to the tactician
    /// (#366) leaves a live bot's scaled values hers, and her cover hers (`covers` false).
    @Test func engagementScalesArePinnedAtTheMiddle() {
        typealias F = BotBrain.FleetTactics
        let typical = Tactics(profile: nil, skill: 0.9, style: BotConductTests.skill1)
        #expect(typical.tacticEngagement == 0.5 && typical.startEngagement == 0.5)
        #expect(typical.coverLate == F.coverLate && typical.coverRangeLift == 1 && typical.laneHeader == F.laneHeader)
        #expect(typical.shadowHeld == F.shadowHeld && typical.startHoldsGroundSeconds == BotBrain.startLuffEaseSeconds)
        #expect(typical.startLuffUntil == nil)
        for scale in [F.coverLateScale, F.coverRangeLiftScale, F.laneHeaderScale, F.shadowHeldScale,
                      F.startHoldsGroundScale, F.startLuffUntilScale] {
            #expect(scale.at(0) == scale.mild && scale.at(F.engagementFloor) == scale.mild)
            #expect(scale.at(0.5) == scale.middle && scale.at(1) == scale.combative)
        }
        // The owner's spread (2026-10-08): cover lateness and the start's hold, floor / middle / 1.
        #expect([F.coverLateScale.mild, F.coverLateScale.middle, F.coverLateScale.combative] == [3, 8, 12])
        #expect([F.startHoldsGroundScale.mild, F.startHoldsGroundScale.middle, F.startHoldsGroundScale.combative] == [5, 20, 30])
        for profile in BotProfile.allCases {
            let tactics = Tactics(profile: profile, skill: 1)
            #expect(tactics.tacticEngagement == nil && tactics.startEngagement == nil, "\(profile)")
            #expect(tactics.coverLate == F.coverLate && tactics.laneHeader == F.laneHeader
                    && tactics.shadowHeld == F.shadowHeld && tactics.startHoldsGroundSeconds == BotBrain.startLuffEaseSeconds && tactics.startLuffUntil == nil, "\(profile)")
        }
        // The tactician lee-bows inside her tack interval as before, right after a tack.
        #expect(Tactics(profile: .tactician, skill: 1).leeBowExempt(sinceTack: 0))
        var rng = SplitMix64(seed: 7)
        let cautious = BotBrain(style: BotBrain.Caution.style(skill: 0.9, rng: &rng), seed: 7,
                                weaknesses: BotBrain.Caution.weaknesses(skill: 0.9), caution: .standard)
        #expect(cautious.tactics.tacticEngagement == nil && cautious.tactics.startEngagement == nil)
        #expect(!cautious.tactics.coversTackers && !cautious.tactics.leeBows && !cautious.tactics.tacksOnWind
                && !cautious.tactics.holdsLane && cautious.tactics.startLuffUntil == nil)
        // A National live bot at engagement 1, at the top of the band: the tactician's tactics, her own cover and scales.
        var combative = BotConductTests.skill1
        combative.engagement = 1
        let national = Tactics(profile: nil, skill: BotTier.national.skillBand.upperBound, style: combative)
        #expect(!national.covers && national.coversTackers && national.coverLate == 12 && national.laneHeader == 3)
        #expect(national.startLuffUntil == 5 && national.startHoldsGroundSeconds == 30)
    }

    /// #234 acceptance (#223: "targets by tactical value only, blind to human or bot"): a port bot meeting a starboard
    /// boat she can lee-bow, with another starboard boat near, chooses the same target, and decides the same, whichever
    /// of the two a human sails.
    @Test func targetIgnoresHumanFlag() throws {
        func play(_ seats: [SeatKind]) throws -> (play: BotBrain.FleetPlay?, decision: BotDecision) {
            let scene = Scene(seats: seats, seed: 9)
            let starboard = scene.centre
            let other = scene.offStarboardBoat(at: starboard, ahead: -1, leeward: -4)
            let port = scene.offStarboardBoat(at: starboard, ahead: 4, leeward: 1.75)
            try scene.place([scene.beating(.port, at: port), scene.beating(.starboard, at: starboard),
                             scene.beating(.starboard, at: other)])
            let view = scene.race.seatView(for: 0)
            var brain = Self.pilot(seat: 0, scene.race, planned: .port).brain
            brain.observe(view.own, view)
            let play = brain.fleetPlay(view.own, view, planned: .port, headed: 0, lean: 0, threshold: deg2rad(5)) { _ in false }
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

    // MARK: #366: live bots ramp to the tactician's tactics through the National band

    /// Live bots of every temperament: willing and reluctant tackers, either favoured side, combative and own-race.
    static let liveStyles: [@Sendable (Double) -> BotStyle] = [
        (0.0, -1.0, 0.0), (0.5, 0.0, 0.5), (1.0, 1.0, 1.0), (0.2, 0.6, 0.8), (0.9, -0.4, 0.3),
    ].map { willingness, side, engagement in
        { skill in
            BotStyle(skill: skill, startSpot: 0.5, finishSpot: 0.7, timingSlack: 0, penaltyDirection: 1,
                     favouredSide: side, tackWillingness: willingness, engagement: engagement)
        }
    }

    /// Her style's and her skill's own, which stay hers at any skill (#234, #337, #102); and the tactician's pure
    /// cover, which stays the tactician's.
    static func withOwnStyle(_ tactics: Tactics, from live: Tactics) -> Tactics {
        var tactics = tactics
        tactics.corridorBias = live.corridorBias
        tactics.tackInterval = live.tackInterval
        tactics.engagement = live.engagement
        tactics.coversTackers = live.coversTackers
        tactics.holdsLane = live.holdsLane
        tactics.leeBows = live.leeBows
        tactics.tacksOnWind = live.tacksOnWind
        tactics.tacticalQuality = live.tacticalQuality
        tactics.puffRange = live.puffRange
        tactics.covers = live.covers
        tactics.tacticEngagement = live.tacticEngagement
        tactics.startEngagement = live.startEngagement
        return tactics
    }

    /// #366 (#364, "the ceiling"): a live bot at the top of the National band sails the tactician's tactics, every
    /// field but her style's own; she keeps her own cover (`coversTackers`), not the tactician's.
    @Test func liveSkillOneSailsTheTacticiansTactics() {
        let top = BotTier.national.skillBand.upperBound
        let tactician = Tactics(profile: .tactician, skill: top)
        for style in Self.liveStyles {
            let live = Tactics(profile: nil, skill: top, style: style(top))
            #expect(live == Self.withOwnStyle(tactician, from: live), "\(style(top))")
            #expect(!live.covers && !live.hunts)
        }
    }

    /// #366 (#364: Club and Regional stay frozen): below the National band a live bot's tactics are #102's, and at its
    /// bottom too.
    @Test func liveTacticsBelowNationalUnchanged() throws {
        let bottom = BotTier.national.skillBand.lowerBound
        for skill in Array(stride(from: 0.0, through: bottom, by: 0.05)) + [bottom] {
            for style in Self.liveStyles {
                let s = style(skill)
                let live = Tactics(profile: nil, skill: skill, style: s)
                let threshold = deg2rad(3 + 2 * (1 - s.tackWillingness) + 12 * max(0, 0.75 - skill))
                let header = try #require(live.headerThreshold)
                #expect(header == threshold)
                #expect(live.anticipation == 0 && live.corridor == 0.35 && live.downwindShiftThreshold == nil)
                #expect(!live.heatsUpInLulls && !live.pinchesToFetch && !live.goesToThePressure && !live.seeksClearAir)
                #expect(!live.runsToPressure && !live.gybesOutOfShadow && !live.startsAtFavouredEnd)
                #expect(!live.covers && !live.hunts && live.replanes && live.rollsTacks)
            }
        }
    }

    /// #366: through the National band each ramped tactic moves only toward the tactician's, and none she takes up is
    /// ever dropped again; her style's own stay hers all the way.
    @Test func liveTacticsRampMonotonicThroughNational() throws {
        let band = BotTier.national.skillBand
        let skills = (0...20).map { band.lowerBound + (band.upperBound - band.lowerBound) * Double($0) / 20 }
        let tactician = Tactics(profile: .tactician, skill: band.upperBound)
        let target = try #require(tactician.headerThreshold)
        for style in Self.liveStyles {
            var previous: Tactics?
            for skill in skills {
                let live = Tactics(profile: nil, skill: skill, style: style(skill))
                let header = try #require(live.headerThreshold)
                if let p = previous {
                    #expect(live.anticipation >= p.anticipation && live.anticipation <= tactician.anticipation)
                    #expect(live.corridor >= p.corridor && live.corridor <= tactician.corridor)
                    let previousHeader = try #require(p.headerThreshold)
                    #expect(abs(header - target) <= abs(previousHeader - target) + 1e-12)
                    let switches: [KeyPath<Tactics, Bool>] = [
                        \.heatsUpInLulls, \.pinchesToFetch, \.seeksClearAir, \.goesToThePressure, \.runsToPressure,
                        \.gybesOutOfShadow, \.startsAtFavouredEnd, \.seeksPuffs, \.seeksPressure, \.replanes,
                    ]
                    for key in switches where p[keyPath: key] {
                        #expect(live[keyPath: key], "\(key) switched back off at \(skill)")
                    }
                    if p.downwindShiftThreshold != nil {
                        #expect(live.downwindShiftThreshold == tactician.downwindShiftThreshold)
                    }
                    #expect(live.corridorBias == p.corridorBias && live.tackInterval == p.tackInterval)
                    #expect(live.engagement == p.engagement && live.coversTackers == p.coversTackers)
                    #expect(live.holdsLane == p.holdsLane && live.leeBows == p.leeBows && live.tacksOnWind == p.tacksOnWind)
                }
                #expect(!live.covers && !live.hunts)
                previous = live
            }
            // The ramp takes her all the way: every switch is on by the top.
            let top = try #require(previous)
            #expect(top.heatsUpInLulls && top.pinchesToFetch && top.seeksClearAir && top.goesToThePressure)
            #expect(top.runsToPressure && top.gybesOutOfShadow && top.startsAtFavouredEnd)
        }
        // Each switch at or before the top, staggered through the band.
        let switchOns = [Tactics.nationalHeatsUpInLulls, Tactics.nationalPinchesToFetch, Tactics.nationalDownwindShifts,
                         Tactics.nationalSeeksClearAir, Tactics.nationalPressureAndLine]
        #expect(switchOns.allSatisfy { $0 > 0 && $0 <= 1 })
        #expect(switchOns == switchOns.sorted() && Set(switchOns).count == switchOns.count)
    }
}

/// #329: the fleet tactics' tuning follow-ups to #234.
@Suite struct FleetTacticsTuningTests {
    /// #329 ("calibrate the shadow-loss estimate ... so the check actually binds"): at the forecast trigger (a factor of
    /// 0.72, where she tacks on a boat's wind in `BotTacticsTests.crossingAhead`), with her own plan neutral, the tack
    /// pays in light air (#263's tack costs 0.74 L at 6 kn) and not at 10 or 14 kn (1.10, 1.27 L). It pays at 14 kn
    /// with her plan leaning to the other tack by half her threshold, and never, not even at 6 kn, lifted on this tack
    /// by her threshold. The deepest shadow (#263's 0.48 close in) pays at every wind, plan neutral.
    @Test func tackOnWindPayoffBinds() {
        let threshold = deg2rad(4)
        func pays(_ knots: Double, factor: Double = 0.72, lean: Double = 0) -> Bool {
            BotBrain.paysToTackOnWind(windSpeed: knots * 0.514444, factor: factor, lean: lean, threshold: threshold)
        }
        #expect(pays(6))
        #expect(!pays(10))
        #expect(!pays(14))
        #expect(pays(14, lean: threshold / 2))
        #expect(!pays(6, lean: -threshold))
        #expect(pays(6, factor: 0.52) && pays(10, factor: 0.52) && pays(14, factor: 0.52))
    }

    /// #329 ("`ownCone` finds her cone by seat order with no check that the cone is hers"): every seat's own cone in a
    /// three-boat race is the one the race casts from her boat; and a cone is hers only from where she is and along her
    /// heading, float noise aside: another boat's, or one turned a hundredth of a radian, isn't.
    @Test func ownConeIsHers() throws {
        let scene = BotTacticsTests.Scene(seats: [.bot, .bot, .bot], seed: 9)
        let starboard = scene.centre
        try scene.place([scene.beating(.port, at: scene.offStarboardBoat(at: starboard, ahead: 4, leeward: 1.75)),
                         scene.beating(.starboard, at: starboard),
                         scene.beating(.starboard, at: scene.offStarboardBoat(at: starboard, ahead: -1, leeward: -4))])
        let brain = BotTacticsTests.pilot(seat: 0, scene.race, planned: .port).brain
        for seat in 0..<3 {
            let view = scene.race.seatView(for: seat)
            #expect(brain.ownCone(view.own, view) == scene.race.shadowCone(ofSeat: seat), "seat \(seat)")
        }
        let boat = scene.race.boats[1]
        let cone = try #require(scene.race.shadowCone(ofSeat: 1))
        #expect(BotBrain.isCone(cone, castFrom: boat.position + Vec2(1e-9, -1e-9), heading: boat.heading + 1e-12))
        #expect(!BotBrain.isCone(cone, castFrom: scene.race.boats[0].position, heading: boat.heading))
        #expect(!BotBrain.isCone(cone, castFrom: boat.position, heading: boat.heading + 0.01))
        #expect(!BotBrain.isCone(cone, castFrom: boat.position, heading: boat.heading + .pi))
    }
}

extension BotTacticsTests {
    /// #377: her tack forecast reads her ribbons and her backwind as the sim then applies them. A National port bot
    /// sailing at a starboard boat (to tack on its wind: from 7 ahead and 2 to leeward; into her backwind, the lee-bow:
    /// from 5.5 ahead and 3.5 to leeward, `leeBowsInsteadOfDuckingWhenPossible`'s), her forecast at 4, 5 and 6 s once it
    /// says her tack would land; then she taps at once and the race
    /// sails it: at each of those seconds its factor is her ribbons' and zone's within 0.2; from 5 s on its backwind flag
    /// is what the race's zone says, and at 6 s both have her in her shadow or neither.
    @Test func tackForecastReadsRibbonsAndBackwind() throws {
        // skiff@6: the unsteered boats beat on the autohelm while the ribbons form (#437).
        let autohelm = try BotHelmTests.autohelmOn().ref
        for seed in Self.fleetSeeds {
            for (ahead, leeward, backwind) in [(7.0, 2.0, false), (5.5, 3.5, true)] {
                let scene = Scene(seed: seed, boatClass: autohelm)
                let port = scene.offStarboardBoat(at: scene.centre, ahead: ahead, leeward: leeward)
                try scene.place([scene.beating(.port, at: port), scene.beating(.starboard, at: scene.centre)])
                let race = scene.race
                var brain = Self.pilot(seat: 0, race, planned: .port).brain
                // Sail on (her ribbon forming on port) until her forecast says her tack would land the boat in her
                // backwind (the lee-bow) or in her shadow (tacking on its wind), as a bot would tap there.
                var forecast: [(astern: Double, abeam: Double, factor: Double, backwind: Bool)] = []
                for _ in 0..<(10 * Race.tickRate) {
                    race.step()
                    guard race.tick.isMultiple(of: BotDriver.decisionInterval) else { continue }
                    let view = race.seatView(for: 0)
                    brain.observe(view.own, view)
                    let other = try #require(view.others.first { $0.seat == 1 })
                    forecast = try #require(brain.tackForecast(view.own, view, on: other))
                    let lands = backwind ? brain.leeBowLands(view.own, view, other)
                        : forecast.reduce(0) { $0 + $1.factor } / Double(forecast.count) < 0.9
                    if lands { break }
                }
                let from = race.tick
                race.tap(.tackGybe, seat: 0, atTick: race.tick + 1)
                var actual: [(factor: Double, backwind: Bool)] = []
                for t in BotBrain.FleetTactics.tackOnWindSeconds {
                    while race.tick < from + Int((t * Double(Race.tickRate)).rounded()) { race.step() }
                    let zone = try #require(race.shadowCone(ofSeat: 0))
                    let them = race.boats[1].position
                    actual.append(((1 - race.wake.loss(of: 0, at: them, tick: race.tick)) * zone.factor(at: them), zone.isInBackwind(them)))
                }
                let note = "seed \(seed), \(ahead) ahead \(leeward) leeward: forecast \(forecast.map { ($0.factor, $0.backwind) }), sim \(actual)"
                // Her reckoning runs about a second ahead of her real tack (seeds 3, 11, 20: the ribbon's leading edge and
                // her new backwind arrive up to a second later than reckoned), so the edges agree from 5 s on.
                for (k, (f, a)) in zip(forecast, actual).enumerated() {
                    #expect(abs(f.factor - a.factor) <= 0.2, "\(note)")
                    guard k > 0 else { continue }
                    #expect(f.backwind == a.backwind, "\(note)")
                }
                if let f = forecast.last, let a = actual.last { #expect((f.factor < 1) == (a.factor < 1), "\(note)") }
                #expect(actual.contains { $0.backwind } == backwind, "\(note)")
            }
        }
    }
}
