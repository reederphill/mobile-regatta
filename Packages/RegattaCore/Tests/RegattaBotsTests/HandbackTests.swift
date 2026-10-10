import Testing
import RegattaCore
@testable import RegattaBots

/// #104: a dropped player takes their boat back (CONTEXT.md **Handback**): the seat swaps from the cautious bot to the
/// player between steps (`SeatControllers.handBack`), and the boat keeps everything the race holds for her.
@Suite struct HandbackTests {
    static func race(seed: UInt64, fleetSize: Int = 4, boatClass: FileRef = BotConductTests.waterClass) -> Race {
        botRace(seats: [.human] + Array(repeating: .bot, count: fleetSize - 1), laps: 1, prestartSeconds: 30, seed: seed, boatClass: boatClass)
    }

    static func fleet(_ race: Race) -> SeatControllers {
        SeatControllers([.human] + (1..<race.boats.count).map { .bot(BotDriver(seat: $0, raceSeed: race.setup.raceSeed)) })
    }

    /// The held inputs the race applied for `seat` after `tick`, in order.
    static func applied(_ race: Race, seat: Int, after tick: Int) throws -> [InputRecord] {
        try #require(race.log).inputs.filter { $0.seat == seat && $0.tick > tick }
    }

    /// #104 acceptance: handback preserves the boat's state and the player's inputs apply from the next tick.
    /// - Mid-penalty: the player turns part of a penalty turn, drops, the cautious bot turns on, the player takes the
    ///   boat back and turns on. The turn's progress never falls (no `.penaltyReset`) through takeover and handback, and
    ///   the first input applied for the seat after the handback is the player's, on the next tick.
    /// - Autohelm target (#219: handback preserves it, rather than asking the player to tap the autopilot): the bot
    ///   sailing on the autohelm with the rudder centred, the player takes the boat back sending a centred rudder too;
    ///   the target is the one the bot left until the player steers, and the player's rudder takes the helm on the
    ///   tick after they send it.
    @Test func handbackKeepsPenaltyProgressAndAutohelmTarget() throws {
        var penaltyHandbacks = 0, autohelmHandbacks = 0
        for seed: UInt64 in 1...16 {
            if try Self.penaltyHandback(seed: seed) { penaltyHandbacks += 1 }
            if try Self.autohelmHandback(seed: seed) { autohelmHandbacks += 1 }
        }
        #expect(penaltyHandbacks >= 6, "\(penaltyHandbacks) mid-penalty handbacks")
        #expect(autohelmHandbacks == 16)
    }

    /// Mid-penalty handback on `seed`; false if the scenario didn't arise (the turn served, or a boat near her).
    static func penaltyHandback(seed: UInt64) throws -> Bool {
        // One other boat, so she has the water to herself more often.
        let race = Self.race(seed: seed, fleetSize: 2)
        var controllers = Self.fleet(race)
        controllers[0] = .bot(BotDriver(seat: 0, raceSeed: race.setup.raceSeed))
        sail(race, &controllers, ticks: 40 * Race.tickRate - race.tick)
        controllers.handBack(seat: 0)
        var snapshot = race.exportSnapshot()
        if snapshot.seats[0].boat.penaltyTurnsOwed == 0 {
            snapshot.seats[0].boat.penaltyTurnsOwed = 1
            snapshot.seats[0].boat.penaltyClockTick = race.tick
        }
        snapshot.seats[0].boat.penaltyProgress = 0
        try race.importSnapshot(snapshot)
        let way: Int8 = seed.isMultiple(of: 2) ? 100 : -100
        race.apply(BoatInput(rudder: way), seat: 0, atTick: race.tick + 1)
        var events: [RaceEvent.Kind] = []
        func record(_ race: Race) {
            events += race.drainEvents().map(\.kind)
        }
        // The player turns into it (from wherever the bot left the rudder: a reset of the player's own doesn't count).
        sail(race, &controllers, ticks: 2 * Race.tickRate)
        record(race)
        events = []
        // In clear water: near a boat she would give the turn up to keep clear of it (rule 21.2), which resets it.
        guard race.boats[0].penaltyTurnsOwed > 0,
              race.boats.dropFirst().allSatisfy({ ($0.position - race.boats[0].position).length > BotTakeoverTests.clearWater })
        else { return false }
        let progressAtDrop = abs(race.boats[0].penaltyProgress)
        #expect(progressAtDrop > deg2rad(30), "seed \(seed): \(rad2deg(progressAtDrop))° into the turn at the drop")
        controllers.takeOver(seat: 0, raceSeed: race.setup.raceSeed, cautious: true)
        let owed = race.boats[0].penaltyTurnsOwed
        // The bot turns on for a second; the turn served or not, its progress never falls on its own.
        var previous = progressAtDrop
        var fell = false
        for _ in 0..<Race.tickRate where race.boats[0].penaltyTurnsOwed == owed {
            controllers.drive(race)
            race.step()
            record(race)
            let now = abs(race.boats[0].penaltyProgress)
            if race.boats[0].penaltyTurnsOwed == owed, now < previous - 1e-9 { fell = true }
            previous = now
        }
        guard race.boats[0].penaltyTurnsOwed == owed else { return false }
        #expect(!fell, "seed \(seed): the bot turned the penalty back")
        // Handback between steps, mid-turn.
        controllers.handBack(seat: 0)
        let handback = race.tick
        let progressAtHandback = abs(race.boats[0].penaltyProgress)
        let sign = race.boats[0].penaltyProgress > 0 ? 1.0 : -1.0
        let player = BoatInput(rudder: Int8(90 * sign))
        race.apply(player, seat: 0, atTick: race.tick + 1)
        sail(race, &controllers, ticks: 1) { _ in }
        record(race)
        let after = try Self.applied(race, seat: 0, after: handback)
        #expect(after.first == InputRecord(tick: handback + 1, seat: 0, kind: .held(player)),
                "seed \(seed): first input applied after the handback \(String(describing: after.first))")
        #expect(race.heldInputs[0] == player)
        if race.boats[0].penaltyTurnsOwed == owed {
            #expect(abs(race.boats[0].penaltyProgress) >= progressAtHandback, "seed \(seed): turn fell at the handback")
        }
        #expect(!events.contains(.penaltyReset(seat: 0)), "seed \(seed): the turn was reset")
        return true
    }

    /// Autohelm-target handback on `seed`.
    static func autohelmHandback(seed: UInt64) throws -> Bool {
        let race = try Self.race(seed: seed, boatClass: BotHelmTests.autohelmOn().ref) // skiff@6: the autohelm target is the subject (#437)
        var controllers = Self.fleet(race)
        controllers.takeOver(seat: 0, raceSeed: race.setup.raceSeed, cautious: true)
        sail(race, &controllers, ticks: 30 * Race.tickRate - race.tick)
        // On to a step after which she is on the autohelm, rudder centred, no tap under way, owing nothing.
        var steps = 0
        while steps < 30 * Race.tickRate, !(race.heldInputs[0].rudder == 0 && race.boats[0].autohelm?.isTapping == false
                                           && race.boats[0].penaltyTurnsOwed == 0) {
            sail(race, &controllers, ticks: 1)
            steps += 1
        }
        let target = try #require(race.boats[0].autohelm?.target, "seed \(seed): never on the autohelm")
        controllers.handBack(seat: 0)
        let handback = race.tick
        // The player sends a centred rudder, as the bot held: nothing changes, and the target holds.
        race.apply(BoatInput(rudder: 0 as Int8, ease: race.heldInputs[0].ease), seat: 0, atTick: race.tick + 1)
        sail(race, &controllers, ticks: 2 * Race.tickRate)
        #expect(race.boats[0].autohelm?.target == target, "seed \(seed): target \(String(describing: race.boats[0].autohelm?.target)) after the handback, was \(target)")
        #expect(try Self.applied(race, seat: 0, after: handback).isEmpty, "seed \(seed): no input applied but the player's")
        // The player steers: the rudder takes the helm on the next tick, not before.
        let steer = race.tick
        race.apply(BoatInput(rudder: 60 as Int8), seat: 0, atTick: race.tick + 1)
        #expect(race.boats[0].autohelm?.target == target)
        sail(race, &controllers, ticks: 1)
        #expect(race.boats[0].autohelm == nil, "seed \(seed): the player's rudder has the helm")
        #expect(try Self.applied(race, seat: 0, after: steer).first?.tick == steer + 1)
        return true
    }

    /// #219 (comment): a dropped seat with a centred rudder holds its wind angle on the autohelm, not its heading.
    /// Between the drop and the bot taking over (#18's hold), the player's last held input stays; centred, the
    /// autohelm keeps her sailing angle to the wind wherever the wind goes, turning with it.
    @Test func aDroppedSeatWithACentredRudderHoldsItsWindAngle() throws {
        for seed: UInt64 in 1...6 {
            let race = try Self.race(seed: seed, boatClass: BotHelmTests.autohelmOn().ref) // skiff@6: the autohelm is the subject (#437)
            var controllers = Self.fleet(race)
            controllers.takeOver(seat: 0, raceSeed: race.setup.raceSeed, cautious: true)
            sail(race, &controllers, ticks: 40 * Race.tickRate - race.tick)
            // The player drops: held input centred, no controller sends anything for the seat.
            controllers.handBack(seat: 0)
            race.apply(.neutral, seat: 0, atTick: race.tick + 1)
            sail(race, &controllers, ticks: 1)
            let autohelm = try #require(race.boats[0].autohelm, "seed \(seed): a centred rudder engages the autohelm")
            guard !autohelm.isTapping else { continue }
            var worst = 0.0
            sail(race, &controllers, ticks: 20 * Race.tickRate) { race in
                let boat = race.boats[0]
                guard boat.status == .racing, boat.penaltyTurnsOwed == 0, let held = autohelm.target.angle else { return }
                worst = max(worst, abs(wrapAngle(boat.sailingAngle - held)))
            }
            #expect(race.boats[0].autohelm?.target == autohelm.target, "seed \(seed): the target held")
            #expect(worst < deg2rad(10), "seed \(seed): sailing angle off its target by \(rad2deg(worst))°")
        }
    }
}
