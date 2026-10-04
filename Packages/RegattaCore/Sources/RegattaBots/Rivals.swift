import RegattaCore

/// One practice race the player finished, as the rivals' history keeps it (#235): the raw facts, so the mapping to a
/// skill (`Rivals.skill(history:tier:)`) can be retuned without rewriting anyone's history.
public struct PracticeFinish: Codable, Hashable, Sendable {
    /// The player's place, 1 = won.
    public var place: Int
    /// Boats in the race, the player's included.
    public var fleetSize: Int
    /// The race's bot tier; nil a Mixed fleet.
    public var tier: BotTier?

    public init(place: Int, fleetSize: Int, tier: BotTier?) {
        self.place = place
        self.fleetSize = fleetSize
        self.tier = tier
    }
}

/// Practice rivals (#235, CONTEXT.md **Rival**): in a practice race, 1–2 bots whose skill is set from the player's
/// recent practice results, so the player usually finishes near them. A rival races like any other bot and targets
/// nobody (#223); only her skill is set. Practice only: online setups never have any, so no rating sees one (#177).
///
/// Build-time bot config, like a tier (ADR 0002): bots' inputs are logged and replays never run a brain, so nothing
/// here reaches a `RaceSetup`, a log or the wire. The window, the linear place map, the small-fleet cut and the count
/// are placeholders, retunable without touching anyone's history.
public enum Rivals {
    /// The newest counted finishes a rival's skill is set from.
    public static let window = 5
    /// Finishes a history keeps: more than the window, so a retune can widen it.
    public static let kept = 10
    /// A race with fewer boats than this says nothing about pace, and doesn't count.
    public static let minFleetSize = 4
    /// Bot seats at or above which a race has two rivals; below, one.
    public static let twoRivalsFrom = 5
    /// Stream tag for `SplitMix64(seed:stream:)` on the race seed, for picking the rivals' seats: ASCII "RIVALS".
    /// Never one of the race's streams, so picking rivals moves no other draw.
    public static let seatStream: UInt64 = 0x5249_5641_4C53

    /// The skill a finish is worth: where the place falls through the finish's tier band (1 = won its top, last its
    /// bottom), linearly. Nil for a fleet under `minFleetSize` or a place outside it.
    public static func skillEquivalent(of finish: PracticeFinish) -> Double? {
        guard finish.fleetSize >= minFleetSize, (1...finish.fleetSize).contains(finish.place) else { return nil }
        let q = Double(finish.fleetSize - finish.place) / Double(finish.fleetSize - 1)
        let band = finish.tier?.skillBand ?? BotTier.mixedBand
        return band.lowerBound + q * (band.upperBound - band.lowerBound)
    }

    /// The rivals' skill for the coming race from `history` (oldest first): the mean skill of its newest `window`
    /// counted finishes, clamped to the coming race's `tier` band, or to the Mixed union for a Mixed fleet. Nil
    /// with no counted finish: no rivals (the first race, a fresh install).
    public static func skill(history: [PracticeFinish], tier: BotTier?) -> Double? {
        let counted = history.compactMap(skillEquivalent(of:)).suffix(window)
        guard !counted.isEmpty else { return nil }
        let mean = counted.reduce(0, +) / Double(counted.count)
        let band = tier?.skillBand ?? BotTier.mixedBand
        return min(max(mean, band.lowerBound), band.upperBound)
    }

    /// `history` with `finish` added, cut to the newest `kept`.
    public static func recording(_ finish: PracticeFinish, in history: [PracticeFinish]) -> [PracticeFinish] {
        Array((history + [finish]).suffix(kept))
    }

    /// The rival seats among `botSeats` in the race with `raceSeed`: two from `twoRivalsFrom` bot seats, else one
    /// (none without a bot seat), picked by a shuffle on the race seed's own rivals stream (`seatStream`).
    public static func seats(raceSeed: RaceSeed, botSeats: [Int]) -> Set<Int> {
        var order = botSeats.sorted()
        var rng = SplitMix64(seed: raceSeed.value, stream: seatStream)
        rng.shuffle(&order)
        return Set(order.prefix(order.count >= twoRivalsFrom ? 2 : 1))
    }

    /// The rival seats of `setup`: among its bot seats.
    public static func seats(setup: RaceSetup) -> Set<Int> {
        seats(raceSeed: setup.raceSeed, botSeats: setup.seats.indices.filter { setup.seats[$0] == .bot })
    }
}

extension BotTier {
    /// A Mixed fleet's skills: the union of every tier's band (CONTEXT.md **Mixed fleet**).
    public static var mixedBand: ClosedRange<Double> {
        let bands = allCases.map(\.skillBand)
        return bands.map(\.lowerBound).min()!...bands.map(\.upperBound).max()!
    }
}
