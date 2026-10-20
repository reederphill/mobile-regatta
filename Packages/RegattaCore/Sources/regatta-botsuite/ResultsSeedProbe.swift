// `regatta-botsuite results-seed` (#404) and `rounding-seed` (#477): the headless probes behind the UI tests' seed table
// (`RegattaUITests/SeedTable.swift`, written by `scripts/pick-ui-seeds.sh`). A UI test can't sail a headless race at
// test time, so the seed it launches is the first one a probe finds meeting the test's condition, never a hand pick.
import Foundation
import RegattaBots
import RegattaCore

enum ResultsSeedProbe {
    static let usage = """
        usage: regatta-botsuite results-seed [--from <n>] [--to <n>] [--laps <n>] [--opponents <n>] [--min-gap-ticks <n>]
          The first race seed in from...to (default 1...400) on which the app's `-demo` race (`RaceConfig.launch()`
          with `-seed` and `-laps`: you and the opponents (default 7), a 60 s sequence, laps (default 1), the bundled
          files, the wind seed pinned to the seed, a bot sailing your boat) has your boat finish at least
          min-gap-ticks (default 1680: 14 s of wall-clock time at -timescale 4, 30 ticks/s × 4) before the race closes.
          Prints `seed <n> finish <tick> close <tick>`; exits 1 when no seed in the range does, 2 on a usage error.
        """

    static func main(arguments: [String]) -> Int32 {
        var options = (from: UInt64(1), to: UInt64(400), laps: 1, opponents: 7, minGap: 1680)
        var rest = arguments[...]
        while let flag = rest.popFirst() {
            guard let text = rest.popFirst(), let value = Int(text), value >= 0 else {
                FileHandle.standardError.write(Data("results-seed: \(flag) needs a whole number\n\(usage)\n".utf8))
                return 2
            }
            switch flag {
            case "--from": options.from = UInt64(value)
            case "--to": options.to = UInt64(value)
            case "--laps": options.laps = value
            case "--opponents": options.opponents = value
            case "--min-gap-ticks": options.minGap = value
            default:
                FileHandle.standardError.write(Data("results-seed: unknown option \(flag)\n\(usage)\n".utf8))
                return 2
            }
        }
        guard options.from <= options.to else {
            FileHandle.standardError.write(Data("results-seed: --from is after --to\n".utf8))
            return 2
        }
        guard options.laps >= 1, RaceSetup.fleetSizes.contains(options.opponents + 1) else {
            FileHandle.standardError.write(Data(
                "results-seed: --laps must be at least 1 and --opponents in \(RaceSetup.fleetSizes.lowerBound - 1)...\(RaceSetup.fleetSizes.upperBound - 1)\n\(usage)\n".utf8))
            return 2
        }
        for seed in options.from...options.to {
            guard let (finish, close) = sail(seed: seed, laps: options.laps, opponents: options.opponents) else { continue }
            if close - finish >= options.minGap {
                print("seed \(seed) finish \(finish) close \(close)")
                return 0
            }
        }
        let tried = options.to - options.from + 1
        FileHandle.standardError.write(Data(
            "results-seed: no seed in \(options.from)...\(options.to) meets the condition (\(tried) tried)\n".utf8))
        return 1
    }

    /// The app's `-demo -seed <seed> -laps <laps>` race sailed headless to its close: your boat's finish tick and the
    /// close's, or nil when she didn't finish.
    static func sail(seed: UInt64, laps: Int, opponents: Int) -> (finish: Int, close: Int)? {
        let (race, demo) = demoRace(seed: seed, laps: laps, opponents: opponents)
        var controllers = demo
        var finish: Int?
        while !race.isOver {
            controllers.drive(race)
            race.step()
            if finish == nil, race.boats[0].status == .finished { finish = race.tick }
        }
        return finish.map { ($0, race.tick) }
    }

    /// The app's `-demo -seed <seed> -laps <laps>` race at its first tick, and its controllers. Mirrors
    /// `RaceConfig.setup`, `.seatControllers` and `.windSeed(pinnedTo:)`.
    static func demoRace(seed: UInt64, laps: Int, opponents: Int) -> (Race, SeatControllers) {
        let setup = try! RaceSetup(raceSeed: RaceSeed(seed), seats: [.human] + Array(repeating: .bot, count: opponents),
                                   laps: laps, startSequenceTicks: 60 * Race.tickRate)
        var wind = SplitMix64(seed: seed ^ 0x5749_4E44_5345_4544) // "WINDSEED", as RaceConfig.windSeed(pinnedTo:)
        let race = Race(setup: setup, windSeed: WindSeed(wind.next()))
        var controllers = SeatControllers(setup: setup)
        controllers[0] = .bot(BotDriver(seat: 0, raceSeed: setup.raceSeed))
        return (race, controllers)
    }
}

/// `regatta-botsuite rounding-seed` (#477): the seed of `RaceAssemblyUITests`' first-rounding race, by condition.
enum RoundingSeedProbe {
    static let usage = """
        usage: regatta-botsuite rounding-seed [--from <n>] [--to <n>] [--laps <n>] [--opponents <n>]
                                              [--max-start-ticks <n>] [--max-rounding-ticks <n>]
          The first race seed in from...to (default 1...400) on which the app's `-demo` race (as `results-seed`'s, laps
          default 2) has your boat start cleanly, racing within max-start-ticks of the gun (default 60) with no rule
          call against her and no mark touch, and round the windward mark within max-rounding-ticks of the gun
          (default 4200: 140 s), still with none. Prints `seed <n> start <tick> rounding <tick>`; exits 1 when no seed
          in the range does, 2 on a usage error.
        """

    static func main(arguments: [String]) -> Int32 {
        var options = (from: UInt64(1), to: UInt64(400), laps: 2, opponents: 7, maxStart: 60, maxRounding: 4200)
        var rest = arguments[...]
        while let flag = rest.popFirst() {
            guard let text = rest.popFirst(), let value = Int(text), value >= 0 else {
                FileHandle.standardError.write(Data("rounding-seed: \(flag) needs a whole number\n\(usage)\n".utf8))
                return 2
            }
            switch flag {
            case "--from": options.from = UInt64(value)
            case "--to": options.to = UInt64(value)
            case "--laps": options.laps = value
            case "--opponents": options.opponents = value
            case "--max-start-ticks": options.maxStart = value
            case "--max-rounding-ticks": options.maxRounding = value
            default:
                FileHandle.standardError.write(Data("rounding-seed: unknown option \(flag)\n\(usage)\n".utf8))
                return 2
            }
        }
        guard options.from <= options.to, options.laps >= 1, RaceSetup.fleetSizes.contains(options.opponents + 1) else {
            FileHandle.standardError.write(Data("rounding-seed: bad range, laps or opponents\n\(usage)\n".utf8))
            return 2
        }
        for seed in options.from...options.to {
            let (race, controllers) = ResultsSeedProbe.demoRace(seed: seed, laps: options.laps,
                                                                opponents: options.opponents)
            if let (start, rounding) = sail(race, controllers, maxStart: options.maxStart,
                                            maxRounding: options.maxRounding) {
                print("seed \(seed) start \(start) rounding \(rounding)")
                return 0
            }
        }
        FileHandle.standardError.write(Data(
            "rounding-seed: no seed in \(options.from)...\(options.to) meets the condition\n".utf8))
        return 1
    }

    /// Your boat's start and windward-mark rounding ticks, or nil once the race can't meet the condition: she isn't
    /// racing by `maxStart`, hasn't rounded by `maxRounding`, is over at the gun, or takes a rule call or touches a
    /// mark before rounding.
    static func sail(_ race: Race, _ controllers: SeatControllers, maxStart: Int,
                     maxRounding: Int) -> (start: Int, rounding: Int)? {
        var controllers = controllers
        var start: Int?
        while !race.isOver, race.tick <= maxRounding {
            controllers.drive(race)
            race.step()
            for event in race.drainEvents() {
                switch event.kind {
                case .ruleCall(let call) where call.offender == 0: return nil
                case .markTouch(let seat, _) where seat == 0: return nil
                case .ocsNotice(let recipient) where recipient == 0: return nil
                default: break
                }
            }
            let boat = race.boats[0]
            if start == nil, boat.status == .racing { start = race.tick }
            if start == nil, race.tick > maxStart { return nil }
            if let start, boat.legIndex >= 1 { return (start, race.tick) }
        }
        return nil
    }
}
