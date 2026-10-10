import Foundation
import RegattaCore

// What an online race is sailed in (#146): a venue × conditions pairing from the bundled venue files, drawn uniformly,
// a tide state within the venue's range (drawn from the race seed, as the sim draws it: `CurrentField`), and a wind
// seed from the pool for that venue × conditions × tide state. G1 (map #37): "reuse cap 1. Retire the wind seed from
// the pool at fleet lock; if the drawn pairing's buffer is empty, draw another venue × conditions × tide state".

/// One venue × conditions pairing an online race can be sailed in.
public struct OnlinePairing: Sendable {
    public let venue: DataFile<Venue>
    public let conditions: ConditionsFile

    public init(venue: DataFile<Venue>, conditions: ConditionsFile) {
        self.venue = venue
        self.conditions = conditions
    }

    public var name: String { "\(venue.id)@\(venue.version) × \(conditions.id)@\(conditions.version)" }

    /// Every pairing of the bundled venues `ids` names (the newest version of each), or of every bundled venue but the
    /// dev venue when `ids` is nil, whose conditions file is bundled, in venue then file order.
    public static func bundled(venues ids: [String]? = nil) -> [OnlinePairing] {
        var newest: [String: Int] = [:]
        for key in DataFile<Venue>.bundledKeys() { newest[key.id] = max(newest[key.id] ?? 0, key.version) }
        let chosen = ids ?? newest.keys.filter { $0 != devVenueID }.sorted()
        var pairings: [OnlinePairing] = []
        for id in chosen {
            guard let version = newest[id], let venue = try? DataFile<Venue>.bundled(id: id, version: version) else { continue }
            for pairing in venue.content.pairings {
                guard let conditions = try? ConditionsFile.bundled(id: pairing.conditions.id, version: pairing.conditions.version)
                else { continue }
                pairings.append(OnlinePairing(venue: venue, conditions: conditions))
            }
        }
        return pairings
    }

    /// The venue the sim's tests sail; never an online race's.
    static let devVenueID = "dev-venue"
}

/// Where an online race's wind seeds come from: the vetted pool for each venue × conditions × tide state (#106).
/// `take` retires the seed it returns: G1's reuse cap is 1.
public protocol WindSeedSource: Sendable {
    /// The next seed for `pairing`, retired as it's taken; nil when its buffer is empty.
    mutating func take(for pairing: WindSeedPool.Pairing) -> WindSeed?
}

/// Until #106 vets the real pools: `poolSize` made-up seeds per venue × conditions (the tide state isn't part of the
/// key yet: a pool per exact tide state can't be pre-made for a tide drawn from the race seed; #106 decides how its
/// pools bucket it), each sailed at most `reuseCap` times. Deterministic: the same pairing always has the same seeds.
public struct FixtureWindSeedPools: WindSeedSource {
    public let poolSize: Int
    public let reuseCap: Int
    private var taken: [Key: Int] = [:]

    private struct Key: Hashable {
        let venue: WindSeedPool.FileID
        let conditions: WindSeedPool.FileID
    }

    public init(poolSize: Int, reuseCap: Int = 1) {
        self.poolSize = max(0, poolSize)
        self.reuseCap = max(1, reuseCap)
    }

    public mutating func take(for pairing: WindSeedPool.Pairing) -> WindSeed? {
        let key = Key(venue: pairing.venue, conditions: pairing.conditions)
        let count = taken[key, default: 0]
        guard count < poolSize * reuseCap else { return nil }
        taken[key] = count + 1
        return Self.seed(key.venue, key.conditions, index: count / reuseCap)
    }

    /// Seeds left for a pairing, for tests.
    public func remaining(for pairing: WindSeedPool.Pairing) -> Int {
        poolSize * reuseCap - taken[Key(venue: pairing.venue, conditions: pairing.conditions), default: 0]
    }

    static func seed(_ venue: WindSeedPool.FileID, _ conditions: WindSeedPool.FileID, index: Int) -> WindSeed {
        // FNV-1a of the key, then SplitMix64's `index`th value: stable across runs and platforms (no `Hasher`).
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in "\(venue)|\(conditions)".utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        var rng = SplitMix64(seed: hash)
        var value = rng.next()
        for _ in 0..<index { value = rng.next() }
        return WindSeed(value)
    }
}

/// A race drawn for a fleet: where, in what, and its seeds.
public struct DrawnRace: Sendable {
    public let pairing: OnlinePairing
    public let raceSeed: RaceSeed
    public let windSeed: WindSeed
    /// The pool key the wind seed was taken from: the tide state at the gun in degrees, nil without current.
    public let poolKey: WindSeedPool.Pairing
}

/// Draws a race: pairings in a random order (uniform), the first whose pool has a seed for the race seed's tide state.
public struct RaceDraw: Sendable {
    public let pairings: [OnlinePairing]
    public var seeds: any WindSeedSource

    public init(pairings: [OnlinePairing], seeds: any WindSeedSource) {
        self.pairings = pairings
        self.seeds = seeds
    }

    /// Nil when no pairing has a seed left: the fleet waits (and the server says so) until the pools are topped up.
    public mutating func draw(using rng: inout some RandomNumberGenerator) -> DrawnRace? {
        for pairing in pairings.shuffled(using: &rng) {
            let raceSeed = RaceSeed(rng.next())
            let tide = CurrentField.tideStateAtGun(for: pairing.venue.content, raceSeed: raceSeed).map { $0 * 180 / .pi }
            let key = WindSeedPool.Pairing(venue: .init(id: pairing.venue.id, version: pairing.venue.version),
                                           conditions: .init(id: pairing.conditions.id, version: pairing.conditions.version),
                                           tideStateDegrees: tide)
            guard let windSeed = seeds.take(for: key) else { continue }
            return DrawnRace(pairing: pairing, raceSeed: raceSeed, windSeed: windSeed, poolKey: key)
        }
        return nil
    }
}

/// The matchmaker's random numbers: SplitMix64 from a seed, so a test replays the same draws.
public struct SeededRandom: RandomNumberGenerator, Sendable {
    private var source: SplitMix64

    public init(seed: UInt64) { source = SplitMix64(seed: seed) }

    /// Seeded from the system's generator: production.
    public static func system() -> SeededRandom {
        var system = SystemRandomNumberGenerator()
        return SeededRandom(seed: system.next())
    }

    public mutating func next() -> UInt64 { source.next() }
}
