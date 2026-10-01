import Testing
import RegattaCore
@testable import RegattaBots

/// #104: a bot takes a seat over at any tick, from wherever the boat is (#19): mid-tack, mid-penalty, OCS, in irons,
/// on the race area's edge, or wherever a player's random helming left her. She rebuilds her plan from the seat's
/// view alone (`BotBrain.adopt`) and sails on.
@Suite struct BotTakeoverTests {
    /// Placeholders (#104, tuned by #105): seconds after the takeover by which she is out of irons, and the share of
    /// takeovers that must be.
    static let ironsDeadline = 10.0
    static let ironsPassShare = 0.95
    /// Seconds she sails after the takeover.
    static let sailSeconds = 30.0
    /// A boat slower than this, pointing inside the no-go zone and turning no penalty, is in irons: the bot suite's
    /// definition (`BotRaceHarness.ironsSpeed`).
    static let ironsSpeed = 0.5

    /// Where the boat is when the bot takes her.
    enum Situation: String, CaseIterable {
        /// A player helmed her at random, from the start sequence to somewhere in the race.
        case helmedAtRandom
        /// Head to wind, stopped.
        case irons
        /// Part way through a tack or gybe the autohelm is sailing for her tap.
        case midTack
        /// Part way through a penalty turn, the rudder held hard over or let go.
        case midPenalty
        /// Over the line at the gun.
        case ocs
        /// Close to the race area's edge, sailing at it.
        case edge
    }

    /// A race of `fleetSize` with seat 0 the player's, and the others the fleet's bots.
    static func race(seed: UInt64, fleetSize: Int = 6) -> Race {
        botRace(seats: [.human] + Array(repeating: .bot, count: fleetSize - 1), laps: 1, prestartSeconds: 30, seed: seed)
    }

    static func fleet(_ race: Race) -> SeatControllers {
        SeatControllers([.human] + (1..<race.boats.count).map { .bot(BotDriver(seat: $0, raceSeed: race.setup.raceSeed)) })
    }

    /// Sails `race` to the moment of the takeover in `situation`, with seat 0 helmed by a bot (or at random) and then
    /// put there; returns the controllers, seat 0 human, ready for the takeover between steps.
    static func setUp(_ race: Race, _ situation: Situation, seed: UInt64) throws -> SeatControllers {
        var controllers = fleet(race)
        var rng = SplitMix64(seed: seed, stream: 104)
        let racingSeconds = rng.range(10, 60)
        if situation == .helmedAtRandom {
            let until = rng.bool() ? Int(rng.range(-20, -2) * Double(Race.tickRate)) : Int(racingSeconds) * Race.tickRate
            var step = 0
            sail(race, &controllers, ticks: until - race.tick) { race in
                if step % 45 == 0 {
                    race.apply(BoatInput(rudder: Int8(rng.int(in: -100...100)), ease: rng.bool()), seat: 0, atTick: race.tick + 1)
                }
                step += 1
            }
            return controllers
        }
        // Seat 0 sails as one of the fleet's bots up to the moment.
        controllers[0] = .bot(BotDriver(seat: 0, raceSeed: race.setup.raceSeed))
        let moment = situation == .ocs ? -Race.tickRate : Int(racingSeconds) * Race.tickRate
        sail(race, &controllers, ticks: moment - race.tick)
        controllers.handBack(seat: 0)
        race.apply(.neutral, seat: 0, atTick: race.tick + 1)
        var snapshot = race.exportSnapshot()
        let wind = race.boats[0].windDirection
        switch situation {
        case .helmedAtRandom:
            break
        case .irons:
            snapshot.seats[0].boat.heading = wind + deg2rad(rng.range(-15, 15))
            snapshot.seats[0].boat.speed = rng.range(0, 0.3)
            snapshot.seats[0].boat.autohelm = nil
            snapshot.seats[0].boat.rudder = 0
            snapshot.seats[0].boat.desiredRudder = 0
        case .midTack:
            break
        case .midPenalty:
            if snapshot.seats[0].boat.penaltyTurnsOwed == 0 {
                snapshot.seats[0].boat.penaltyTurnsOwed = 1
                snapshot.seats[0].boat.penaltyClockTick = race.tick
            }
            snapshot.seats[0].boat.penaltyProgress = 0
        case .ocs:
            let line = race.course.startLine
            let position = race.boats[0].position
            snapshot.seats[0].boat.position = position + race.course.upwind * (rng.range(1, 6) - line.side(position))
            snapshot.seats[0].boat.heading = wind - deg2rad(45)
            snapshot.seats[0].boat.boomSide = .port
            snapshot.seats[0].boat.speed = 3
        case .edge:
            // Sailing at the race area's edge, a little inside it.
            let bearing = rng.range(-.pi, .pi)
            var p = race.boats[0].position
            while race.course.isInRaceArea(p + Vec2.heading(bearing) * 15) { p = p + Vec2.heading(bearing) * 5 }
            snapshot.seats[0].boat.position = p
            snapshot.seats[0].boat.heading = bearing
            snapshot.seats[0].boat.boomSide = wrapAngle(wind - bearing) >= 0 ? .port : .starboard
            snapshot.seats[0].boat.autohelm = nil
            snapshot.seats[0].boat.speed = 3
        }
        try race.importSnapshot(snapshot)
        switch situation {
        case .midTack:
            race.tap(.tackGybe, seat: 0, atTick: race.tick + 1)
            sail(race, &controllers, ticks: rng.int(in: 3...30))
        case .midPenalty:
            // Hard over one way into the turn, then perhaps let go.
            let way: Int8 = rng.bool() ? 100 : -100
            race.apply(BoatInput(rudder: way), seat: 0, atTick: race.tick + 1)
            sail(race, &controllers, ticks: rng.int(in: 30...150))
            if rng.bool() {
                race.apply(.neutral, seat: 0, atTick: race.tick + 1)
                sail(race, &controllers, ticks: rng.int(in: 1...20))
            }
        case .ocs:
            sail(race, &controllers, ticks: 2 * Race.tickRate)
        default:
            sail(race, &controllers, ticks: 1)
        }
        return controllers
    }

    /// The situations, 34 seeds of each: 204 takeovers.
    static let cases: [(Situation, UInt64)] = Situation.allCases.flatMap { situation in (1...34).map { (situation, UInt64($0)) } }

    /// #104 acceptance: a cautious bot taking a seat over leaves irons: from 200 snapshots of a boat anywhere, in ≥ 95 %
    /// (`ironsPassShare`) she is never in irons (the bot suite's definition) from `ironsDeadline` seconds after the
    /// takeover on.
    @Test func takeoverFrom200SnapshotsLeavesIrons() throws {
        var failures: [String] = []
        for (situation, seed) in Self.cases {
            let race = Self.race(seed: seed)
            var controllers = try Self.setUp(race, situation, seed: seed)
            let noGo = BoatDynamics.noGoAngle(race.boatClass.polar)
            controllers.takeOver(seat: 0, raceSeed: race.setup.raceSeed, cautious: true)
            let takeover = race.tick
            var irons = 0
            sail(race, &controllers, ticks: Int(Self.sailSeconds) * Race.tickRate) { race in
                let boat = race.boats[0]
                guard race.tick - takeover > Int(Self.ironsDeadline) * Race.tickRate, boat.isOnCourse else { return }
                if !boat.isTakingPenalty && boat.twa < noGo && boat.speed < Self.ironsSpeed { irons += 1 }
            }
            if irons > 0 { failures.append("\(situation.rawValue) seed \(seed) at tick \(takeover): \(irons) ticks in irons") }
        }
        let share = 1 - Double(failures.count) / Double(Self.cases.count)
        #expect(Self.cases.count >= 200)
        #expect(share >= Self.ironsPassShare, "\(share): \(failures.joined(separator: "\n"))")
    }

    /// Metres from any other boat at which she has the water to herself for a few seconds.
    static let clearWater = 60.0

    /// A cautious bot taking over part way into a penalty turn turns it on the way it was turning (`BotBrain.adopt`):
    /// turning it back would reset it (`.penaltyReset`), losing the player's turn. In clear water (`clearWater` from
    /// the one other boat): near a boat she still gives a turn up to keep clear of it (rule 21.2,
    /// `BotBrain.penaltyInput`), which resets it.
    @Test func takeoverMidPenaltyTurnsOnTheSameWay() throws {
        var resets: [UInt64] = []
        var started = 0
        for seed: UInt64 in 1...60 {
            let race = Self.race(seed: seed, fleetSize: 2)
            var controllers = try Self.setUp(race, .midPenalty, seed: seed)
            _ = race.drainEvents()
            guard race.boats[0].penaltyTurnsOwed > 0, abs(race.boats[0].penaltyProgress) > deg2rad(10),
                  (race.boats[1].position - race.boats[0].position).length > Self.clearWater else { continue }
            started += 1
            controllers.takeOver(seat: 0, raceSeed: race.setup.raceSeed, cautious: true)
            var events: [RaceEvent.Kind] = []
            sail(race, &controllers, ticks: 5 * Race.tickRate) { race in events += race.drainEvents().map(\.kind) }
            if events.contains(.penaltyReset(seat: 0)) { resets.append(seed) }
        }
        #expect(started >= 20, "\(started) takeovers part way into a turn")
        #expect(resets.isEmpty, "turned back, resetting the turn: seeds \(resets)")
    }

    /// The fleet's drivers are bit-identical: a driver only adopts when it takes a seat over (`takingOver()`), and only
    /// the cautious bot is cautious.
    @Test func onlyTakeoversAdoptAndOnlyTheCautiousBotIsCautious() {
        let seed = RaceSeed(7)
        #expect(!BotDriver(seat: 2, raceSeed: seed).isCautious)
        #expect(BotDriver.cautious(seat: 2, raceSeed: seed).isCautious)
        let cautious = BotDriver.cautious(seat: 2, raceSeed: seed).style
        #expect(cautious.skill == BotTier.club.skillBand.lowerBound)
        #expect(cautious.engagement == 0, "never attacks")
        var controllers = SeatControllers([.human, .human])
        controllers.takeOver(seat: 1, raceSeed: seed, cautious: true)
        guard case .dropped(let dropped) = controllers[1] else { Issue.record("cautious takeover is .dropped"); return }
        #expect(dropped.isCautious)
        controllers.takeOver(seat: 1, raceSeed: seed, cautious: false)
        guard case .bot(let fleet) = controllers[1] else { Issue.record("fleet-draw takeover is .bot"); return }
        #expect(!fleet.isCautious)
        #expect(fleet.style == BotDriver(seat: 1, raceSeed: seed).style, "at the fleet's normal draw")
        controllers.handBack(seat: 1)
        #expect(controllers[1].isHuman)
    }
}
