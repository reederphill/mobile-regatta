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
    /// The hunters scenario (#355): hunters (`BotProfile.hunter`) among live bots, one in a fleet under ten (a 1-v-1
    /// against a hunter in a two-boat race), two in a fleet of ten or more, half the fleet apart; the hunters' seats
    /// one further along for each seed, as the fun pass's. Sailed only when named (`--profile-mix hunters`), never in
    /// the bundled matrix; its races stay out of the live tiers the thresholds gate (`BotSuiteReport.tiers`).
    case hunters
    /// Execution against tactics (#222, #105): the executor (`BotProfile.executor`: the baseline's tactics, every roll
    /// hit) and the tactician at Club-level execution (`BotProfile.tacticianClubExecution`: half her rolls miss) by turns,
    /// as the skill gap's seats alternate. Sailed in all-National fleets only (`tierMix`): profiles take no tier, but
    /// their skill, drawn in the tier's band, must clear the roll floor (`BotWeaknesses.rollSkillFloor`) to roll at all.
    case execution
    /// One cautious bot (CONTEXT.md **Cautious bot**, #104, `BotDriver.cautious`) among live bots of the cell's tier mix
    /// (#105: "1 cautious + rest"): seat `seed % fleetSize`, rotating with the seed as `CautiousBotSuiteTests` rotates
    /// it. Its races stay out of the live tiers the thresholds gate (`gatesLiveTiers`); `BotSuiteReport.cautious`
    /// reports the cautious seats.
    case cautious
    /// Practice rivals (#235, #105): seat 0 stands in for the player, a bot at skill s, and the race's rivals
    /// (`Rivals.seats`) sail at the same s; the rest are a Mixed fleet (`tierMix`). s cycles through `rivalSkills` with
    /// the seed. Reported as `BotSuiteReport.rivals`, the rival pace band (`RivalLimits`). The bundled matrix sails it in
    /// fleets of 10 alone (`BotMatrix.mixFleetSizes`), as is rank stability.
    case rivals
    /// Rank stability (#105): every seat at a fixed skill (`rankSkills`, the centres of the tiers' bands, by turns,
    /// one seat further along for each seed), so a fleet of a fixed mix of skills races over the seeds. Reported as
    /// `BotSuiteReport.rank`: how well skill orders the finish (Spearman), and how far boats of one skill spread.
    case rankStability
    /// Hand steering (#435): the baseline and the tactician each steering by hand perfectly and at Club level
    /// (`BotProfile.clubSteering`, `tacticianClubSteering`), the four by turns, one seat further along for each seed, so
    /// the per-leg dividend of steering well is measured with tactics and without. Steering by hand shows only in a class
    /// whose autohelm doesn't hold a centred rudder: the default class since #437, or `--autohelm off` (`BotMatrix.handSteers`). Sailed only
    /// when named (`--profile-mix handling`), never in the bundled matrix; all-National fleets, as `execution`; its races
    /// stay out of the live tiers the thresholds gate and out of the skill gap. `BotSuiteReport.handling` reports it.
    case handling

    /// The profile sailing `seat` in a race of `fleetSize` boats with race seed `seed`, or nil for a live bot. Only the
    /// hunters mix reads the fleet size, but every mix needs it: a seat of the fleet.
    public func profile(ofSeat seat: Int, seed: UInt64, fleetSize: Int) -> BotProfile? {
        precondition(fleetSize > 0 && (0..<fleetSize).contains(seat), "seat \(seat) of a fleet of \(fleetSize)")
        return switch self {
        case .live, .cautious, .rivals, .rankStability: nil
        case .skillGap: (seat + Int(seed % 2)).isMultiple(of: 2) ? .baseline : .tactician
        case .funPass: [BotProfile.baseline, .tactician, .blipTacker][(seat + Int(seed % 3)) % 3]
        case .hunters:
            ProfileMix.isHunterSeat(seat, seed: seed, fleetSize: fleetSize) ? .hunter : nil
        case .execution: (seat + Int(seed % 2)).isMultiple(of: 2) ? .executor : .tacticianClubExecution
        case .handling: ProfileMix.handlingProfiles[(seat + Int(seed % 4)) % 4]
        }
    }

    /// The handling mix's profiles, by turns: perfect and Club hand steering, without tactics and with.
    public static let handlingProfiles: [BotProfile] = [.baseline, .clubSteering, .tactician, .tacticianClubSteering]

    /// The seat the cautious bot sails in the cautious mix (#105), or none in another mix.
    public func cautiousSeats(seed: UInt64, fleetSize: Int) -> Set<Int> {
        self == .cautious ? [Int(seed % UInt64(fleetSize))] : []
    }

    /// The skills seats sail at in place of their tier mix's draw (`BotRaceHarness.run(_:cautiousSeats:seatSkills:)`):
    /// the rivals mix's seat 0 and rivals, and every seat of the rank-stability mix; none in another mix.
    public func seatSkills(seed: UInt64, fleetSize: Int) -> [Int: Double] {
        switch self {
        case .rivals:
            let skill = ProfileMix.rivalSkill(seed: seed)
            var skills = [0: skill]
            for rival in ProfileMix.rivalSeats(seed: seed, fleetSize: fleetSize) { skills[rival] = skill }
            return skills
        case .rankStability:
            return Dictionary(uniqueKeysWithValues: (0..<fleetSize).map { ($0, ProfileMix.rankSkill(ofSeat: $0, seed: seed)) })
        default:
            return [:]
        }
    }

    /// The skills the rivals mix's player stand-in and her rivals sail at, by turns with the seed: #235's acceptance's.
    public static let rivalSkills = [0.45, 0.7, 0.9]

    static func rivalSkill(seed: UInt64) -> Double { rivalSkills[Int(seed % UInt64(rivalSkills.count))] }

    /// The rivals mix's rivals of seat 0 (`Rivals.seats`, as the app picks them): drawn from the race seed among the
    /// other seats.
    static func rivalSeats(seed: UInt64, fleetSize: Int) -> Set<Int> {
        fleetSize < 2 ? [] : Rivals.seats(raceSeed: RaceSeed(seed), botSeats: Array(1..<fleetSize))
    }

    /// The rank-stability mix's skills: the centre of each tier's band, Club to National.
    public static var rankSkills: [Double] { BotTier.allCases.map { $0.skill(at: 0.5) } }

    static func rankSkill(ofSeat seat: Int, seed: UInt64) -> Double {
        let skills = rankSkills
        return skills[(seat + Int(seed % UInt64(skills.count))) % skills.count]
    }

    /// Whether the live seats of the mix's races are the live tiers' the thresholds gate (`BotSuiteReport.tiers`): not
    /// those racing hunters, a cautious bot, or at a skill set by the mix.
    public var gatesLiveTiers: Bool {
        switch self {
        case .live, .skillGap, .funPass, .execution: true
        case .hunters, .cautious, .rivals, .rankStability, .handling: false
        }
    }

    /// The tier mix the mix is sailed in, of those the matrix names; nil for any the matrix names. A mix whose seats
    /// take no tier from it (profiles, or skills it sets) would only repeat its races in each. A matrix that names the
    /// mix but not its tier mix sails none of its races, so `validate` refuses it; the command line's `--tier-mix`
    /// leaves out the mixes it can't sail unless `--profile-mix` names them (`BotSuiteOptions.matrix`).
    public var tierMix: TierMix? {
        switch self {
        case .live, .skillGap, .funPass, .hunters, .cautious: nil
        case .execution, .handling: .national
        case .rivals, .rankStability: .mixed
        }
    }

    /// Whether `seat` of a fleet of `fleetSize` sails the hunter in the hunters mix on seed `seed`: every
    /// `fleetSize / 2`th seat in a fleet of ten or more, else one seat, rotating with the seed.
    static func isHunterSeat(_ seat: Int, seed: UInt64, fleetSize: Int) -> Bool {
        let spacing = fleetSize >= 10 ? fleetSize / 2 : fleetSize
        return (seat + Int(seed % UInt64(spacing))) % spacing == 0
    }

    /// The conditions file the mix is sailed in, by id, whatever its version; nil for any the matrix names.
    /// The fun pass's numbers (#221) are for an oscillating breeze: a matrix sails it in no other conditions.
    public var conditionsID: String? {
        switch self {
        case .live, .skillGap, .hunters, .execution, .cautious, .rivals, .rankStability, .handling: nil
        case .funPass: "classic-oscillating"
        }
    }

    /// Whether the mix is sailed in `tierMix` (`ProfileMix.tierMix`).
    public func sails(in tierMix: TierMix) -> Bool { self.tierMix.map { $0 == tierMix } ?? true }

    /// Whether the mix is sailed in `conditions`, a data file named `id@version`.
    public func sails(in conditions: String) -> Bool {
        guard let id = conditionsID else { return true }
        return (try? dataFileKey(conditions))?.id == id
    }
}

extension ProfileMix: CodingKeyRepresentable {}

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
    /// tier and her skill in it both from the draw, her handling in that tier's handling band (#443).
    public func driver(seat: Int, raceSeed: RaceSeed, profile: BotProfile? = nil) -> BotDriver {
        guard self == .mixed else { return tier(ofSeat: seat, raceSeed: raceSeed).driver(seat: seat, raceSeed: raceSeed, profile: profile) }
        return BotDriver(seat: seat, raceSeed: raceSeed, profile: profile)
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
    /// The conditions a venue sails, of `conditions`, by venue (`id@version`), for a venue that pairs with only some of
    /// them (#316: the real venues pair with two each); a venue not in it sails every one. Empty when a matrix file
    /// has none.
    public var conditionsByVenue: [String: [String]]
    /// Tide states at the gun, degrees through the cycle (as a wind-seed pool names them).
    public var tideStatesDegrees: [Double]
    public var fleetSizes: [Int]
    public var tierMixes: [TierMix]
    /// Which seats sail a scripted profile (#231); `[.live]` when a matrix file has none.
    public var profileMixes: [ProfileMix]
    /// The one fleet size a profile mix is sailed in, of `fleetSizes`, for a mix whose summary must not pool fleets
    /// (#105: the rank correlation and the rival mean place, which a two-boat race would skew); every fleet size for a
    /// mix not in it. Empty when a matrix file has none.
    public var mixFleetSizes: [ProfileMix: Int]
    public var laps: Int
    /// Seconds after the gun a race may sail before the harness stops it; its unfinished boats count
    /// as not finished.
    public var capSecondsAfterGun: Int
    /// Sail every race on a copy of its class with the autohelm off a centred rudder (#435, `--autohelm off`), so the
    /// bots steer by hand (`BotHelm`); false sails the class as bundled. Left out of a matrix file when false.
    public var autohelmOff = false

    /// The bots steer by hand: the matrix sails a copy with the autohelm off, or the default class's autohelm already
    /// doesn't hold a centred rudder (skiff@7, the default since #437).
    public var handSteers: Bool {
        autohelmOff || !RaceFiles.defaults.boatClass.content.steering.autohelm.holdsWhenCentred
    }

    public init(seeds: [UInt64], venues: [String] = ["dev-venue@3"], conditions: [String] = ["classic-oscillating@3"],
                conditionsByVenue: [String: [String]] = [:], tideStatesDegrees: [Double] = [0], fleetSizes: [Int], tierMixes: [TierMix] = [.mixed],
                profileMixes: [ProfileMix] = [.live], mixFleetSizes: [ProfileMix: Int] = [:], laps: Int = RaceSetup.defaultLaps,
                capSecondsAfterGun: Int = BotMatrix.defaultCapSecondsAfterGun, autohelmOff: Bool = false) {
        self.seeds = seeds
        self.venues = venues
        self.conditions = conditions
        self.conditionsByVenue = conditionsByVenue
        self.tideStatesDegrees = tideStatesDegrees
        self.fleetSizes = fleetSizes
        self.tierMixes = tierMixes
        self.profileMixes = profileMixes
        self.mixFleetSizes = mixFleetSizes
        self.laps = laps
        self.capSecondsAfterGun = capSecondsAfterGun
        self.autohelmOff = autohelmOff
    }

    private enum CodingKeys: String, CodingKey {
        case seeds, venues, conditions, conditionsByVenue, tideStatesDegrees, fleetSizes, tierMixes, profileMixes, mixFleetSizes, laps
        case capSecondsAfterGun, autohelmOff
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(seeds: try c.decode([UInt64].self, forKey: .seeds),
                  venues: try c.decode([String].self, forKey: .venues),
                  conditions: try c.decode([String].self, forKey: .conditions),
                  conditionsByVenue: try c.decodeIfPresent([String: [String]].self, forKey: .conditionsByVenue) ?? [:],
                  tideStatesDegrees: try c.decode([Double].self, forKey: .tideStatesDegrees),
                  fleetSizes: try c.decode([Int].self, forKey: .fleetSizes),
                  tierMixes: try c.decode([TierMix].self, forKey: .tierMixes),
                  profileMixes: try c.decodeIfPresent([ProfileMix].self, forKey: .profileMixes) ?? [.live],
                  mixFleetSizes: try c.decodeIfPresent([ProfileMix: Int].self, forKey: .mixFleetSizes) ?? [:],
                  laps: try c.decode(Int.self, forKey: .laps),
                  capSecondsAfterGun: try c.decode(Int.self, forKey: .capSecondsAfterGun),
                  autohelmOff: try c.decodeIfPresent(Bool.self, forKey: .autohelmOff) ?? false)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(seeds, forKey: .seeds)
        try c.encode(venues, forKey: .venues)
        try c.encode(conditions, forKey: .conditions)
        // Left out when empty, so a matrix without it encodes as it did before #316.
        if !conditionsByVenue.isEmpty { try c.encode(conditionsByVenue, forKey: .conditionsByVenue) }
        try c.encode(tideStatesDegrees, forKey: .tideStatesDegrees)
        try c.encode(fleetSizes, forKey: .fleetSizes)
        try c.encode(tierMixes, forKey: .tierMixes)
        try c.encode(profileMixes, forKey: .profileMixes)
        try c.encode(mixFleetSizes, forKey: .mixFleetSizes)
        try c.encode(laps, forKey: .laps)
        try c.encode(capSecondsAfterGun, forKey: .capSecondsAfterGun)
        // Left out when false, so a matrix without it encodes as it did before #435.
        if autohelmOff { try c.encode(autohelmOff, forKey: .autohelmOff) }
    }

    /// The conditions `venue` sails, in `conditions`' order: those `conditionsByVenue` names for it, else all.
    public func conditions(at venue: String) -> [String] {
        guard let named = conditionsByVenue[venue] else { return conditions }
        return conditions.filter(named.contains)
    }

    /// As `botFleetCompletesARace` sails its fleet: well past a two-lap race and its finish window.
    public static let defaultCapSecondsAfterGun = 1_500

    /// Every race of the matrix, seeds outermost and profile mixes innermost; each venue in the conditions it sails
    /// (`conditions(at:)`).
    public var cells: [BotRaceCell] {
        seeds.flatMap { seed in
            venues.flatMap { venue in
                self.conditions(at: venue).flatMap { conditions in
                    tideStatesDegrees.flatMap { tide in
                        fleetSizes.flatMap { fleetSize in
                            tierMixes.flatMap { mix in
                                profileMixes.filter {
                                    $0.sails(in: conditions) && $0.sails(in: mix) && sails($0, inFleetOf: fleetSize)
                                }.map { profiles in
                                    BotRaceCell(seed: seed, venue: venue, conditions: conditions, tideStateDegrees: tide,
                                                fleetSize: fleetSize, tierMix: mix, profileMix: profiles, laps: laps,
                                                capSecondsAfterGun: capSecondsAfterGun, autohelmOff: autohelmOff ? true : nil)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Whether `mix` is sailed in fleets of `size` (`mixFleetSizes`).
    public func sails(_ mix: ProfileMix, inFleetOf size: Int) -> Bool { mixFleetSizes[mix].map { $0 == size } ?? true }

    /// Whether the matrix sails any race of `mix`: it names conditions, a tier mix and a fleet size the mix is sailed in.
    public func sailsAny(_ mix: ProfileMix) -> Bool {
        venues.contains { conditions(at: $0).contains(where: mix.sails(in:)) } && tierMixes.contains(where: mix.sails(in:))
            && fleetSizes.contains { sails(mix, inFleetOf: $0) }
    }

    /// Throws unless every axis has a value, every fleet size is one a race can have, every data file
    /// is bundled, every venue has a pairing for every conditions it sails (`conditions(at:)`: `conditionsByVenue` names
    /// only venues and conditions of the matrix, at least one each), and every profile mix sails at least one race:
    /// a gate that sails nothing would pass without measuring anything (#105), so it fails loudly instead.
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
        for (venue, named) in conditionsByVenue.sorted(by: { $0.key < $1.key }) {
            guard venues.contains(venue) else { throw BotSuiteError.matrix("conditionsByVenue names \(venue), which venues doesn't") }
            for conditions in named where !self.conditions.contains(conditions) {
                throw BotSuiteError.matrix("conditionsByVenue gives \(venue) \(conditions), which conditions doesn't name")
            }
            if named.isEmpty { throw BotSuiteError.matrix("conditionsByVenue gives \(venue) no conditions") }
        }
        for venue in venues {
            let venueKey = try dataFileKey(venue)
            let file = try VenueFile.bundled(id: venueKey.id, version: venueKey.version)
            for conditions in self.conditions(at: venue) {
                let key = try dataFileKey(conditions)
                _ = try ConditionsFile.bundled(id: key.id, version: key.version)
                guard file.content.pairing(for: key) != nil else {
                    throw BotSuiteError.matrix("\(venue) has no pairing for \(conditions)")
                }
            }
        }
        for mix in profileMixes {
            if let id = mix.conditionsID, !venues.contains(where: { conditions(at: $0).contains(where: mix.sails(in:)) }) {
                throw BotSuiteError.matrix("\(mix.rawValue) sails only in \(id) conditions, which the matrix doesn't name")
            }
            if let tierMix = mix.tierMix, !tierMixes.contains(tierMix) {
                throw BotSuiteError.matrix("\(mix.rawValue) sails only in a \(tierMix.rawValue) fleet, which the matrix doesn't name")
            }
            if let size = mixFleetSizes[mix], !fleetSizes.contains(size) {
                throw BotSuiteError.matrix("\(mix.rawValue) sails only in a fleet of \(size), which the matrix doesn't name")
            }
        }
        if profileMixes.contains(.handling) {
            // Hand steering shows only where the autohelm doesn't hold a centred rudder, and the mix deals four
            // profiles by turns, so a smaller fleet would leave one unsailed.
            guard handSteers else {
                throw BotSuiteError.matrix("handling measures hand steering, which shows only with autohelmOff (--autohelm off)")
            }
            let needed = ProfileMix.handlingProfiles.count
            if let size = fleetSizes.filter({ sails(.handling, inFleetOf: $0) }).min(), size < needed {
                throw BotSuiteError.matrix("handling deals \(needed) profiles, so it needs fleets of at least \(needed); the matrix sails it in a fleet of \(size)")
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
    public var profileMix: ProfileMix
    public var laps: Int
    public var capSecondsAfterGun: Int
    /// True: sailed on a copy of the class with the autohelm off a centred rudder (#435, `BotMatrix.autohelmOff`); nil
    /// for the class as bundled, and left out of the report then.
    public var autohelmOff: Bool? = nil

    /// The profile sailing `seat`, or nil for a live bot.
    public func profile(ofSeat seat: Int) -> BotProfile? { profileMix.profile(ofSeat: seat, seed: seed, fleetSize: fleetSize) }
    /// The seats the cautious bot sails (`ProfileMix.cautiousSeats`).
    public var cautiousSeats: Set<Int> { profileMix.cautiousSeats(seed: seed, fleetSize: fleetSize) }
    /// The seats sailing at a skill the mix sets (`ProfileMix.seatSkills`).
    public var seatSkills: [Int: Double] { profileMix.seatSkills(seed: seed, fleetSize: fleetSize) }
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
