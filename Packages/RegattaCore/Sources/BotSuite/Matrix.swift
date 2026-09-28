import Foundation
import RegattaBots
import RegattaCore

extension BotTier {
    /// The bot sailing `seat` at this tier (`BotDriver(seat:raceSeed:tier:profile:)`, RegattaBots' mapping), sailing
    /// `profile` if the matrix gives the seat one (#231). Her skill is drawn inside the tier's band from her own seed,
    /// so a tier keeps the spread of its bots' skills and never touches the race's streams.
    public func driver(seat: Int, raceSeed: RaceSeed, profile: BotProfile? = nil) -> BotDriver {
        BotDriver(seat: seat, raceSeed: raceSeed, tier: self, profile: profile)
    }
}

/// Which scripted profile, if any, sails each seat of a race (#231): the matrix's profile axis, as a tier
/// mix is its tier axis. #234 adds mixes for its profiles.
public enum ProfileMix: String, Codable, CaseIterable, Hashable, Sendable {
    /// Every seat a live bot, sailing as its tier does: the seats the tier limits gate.
    case live
    /// The skill-gap scenario (ADR 0007): baseline and tactician seats by turns, the tactician on the odd
    /// seats for an even seed and the even seats for an odd one, so neither profile keeps a seat's start.
    case skillGap
    /// The fun-pass scenario (#221, #238), sailed in classic oscillating conditions only: baseline, tactician
    /// and blip-tacker seats by turns, starting one seat further along for each seed. #221's proof that the
    /// shifts are worth playing: the tactician tacks often, and beats the boat that tacks on every blip.
    case funPass

    /// The profile sailing `seat` in a race with race seed `seed`, or nil for a live bot.
    public func profile(ofSeat seat: Int, seed: UInt64) -> BotProfile? {
        switch self {
        case .live: nil
        case .skillGap: (seat + Int(seed % 2)).isMultiple(of: 2) ? .baseline : .tactician
        case .funPass: [BotProfile.baseline, .tactician, .blipTacker][(seat + Int(seed % 3)) % 3]
        }
    }

    /// The conditions file the mix is sailed in, by id, whatever its version; nil for any the matrix names.
    /// The fun pass's numbers (#221) are for an oscillating breeze: a matrix sails it in no other conditions.
    public var conditionsID: String? {
        switch self {
        case .live, .skillGap: nil
        case .funPass: "classic-oscillating"
        }
    }

    /// Whether the mix is sailed in `conditions`, a data file named `id@version`.
    public func sails(in conditions: String) -> Bool {
        guard let id = conditionsID else { return true }
        return (try? dataFileKey(conditions))?.id == id
    }
}

/// Which tier sails each seat of a race.
public enum TierMix: String, Codable, CaseIterable, Hashable, Sendable {
    case club, regional, national
    /// A Mixed fleet (CONTEXT.md **Mixed fleet**), as the app's bots are (`BotDriver(seat:raceSeed:)`): each seat's
    /// tier drawn from its bot's own seed by the bot-tier file's shares (`BotTier.mixedFleetDraw`).
    case mixed

    /// The tier sailing `seat` of the race with `raceSeed`.
    public func tier(ofSeat seat: Int, raceSeed: RaceSeed) -> BotTier {
        switch self {
        case .club: .club
        case .regional: .regional
        case .national: .national
        case .mixed: BotTier.mixedFleetDraw(seed: botSeed(raceSeed: raceSeed, seat: seat)).tier
        }
    }

    /// The live bot sailing `seat` of the race with `raceSeed`, sailing `profile` if the matrix gives the seat one:
    /// its tier's (`BotTier.driver`), or in a Mixed fleet exactly the app's (`BotDriver(seat:raceSeed:)`), her
    /// tier and her skill in it both from the draw.
    public func driver(seat: Int, raceSeed: RaceSeed, profile: BotProfile? = nil) -> BotDriver {
        guard self == .mixed else { return tier(ofSeat: seat, raceSeed: raceSeed).driver(seat: seat, raceSeed: raceSeed, profile: profile) }
        let skill = BotTier.mixedFleetDraw(seed: botSeed(raceSeed: raceSeed, seat: seat)).skill
        return BotDriver(seat: seat, raceSeed: raceSeed, skill: skill, profile: profile)
    }
}

/// The races a suite run sails (#97): every combination of seed × venue × conditions × tide state ×
/// fleet size × tier mix × profile mix (#231), but for a profile mix pinned to other conditions
/// (`ProfileMix.conditionsID`). Venues and conditions are data files named `id@version`.
///
/// Venue and conditions go into each race's setup, and the race is assembled from the files it names
/// (#81): its wind, course and race area come from them. The tide state is recorded but doesn't vary the
/// race: a race draws its tide state at the gun from its race seed and venue (#78), which the report
/// gives as `tideStateAtGunDegrees`, and boats don't feel the current until #79.
public struct BotMatrix: Codable, Hashable, Sendable {
    public var seeds: [UInt64]
    public var venues: [String]
    public var conditions: [String]
    /// Tide states at the gun, degrees through the cycle (as a wind-seed pool names them).
    public var tideStatesDegrees: [Double]
    public var fleetSizes: [Int]
    public var tierMixes: [TierMix]
    /// Which seats sail a scripted profile (#231); `[.live]` when a matrix file has none.
    public var profileMixes: [ProfileMix]
    public var laps: Int
    /// Seconds after the gun a race may sail before the harness stops it; its unfinished boats count
    /// as not finished.
    public var capSecondsAfterGun: Int

    public init(seeds: [UInt64], venues: [String] = ["dev-venue@3"], conditions: [String] = ["classic-oscillating@3"],
                tideStatesDegrees: [Double] = [0], fleetSizes: [Int], tierMixes: [TierMix] = [.mixed],
                profileMixes: [ProfileMix] = [.live], laps: Int = RaceSetup.defaultLaps,
                capSecondsAfterGun: Int = BotMatrix.defaultCapSecondsAfterGun) {
        self.seeds = seeds
        self.venues = venues
        self.conditions = conditions
        self.tideStatesDegrees = tideStatesDegrees
        self.fleetSizes = fleetSizes
        self.tierMixes = tierMixes
        self.profileMixes = profileMixes
        self.laps = laps
        self.capSecondsAfterGun = capSecondsAfterGun
    }

    private enum CodingKeys: String, CodingKey {
        case seeds, venues, conditions, tideStatesDegrees, fleetSizes, tierMixes, profileMixes, laps, capSecondsAfterGun
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(seeds: try c.decode([UInt64].self, forKey: .seeds),
                  venues: try c.decode([String].self, forKey: .venues),
                  conditions: try c.decode([String].self, forKey: .conditions),
                  tideStatesDegrees: try c.decode([Double].self, forKey: .tideStatesDegrees),
                  fleetSizes: try c.decode([Int].self, forKey: .fleetSizes),
                  tierMixes: try c.decode([TierMix].self, forKey: .tierMixes),
                  profileMixes: try c.decodeIfPresent([ProfileMix].self, forKey: .profileMixes) ?? [.live],
                  laps: try c.decode(Int.self, forKey: .laps),
                  capSecondsAfterGun: try c.decode(Int.self, forKey: .capSecondsAfterGun))
    }

    /// As `botFleetCompletesARace` sails its fleet: well past a two-lap race and its finish window.
    public static let defaultCapSecondsAfterGun = 1_500

    /// Every race of the matrix, seeds outermost and profile mixes innermost.
    public var cells: [BotRaceCell] {
        seeds.flatMap { seed in
            venues.flatMap { venue in
                conditions.flatMap { conditions in
                    tideStatesDegrees.flatMap { tide in
                        fleetSizes.flatMap { fleetSize in
                            tierMixes.flatMap { mix in
                                profileMixes.filter { $0.sails(in: conditions) }.map { profiles in
                                    BotRaceCell(seed: seed, venue: venue, conditions: conditions, tideStateDegrees: tide,
                                                fleetSize: fleetSize, tierMix: mix, profileMix: profiles, laps: laps,
                                                capSecondsAfterGun: capSecondsAfterGun)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Throws unless every axis has a value, every fleet size is one a race can have, every data file
    /// is bundled, every venue has a pairing for every conditions, and every profile mix has conditions to
    /// sail in.
    public func validate() throws {
        for (axis, count) in [("seeds", seeds.count), ("venues", venues.count), ("conditions", conditions.count),
                              ("tideStatesDegrees", tideStatesDegrees.count), ("fleetSizes", fleetSizes.count),
                              ("tierMixes", tierMixes.count), ("profileMixes", profileMixes.count)] where count == 0 {
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
        for mix in profileMixes {
            guard let id = mix.conditionsID, !conditions.contains(where: mix.sails(in:)) else { continue }
            throw BotSuiteError.matrix("\(mix.rawValue) sails only in \(id) conditions, which the matrix doesn't name")
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
    public var profileMix: ProfileMix
    public var laps: Int
    public var capSecondsAfterGun: Int

    /// The profile sailing `seat`, or nil for a live bot.
    public func profile(ofSeat seat: Int) -> BotProfile? { profileMix.profile(ofSeat: seat, seed: seed) }
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
