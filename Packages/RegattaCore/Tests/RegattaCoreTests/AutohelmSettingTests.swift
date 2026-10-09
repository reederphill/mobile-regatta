import Foundation
import Testing
@testable import RegattaCore

/// skiff@6 headed as schema 4 (#434), with `members` (JSON text, e.g. `"holdsWhenCentred": false`) added to its
/// `steering.autohelm`, or none.
enum AutohelmSettingFixtures {
    static func data(_ members: String? = nil) throws -> Data {
        var edits = [(of: #""schemaVersion": 3,"#, with: #""schemaVersion": 4,"#)]
        if let members {
            edits.append((of: #""grooveWindAverageSeconds": 30"#, with: #""grooveWindAverageSeconds": 30, \#(members)"#))
        }
        return try SkiffFixtures.edited(edits)
    }

    /// `data(members)` loaded as tune `tune`, so it never shares a ref with the bundled skiff@6.
    static func file(_ members: String? = nil, tune: Int = 1) throws -> BoatClassFile {
        try BoatClassFile(data: data(members), tune: tune)
    }

    /// The skiff with her autohelm off a centred rudder.
    static func off() throws -> BoatClassFile { try file(#""holdsWhenCentred": false"#) }
}

/// #434 acceptance: the autohelm as a boat class value (`AutohelmTuning.holdsWhenCentred`, ADR 0011).
@Suite struct AutohelmSettingTests {
    /// Her boom to `boom`, the wind at `sailingAngle` in her wind, at the polar's speed.
    func sailing(_ sailingAngle: Double, boom: BoomSide = .port) -> (inout Boat, BoatClass) -> Void {
        { boat, boatClass in
            boat.boomSide = boom
            boat.heading = wrapAngle(boat.windDirection - boom.windSign * sailingAngle)
            boat.speed = boatClass.polar.speed(twa: sailingAngle, tws: boat.windSpeed)
        }
    }

    func steps(_ race: Race, seconds: Double, each: (Boat) -> Void = { _ in }) {
        for _ in 0..<Int((seconds * Double(Race.tickRate)).rounded()) {
            race.step()
            each(race.boats[0])
        }
    }

    /// Off, a centred rudder is a centred rudder: through a 10° shift her heading doesn't move, the autohelm never
    /// engages, and let go within a snap of the groove she doesn't snap to it.
    @Test func offHoldsHeadingThroughShift() throws {
        let off = try AutohelmSettingFixtures.off()
        #expect(!off.content.steering.autohelm.holdsWhenCentred)
        for shift in [deg2rad(10), deg2rad(-10)] {
            let race = try scriptedWindRace(
                boatClassFile: off,
                wind: { t in Wind(direction: t < 20 ? 0 : shift, speed: metresPerSecond(knots: 10)) },
                place: sailing(deg2rad(70)))
            steps(race, seconds: 2)
            let before = race.boats[0]
            #expect(before.autohelm == nil)
            var engaged = false
            steps(race, seconds: 30) { boat in engaged = engaged || boat.autohelm != nil }
            let after = race.boats[0]
            #expect(!engaged, "the autohelm engaged on a centred rudder")
            #expect(abs(wrapAngle(after.heading - before.heading)) < 1e-12, "turned \(rad2deg(after.heading - before.heading))°")
            let freed = rad2deg(wrapAngle(after.sailingAngle - before.sailingAngle))
            #expect(abs(abs(freed) - 10) < 0.5, "her wind angle moved \(freed)° with a 10° shift")
        }

        let groove = off.content.polar.bestUpwind(tws: metresPerSecond(knots: 10)).twa
        let race = try scriptedWindRace(boatClassFile: off, wind: steadyWind(knots: 10), place: sailing(groove + deg2rad(1.5)))
        let heading = race.boats[0].heading
        var events: [RaceEvent.Kind] = []
        steps(race, seconds: 10) { _ in events += race.drainEvents().map(\.kind) }
        #expect(!events.contains(.grooveSnap(seat: 0)))
        #expect(race.boats[0].autohelm == nil)
        #expect(abs(wrapAngle(race.boats[0].heading - heading)) < 1e-12)
    }

    /// The value left out, or true (a bool or 1): today's behaviour exactly, tick for tick, through held rudders,
    /// centring, taps and the seeded wind's shifts.
    @Test func onIsTodaysBehaviour() throws {
        // skiff@6 as bundled, the autohelm on (the default class is skiff@7, the autohelm off, since #437).
        let bundled = try BoatClassFile.bundled(id: SkiffFixtures.classID, version: SkiffFixtures.version)
        #expect(bundled.content.steering.autohelm.holdsWhenCentred)
        let copies = try [nil, #""holdsWhenCentred": true"#, #""holdsWhenCentred": 1"#].map { try AutohelmSettingFixtures.file($0) }
        for copy in copies { #expect(copy.content == bundled.content && copy.ref != bundled.ref) }

        func digests(_ boatClass: BoatClassFile) throws -> [UInt64] {
            var catalog = RaceFileCatalog()
            try catalog.boatClasses.add(boatClass)
            let setup = try RaceSetup(raceSeed: RaceSeed(434), seats: [.human, .human, .human], laps: 1,
                                      startSequenceTicks: 30 * Race.tickRate, boatClass: boatClass.ref)
            let race = try Race(setup: setup, files: RaceFiles(resolving: setup, from: catalog),
                                mode: .authoritative(windSeed: WindSeed(434)))
            var digests: [UInt64] = []
            for k in 0..<(150 * Race.tickRate) {
                let t = k / Race.tickRate
                // Seat 0 steers, lets go and taps; seat 1 lets go and taps; seat 2 never touches the helm.
                let rudder: Double = t % 20 < 2 ? 0.5 : t % 20 >= 10 && t % 20 < 11 ? -0.3 : 0
                race.apply(BoatInput(rudder: rudder), seat: 0, atTick: race.tick + 1)
                if k % (15 * Race.tickRate) == 5 * Race.tickRate {
                    race.tap(.tackGybe, seat: 0, atTick: race.tick + 1)
                    race.tap(.tackGybe, seat: 1, atTick: race.tick + 1)
                }
                race.step()
                digests.append(race.digest())
            }
            return digests
        }
        let today = try digests(bundled)
        for copy in copies { #expect(try digests(copy) == today) }
    }

    /// Off, the tap still sails the tack or gybe; past the boom it lets go within the class's hand-back (3°) of the new
    /// groove, the rudder centred, and once the rudder is centred her heading holds.
    @Test func tapSailsTurnThenHandsBack() throws {
        let off = try AutohelmSettingFixtures.off()
        let skiff = off.content
        #expect(skiff.steering.autohelm.handBack == deg2rad(3))
        let tack = (start: skiff.polar.bestUpwind(tws: metresPerSecond(knots: 10)).twa, knots: 10.0, groove: Autohelm.Groove.upwind)
        let gybe = (start: deg2rad(150), knots: 12.0, groove: Autohelm.Groove.downwind)
        for turn in [tack, gybe] {
            let race = try scriptedWindRace(boatClassFile: off, wind: steadyWind(knots: turn.knots), place: sailing(turn.start))
            steps(race, seconds: 3)
            #expect(race.boats[0].autohelm == nil)
            race.tap(.tackGybe, seat: 0, atTick: race.tick + 1)
            race.step()
            #expect(race.boats[0].autohelm == Autohelm(target: .groove(turn.groove), isTapping: true))

            var previous = race.boats[0]
            var handedBack: (before: Boat, after: Boat, tick: Int)?
            for _ in 0..<(20 * Race.tickRate) where handedBack == nil {
                race.step()
                let boat = race.boats[0]
                if previous.autohelm != nil && boat.autohelm == nil { handedBack = (previous, boat, race.tick) }
                previous = boat
            }
            let back = try #require(handedBack, "the tap never handed her back")
            #expect(back.after.boomSide == .starboard, "she handed back on the new side")
            #expect(back.after.desiredRudder == 0)
            // The check runs on her state as the tick began: within 3° of the groove the tap was sailing to.
            let aim = Autohelm(target: .groove(turn.groove)).aim(
                tws: back.before.polarWindSpeed(in: skiff), grooveTWS: back.before.grooveWindSpeed(in: skiff), boatClass: skiff)
            let error = rad2deg(abs(wrapAngle(aim - back.before.sailingAngle)))
            #expect(error <= 3, "handed back \(error)° from the groove")

            // Then nothing takes her back: the rudder slews to centre, and her heading holds.
            steps(race, seconds: 3)
            let settled = race.boats[0]
            #expect(settled.autohelm == nil && settled.rudder == 0)
            steps(race, seconds: 5)
            #expect(race.boats[0].autohelm == nil)
            #expect(abs(wrapAngle(race.boats[0].heading - settled.heading)) < 1e-12)
            let final = rad2deg(abs(wrapAngle(race.boats[0].sailingAngle - aim)))
            #expect(final <= 5, "settled \(final)° from the groove")
        }
    }
}
