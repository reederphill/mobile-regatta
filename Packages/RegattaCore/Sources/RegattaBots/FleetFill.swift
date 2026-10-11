import Foundation
import RegattaCore

/// The versioned skill ↔ rating map (#19, #149): what skill an online bot of a given rating sails at. Build-time
/// configuration like the bot-tier file (`BotTierFile`): a bot's inputs are logged and replays never run brains
/// (ADR 0002), so it isn't part of a race log. A released version never changes (ADR 0004): tuning ships the next.
/// Version 1's values are placeholders.
public struct BotRatingMap: Codable, Hashable, Sendable {
    public struct Point: Codable, Hashable, Sendable {
        public var rating: Int
        public var skill: Double

        public init(rating: Int, skill: Double) {
            self.rating = rating
            self.skill = skill
        }
    }

    public var id: String
    public var version: Int
    /// By rating, ascending; skills never fall.
    public var points: [Point]

    public init(id: String = "bot-ratings", version: Int, points: [Point]) {
        self.id = id
        self.version = version
        self.points = points
    }

    /// Whether the points make a map: two or more, ratings strictly rising, skills in 0…1 and never falling.
    public var isValid: Bool {
        points.count >= 2 && points.allSatisfy { (0...1).contains($0.skill) }
            && zip(points, points.dropFirst()).allSatisfy { $0.rating < $1.rating && $0.skill <= $1.skill }
    }

    /// The skills an online bot may sail at: Club's lowest to 1, whatever the points say.
    public static var skillRange: ClosedRange<Double> { BotTier.club.skillBand.lowerBound...1 }

    /// The skill of a bot rated `rating`: on the straight line between the points either side of it, the first
    /// point's below them and the last's above, kept inside `skillRange`.
    public func skill(rating: Int) -> Double {
        let range = BotRatingMap.skillRange
        func clamped(_ skill: Double) -> Double { min(max(skill, range.lowerBound), range.upperBound) }
        guard let first = points.first, let last = points.last else { return range.lowerBound }
        if rating <= first.rating { return clamped(first.skill) }
        if rating >= last.rating { return clamped(last.skill) }
        for (low, high) in zip(points, points.dropFirst()) where rating <= high.rating {
            let t = Double(rating - low.rating) / Double(high.rating - low.rating)
            return clamped(low.skill + t * (high.skill - low.skill))
        }
        return clamped(last.skill)
    }

    /// The map online bots sail by.
    public static let currentVersion = 1

    /// The bundled `bot-ratings@<currentVersion>.json`.
    public static let bundled: BotRatingMap = {
        do {
            return try load(version: currentVersion)
        } catch {
            preconditionFailure("bot-ratings@\(currentVersion).json: \(error)")
        }
    }()

    /// The bundled `bot-ratings@<version>.json`.
    public static func load(version: Int) throws -> BotRatingMap {
        guard let url = Bundle.module.url(forResource: "bot-ratings@\(version)", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try decode(Data(contentsOf: url), version: version)
    }

    /// A map file's bytes, refused unless they are version `version` of the bot-ratings file and a map (`isValid`).
    public static func decode(_ data: Data, version: Int) throws -> BotRatingMap {
        let map = try JSONDecoder().decode(BotRatingMap.self, from: data)
        guard map.id == "bot-ratings", map.version == version, map.isValid else { throw CocoaError(.fileReadCorruptFile) }
        return map
    }
}

/// What an online bot is, apart from her seed's style: recorded with the race (`race_bots`, #149) for the shadow
/// ratings (#177). Never in the race log.
public struct BotPlan: Hashable, Sendable {
    /// The rating she was given: the fleet's median, plus her seat's offset.
    public var rating: Int
    /// The skill the map gives that rating.
    public var skill: Double
    /// Her handling skill (#443), drawn from her seed in the band of the tier holding her skill.
    public var handling: Double
    /// The version of the map that turned her rating into her skill.
    public var mapVersion: Int

    public init(rating: Int, skill: Double, handling: Double, mapVersion: Int) {
        self.rating = rating
        self.skill = skill
        self.handling = handling
        self.mapVersion = mapVersion
    }
}

/// The bots of an online fleet (#19, #149): the ones that fill it at fleet lock, and the one that takes a seat its
/// player gave up before the gun. Each is rated at the fleet's median human rating, give or take `ratingSpread`, and
/// sails at the skill the map gives that rating. Pure: the same fleet, seat and race seed give the same bot.
///
/// Her offset is the first draw of her own seed (`botSeed(raceSeed:seat:)`) on a stream of its own (`ratingStream`),
/// so it moves no other draw of hers, and nothing of the race's, the matchmaker's or the clock's is read (#60).
public struct FleetFill: Hashable, Sendable {
    /// A bot's rating is within this of the fleet's median (#19).
    public static let ratingSpread = 150

    public let medianRating: Int
    public let map: BotRatingMap

    public init(medianRating: Int, map: BotRatingMap = .bundled) {
        self.medianRating = medianRating
        self.map = map
    }

    /// The fleet whose humans are rated `humanRatings`; with none, `fallback`.
    public init(humanRatings: [Int], fallback: Int, map: BotRatingMap = .bundled) {
        self.init(medianRating: FleetFill.median(humanRatings) ?? fallback, map: map)
    }

    /// The middle rating; for an even count the mean of the middle two, rounded half up. Nil for none.
    public static func median(_ ratings: [Int]) -> Int? {
        guard !ratings.isEmpty else { return nil }
        let sorted = ratings.sorted(), middle = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[middle] }
        return Int((Double(sorted[middle - 1] + sorted[middle]) / 2).rounded(.up))
    }

    /// Whole points from the median, uniform in −`ratingSpread`…`ratingSpread`: its own arithmetic on the seat's
    /// rating stream, so a seed gives the same offset on every platform.
    public static func ratingOffset(seed: UInt64) -> Int {
        var rng = SplitMix64(seed: seed, stream: ratingStream)
        return Int(rng.next() % UInt64(2 * ratingSpread + 1)) - ratingSpread
    }

    /// Stream tag for `SplitMix64(seed:stream:)` on her bot seed: ASCII "botrate".
    static let ratingStream: UInt64 = 0x0062_6F74_7261_7465

    /// The bot for `seat`: her rating, and the skill and handling she sails at.
    public func plan(seat: Int, raceSeed: RaceSeed) -> BotPlan {
        let seed = botSeed(raceSeed: raceSeed, seat: seat)
        let rating = medianRating + FleetFill.ratingOffset(seed: seed)
        let skill = map.skill(rating: rating)
        return BotPlan(rating: rating, skill: skill, handling: BotTier.holding(skill: skill).handling(seed: seed), mapVersion: map.version)
    }

    /// The driver that sails `seat` from the start: her style from her own seed, at her plan's skill and handling. No
    /// tier label and no suite profile. One that takes a seat over is `driver(...).takingOver()`.
    public func driver(seat: Int, raceSeed: RaceSeed) -> BotDriver {
        let plan = plan(seat: seat, raceSeed: raceSeed)
        return BotDriver(seat: seat, raceSeed: raceSeed, skill: plan.skill, handling: plan.handling)
    }
}

/// What an online fleet's bots are called and wear (#19, #149): a sailing name and a free starter livery each, from
/// the seat's own seed. Built at fleet lock; a seat a player gives up before the gun is dressed when it is taken
/// (`takeOver(seat:)`), so no name already showing ever changes. Pure.
public struct BotDressing: Hashable, Sendable {
    public let raceSeed: RaceSeed
    public let boatClass: String
    /// Each bot seat's sailing name, by seat; nil for a seat a player sails.
    public private(set) var names: [String?]

    /// The setup's bot seats, named as `FleetRoster` names them (what a client derives from the setup alone).
    public init(setup: RaceSetup) {
        raceSeed = setup.raceSeed
        boatClass = setup.boatClass.id
        names = FleetRoster(setup: setup).entries.map(\.sailingName)
    }

    public func isBot(seat: Int) -> Bool { names.indices.contains(seat) && names[seat] != nil }

    /// A bot takes `seat` from its player: she gets the name her seed picks, moved on past every name a bot of this
    /// fleet already has (the probe `FleetRoster` uses). Returns it; a seat that is a bot's already keeps its name.
    @discardableResult
    public mutating func takeOver(seat: Int) -> String {
        if let name = names[seat] { return name }
        let all = FleetRoster.sailingNames
        let taken = Set(names.compactMap { $0 })
        var index = Int(botSeed(raceSeed: raceSeed, seat: seat) % UInt64(all.count))
        // A fleet has at most 16 boats and there are 24 names: one is always free.
        while taken.contains(all[index]) { index = (index + 1) % all.count }
        names[seat] = all[index]
        return all[index]
    }

    /// The livery a bot in `seat` wears (#19, #21): a free starter design, colours and a sail number from the seat's
    /// bot seed, the same everywhere the seed is known (the client draws it from the same seed). Never an earned or
    /// paid design. Nil if the catalogue has no free design for the class. The fleet's shown sail numbers are
    /// `LiveryCatalogue.raceSailNumbers` over all its liveries.
    public func livery(seat: Int, catalogue: LiveryCatalogue) -> Livery? {
        BotDressing.livery(seat: seat, raceSeed: raceSeed, boatClass: boatClass, catalogue: catalogue)
    }

    public static func livery(seat: Int, raceSeed: RaceSeed, boatClass: String, catalogue: LiveryCatalogue) -> Livery? {
        catalogue.botLivery(boatClass: boatClass, seed: botSeed(raceSeed: raceSeed, seat: seat))
    }
}
