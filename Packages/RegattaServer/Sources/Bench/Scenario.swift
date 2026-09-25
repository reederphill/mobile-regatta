import Foundation
import RegattaCore

/// One benchmark scenario (#69): a race the bench sails with bots and times. The list is data,
/// `scenarios.json` beside this file, so #105 adds keyed wind and puffs, estuary current and worst-case
/// escape-sim scenarios as rows, with only the fields they need added here.
public struct Scenario: Codable, Hashable, Sendable {
    /// Named in the report and by `--scenario`.
    public var name: String
    /// Boats in the race, every one sailed by the current bot brains (#19).
    public var boats: Int
    public var raceSeed: UInt64
    public var windSeed: UInt64
    public var laps: Int
    public var startSequenceTicks: Int
    /// Ticks stepped before timing starts, so first-tick allocations don't count.
    public var warmupTicks: Int
    /// Ticks timed, or fewer if the race is over first.
    public var ticks: Int

    public init(name: String, boats: Int = 16, raceSeed: UInt64, windSeed: UInt64, laps: Int = RaceSetup.defaultLaps,
                startSequenceTicks: Int = RaceSetup.defaultStartSequenceTicks, warmupTicks: Int = 30, ticks: Int) {
        self.name = name
        self.boats = boats
        self.raceSeed = raceSeed
        self.windSeed = windSeed
        self.laps = laps
        self.startSequenceTicks = startSequenceTicks
        self.warmupTicks = warmupTicks
        self.ticks = ticks
    }

    /// The `index`th race of this scenario: its seeds offset by `index`, so concurrent races differ.
    public func race(index: Int = 0) throws -> Race {
        let setup = try RaceSetup(raceSeed: RaceSeed(raceSeed &+ UInt64(index)),
                                  seats: Array(repeating: .bot, count: boats),
                                  laps: laps, startSequenceTicks: startSequenceTicks)
        return Race(setup: setup, windSeed: WindSeed(windSeed &+ UInt64(index)))
    }

    /// The scenarios in the JSON file at `url`: an array of scenarios.
    public static func load(from url: URL) throws -> [Scenario] {
        try JSONDecoder().decode([Scenario].self, from: Data(contentsOf: url))
    }

    /// The scenarios the bench ships with.
    public static func bundled() throws -> [Scenario] {
        guard let url = Bundle.module.url(forResource: "scenarios", withExtension: "json") else {
            throw BenchError.usage("scenarios.json is missing from the bench's resources")
        }
        return try load(from: url)
    }
}
