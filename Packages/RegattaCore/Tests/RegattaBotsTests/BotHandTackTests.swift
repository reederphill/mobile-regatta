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

    /// Old classes sail the tap and the roll exactly as before #459: an all-bot race on skiff@7 (the default class until #461, the
    /// autohelm off, a roll tack) and on skiff@6 (the autohelm on), pinned on #458's tip before any bot code changed
    /// (re-pinned on #508, whose windward final approach every class sails; and on #517, whose circle round a boat
    /// taking a penalty is every class's before a tack or gybe: both races have boats turning one near a boat about to
    /// tack, whose tack the circle holds off first 13.9 s after the gun on skiff@7 and 10.9 s after it on skiff@6, and
    /// with the circle off both kept their digests).
    @Test(.onFiveRules) func skiffSevenBotsAreBitIdentical() throws {
        let seven = try Self.digest(seed: 459, boatClass: BoatClassFile.bundled(id: "skiff", version: 7))
        let six = try Self.digest(seed: 459, boatClass: BoatClassFile.bundled(id: "skiff", version: 6))
        #expect(hex64(seven) == "0xa14310d235ced195")
        #expect(hex64(six) == "0xb5f6b3e1a7f78b40")
    }

    /// And skiff@8, the default class until #462's switch, sails exactly as before #462's bots layer (every change there is behind "the
    /// class has the new planing rule", skiff@9's `stayOnSpeedShare` and `apparentWind`): all-bot races through the
    /// start and the first beat, and through two laps with their runs, pinned on #462's core tip before any bot code
    /// changed (re-pinned there on fleet-rules@6, #490's default, and on #508: the windward final approach and the lower
    /// tacking speed by hand near her mark are every class's; the two laps again on #509, whose hold of a turn refused
    /// near her mark is every class's too: the start and the first beat have none and kept their digest; the two laps
    /// again on #518, whose pick of the leeward gate's mark is every class's: the start and the first beat reach no gate
    /// and kept theirs; the two laps, seed 462, again on #517, whose circle round a boat taking a penalty is every
    /// class's before a tack or gybe: it holds a turn off first 18.8 s before the gun, and others up the first beat, and
    /// with the circle off they kept their digest; in the start and the first beat, seed 459, no circle holds any turn
    /// off, and they kept theirs; the two laps again on #523, whose gate pick range and exit tack are every class's: the start and the first beat reach no gate and kept theirs). On fleet-rules@6 since #517's default switch: the class is the test's subject, and on
    /// fleet-rules@7 the two laps have a 21.2 incident called as 16.1.
    @Test(.onSixRules) func skiffEightBotsAreBitIdentical() throws {
        let short = try Self.digest(seed: 459, boatClass: Self.skiffEight)
        let long = try Self.digest(seed: 462, boatClass: Self.skiffEight, seconds: 700)
        #expect(hex64(short) == "0x2f226740a8699d03")
        #expect(hex64(long) == "0x92df68b4d1064722")
    }

    // MARK: - skiff@8: tacks and gybes by hand

    static let skiffEight = try! BoatClassFile.bundled(id: "skiff", version: 8)

    /// What a fleet of bots made of a race on skiff@8.
    struct Fleet {
        /// Each boat's boom crossings with the wind forward of the beam (tacks) and abaft it (gybes), racing.
        var tacks: [Int]
        var gybes: [Int]
        /// Each boat's longest spell in irons, seconds: under 30 % of her close-hauled speed inside the no-go zone,
        /// owing no penalty turn; and owing one (`turnStuck`): slow, she turns it on through the wind rather than let
        /// go, which would give the turn up (#461).
        var stuck: [Double]
        var turnStuck: [Double]
        var tackGybeTaps: Int
        var finished: Int
    }

    /// An all-bot race on skiff@8 for `seconds`: the fleet's normal draw, or every bot's handling `handling`; seat 0
    /// the cautious bot's from a minute after the gun if `cautiousTakeover`.
    static func fleet(seed: UInt64, seconds: Int, handling: Double? = nil, cautiousTakeover: Bool = false,
                      boatClass: BoatClassFile = skiffEight) throws -> Fleet {
        let race = try BotHelmTests.race(seed: seed, boatClass: boatClass)
        var controllers = handling.map { handling in
            SeatControllers(race.boats.indices.map { seat in
                let skill = BotTier.mixedFleetDraw(seed: botSeed(raceSeed: race.setup.raceSeed, seat: seat)).skill
                return .bot(BotDriver(seat: seat, raceSeed: race.setup.raceSeed, skill: skill, handling: handling))
            })
        } ?? allBots(race)
        let count = race.boats.count
        var fleet = Fleet(tacks: Array(repeating: 0, count: count), gybes: Array(repeating: 0, count: count),
                          stuck: Array(repeating: 0, count: count), turnStuck: Array(repeating: 0, count: count),
                          tackGybeTaps: 0, finished: 0)
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
                if boat.penaltyTurnsOwed > 0 {
                    fleet.turnStuck[seat] = max(fleet.turnStuck[seat], spell[seat])
                } else {
                    fleet.stuck[seat] = max(fleet.stuck[seat], spell[seat])
                }
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
            print("BOTHANDTACK floor seed \(seed): tacks \(fleet.tacks) gybes \(fleet.gybes) stuck \(fleet.stuck.map { ($0 * 10).rounded() / 10 }) owing a turn \(fleet.turnStuck.map { ($0 * 10).rounded() / 10 })")
            #expect(fleet.stuck.allSatisfy { $0 <= 10 }, "seed \(seed): seconds in irons by boat: \(fleet.stuck)")
            // Owing a turn she turns on through the wind rather than let go: #459's 10 s holds there too since #461's
            // fall-off retune (the worst is 4.0 s, seed 2; 11.6 s before it, when a turn from a standstill crawled
            // through the wind at 3° a second).
            #expect(fleet.turnStuck.allSatisfy { $0 <= 10 }, "seed \(seed): seconds in irons owing a turn: \(fleet.turnStuck)")
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
            decision.input = helm.input(decision.input, view, tapping: decision.tap != nil, centred: decision.centred,
                                        holdsHerAngle: decision.holdsHerAngle)
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
    /// stalls. The top draw's costs what the best hand tack does: 1.37 L in this water's 9 to 13 kn, the #458 harness's
    /// 60 % eased turn in a steady wind (1.30 L at 10 kn; `HandTurnProfileTests`). #458's 0.95 is that turn's mean
    /// over its seven winds, six of them shifting under one tack; here each water is tacked from both tacks, so a
    /// shift's gain on one is its loss on the other. The floor of the fleet's draws slams it and flubs half: 2.2 L.
    @Test func tackLossFallsWithHandlingOnSkiffEight() throws {
        let levels = [1.0, 0.7, 0.4, 0.1]
        let measured = try levels.map { try Self.turns(gybe: false, handling: $0) }
        for (h, m) in zip(levels, measured) {
            print("BOTHANDTACK tack h=\(h): loss \(m.loss) L, flubbed \(m.flubbed), stuck \(m.stuck) s, wind \(m.knots) kn")
        }
        let loss = measured.map(\.loss)
        #expect(loss[0] <= loss[1] + 0.02 && loss[1] <= loss[2] + 0.04, "\(loss)")
        #expect(loss[3] > loss[0] + 0.4, "\(loss)")
        #expect(abs(loss[0] - 1.37) <= 0.1, "the top draw's tack: \(loss[0]) L")
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
        // Mid-tack onto port, as she stalled: on a fifth of the rudder, which the fall-off holds at a standstill since
        // #461's retune (2°/s against the floor's 8; half rudder, which stalled her before it, now turns her through).
        hand.brain.plannedTack = .port
        hand.brain.handTurn = BotBrain.HandTurn(isTack: true, toTack: .port, sign: 1, fraction: 0.2, ease: 0, overSteer: 0,
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

    /// A bot owed a penalty turn on skiff@8 turns it, at 70 % rudder (`HandTackTable.penaltyFraction`), inside its
    /// deadline: from her groove at speed, and from a stall short of head to wind 60° into it (she puts the rudder
    /// hard over and turns on through the wind without letting go, #461: a let-go there falls her back, and on a
    /// class without the autohelm that gives the turn up).
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
            let reset = kinds.contains { if case .penaltyReset = $0 { true } else { false } }
            // Stalled, the scene's first ticks fall her back before her rudder is over: that one turn is given up.
            #expect(stalled || !reset, "she gave the turn up")
            #expect(centred == 0, "stalled \(stalled): she let the rudder go")
            #expect(race.time < (stalled ? 20 : 14), "stalled \(stalled): served at \(race.time) s")
        }
    }

    /// Stalled short of head to wind owing a turn she has not begun, with its start deadline close (#471): she lets
    /// the rudder go for steerage only until `penaltyStartMargin` before the deadline, then turns with what way she
    /// has, and is not disqualified. Waiting on centred (for steerage, or `HandTackTable.stallWait`), a National boat
    /// held off her turn by the committee boat and luffed into irons keeping clear sat through her start deadline.
    @Test(.onFiveRules) func stalledOwingATurnSheTurnsBeforeItsStartDeadline() throws {
        let toStart = 7.0
        let penalty = try Self.alone(seed: 3).race.rules.raceFormat.penalty
        let (race, _) = try Self.alone(seed: 3) { snapshot, water in
            snapshot.seats[0].boat.penaltyTurnsOwed = 1
            snapshot.seats[0].boat.penaltyProgress = 0
            snapshot.seats[0].boat.penaltyClockTick = snapshot.tick - RulesConfig.ticks(penalty.start - toStart)
            snapshot.seats[0].boat.heading = water.heading(.starboard, deg2rad(12))
            snapshot.seats[0].boat.speed = 0.05
        }
        var hand = Hand(seat: 0, race: race, handling: 0.5)
        let from = race.time
        // As she stalled, the turn not begun (held off for a mark): the rudder let go already.
        hand.brain.stall.centredSince = from
        var centredLate = 0, centred = 0
        var kinds: [RaceEvent.Kind] = []
        for _ in 0..<(45 * Race.tickRate) where race.boats[0].penaltyTurnsOwed > 0 && race.boats[0].status == .racing {
            if hand.drive(race)?.centred == true {
                centred += 1
                if race.time - from > toStart - BotBrain.penaltyStartMargin + 0.5 { centredLate += 1 }
            }
            race.step()
            kinds += race.drainEvents().map(\.kind)
        }
        print("BOTHANDTACK stalled owing a turn: \(race.boats[0].status), owes \(race.boats[0].penaltyTurnsOwed) at \(race.time - from) s, centred \(centred)")
        #expect(centred > 0, "she never let the rudder go: the scene is not the stall")
        #expect(centredLate == 0, "she let the rudder go inside her start margin")
        #expect(!kinds.contains { if case .disqualified = $0 { true } else { false } }, "disqualified: \(race.boats[0].status)")
        #expect(race.boats[0].penaltyTurnsOwed == 0 && race.boats[0].status == .racing)
    }

    /// A mark close aboard holds a penalty turn by hand off only while the turn itself still fits its complete
    /// deadline (`markHoldLeavesTheTurn`, #471): in light air the turn is longer than the 26 s the start margin leaves.
    @Test(.onFiveRules) func aMarkHoldsHerTurnOffOnlyWhileTheTurnFits() throws {
        /// Whether the hold still stands with `slack` seconds more than the hold must leave her to its complete deadline.
        func holds(slack: Double) throws -> Bool {
            let (probe, _) = try Self.alone(seed: 3)
            let own = probe.seatView(for: 0)
            let seconds = Hand(seat: 0, race: probe, handling: 0.5).brain.penaltyTurnSeconds(own.own, own)
            let (race, _) = try Self.alone(seed: 3) { snapshot, _ in
                snapshot.seats[0].boat.penaltyTurnsOwed = 1
                snapshot.seats[0].boat.penaltyClockTick = snapshot.tick
                    - RulesConfig.ticks(probe.rules.raceFormat.penalty.complete - seconds + HandTackTable.penaltyMarkHoldShort - slack)
            }
            let view = race.seatView(for: 0)
            return Hand(seat: 0, race: race, handling: 0.5).brain.markHoldLeavesTheTurn(try #require(view.own.penalty), view.own, view)
        }
        #expect(try holds(slack: 1))
        #expect(try !holds(slack: -1))
    }

    /// #488 acceptance: under fleet-rules@6 a penalty turn's time is reckoned from the crossings it has left, the way it
    /// turns, from her wind angle and side (`BotBrain.penaltyTurnAngle`), not a whole circle: from close-hauled, luffing
    /// first is about 225° (the tack at her wind angle, the gybe half a circle on), bearing away first about 315°; from a
    /// run, gybing first is shorter; with one crossing made, only the other's angle is left. Seconds: that angle at the
    /// turn's rate (`penaltyTurnSeconds`' reckoning), and the crawl through the wind only while the tack is to come.
    @Test(.onSixRules) func penaltyTurnSecondsFromTheCrossingsLeft() throws {
        let angle = BotBrain.penaltyTurnAngle
        let closeHauled = deg2rad(45), run = deg2rad(160)
        func degrees(_ radians: Double) -> Double { (rad2deg(radians) * 1e6).rounded() / 1e6 }
        #expect(degrees(angle(closeHauled, true, true, true)) == 225)
        #expect(degrees(angle(closeHauled, false, true, true)) == 315)
        #expect(degrees(angle(run, false, true, true)) == 200)
        #expect(degrees(angle(run, true, true, true)) == 340)
        #expect(angle(run, false, true, true) < angle(run, true, true, true), "from a run, gybing first is shorter")
        // Tacked, bearing away to the gybe; gybed, luffing to the tack.
        #expect(degrees(angle(deg2rad(40), false, false, true)) == 140)
        #expect(degrees(angle(deg2rad(150), true, true, false)) == 150)
        #expect(angle(closeHauled, true, false, false) == 0)

        let (race, _) = try Self.alone(seed: 3) { snapshot, _ in
            snapshot.seats[0].boat.penaltyTurnsOwed = 1
            snapshot.seats[0].boat.penaltyClockTick = snapshot.tick
        }
        #expect(race.rules.raceFormat.penalty.turn == .tackAndGybe)
        let view = race.seatView(for: 0)
        let b = view.own
        let owed = try #require(b.penalty)
        let brain = Hand(seat: 0, race: race, handling: 0.5).brain
        let speed = brain.closeHauledSpeed(b, view) * HandTackTable.penaltyTurn.speed
        let rate = HandTackTable.penaltyFraction * view.boatClass.steering.turnRate(speed: speed)
        let luff: Double = b.relativeWind > 0 ? 1 : -1
        let crawl = HandTackTable.penaltyTurn.crawl
        let luffing = angle(b.twa, true, true, true), bearingAway = angle(b.twa, false, true, true)
        #expect(abs(brain.penaltyTurnSeconds(b, view, owed, direction: luff) - (luffing / rate + crawl)) < 1e-9)
        #expect(abs(brain.penaltyTurnSeconds(b, view, owed, direction: -luff) - (bearingAway / rate + crawl)) < 1e-9)
        #expect(brain.penaltyTurnSeconds(b, view, owed, direction: luff) < brain.penaltyTurnSeconds(b, view),
                "luffing first from close-hauled is shorter than the whole circle")
        // Tacked already, that way: the gybe is all that is left, and no crawl.
        let tacked = OwedPenalty(turnsOwed: 1, startDeadlineTick: owed.completeDeadlineTick,
                                 completeDeadlineTick: owed.completeDeadlineTick, progress: 0, isStarted: true,
                                 hasTacked: true, direction: Int(-luff))
        #expect(abs(brain.penaltyTurnSeconds(b, view, tacked, direction: -luff) - angle(b.twa, false, false, true) / rate) < 1e-9)
        // The other way from a turn under way (a recross): both crossings again.
        #expect(abs(brain.penaltyTurnSeconds(b, view, tacked, direction: luff) - (luffing / rate + crawl)) < 1e-9)
    }

    /// #508 acceptance: within `PlaningTable.markRange` of her mark a bot that turns by hand tacks from
    /// `nearMarkTackingSpeed` of her close-hauled speed, not `tackingSpeed`; away from her mark, and for a tap's tack
    /// anywhere, the floor is as it was.
    @Test func tacksFromLowerSpeedNearHerMarkOnly() throws {
        #expect(BotBrain.nearMarkTackingSpeed == 0.55 && BotBrain.tackingSpeed == 0.75)
        /// Whether a bot beating in open water at `share` of her close-hauled speed can tack: by hand or by the tap,
        /// near her mark or not.
        func tacks(share: Double, byHand: Bool, nearHerMark: Bool,
                   pose: @escaping (inout WorldSnapshot) -> Void = { _ in }) throws -> Bool {
            let (probe, _) = try Self.alone(seed: 3) { snapshot, _ in pose(&snapshot) }
            let own = probe.seatView(for: 0)
            let closeHauled = Hand(seat: 0, race: probe, handling: 0.5).brain.closeHauledSpeed(own.own, own)
            let (race, _) = try Self.alone(seed: 3) { snapshot, _ in
                snapshot.seats[0].boat.speed = closeHauled * share
                pose(&snapshot)
            }
            var hand = Hand(seat: 0, race: race, handling: 0.5)
            let view = race.seatView(for: 0)
            try #require(abs(view.own.speed - hand.brain.closeHauledSpeed(view.own, view) * share) < 0.01)
            hand.brain.isNearHerMark = nearHerMark
            return hand.brain.canTap(view.own, view, byHand: byHand)
        }
        for nearHerMark in [false, true] {
            for byHand in [false, true] {
                let lower = byHand && nearHerMark
                #expect(try tacks(share: 0.8, byHand: byHand, nearHerMark: nearHerMark))
                #expect(try tacks(share: 0.65, byHand: byHand, nearHerMark: nearHerMark) == lower,
                        "by hand \(byHand), near her mark \(nearHerMark)")
                #expect(try !tacks(share: 0.5, byHand: byHand, nearHerMark: nearHerMark))
            }
        }

        // Only at a mark or gate of her course (#471's start first, then turn): before her start, returning to it and
        // on the finish leg `isNearHerMark` is a point of her start or the line, and her hand tack keeps the 0.75.
        let finishLeg = try #require(Self.alone(seed: 3).race.course.legs.lastIndex { if case .finish = $0 { true } else { false } })
        let elsewhere: [(String, (inout WorldSnapshot) -> Void)] = [
            ("before her start", { $0.seats[0].boat.status = .prestart }),
            ("returning to her start", { $0.seats[0].boat.status = .ocs }),
            ("on the finish leg", { $0.seats[0].boat.legIndex = finishLeg }),
        ]
        for (name, pose) in elsewhere {
            #expect(try tacks(share: 0.8, byHand: true, nearHerMark: true, pose: pose), "\(name)")
            #expect(try !tacks(share: 0.65, byHand: true, nearHerMark: true, pose: pose), "\(name)")
        }

        // At the helm: slow on port on the windward mark's final approach, her starboard board clear of it, she puts
        // the helm down by hand on the default class; on a class whose tap sails the tack she waits for her speed.
        let hand = try BotNavigationTests.finalApproach(tack: .port, over: 4, speedShare: 0.65)
        var view = hand.view
        try #require(BotBrain.turnsByHand(view))
        var brain = hand.brain
        _ = brain.decide(view)
        #expect(brain.plannedTack == .starboard && brain.handTurn != nil)

        let tap = try BotConductTests.$waterClass.withValue(BotHelmTests.autohelmOn().ref) {
            try BotNavigationTests.finalApproach(tack: .port, over: 4, speedShare: 0.65)
        }
        view = tap.view
        try #require(!BotBrain.turnsByHand(view))
        brain = tap.brain
        let decision = brain.decide(view)
        #expect(brain.plannedTack == .starboard && decision.tap == nil)
        // The tap is hers at speed: only the floor held it.
        let fast = try BotConductTests.$waterClass.withValue(BotHelmTests.autohelmOn().ref) {
            try BotNavigationTests.finalApproach(tack: .port, over: 4)
        }
        brain = fast.brain
        #expect(brain.decide(fast.view).tap == .tackGybe)
    }
}
