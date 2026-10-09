import Foundation
import Testing
import RegattaCore
@testable import RegattaBots

/// #101: a bot's conduct under the rules. Two bots at skill 1 meet in every relation the rules give them (#19: "they
/// foul only by misjudging"; a skill-1 bot misjudges nothing a scripted encounter sets her), and as the right-of-way
/// boat a bot holds her course (#228), never ruddering a turn towards a boat that must keep clear of her.
@Suite struct BotConductTests {
    /// A skill-1 bot: the most skilled there is.
    static let skill1 = BotStyle(skill: 1, startSpot: 0.5, finishSpot: 0.7, timingSlack: 0, penaltyDirection: 1)
    /// Skills from none to the most: each tier band's ends and centre (#102's bands, Club 0.35…0.6, Regional …0.8,
    /// National …1), and below Club.
    static let everySkill = [0.0, 0.35, 0.475, 0.6, 0.7, 0.8, 0.9, 1.0]

    /// One boat's place in an encounter: where she is, her heading and speed, what her autohelm holds (her wind
    /// angle held as she sails it, unless given), and her status.
    struct Placement {
        var position: Vec2
        var heading: Double
        var speed: Double
        var status: BoatStatus = .racing
        var autohelm: Autohelm.Target?
        /// The leg she is sailing; the water's by default.
        var legIndex: Int?
    }

    /// Two bots after the gun on seed `seed`'s race, both seats bots, nothing placed yet: open water on the course,
    /// a third of the way up the beat for boats beating to the windward mark, or two thirds for boats running down to
    /// the gate (`running`); the wind there, and the best upwind and downwind in it.
    /// The class the scripted encounters' water sails (`Water`): the default, or a pinned one a test binds (#437).
    @TaskLocal static var waterClass: FileRef = RaceFiles.defaults.boatClass.ref

    struct Water {
        let race: Race
        let wind: Double
        let up: PolarTable.Optimum
        let down: PolarTable.Optimum
        let centre: Vec2
        let length: Double
        /// The leg boats sail there: to the windward mark, or running, to the gate.
        let leg: Int

        init(seed: UInt64, running: Bool = false) {
            race = botRace(seats: [.bot, .bot], seed: seed, boatClass: BotConductTests.waterClass)
            for _ in 0..<(race.setup.startSequenceTicks + Race.tickRate) { race.step() }
            let c = race.course
            centre = c.startLine.centre + c.upwind * (c.beat * (running ? 0.7 : 0.35))
            leg = running ? 2 : 0
            let wind = race.groundWind(at: centre)
            self.wind = wind.direction
            up = race.boatClass.polar.bestUpwind(tws: wind.speed)
            down = race.boatClass.polar.bestDownwind(tws: wind.speed)
            length = race.boatClass.hull.length
        }

        /// Before the gun (#280): two bots on seed `seed`'s race, `toGun` seconds before it, nothing placed yet, the
        /// water `below` hull lengths below the middle of the start line.
        init(seed: UInt64, toGun: Int, below: Double) {
            race = botRace(seats: [.bot, .bot], prestartSeconds: toGun + 10, seed: seed, boatClass: BotConductTests.waterClass)
            for _ in 0..<(10 * Race.tickRate) { race.step() }
            let c = race.course
            length = race.boatClass.hull.length
            centre = c.startLine.centre - c.upwind * (length * below)
            leg = 0
            let wind = race.groundWind(at: centre)
            self.wind = wind.direction
            up = race.boatClass.polar.bestUpwind(tws: wind.speed)
            down = race.boatClass.polar.bestDownwind(tws: wind.speed)
        }

        /// Her heading on `tack` at wind angle `angle`.
        func heading(_ tack: Tack, _ angle: Double) -> Double { tack == .starboard ? wind - angle : wind + angle }
        func beat(_ tack: Tack) -> Double { heading(tack, up.twa) }
        func run(_ tack: Tack) -> Double { heading(tack, down.twa) }
    }

    /// Places seat 0 and seat 1 in `water`'s race as `placements` say: each boat's boom on her tack's side, the rudder
    /// centred, the autohelm holding her wind angle (or what the placement gives), no penalty owed.
    static func place(_ water: Water, _ placements: [Placement], edit: (inout WorldSnapshot) -> Void = { _ in }) throws -> Race {
        let race = water.race
        var snapshot = race.exportSnapshot()
        for (seat, placement) in placements.enumerated() {
            let relative = wrapAngle(water.wind - placement.heading)
            snapshot.seats[seat].boat.position = placement.position
            snapshot.seats[seat].boat.heading = placement.heading
            snapshot.seats[seat].boat.speed = placement.speed
            snapshot.seats[seat].boat.boomSide = relative >= 0 ? .port : .starboard
            snapshot.seats[seat].boat.status = placement.status
            snapshot.seats[seat].boat.legIndex = placement.legIndex ?? water.leg
            snapshot.seats[seat].boat.roundingStage = 0
            snapshot.seats[seat].boat.autohelm = Autohelm(target: placement.autohelm ?? .angle(abs(relative)))
            snapshot.seats[seat].boat.rudder = 0
            snapshot.seats[seat].boat.isTacking = false
            snapshot.seats[seat].heldInput = .neutral
        }
        // Placed boats start in clean air (#377): no ribbons, headers or backwind from where they were.
        snapshot.ribbonPoints = []
        snapshot.emissionLevels = []
        snapshot.headers = []
        snapshot.backwind = BackwindSails()
        edit(&snapshot)
        try race.importSnapshot(snapshot)
        _ = race.drainEvents()
        return race
    }

    /// A bot at the helm of `seat`, deciding at 10 Hz on its `SeatView` as `BotDriver` does, with the tack she means to
    /// sail set: at `skill` with its weaknesses (#103), or with `weaknesses` if given; her own draws from her seat.
    struct Pilot {
        let seat: Int
        var brain: BotBrain

        init(seat: Int, plannedTack: Tack?, race: Race, skill: Double = 1, weaknesses: BotWeaknesses? = nil,
             caution: BotBrain.Caution? = nil, profile: BotProfile? = nil) {
            self.seat = seat
            var style = BotConductTests.skill1
            style.skill = skill
            brain = BotBrain(style: style, profile: profile, seed: UInt64(seat + 1), weaknesses: weaknesses, caution: caution)
            if profile == nil {
                // #366: a scripted encounter sails a live bot's own tactics (#102), as at the bottom of the National band,
                // with her own skill's execution and weaknesses: the ramp to the tactician's (seeking clear air,
                // anticipating, setting up at the favoured end) would steer her away from the boat the scene puts her
                // against, and the scene would test nothing. The ramp's conduct is the bot matrix's (National tier).
                brain.tactics = Tactics(profile: nil, skill: min(skill, BotTier.national.skillBand.lowerBound),
                                        style: style, weaknesses: brain.weaknesses)
            }
            brain.plannedTack = plannedTack ?? race.boats[seat].tack
        }

        /// Decides on a decision tick; returns the decision sent.
        mutating func drive(_ race: Race) -> BotDecision? {
            guard (race.tick + seat).isMultiple(of: BotDriver.decisionInterval) else { return nil }
            let decision = brain.decide(race.seatView(for: seat))
            race.apply(decision.input, seat: seat, atTick: race.tick + 1)
            if let tap = decision.tap { race.tap(tap, seat: seat, atTick: race.tick + 1) }
            return decision
        }
    }

    /// Sails `race` with both seats' bots for `seconds`, at `skill` (skill 1 unless given) or with `weaknesses` (each
    /// seat's, if given), cautious with `caution` (#104) if given: every event, and `each` after every step.
    static func sail(_ race: Race, seconds: Double, planned: [Tack?] = [nil, nil], skill: Double = 1,
                     weaknesses: [BotWeaknesses?] = [nil, nil], caution: BotBrain.Caution? = nil,
                     each: (Race) -> Void = { _ in }) -> [RaceEvent.Kind] {
        var pilots = [0, 1].map {
            Pilot(seat: $0, plannedTack: planned[$0], race: race, skill: skill, weaknesses: weaknesses[$0], caution: caution)
        }
        var kinds: [RaceEvent.Kind] = []
        for _ in 0..<Int(seconds * Double(Race.tickRate)) where !race.isOver {
            for i in pilots.indices { _ = pilots[i].drive(race) }
            race.step()
            each(race)
            kinds += race.drainEvents().map(\.kind)
        }
        return kinds
    }

    /// The rule calls in `kinds`, as "rule on offender".
    static func calls(_ kinds: [RaceEvent.Kind]) -> [String] {
        kinds.compactMap { if case .ruleCall(let call) = $0 { "\(call.rule.rawValue) on \(call.offender)" } else { nil } }
    }

    /// Every scripted encounter: its name, and the race it begins, with the tacks the two bots mean to sail.
    typealias Encounter = (name: String, race: () throws -> Race, planned: [Tack?], seconds: Double)

    /// Port and starboard beating or running into each other, the port boat arriving `early` seconds before the
    /// starboard one at the crossing (negative: after).
    static func portStarboard(seed: UInt64, early: Double, running: Bool) -> Encounter {
        ("port/starboard \(running ? "running" : "beating") early \(early) s (seed \(seed))", {
            let water = Water(seed: seed, running: running)
            let speed = running ? water.down.speed : water.up.speed
            let starboard = running ? water.run(.starboard) : water.beat(.starboard)
            let port = running ? water.run(.port) : water.beat(.port)
            let meet = 7.0
            return try place(water, [
                Placement(position: water.centre - Vec2.heading(starboard) * speed * meet, heading: starboard, speed: speed),
                Placement(position: water.centre - Vec2.heading(port) * speed * (meet - early), heading: port, speed: speed),
            ])
        }, [.starboard, .port], 25)
    }

    /// Overlapped on starboard, seat 1 `abeam` hull lengths to windward of seat 0 and `ahead` hull lengths ahead,
    /// bearing away `converging` radians towards her; or seat 1 clear astern and to leeward, faster, sailing into an
    /// overlap to leeward of seat 0 (`fromAstern`).
    static func windwardLeeward(seed: UInt64, running: Bool, abeam: Double, ahead: Double, converging: Double,
                                fromAstern: Bool = false) -> Encounter {
        ("windward/leeward \(running ? "running" : "beating") abeam \(abeam) ahead \(ahead)\(fromAstern ? " from astern" : "") (seed \(seed))", {
            let water = Water(seed: seed, running: running)
            let speed = running ? water.down.speed : water.up.speed
            let heading = running ? water.run(.starboard) : water.beat(.starboard)
            let forward = Vec2.heading(heading)
            // On starboard her windward side is her starboard side.
            let windward = forward.rightPerp
            let leeward = Placement(position: water.centre, heading: heading, speed: speed)
            let other: Placement
            if fromAstern {
                other = Placement(position: water.centre - windward * water.length * abeam - forward * water.length * ahead,
                                  heading: heading, speed: speed * 1.35)
            } else {
                // Bearing away on starboard turns her to port, towards the leeward boat.
                other = Placement(position: water.centre + windward * water.length * abeam + forward * water.length * ahead,
                                  heading: heading - converging, speed: speed)
            }
            return try place(water, [leeward, other])
        }, [.starboard, .starboard], 25)
    }

    /// Seat 0 clear astern of seat 1 on the same tack by `astern` hull lengths, `across` hull lengths to one side,
    /// sailing at her speed while seat 1 sails slowly: she catches her up.
    static func clearAstern(seed: UInt64, running: Bool, tack: Tack, astern: Double, across: Double) -> Encounter {
        ("clear astern \(running ? "running" : "beating") on \(tack) astern \(astern) across \(across) (seed \(seed))", {
            let water = Water(seed: seed, running: running)
            let speed = running ? water.down.speed : water.up.speed
            let heading = running ? water.run(tack) : water.beat(tack)
            let forward = Vec2.heading(heading)
            return try place(water, [
                Placement(position: water.centre - forward * water.length * astern + forward.rightPerp * water.length * across,
                          heading: heading, speed: speed),
                Placement(position: water.centre, heading: heading, speed: speed * 0.35),
            ])
        }, [tack, tack], 25)
    }

    /// Seat 0 beating on port, meaning to tack (her planned tack starboard), with seat 1 on starboard `astern` hull
    /// lengths behind and `windward` hull lengths to windward of where her tack would put her: tacking at once would
    /// tack her into seat 1's water.
    static func tackInto(seed: UInt64, astern: Double, windward: Double) -> Encounter {
        ("tack into astern \(astern) windward \(windward) (seed \(seed))", {
            let water = Water(seed: seed)
            let tacked = Vec2.heading(water.beat(.starboard))
            let position = water.centre + tacked * water.length * astern - tacked.rightPerp * water.length * windward
            return try place(water, [
                Placement(position: water.centre, heading: water.beat(.port), speed: water.up.speed),
                Placement(position: position, heading: water.beat(.starboard), speed: water.up.speed),
            ])
        }, [.starboard, .starboard], 25)
    }

    /// Both beating on starboard up the layline to the windward mark, overlapped as they reach its zone: seat 0 inside
    /// (to leeward, nearer the mark), seat 1 `abeam` hull lengths outside and `ahead` hull lengths ahead; or up to the
    /// offset mark on a reach from the windward mark, seat 1 to one side (`offset`, positive to windward).
    static func markRoom(seed: UInt64, abeam: Double, ahead: Double, offsetMark: Bool = false) -> Encounter {
        ("mark-room at the \(offsetMark ? "offset" : "windward") mark abeam \(abeam) ahead \(ahead) (seed \(seed))", {
            let water = Water(seed: seed)
            let c = water.race.course
            let heading: Double, position: Vec2, speed: Double
            if offsetMark {
                let mark = c.elements[CourseLayout.offsetIndex].marks[0].position
                heading = (-c.right).bearing
                position = mark + c.right * (c.zoneRadius + water.length * 6) + c.upwind * water.length * 1.5
                speed = water.up.speed * 1.3
            } else {
                let mark = c.elements[CourseLayout.windwardIndex].marks[0].position
                heading = water.beat(.starboard)
                let fetch = mark + c.right * 6 + c.upwind * 4
                position = fetch - Vec2.heading(heading) * (c.zoneRadius + water.length * 8)
                speed = water.up.speed
            }
            let forward = Vec2.heading(heading)
            let outside = position + forward.rightPerp * water.length * abeam + forward * water.length * ahead
            let leg = offsetMark ? 1 : 0
            return try place(water, [
                Placement(position: position, heading: heading, speed: speed, legIndex: leg),
                Placement(position: outside, heading: heading, speed: speed, legIndex: leg),
            ])
        }, [.starboard, .starboard], 30)
    }

    /// Seat 0 60° into a penalty turn to starboard in open water, reaching on starboard, hard over (#100's 21.2
    /// encounter); seat 1 reaching back past her on port, `ahead` hull lengths ahead and `across` to her starboard.
    static func penalised(seed: UInt64, ahead: Double, across: Double) -> Encounter {
        ("penalised boat ahead \(ahead) across \(across) (seed \(seed))", {
            let water = Water(seed: seed)
            let heading = water.wind - .pi / 2
            let forward = Vec2.heading(heading)
            return try place(water, [
                Placement(position: water.centre, heading: heading, speed: 4),
                Placement(position: water.centre + forward * water.length * ahead + forward.rightPerp * water.length * across,
                          heading: heading + .pi, speed: 4),
            ]) { snapshot in
                snapshot.seats[0].boat.autohelm = nil
                snapshot.seats[0].boat.rudder = 1
                snapshot.seats[0].heldInput = BoatInput(rudder: 1.0)
                snapshot.seats[0].boat.penaltyTurnsOwed = 1
                snapshot.seats[0].boat.penaltyProgress = deg2rad(60)
                snapshot.seats[0].boat.penaltyClockTick = snapshot.tick
            }
        }, [nil, nil], 35)
    }

    /// Seat 0 OCS just after the gun, a hull length over the line and returning (rule 21.1), `along` hull lengths
    /// along the line from seat 1, who is below it, beating up to start.
    static func ocsReturner(seed: UInt64, along: Double) -> Encounter {
        ("OCS returner along \(along) (seed \(seed))", {
            let water = Water(seed: seed)
            let line = water.race.course.startLine
            let across = (line.committee.position - line.pin.position).normalized
            let up = water.race.course.upwind
            let spot = line.centre + across * water.length * along
            return try place(water, [
                Placement(position: spot + up * water.length, heading: water.run(.starboard), speed: water.down.speed * 0.6,
                          status: .ocs),
                Placement(position: line.centre - up * water.length * 4, heading: water.beat(.starboard),
                          speed: water.up.speed, status: .prestart),
            ])
        }, [nil, nil], 30)
    }

    /// Every scripted encounter, with variations.
    static var encounters: [Encounter] {
        var all: [Encounter] = []
        for early in [-1.5, -0.75, 0, 0.75, 1.5] { all.append(portStarboard(seed: 11, early: early, running: false)) }
        for early in [-1.0, 0, 1.0] { all.append(portStarboard(seed: 12, early: early, running: true)) }
        for ahead in [-0.5, 0, 0.5] {
            all.append(windwardLeeward(seed: 13, running: false, abeam: 1.2, ahead: ahead, converging: deg2rad(15)))
            all.append(windwardLeeward(seed: 14, running: true, abeam: 1.2, ahead: ahead, converging: deg2rad(12)))
        }
        all.append(windwardLeeward(seed: 15, running: true, abeam: 1.0, ahead: 2, converging: 0, fromAstern: true))
        all.append(windwardLeeward(seed: 15, running: false, abeam: 1.0, ahead: 1.5, converging: 0, fromAstern: true))
        for across in [0, 0.3] {
            all.append(clearAstern(seed: 16, running: false, tack: .starboard, astern: 2.5, across: across))
            all.append(clearAstern(seed: 17, running: true, tack: .port, astern: 2.5, across: across))
        }
        for (astern, windward) in [(2.0, 1.0), (3.0, 1.5), (4.0, 0.5)] {
            all.append(tackInto(seed: 18, astern: astern, windward: windward))
        }
        for (abeam, ahead) in [(1.2, 0.0), (1.2, 0.6), (1.5, -0.6)] { all.append(markRoom(seed: 19, abeam: abeam, ahead: ahead)) }
        for abeam in [1.2, -1.2] { all.append(markRoom(seed: 20, abeam: abeam, ahead: 0, offsetMark: true)) }
        for (ahead, across) in [(14.0 / 4.9, 7.0 / 4.9), (2.0, 0.5), (4.0, 1.0)] {
            all.append(penalised(seed: 5, ahead: ahead, across: across))
        }
        for along in [-1.0, 0, 1.0] { all.append(ocsReturner(seed: 21, along: along)) }
        return all
    }

    /// #101 acceptance: two skill-1 bots meet in every relation the rules give them (port and starboard, overlapped
    /// to windward and leeward, clear astern, a tack into another boat's water, mark-room inside and outside, a
    /// boat turning a penalty and one returning OCS), each in several variations, and no rule call is made on
    /// either: each keeps clear when she must and holds her course when she needn't. Neither ever protests.
    @Test func scriptedEncountersZeroFoulsAtSkill1() throws {
        // skiff@6 until #455: the scripted encounters' bots miss each other or draw calls under hand steering.
        try Self.$waterClass.withValue(BotHelmTests.autohelmOn().ref) { try Self.checkScriptedEncountersZeroFouls() }
    }

    static func checkScriptedEncountersZeroFouls() throws {
        var failures: [String] = []
        var markRoomEncounters = 0
        var closest = Double.infinity
        for encounter in Self.encounters {
            let race = try encounter.race()
            var nearest = Double.infinity
            var hadMarkRoom = false
            let kinds = Self.sail(race, seconds: encounter.seconds, planned: encounter.planned) { race in
                nearest = min(nearest, (race.boats[0].position - race.boats[1].position).length)
                // The umpire's rule 18 record, as the bots read it: no event announces it (#403).
                if !hadMarkRoom, !race.seatView(for: 0).own.markRoom.isEmpty { hadMarkRoom = true }
            }
            closest = min(closest, nearest)
            let calls = Self.calls(kinds)
            if !calls.isEmpty { failures.append("\(encounter.name): \(calls)") }
            if kinds.contains(where: { if case .protestRecorded = $0 { true } else { false } }) {
                failures.append("\(encounter.name): protested")
            }
            if hadMarkRoom { markRoomEncounters += 1 }
            #expect(nearest < race.boatClass.hull.length * 4, "\(encounter.name): they never met (\(nearest) m)")
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
        #expect(markRoomEncounters >= 3, "the mark-room encounters made rule 18 records")
    }

    /// "Tacks away from a boat alongside" (#263): two bots beating on starboard side by side, a hull length apart (inside
    /// the clearance a tack keeps), both meaning to tack onto port, the windward one misjudging her keep-clear (#103) so
    /// she doesn't luff out of the clearance first. The windward one, whose tack only opens the gap, tacks; the leeward
    /// one, whose tack would sail her into the other, waits. Before, each waited on the other and they sailed on together
    /// (BotEdgeTests, seed 1 in the sea breeze: into the race area's edge).
    @Test func theWindwardBoatAlongsideTacksAway() throws {
        for seed: UInt64 in [3, 9, 16] {
            let water = Water(seed: seed)
            let heading = water.beat(.starboard)
            let forward = Vec2.heading(heading)
            let race = try Self.place(water, [
                Placement(position: water.centre, heading: heading, speed: water.up.speed),
                Placement(position: water.centre + forward.rightPerp * water.length - forward * water.length * 0.2,
                          heading: heading, speed: water.up.speed),
            ])
            var tackedAt: [Int?] = [nil, nil]
            let kinds = Self.sail(race, seconds: 12, planned: [.port, .port], weaknesses: [nil, Self.misjudging(1)]) { race in
                for seat in 0...1 where tackedAt[seat] == nil && race.boats[seat].tack == .port { tackedAt[seat] = race.tick }
            }
            #expect(Self.calls(kinds).isEmpty, "seed \(seed): \(Self.calls(kinds))")
            let windward = try #require(tackedAt[1], "seed \(seed): the windward boat never tacked")
            #expect(tackedAt[0].map { $0 > windward } ?? true, "seed \(seed): the leeward boat tacked first: \(tackedAt)")
        }
    }

    /// The closest `other` comes to `boat` over `horizon` seconds were `boat` sailing `heading` at her speed, `other`
    /// sailing on at hers: both in straight lines, in the same water. Metres between centres.
    static func closestApproach(_ boat: Boat, heading: Double, _ other: Boat, horizon: Double) -> Double {
        let offset = other.position - boat.position
        let relative = other.velocity - Vec2.heading(heading) * boat.speed
        let vv = relative.lengthSquared
        let t = vv > 1e-9 ? (-offset.dot(relative) / vv).clamped(to: 0...horizon) : 0
        return (offset + relative * t).length
    }

    /// #101 acceptance, the owner's invariant (2026-09-26): as the right-of-way boat a bot never initiates a course
    /// change towards a boat that must keep clear of her inside her escape horizon. A course change is her heading
    /// turning faster than the rules' "changes course" rate (16.1, `RulesConfig.Escape.changesCourse`), initiated by
    /// her when her rudder is held off centre that way: a turn her autohelm makes with the rudder centred, following
    /// a shift, isn't hers (#228). Towards a boat inside the escape horizon (`RulesConfig.Escape.horizon`): the turn
    /// brings that boat's closest approach over the horizon, sailing on, closer than it was on her heading before it,
    /// and inside `clearance` hull lengths. Checked tick by tick through the scripted encounters where one bot has
    /// right of way over the other, in whatever the wind does, but for a bot sailing within the mark-room she is
    /// entitled to from the other (rule 18.2: the room the other must give her, #93), or for a bot owing a penalty turn,
    /// who keeps clear of every boat as she turns it (rule 21.2, #100). At every skill (#103): both bots sail with their
    /// skill's weaknesses, misjudging encounters as it has them, and still neither ever turns towards a boat that must
    /// keep clear of her.
    @Test(arguments: BotConductTests.everySkill)
    func rightOfWayBotNeverRuddersTowardAKeepClearBoat(skill: Double) throws {
        // skiff@6 until #455: right-of-way bots turn towards a keep-clear boat under hand steering.
        try Self.$waterClass.withValue(BotHelmTests.autohelmOn().ref) {
            try Self.checkRightOfWayNeverRuddersTowardAKeepClearBoat(skill: skill)
        }
    }

    /// #104: the cautious bot holds to #101's invariant too: both bots cautious, at her skill and with her weaknesses.
    @Test func cautiousRightOfWayBotNeverRuddersTowardAKeepClearBoat() throws {
        let skill = BotBrain.Caution.skill
        try Self.checkRightOfWayNeverRuddersTowardAKeepClearBoat(skill: skill, weaknesses: BotBrain.Caution.weaknesses(skill: skill),
                                                                   caution: .standard)
    }

    /// #388 (from #360): the cautious bot (#104) 30° to 60° into a penalty turn, hard over, near a boat that holds its
    /// course, never fouls it: turning, she keeps clear of every boat (rule 21.2), so her look before she leaps
    /// (`guarded`) covers the turn's own path. She reaches on starboard and bears away into the turn, its circle
    /// sweeping to port; the other boat, on her port side, sails on what her autohelm holds, never steering for her:
    /// overtaking her from her port quarter a little faster on near enough her course (seed 82 of
    /// `CautiousBotSuiteTests`: she bore away round her circle into a boat overtaking her there), alongside, or
    /// reaching back past her.
    @Test func cautiousBotTurningAPenaltyNearABoatHoldingCourseDoesNotFoul() throws {
        var fouls: [String] = []
        var encounters = 0
        for progress in [30.0, 45.0, 60.0] {
            // The other boat: hull lengths ahead of her and to port, her heading off hers, and her speed.
            for (ahead, toPort, off, speed) in [(-1.3, 0.95, 7.0, 3.7), (-2.0, 1.0, 0.0, 3.7), (-1.0, 1.2, 10.0, 3.5),
                                                (0.0, 1.4, 0.0, 3.0), (-0.5, 1.6, 5.0, 3.2),
                                                (2.0, 1.2, 180.0, 3.0), (3.0, 0.8, 180.0, 3.0)] {
                let water = Water(seed: 5)
                let heading = water.wind - .pi / 2
                let forward = Vec2.heading(heading)
                let race = try Self.place(water, [
                    Placement(position: water.centre, heading: heading, speed: 2.9),
                    Placement(position: water.centre + forward * water.length * ahead - forward.rightPerp * water.length * toPort,
                              heading: heading + deg2rad(off), speed: speed),
                ]) { snapshot in
                    snapshot.seats[0].boat.autohelm = nil
                    snapshot.seats[0].boat.rudder = -1
                    snapshot.seats[0].heldInput = BoatInput(rudder: -1.0)
                    snapshot.seats[0].boat.penaltyTurnsOwed = 1
                    snapshot.seats[0].boat.penaltyProgress = -deg2rad(progress)
                    snapshot.seats[0].boat.penaltyClockTick = snapshot.tick
                }
                let skill = BotBrain.Caution.skill
                var pilot = Pilot(seat: 0, plannedTack: nil, race: race, skill: skill,
                                  weaknesses: BotBrain.Caution.weaknesses(skill: skill), caution: .standard)
                var kinds: [RaceEvent.Kind] = []
                for _ in 0..<(30 * Race.tickRate) where !race.isOver {
                    _ = pilot.drive(race)
                    race.step()
                    kinds += race.drainEvents().map(\.kind)
                }
                encounters += 1
                let calls = Self.calls(kinds)
                if !calls.isEmpty { fouls.append("\(progress)° in, ahead \(ahead) to port \(toPort) off \(off)°: \(calls)") }
            }
        }
        #expect(encounters == 21)
        #expect(fouls.isEmpty, "\(fouls.joined(separator: "\n"))")
    }

    /// `rightOfWayBotNeverRuddersTowardAKeepClearBoat` at `skill`, both bots with `weaknesses` (their skill's if nil) and
    /// `caution`.
    static func checkRightOfWayNeverRuddersTowardAKeepClearBoat(skill: Double, weaknesses: BotWeaknesses? = nil,
                                                                caution: BotBrain.Caution? = nil) throws {
        let clearance = 1.5
        var violations: [String] = []
        var checked = 0
        var courseChanges = 0
        let encounters = Self.encounters.filter { !$0.name.hasPrefix("penalised") && !$0.name.hasPrefix("OCS") }
        for encounter in encounters {
            let race = try encounter.race()
            let escape = race.rules.incidents.escape
            let changesCourse = try #require(escape.changesCourse)
            let length = race.boatClass.hull.length
            var headings = race.boats.map(\.heading)
            _ = Self.sail(race, seconds: encounter.seconds, planned: encounter.planned, skill: skill,
                          weaknesses: [weaknesses, weaknesses], caution: caution) { race in
                defer { headings = race.boats.map(\.heading) }
                for seat in 0..<2 where race.boats[seat].status == .racing {
                    let other = 1 - seat
                    guard let right = race.rightOfWay(seat, other), right.keepClear == other else { continue }
                    // Sailing within the mark-room she is entitled to from that boat (18.2), she turns as the mark has
                    // her: that's the room the other must give (#93 exonerates her).
                    let view = race.seatView(for: seat)
                    guard !view.own.markRoom.contains(where: { $0.entitled == seat && $0.owing == other }) else { continue }
                    // Owing a penalty turn she turns it hard over (#89, #100), keeping clear of every boat under rule
                    // 21.2 rather than holding rights: below Club's centre a bot sometimes owes one here, from a mark
                    // she touched or an encounter she misjudged (#103).
                    guard race.boats[seat].penaltyTurnsOwed == 0 else { continue }
                    checked += 1
                    let boat = race.boats[seat]
                    let rudder = race.heldInputs[seat].rudder
                    let turned = wrapAngle(boat.heading - headings[seat])
                    guard rudder != 0, (turned > 0) == (rudder > 0),
                          abs(turned) * Double(Race.tickRate) > changesCourse else { continue }
                    courseChanges += 1
                    let now = Self.closestApproach(boat, heading: boat.heading, race.boats[other], horizon: escape.horizon)
                    let before = Self.closestApproach(boat, heading: headings[seat], race.boats[other], horizon: escape.horizon)
                    if now < length * clearance && now < before {
                        violations.append("skill \(skill) \(encounter.name): tick \(race.tick) seat \(seat) turned \(rad2deg(turned))° "
                            + "with rudder \(rudder) towards seat \(other) (\(before) → \(now) m)")
                    }
                }
            }
        }
        #expect(checked > 1_000, "right of way held in the encounters")
        #expect(courseChanges > 0, "the right-of-way bots changed course by the rudder somewhere")
        #expect(violations.isEmpty, "\(violations.prefix(20).joined(separator: "\n"))")
    }

    // MARK: - Misjudging (#103)

    /// #103: the chance a bot misjudges an encounter falls with her skill, continuously, from certain at skill 0 to none
    /// from National's band up (placeholders): Club's centre misjudges more than Regional's, and National's none.
    @Test func ruleMisjudgeRateFallsWithSkillToNoneAtNational() {
        let skills = stride(from: 0.0, through: 1.0, by: 0.01).map { $0 }
        let rates = skills.map { BotWeaknesses(skill: $0).ruleMisjudgeRate }
        for (a, b) in zip(rates, rates.dropFirst()) { #expect(b <= a) }
        for (a, b) in zip(rates, rates.dropFirst()) { #expect(a - b < 0.03, "continuous in skill") }
        #expect(rates.first == 1)
        #expect(rates.allSatisfy { $0 >= 0 && $0 <= 1 })
        let national = BotTier.national.skillBand
        #expect(zip(skills, rates).allSatisfy { !national.contains($0) || $1 == 0 }, "none in National's band")
        func centre(_ tier: BotTier) -> Double { BotWeaknesses(skill: tier.skill(at: 0.5)).ruleMisjudgeRate }
        #expect(centre(.club) > centre(.regional) && centre(.regional) > 0 && centre(.national) == 0,
                "club \(centre(.club)), regional \(centre(.regional))")
        #expect(BotWeaknesses.none(skill: 0).ruleMisjudgeRate == 0, "a bot-suite profile misjudges nothing")
        #expect(BotWeaknesses.misjudgeScope == [.portStarboard, .windwardLeeward, .clearAstern, .givingMarkRoom])
    }

    /// #103: how far ahead she looks keeping clear grows with her skill, 2.5 s at 0 to 4.5 s at 1, #99's and #101's
    /// lookahead as it was, for a live bot and a bot-suite profile alike; her brain looks that far.
    @Test func keepClearLookaheadGrowsWithSkill() {
        for skill in stride(from: 0.0, through: 1.0, by: 0.05) {
            let lookahead = BotWeaknesses(skill: skill).keepClearLookahead
            #expect(abs(lookahead - (2.5 + 2 * skill)) < 1e-12)
            #expect(BotWeaknesses.none(skill: skill).keepClearLookahead == lookahead)
            var style = Self.skill1
            style.skill = skill
            #expect(BotBrain(style: style).keepClearLookahead == lookahead)
            #expect(BotBrain(style: style, profile: .baseline).keepClearLookahead == lookahead)
        }
    }

    /// Skill-1 weaknesses (none), but misjudging every encounter in scope at `rate`.
    static func misjudging(_ rate: Double) -> BotWeaknesses {
        var weaknesses = BotWeaknesses(skill: 1)
        weaknesses.ruleMisjudgeRate = rate
        return weaknesses
    }

    /// #103, #19 "they foul only by misjudging": a port boat that misjudges the encounter believes she holds her rights
    /// and sails on into the starboard boat, and is called under rule 10; judging it right, she ducks and nobody is
    /// called. The starboard boat holds her course throughout.
    @Test func misjudgingPortBoatSailsOnAndIsCalled() throws {
        let encounter = Self.portStarboard(seed: 11, early: 0, running: false)
        let judged = Self.sail(try encounter.race(), seconds: encounter.seconds, planned: encounter.planned,
                               weaknesses: [nil, Self.misjudging(0)])
        #expect(Self.calls(judged).isEmpty)
        let misjudged = Self.sail(try encounter.race(), seconds: encounter.seconds, planned: encounter.planned,
                                  weaknesses: [nil, Self.misjudging(1)])
        let calls = Self.calls(misjudged)
        #expect(calls.first == "10 on 1", "\(calls)")
        #expect(!calls.contains { $0.hasSuffix("on 0") }, "\(calls)")
    }

    /// #103: she judges an encounter once, keeps that judgement while the other boat is near and forgets it once it is
    /// beyond `keepClearRange`; a bot that can't misjudge draws nothing.
    @Test func encountersAreJudgedOnceAndOnlyWhenMisjudgingIsPossible() throws {
        let encounter = Self.portStarboard(seed: 11, early: 0, running: false)
        let race = try encounter.race()
        // Sailing on, nobody at the helm, until they are near each other.
        for _ in 0..<(3 * Race.tickRate) { race.step() }
        let port = race.seatView(for: 1)
        #expect((port.others[0].position - port.own.position).length < BotBrain.keepClearRange)
        var brain = BotBrain(style: Self.skill1, seed: 7, weaknesses: Self.misjudging(1))
        brain.plannedTack = .port
        _ = brain.decide(port)
        #expect(brain.misjudged == [0: true])
        let drawn = brain.rng
        _ = brain.decide(port)
        #expect(brain.misjudged == [0: true])
        var once = brain.rng, then = drawn
        #expect(once.next() == then.next(), "judged once an encounter")
        var never = BotBrain(style: Self.skill1, seed: 7, weaknesses: Self.misjudging(0))
        never.plannedTack = .port
        var untouched = never.rng
        _ = never.decide(port)
        #expect(never.misjudged.isEmpty)
        #expect(never.rng.next() == untouched.next(), "no draw")
        // Beyond `keepClearRange`, she forgets it.
        var far = try encounter.race().exportSnapshot()
        far.seats[0].boat.position = far.seats[1].boat.position + Vec2(x: 0, y: BotBrain.keepClearRange * 2)
        let apart = try encounter.race()
        try apart.importSnapshot(far)
        _ = brain.decide(apart.seatView(for: 1))
        #expect(brain.misjudged.isEmpty)
        // The starboard boat owes the port boat nothing: nothing to judge.
        var starboard = BotBrain(style: Self.skill1, seed: 7, weaknesses: Self.misjudging(1))
        _ = starboard.decide(race.seatView(for: 0))
        #expect(starboard.misjudged.isEmpty)
    }

    // MARK: - Before the start (#280)

    /// Before the gun, both on starboard below the line, `toGun` seconds before it: seat 0 the leeward boat, holding
    /// `leeward` off the wind, seat 1 `abeam` hull lengths to windward of her and `ahead` ahead, holding `windward` off
    /// it, both at `speed`.
    static func prestartWindwardLeeward(seed: UInt64, toGun: Int = 25, leeward: Double, windward: Double, abeam: Double,
                                        ahead: Double = 0, speed: Double = 2) throws -> Race {
        let water = Water(seed: seed, toGun: toGun, below: 5)
        let heading = water.heading(.starboard, leeward)
        let forward = Vec2.heading(heading)
        return try place(water, [
            Placement(position: water.centre, heading: heading, speed: speed, status: .prestart),
            Placement(position: water.centre + forward.rightPerp * water.length * abeam + forward * water.length * ahead,
                      heading: water.heading(.starboard, windward), speed: speed, status: .prestart),
        ])
    }

    /// One decision `sailOne` records.
    struct Sailed {
        var decision: BotDecision
        var keepClear: RacingRule?
        var gap: Double
        var ahead: Double
        var twa: Double
    }

    /// Sails `race` for `seconds` with only `seat`'s bot at the helm, the other boat holding what her autohelm holds:
    /// every decision of the bot's, with the rule she keeps clear of the other boat under as she made it (nil: none),
    /// the metres between them, centre to centre, how far she is ahead of the other boat along its heading, and her
    /// wind angle, and every event.
    static func sailOne(_ race: Race, seat: Int, seconds: Double, skill: Double = 1, weaknesses: BotWeaknesses? = nil,
                        planned: Tack? = nil) -> (decisions: [Sailed], kinds: [RaceEvent.Kind]) {
        var pilot = Pilot(seat: seat, plannedTack: planned, race: race, skill: skill, weaknesses: weaknesses)
        var decisions: [Sailed] = []
        var kinds: [RaceEvent.Kind] = []
        for _ in 0..<Int(seconds * Double(Race.tickRate)) where !race.isOver {
            let view = race.seatView(for: seat)
            let right = view.others.first?.rightOfWay
            let gap = view.others.first.map { ($0.position - view.own.position).length } ?? .infinity
            let ahead = view.others.first.map { (view.own.position - $0.position).dot(Vec2.heading($0.heading)) } ?? 0
            let keepClear = right?.keepClear == seat ? right?.rule : nil
            if let decision = pilot.drive(race) {
                decisions.append(Sailed(decision: decision, keepClear: keepClear, gap: gap, ahead: ahead, twa: view.own.twa))
            }
            race.step()
            kinds += race.drainEvents().map(\.kind)
        }
        return (decisions, kinds)
    }

    /// #280 acceptance: before the gun, a windward boat holding near close-hauled (#99's hold, a few degrees outside
    /// the no-go zone) with a leeward boat converging on her keeps clear (rule 11): she luffs (rudder towards the wind),
    /// or, with no luff left, eases and drops astern; she never bears away towards her, and the rule 11 call never
    /// comes. #99's luff target sat inside `steer`'s no-go clamp, so she luffed by nothing.
    @Test func windwardLuffHoldingNearCloseHauledLuffs() throws {
        var failures: [String] = []
        for seed: UInt64 in [3, 7, 13] {
            for (windward, abeam, ahead) in [(36.0, 1.1, 0.3), (33.0, 1.1, 0.3), (36.0, 0.9, 0.0), (40.0, 1.2, 0.5)] {
                let race = try Self.prestartWindwardLeeward(seed: seed, leeward: deg2rad(32), windward: deg2rad(windward),
                                                            abeam: abeam, ahead: ahead)
                let sailed = Self.sailOne(race, seat: 1, seconds: 15, planned: .starboard)
                let calls = Self.calls(sailed.kinds)
                let name = "seed \(seed) windward at \(windward)° abeam \(abeam) ahead \(ahead)"
                if !calls.isEmpty { failures.append("\(name): \(calls)") }
                // Bearing away on starboard turns her to port: towards the leeward boat, inside the distance she keeps.
                let close = race.boatClass.hull.length * BotBrain.keepClearDistance
                let bearsAway = sailed.decisions.filter {
                    $0.keepClear == .windwardLeeward && $0.gap < close && $0.decision.input.rudder < 0
                }
                if !bearsAway.isEmpty { failures.append("\(name): bore away keeping clear \(bearsAway.count) times") }
                // Luffing on starboard turns her to starboard, away from the leeward boat: inside her hold angle, the luff
                // #99's clamp took away. Luffed to the floor and still inside the distance she keeps, with the gun more
                // than `startLuffEaseSeconds` off, she eases and drops astern too.
                let keeping = sailed.decisions.filter { $0.keepClear == .windwardLeeward && $0.gap < close }
                if let first = keeping.first, let last = keeping.last {
                    let view = race.seatView(for: 1)
                    let luffs = keeping.contains { $0.twa < BotBrain.holdAngle(view) }
                    if !luffs { failures.append("\(name): never luffed inside her hold keeping clear") }
                    // Within half a degree of the luff floor, 1° outside the no-go zone.
                    let floor = BoatDynamics.noGoAngle(race.boatClass.polar) + deg2rad(1.5)
                    let atFloor = keeping.contains { $0.twa < floor }
                    let dropsAstern = keeping.contains { $0.decision.input.ease } && last.ahead < first.ahead
                    if atFloor && !dropsAstern { failures.append("\(name): at the luff floor, never eased astern") }
                }
                if !sailed.decisions.contains(where: { $0.keepClear == .windwardLeeward }) {
                    failures.append("\(name): never windward")
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    /// Before the gun, seat 0 60° into a penalty turn to starboard below the line, reaching on starboard, hard over (as
    /// `penalised`, before her start); seat 1 reaching back past her on port, `ahead` hull lengths ahead and `across` to
    /// her starboard.
    static func prestartPenalised(seed: UInt64, ahead: Double, across: Double) throws -> Race {
        let water = Water(seed: seed, toGun: 40, below: 6)
        let heading = water.wind - .pi / 2
        let forward = Vec2.heading(heading)
        return try place(water, [
            Placement(position: water.centre, heading: heading, speed: 3, status: .prestart),
            Placement(position: water.centre + forward * water.length * ahead + forward.rightPerp * water.length * across,
                      heading: heading + .pi, speed: 3, status: .prestart),
        ]) { snapshot in
            snapshot.seats[0].boat.autohelm = nil
            snapshot.seats[0].boat.rudder = 1
            snapshot.seats[0].heldInput = BoatInput(rudder: 1.0)
            snapshot.seats[0].boat.penaltyTurnsOwed = 1
            snapshot.seats[0].boat.penaltyProgress = deg2rad(60)
            snapshot.seats[0].boat.penaltyClockTick = snapshot.tick
        }
    }

    /// #280 acceptance: a bot turning a penalty before the gun keeps clear of every boat as she turns it (rule 21.2),
    /// as she does racing (#100), rather than turning on into the boats around her: the turn doesn't collect further
    /// 21.2 calls, and she never owes more than the one. Before, #99 held the turn hard over whoever was near, and one
    /// boat went from one turn owed to four in 2 s.
    @Test func prestartPenaltyDoesNotCascade() throws {
        var failures: [String] = []
        for seed: UInt64 in [3, 5, 7] {
            for (ahead, across) in [(2.0, 0.5), (14.0 / 4.9, 7.0 / 4.9), (3.0, 1.0), (1.5, 1.0)] {
                let race = try Self.prestartPenalised(seed: seed, ahead: ahead, across: across)
                var most = 0
                let kinds = Self.sail(race, seconds: 20) { race in most = max(most, race.boats[0].penaltyTurnsOwed) }
                let calls = Self.calls(kinds).filter { $0 == "21.2 on 0" }
                if !calls.isEmpty || most > 1 {
                    failures.append("seed \(seed) ahead \(ahead) across \(across): \(Self.calls(kinds)), owed at most \(most)")
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    /// Racing on the beat (#351): seat 0 just called, owing a turn she hasn't started, beating on starboard; seat 1
    /// beating beside her on the same tack, `across` hull lengths to her starboard (negative: to port) and `ahead` hull
    /// lengths ahead, inside `BotBrain.penaltyBoatClearance`. On `legIndex` if given (the water's leg by default).
    static func racingPenalised(seed: UInt64, ahead: Double, across: Double, legIndex: Int? = nil) throws -> Race {
        let water = Water(seed: seed)
        let heading = water.beat(.starboard)
        let forward = Vec2.heading(heading)
        let speed = water.up.speed
        return try place(water, [
            Placement(position: water.centre, heading: heading, speed: speed, legIndex: legIndex),
            Placement(position: water.centre + forward * water.length * ahead + forward.rightPerp * water.length * across,
                      heading: heading, speed: speed, legIndex: legIndex),
        ]) { snapshot in
            snapshot.seats[0].boat.penaltyTurnsOwed = 1
            snapshot.seats[0].boat.penaltyProgress = 0
            snapshot.seats[0].boat.penaltyClockTick = snapshot.tick
        }
    }

    /// The pairs `racingPenalised` sails: abeam to either side, and overlapped ahead and astern.
    static let racingPenalisedPairs: [(ahead: Double, across: Double)] = [(0, 1.5), (0, -1.5), (1, 1.2), (-1, -1.2)]

    /// #351 acceptance: racing, a bot that owes a turn with another boat in her water (`BotBrain.penaltyBoatClearance`)
    /// puts it off and sails on rather than turning it at once through her: she isn't 30° into it in the first 2 s, she
    /// isn't called 21.2 (before, a penalised boat turning in the pack collected 21.2 calls from boats that had nothing to
    /// do with her first foul), and she still serves it in time (no missed-penalty disqualification).
    @Test func racingPenaltyInACrowdIsPutOffAndDoesNotCascade() throws {
        var failures: [String] = []
        for seed: UInt64 in [3, 5, 7] {
            for pair in Self.racingPenalisedPairs {
                let race = try Self.racingPenalised(seed: seed, ahead: pair.ahead, across: pair.across)
                let early = race.tick + 2 * Race.tickRate
                var startedEarly = false
                let kinds = Self.sail(race, seconds: 45) { race in
                    if race.tick <= early, abs(race.boats[0].penaltyProgress) >= deg2rad(30) { startedEarly = true }
                }
                let foul = Self.calls(kinds).filter { $0 == "21.2 on 0" }
                let boat = race.boats[0]
                if startedEarly || !foul.isEmpty || boat.status == .dsq || boat.penaltyTurnsOwed > 0 {
                    failures.append("seed \(seed) \(pair): started early \(startedEarly), \(Self.calls(kinds)), "
                                    + "\(boat.status), owes \(boat.penaltyTurnsOwed)")
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    /// #351: on the last leg she can't finish owing a turn, so there she starts it at once, crowd or not.
    @Test func racingPenaltyOnTheLastLegStartsAtOnce() throws {
        for seed: UInt64 in [3, 5] {
            let probe = Water(seed: seed).race.course.legs
            let last = probe.count - 1
            guard case .finish = probe[last] else { Issue.record("seed \(seed): last leg isn't the finish"); continue }
            let race = try Self.racingPenalised(seed: seed, ahead: 0, across: 1.5, legIndex: last)
            let early = race.tick + 2 * Race.tickRate
            var started = false
            _ = Self.sail(race, seconds: 2.5) { race in
                if race.tick <= early, abs(race.boats[0].penaltyProgress) >= deg2rad(30) { started = true }
            }
            #expect(started, "seed \(seed): not 30° into her turn 2 s after it was hers")
        }
    }

    /// Before the gun, `toGun` seconds before it below the line: seat 0 beating on starboard, seat 1 reaching across on
    /// port (60° off the wind, where she positions before the gun) into her, both meeting in `meet` seconds.
    static func prestartPortStarboard(seed: UInt64, toGun: Int = 50, meet: Double = 4) throws -> Race {
        let water = Water(seed: seed, toGun: toGun, below: 8)
        let starboard = water.beat(.starboard), port = water.heading(.port, deg2rad(60))
        let speed = water.up.speed * 0.8
        // Reaching, she sails faster.
        let reaching = water.race.boatClass.polar.speed(twa: deg2rad(60), tws: water.race.groundWind(at: water.centre).speed)
        return try place(water, [
            Placement(position: water.centre - Vec2.heading(starboard) * speed * meet, heading: starboard, speed: speed,
                      status: .prestart),
            Placement(position: water.centre - Vec2.heading(port) * reaching * meet, heading: port, speed: reaching,
                      status: .prestart),
        ])
    }

    /// #280, ruling 2 (#103's model before the start): a port boat that misjudges her encounter before the gun believes
    /// she holds her rights and sails on into the starboard boat, and is called under rule 10; judging it right, she
    /// keeps clear and nobody is called. Never a turn towards: misjudging only leaves her keep-clear out.
    @Test func prestartMisjudgingPortBoatSailsOnAndIsCalled() throws {
        // Seeds 1 and 11 (#437): hand steering (skiff@7) puts the port boat 0.3 m wide of the starboard one on seed 3, a miss.
        for seed: UInt64 in [1, 11] {
            let judged = Self.sailOne(try Self.prestartPortStarboard(seed: seed), seat: 1, seconds: 12,
                                      weaknesses: Self.misjudging(0), planned: .port)
            #expect(Self.calls(judged.kinds).isEmpty, "seed \(seed): \(Self.calls(judged.kinds))")
            let misjudged = Self.sailOne(try Self.prestartPortStarboard(seed: seed), seat: 1, seconds: 12,
                                         weaknesses: Self.misjudging(1), planned: .port)
            #expect(Self.calls(misjudged.kinds).first == "10 on 1", "seed \(seed): \(Self.calls(misjudged.kinds))")
        }
    }

    /// #280, ruling 2: before her start she judges an encounter once, as racing, and only if she can misjudge at all: a
    /// bot from National's band up (skill 0.8 and over) draws nothing, and so misjudges nothing before the gun either.
    @Test func prestartEncountersAreJudgedOnceAndOnlyWhenMisjudgingIsPossible() throws {
        let race = try Self.prestartPortStarboard(seed: 11)
        for _ in 0..<(2 * Race.tickRate) { race.step() }
        let port = race.seatView(for: 1)
        #expect(port.own.status == .prestart)
        #expect(port.others[0].rightOfWay?.keepClear == 1)
        var brain = BotBrain(style: Self.skill1, seed: 7, weaknesses: Self.misjudging(1))
        brain.plannedTack = .port
        _ = brain.decide(port)
        #expect(brain.misjudged == [0: true])
        let drawn = brain.rng
        _ = brain.decide(port)
        var once = brain.rng, then = drawn
        #expect(once.next() == then.next(), "judged once an encounter")
        var never = BotBrain(style: Self.skill1, seed: 7, weaknesses: Self.misjudging(0))
        never.plannedTack = .port
        var untouched = never.rng
        _ = never.decide(port)
        #expect(never.misjudged.isEmpty)
        #expect(never.rng.next() == untouched.next(), "no draw")
        for skill in [0.8, 0.9, 1.0] {
            var style = Self.skill1
            style.skill = skill
            var national = BotBrain(style: style, seed: 7)
            national.plannedTack = .port
            #expect(national.weaknesses.ruleMisjudgeRate == 0)
            _ = national.decide(port)
            #expect(national.misjudged.isEmpty, "skill \(skill)")
        }
    }

    /// #350: the cautious bot looks before she taps sailing the tap through in her mind (`BotBrain.tapTrack`), every
    /// boat going on turning as she saw it turn (`tapApproach`). Slow on a reach, the tack takes her seconds, sailing on
    /// where she was going; a port boat ahead bearing away out of its own tack crosses her bow there, clear of her by
    /// the straight-line reckoning every bot makes (seed 69 of `CautiousBotSuiteTests`). Seen sailing straight, it's
    /// clear by both.
    @Test func cautiousTapCheckCatchesABoatBearingAwayAcrossHerSlowTack() throws {
        let water = Water(seed: 1)
        let heading = water.heading(.starboard, deg2rad(63))
        let forward = Vec2.heading(heading)
        let port = water.beat(.port)
        let race = try Self.place(water, [
            Placement(position: water.centre, heading: heading, speed: 1.5),
            Placement(position: water.centre + forward * 16 + forward.rightPerp * 4, heading: port, speed: water.up.speed),
        ])
        let view = race.seatView(for: 0)
        let b = view.own
        let other = try #require(view.others.first)
        var brain = BotBrain(style: Self.skill1, caution: .standard)
        let clear = view.boatClass.hull.length * brain.tapClearanceLengths
        let gap = (other.position - b.position).length
        let straight = BotBrain.closestApproach(of: other, to: b, heading: 2 * b.windDirection - b.heading,
                                                speed: b.speed * BotBrain.tapSpeedShare,
                                                lookahead: BotBrain.tapLookahead * brain.tapLookaheadScale)
        #expect(gap <= BotBrain.tapRange)
        #expect(straight >= min(clear, gap), "clear by the straight-line reckoning")
        brain.seen = [nil, BotBrain.Seen(time: view.time - 0.1, heading: other.heading, speed: other.speed)]
        #expect(brain.tapIsClear(b, view), "sailing straight, clear")
        brain.seen = [nil, BotBrain.Seen(time: view.time - 0.1, heading: other.heading - BotBrain.guardTurnRate * 0.1,
                                         speed: other.speed)]
        #expect(!brain.tapIsClear(b, view), "bearing away across her tack")
    }
}
