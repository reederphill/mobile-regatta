import Foundation

/// A pool of vetted wind seeds for one pairing of venue, conditions and tide state (#10, #11, #106).
/// Server-only: it never ships in the app, since a wind seed on a client would give away the whole wind
/// (ADR 0001). Each seed sails at most one online race and is then retired (G1), so a pool is working
/// data that changes as it's drawn down and topped up, not an immutable data file (ADR 0004: the race
/// log records the seed a race used, so changing a pool never affects a replay).
///
/// The file is JSON, schema version 1:
///
/// ```json
/// {
///   "schemaVersion": 1,
///   "kind": "wind-seed-pool",
///   "venue": { "id": "test-venue", "version": 1 },
///   "conditions": { "id": "classic-oscillating", "version": 2 },
///   "tideStateDegrees": 90,
///   "notes": ["free text, ignored"],
///   "seeds": ["0x0123456789abcdef", "…"]
/// }
/// ```
///
/// The pool is keyed by venue id + version × conditions id + version × tide state: a new version of
/// either file sails different water or wind, so its seeds need vetting again (#32, #106).
/// `tideStateDegrees` is the tide's phase at the gun, degrees in [0, 360), or null for a venue with no
/// current. Seeds are "0x…" hex strings, like the race log's, and never repeat.
public struct WindSeedPool: Hashable, Sendable {
    public static let schemaVersion = 1
    public static let kind = "wind-seed-pool"

    /// A data file named by id and version.
    public struct FileID: Hashable, Sendable, Codable, CustomStringConvertible {
        public let id: String
        public let version: Int

        public init(id: String, version: Int) {
            self.id = id
            self.version = version
        }

        public var description: String { "\(id)@\(version)" }
    }

    /// What a pool is keyed by.
    public struct Pairing: Hashable, Sendable, CustomStringConvertible {
        public let venue: FileID
        public let conditions: FileID
        /// Tide phase at the gun, degrees in [0, 360), or nil for a venue with no current.
        public let tideStateDegrees: Double?

        public init(venue: FileID, conditions: FileID, tideStateDegrees: Double?) {
            self.venue = venue
            self.conditions = conditions
            self.tideStateDegrees = tideStateDegrees
        }

        public var description: String {
            "\(venue) × \(conditions) × " + (tideStateDegrees.map { "tide \($0)°" } ?? "no tide")
        }
    }

    public let pairing: Pairing
    /// Vetted seeds, in the order they're drawn.
    public let seeds: [WindSeed]

    public init(pairing: Pairing, seeds: [WindSeed]) throws {
        try Self.validate(pairing, seeds)
        self.pairing = pairing
        self.seeds = seeds
    }

    /// Loads a pool file from its bytes.
    public init(data: Data) throws {
        let file: File
        do {
            file = try JSONDecoder().decode(File.self, from: data)
        } catch let error as WindSeedPoolError {
            throw error
        } catch {
            throw WindSeedPoolError.malformed("\(error)")
        }
        try self.init(pairing: Pairing(venue: file.venue, conditions: file.conditions, tideStateDegrees: file.tideStateDegrees),
                      seeds: file.seeds)
    }

    /// Loads a pool file and checks it is the pool for `expected`: a pool for another venue version,
    /// conditions or tide state throws `wrongPairing`.
    public init(data: Data, for expected: Pairing) throws {
        try self.init(data: data)
        guard pairing == expected else { throw WindSeedPoolError.wrongPairing(expected: expected, found: pairing) }
    }

    /// The pool as a file: stable JSON with sorted keys.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        return try encoder.encode(File(schemaVersion: Self.schemaVersion, kind: Self.kind, venue: pairing.venue,
                                       conditions: pairing.conditions, tideStateDegrees: pairing.tideStateDegrees,
                                       notes: nil, seeds: seeds))
    }

    private static func validate(_ pairing: Pairing, _ seeds: [WindSeed]) throws {
        for file in [pairing.venue, pairing.conditions] {
            guard ConditionsFile.isValidID(file.id), file.version >= 1 else {
                throw WindSeedPoolError.invalid("\(file) is not a valid file id and version")
            }
        }
        if let tide = pairing.tideStateDegrees, !(tide.isFinite && tide >= 0 && tide < 360) {
            throw WindSeedPoolError.invalid("tide state \(tide)° is not in [0, 360)")
        }
        // G1: a seed sails at most one online race, so it appears once. Sorted copy: no Set, no hash order.
        let sorted = seeds.map(\.value).sorted()
        if let repeated = zip(sorted, sorted.dropFirst()).first(where: { $0 == $1 }) {
            throw WindSeedPoolError.invalid("seed \(hex64(repeated.0)) appears more than once")
        }
    }

    private struct File: Codable {
        let schemaVersion: Int
        let kind: String
        let venue: FileID
        let conditions: FileID
        let tideStateDegrees: Double?
        let notes: [String]?
        let seeds: [WindSeed]

        init(schemaVersion: Int, kind: String, venue: FileID, conditions: FileID, tideStateDegrees: Double?,
             notes: [String]?, seeds: [WindSeed]) {
            self.schemaVersion = schemaVersion
            self.kind = kind
            self.venue = venue
            self.conditions = conditions
            self.tideStateDegrees = tideStateDegrees
            self.notes = notes
            self.seeds = seeds
        }

        private enum CodingKeys: String, CodingKey { case schemaVersion, kind, venue, conditions, tideStateDegrees, notes, seeds }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // The header first, so a file of another schema or kind is refused as that, not as malformed.
            schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
            guard schemaVersion == WindSeedPool.schemaVersion else {
                throw WindSeedPoolError.unsupportedSchemaVersion(found: schemaVersion, supported: [WindSeedPool.schemaVersion])
            }
            kind = try c.decode(String.self, forKey: .kind)
            guard kind == WindSeedPool.kind else { throw WindSeedPoolError.wrongKind(kind) }
            venue = try c.decode(FileID.self, forKey: .venue)
            conditions = try c.decode(FileID.self, forKey: .conditions)
            // Always present: null, not absent, for a venue with no current.
            guard c.contains(.tideStateDegrees) else {
                throw WindSeedPoolError.malformed("tideStateDegrees is missing; use null for a venue with no current")
            }
            tideStateDegrees = try c.decodeNil(forKey: .tideStateDegrees) ? nil : c.decode(Double.self, forKey: .tideStateDegrees)
            notes = try c.decodeIfPresent([String].self, forKey: .notes)
            seeds = try c.decode([WindSeed].self, forKey: .seeds)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(schemaVersion, forKey: .schemaVersion)
            try c.encode(kind, forKey: .kind)
            try c.encode(venue, forKey: .venue)
            try c.encode(conditions, forKey: .conditions)
            // Always written, as null for a venue with no current.
            if let tideStateDegrees { try c.encode(tideStateDegrees, forKey: .tideStateDegrees) } else { try c.encodeNil(forKey: .tideStateDegrees) }
            try c.encodeIfPresent(notes, forKey: .notes)
            try c.encode(seeds, forKey: .seeds)
        }
    }
}

public enum WindSeedPoolError: Error, Equatable, Sendable {
    /// Not JSON, or a field is missing or has the wrong type.
    case malformed(String)
    case unsupportedSchemaVersion(found: Int, supported: [Int])
    /// The file isn't a wind seed pool.
    case wrongKind(String)
    /// It decoded but breaks the format's rules: a bad file id, tide state or repeated seed.
    case invalid(String)
    /// A pool for another pairing, e.g. another version of the venue.
    case wrongPairing(expected: WindSeedPool.Pairing, found: WindSeedPool.Pairing)
}
