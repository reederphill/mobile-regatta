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
    /// The venue and the conditions sailed, bundled data files named `id@version` (#105); nil for the default race
    /// files' (`RaceFiles.defaults`). A row that leaves them out keeps the race it always sailed.
    public var venue: String?
    public var conditions: String?
    /// Why the row is there and how its seeds were picked (#105): data for a reader, never read by the bench.
    public var note: String?

    public init(name: String, boats: Int = 16, raceSeed: UInt64, windSeed: UInt64, laps: Int = RaceSetup.defaultLaps,
                startSequenceTicks: Int = RaceSetup.defaultStartSequenceTicks, warmupTicks: Int = 30, ticks: Int,
                venue: String? = nil, conditions: String? = nil, note: String? = nil) {
        self.name = name
        self.boats = boats
        self.raceSeed = raceSeed
        self.windSeed = windSeed
        self.laps = laps
        self.startSequenceTicks = startSequenceTicks
        self.warmupTicks = warmupTicks
        self.ticks = ticks
        self.venue = venue
        self.conditions = conditions
        self.note = note
    }

    /// The `index`th race of this scenario: its seeds offset by `index`, so concurrent races differ. Assembled from the
    /// files its setup names (`RaceFiles(resolving:)`), as the server and the bot suite assemble a race.
    public func race(index: Int = 0) throws -> Race {
        let setup = try self.setup(index: index)
        return try Race(setup: setup, files: RaceFiles(resolving: setup),
                        mode: .authoritative(windSeed: WindSeed(windSeed &+ UInt64(index))))
    }

    /// The `index`th race's setup: every seat a bot, at the scenario's venue and conditions if it names them.
    public func setup(index: Int = 0) throws -> RaceSetup {
        let defaults = RaceFiles.defaults
        let venueRef = try venue.map { name in
            let key = try Scenario.key(name)
            return try VenueFile.bundled(id: key.id, version: key.version).ref
        } ?? defaults.venue.ref
        let conditionsRef = try conditions.map { name in
            let key = try Scenario.key(name)
            return try ConditionsFile.bundled(id: key.id, version: key.version).ref
        } ?? defaults.conditions.ref
        return try RaceSetup(raceSeed: RaceSeed(raceSeed &+ UInt64(index)), seats: Array(repeating: .bot, count: boats),
                             laps: laps, startSequenceTicks: startSequenceTicks, venue: venueRef, conditions: conditionsRef)
    }

    /// `id@version`, as a row names a data file.
    static func key(_ name: String) throws -> (id: String, version: Int) {
        guard let at = name.lastIndex(of: "@"), let version = Int(name[name.index(after: at)...]) else {
            throw BenchError.usage("not a data file id@version: \(name)")
        }
        return (String(name[..<at]), version)
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
