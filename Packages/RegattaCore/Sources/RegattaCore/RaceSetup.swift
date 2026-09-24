/// Who holds a seat when it's filled: a player, or a bot filling an empty seat.
public enum SeatKind: String, Codable, Hashable, Sendable {
    case human
    case bot
}

/// The public race seed: boat placement, start order and bot styles (#35, #19). Every client gets it
/// in the join/resync message (#18), so nothing secret may come from it; in particular the wind
/// never does (ADR 0001).
public struct RaceSeed: Hashable, Sendable {
    public let value: UInt64
    public init(_ value: UInt64) { self.value = value }
}

/// Keys the wind. Online it stays on the server, which reveals the wind one window ahead (ADR 0001);
/// for a practice race it's held on the device. Deliberately a separate type from `RaceSeed`, kept
/// out of `RaceSetup` and never derived from the race seed. Until the keyed wind lands it is the
/// single seed of `WindField`.
public struct WindSeed: Hashable, Sendable {
    public let value: UInt64
    public init(_ value: UInt64) { self.value = value }
}

// Seeds are coded as "0x…" strings: a UInt64 above 2^53 doesn't survive a JSON number in every reader.
extension RaceSeed: Codable {
    public init(from decoder: Decoder) throws { value = try decodeHexSeed(decoder) }
    public func encode(to encoder: Encoder) throws { try encodeHexSeed(value, encoder) }
}

extension WindSeed: Codable {
    public init(from decoder: Decoder) throws { value = try decodeHexSeed(decoder) }
    public func encode(to encoder: Encoder) throws { try encodeHexSeed(value, encoder) }
}

private func decodeHexSeed(_ decoder: Decoder) throws -> UInt64 {
    let c = try decoder.singleValueContainer()
    let text = try c.decode(String.self)
    guard let value = parseHex64(text) else {
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "seed \(text) is not a 0x-prefixed 64-bit hex number")
    }
    return value
}

private func encodeHexSeed(_ value: UInt64, _ encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    try c.encode(hex64(value))
}

public enum RaceSetupError: Error, Equatable, Sendable {
    /// A fleet race has 2…16 boats (#8).
    case fleetSize(Int)
    case laps(Int)
    case startSequenceTicks(Int)
}

/// Everything a race is built from except the wind seed, which is kept apart (ADR 0001). Public:
/// it goes to every client and heads the race log with the wind seed (ADR 0002). Always valid:
/// the initialiser and the decoder both throw on an invalid setup.
public struct RaceSetup: Hashable, Sendable {
    public static let fleetSizes = 2...16
    /// Two laps by default (#8); the first race sails one (#23).
    public static let defaultLaps = 2
    public static let defaultStartSequenceTicks = 60 * Race.tickRate

    /// The simulation version this race runs on; a replay needs a build with the same one (ADR 0002).
    public let simulationVersion: String
    public let raceSeed: RaceSeed
    public let laps: Int
    /// Ticks from the start of the sequence to the gun: the race starts at tick −startSequenceTicks.
    public let startSequenceTicks: Int
    /// One entry per boat, indexed by seat. Seat ids are indices into this array and `Race.boats`.
    public let seats: [SeatKind]
    // Data files the race is sailed with (ADR 0004). Carried but not yet read: #81 resolves them.
    public let boatClass: FileRef?
    public let venue: FileRef?
    public let conditions: FileRef?
    public let rulesConfiguration: FileRef?

    public var fleetSize: Int { seats.count }

    public init(
        simulationVersion: String = RegattaCore.simulationVersion,
        raceSeed: RaceSeed,
        seats: [SeatKind],
        laps: Int = RaceSetup.defaultLaps,
        startSequenceTicks: Int = RaceSetup.defaultStartSequenceTicks,
        boatClass: FileRef? = nil,
        venue: FileRef? = nil,
        conditions: FileRef? = nil,
        rulesConfiguration: FileRef? = nil
    ) throws {
        guard RaceSetup.fleetSizes.contains(seats.count) else { throw RaceSetupError.fleetSize(seats.count) }
        guard laps >= 1 else { throw RaceSetupError.laps(laps) }
        guard startSequenceTicks >= 1 else { throw RaceSetupError.startSequenceTicks(startSequenceTicks) }
        self.simulationVersion = simulationVersion
        self.raceSeed = raceSeed
        self.seats = seats
        self.laps = laps
        self.startSequenceTicks = startSequenceTicks
        self.boatClass = boatClass
        self.venue = venue
        self.conditions = conditions
        self.rulesConfiguration = rulesConfiguration
    }
}

extension RaceSetup: Codable {
    private enum CodingKeys: String, CodingKey {
        case simulationVersion, raceSeed, laps, startSequenceTicks, seats
        case boatClass, venue, conditions, rulesConfiguration
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            simulationVersion: c.decode(String.self, forKey: .simulationVersion),
            raceSeed: c.decode(RaceSeed.self, forKey: .raceSeed),
            seats: c.decode([SeatKind].self, forKey: .seats),
            laps: c.decode(Int.self, forKey: .laps),
            startSequenceTicks: c.decode(Int.self, forKey: .startSequenceTicks),
            boatClass: c.decodeIfPresent(FileRef.self, forKey: .boatClass),
            venue: c.decodeIfPresent(FileRef.self, forKey: .venue),
            conditions: c.decodeIfPresent(FileRef.self, forKey: .conditions),
            rulesConfiguration: c.decodeIfPresent(FileRef.self, forKey: .rulesConfiguration)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(simulationVersion, forKey: .simulationVersion)
        try c.encode(raceSeed, forKey: .raceSeed)
        try c.encode(laps, forKey: .laps)
        try c.encode(startSequenceTicks, forKey: .startSequenceTicks)
        try c.encode(seats, forKey: .seats)
        try c.encodeIfPresent(boatClass, forKey: .boatClass)
        try c.encodeIfPresent(venue, forKey: .venue)
        try c.encodeIfPresent(conditions, forKey: .conditions)
        try c.encodeIfPresent(rulesConfiguration, forKey: .rulesConfiguration)
    }
}
