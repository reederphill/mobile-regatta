import Foundation
import Testing
import RegattaCore
@testable import RegattaBots

/// #342: "Tacks away from a squeeze". Racing, a windward bot keeping clear under rule 11 luffs when that clears her,
/// tacks away when it doesn't and a tack is clear, and eases to drop astern when neither.
extension BotConductTests {
    /// Beating on starboard: seat 0 at the water's centre at her close-hauled speed, seat 1 a bot `abeam` hull lengths
    /// to windward and `astern` astern, `faster` times as fast, coming up from astern. With `windward`, a third boat
    /// (seat 2) on starboard that far to windward of seat 1, alongside her, holding her course.
    static func squeeze(seed: UInt64, abeam: Double, astern: Double, faster: Double,
                        windward: Double? = nil) throws -> (race: Race, length: Double) {
        let water = Water(seed: seed, seats: windward == nil ? 2 : 3)
        let heading = water.beat(.starboard)
        let forward = Vec2.heading(heading)
        // On starboard her windward side is her starboard side.
        let up = forward.rightPerp * water.length
        let bot = water.centre + up * abeam - forward * water.length * astern
        var placements = [
            Placement(position: water.centre, heading: heading, speed: water.up.speed),
            Placement(position: bot, heading: heading, speed: water.up.speed * faster),
        ]
        if let windward {
            placements.append(Placement(position: bot + up * windward, heading: heading, speed: water.up.speed * faster))
        }
        return (try place(water, placements), water.length)
    }

    /// The leeward boat's script (the owner's playtest, #342): she eases for `easeSeconds`, then turns gently towards
    /// the windward boat (`rudder` to starboard, still eased), slower than rule 16.1's course-change rate, so 16.1 is never
    /// in it. Sends seat 0's input; `start` is the tick the script began.
    static func easeThenTurn(_ race: Race, start: Int, easeSeconds: Double = 1.5, rudder: Int8 = 25) {
        let t = Double(race.tick - start) / Double(Race.tickRate)
        race.apply(BoatInput(rudder: t < easeSeconds ? 0 : rudder, ease: true), seat: 0, atTick: race.tick + 1)
    }

    /// #342 acceptance: the right-of-way boat eases, then turns gently (rudder about 0.2, under 16.1's course-change
    /// rate) into a windward bot arriving from astern. Close-hauled already, the bot has no luff that clears her, and
    /// bearing away or dropping astern takes her into the leeward boat; she tacks away, and no rule call comes. Before,
    /// she was called under rule 11 on every seed.
    @Test func windwardBotTacksAwayFromSqueezeWithNoEscapeOnHerTack() throws {
        var failures: [String] = []
        for seed: UInt64 in [3, 7, 13] {
            let (race, _) = try Self.squeeze(seed: seed, abeam: 1.0, astern: 1.0, faster: 1.15)
            let start = race.tick
            let changesCourse = try #require(race.rules.incidents.escape.changesCourse)
            var last = race.boats[0].heading
            var fastestTurn = 0.0
            let sailed = Self.sailOne(race, seat: 1, seconds: 15, planned: .starboard) { race in
                Self.easeThenTurn(race, start: start)
                fastestTurn = max(fastestTurn, abs(wrapAngle(race.boats[0].heading - last)) * Double(Race.tickRate))
                last = race.boats[0].heading
            }
            let calls = Self.calls(sailed.kinds)
            if !calls.isEmpty { failures.append("seed \(seed): \(calls)") }
            if fastestTurn >= changesCourse { failures.append("seed \(seed): the leeward boat turned at \(rad2deg(fastestTurn))°/s") }
            let tackedAway = sailed.decisions.contains { $0.keepClear == .windwardLeeward && $0.decision.tap == .tackGybe }
            if !tackedAway { failures.append("seed \(seed): never tacked away keeping clear") }
            if race.boats[1].tack != .port { failures.append("seed \(seed): ended on \(race.boats[1].tack)") }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    /// #342 acceptance: step 1 still wins when it clears her. A windward bot bearing away towards a leeward boat holding
    /// her course, with room to windward, keeps clear by luffing: no tack, and no rule call.
    @Test func windwardBotLuffsWhenLuffClears() throws {
        var failures: [String] = []
        for seed: UInt64 in [3, 7, 13] {
            for (abeam, converging) in [(1.5, 15.0), (2.0, 12.0)] {
                let water = Water(seed: seed)
                let heading = water.beat(.starboard)
                let forward = Vec2.heading(heading)
                let race = try Self.place(water, [
                    Placement(position: water.centre, heading: heading, speed: water.up.speed),
                    // Bearing away on starboard turns her to port, towards the leeward boat.
                    Placement(position: water.centre + forward.rightPerp * water.length * abeam, heading: heading - deg2rad(converging),
                              speed: water.up.speed),
                ])
                let sailed = Self.sailOne(race, seat: 1, seconds: 12, planned: .starboard)
                let name = "seed \(seed) abeam \(abeam) converging \(converging)°"
                let calls = Self.calls(sailed.kinds)
                if !calls.isEmpty { failures.append("\(name): \(calls)") }
                let keeping = sailed.decisions.filter { $0.keepClear == .windwardLeeward }
                // Luffing on starboard turns her to starboard, away from the leeward boat.
                if !keeping.contains(where: { $0.decision.input.rudder > 0 }) { failures.append("\(name): never luffed keeping clear") }
                if sailed.decisions.contains(where: { $0.decision.tap == .tackGybe }) { failures.append("\(name): tacked") }
            }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    /// #342 acceptance: `tapIsClear` still gates the tack. The squeeze of `windwardBotTacksAwayFromSqueezeWithNoEscapeOnHerTack`
    /// with a third boat alongside the bot to windward, where her tack would take her: she doesn't tack into her, and eases
    /// to drop astern instead.
    @Test func windwardBotDoesNotTackIntoABoat() throws {
        var failures: [String] = []
        for seed: UInt64 in [3, 7, 13] {
            let (race, length) = try Self.squeeze(seed: seed, abeam: 1.0, astern: 1.0, faster: 1.15, windward: 1.2)
            let start = race.tick
            let sailed = Self.sailOne(race, seat: 1, seconds: 15, planned: .starboard) { race in
                Self.easeThenTurn(race, start: start)
            }
            let keeping = sailed.decisions.filter { $0.keepClear == .windwardLeeward && $0.gap < length * 2 }
            if keeping.isEmpty { failures.append("seed \(seed): never kept clear of the leeward boat") }
            if keeping.contains(where: { $0.decision.tap == .tackGybe }) { failures.append("seed \(seed): tacked into the windward boat") }
            if !keeping.contains(where: { $0.decision.input.ease }) { failures.append("seed \(seed): never eased to drop astern") }
            let calls = Self.calls(sailed.kinds).filter { $0.hasPrefix("13 ") || $0.hasPrefix("15 ") || $0.hasPrefix("10 ") }
            if !calls.isEmpty { failures.append("seed \(seed): \(calls)") }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }
}
