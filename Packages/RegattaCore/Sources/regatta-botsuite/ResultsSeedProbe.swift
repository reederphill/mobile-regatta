// `regatta-botsuite results-seed` (#404): the headless probe behind the UI tests' seed table
// (`RegattaUITests/SeedTable.swift`, written by `scripts/pick-ui-seeds.sh`). A UI test can't sail a headless race at
// test time, so the seed it launches is the first one this probe finds meeting the test's condition, never a hand pick.
import Foundation
import RegattaBots
import RegattaCore

enum ResultsSeedProbe {
    static let usage = """
        usage: regatta-botsuite results-seed [--from <n>] [--to <n>] [--laps <n>] [--opponents <n>] [--min-gap-ticks <n>]
          The first race seed in from...to (default 1...400) on which the app's `-demo` race (`RaceConfig.launch()`
          with `-seed` and `-laps`: you and the opponents (default 7), a 60 s sequence, laps (default 1), the bundled
          files, the wind seed pinned to the seed, a bot sailing your boat) has your boat finish at least
          min-gap-ticks (default 3360: 14 s of wall-clock time at -timescale 8) before the race closes.
          Prints `seed <n> finish <tick> close <tick>`; exits 1 when no seed in the range does, 2 on a usage error.
        """

    static func main(arguments: [String]) -> Int32 {
        var options = (from: UInt64(1), to: UInt64(400), laps: 1, opponents: 7, minGap: 3360)
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
    /// close's, or nil when she didn't finish. Mirrors `RaceConfig.setup`, `.seatControllers` and `.windSeed(pinnedTo:)`.
    static func sail(seed: UInt64, laps: Int, opponents: Int) -> (finish: Int, close: Int)? {
        let setup = try! RaceSetup(raceSeed: RaceSeed(seed), seats: [.human] + Array(repeating: .bot, count: opponents),
                                   laps: laps, startSequenceTicks: 60 * Race.tickRate)
        var wind = SplitMix64(seed: seed ^ 0x5749_4E44_5345_4544) // "WINDSEED", as RaceConfig.windSeed(pinnedTo:)
        let race = Race(setup: setup, windSeed: WindSeed(wind.next()))
        var controllers = SeatControllers(setup: setup)
        controllers[0] = .bot(BotDriver(seat: 0, raceSeed: setup.raceSeed))
        var finish: Int?
        while !race.isOver {
            controllers.drive(race)
            race.step()
            if finish == nil, race.boats[0].status == .finished { finish = race.tick }
        }
        return finish.map { ($0, race.tick) }
    }
}
