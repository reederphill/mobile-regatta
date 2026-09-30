import Foundation
import Testing
@testable import RegattaCore

/// #263 acceptance: the roll tack (#222). A second tack/gybe tap during a tack is the roll: within the class's window
/// of the boom crossing (skiff@3: ±0.25 s) it hits, and until close-hauled she takes only half of each tick's speed
/// loss (no floor, no jump, never better than not tacking); outside it, early or late, it misses and her speed is
/// multiplied by 0.8, once. Twin races in open water and a steady wind (`OpenWater`).
@Suite struct RollTackTests {
    let knots = 10.0
    var roll: BoatClass.RollTackTuning { OpenWater.boatClass.rollTack! }

    /// Twin races stepped once (autohelms on the groove) with the tack tapped in both for the next tick.
    func twins() throws -> (plain: Race, rolled: Race) {
        let plain = try OpenWater.race(knots: knots), rolled = try OpenWater.race(knots: knots)
        for race in [plain, rolled] {
            race.step()
            race.tap(.tackGybe, seat: 0, atTick: race.tick + 1)
        }
        return (plain, rolled)
    }

    /// The tick the boom crosses on the tack a plain tap sails (the same in every twin until a roll).
    func crossingTick() throws -> Int {
        let race = try twins().plain
        while race.boats[0].tackCrossingTick == nil { race.step() }
        return race.boats[0].tackCrossingTick!
    }

    /// Steps both races to `tick`.
    func step(_ a: Race, _ b: Race, to tick: Int) {
        while a.tick < tick {
            a.step()
            b.step()
        }
    }

    @Test func classRollsWithinAQuarterSecondAtHalfTheLossAndMissesAtFourFifths() {
        #expect(roll.window == 0.25 && roll.windowTicks == 7)
        #expect(roll.hitLossFraction == 0.5 && roll.missSpeedFactor == 0.8)
    }

    @Test func hitHalvesTheSpeedLossAndNeverBeatsNotTacking() throws {
        let direction = try OpenWater.windDirection()
        let crossing = try crossingTick()
        let (plain, rolled) = try twins()
        let sailingOn = try OpenWater.race(knots: knots)
        sailingOn.step()
        let start = plain.boats[0].position
        let entry = plain.boats[0].speed
        step(plain, rolled, to: crossing - 1)
        while sailingOn.tick < crossing - 1 { sailingOn.step() }
        #expect(plain.boats[0].speed == rolled.boats[0].speed)
        rolled.tap(.tackGybe, seat: 0, atTick: crossing)
        var hitTicks = 0
        for _ in 0..<(25 * Race.tickRate) {
            let (plainBefore, rolledBefore) = (plain.boats[0].speed, rolled.boats[0].speed)
            plain.step()
            rolled.step()
            sailingOn.step()
            if rolled.boats[0].roll == .hit {
                hitTicks += 1
                // No jump: a hit never gains speed where the plain tack loses it, nor above her entry speed.
                if plain.boats[0].speed < plainBefore { #expect(rolled.boats[0].speed <= rolledBefore) }
                #expect(rolled.boats[0].speed <= entry)
            }
        }
        let events = rolled.drainEvents()
        #expect(events.contains { $0.kind == .rollHit(seat: 0) && $0.tick == crossing })
        #expect(!events.contains { $0.kind == .rollMissed(seat: 0) })
        #expect(hitTicks > 0 && rolled.boats[0].roll == nil && !rolled.boats[0].isTacking)
        #expect(!plain.drainEvents().contains { $0.kind == .rollHit(seat: 0) || $0.kind == .rollMissed(seat: 0) })

        let plainLoss = OpenWater.madeGood(sailingOn, from: start, direction: direction)
            - OpenWater.madeGood(plain, from: start, direction: direction)
        let rolledLoss = OpenWater.madeGood(sailingOn, from: start, direction: direction)
            - OpenWater.madeGood(rolled, from: start, direction: direction)
        let saved = (plainLoss - rolledLoss) / OpenWater.hullLength
        // A rolled tack is cheaper, but never better than not tacking (#222: execution never beats tactics).
        #expect(rolledLoss > 0, "rolled tack lost \(rolledLoss / OpenWater.hullLength) L")
        #expect(saved > 0.05 && saved < 0.4, "a hit saved \(saved) L at \(knots) kn (target ~0.2)")
    }

    @Test func hitKeepsBackHalfOfTheTicksSpeedLoss() throws {
        // At the crossing both twins start the tick at the same speed; the plain one's tick loss is what the
        // dynamics give, and the hit takes half of it.
        let crossing = try crossingTick()
        let (plain, rolled) = try twins()
        step(plain, rolled, to: crossing - 1)
        rolled.tap(.tackGybe, seat: 0, atTick: crossing)
        let before = plain.boats[0].speed
        plain.step()
        rolled.step()
        #expect(rolled.boats[0].roll == .hit)
        let plainLoss = before - plain.boats[0].speed
        #expect(plainLoss > 0)
        #expect(abs((before - rolled.boats[0].speed) - roll.hitLossFraction * plainLoss) < 1e-12)
    }

    @Test(arguments: [false, true])
    func missMultipliesSpeedBy0_8EarlyOrLate(late: Bool) throws {
        let crossing = try crossingTick()
        let (plain, rolled) = try twins()
        // Early: a tap well before the window, decided once the window has passed without a crossing. Late: a tap
        // just past the window after the crossing, decided that tick.
        let tapTick = late ? crossing + roll.windowTicks + 1 : plain.tick + 1
        #expect(late || crossing - tapTick > roll.windowTicks, "the early tap is outside the window")
        let missTick = late ? tapTick : tapTick + roll.windowTicks + 1
        step(plain, rolled, to: tapTick - 1)
        rolled.tap(.tackGybe, seat: 0, atTick: tapTick)
        step(plain, rolled, to: missTick - 1)
        #expect(rolled.boats[0].speed == plain.boats[0].speed, "a pending roll changes nothing")
        plain.step()
        rolled.step()
        #expect(rolled.boats[0].roll == .missed)
        #expect(abs(rolled.boats[0].speed - roll.missSpeedFactor * plain.boats[0].speed) < 1e-12)
        #expect(rolled.drainEvents().filter { $0.kind == .rollMissed(seat: 0) }.map(\.tick) == [missTick])
        // Only once: after the miss she sails the rest of her tack on her own, and a further tap is ignored.
        rolled.tap(.tackGybe, seat: 0, atTick: rolled.tick + 1)
        for _ in 0..<(10 * Race.tickRate) { rolled.step() }
        let rest = rolled.drainEvents()
        #expect(!rest.contains { $0.kind == .rollMissed(seat: 0) || $0.kind == .rollHit(seat: 0) })
        // The early roll was decided before the boom crossed: her one tack's crossing comes after it.
        #expect(rest.filter { $0.kind == .tacked(seat: 0) }.count == (late ? 0 : 1), "the ignored tap started no tack")
    }

    @Test func rollInputReplaysToTheSameDigest() throws {
        // A live race of the default class, its inputs in the log like any others: seat 0 heads up from where the
        // race puts her until she's close-hauled and lets her autohelm take the groove, then tacks with a roll on the
        // crossing (a hit) and, later, tacks again with a roll straight after the tap (a miss). Replaying the log
        // gives the same digest and the same roll events.
        let setup = try RaceSetup(raceSeed: RaceSeed(263), seats: [.human, .human], laps: 1,
                                  startSequenceTicks: 90 * Race.tickRate)
        let live = Race(setup: setup, windSeed: WindSeed(263))
        var steering = true
        var tacks: [Int] = []
        var rolled = false
        for _ in 0..<(60 * Race.tickRate) {
            let t = live.tick + 1
            let b = live.boats[0]
            if steering {
                if b.twa > deg2rad(50) {
                    live.apply(BoatInput(rudder: b.relativeWind > 0 ? 0.6 : -0.6), seat: 0, atTick: t)
                } else {
                    live.apply(.neutral, seat: 0, atTick: t)
                    steering = false
                    tacks = [t + 15 * Race.tickRate, t + 35 * Race.tickRate]
                }
            }
            if tacks.contains(t) { live.tap(.tackGybe, seat: 0, atTick: t) }
            if !rolled, let crossing = b.tackCrossingTick, crossing == live.tick {
                live.tap(.tackGybe, seat: 0, atTick: t)
                rolled = true
            }
            if tacks.count == 2, t == tacks[1] + 1 { live.tap(.tackGybe, seat: 0, atTick: t) }
            live.step()
        }
        let rolls = { (race: Race) in
            race.drainEvents().filter { $0.kind == .rollHit(seat: 0) || $0.kind == .rollMissed(seat: 0) }
        }
        let events = rolls(live)
        #expect(events.map(\.kind) == [.rollHit(seat: 0), .rollMissed(seat: 0)])

        let log = try #require(live.log)
        let replayed = try Replayer.replay(log)
        #expect(replayed.tick == live.tick)
        #expect(replayed.digest() == live.digest())
        #expect(rolls(replayed) == events)
    }
}
