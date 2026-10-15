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
    /// The rules the scripted encounters' water races under (`Water`): the default (fleet-rules@7 since #517), or the
    /// version a test pins (`.onSixRules`, #488; `.onFiveRules`, the full circle).
    @TaskLocal static var waterRules: FileRef = RaceFiles.defaults.rulesConfiguration.ref

    struct Water {
        let race: Race
        let wind: Double
        let up: PolarTable.Optimum
        let down: PolarTable.Optimum
        let centre: Vec2
        let length: Double
        /// The leg boats sail there: to the windward mark, or running, to the gate.
        let leg: Int

        init(seed: UInt64, running: Bool = false, seats: Int = 2) {
            race = botRace(seats: Array(repeating: .bot, count: seats), seed: seed, boatClass: BotConductTests.waterClass)
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
             caution: BotBrain.Caution? = nil, profile: BotProfile? = nil, penaltyDirection: Double = 1) {
            self.seat = seat
            var style = BotConductTests.skill1
            style.skill = skill
            style.penaltyDirection = penaltyDirection
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
    // skiff@7 until #455: on skiff@8 the windward boat never luffs inside her hold (seeds 3 and 7).
    @Test(.onSkiffSeven) func windwardLuffHoldingNearCloseHauledLuffs() throws {
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
    // skiff@7 until #455: on skiff@8 seeds 5 and 7 draw a rule 15 call on the penalised boat (tried again after #471's
    // step C: the same two, a second turn owed).
    @Test(.onFiveRules, .onSkiffSeven) func prestartPenaltyDoesNotCascade() throws {
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
    /// lengths ahead, inside `BotBrain.penaltyBoatClearance` (by hand, in the water of both circles she could turn,
    /// `BotBrain.PenaltySweeps.isCrowded`, #486). On `legIndex` if given (the water's leg by default).
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

    /// #351 acceptance: racing, a bot that owes a turn with another boat in her water (`BotBrain.penaltyBoatClearance`;
    /// by hand, both her turn's sweeps cross it, #486) puts it off and sails on rather than turning it at once through
    /// her: she isn't 30° into it in the first 2 s, she isn't called 21.2 (before, a penalised boat turning in the pack
    /// collected 21.2 calls from boats that had nothing to do with her first foul), and she still serves it in time (no
    /// missed-penalty disqualification).
    // skiff@7 until #455: on skiff@8 seed 3 draws a rule 21.2 call on the turning boat (tried again after #471's step C:
    // the same, the boat abeam to leeward).
    @Test(.onFiveRules, .onSkiffSeven) func racingPenaltyInACrowdIsPutOffAndDoesNotCascade() throws {
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

    /// Before the gun on the default class (#471): seat 0 beating on starboard `below` hull lengths under the middle of
    /// the line, `toGun` seconds before the gun, just called and owing a turn she hasn't started; seat 1 on the same
    /// course `across` hull lengths to her starboard (to windward of her).
    static func prestartCalled(seed: UInt64, toGun: Int, below: Double, across: Double) throws -> Race {
        let water = Water(seed: seed, toGun: toGun, below: below)
        let heading = water.beat(.starboard)
        let speed = water.up.speed * 0.8
        return try place(water, [
            Placement(position: water.centre, heading: heading, speed: speed, status: .prestart),
            Placement(position: water.centre + Vec2.heading(heading).rightPerp * water.length * across, heading: heading,
                      speed: speed, status: .prestart),
        ]) { snapshot in
            snapshot.seats[0].boat.penaltyTurnsOwed = 1
            snapshot.seats[0].boat.penaltyProgress = 0
            snapshot.seats[0].boat.penaltyClockTick = snapshot.tick
        }
    }

    /// What `penalisedBeforeTheGun` saw of seat 0: the race clock when she was first 30° into a turn (her own sailing
    /// counts towards it), when she was 30° into the turn she then served, and when she started; the turns she owed as
    /// she started, and the race's events.
    struct Served {
        var firstThirtyIn: Double?
        var thirtyIn: Double?
        var started: Double?
        var owedStarting = 0
        var kinds: [RaceEvent.Kind] = []

        var resets: Int { kinds.filter { $0 == .penaltyReset(seat: 0) }.count }
        var isServed: Bool { kinds.contains(.penaltyServed(seat: 0)) }
        var isDisqualified: Bool { kinds.contains { if case .disqualified(seat: 0, _) = $0 { true } else { false } } }
    }

    static func penalisedBeforeTheGun(_ race: Race, seconds: Double, skill: Double = 1) -> Served {
        var served = Served()
        var wasIn = false
        served.kinds = sail(race, seconds: seconds, skill: skill) { race in
            let boat = race.boats[0]
            let isIn = abs(boat.penaltyProgress) >= deg2rad(30)
            if isIn, served.firstThirtyIn == nil { served.firstThirtyIn = race.time }
            if isIn, !wasIn { served.thirtyIn = race.time }
            wasIn = isIn
            if served.started == nil, boat.status == .racing {
                served.started = race.time
                served.owedStarting = boat.penaltyTurnsOwed
            }
        }
        return served
    }

    /// #471, "start first, then turn" (the owner's ruling of 2026-10-10), on the default class: called 8 s before the
    /// gun a few lengths under the line, her turn's start deadline is 12 s after it. She sails her start, crosses
    /// still owing the turn, is 30° into the turn she serves only after she has started and inside its deadline (the
    /// scene's two-boat line is short, so its end marks hold her off to the start margin, #461), and serves it. Called
    /// 30 s before the gun the deadline falls before it: she turns where she is.
    @Test(.onFiveRules) func aLateCallIsServedAfterTheStart() throws {
        for seed: UInt64 in [3, 5, 7] {
            let late = Self.penalisedBeforeTheGun(try Self.prestartCalled(seed: seed, toGun: 8, below: 4, across: 12), seconds: 50)
            let started = try #require(late.started, "seed \(seed): she never started")
            let thirtyIn = try #require(late.thirtyIn, "seed \(seed): she never turned")
            #expect(started < 6, "seed \(seed): started \(started) s after the gun")
            #expect(late.owedStarting == 1, "seed \(seed): she had served her turn before she started")
            #expect(thirtyIn > started && thirtyIn <= 12, "seed \(seed): 30° in at \(thirtyIn) s, started at \(started) s")
            #expect(late.isServed && !late.isDisqualified, "seed \(seed): \(late.kinds.filter { $0 != .penaltyStarted(seat: 0) }.suffix(3))")

            let early = Self.penalisedBeforeTheGun(try Self.prestartCalled(seed: seed, toGun: 30, below: 4, across: 12), seconds: 50)
            let turned = try #require(early.firstThirtyIn, "seed \(seed): she never turned")
            #expect(turned < -10, "seed \(seed): called 30 s before the gun, 30° in at \(turned) s")
            #expect(early.isServed && !early.isDisqualified)
        }
    }

    /// #471: before her start on the default class she doesn't put her turn off for a boat in her water (by hand that
    /// wait sailed her into the turn's 30° and out again, a started turn given up 1.5 times an episode): with a boat
    /// a length and a half to windward 40 s before the gun she bears away for room, is 30° in inside 9 s, never gives
    /// the turn up, and serves it inside its deadline.
    @Test(.onFiveRules) func beforeHerStartShePutsNoTurnOffInTheCrowd() throws {
        for seed: UInt64 in [3, 5, 7] {
            let seen = Self.penalisedBeforeTheGun(try Self.prestartCalled(seed: seed, toGun: 40, below: 6, across: 1.5), seconds: 40)
            let thirtyIn = try #require(seen.firstThirtyIn, "seed \(seed): she never turned")
            #expect(thirtyIn < -31, "seed \(seed): 30° in at \(thirtyIn) s")
            #expect(seen.resets == 0, "seed \(seed): she gave a started turn up \(seen.resets) times")
            #expect(seen.isServed && !seen.isDisqualified, "seed \(seed)")
        }
    }

    /// #471, "bear away, then turn" (the owner's ruling of 2026-10-10), on the default class, for a Club bot racing
    /// (she doesn't put the turn off for the pack): with a boat abeam to windward inside three lengths she bears away
    /// first, under the rules' 30° for the first 2 s and 10° or more off her course by then, and turns after it; alone
    /// she is 30° into her turn inside 2.5 s.
    @Test(.onFiveRules) func bearsAwayForRoomBeforeHerTurn() throws {
        for seed: UInt64 in [3, 5] {
            func sailed(across: Double) throws -> (twoSeconds: Double, thirtyIn: Double?, served: Bool) {
                let race = try Self.racingPenalised(seed: seed, ahead: 0, across: across)
                let heading = race.boats[0].heading, from = race.time
                var twoSeconds = 0.0, thirtyIn: Double?
                let kinds = Self.sail(race, seconds: 45, skill: 0.5) { race in
                    if race.time - from <= 2 { twoSeconds = wrapAngle(race.boats[0].heading - heading) }
                    if thirtyIn == nil, abs(race.boats[0].penaltyProgress) >= deg2rad(30) { thirtyIn = race.time - from }
                }
                return (twoSeconds, thirtyIn, kinds.contains(.penaltyServed(seat: 0)))
            }
            let beside = try sailed(across: 1.5)
            // On starboard she bears away to port: her heading falls.
            #expect(beside.twoSeconds < -deg2rad(10) && beside.twoSeconds > -deg2rad(30), "seed \(seed): \(rad2deg(beside.twoSeconds))°")
            #expect((beside.thirtyIn ?? 0) > 2 && beside.served, "seed \(seed): \(String(describing: beside.thirtyIn))")
            let alone = try sailed(across: 12)
            #expect((alone.thirtyIn ?? 9) < 2.5 && alone.served, "seed \(seed): \(String(describing: alone.thirtyIn))")
        }
    }

    /// #351: on the last leg she can't finish owing a turn, so there she starts it at once, crowd or not.
    @Test(.onFiveRules) func racingPenaltyOnTheLastLegStartsAtOnce() throws {
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

    /// Racing on the beat (#486): seat 0 just called, owing a turn she hasn't started, beating on starboard at
    /// close-hauled speed; every other seat (as many as `others`) on the reciprocal of her course at that speed,
    /// running back down past her, `ahead` hull lengths ahead of her and `across` to her starboard (negative: to port).
    static func sweepScene(seed: UInt64, _ others: [(ahead: Double, across: Double)]) throws -> Race {
        let water = Water(seed: seed, seats: others.count + 1)
        let heading = water.beat(.starboard)
        let forward = Vec2.heading(heading)
        let speed = water.up.speed
        return try place(water, [Placement(position: water.centre, heading: heading, speed: speed)] + others.map {
            Placement(position: water.centre + forward * water.length * $0.ahead + forward.rightPerp * water.length * $0.across,
                      heading: heading + .pi, speed: speed)
        }) { snapshot in
            snapshot.seats[0].boat.penaltyTurnsOwed = 1
            snapshot.seats[0].boat.penaltyProgress = 0
            snapshot.seats[0].boat.penaltyClockTick = snapshot.tick
        }
    }

    /// What `sailSweepScene` saw of seat 0: the way her turn went (the sign of her progress once 30° in) and the
    /// seconds from the call it took; the seconds from the call at which she chose her turn's way, and the clear
    /// sweeps (−1 port, 1 starboard) she had as she chose it; how far seat 1 was past her once she was 30° in; and the
    /// race's events.
    struct Swept {
        var way: Double?
        var thirtyIn: Double?
        var chosen: Double?
        var clearChoosing: [Double] = []
        /// Metres seat 1 had sailed on past her, along its own heading, when she was 30° in (negative: still to come).
        var passedThirtyIn: Double?
        var kinds: [RaceEvent.Kind] = []
    }

    /// Sails `race` for `seconds` with only seat 0's bot at the helm (the others hold what their autohelms hold), at
    /// `skill` with its weaknesses, turning penalties `penaltyDirection`'s way in open water.
    static func sailSweepScene(_ race: Race, seconds: Double, skill: Double = 1, penaltyDirection: Double) -> Swept {
        var pilot = Pilot(seat: 0, plannedTack: nil, race: race, skill: skill, weaknesses: BotWeaknesses(skill: skill),
                          penaltyDirection: penaltyDirection)
        let from = race.time
        var swept = Swept()
        for _ in 0..<Int(seconds * Double(Race.tickRate)) where !race.isOver {
            let view = race.seatView(for: 0)
            let clear = [-1.0, 1.0].filter { pilot.brain.turnSweep(view.own, view, direction: $0) == nil }
            let wasChosen = pilot.brain.penaltyTurn != nil
            _ = pilot.drive(race)
            if !wasChosen, pilot.brain.penaltyTurn != nil, swept.chosen == nil {
                swept.chosen = race.time - from
                swept.clearChoosing = clear
            }
            race.step()
            swept.kinds += race.drainEvents().map(\.kind)
            let boat = race.boats[0]
            if swept.way == nil, abs(boat.penaltyProgress) >= deg2rad(30) {
                swept.way = boat.penaltyProgress > 0 ? 1 : -1
                swept.thirtyIn = race.time - from
                swept.passedThirtyIn = (race.boats[1].position - boat.position).dot(Vec2.heading(race.boats[1].heading))
            }
        }
        return swept
    }

    /// The ways (−1 port, 1 starboard) whose sweep is clear for seat 0 of `race` as it stands, for a bot at `skill`.
    static func clearSweeps(_ race: Race, skill: Double = 1) -> [Double] {
        let pilot = Pilot(seat: 0, plannedTack: nil, race: race, skill: skill, weaknesses: BotWeaknesses(skill: skill))
        let view = race.seatView(for: 0)
        return [-1.0, 1.0].filter { pilot.brain.turnSweep(view.own, view, direction: $0) == nil }
    }

    /// #486 acceptance: a boat coming down on one side of her, through the circle she would turn that way, and open
    /// water on the other: she turns towards the open side, though her own way (`BotStyle.penaltyDirection`) is
    /// towards the boat, and the nearest boat (a boat close astern on the open side, sailing away) would turn her
    /// towards it too. Before #486 she turned her own way into the boat: neither boat was within 2.5 hull lengths of her.
    @Test(.onFiveRules) func penaltyTurnStartsTheWayItsSweepIsClear() throws {
        for side in [1.0, -1.0] {
            let others: [(ahead: Double, across: Double)] = [(6, 2.1 * side), (-3.5, -1.0 * side)]
            // A seed whose scene crosses only the circle on the boat's side.
            let seed = try firstSeed(in: 1...20) { Self.clearSweeps(try Self.sweepScene(seed: $0, others)) == [-side] }
            let race = try Self.sweepScene(seed: seed, others)
            let near = race.boats[2].position - race.boats[0].position
            #expect(near.length < (race.boats[1].position - race.boats[0].position).length, "the open side's boat is nearest")
            let swept = Self.sailSweepScene(race, seconds: 8, penaltyDirection: side)
            #expect(swept.way == -side, "seed \(seed) side \(side): turned \(String(describing: swept.way))")
        }
    }

    /// #486 acceptance: boats coming down through both her circles, the nearer, on her starboard side, soon past her:
    /// she sails on, putting her turn off, while both sweeps cross a boat, and starts once one is clear, that way (her
    /// own way is the other), inside the start deadline's `penaltyStartMargin`.
    @Test(.onFiveRules) func penaltyTurnIsPutOffWhileBothSweepsCross() throws {
        let others: [(ahead: Double, across: Double)] = [(3, 2.0), (8, -2.0)]
        let start = fiveRulesPenalty.start
        let seed = try firstSeed(in: 1...20) { Self.clearSweeps(try Self.sweepScene(seed: $0, others)).isEmpty }
        let swept = Self.sailSweepScene(try Self.sweepScene(seed: seed, others), seconds: 20, penaltyDirection: -1)
        let chosen = try #require(swept.chosen, "seed \(seed): she never chose a way")
        #expect(chosen > 0, "seed \(seed): she started at once")
        #expect(swept.clearChoosing == [1], "seed \(seed): clear \(swept.clearChoosing) as she chose at \(chosen) s")
        #expect(swept.way == 1, "seed \(seed): turned \(String(describing: swept.way))")
        let thirtyIn = try #require(swept.thirtyIn, "seed \(seed): never 30° in")
        #expect(thirtyIn < start - BotBrain.penaltyStartMargin, "seed \(seed): 30° in at \(thirtyIn) s")
    }

    /// #486 acceptance: a Club bot (the centre of the band) owing a turn, with a boat running back down past her close
    /// to windward, through both circles she could turn: she waits for it to pass (it is astern of her when she is 30°
    /// in), is called for nothing, touches nothing, and serves the turn. Before #486 a Club bot read no pack and turned
    /// at once, her own way: into it.
    @Test(.onFiveRules) func clubBotWaitsForAPassingBoat() throws {
        let club = BotTier.club.skill(at: 0.5)
        let others: [(ahead: Double, across: Double)] = [(3, 0.6)]
        let complete = fiveRulesPenalty.complete
        // A seed whose boat crosses both circles, and whose turn by hand leaves her time to wait for it to pass.
        let seed = try firstSeed(in: 1...20) { seed in
            let race = try Self.sweepScene(seed: seed, others)
            let view = race.seatView(for: 0)
            let pilot = Pilot(seat: 0, plannedTack: nil, race: race, skill: club, weaknesses: BotWeaknesses(skill: club))
            return Self.clearSweeps(race, skill: club).isEmpty
                && pilot.brain.penaltyTurnSeconds(view.own, view) + HandTackTable.penaltyTurn.margin + 6 < complete
        }
        let swept = Self.sailSweepScene(try Self.sweepScene(seed: seed, others), seconds: 45, skill: club, penaltyDirection: 1)
        let calls = Self.calls(swept.kinds)
        #expect(!calls.contains("21.2 on 0"), "seed \(seed): \(calls)")
        #expect(!swept.kinds.contains { if case .contact = $0 { true } else { false } }, "seed \(seed): contact")
        let passed = try #require(swept.passedThirtyIn, "seed \(seed): never 30° in")
        #expect(passed > 0, "seed \(seed): the boat was \(-passed) m short of passing her as she was 30° in")
        #expect(swept.kinds.contains(.penaltyServed(seat: 0)), "seed \(seed): not served")
    }

    // MARK: - fleet-rules@6 (#488)

    /// Racing on the beat under fleet-rules@6 (#487, `.onSixRules`): seat 0 has just tacked as the first crossing of a
    /// penalty turn, luffing up from starboard, and is beating on port at `speed` of her close-hauled speed, bearing
    /// away now towards the turn's gybe, owing the one turn, called 5 s ago. Every other seat (as many as `others`) at
    /// close-hauled speed, `ahead` hull lengths ahead of her and `across` towards the side her turn goes (negative: the
    /// other), on her heading (`running` false) or its reciprocal. Returns the race and the turn's way (+1 starboard).
    /// `calledAgo` moves the call (and the turn's clock) further back.
    static func midTurnScene(seed: UInt64, speed: Double = 0.6, calledAgo: Double = 5,
                             _ others: [(ahead: Double, across: Double, running: Bool)]) throws -> (race: Race, way: Double) {
        let water = Water(seed: seed, seats: others.count + 1)
        let heading = water.beat(.port)
        // Bearing away from port close-hauled: away from the wind over her port side.
        let way: Double = wrapAngle(water.wind - heading) > 0 ? -1 : 1
        let forward = Vec2.heading(heading)
        let race = try place(water, [Placement(position: water.centre, heading: heading, speed: water.up.speed * speed)] + others.map {
            Placement(position: water.centre + forward * water.length * $0.ahead + forward.rightPerp * water.length * $0.across * way,
                      heading: $0.running ? heading + .pi : heading, speed: water.up.speed)
        }) { snapshot in
            for seat in snapshot.seats.indices {
                snapshot.seats[seat].boat.penaltyTurnsOwed = 0
                snapshot.seats[seat].boat.penaltyClockTick = nil
                snapshot.seats[seat].boat.penaltyDirection = 0
                snapshot.seats[seat].boat.penaltyFirstCrossing = nil
                snapshot.seats[seat].boat.penaltyDirectionLocked = false
                snapshot.seats[seat].boat.penaltyCrossingHeld = false
            }
            snapshot.seats[0].boat.penaltyTurnsOwed = 1
            snapshot.seats[0].boat.penaltyProgress = 0
            snapshot.seats[0].boat.penaltyClockTick = snapshot.tick - Int((calledAgo * Double(RulesConfig.ticks(1))).rounded())
            snapshot.seats[0].boat.penaltyFirstCrossing = .tack
            snapshot.seats[0].boat.penaltyDirection = Int(way)
        }
        #expect(race.rules.raceFormat.penalty.turn == .tackAndGybe)
        return (race, way)
    }

    /// The first conflict on what is left of seat 0's turn each way (−1 port, 1 starboard) as `race` stands, for a bot at
    /// `skill` (`BotBrain.turnSweep` over `penaltyTurnLeft`): nil for a way whose sweep is clear.
    static func sweepsLeft(_ race: Race, skill: Double = 1) throws -> [Double: Double?] {
        let pilot = Pilot(seat: 0, plannedTack: nil, race: race, skill: skill, weaknesses: BotWeaknesses(skill: skill))
        let view = race.seatView(for: 0)
        let owed = try #require(view.own.penalty)
        var sweeps: [Double: Double?] = [:]
        for way in [-1.0, 1.0] {
            let angle = pilot.brain.penaltyTurnLeft(view.own, owed, view, direction: way)
            sweeps[way] = .some(pilot.brain.turnSweep(view.own, view, direction: way, angle: angle)?.seconds)
        }
        return sweeps
    }

    /// What `sailCrossings` saw of seat 0 under fleet-rules@6: the most turns she owed, the ways her turn went (each
    /// change of `Boat.penaltyDirection`), her first crossing, whether she ever held her rudder against the turn's way
    /// `way` after the scene began, the heading turned her turn's way from the start to when the turn was served, and
    /// the race's events.
    struct Crossed {
        var mostOwed = 0
        var ways: [Int] = []
        var firstCrossing: PenaltyCrossing?
        var steeredAgainst = false
        /// Whether she held her rudder against the turn's way before it was served (#528).
        var steeredAgainstTurning = false
        var turned = 0.0
        var servedAt: Double?
        var kinds: [RaceEvent.Kind] = []
        var contact: Bool { kinds.contains { if case .contact = $0 { true } else { false } } }
        var resets: Int { kinds.filter { if case .penaltyReset(seat: 0) = $0 { true } else { false } }.count }
    }

    /// Sails `race` for `seconds` with only seat 0's bot at the helm (the others hold what their autohelms hold), at
    /// `skill`, her own penalty way `penaltyDirection`, watching her turn `way`'s way.
    static func sailCrossings(_ race: Race, seconds: Double, way: Double, skill: Double = 1,
                              penaltyDirection: Double = 1) -> Crossed {
        var pilot = Pilot(seat: 0, plannedTack: nil, race: race, skill: skill, weaknesses: BotWeaknesses(skill: skill),
                          penaltyDirection: penaltyDirection)
        let from = race.time
        var crossed = Crossed()
        var lastWay = race.boats[0].penaltyDirection
        for _ in 0..<Int(seconds * Double(Race.tickRate)) where !race.isOver {
            if let decision = pilot.drive(race), decision.input.rudderValue * way < -0.05 {
                crossed.steeredAgainst = true
                if crossed.servedAt == nil { crossed.steeredAgainstTurning = true }
            }
            let heading = race.boats[0].heading
            race.step()
            let boat = race.boats[0]
            if crossed.servedAt == nil { crossed.turned += wrapAngle(boat.heading - heading) * way }
            let kinds = race.drainEvents().map(\.kind)
            crossed.kinds += kinds
            if crossed.servedAt == nil, kinds.contains(.penaltyServed(seat: 0)) { crossed.servedAt = race.time - from }
            crossed.mostOwed = max(crossed.mostOwed, boat.penaltyTurnsOwed)
            if crossed.firstCrossing == nil { crossed.firstCrossing = boat.penaltyFirstCrossing }
            if boat.penaltyDirection != lastWay, boat.penaltyDirection != 0 { crossed.ways.append(boat.penaltyDirection) }
            lastWay = boat.penaltyDirection
        }
        return crossed
    }

    /// #488 acceptance (fleet-rules@6): mid-turn, tacked and bearing away to her gybe, a boat runs down at her on the
    /// side her turn goes, through what is left of her turn either way: she steers off it (her rudder against the turn,
    /// free to turn back now that turning back costs nothing), then turns on the same way once her sweep is clear, and
    /// serves the turn: no recross, no new call, no contact. Before #488 she held the turn on or gave it up the other
    /// way at once.
    @Test(.onSixRules) func turningBotDodgesAndCarriesOn() throws {
        let others: [(ahead: Double, across: Double, running: Bool)] = [(6, 0.5, true)]
        let lookahead = BotWeaknesses(skill: 1).keepClearLookahead
        // A seed whose boat crosses what is left of her turn both ways, the turn's own way inside her lookahead soon.
        let seed = try firstSeed(in: 1...20) { seed in
            let (race, way) = try Self.midTurnScene(seed: seed, others)
            let sweeps = try Self.sweepsLeft(race)
            guard let own = sweeps[way] ?? nil, (sweeps[-way] ?? nil) != nil else { return false }
            return own < 2 * lookahead
        }
        let (race, way) = try Self.midTurnScene(seed: seed, others)
        let crossed = Self.sailCrossings(race, seconds: 40, way: way)
        let calls = Self.calls(crossed.kinds)
        #expect(crossed.steeredAgainst, "seed \(seed): she never steered off her turn")
        #expect(crossed.servedAt != nil, "seed \(seed): not served")
        #expect(crossed.resets == 0 && crossed.ways.isEmpty, "seed \(seed): she recrossed (\(crossed.ways))")
        #expect(crossed.mostOwed == 1 && !calls.contains { $0.hasSuffix("on 0") }, "seed \(seed): \(calls)")
        #expect(!crossed.contact, "seed \(seed): contact")
    }

    /// #488 acceptance (fleet-rules@6): mid-turn, tacked and bearing away to her gybe, a boat close abeam on the side her
    /// turn goes, through what is left of it, and the other way clear: she turns back through the wind, which only
    /// changes her turn's way (its first crossing, the other way), and serves the turn that way: no new call, no contact.
    @Test(.onSixRules) func turningBotRecrossesWhenTheOtherWayIsClear() throws {
        let others: [(ahead: Double, across: Double, running: Bool)] = [(0, 2.0, false)]
        let lookahead = BotWeaknesses(skill: 1).keepClearLookahead
        let seed = try firstSeed(in: 1...20) { seed in
            let (race, way) = try Self.midTurnScene(seed: seed, others)
            let sweeps = try Self.sweepsLeft(race)
            guard let own = sweeps[way] ?? nil else { return false }
            return own < lookahead && (sweeps[-way] ?? nil) == nil
        }
        let (race, way) = try Self.midTurnScene(seed: seed, others)
        let crossed = Self.sailCrossings(race, seconds: 40, way: way)
        let calls = Self.calls(crossed.kinds)
        #expect(crossed.ways.first == Int(-way), "seed \(seed): her turn's ways \(crossed.ways)")
        #expect(crossed.servedAt != nil && race.boats[0].penaltyTurnsOwed == 0, "seed \(seed): not served")
        #expect(crossed.mostOwed == 1 && !calls.contains { $0.hasSuffix("on 0") }, "seed \(seed): \(calls)")
        #expect(!crossed.contact, "seed \(seed): contact")
    }

    // MARK: - Past her latest start (#528)

    /// Seconds to seat 0's latest start (`BotBrain.latestStartSeconds`) in `race` as it stands.
    static func latestStart(_ race: Race) throws -> Double {
        let pilot = Pilot(seat: 0, plannedTack: nil, race: race, skill: 1, weaknesses: BotWeaknesses(skill: 1))
        let view = race.seatView(for: 0)
        return pilot.brain.latestStartSeconds(try #require(view.own.penalty), view.own, view)
    }

    /// Racing on the beat (#528): seat 0 close-hauled on starboard at close-hauled speed, owing a later turn she hasn't
    /// started, its way locked (RRS 44.2) luffing, the side `others` lie (`across` towards it), called long enough ago
    /// that her latest start (`latestStartSeconds`) is `latest` seconds off; every other seat at close-hauled speed
    /// `ahead` hull lengths ahead of her, on her heading (`running` false) or its reciprocal. Returns the race and the way.
    static func lateStartScene(seed: UInt64, latest: Double, locked: Bool = true,
                               _ others: [(ahead: Double, across: Double, running: Bool)]) throws -> (race: Race, way: Double) {
        func scene(calledAgo: Double) throws -> (race: Race, way: Double) {
            let water = Water(seed: seed, seats: others.count + 1)
            let heading = water.beat(.starboard)
            // Luffing from starboard close-hauled: towards the wind over her starboard side.
            let way: Double = wrapAngle(water.wind - heading) > 0 ? 1 : -1
            let forward = Vec2.heading(heading)
            let race = try place(water, [Placement(position: water.centre, heading: heading, speed: water.up.speed)] + others.map {
                Placement(position: water.centre + forward * water.length * $0.ahead + forward.rightPerp * water.length * $0.across * way,
                          heading: $0.running ? heading + .pi : heading, speed: water.up.speed)
            }) { snapshot in
                for seat in snapshot.seats.indices {
                    snapshot.seats[seat].boat.penaltyTurnsOwed = 0
                    snapshot.seats[seat].boat.penaltyClockTick = nil
                    snapshot.seats[seat].boat.penaltyDirection = 0
                    snapshot.seats[seat].boat.penaltyFirstCrossing = nil
                    snapshot.seats[seat].boat.penaltyDirectionLocked = false
                    snapshot.seats[seat].boat.penaltyCrossingHeld = false
                }
                snapshot.seats[0].boat.penaltyTurnsOwed = 1
                snapshot.seats[0].boat.penaltyProgress = 0
                snapshot.seats[0].boat.penaltyClockTick = snapshot.tick - Int((calledAgo * Double(RulesConfig.ticks(1))).rounded())
                if locked {
                    snapshot.seats[0].boat.penaltyDirection = Int(way)
                    snapshot.seats[0].boat.penaltyDirectionLocked = true
                }
            }
            return (race, way)
        }
        let now = try latestStart(try scene(calledAgo: 0).race)
        return try scene(calledAgo: now - latest)
    }

    /// #528 acceptance: a boat owing a turn just past its latest start, its way locked to the side a boat running
    /// down at her lies, inside her sweep and about to hit her: she doesn't start the circle (her rudder doesn't go over
    /// her turn's way) while it comes, then turns, serves the turn, and touches nothing. Before #528 she turned at once,
    /// through it: past her latest start she turned on whoever was near.
    @Test func penaltyTurnPastItsLatestStartWaitsForTheBoatInItsSweep() throws {
        let others: [(ahead: Double, across: Double, running: Bool)] = [(3, 1.0, true)]
        let lookahead = BotWeaknesses(skill: 1).keepClearLookahead
        // A seed whose boat crosses her turn's sweep inside her lookahead.
        let seed = try firstSeed(in: 1...20) { seed in
            let (race, way) = try Self.lateStartScene(seed: seed, latest: -0.2, others)
            let pilot = Pilot(seat: 0, plannedTack: nil, race: race, skill: 1, weaknesses: BotWeaknesses(skill: 1))
            let view = race.seatView(for: 0)
            return (pilot.brain.turnSweep(view.own, view, direction: way)?.seconds ?? .infinity) < lookahead
        }
        let (race, way) = try Self.lateStartScene(seed: seed, latest: -0.2, others)
        var pilot = Pilot(seat: 0, plannedTack: nil, race: race, skill: 1, weaknesses: BotWeaknesses(skill: 1))
        let input = try #require(pilot.drive(race)?.input)
        #expect(input.rudderValue * way <= 0, "seed \(seed): she put her rudder over her turn's way at once")
        let crossed = Self.sailCrossings(race, seconds: 40, way: way)
        #expect(crossed.servedAt != nil, "seed \(seed): not served")
        #expect(!crossed.contact, "seed \(seed): contact")
        #expect(!crossed.kinds.contains { if case .disqualified(seat: 0, _) = $0 { true } else { false } },
                "seed \(seed): disqualified")
    }

    /// #528 acceptance: mid-turn, tacked and bearing away to her gybe, just past her latest start, a boat runs
    /// down into what is left of her turn on the side it goes: she steers off it, away (her rudder against the turn),
    /// then turns on and serves the turn, touching nothing. Before #528 she turned on through it: past her latest start
    /// she dodged nothing.
    @Test func turningBotPastItsLatestStartTurnsAwayFromABoatEnteringItsSweep() throws {
        let others: [(ahead: Double, across: Double, running: Bool)] = [(3, 1.0, true)]
        func scene(_ seed: UInt64) throws -> (race: Race, way: Double) {
            let first = try Self.midTurnScene(seed: seed, others)
            return try Self.midTurnScene(seed: seed, calledAgo: 5 + Self.latestStart(first.race) + 0.2, others)
        }
        let lookahead = BotWeaknesses(skill: 1).keepClearLookahead
        // A seed whose boat crosses what is left of her turn its own way, inside her lookahead.
        let seed = try firstSeed(in: 1...20) { seed in
            let (race, way) = try scene(seed)
            guard let own = try Self.sweepsLeft(race)[way] ?? nil else { return false }
            return own < lookahead
        }
        let (race, way) = try scene(seed)
        let latest = try Self.latestStart(race)
        #expect(latest < 0 && latest > -BotBrain.penaltyLateDodgeSeconds, "seed \(seed): latest start \(latest) s")
        let crossed = Self.sailCrossings(race, seconds: 40, way: way)
        #expect(crossed.steeredAgainstTurning, "seed \(seed): she never steered off her turn")
        #expect(crossed.servedAt != nil, "seed \(seed): not served")
        #expect(!crossed.contact, "seed \(seed): contact")
    }

    /// What `sailToClearWater` saw of seat 0 (#528): the most her heading moved off where it was in the first
    /// `early` seconds, the nearest boat as the scene began and as she started her turn, her latest start
    /// (`latestStartSeconds`) as she started it (her bot chose its way, `penaltyTurn`), the headings of the ways out she
    /// held turning (`penaltyEscape`, each change), whether she was ever over the line early before the gun, the
    /// longest she steered off her plan before the gun without turning, and the race's events.
    struct Cleared {
        var turnedEarly = 0.0
        var nearestAtCall = 0.0
        var nearestStarting: Double?
        var latestStarting: Double?
        /// Seconds from the scene's start to when she started it.
        var startedAfter: Double?
        var escapes: [Double] = []
        /// Her heading as she first chose a way out turning (`penaltyEscape`).
        var escapeFrom: Double?
        var overEarly = false
        var kinds: [RaceEvent.Kind] = []
        var served: Bool { kinds.contains(.penaltyServed(seat: 0)) }
        var contact: Bool { kinds.contains { if case .contact = $0 { true } else { false } } }
        var calledOnHer: [String] { BotConductTests.calls(kinds).filter { $0.hasSuffix("on 0") } }
        var disqualified: Bool { kinds.contains { if case .disqualified(seat: 0, _) = $0 { true } else { false } } }
    }

    /// Sails `race` for `seconds` with only seat 0's bot at the helm (the others hold what their autohelms hold),
    /// watching how she finds clear water for her penalty turn (`Cleared`).
    static func sailToClearWater(_ race: Race, seconds: Double, early: Double = 2) -> Cleared {
        var pilot = Pilot(seat: 0, plannedTack: nil, race: race, skill: 1, weaknesses: BotWeaknesses(skill: 1))
        let from = race.time
        let heading = race.boats[0].heading
        func nearest() -> Double {
            race.boats.indices.dropFirst().map { (race.boats[$0].position - race.boats[0].position).length }.min() ?? .infinity
        }
        var cleared = Cleared()
        cleared.nearestAtCall = nearest()
        for _ in 0..<Int(seconds * Double(Race.tickRate)) where !race.isOver {
            let view = race.seatView(for: 0)
            let latest = view.own.penalty.map { pilot.brain.latestStartSeconds($0, view.own, view) }
            let choosing = pilot.brain.penaltyTurn == nil
            _ = pilot.drive(race)
            if choosing, pilot.brain.penaltyTurn != nil, cleared.latestStarting == nil {
                cleared.latestStarting = latest
                cleared.startedAfter = race.time - from
                cleared.nearestStarting = nearest()
            }
            if let escape = pilot.brain.penaltyEscape?.heading, escape != cleared.escapes.last { cleared.escapes.append(escape) }
            if pilot.brain.penaltyEscape != nil, cleared.escapeFrom == nil { cleared.escapeFrom = view.own.heading }

            race.step()
            cleared.kinds += race.drainEvents().map(\.kind)
            let boat = race.boats[0]
            if race.time - from <= early { cleared.turnedEarly = max(cleared.turnedEarly, abs(wrapAngle(boat.heading - heading))) }
            if boat.status == .prestart, race.course.startLine.side(boat.position) > 0 { cleared.overEarly = true }
        }
        return cleared
    }

    /// #528 acceptance ("move, don't wait"): racing on the beat, owing a turn she hasn't started (its way hers to
    /// choose), with her latest start 14 s off and a pack alongside at her speed (a boat a length and a half to windward
    /// and one three lengths to leeward, on her heading, so holding her course never clears either circle): she changes her heading
    /// at once, the nearest boat is further off as she starts the turn than at the call, she starts it before her latest
    /// start (not blind at it), serves it, touches nothing and draws no call. Before #528 she bore away 25° for 3.5 s and
    /// then put the turn off on her plan's heading, in the pack, until her latest start.
    @Test func penaltyCalledInAPackSailsToClearWaterAndTurnsThere() throws {
        let pack: [(ahead: Double, across: Double, running: Bool)] = [(0, 1.5, false), (0, -3, false)]
        let seed = try firstSeed(in: 1...20) { seed in
            try Self.clearSweeps(Self.lateStartScene(seed: seed, latest: 14, locked: false, pack).race).isEmpty
        }
        let (race, _) = try Self.lateStartScene(seed: seed, latest: 14, locked: false, pack)
        let cleared = Self.sailToClearWater(race, seconds: 45)
        #expect(cleared.turnedEarly > deg2rad(5), "seed \(seed): turned \(rad2deg(cleared.turnedEarly))° in 2 s")
        let starting = try #require(cleared.latestStarting, "seed \(seed): never started")
        #expect(starting > 0, "seed \(seed): started \(starting) s from her latest start")
        #expect((cleared.nearestStarting ?? 0) > cleared.nearestAtCall,
                "seed \(seed): nearest \(cleared.nearestAtCall) m at the call, \(cleared.nearestStarting ?? 0) m starting")
        #expect(cleared.served && !cleared.disqualified, "seed \(seed): not served")
        #expect(!cleared.contact && cleared.calledOnHer.isEmpty, "seed \(seed): \(cleared.calledOnHer)")
    }

    /// #528 acceptance ("start earlier, not later"): a pair at her speed six lengths astern, either side of her wake,
    /// on her heading, crossing both her circles as she slows into them but late (her keep-clear lookahead or more into
    /// each turn), and her latest start 9 s off: she starts the turn at once with that thin margin, not blind at her
    /// latest start, and serves it. Before #528 she put it off, the pair astern all the while, to her latest start.
    @Test func penaltyCalledWithNoClearWaterStartsWithAThinMargin() throws {
        let pack: [(ahead: Double, across: Double, running: Bool)] = [(-6, 0.7, false), (-6, -0.7, false)]
        let lookahead = BotWeaknesses(skill: 1).keepClearLookahead
        let seed = try firstSeed(in: 1...20) { seed in
            let race = try Self.lateStartScene(seed: seed, latest: 9, locked: false, pack).race
            let pilot = Pilot(seat: 0, plannedTack: nil, race: race, skill: 1, weaknesses: BotWeaknesses(skill: 1))
            let view = race.seatView(for: 0)
            let conflicts = [-1.0, 1.0].map { pilot.brain.turnSweep(view.own, view, direction: $0)?.seconds }
            return conflicts.allSatisfy { $0 != nil } && conflicts.compactMap { $0 }.max()! >= lookahead
        }
        let (race, _) = try Self.lateStartScene(seed: seed, latest: 9, locked: false, pack)
        let cleared = Self.sailToClearWater(race, seconds: 45)
        let starting = try #require(cleared.latestStarting, "seed \(seed): never started")
        #expect(starting > 2, "seed \(seed): started \(starting) s from her latest start")
        #expect(cleared.served && !cleared.disqualified, "seed \(seed): not served")
    }

    /// #528 (a pin, as #471 left it): before her start, called in the crowd below the line (a boat a length and a
    /// bit to windward), her bear-away for room takes the clearing course's heading but lasts no longer than
    /// `HandTackTable.penaltyClear.seconds` before she starts the turn, and she is never over the line early.
    @Test func beforeHerStartTheClearingCourseIsShortAndNeverEarly() throws {
        for seed: UInt64 in [1, 2, 3] {
            let race = try Self.prestartCalled(seed: seed, toGun: 40, below: 3, across: 1.2)
            let cleared = Self.sailToClearWater(race, seconds: 30)
            let started = try #require(cleared.startedAfter, "seed \(seed): never started")
            #expect(started <= HandTackTable.penaltyClear.seconds + 0.2, "seed \(seed): started after \(started) s")
            #expect(!cleared.overEarly, "seed \(seed): over the line early")
        }
    }

    /// #528 acceptance (the committed dodge): mid-turn, tacked and bearing away to her gybe, a boat runs down into what
    /// is left of her turn on the side it goes, and a second boat lies where steering 35° off the first would take her:
    /// she commits to one direction out (the owner's ruling on round 2: the direction, not a heading) and every heading
    /// she holds lies on that side of where she was heading as she chose it, never back through the boats; then she
    /// serves the turn, touching nothing. Before #528 she steered 35° off the first boat, re-derived each tick.
    @Test func turningBotHoldsOneWayOutOfTwoBoats() throws {
        let others: [(ahead: Double, across: Double, running: Bool)] = [(6, 0.5, true), (2.5, -2.5, true)]
        let lookahead = BotWeaknesses(skill: 1).keepClearLookahead
        let seed = try firstSeed(in: 1...20) { seed in
            let (race, way) = try Self.midTurnScene(seed: seed, others)
            guard let own = try Self.sweepsLeft(race)[way] ?? nil else { return false }
            return own < 2 * lookahead
        }
        let (race, way) = try Self.midTurnScene(seed: seed, others)
        let crossed = Self.sailCrossings(race, seconds: 40, way: way)
        let cleared = Self.sailToClearWater(try Self.midTurnScene(seed: seed, others).race, seconds: 40)
        #expect(!cleared.escapes.isEmpty, "seed \(seed): she held no way out")
        let from = try #require(cleared.escapeFrom)
        let sides = cleared.escapes.map { wrapAngle($0 - from) }.filter { abs($0) >= BotBrain.clearingStep / 2 }
        #expect(!sides.isEmpty && (sides.allSatisfy { $0 > 0 } || sides.allSatisfy { $0 < 0 }),
                "seed \(seed): ways out \(cleared.escapes.map { Int(rad2deg(wrapAngle($0 - from))) }) off her heading")
        #expect(crossed.servedAt != nil, "seed \(seed): not served")
        #expect(!crossed.contact, "seed \(seed): contact")
    }

    /// #528 (the tie-break's other half): in a pack, every heading on her side short of room, at a mark (`openWater`
    /// false, as `penaltyDodge` passes with a mark near) she waits, holding her heading, where in open water the room
    /// the heading leaves her breaks the tie and moves her out of the pack. Scene: racing on the beat, a pack alongside
    /// at her speed (a boat a length and a half to windward, one three lengths to leeward), her latest start 14 s off.
    @Test func inAPackAtAMarkSheWaits() throws {
        let pack: [(ahead: Double, across: Double, running: Bool)] = [(0, 1.5, false), (0, -3, false)]
        var checked = 0
        for seed: UInt64 in 1...20 {
            let race = try Self.lateStartScene(seed: seed, latest: 14, locked: false, pack).race
            let pilot = Pilot(seat: 0, plannedTack: nil, race: race, skill: 1, weaknesses: BotWeaknesses(skill: 1))
            let view = race.seatView(for: 0)
            let owed = try #require(view.own.penalty)
            let brain = pilot.brain
            let horizon = BotBrain.penaltyEscapeHorizon
            let room = view.boatClass.hull.length * brain.roomLengths
            func pick(openWater: Bool) -> Double? {
                brain.penaltyEscapeHeading(view.own, view, ways: [-1, 1],
                                           angle: { brain.penaltyTurnLeft(view.own, owed, view, direction: $0) },
                                           horizon: horizon, openWater: openWater)
            }
            // Only a pack: the open-water pick moves her and still leaves her short of room (the tie room breaks).
            guard let open = pick(openWater: true), abs(wrapAngle(open - view.own.heading)) > BotBrain.clearingStep / 2,
                  brain.penaltyEscapeRoom(view.own, view, heading: open, horizon: horizon) < room else { continue }
            checked += 1
            let atMark = try #require(pick(openWater: false), "seed \(seed): no heading at a mark")
            #expect(abs(wrapAngle(atMark - view.own.heading)) < BotBrain.clearingStep / 2,
                    "seed \(seed): at a mark she steered \(Int(rad2deg(wrapAngle(atMark - view.own.heading))))° off")
        }
        #expect(checked > 0, "no seed puts her in a pack short of room")
    }

    /// #488 acceptance (fleet-rules@6): beating at close-hauled speed in open water, her own way bearing away, she luffs
    /// first, the shorter turn (about 225°: the tack, then the gybe half a circle on, against 315° bearing away first),
    /// and serves it at the gybe. Off the wind the shorter turn is the other way: on a broad reach (125°), her own way
    /// luffing, she bears away first (the gybe at 55°, the tack at 235°, against 305° luffing first). Before #488 she
    /// luffed first from close-hauled too (#461's `penaltyLuffFirst`), but past `luffFirstAngle` her own way decided
    /// it, and she luffed the long way round from the reach.
    @Test(.onSixRules) func luffsFirstFromCloseHauledOnSixRules() throws {
        for seed: UInt64 in [3, 5] {
            let race = try Self.racingPenalised(seed: seed, ahead: 0, across: 12)
            #expect(race.rules.raceFormat.penalty.turn == .tackAndGybe)
            let bearAway: Double = race.seatView(for: 0).own.relativeWind > 0 ? -1 : 1
            let crossed = Self.sailCrossings(race, seconds: 40, way: -bearAway, penaltyDirection: bearAway)
            #expect(crossed.firstCrossing == .tack, "seed \(seed): first crossing \(String(describing: crossed.firstCrossing))")
            #expect(crossed.servedAt != nil, "seed \(seed): not served")
            #expect(crossed.turned > deg2rad(190) && crossed.turned < deg2rad(270), "seed \(seed): \(rad2deg(crossed.turned))°")

            let reach = try Self.reachingPenalised(seed: seed, twa: deg2rad(125))
            let off = reach.seatView(for: 0).own
            #expect(off.twa > HandTackTable.penaltyTurn.luffFirstAngle)
            let away: Double = off.relativeWind > 0 ? -1 : 1
            let reached = Self.sailCrossings(reach, seconds: 40, way: away, penaltyDirection: -away)
            #expect(reached.firstCrossing == .gybe, "seed \(seed), reaching: first crossing \(String(describing: reached.firstCrossing))")
            #expect(reached.servedAt != nil, "seed \(seed), reaching: not served")
            #expect(reached.turned > deg2rad(200) && reached.turned < deg2rad(280),
                    "seed \(seed), reaching: \(rad2deg(reached.turned))°")
        }
    }

    /// Under fleet-rules@6 (`.onSixRules`): seat 0 on the beat, close-hauled on starboard at her speed, heading for the
    /// windward mark, `gap` hull lengths short of its zone (`zoneRadius` and half a hull) on her heading, owing one turn
    /// whose clock started `clockAgo` seconds ago; seat 1 far off abeam.
    static func markApproachScene(seed: UInt64, gap: Double, clockAgo: Double) throws -> Race {
        let water = Water(seed: seed, seats: 2)
        let heading = water.beat(.starboard)
        let forward = Vec2.heading(heading)
        let course = water.race.course
        guard case .round(let index) = course.legs[0], let mark = course.elements[index].marks.first?.position else {
            throw NoChoiceMeetsTheCondition(description: "seed \(seed): no mark to round on the beat")
        }
        let reach = course.zoneRadius + water.length / 2
        let position = mark - forward * (reach + water.length * gap)
        return try place(water, [
            Placement(position: position, heading: heading, speed: water.up.speed),
            Placement(position: position - forward.rightPerp * water.length * 15, heading: heading, speed: water.up.speed),
        ]) { snapshot in
            snapshot.seats[0].boat.penaltyTurnsOwed = 1
            snapshot.seats[0].boat.penaltyProgress = 0
            snapshot.seats[0].boat.penaltyClockTick = snapshot.tick - RulesConfig.ticks(clockAgo)
        }
    }

    /// What `sailToTheMark` saw of seat 0: when she began her turn and served it, whether she was disqualified, how long
    /// she spent in the mark's zone (`SeatView.OwnBoat.isRounding`) owing it, and whether she had rounded any of the
    /// mark (her leg or rounding stage moved on) when she served it.
    struct MarkApproach {
        var startedAt: Double?
        var servedAt: Double?
        var disqualified = false
        var roundingOwing = 0.0
        var roundedFirst = false
        /// Hull lengths she sailed off the mark, at the most, before she began her turn.
        var sailedOff = 0.0
    }

    /// Sails `race` for `seconds` with seat 0's bot at the helm (the other's autohelm holding), or until she serves her
    /// turn or is disqualified.
    static func sailToTheMark(_ race: Race, seconds: Double) -> MarkApproach {
        var pilot = Pilot(seat: 0, plannedTack: nil, race: race, skill: 1, weaknesses: BotWeaknesses(skill: 1))
        let from = race.time
        let leg = race.boats[0].legIndex, stage = race.boats[0].roundingStage
        let mark: Vec2? = if case .round(let index) = race.course.legs[leg] { race.course.elements[index].marks.first?.position } else { nil }
        let from0 = mark.map { ($0 - race.boats[0].position).length } ?? 0
        var seen = MarkApproach()
        for _ in 0..<Int(seconds * Double(Race.tickRate)) where !race.isOver {
            _ = pilot.drive(race)
            race.step()
            let boat = race.boats[0]
            let kinds = race.drainEvents().map(\.kind)
            if seen.startedAt == nil, kinds.contains(.penaltyStarted(seat: 0)) { seen.startedAt = race.time - from }
            if kinds.contains(.penaltyServed(seat: 0)) {
                seen.servedAt = race.time - from
                seen.roundedFirst = boat.legIndex != leg || boat.roundingStage != stage
                break
            }
            if boat.status == .dsq {
                seen.disqualified = true
                break
            }
            if race.seatView(for: 0).own.isRounding { seen.roundingOwing += 1 / Double(Race.tickRate) }
            if seen.startedAt == nil, let mark {
                seen.sailedOff = max(seen.sailedOff, ((mark - boat.position).length - from0) / race.boatClass.hull.length)
            }
        }
        return seen
    }

    /// Fix round 3 (fleet-rules@6, "turn before the mark", the owner's ruling of 2026-10-12): her clock running, the
    /// windward mark's zone ahead and no time to round it and then turn (`penaltyMarkAhead`), she serves her turn before
    /// the rounding.
    /// (a) Four hull lengths short of the zone, the turn's crossings clear of it: she turns at once and serves it
    /// without entering the zone. (The bots turned there before this fix too: the case pins the branch.)
    /// (b) Half a hull length short, 25 s left: as she turns her crossings fall in the zone (`penaltyCrossingRounds`),
    /// so she holds the rounding off, sailing away from the mark (out of the zone, if her turn away took her in), then
    /// turns and serves it before rounding it. Before the fix she sailed into the rounding, the turn waiting for its end
    /// (`sailOn`), and was disqualified on three seeds of 1...4.
    @Test(.onSixRules) func penaltyCalledNearAMarkIsServedBeforeTheRounding() throws {
        // The race, whether the mark is ahead of her time (`penaltyMarkAhead`), and whether each way's crossings fall in
        // its zone.
        func scene(_ seed: UInt64, gap: Double, clockAgo: Double) throws -> (race: Race, ahead: Bool, rounds: Bool) {
            let race = try Self.markApproachScene(seed: seed, gap: gap, clockAgo: clockAgo)
            let pilot = Pilot(seat: 0, plannedTack: nil, race: race, skill: 1, weaknesses: BotWeaknesses(skill: 1))
            let view = race.seatView(for: 0)
            let owed = try #require(view.own.penalty)
            let ahead = pilot.brain.penaltyMarkAhead(view.own, owed, view) != nil
            let rounds = [-1.0, 1.0].allSatisfy { pilot.brain.penaltyCrossingRounds(view.own, owed, view, direction: $0) }
            return (race, ahead, rounds)
        }
        let turnFits = try firstSeed(in: 1...20) { seed in
            let s = try scene(seed, gap: 4, clockAgo: 18)
            return s.ahead && !s.rounds
        }
        let fits = Self.sailToTheMark(try scene(turnFits, gap: 4, clockAgo: 18).race, seconds: 40)
        #expect(fits.startedAt.map { $0 < 3 } == true, "seed \(turnFits), (a): \(fits)")
        #expect(fits.servedAt != nil && !fits.roundedFirst && fits.roundingOwing == 0, "seed \(turnFits), (a): \(fits)")

        let holdsOff = try firstSeed(in: 1...20) { seed in
            let s = try scene(seed, gap: 0.5, clockAgo: 15)
            return s.ahead
        }
        let held = Self.sailToTheMark(try scene(holdsOff, gap: 0.5, clockAgo: 15).race, seconds: 40)
        #expect(!held.disqualified && held.servedAt != nil, "seed \(holdsOff), (b): \(held)")
        #expect(!held.roundedFirst, "seed \(holdsOff), (b): she rounded the mark first: \(held)")
        #expect(held.startedAt.map { $0 > 5 } == true && held.sailedOff > 0.25, "seed \(holdsOff), (b): she didn't hold off: \(held)")
    }

    /// Seat 0 alone in open water on the run to the gate (`Water(running:)`), on starboard at `twa` off the wind at her
    /// polar speed there, owing a turn whose clock starts now; seat 1 far off abeam.
    static func reachingPenalised(seed: UInt64, twa: Double) throws -> Race {
        let water = Water(seed: seed, running: true)
        let heading = water.heading(.starboard, twa)
        let forward = Vec2.heading(heading)
        let speed = water.race.boatClass.polar.speed(twa: twa, tws: water.race.groundWind(at: water.centre).speed)
        return try place(water, [
            Placement(position: water.centre, heading: heading, speed: speed),
            Placement(position: water.centre + forward.rightPerp * water.length * 12, heading: heading, speed: speed),
        ]) { snapshot in
            snapshot.seats[0].boat.penaltyTurnsOwed = 1
            snapshot.seats[0].boat.penaltyProgress = 0
            snapshot.seats[0].boat.penaltyClockTick = snapshot.tick
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

    // MARK: - #517: give a turning boat her circle

    /// The water seat 1 means to turn in (`tackTowardsATurningBoat`): beating up the first beat, to tack; running down
    /// to the gate, to gybe; or beating below the line 40 s before the gun, to tack.
    enum TurnWater { case beating, running, beforeTheGun }

    /// Seat 1 beating on starboard, meaning to tack (in `water`: or running on starboard, meaning to gybe, or before
    /// her start); seat 0 `along` hull lengths up the line her tack would sail and `ahead` up her own course (or
    /// `offset` metres from her, if given), on `heading` (the port beat's unless given: sailing away up that line) at
    /// `speed` (0.6 of close-hauled speed unless given). `turning`: seat 0 has just tacked as the first crossing of a
    /// penalty turn and owes the gybe (`midTurnScene`'s boat, rule 21.2); else she owes nothing. Seat 0 is racing, or
    /// before her start with seat 1, unless `status` is given.
    static func tackTowardsATurningBoat(seed: UInt64, along: Double, ahead: Double, turning: Bool = true,
                                        heading: Double? = nil, status: BoatStatus? = nil, speed: Double? = nil,
                                        offset: Vec2? = nil, water kind: TurnWater = .beating) throws -> Race {
        let water = switch kind {
        case .beating: Water(seed: seed)
        case .running: Water(seed: seed, running: true)
        case .beforeTheGun: Water(seed: seed, toGun: 40, below: 12)
        }
        let own: BoatStatus = kind == .beforeTheGun ? .prestart : .racing
        let from = kind == .running ? water.run(.starboard) : water.beat(.starboard)
        let onto = kind == .running ? water.run(.port) : water.beat(.port)
        let forward = Vec2.heading(from), tacked = Vec2.heading(onto)
        return try place(water, [
            Placement(position: water.centre + (offset ?? tacked * water.length * along + forward * water.length * ahead),
                      heading: heading ?? water.beat(.port), speed: speed ?? water.up.speed * 0.6, status: status ?? own),
            Placement(position: water.centre, heading: from, speed: kind == .running ? water.down.speed : water.up.speed,
                      status: own),
        ]) { snapshot in
            guard turning else { return }
            snapshot.seats[0].boat.penaltyTurnsOwed = 1
            snapshot.seats[0].boat.penaltyClockTick = snapshot.tick - RulesConfig.ticks(5)
            snapshot.seats[0].boat.penaltyFirstCrossing = .tack
            // Bearing away from port close-hauled, to the gybe: to starboard.
            snapshot.seats[0].boat.penaltyDirection = 1
        }
    }

    /// Seat 1's look before her tack or gybe as `race` stands, for a skill-1 bot (the cautious bot's with `caution`):
    /// whether it is clear (`BotBrain.tapIsClear`), seat 0 as she sees her, the closest her tack's track and the sailing
    /// after it come to where seat 0 is (`circleApproach`), the closest the tap's line comes to seat 0 sailed straight
    /// on at her velocity (every bot's reckoning before #517, and still), and the gap between them now, metres; the
    /// circle seat 0 is to her with the clearance round it (`need`, nil unless seat 0 is taking a penalty), and whether
    /// she can begin the turn now (`BotBrain.canTap`, by hand: the gate of a tap and of a hand turn's start).
    static func lookBeforeHerTack(_ race: Race, caution: BotBrain.Caution? = nil) throws
        -> (isClear: Bool, other: SeatView.OtherBoat, circle: Double, straight: Double, gap: Double, need: Double?,
            canTurn: Bool) {
        let view = race.seatView(for: 1)
        let b = view.own
        let other = try #require(view.others.first { $0.seat == 0 })
        let brain = BotBrain(style: Self.skill1, caution: caution)
        let need = brain.penaltyCircleRadius(of: other, b, view).map { $0 + view.boatClass.hull.length * brain.tapClearanceLengths }
        let heading = 2 * b.windDirection - b.heading
        let lookahead = (other.tack == .starboard ? BotBrain.tapOntoPortLookahead : BotBrain.tapLookahead) * brain.tapLookaheadScale
        let straight = BotBrain.closestApproach(of: other, to: b, heading: heading, speed: b.speed * BotBrain.tapSpeedShare,
                                                lookahead: lookahead)
        return (brain.tapIsClear(b, view), other, brain.circleApproach(to: other, b, heading: heading), straight,
                (other.position - b.position).length, need, brain.canTap(b, view, byHand: true))
    }

    /// Sails `race` for `seconds`, seat 1 meaning to tack onto port and seat 0 sailing her own race (a turn she owes),
    /// both at skill 1: the view seat 1 put her helm over for the tack on (or tapped it on) and the seconds until she
    /// did, her least speed and the most her heading left its first while she hadn't, the closest the boats came, and
    /// every event; and of seat 0 while seat 1 hadn't: whether she was taking her penalty at every tick
    /// (`Boat.isTakingPenalty`), and the most her heading left its first (the turn she made on the water). `planned`
    /// nil: seat 1 means no turn, and sails her own tack on.
    static func sailToHerTack(_ race: Race, seconds: Double, planned: Tack? = .port)
        -> (began: (view: SeatView, seconds: Double)?, leastSpeed: Double, mostOffCourse: Double, closest: Double,
            kinds: [RaceEvent.Kind], tookPenalty: Bool, turned: Double) {
        var pilots = [Pilot(seat: 0, plannedTack: nil, race: race), Pilot(seat: 1, plannedTack: planned, race: race)]
        var began: (view: SeatView, seconds: Double)?
        let first = race.boats[1].heading, start = race.tick
        var leastSpeed = race.boats[1].speed, mostOffCourse = 0.0
        var closest = (race.boats[0].position - race.boats[1].position).length
        var kinds: [RaceEvent.Kind] = []
        let firstOfTurning = race.boats[0].heading
        var tookPenalty = true, turned = 0.0
        for _ in 0..<Int(seconds * Double(Race.tickRate)) where !race.isOver {
            _ = pilots[0].drive(race)
            let view = race.seatView(for: 1)
            if let decision = pilots[1].drive(race), began == nil, pilots[1].brain.handTurn != nil || decision.tap != nil {
                began = (view, Double(race.tick - start) / Double(Race.tickRate))
            }
            race.step()
            if began == nil {
                leastSpeed = min(leastSpeed, race.boats[1].speed)
                mostOffCourse = max(mostOffCourse, abs(wrapAngle(race.boats[1].heading - first)))
                tookPenalty = tookPenalty && race.boats[0].isTakingPenalty
                turned = max(turned, abs(wrapAngle(race.boats[0].heading - firstOfTurning)))
            }
            closest = min(closest, (race.boats[0].position - race.boats[1].position).length)
            kinds += race.drainEvents().map(\.kind)
        }
        return (began, leastSpeed, mostOffCourse, closest, kinds, tookPenalty, turned)
    }

    /// #517, "give a turning boat her circle" (the owner's incident of 2026-10-13: a boat tacked into a boat turning a
    /// penalty, who had no way to avoid her and was called 21.2). Seat 0 is turning a penalty up the line seat 1's tack
    /// would sail, sailing away up it: clear by the straight-line reckoning every bot made, sailed on at her velocity,
    /// but she is slow and circling, and the tack and the sailing after it pass through the water she turns in. Seat 1
    /// holds the tack: she never puts her helm over while her track crosses the circle, where seat 0 then is. Held off
    /// it she sails on, on her course at her speed (no orderly bots), and nobody is called.
    @Test func holdsATackThroughTheCircleOfABoatTakingAPenalty() throws {
        for seed: UInt64 in [3, 9, 18] {
            let race = try Self.tackTowardsATurningBoat(seed: seed, along: 2.9, ahead: 1.8)
            let length = race.boatClass.hull.length
            let brain = BotBrain(style: Self.skill1)
            let look = try Self.lookBeforeHerTack(race)
            let view = race.seatView(for: 1)
            #expect(look.other.rightOfWay == RightOfWay(keepClear: 0, rule: .takingAPenalty), "seed \(seed)")
            let radius = try #require(brain.penaltyCircleRadius(of: look.other, view.own, view), "seed \(seed)")
            let need = radius + length * BotBrain.tapClearance
            #expect(look.gap <= BotBrain.tapRange && look.gap > need, "seed \(seed): \(look.gap) m off, circle \(need) m")
            #expect(look.straight >= length * BotBrain.tapClearance, "seed \(seed): clear by the straight-line reckoning")
            #expect(look.circle < need, "seed \(seed): her track crosses the circle: \(look.circle) of \(need) m")
            #expect(!look.isClear, "seed \(seed): the tack isn't clear")

            // "And the sailing after it": seat 0 further up that line, beyond the tack itself.
            let further = try Self.lookBeforeHerTack(Self.tackTowardsATurningBoat(seed: seed, along: 5.5, ahead: 0))
            let tack = view.own.speed * BotBrain.tapSpeedShare * BotBrain.tapLookahead
            #expect(further.gap - tack >= need && further.gap <= BotBrain.tapRange, "seed \(seed): the tack alone is clear")
            #expect(further.circle < need && !further.isClear, "seed \(seed): the sailing after it isn't")

            let speed = race.boats[1].speed
            let sailed = Self.sailToHerTack(race, seconds: 14)
            #expect(Self.calls(sailed.kinds).isEmpty, "seed \(seed): \(Self.calls(sailed.kinds))")
            #expect(sailed.closest > length * BotBrain.tapClearance, "seed \(seed): came within \(sailed.closest) m")
            // Held: without the circle she puts her helm over at her first decision.
            #expect((sailed.began?.seconds ?? .infinity) > 2, "seed \(seed): tacked after \(sailed.began?.seconds ?? -1) s")
            // Sailing on meanwhile: her course, her speed.
            #expect(sailed.leastSpeed > speed * 0.9, "seed \(seed): slowed to \(sailed.leastSpeed) of \(speed) m/s")
            #expect(sailed.mostOffCourse < deg2rad(8), "seed \(seed): \(rad2deg(sailed.mostOffCourse))° off her course")
            // Seat 0 is sailed by her own bot, which turns the penalty the scene has her owe: all the while the tack
            // is held she is taking it (rule 21.2), and turning on the water, bearing away for her gybe.
            #expect(sailed.tookPenalty, "seed \(seed): seat 0 taking her penalty while the tack is held")
            #expect(sailed.turned > deg2rad(60), "seed \(seed): seat 0 turned \(rad2deg(sailed.turned))° meanwhile")
            // And she tacks with seat 0 still turning, her track out of the circle.
            let began = try #require(sailed.began, "seed \(seed): she never tacked")
            let other = try #require(began.view.others.first { $0.seat == 0 })
            #expect(other.rightOfWay == RightOfWay(keepClear: 0, rule: .takingAPenalty),
                    "seed \(seed): seat 0 still taking her penalty as she tacked, after \(began.seconds) s")
            let around = try #require(brain.penaltyCircleRadius(of: other, began.view.own, began.view), "seed \(seed)")
            let b = began.view.own
            let approach = brain.circleApproach(to: other, b, heading: 2 * b.windDirection - b.heading)
            #expect(approach >= around + length * BotBrain.tapClearance,
                    "seed \(seed): tacked \(approach) m off a circle of \(around) m")
        }
    }

    /// #517: and she tacks as soon as her track clears the circle, with seat 0 still turning in it: the tack is held
    /// off, never given up, and she waits on nothing else. With no circle there she tacks at once: seat 0 in the same
    /// water with her turn served, seat 0 turning beyond the circle's reach of her track, and a returning boat (rule
    /// 21.1), who sails a course and is weighed sailing on at her velocity as every boat was.
    @Test func tacksOnceHerTrackClearsABoatTakingAPenalty() throws {
        for seed: UInt64 in [3, 9, 18] {
            let held = try Self.tackTowardsATurningBoat(seed: seed, along: 2.9, ahead: 1.8)
            let length = held.boatClass.hull.length
            let brain = BotBrain(style: Self.skill1)
            let first = held.seatView(for: 1)
            let turning = try #require(first.others.first { $0.seat == 0 })
            let radius = try #require(brain.penaltyCircleRadius(of: turning, first.own, first), "seed \(seed)")
            let need = radius + length * BotBrain.tapClearance
            #expect(try !Self.lookBeforeHerTack(held).isClear, "seed \(seed): held at first")
            let sailed = Self.sailToHerTack(held, seconds: 14)
            let began = try #require(sailed.began, "seed \(seed): she never tacked")
            #expect(began.seconds > 2, "seed \(seed): held at first, tacked after \(began.seconds) s")
            let other = try #require(began.view.others.first { $0.seat == 0 })
            #expect(other.rightOfWay == RightOfWay(keepClear: 0, rule: .takingAPenalty),
                    "seed \(seed): seat 0 still turning as she tacked, after \(began.seconds) s")
            #expect(Self.calls(sailed.kinds).isEmpty, "seed \(seed): \(Self.calls(sailed.kinds))")

            // Her turn served: the same water, no circle.
            let served = try Self.tackTowardsATurningBoat(seed: seed, along: 2.9, ahead: 1.8, turning: false)
            var look = try Self.lookBeforeHerTack(served)
            #expect(look.other.rightOfWay?.rule != .takingAPenalty, "seed \(seed)")
            #expect(look.circle < need && look.isClear, "seed \(seed): turn served, clear")
            #expect((Self.sailToHerTack(served, seconds: 3).began?.seconds ?? .infinity) < 0.5, "seed \(seed): turn served")

            // Turning, beyond the circle's reach of her track.
            let beyond = try Self.tackTowardsATurningBoat(seed: seed, along: 2.9, ahead: -4.5)
            look = try Self.lookBeforeHerTack(beyond)
            #expect(look.other.rightOfWay?.rule == .takingAPenalty && look.gap <= BotBrain.tapRange, "seed \(seed)")
            #expect(look.circle >= need && look.isClear, "seed \(seed): beyond the circle, clear")
            #expect((Self.sailToHerTack(beyond, seconds: 3).began?.seconds ?? .infinity) < 0.5, "seed \(seed): beyond it")

            // A returning boat (rule 21.1) running off below the line her tack would sail: inside what the circle of a
            // boat taking a penalty would be, and clear sailed on at her velocity.
            let water = Water(seed: seed)
            let returning = try Self.tackTowardsATurningBoat(seed: seed, along: 2.9, ahead: -1.2, turning: false,
                                                             heading: water.wind + .pi, status: .ocs)
            look = try Self.lookBeforeHerTack(returning)
            #expect(look.other.rightOfWay == RightOfWay(keepClear: 0, rule: .returningToStart), "seed \(seed)")
            #expect(look.circle < need && look.straight >= length * BotBrain.tapClearance, "seed \(seed)")
            #expect(look.isClear, "seed \(seed): a returning boat, clear")
            #expect((Self.sailToHerTack(returning, seconds: 3).began?.seconds ?? .infinity) < 0.5, "seed \(seed): returning")
        }
    }

    /// #517: a gybe is held off as a tack is. Seat 1 running on starboard, meaning to gybe; seat 0 taking her penalty
    /// up the line the gybe would sail, slow, clear by the straight-line reckoning. Seat 1 holds the gybe, running on
    /// at the speed she would run at meaning no gybe at all, and gybes with seat 0 still turning once her track is out
    /// of the circle. With seat 0's turn served she gybes at once.
    ///
    /// Off the wind her track is longer than on it, and reaches the circle of a boat beyond `BotBrain.tapRange`: that
    /// boat is looked at too, as far off as the range and her circle with its clearance.
    @Test func holdsAGybeThroughTheCircleOfABoatTakingAPenalty() throws {
        for seed: UInt64 in [3, 9, 18] {
            let scene = { try Self.tackTowardsATurningBoat(seed: seed, along: 5, ahead: 1, turning: $0, water: .running) }
            let race = try scene(true)
            let clear = race.boatClass.hull.length * BotBrain.tapClearance
            #expect(race.boats[1].twa > .pi / 2, "seed \(seed): running")
            let look = try Self.lookBeforeHerTack(race)
            let need = try #require(look.need, "seed \(seed): seat 0 taking a penalty")
            #expect(look.gap <= BotBrain.tapRange && look.gap > need, "seed \(seed): \(look.gap) m off, circle \(need) m")
            #expect(look.straight >= clear, "seed \(seed): clear by the straight-line reckoning, \(look.straight) m")
            #expect(look.circle < need, "seed \(seed): her track crosses the circle: \(look.circle) of \(need) m")
            #expect(!look.isClear && !look.canTurn, "seed \(seed): the gybe isn't clear")

            let sailed = Self.sailToHerTack(race, seconds: 10)
            let began = try #require(sailed.began, "seed \(seed): she never gybed")
            #expect(began.seconds > 1.5, "seed \(seed): gybed after \(began.seconds) s")
            #expect(sailed.tookPenalty, "seed \(seed): seat 0 taking her penalty while the gybe is held")
            let other = try #require(began.view.others.first { $0.seat == 0 })
            #expect(other.rightOfWay == RightOfWay(keepClear: 0, rule: .takingAPenalty), "seed \(seed): and as she gybed")
            #expect(Self.calls(sailed.kinds).isEmpty, "seed \(seed): \(Self.calls(sailed.kinds))")
            #expect(sailed.closest > clear, "seed \(seed): came within \(sailed.closest) m")
            // Running on meanwhile as she would meaning no gybe: her course, and the same speed (no orderly bots).
            let running = Self.sailToHerTack(try scene(true), seconds: began.seconds, planned: nil)
            #expect(sailed.leastSpeed >= running.leastSpeed - 0.01,
                    "seed \(seed): slowed to \(sailed.leastSpeed) m/s, \(running.leastSpeed) m/s running on")
            #expect(sailed.mostOffCourse < deg2rad(8), "seed \(seed): \(rad2deg(sailed.mostOffCourse))° off her course")

            // Her turn served: the same water, no circle.
            let served = try Self.lookBeforeHerTack(scene(false))
            #expect(served.need == nil && served.isClear && served.canTurn, "seed \(seed): turn served, clear")
            #expect((Self.sailToHerTack(try scene(false), seconds: 3).began?.seconds ?? .infinity) < 0.5, "seed \(seed): turn served")

            // Beyond `tapRange`, her circle within reach of the gybe's track.
            let far = try Self.lookBeforeHerTack(Self.tackTowardsATurningBoat(seed: seed, along: 9.2, ahead: 0, water: .running))
            #expect(far.gap > BotBrain.tapRange && far.gap <= BotBrain.tapRange + need, "seed \(seed): \(far.gap) m off")
            #expect(far.circle < need && !far.isClear, "seed \(seed): the track reaches her circle: \(far.circle) of \(need) m")
            // And beyond the range and the circle no boat is looked at.
            let beyond = try Self.lookBeforeHerTack(Self.tackTowardsATurningBoat(seed: seed, along: 11.5, ahead: 0, water: .running))
            #expect(beyond.gap > BotBrain.tapRange + need && beyond.isClear, "seed \(seed): \(beyond.gap) m off")
        }
    }

    /// #517: and before her start (`tapIsClear` is her look there too, #280). Seat 1 beating below the line 40 s before
    /// the gun, seat 0 taking a penalty up the line her tack would sail, sailing away up it: the tack is refused for
    /// the circle, and clear with seat 0's turn served.
    @Test func holdsATackBeforeHerStartThroughTheCircleOfABoatTakingAPenalty() throws {
        for seed: UInt64 in [3, 9, 18] {
            let scene = { try Self.tackTowardsATurningBoat(seed: seed, along: 4, ahead: 0, turning: $0, water: .beforeTheGun) }
            let race = try scene(true)
            #expect(race.boats.allSatisfy { $0.status == .prestart }, "seed \(seed)")
            let clear = race.boatClass.hull.length * BotBrain.tapClearance
            let look = try Self.lookBeforeHerTack(race)
            #expect(look.other.rightOfWay == RightOfWay(keepClear: 0, rule: .takingAPenalty), "seed \(seed)")
            let need = try #require(look.need, "seed \(seed)")
            #expect(look.gap <= BotBrain.tapRange && look.gap > need, "seed \(seed): \(look.gap) m off, circle \(need) m")
            #expect(look.straight >= clear, "seed \(seed): clear by the straight-line reckoning, \(look.straight) m")
            #expect(look.circle < need, "seed \(seed): her track crosses the circle: \(look.circle) of \(need) m")
            #expect(!look.isClear && !look.canTurn, "seed \(seed): the tack isn't clear")
            let served = try Self.lookBeforeHerTack(scene(false))
            #expect(served.need == nil && served.isClear && served.canTurn, "seed \(seed): turn served, clear")
        }
    }

    /// #517: the cautious bot (#104) gives the circle more. Her clearance round it is wider (`tapClearanceLengths`) and
    /// the tack's part of her track longer (`tapLookaheadScale`), both by `Caution.clearanceFactor` as for any boat;
    /// the circle's radius (the class's penalty turn) and the sailing after the tack (`penaltyCircleAfter`) are the
    /// same for every bot. Seat 0 taking her penalty far enough up the line of the tack that a skill-1 bot's track
    /// stops short of her circle: the cautious bot's doesn't, and she holds the tack.
    @Test func cautiousBotHoldsATackThroughTheCircleOfABoatTakingAPenalty() throws {
        for seed: UInt64 in [3, 9, 18] {
            let scene = { try Self.tackTowardsATurningBoat(seed: seed, along: 7.7, ahead: 0, turning: $0) }
            let race = try scene(true)
            let length = race.boatClass.hull.length, speed = race.boats[1].speed
            let factor = BotBrain.Caution.standard.clearanceFactor
            let plain = try Self.lookBeforeHerTack(race), cautious = try Self.lookBeforeHerTack(race, caution: .standard)
            let need = try #require(plain.need, "seed \(seed)"), wider = try #require(cautious.need, "seed \(seed)")
            #expect(plain.gap <= BotBrain.tapRange, "seed \(seed): \(plain.gap) m off")
            #expect(abs(wider - need - length * BotBrain.tapClearance * (factor - 1)) < 1e-9, "seed \(seed): the clearance only")
            let further = speed * BotBrain.tapSpeedShare * BotBrain.tapLookahead * (factor - 1)
            // To centimetres: seat 0 is up the water's port beat, a touch off the line of the tack in seat 1's own wind.
            #expect(abs(plain.circle - cautious.circle - further) < 0.05, "seed \(seed): the tack's part of the track only")
            #expect(plain.circle >= need && plain.isClear, "seed \(seed): a skill-1 bot's track stops short of the circle")
            #expect(cautious.straight >= length * BotBrain.tapClearance * factor, "seed \(seed): clear by the straight-line reckoning")
            #expect(cautious.circle < wider, "seed \(seed): hers crosses it: \(cautious.circle) of \(wider) m")
            #expect(!cautious.isClear && !cautious.canTurn, "seed \(seed): the cautious bot's tack isn't clear")
            let served = try Self.lookBeforeHerTack(scene(false), caution: .standard)
            #expect(served.need == nil && served.isClear && served.canTurn, "seed \(seed): turn served, clear")
        }
    }

    /// #517, the ruling of 2026-10-13: a boat taking a penalty is a circle of water and a boat sailed on, both. Between
    /// her tack and her gybe she is reaching, not circling in place. Seat 0 taking her penalty, beam reaching on
    /// starboard at the line seat 1's tack would sail, to meet her on it 5 s on (inside `tapOntoPortLookahead`), her
    /// circle clear of the track: the tack is refused, as it is with her turn served, and as it was before #517.
    @Test func refusesATackAcrossABoatTakingAPenaltyReachingAtHerTrack() throws {
        for seed: UInt64 in [3, 9, 18] {
            let water = Water(seed: seed)
            let need = try #require(try Self.lookBeforeHerTack(Self.tackTowardsATurningBoat(seed: seed, along: 2.9, ahead: 1.8)).need)
            let tacked = Vec2.heading(water.beat(.port))
            let reach = water.heading(.starboard, .pi / 2), reaching = Vec2.heading(reach)
            // Her speed: from 1.5 m outside the circle's reach of the track to the track in `meet` seconds.
            let meet = 5.0
            let speed = (need + 1.5) / (meet * abs(reaching.dot(tacked.rightPerp)))
            let offset = tacked * (water.up.speed * BotBrain.tapSpeedShare * meet) - reaching * (speed * meet)
            let scene = { try Self.tackTowardsATurningBoat(seed: seed, along: 0, ahead: 0, turning: $0, heading: reach,
                                                           speed: speed, offset: offset) }
            let look = try Self.lookBeforeHerTack(scene(true))
            #expect(look.other.rightOfWay == RightOfWay(keepClear: 0, rule: .takingAPenalty), "seed \(seed)")
            #expect(look.other.tack == .starboard && look.gap <= BotBrain.tapRange, "seed \(seed): \(look.gap) m off")
            #expect(speed < water.up.speed * 1.2, "seed \(seed): reaching at \(speed) m/s")
            #expect(look.circle >= need, "seed \(seed): her track is out of the circle: \(look.circle) of \(need) m")
            #expect(look.straight < water.length * BotBrain.tapClearance, "seed \(seed): she sails into the tack: \(look.straight) m")
            #expect(!look.isClear && !look.canTurn, "seed \(seed): the tack isn't clear")
            let served = try Self.lookBeforeHerTack(scene(false))
            #expect(served.need == nil && !served.isClear, "seed \(seed): nor with her turn served")
        }
    }
}
