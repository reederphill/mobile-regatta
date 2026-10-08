import Foundation
import RegattaCore

/// How well a bot sails (#19, CONTEXT.md **Bot tier**): Club, Regional or National, each a band of skill
/// (`BotWeaknesses`). A tier is only its band: its bots sail the same boat as everyone (#19: "weaknesses, not a
/// slower boat") with the weaknesses their skills give them. The bands, a Mixed fleet's shares and the place gap
/// between tiers are data, the versioned bot-tier file (`BotTierFile`), placeholders until #105 tunes them.
public enum BotTier: String, Codable, CaseIterable, Hashable, Sendable {
    case club, regional, national

    /// The skills its bots sail at, from the bot-tier file.
    public var skillBand: ClosedRange<Double> { BotTierFile.bundled[self].skillBand }

    /// The skill at `position` (0…1) through the band: 0 its bottom, 1 its top.
    public func skill(at position: Double) -> Double {
        let band = skillBand
        let t = min(max(position, 0), 1)
        return min(max(band.lowerBound + t * (band.upperBound - band.lowerBound), band.lowerBound), band.upperBound)
    }

    /// The skill of the bot with seed `seed` at this tier: where in the band she sails is her seed's first draw
    /// (`skillDraw`), so a tier keeps a spread of skills and never touches the race's streams. Skill is an input to
    /// her brain, never drawn in it (#102).
    public func skill(seed: UInt64) -> Double {
        skill(at: BotTier.skillDraw(seed: seed))
    }

    /// The Mixed-fleet draw (CONTEXT.md **Mixed fleet**): the tier of the bot with seed `seed`, dealt by the bot-tier
    /// file's mix shares, and her skill in it. One draw sets both: it picks the tier by the shares, and where in the
    /// tier's share it fell is where in the band she sails.
    public static func mixedFleetDraw(seed: UInt64) -> (tier: BotTier, skill: Double) {
        let file = BotTierFile.bundled
        let total = allCases.reduce(0) { $0 + file[$1].mixShare }
        var pick = skillDraw(seed: seed) * total
        for tier in allCases {
            let share = file[tier].mixShare
            if pick < share || tier == allCases.last { return (tier, tier.skill(at: share > 0 ? pick / share : 0)) }
            pick -= share
        }
        preconditionFailure("no tiers")
    }

    /// Uniform in [0, 1): the first draw of a bot's seed (`botSeed(raceSeed:seat:)`), which the prototype brain drew
    /// its skill from (0.35 + 0.65 × it). `BotStyle(skill:rng:)` still consumes it, so her style's draws stay put.
    public static func skillDraw(seed: UInt64) -> Double {
        var rng = SplitMix64(seed: seed)
        return rng.unit()
    }
}

/// The versioned bot-tier file (#102): each tier's skill band and share of a Mixed fleet, and the mean-place gap
/// each tier step must keep over mixed fleets. Build-time configuration like the bot suite's matrix and thresholds:
/// a bot's inputs are logged and replays never run brains (ADR 0002), so it isn't part of a race log. As the data
/// files are (ADR 0004), a released version never changes: tuning (#105) ships the next version.
public struct BotTierFile: Codable, Hashable, Sendable {
    public struct Tier: Codable, Hashable, Sendable {
        /// `[lowest, highest]` skill.
        public var skillBand: ClosedRange<Double>
        /// Its share of a Mixed fleet's bots; the shares are weights, normalised over the tiers. Placeholders in proportion
        /// to the bands' widths, so a Mixed fleet's skills spread evenly over the three bands, as the prototype's did.
        public var mixShare: Double

        public init(skillBand: ClosedRange<Double>, mixShare: Double) {
            self.skillBand = skillBand
            self.mixShare = mixShare
        }

        private enum CodingKeys: String, CodingKey { case skillBand, mixShare }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let band = try c.decode([Double].self, forKey: .skillBand)
            guard band.count == 2, band[0] <= band[1], band[0] >= 0, band[1] <= 1 else {
                throw DecodingError.dataCorruptedError(forKey: .skillBand, in: c, debugDescription: "skillBand must be [low, high] in 0...1")
            }
            skillBand = band[0]...band[1]
            mixShare = try c.decode(Double.self, forKey: .mixShare)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode([skillBand.lowerBound, skillBand.upperBound], forKey: .skillBand)
            try c.encode(mixShare, forKey: .mixShare)
        }
    }

    public var id: String
    public var version: Int
    public var club: Tier
    public var regional: Tier
    public var national: Tier
    /// Places, at least, between one tier's mean place and the next's over mixed fleets (#102, placeholder).
    public var minPlaceGap: Double

    public subscript(tier: BotTier) -> Tier {
        switch tier {
        case .club: club
        case .regional: regional
        case .national: national
        }
    }

    /// The file bots sail by.
    public static let currentVersion = 1

    /// The bundled `bot-tiers@<currentVersion>.json`.
    public static let bundled: BotTierFile = {
        do {
            return try load(version: currentVersion)
        } catch {
            preconditionFailure("bot-tiers@\(currentVersion).json: \(error)")
        }
    }()

    /// The bundled `bot-tiers@<version>.json`.
    public static func load(version: Int) throws -> BotTierFile {
        guard let url = Bundle.module.url(forResource: "bot-tiers@\(version)", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let file = try JSONDecoder().decode(BotTierFile.self, from: Data(contentsOf: url))
        guard file.id == "bot-tiers", file.version == version else { throw CocoaError(.fileReadCorruptFile) }
        return file
    }
}

extension BotDriver {
    /// A bot of `tier` for `seat` (practice setup, #131): her skill drawn inside the tier's band from her own seed
    /// (`BotTier.skill(seed:)`), sailing `profile` if the bot suite gives her one (#231).
    public init(seat: Int, raceSeed: RaceSeed, tier: BotTier, profile: BotProfile? = nil) {
        let seed = botSeed(raceSeed: raceSeed, seat: seat)
        self.init(seat: seat, raceSeed: raceSeed, skill: tier.skill(seed: seed), profile: profile)
    }

    /// A bot of `skill` for `seat`, e.g. one derived from a rating: her style drawn from her own seed. `weaknesses`, if
    /// given, replace what her skill and profile give her (`BotProfile.weaknesses(skill:)`): a suite profile's override
    /// (#367), e.g. the novice stand-in's low-skill weaknesses (#370). Nil is the bot she always was.
    public init(seat: Int, raceSeed: RaceSeed, skill: Double, profile: BotProfile? = nil, weaknesses: BotWeaknesses? = nil) {
        var rng = SplitMix64(seed: botSeed(raceSeed: raceSeed, seat: seat))
        self.init(seat: seat, raceSeed: raceSeed, style: BotStyle(skill: skill, rng: &rng), profile: profile,
                  overriding: weaknesses)
    }
}
