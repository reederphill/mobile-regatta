import Foundation
import RegattaBots
import RegattaCore

/// A practice race's setup (#25, #19): the venue, its conditions or Random, the bot tier or a Mixed fleet, and the
/// fleet size. Laps and the 60 s start sequence are fixed, and the seed is always random (or `-seed`'s). Kept per
/// device, like `DeviceSettings`: the last choices are the next race's.
struct PracticeSetup: Equatable, Sendable {
    /// The setup's conditions: one of the venue's pairings, by the conditions file's id, or Random.
    enum ConditionsChoice: Hashable, Sendable {
        /// Drawn from the venue's pairings by the race seed, so a `-seed` launch reproduces it.
        case random
        /// The conditions file with this id among the venue's pairings.
        case named(String)
    }

    /// The venue's id (`PracticeVenue.id`).
    var venue = PracticeVenue.defaultID {
        didSet {
            // The conditions on offer change with the venue: a choice the new venue can't have falls back to Random.
            if case .named(let id) = conditions, !(PracticeVenue.named(venue)?.offers(id) ?? false) { conditions = .random }
        }
    }
    var conditions = ConditionsChoice.random
    /// The bots' tier, or nil for a Mixed fleet (the default): bots drawn from all three tiers.
    var botTier: BotTier?
    /// Every boat in the race, yours included.
    var fleetSize = PracticeSetup.defaultFleetSize

    static let fleetSizes = 2...16
    static let defaultFleetSize = 10
    /// Fixed (#245's three laps, over #8's two): no picker. `-laps` still overrides it for UI tests.
    static let laps = RaceSetup.defaultLaps
    /// Fixed (#8): a 60 s countdown.
    static let prestartSeconds = 60.0

    /// The setup page's line on what's fixed, in words (owner, 2026-10-02: off-water screens say it short, words over
    /// numbers): "Three laps. One-minute start."
    static var fixedNote: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = Locale(identifier: "en")
        let laps = formatter.string(from: NSNumber(value: laps)) ?? "\(laps)"
        return "\(laps.prefix(1).uppercased() + laps.dropFirst()) \(laps == "one" ? "lap" : "laps"). One-minute start."
    }

    /// The defaults: what a new install starts with (Hollin Bay, Random conditions, Mixed, 10 boats).
    init() {}

    /// The setup stored in `defaults`, each missing, unknown or out-of-range value at its default.
    init(defaults: UserDefaults) {
        if let id = defaults.string(forKey: Key.venue.rawValue), PracticeVenue.named(id) != nil { venue = id }
        if let id = defaults.string(forKey: Key.conditions.rawValue), id != Self.randomValue,
           PracticeVenue.named(venue)?.offers(id) ?? false {
            conditions = .named(id)
        }
        if let tier = defaults.string(forKey: Key.botTier.rawValue).flatMap(BotTier.init(rawValue:)) { botTier = tier }
        if let size = defaults.object(forKey: Key.fleetSize.rawValue) as? Int, Self.fleetSizes.contains(size) { fleetSize = size }
    }

    /// Writes every value to `defaults`.
    func save(to defaults: UserDefaults) {
        defaults.set(venue, forKey: Key.venue.rawValue)
        switch conditions {
        case .random: defaults.set(Self.randomValue, forKey: Key.conditions.rawValue)
        case .named(let id): defaults.set(id, forKey: Key.conditions.rawValue)
        }
        defaults.set(botTier?.rawValue ?? Self.mixedValue, forKey: Key.botTier.rawValue)
        defaults.set(fleetSize, forKey: Key.fleetSize.rawValue)
    }

    /// Where each value lives in `UserDefaults`.
    enum Key: String, CaseIterable {
        case venue = "practice.venue"
        case conditions = "practice.conditions"
        case botTier = "practice.botTier"
        case fleetSize = "practice.fleetSize"
    }

    private static let randomValue = "random"
    private static let mixedValue = "mixed"

    /// The setup's venue, or the default one if this build doesn't have it.
    var practiceVenue: PracticeVenue { PracticeVenue.named(venue) ?? PracticeVenue.all[0] }

    /// The conditions a race on `seed` sails: the chosen ones, or for Random one of the venue's pairings drawn from a
    /// stream keyed by the race seed.
    func conditionsOption(seed: UInt64) -> PracticeVenue.Option {
        let venue = practiceVenue
        if case .named(let id) = conditions, let option = venue.conditions.first(where: { $0.id == id }) { return option }
        var rng = SplitMix64(seed: seed ^ 0x434F_4E44_4954_4E53) // "CONDITNS"
        return venue.conditions[Int(rng.next() % UInt64(venue.conditions.count))]
    }

    /// The practice race this setup starts on `seed` and `windSeed`: you and `fleetSize - 1` bots of `botTier` (or a
    /// Mixed fleet), at the venue on its conditions, with the fixed laps and start sequence. `rivalSkill` (#235,
    /// `PracticeSetup.rivalSkill(history:)`) gives the race its rivals; nil, none.
    func config(seed: UInt64, windSeed: UInt64, rivalSkill: Double? = nil) -> RaceConfig {
        let fleet = min(max(fleetSize, Self.fleetSizes.lowerBound), Self.fleetSizes.upperBound)
        var config = RaceConfig(opponents: fleet - 1, laps: Self.laps, prestartSeconds: Self.prestartSeconds,
                                seed: seed, windSeed: windSeed)
        config.botTier = botTier
        config.rivalSkill = rivalSkill
        config.files.venue = practiceVenue.ref
        config.files.conditions = conditionsOption(seed: seed).ref
        return config
    }

    /// The rivals' skill for a race on this setup from your practice `history` (#235): set from your recent results,
    /// clamped to `botTier`'s band (or the Mixed union). Nil with no counted result: no rivals.
    func rivalSkill(history: [PracticeFinish]) -> Double? {
        Rivals.skill(history: history, tier: botTier)
    }
}

/// A venue practice offers (#25: three, by name), with the conditions its pairings name, in file order. Loaded once
/// from the bundled files, at each venue's newest bundled version.
struct PracticeVenue: Identifiable, Equatable, Sendable {
    /// One of the venue's conditions.
    struct Option: Identifiable, Equatable, Sendable {
        /// The conditions file's id.
        let id: String
        let name: String
        let ref: FileRef
    }

    let id: String
    let name: String
    let ref: FileRef
    let conditions: [Option]

    /// The v1.0 venues, in the order the setup lists them. The first is the default.
    static let ids = ["hollin-bay", "saltings-reach", "fellmere"]
    static let defaultID = ids[0]

    /// Every practice venue this build ships.
    static let all: [PracticeVenue] = ids.compactMap { load($0) }

    static func named(_ id: String) -> PracticeVenue? { all.first { $0.id == id } }

    func offers(_ conditionsID: String) -> Bool { conditions.contains { $0.id == conditionsID } }

    private static func load(_ id: String) -> PracticeVenue? {
        guard let key = VenueFile.bundledKeys().last(where: { $0.id == id }),
              let venue = try? VenueFile.bundled(id: key.id, version: key.version) else { return nil }
        let options = venue.content.pairings.compactMap { pairing -> Option? in
            guard let file = try? ConditionsFile.bundled(id: pairing.conditions.id, version: pairing.conditions.version) else {
                return nil
            }
            return Option(id: file.ref.id, name: file.content.name, ref: file.ref)
        }
        guard !options.isEmpty else { return nil }
        return PracticeVenue(id: id, name: venue.content.displayName, ref: venue.ref, conditions: options)
    }
}
