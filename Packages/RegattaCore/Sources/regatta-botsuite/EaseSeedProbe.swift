// `regatta-botsuite ease-seed` (#579): the headless probe behind `SeedTable.ease`, the seed `EaseUITests` launches.
import Foundation
import RegattaBots
import RegattaCore

/// `EaseUITests.testEasingSlowsTheBoat` sails the app's `-autostart -seed <n> -timescale 1` race (`RaceConfig.launch()`:
/// you and seven bots, two laps, a 60 s sequence) with your boat human: one tap lets the opening's ease go, she sheets
/// in on the autohelm, and after 10 race seconds the test reads her start speed, eases her a short while, then at least
/// 3 s, and holds the long ease's speed to a bar from skiff@9's ease physics. The bar takes her wind as steady and her
/// air as hers: on seed 1 she sails through two bots' ribbons (seats 2 and 4, a shadow down to 0.58 at T-47), so a fast
/// runner that taps early reads her start speed in a wake and the bar falls under the long ease's speed (#579: 4.33 kn
/// against 4.14). Every runner taps at its own race time, so the probe sails every one the test can be.
enum EaseSeedProbe {
    static let usage = """
        usage: regatta-botsuite ease-seed [--from <n>] [--to <n>]
          The first race seed in from...to (default 1...400) on which EaseUITests' race (the app's `-autostart -seed <n>`
          launch race, your boat human) gives the test clear air and a steady wind for every runner it models: the first
          tap at T-59 to T-40 in 0.5 s steps, a short ease of 1.2 or 3.2 s, the long one 2.2 s longer (3.2 s at least).
          For each: no other boat's ribbons or backwind on her (`Boat.shadow` 1, no backwind envelope) from the first tap
          to the long ease's release, her wind within 5 % of the start reading's, the long ease's speed at least
          0.2 kn under the test's bar (`EaseUITests.bar`) and under the short ease's. Prints `seed <n> margin <kn>`
          (the least margin under the bar); exits 1 when no seed in the range does, 2 on a usage error.
        """

    /// EaseUITests' physics (`easedFraction`, `easeTimeConstant`, `bar(after:)`): fleet-rules@8's opening ease
    /// fraction and skiff@9's ease time constant.
    static let easedFraction = 0.5
    static let easeTimeConstant = 2.0
    static func easedShare(after held: Double) -> Double {
        easedFraction + (1 - easedFraction) * exp(-held / easeTimeConstant)
    }
    static func bar(after held: Double) -> Double { 0.70 - (easedShare(after: 3) - easedShare(after: held)) }

    /// The modelled runners: the first tap's race second (from the gun), and the short ease's hold.
    static let firstTaps = stride(from: -59.0, through: -40.0, by: 0.5)
    static let shortHolds = [1.2, 3.2]
    /// The least room under the bar a runner must leave, knots, and the most her wind may move, a share.
    static let minMargin = 0.2
    static let windTolerance = 0.05

    static func main(arguments: [String]) -> Int32 {
        var from: UInt64 = 1, to: UInt64 = 400
        var rest = arguments[...]
        while let flag = rest.popFirst() {
            guard let text = rest.popFirst(), let value = UInt64(text) else {
                FileHandle.standardError.write(Data("ease-seed: \(flag) needs a whole number\n\(usage)\n".utf8))
                return 2
            }
            switch flag {
            case "--from": from = value
            case "--to": to = value
            default:
                FileHandle.standardError.write(Data("ease-seed: unknown option \(flag)\n\(usage)\n".utf8))
                return 2
            }
        }
        guard from <= to else {
            FileHandle.standardError.write(Data("ease-seed: --from is after --to\n".utf8))
            return 2
        }
        for seed in from...to {
            if let margin = leastMargin(seed: seed) {
                print("seed \(seed) margin \(String(format: "%.2f", margin))")
                return 0
            }
        }
        FileHandle.standardError.write(Data("ease-seed: no seed in \(from)...\(to) meets the condition\n".utf8))
        return 1
    }

    /// The least margin under the bar over every modelled runner, or nil once one breaks the condition.
    static func leastMargin(seed: UInt64) -> Double? {
        var least = Double.infinity
        for firstTap in firstTaps {
            for shortHold in shortHolds {
                guard let margin = sail(seed: seed, firstTap: firstTap, shortHold: shortHold) else { return nil }
                least = min(least, margin)
            }
        }
        return least
    }

    /// One runner on `seed`: the long ease's margin under the bar, or nil if her air or wind isn't clear and steady,
    /// or the long ease isn't slower than the bar less `minMargin` and than the short one.
    static func sail(seed: UInt64, firstTap: Double, shortHold: Double) -> Double? {
        var (race, controllers) = ResultsSeedProbe.demoRace(seed: seed, laps: 2, opponents: 7)
        controllers[0] = .human
        func tick(_ seconds: Double) -> Int { Int((seconds * Double(Race.tickRate)).rounded()) }
        // The test: settle 10 whole clock seconds (about 11 race seconds), a second to each tap, the long ease 2 s
        // longer than the short one (3 s at least), each let go a little past its hold.
        let startRead = firstTap + 11, shortOn = startRead + 1, shortOff = shortOn + shortHold
        let longHold = max(3, shortHold + 2) + 0.2, longOn = shortOff + 1, longOff = longOn + longHold
        let taps = [(tick(firstTap), false), (tick(shortOn), true), (tick(shortOff), false),
                    (tick(longOn), true), (tick(longOff), false)]
        var start: (knots: Double, wind: Double)?
        var short: Double?
        while race.tick < tick(longOff) {
            for (at, ease) in taps where at == race.tick + 1 {
                race.apply(BoatInput(rudder: 0 as Int8, ease: ease), seat: 0, atTick: at)
            }
            controllers.drive(race)
            race.step()
            guard race.tick >= tick(firstTap) else { continue }
            let her = race.boats[0]
            guard her.shadow == 1, !backwound(race) else { return nil }
            if race.tick == tick(startRead) { start = (knots(her.speed), her.sailingWind.speed) }
            if let start, abs(her.sailingWind.speed / start.wind - 1) > windTolerance { return nil }
            if race.tick == tick(shortOff) { short = knots(her.speed) }
        }
        guard let start, let short else { return nil }
        let long = knots(race.boats[0].speed)
        let margin = start.knots * bar(after: longHold) - long
        guard margin >= minMargin, long < short else { return nil }
        return margin
    }

    /// Whether another boat's backwind envelope reaches your boat.
    static func backwound(_ race: Race) -> Bool {
        let p = race.boats[0].position
        return race.boats.indices.dropFirst().contains { race.shadowCone(ofSeat: $0).map { $0.backwindEnvelope(at: p) > 0 } ?? false }
    }

    static func knots(_ metresPerSecond: Double) -> Double { RegattaCore.knots(metresPerSecond: metresPerSecond) }
}
