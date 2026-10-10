import Foundation
import RegattaCore

/// The reference regatta (#367, #364): about 16 pinned races, each its race seed, wind seed, files, fleet, bot tier,
/// laps and start sequence, read from the versioned `reference-regatta@<version>.json`. The app sails race n with you in
/// seat 0 (`-referenceRace <n>`, Debug builds) and the bot suite sails it with a stand-in there
/// (`BotRaceHarness.runReference`); both build it through `ReferenceRace` and nothing else, so only the helm in seat 0
/// differs. Its seeds are literals in the file, never derived from each other (ADR 0001: a pinned wind seed is for
/// development launches and tests only). As the data files are (ADR 0004), a released version never changes.
public struct ReferenceRegatta: Sendable {
    /// One race of the file, as written.
    public struct Entry: Codable, Hashable, Sendable {
        public var raceSeed: RaceSeed
        public var windSeed: WindSeed
        /// Each data file as `id@version`, a bundled file, untuned.
        public var venue: String
        public var conditions: String
        public var boatClass: String
        public var rulesConfiguration: String
        public var fleetSize: Int
        /// Every bot's tier: her skill drawn inside its band from her own seed (`BotDriver(seat:raceSeed:tier:)`).
        public var tier: BotTier
        public var laps: Int
        public var startSequenceSeconds: Int
    }

    private struct File: Codable {
        var id: String
        var version: Int
        var races: [Entry]
    }

    public let version: Int
    /// The races in the file's order: race n is `races[n - 1]`.
    public let races: [ReferenceRace]

    /// The file the app and the suite sail: version 3, on skiff@8, the default class (#461). Versions 1, on skiff@6, and
    /// 2, on skiff@7, stay bundled.
    public static let currentVersion = 3

    /// The bundled `reference-regatta@<currentVersion>.json`.
    public static let bundled: ReferenceRegatta = {
        do {
            return try load(version: currentVersion)
        } catch {
            preconditionFailure("reference-regatta@\(currentVersion).json: \(error)")
        }
    }()

    /// How many races the bundled file holds: `-referenceRace` takes 1…count.
    public static var count: Int { bundled.races.count }

    /// Race `n` of the bundled file, 1-based: 1…`count`.
    public static func race(_ n: Int) -> ReferenceRace {
        precondition((1...count).contains(n), "reference race \(n) is outside 1…\(count)")
        return bundled.races[n - 1]
    }

    /// The bundled `reference-regatta@<version>.json`, every race built: throws if a race names a file this build
    /// doesn't bundle, a venue that can't host its conditions, or a fleet `RaceSetup` refuses.
    public static func load(version: Int) throws -> ReferenceRegatta {
        guard let url = Bundle.module.url(forResource: "reference-regatta@\(version)", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        guard file.id == "reference-regatta", file.version == version else { throw CocoaError(.fileReadCorruptFile) }
        return try ReferenceRegatta(version: version,
                                    races: file.races.enumerated().map { try ReferenceRace(number: $0.offset + 1, entry: $0.element) })
    }

    private init(version: Int, races: [ReferenceRace]) {
        self.version = version
        self.races = races
    }
}

/// Who sails seat 0 of a reference race in the bot suite (#364 "Stand-in"): a profile at a skill, with weaknesses in
/// place of what her skill and profile give if set. The tactician with none stands in for the owner (#368); a novice
/// stand-in passes low-skill weaknesses (#370).
public struct StandIn: Hashable, Sendable {
    public var profile: BotProfile
    public var skill: Double
    /// Nil: the profile's own at `skill` (`BotProfile.weaknesses(skill:)`).
    public var weaknesses: BotWeaknesses?

    public init(profile: BotProfile, skill: Double = 1, weaknesses: BotWeaknesses? = nil) {
        self.profile = profile
        self.skill = skill
        self.weaknesses = weaknesses
    }

    /// The suite's tactician at skill 1, with no weaknesses (#364: "the tactician (no weaknesses) in the owner's seat").
    public static let tactician = StandIn(profile: .tactician)

    /// The National stand-in (#435, #426 T4): the tactician at skill 1, steering by hand at Club level
    /// (`BotWeaknesses.clubHandSteering`) and with no other weakness. Steering by hand shows only in a class whose
    /// autohelm doesn't hold a centred rudder; in one that does she sails as `tactician`.
    public static let national = StandIn(profile: .tactician,
                                         weaknesses: BotWeaknesses.none(skill: 1).steering(like: .clubHandSteering))

    /// The Club stand-in (#435, #370): the groove-only novice (the baseline at skill 0.35, with that skill's
    /// weaknesses), steering by hand at Club level.
    public static let club = StandIn(profile: .baseline, skill: noviceSkill,
                                     weaknesses: BotWeaknesses(skill: noviceSkill).steering(like: .clubHandSteering))

    /// The novice stand-in's skill (#370): the bottom of Club's band.
    public static let noviceSkill = 0.35

    /// Her driver for `seat` of the race with `raceSeed`.
    public func driver(seat: Int, raceSeed: RaceSeed) -> BotDriver {
        BotDriver(seat: seat, raceSeed: raceSeed, skill: skill, profile: profile, weaknesses: weaknesses)
    }
}

/// Race n of the reference regatta, built (#367): the one place its setup, wind seed and bots come from. The app's
/// `-referenceRace` launch and the suite's `BotRaceHarness.runReference` both take them from here.
public struct ReferenceRace: Hashable, Sendable {
    /// 1-based, as the owner reads it ("race 3 of 16").
    public let number: Int
    public let entry: ReferenceRegatta.Entry
    /// Seat 0 is the human's (or the stand-in's, sailing it through the same input API); every other seat a bot.
    public let setup: RaceSetup
    public let windSeed: WindSeed

    init(number: Int, entry: ReferenceRegatta.Entry) throws {
        self.number = number
        self.entry = entry
        func ref<Content: DataFileContent>(_ name: String, _: Content.Type) throws -> FileRef {
            guard let at = name.lastIndex(of: "@"), let version = Int(name[name.index(after: at)...]) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return try DataFile<Content>.bundled(id: String(name[..<at]), version: version).ref
        }
        guard entry.fleetSize >= 1 else { throw RaceSetupError.fleetSize(entry.fleetSize) }
        setup = try RaceSetup(
            raceSeed: entry.raceSeed,
            seats: [.human] + Array(repeating: .bot, count: entry.fleetSize - 1),
            laps: entry.laps,
            startSequenceTicks: entry.startSequenceSeconds * Race.tickRate,
            boatClass: ref(entry.boatClass, BoatClass.self),
            venue: ref(entry.venue, Venue.self),
            conditions: ref(entry.conditions, Conditions.self),
            rulesConfiguration: ref(entry.rulesConfiguration, RulesConfig.self)
        )
        windSeed = entry.windSeed
        _ = try files()
    }

    public var tier: BotTier { entry.tier }

    /// The files `setup` names, this build's bundled ones.
    public func files() throws -> RaceFiles {
        try RaceFiles(resolving: setup)
    }

    /// The race of record on `setup` and `windSeed` (`Mode.authoritative`), as the app's practice race and the suite
    /// both build it.
    public func race() throws -> Race {
        try Race(setup: setup, files: files(), mode: .authoritative(windSeed: windSeed))
    }

    /// The bot in `seat`: of the file's tier, her skill drawn in its band from her own seed.
    public func driver(seat: Int) -> BotDriver {
        BotDriver(seat: seat, raceSeed: setup.raceSeed, tier: tier)
    }

    /// Every seat's controller: the file's bots in seats 1…, and seat 0 the human's, or `standIn`'s if given.
    public func controllers(standIn: StandIn?) -> SeatControllers {
        SeatControllers(setup.seats.indices.map { seat in
            if seat == 0 { return standIn.map { .bot($0.driver(seat: 0, raceSeed: setup.raceSeed)) } ?? .human }
            return .bot(driver(seat: seat))
        })
    }
}
