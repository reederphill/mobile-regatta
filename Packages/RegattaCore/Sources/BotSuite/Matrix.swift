import Foundation
import RegattaBots
import RegattaCore

/// How well a bot sails (#19, CONTEXT.md **Bot tier**), plus `seeded`: today's bot, its skill drawn over
/// `BotStyle`'s whole range. Until #102 gives each tier its own tuning, a tier is a skill band.
public enum BotTier: String, Codable, CaseIterable, Hashable, Sendable {
    case club, regional, national, seeded

    /// The skill a tier's bots sail at, until #102; nil for `seeded`.
    public var skillBand: ClosedRange<Double>? {
        switch self {
        case .club: 0.35...0.6
        case .regional: 0.6...0.8
        case .national: 0.8...1
        case .seeded: nil
        }
    }

    /// `BotStyle(rng:)`'s skill range, which a band rescales.
    static let drawnSkill = 0.35...1.0

    /// The bot sailing `seat` at this tier. Its style is drawn from its own seed exactly as
    /// `BotDriver(seat:raceSeed:)` draws it, then its skill is rescaled from the drawn range into the
    /// tier's band, so a tier keeps the spread of its bots' skills and never touches the race's streams.
    public func driver(seat: Int, raceSeed: RaceSeed) -> BotDriver {
        guard let band = skillBand else { return BotDriver(seat: seat, raceSeed: raceSeed) }
        var rng = SplitMix64(seed: botSeed(raceSeed: raceSeed, seat: seat))
        var style = BotStyle(rng: &rng)
        let drawn = BotTier.drawnSkill
        let t = (style.skill - drawn.lowerBound) / (drawn.upperBound - drawn.lowerBound)
        style.skill = min(max(band.lowerBound + t * (band.upperBound - band.lowerBound), band.lowerBound), band.upperBound)
        return BotDriver(seat: seat, raceSeed: raceSeed, style: style)
    }
}

/// Which tier sails each seat of a race.
public enum TierMix: String, Codable, CaseIterable, Hashable, Sendable {
    /// Today's bots (`BotTier.seeded`) in every seat.
    case seeded
    case club, regional, national
    /// Club, Regional and National round-robin by seat.
    case mixed

    public func tier(ofSeat seat: Int) -> BotTier {
        switch self {
        case .seeded: .seeded
        case .club: .club
        case .regional: .regional
        case .national: .national
        case .mixed: [BotTier.club, .regional, .national][seat % 3]
        }
    }
}

/// The races a suite run sails (#97): every combination of seed × venue × conditions × tide state ×
/// fleet size × tier mix. Venues and conditions are data files named `id@version`.
///
/// Venue, conditions and tide state go into each race's setup and report, but don't vary the race yet:
/// `Race` sails `Race.defaultVenue` and `Race.defaultConditions` until race assembly reads the setup
/// (#81), and has no tide until #79.
public struct BotMatrix: Codable, Hashable, Sendable {
    public var seeds: [UInt64]
    public var venues: [String]
    public var conditions: [String]
    /// Tide states at the gun, degrees through the cycle (as a wind-seed pool names them).
    public var tideStatesDegrees: [Double]
    public var fleetSizes: [Int]
    public var tierMixes: [TierMix]
    public var laps: Int
    /// Seconds after the gun a race may sail before the harness stops it; its unfinished boats count
    /// as not finished.
    public var capSecondsAfterGun: Int

    public init(seeds: [UInt64], venues: [String] = ["dev-venue@2"], conditions: [String] = ["classic-oscillating@2"],
                tideStatesDegrees: [Double] = [0], fleetSizes: [Int], tierMixes: [TierMix] = [.seeded],
                laps: Int = RaceSetup.defaultLaps, capSecondsAfterGun: Int = BotMatrix.defaultCapSecondsAfterGun) {
        self.seeds = seeds
        self.venues = venues
        self.conditions = conditions
        self.tideStatesDegrees = tideStatesDegrees
        self.fleetSizes = fleetSizes
        self.tierMixes = tierMixes
        self.laps = laps
        self.capSecondsAfterGun = capSecondsAfterGun
    }

    /// As `botFleetCompletesARace` sails its fleet: well past a two-lap race and its finish window.
    public static let defaultCapSecondsAfterGun = 1_500

    /// Every race of the matrix, seeds outermost and tier mixes innermost.
    public var cells: [BotRaceCell] {
        seeds.flatMap { seed in
            venues.flatMap { venue in
                conditions.flatMap { conditions in
                    tideStatesDegrees.flatMap { tide in
                        fleetSizes.flatMap { fleetSize in
                            tierMixes.map { mix in
                                BotRaceCell(seed: seed, venue: venue, conditions: conditions, tideStateDegrees: tide,
                                            fleetSize: fleetSize, tierMix: mix, laps: laps,
                                            capSecondsAfterGun: capSecondsAfterGun)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Throws unless every axis has a value, every fleet size is one a race can have, every data file
    /// is bundled, and every venue has a pairing for every conditions.
    public func validate() throws {
        for (axis, count) in [("seeds", seeds.count), ("venues", venues.count), ("conditions", conditions.count),
                              ("tideStatesDegrees", tideStatesDegrees.count), ("fleetSizes", fleetSizes.count),
                              ("tierMixes", tierMixes.count)] where count == 0 {
            throw BotSuiteError.matrix("\(axis) is empty")
        }
        for size in fleetSizes where !RaceSetup.fleetSizes.contains(size) {
            throw BotSuiteError.matrix("fleet size \(size) is outside \(RaceSetup.fleetSizes)")
        }
        guard laps >= 1 else { throw BotSuiteError.matrix("laps must be at least 1") }
        guard capSecondsAfterGun >= 1 else { throw BotSuiteError.matrix("capSecondsAfterGun must be at least 1") }
        for venue in venues {
            let venueKey = try dataFileKey(venue)
            let file = try VenueFile.bundled(id: venueKey.id, version: venueKey.version)
            for conditions in conditions {
                let key = try dataFileKey(conditions)
                _ = try ConditionsFile.bundled(id: key.id, version: key.version)
                guard file.content.pairing(for: key) != nil else {
                    throw BotSuiteError.matrix("\(venue) has no pairing for \(conditions)")
                }
            }
        }
    }

    public static func load(from url: URL) throws -> BotMatrix {
        try JSONDecoder().decode(BotMatrix.self, from: Data(contentsOf: url))
    }

    /// The bundled full matrix (`matrix.json`).
    public static func bundled() throws -> BotMatrix {
        guard let url = Bundle.module.url(forResource: "matrix", withExtension: "json") else {
            throw BotSuiteError.matrix("matrix.json is not bundled")
        }
        return try load(from: url)
    }
}

/// One race of a matrix.
public struct BotRaceCell: Codable, Hashable, Sendable {
    public var seed: UInt64
    public var venue: String
    public var conditions: String
    public var tideStateDegrees: Double
    public var fleetSize: Int
    public var tierMix: TierMix
    public var laps: Int
    public var capSecondsAfterGun: Int
}

/// `id@version`, as the matrix and report name a data file.
func dataFileKey(_ name: String) throws -> DataFileKey {
    guard let at = name.lastIndex(of: "@"), let version = Int(name[name.index(after: at)...]) else {
        throw BotSuiteError.matrix("not a data file id@version: \(name)")
    }
    return DataFileKey(id: String(name[..<at]), version: version)
}

public enum BotSuiteError: Error, CustomStringConvertible {
    case usage(String)
    case matrix(String)

    public var description: String {
        switch self {
        case .usage(let message): message
        case .matrix(let message): "matrix: \(message)"
        }
    }
}
