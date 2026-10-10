import Foundation
import Testing
@testable import RegattaCore
@testable import RegattaBots

/// #459: bots steer their tacks and gybes by hand on a class whose tap sails nothing (`AutohelmTuning.sailsTap` false,
/// skiff@8), as well as their handling draw lets them; every older class keeps the tap and the roll, to the bit.
@Suite struct BotHandTackTests {
    /// An all-bot race's digest after `seconds` on `boatClass`: eight seats, the fleet's normal draw.
    static func digest(seed: UInt64, boatClass: BoatClassFile, seconds: Int = 200) throws -> UInt64 {
        let race = try BotHelmTests.race(seed: seed, boatClass: boatClass)
        var controllers = allBots(race)
        sail(race, &controllers, ticks: seconds * Race.tickRate)
        return race.digest()
    }

    /// Old classes sail the tap and the roll exactly as before #459: an all-bot race on skiff@7 (the default class, the
    /// autohelm off, a roll tack) and on skiff@6 (the autohelm on), pinned on #458's tip before any bot code changed.
    @Test func skiffSevenBotsAreBitIdentical() throws {
        let seven = try Self.digest(seed: 459, boatClass: BoatClassFile.bundled(id: "skiff", version: 7))
        let six = try Self.digest(seed: 459, boatClass: BoatClassFile.bundled(id: "skiff", version: 6))
        #expect(hex64(seven) == "0xa802fd2cfe1d943f")
        #expect(hex64(six) == "0x3c5c84c4afc4054b")
    }

    // MARK: - skiff@8: tacks and gybes by hand

    static let skiffEight = try! BoatClassFile.bundled(id: "skiff", version: 8)

    /// What a fleet of bots made of a race on skiff@8.
    struct Fleet {
        /// Each boat's boom crossings with the wind forward of the beam (tacks) and abaft it (gybes), racing.
        var tacks: [Int]
        var gybes: [Int]
        /// Each boat's longest spell in irons, seconds: under 30 % of her close-hauled speed inside the no-go zone.
        var stuck: [Double]
        var tackGybeTaps: Int
        var finished: Int
    }

    /// An all-bot race on skiff@8 for `seconds`: the fleet's normal draw, or every bot's handling `handling`; seat 0
    /// the cautious bot's from a minute after the gun if `cautiousTakeover`.
    static func fleet(seed: UInt64, seconds: Int, handling: Double? = nil, cautiousTakeover: Bool = false) throws -> Fleet {
        let race = try BotHelmTests.race(seed: seed, boatClass: skiffEight)
        var controllers = handling.map { handling in
            SeatControllers(race.boats.indices.map { seat in
                let skill = BotTier.mixedFleetDraw(seed: botSeed(raceSeed: race.setup.raceSeed, seat: seat)).skill
                return .bot(BotDriver(seat: seat, raceSeed: race.setup.raceSeed, skill: skill, handling: handling))
            })
        } ?? allBots(race)
        let count = race.boats.count
        var fleet = Fleet(tacks: Array(repeating: 0, count: count), gybes: Array(repeating: 0, count: count),
                          stuck: Array(repeating: 0, count: count), tackGybeTaps: 0, finished: 0)
        var booms = race.boats.map(\.boomSide)
        var spell = Array(repeating: 0.0, count: count)
        let polar = race.boatClass.polar
        let noGo = BoatDynamics.noGoAngle(polar)
        for _ in 0..<(seconds * Race.tickRate) where !race.isOver {
            // The cautious bot takes seat 0 over a minute after the gun, as she would a dropped player's boat.
            if cautiousTakeover, race.tick == 60 * Race.tickRate {
                controllers.takeOver(seat: 0, raceSeed: race.setup.raceSeed, cautious: true)
            }
            controllers.drive(race)
            race.step()
            for (seat, boat) in race.boats.enumerated() where boat.isOnCourse {
                let wind = race.groundWind(at: boat.position)
                let twa = abs(wrapAngle(wind.direction - boat.heading))
                if boat.boomSide != booms[seat], boat.status == .racing {
                    if twa < .pi / 2 { fleet.tacks[seat] += 1 } else { fleet.gybes[seat] += 1 }
                }
                booms[seat] = boat.boomSide
                let stuck = twa < noGo && boat.speed < 0.3 * polar.bestUpwind(tws: wind.speed).speed
                spell[seat] = stuck ? spell[seat] + Race.dt : 0
                fleet.stuck[seat] = max(fleet.stuck[seat], spell[seat])
            }
        }
        fleet.tackGybeTaps = try #require(race.log).inputs.filter { $0.kind == .tap(.tackGybe) }.count
        fleet.finished = race.boats.filter { $0.status == .finished }.count
        return fleet
    }

    /// A bot tacks by hand on skiff@8: through a start and a beat every boat's boom crosses head to wind, none sits
    /// in irons, and no tack/gybe tap is sent.
    @Test func botTacksThroughTheWindOnSkiffEight() throws {
        let fleet = try Self.fleet(seed: 459, seconds: 300)
        print("BOTHANDTACK fleet 300 s: tacks \(fleet.tacks) gybes \(fleet.gybes) stuck \(fleet.stuck.map { ($0 * 10).rounded() / 10 })")
        #expect(fleet.tacks.allSatisfy { $0 >= 1 }, "tacks by boat: \(fleet.tacks)")
        #expect(fleet.tacks.reduce(0, +) >= 3 * fleet.tacks.count, "tacks by boat: \(fleet.tacks)")
        #expect(fleet.stuck.allSatisfy { $0 <= 10 }, "seconds in irons by boat: \(fleet.stuck)")
        #expect(fleet.tackGybeTaps == 0)
    }

    /// And gybes: over a whole race every boat's boom crosses off the wind too, by her rudder alone, and the fleet finishes.
    @Test func botGybesThroughTheWindOnSkiffEight() throws {
        let fleet = try Self.fleet(seed: 459, seconds: 900)
        print("BOTHANDTACK fleet 900 s: tacks \(fleet.tacks) gybes \(fleet.gybes) stuck \(fleet.stuck.map { ($0 * 10).rounded() / 10 }) finished \(fleet.finished)")
        #expect(fleet.gybes.allSatisfy { $0 >= 1 }, "gybes by boat: \(fleet.gybes)")
        #expect(fleet.stuck.allSatisfy { $0 <= 10 }, "seconds in irons by boat: \(fleet.stuck)")
        #expect(fleet.tackGybeTaps == 0)
        // Six of eight when written (the finish window closes on two still on the last leg; seven or eight with
        // every handling at 1): the finish share is #461's gate, not this test's.
        #expect(fleet.finished >= fleet.tacks.count / 2, "\(fleet.finished) finished")
    }

    /// The cautious bot (#104) turns by hand too, at the floor of Club's handling: taking a boat over mid-race she
    /// tacks and gybes it on, her look before she leaps (`guarded`) never leaving her in irons through a turn.
    @Test func cautiousBotTurnsByHandOnSkiffEight() throws {
        for seed in UInt64(1)...3 {
            let fleet = try Self.fleet(seed: seed, seconds: 600, cautiousTakeover: true)
            print("BOTHANDTACK cautious seed \(seed): tacks \(fleet.tacks[0]) gybes \(fleet.gybes[0]) stuck \(fleet.stuck[0]) s")
            #expect(fleet.tacks[0] >= 2 && fleet.gybes[0] >= 1, "seed \(seed): \(fleet.tacks[0]) tacks, \(fleet.gybes[0]) gybes")
            #expect(fleet.stuck[0] <= 10, "seed \(seed): \(fleet.stuck[0]) s in irons")
            #expect(fleet.tackGybeTaps == 0)
        }
    }

    /// #459's named acceptance: with every bot's handling at the floor (0: below Club's band), no bot spends more
    /// than 10 s in irons.
    @Test func noBotSitsInIronsAtTheFloorDraw() throws {
        for seed in UInt64(1)...4 {
            let fleet = try Self.fleet(seed: seed, seconds: 600, handling: 0)
            print("BOTHANDTACK floor seed \(seed): tacks \(fleet.tacks) gybes \(fleet.gybes) stuck \(fleet.stuck.map { ($0 * 10).rounded() / 10 })")
            #expect(fleet.stuck.allSatisfy { $0 <= 10 }, "seed \(seed): seconds in irons by boat: \(fleet.stuck)")
            #expect(fleet.tackGybeTaps == 0)
        }
    }

    // MARK: - One bot, one turn

    /// A brain and her hand on the helm, paired as `BotDriver` pairs them, for a seat of a scripted race.
    struct Hand {
        let seat: Int
        var brain: BotBrain
        var helm = BotHelm()

        /// A skill-1 groove-only bot (the baseline, no weaknesses) that tacks or gybes only when told (`plannedTack`),
        /// turning by hand at `handling`.
        init(seat: Int, race: Race, handling: Double, seed: UInt64 = 1) {
            self.seat = seat
            brain = BotBrain(style: BotConductTests.skill1, profile: .baseline, seed: seed)
            brain.tactics.headerThreshold = nil
            brain.tactics.downwindShiftThreshold = nil
            brain.tactics.corridor = 100
            brain.turnHandling = handling
            brain.plannedTack = race.boats[seat].tack
            // She gybes onto no layline of her own accord: only when told.
            brain.laylineError = (race.boats[seat].legIndex, .pi / 3)
        }

        @discardableResult
        mutating func drive(_ race: Race) -> BotDecision? {
            guard (race.tick + seat).isMultiple(of: BotDriver.decisionInterval) else { return nil }
            let view = race.seatView(for: seat)
            var decision = brain.decide(helm.view(view))
            decision.input = helm.input(decision.input, view, tapping: decision.tap != nil, centred: decision.centred)
            race.apply(decision.input, seat: seat, atTick: race.tick + 1)
            if let tap = decision.tap { race.tap(tap, seat: seat, atTick: race.tick + 1) }
            return decision
        }
    }

    /// Seat 0 alone in open water on skiff@8, in her groove on `tack` at her target speed (beating, or `running`: then
    /// 25 m to the side her gybe sails from, since the race area there is some 75 m either side of the course's axis
    /// and a boat that meets its edge turns off it), seat 1 far off; `edit` the snapshot further.
    static func alone(seed: UInt64, running: Bool = false, tack: Tack = .starboard,
                      edit: (inout WorldSnapshot, BotConductTests.Water) -> Void = { _, _ in })
        throws -> (race: Race, water: BotConductTests.Water) {
        let water = BotConductTests.$waterClass.withValue(skiffEight.ref) { BotConductTests.Water(seed: seed, running: running) }
        let heading = running ? water.run(tack) : water.beat(tack)
        let speed = running ? water.down.speed : water.up.speed
        let race = try BotConductTests.place(water, [
            .init(position: water.centre + water.race.course.upwind.rightPerp * (running ? (tack == .starboard ? 25 : -25) : 0),
                  heading: heading, speed: speed),
            .init(position: water.centre + Vec2.heading(water.wind).rightPerp * 400, heading: heading, speed: speed),
        ]) { snapshot in
            // The start the water was stepped through may have left her a penalty: she owes none.
            snapshot.seats[0].boat.penaltyTurnsOwed = 0
            snapshot.seats[0].boat.penaltyProgress = 0
            snapshot.seats[0].boat.penaltyClockTick = nil
            edit(&snapshot, water)
        }
        return (race, water)
    }

    struct Turn {
        /// Hull lengths the twin that sailed on made good beyond her: to windward for a tack, to leeward for a gybe.
        var loss: Double
        var flubbed: Bool
        var stuck: Double
        var knots: Double
    }

    /// Seconds after she is told to turn that a tack's loss is read (the #458 harness's window), and a gybe's: she is
    /// through it in 2 to 4 s and most of the way back to speed, and a longer one has her reaching for the gate, which
    /// is close below this water (the whole of a gybe's cost, over 30 s, is `HandTurnProfileTests`').
    static let tackSeconds = 25.0
    static let gybeSeconds = 9.0

    /// One tack (or gybe) by a lone bot at `handling` on seed `seed`'s water, told to turn after 3 s in her groove,
    /// against a twin on the same water that sails on: the loss `tackSeconds` (`gybeSeconds`) after she is told.
    static func turn(gybe: Bool, handling: Double, seed: UInt64, brainSeed: UInt64, from tack: Tack) throws -> Turn {
        let (race, water) = try alone(seed: seed, running: gybe, tack: tack)
        let (twinRace, _) = try alone(seed: seed, running: gybe, tack: tack)
        var hand = Hand(seat: 0, race: race, handling: handling, seed: brainSeed)
        var twin = Hand(seat: 0, race: twinRace, handling: handling, seed: brainSeed)
        let along = Vec2.heading(water.wind) * (gybe ? -1 : 1)
        let noGo = BoatDynamics.noGoAngle(race.boatClass.polar)
        var turn = Turn(loss: 0, flubbed: false, stuck: 0, knots: knots(metresPerSecond: race.groundWind(at: water.centre).speed))
        var crossings = 0
        var boom = race.boats[0].boomSide
        let table = gybe ? HandTackTable.gybeFraction(handling: handling) : HandTackTable.tackFraction(handling: handling)
        for tick in 0..<Int((3 + (gybe ? gybeSeconds : tackSeconds)) * Double(Race.tickRate)) {
            if tick == 3 * Race.tickRate { hand.brain.plannedTack = tack.other }
            hand.drive(race)
            twin.drive(twinRace)
            if let started = hand.brain.handTurn, started.overSteer > 0 || started.fraction < table - 1e-9 { turn.flubbed = true }
            race.step()
            twinRace.step()
            let boat = race.boats[0]
            if boat.boomSide != boom { crossings += 1 }
            boom = boat.boomSide
            let wind = race.groundWind(at: boat.position)
            if abs(wrapAngle(wind.direction - boat.heading)) < noGo,
               boat.speed < 0.3 * race.boatClass.polar.bestUpwind(tws: wind.speed).speed { turn.stuck += Race.dt }
        }
        #expect(crossings == 1, "seed \(seed): her boom crossed \(crossings) times")
        #expect(twinRace.boats[0].tack == tack, "seed \(seed): the twin turned")
        turn.loss = (twinRace.boats[0].position - race.boats[0].position).dot(along) / water.length
        return turn
    }

    /// The mean loss, the share flubbed and the longest stuck of `handling`'s turns over 8 waters and 4 bot seeds each.
    static func turns(gybe: Bool, handling: Double) throws -> (loss: Double, flubbed: Double, stuck: Double, knots: Double) {
        var all: [Turn] = []
        for seed in UInt64(1)...8 {
            // From each tack in turn: what a shift gives the twin on one it takes from her on the other.
            for draw in UInt64(1)...4 {
                all.append(try turn(gybe: gybe, handling: handling, seed: seed, brainSeed: seed * 10 + draw,
                                    from: draw.isMultiple(of: 2) ? .port : .starboard))
            }
        }
        let n = Double(all.count)
        return (all.map(\.loss).reduce(0, +) / n, Double(all.filter(\.flubbed).count) / n, all.map(\.stuck).max()!,
                all.map(\.knots).reduce(0, +) / n)
    }

    /// A tack's quality follows the handling draw: the better her handling the less a tack costs her, and none
    /// stalls. The top draw's costs what the best hand tack does: 1.39 L in this water's 9 to 13 kn, the #458 harness's
    /// 75 % eased turn in a steady wind (1.33 L at 10 kn, 1.44 at 12; `HandTurnProfileTests`). #458's 0.97 is that
    /// turn's mean over its seven winds, six of them shifting under one tack; here each water is tacked from both
    /// tacks, so a shift's gain on one is its loss on the other.
    @Test func tackLossFallsWithHandlingOnSkiffEight() throws {
        let levels = [1.0, 0.7, 0.4, 0.1]
        let measured = try levels.map { try Self.turns(gybe: false, handling: $0) }
        for (h, m) in zip(levels, measured) {
            print("BOTHANDTACK tack h=\(h): loss \(m.loss) L, flubbed \(m.flubbed), stuck \(m.stuck) s, wind \(m.knots) kn")
        }
        let loss = measured.map(\.loss)
        #expect(loss[0] <= loss[1] + 0.02 && loss[1] <= loss[2] + 0.04, "\(loss)")
        #expect(loss[3] > loss[0] + 0.1, "\(loss)")
        #expect(abs(loss[0] - 1.39) <= 0.1, "the top draw's tack: \(loss[0]) L")
        #expect(measured[0].flubbed == 0)
        #expect(measured.allSatisfy { $0.stuck <= 5 })
    }

    /// And a gybe's: a good helm gybes gently, a poor one cranks it and loses the most.
    @Test func gybeLossFallsWithHandlingOnSkiffEight() throws {
        let levels = [1.0, 0.7, 0.4, 0.1]
        let measured = try levels.map { try Self.turns(gybe: true, handling: $0) }
        for (h, m) in zip(levels, measured) {
            print("BOTHANDTACK gybe h=\(h): loss \(m.loss) L, flubbed \(m.flubbed), wind \(m.knots) kn")
        }
        let loss = measured.map(\.loss)
        #expect(loss[0] <= loss[1] + 0.02 && loss[1] <= loss[2] + 0.04, "\(loss)")
        #expect(loss[3] > loss[0] + 0.3, "\(loss)")
        #expect(measured[0].flubbed == 0)
    }

    /// "Bear off to build speed": in light air, slow but fast enough to tack, a good helm bears away for 3 s before
    /// she puts the rudder over; a poor one, or anyone in a breeze, turns at once.
    @Test func goodHelmBearsOffFirstInLightAir() throws {
        /// Seat 0 beating on starboard at 80 % of her speed in light-and-patchy's wind, told to tack: whether she
        /// bore off first, how far, and the tack she ends on.
        func tack(seed: UInt64, handling: Double) throws -> (knots: Double, boreOff: Bool, furthest: Double, tack: Tack) {
            let conditions = try ConditionsFile.bundled(id: "light-and-patchy", version: 7)
            let venue = try VenueFile.bundled(id: "dev-venue", version: 7)
            let setup = try RaceSetup(raceSeed: RaceSeed(seed), seats: [.bot, .bot], laps: 2, startSequenceTicks: Race.tickRate,
                                      boatClass: Self.skiffEight.ref, venue: venue.ref, conditions: conditions.ref)
            let race = try Race(setup: setup, files: RaceFiles(resolving: setup),
                                mode: .authoritative(windSeed: WindSeed(seed &* 0x9E37_79B9_7F4A_7C15 &+ 1)))
            for _ in 0..<(2 * Race.tickRate) { race.step() }
            let course = race.course
            let centre = course.startLine.centre + course.upwind * (course.beat * 0.35)
            let wind = race.groundWind(at: centre)
            let up = race.boatClass.polar.bestUpwind(tws: wind.speed)
            var snapshot = race.exportSnapshot()
            for seat in 0...1 {
                snapshot.seats[seat].boat.position = centre + course.upwind.rightPerp * (Double(seat) * 400)
                snapshot.seats[seat].boat.heading = wind.direction - up.twa
                snapshot.seats[seat].boat.speed = up.speed * 0.8
                snapshot.seats[seat].boat.boomSide = .port
                snapshot.seats[seat].boat.status = .racing
                snapshot.seats[seat].boat.legIndex = 0
                snapshot.seats[seat].boat.roundingStage = 0
                snapshot.seats[seat].boat.rudder = 0
                snapshot.seats[seat].boat.penaltyTurnsOwed = 0
                snapshot.seats[seat].heldInput = .neutral
            }
            try race.importSnapshot(snapshot)
            var hand = Hand(seat: 0, race: race, handling: handling)
            hand.brain.plannedTack = .port
            var boreOff = false, furthest = 0.0
            for _ in 0..<(10 * Race.tickRate) {
                hand.drive(race)
                if hand.brain.handTurn?.bearOffUntil != nil { boreOff = true }
                race.step()
                let boat = race.boats[0]
                if boat.tack == .starboard {
                    furthest = max(furthest, abs(wrapAngle(race.groundWind(at: boat.position).direction - boat.heading)) - up.twa)
                }
            }
            return (knots(metresPerSecond: wind.speed), boreOff, furthest, race.boats[0].tack)
        }
        let light = try firstSeed(in: 1...40) { try tack(seed: $0, handling: 1).knots < 7 }
        let good = try tack(seed: light, handling: 1)
        #expect(good.boreOff && good.furthest > deg2rad(6), "\(good)")
        #expect(good.tack == .port, "she tacked after it")
        let poor = try tack(seed: light, handling: 0.6)
        #expect(!poor.boreOff && poor.furthest < deg2rad(3) && poor.tack == .port, "\(poor)")
        print("BOTHANDTACK bear-off seed \(light): \(good.knots) kn, bore off \(rad2deg(good.furthest))°")
    }

    // MARK: - Irons and penalty turns

    /// Stalled short of head to wind with the rudder held over, she lets it go, truly centred, and is sailing again
    /// in seconds; turning with way on she is left alone.
    @Test func stalledBotCentresItsRudder() throws {
        let (race, _) = try Self.alone(seed: 3) { snapshot, water in
            snapshot.seats[0].boat.heading = water.heading(.starboard, deg2rad(12))
            snapshot.seats[0].boat.speed = 0.05
        }
        var hand = Hand(seat: 0, race: race, handling: 0.5)
        // Mid-tack onto port, as she stalled.
        hand.brain.plannedTack = .port
        hand.brain.handTurn = BotBrain.HandTurn(isTack: true, toTack: .port, sign: 1, fraction: 0.5, ease: 0, overSteer: 0,
                                                started: race.time)
        var centred = 0, stuck = 0.0
        let noGo = BoatDynamics.noGoAngle(race.boatClass.polar)
        for _ in 0..<(20 * Race.tickRate) {
            if let decision = hand.drive(race), decision.centred {
                centred += 1
                #expect(decision.input.rudder == 0)
                #expect(hand.helm.held == nil)
            }
            race.step()
            let boat = race.boats[0]
            let wind = race.groundWind(at: boat.position)
            if abs(wrapAngle(wind.direction - boat.heading)) < noGo,
               boat.speed < 0.3 * race.boatClass.polar.bestUpwind(tws: wind.speed).speed { stuck += Race.dt }
        }
        #expect(centred > 0, "she never let the rudder go")
        #expect(stuck < 10, "\(stuck) s in irons")
        #expect(race.boats[0].speed > 0.5 * race.boatClass.polar.bestUpwind(tws: race.groundWind(at: race.boats[0].position).speed).speed)

        // With way on, a turn's rudder is hers to hold.
        let (sailing, _) = try Self.alone(seed: 3)
        var turning = Hand(seat: 0, race: sailing, handling: 1)
        turning.brain.plannedTack = .port
        for _ in 0..<(2 * Race.tickRate) {
            if let decision = turning.drive(sailing) { #expect(!decision.centred) }
            sailing.step()
        }
        #expect(sailing.boats[0].tack == .port)
        _ = centred
    }

    /// A bot owed a penalty turn on skiff@8 turns it, hard over as ever, inside its deadline: from her groove at
    /// speed, and from a stall short of head to wind 60° into it (she lets go, falls off, and turns it on the same way).
    @Test func penaltyTurnsAreCompletedOnSkiffEight() throws {
        for stalled in [false, true] {
            let (race, _) = try Self.alone(seed: 3) { snapshot, water in
                snapshot.seats[0].boat.penaltyTurnsOwed = 1
                snapshot.seats[0].boat.penaltyProgress = stalled ? deg2rad(60) : 0
                snapshot.seats[0].boat.penaltyClockTick = snapshot.tick
                guard stalled else { return }
                snapshot.seats[0].boat.heading = water.heading(.starboard, deg2rad(12))
                snapshot.seats[0].boat.speed = 0.05
            }
            var hand = Hand(seat: 0, race: race, handling: 0.5)
            if stalled { hand.brain.penaltyTurn = 1 }
            var kinds: [RaceEvent.Kind] = []
            var centred = 0
            for _ in 0..<(60 * Race.tickRate) where race.boats[0].penaltyTurnsOwed > 0 && race.boats[0].status == .racing {
                if hand.drive(race)?.centred == true { centred += 1 }
                race.step()
                kinds += race.drainEvents().map(\.kind)
            }
            print("BOTHANDTACK penalty stalled=\(stalled): served at \(race.time) s, centred decisions \(centred)")
            #expect(race.boats[0].penaltyTurnsOwed == 0 && race.boats[0].status == .racing,
                    "stalled \(stalled): owes \(race.boats[0].penaltyTurnsOwed), \(race.boats[0].status)")
            // Stalled, the hard-over rudder itself turns her back before she lets go (a standing boat falls off faster
            // than her rudder turns her, on every class): the race gives that turn up, and she turns it all again.
            let reset = kinds.contains { if case .penaltyReset = $0 { true } else { false } }
            #expect(stalled || !reset, "she gave the turn up")
            #expect(!stalled || centred > 0, "stalled, she never let the rudder go")
        }
    }
}
