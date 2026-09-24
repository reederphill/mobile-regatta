import Foundation

/// A named conditions entry: the kind of wind a race is sailed in (#10). Fixes the wind's strength
/// range, how it oscillates, any persistent trend and build, and how puffy it is. Loaded from its
/// immutable, versioned data file (ADR 0004, extended by #32) with `DataFile<Conditions>(data:)` or
/// `ConditionsFile.bundled(id:version:)`.
///
/// Files use knots, degrees, seconds, metres and fractions; everything here is converted once at load
/// to m/s, radians, seconds, metres and fractions.
///
/// Nothing here is secret: every client has the file. What the keyed wind draws from these ranges
/// (#75, #76) is secret until its window's key is revealed (ADR 0001); what the public race seed
/// draws from them is in `WindSetup`.
///
/// Schema 2 adds the keyed wind's tuning (`keyedWind`): the wobble and the timing of the trend and
/// build. Schema 1 files still load, but only schema 2 can be sailed.
public struct Conditions: DataFileContent, Hashable {
    public static let kind = "conditions"
    public static let bundleDirectory = "conditions"
    public static let supportedSchemaVersions = [1, 2]

    /// Every conditions entry oscillates with a main period in 90–180 s, about one cycle per beat
    /// (#10, ADR 0001). A file's own period range must lie inside this envelope, and wins inside it.
    public static let shiftPeriodEnvelope: ClosedRange<Double> = 90...180

    /// Name shown to players, e.g. "Gusty offshore".
    public let name: String
    /// Range the race's base wind strength is drawn from, m/s (`WindSetup.baseStrength`).
    public let strength: ClosedRange<Double>
    public let shift: Shift
    /// A persistent shift one way over the race, or nil for none.
    public let trend: Trend?
    /// A rise in strength over the race, or nil for strength fixed for the race.
    public let build: Build?
    public let puffs: Puffs
    /// What the keyed wind (#75) reads beyond schema 1, or nil for a schema 1 file, which predates it.
    /// `WindKeyGenerator` refuses conditions without it.
    public let keyedWind: KeyedWind?

    /// The oscillating shift about the mean direction.
    public struct Shift: Hashable, Sendable {
        /// Peak swing either side of the mean direction, radians.
        public let amplitude: Double
        /// Range the oscillator's period is redrawn in, seconds (#75). Inside `shiftPeriodEnvelope`.
        public let period: ClosedRange<Double>
    }

    /// A persistent shift. Its direction is public (`WindSetup.trend`); its size and timing are
    /// drawn by the keyed wind and never shown before the race (#10).
    public struct Trend: Hashable, Sendable {
        /// Range of the net shift over `duration`, radians, always toward the trend direction.
        public let size: ClosedRange<Double>
        /// Seconds the net shift is measured over: only the span `size` is given for, not a schedule.
        /// When the trend starts and how it unfolds are keyed (#75), so this fixed, public duration
        /// reveals no timing (#10).
        public let duration: Double
    }

    /// A gentle ramp in strength over the race, drawn by the keyed wind's strength channel (#75).
    public struct Build: Hashable, Sendable {
        /// Range of the total rise as a fraction of base strength (0.15 = up to 15 % stronger).
        public let fraction: ClosedRange<Double>
    }

    /// Puffs and lulls (#10, #76): the puff columns.
    public struct Puffs: Hashable, Sendable {
        /// Fraction of the race area under a puff or lull at once, on average.
        public let coverage: Double
        /// Diameter of a puff or lull, metres.
        public let diameter: ClosedRange<Double>
        /// Seconds from spawn to gone, fading in and out.
        public let lifetime: ClosedRange<Double>
        /// Downwind drift as a fraction of wind speed, so puffs can be chased.
        public let drift: ClosedRange<Double>
        /// Largest direction change at a puff's edges, radians (the puff fans out).
        public let fan: Double
        /// A puff's peak gain, as a fraction of wind speed (0.2 = 20 % stronger).
        public let gain: ClosedRange<Double>
        /// Fraction of spawns that are lulls rather than puffs.
        public let lullShare: Double
        /// A lull's peak loss, as a fraction of wind speed (0.2 = 20 % weaker).
        public let lullLoss: ClosedRange<Double>
    }

    /// The keyed wind's tuning (#75, schema 2). Nothing here says when anything happens: the key
    /// chain draws that within these ranges (ADR 0001).
    public struct KeyedWind: Hashable, Sendable {
        /// Peak of the smaller, faster wobble on the oscillating shift, radians (#10). Each window's key
        /// draws its own wobble, which vanishes at both of the window's knots. Below `shift.amplitude`.
        public let wobble: Double
        /// The longest the trend's change may take, as fractions of `trend.duration`, within (0, 1]; nil
        /// when there's no trend. The key chain draws the longest duration within this range and a start
        /// so it ends within `trend.duration` of the gun; each window's key draws the pace, so the change
        /// finishes between half and all of that duration after it starts (`WindKeyGenerator`).
        public let trendRamp: ClosedRange<Double>?
        /// Seconds after the gun the build's total rise is measured over (the strength channel's span);
        /// nil when there's no build.
        public let buildDuration: Double?
        /// The longest the rise may take, as fractions of `buildDuration`, within (0, 1], drawn like
        /// `trendRamp`; nil when there's no build.
        public let buildRamp: ClosedRange<Double>?
    }

    public init(fileData: Data, header: DataFileHeader) throws {
        switch header.schemaVersion {
        case 1, 2:
            self = try JSONDecoder().decode(ConditionsSchema.self, from: fileData)
                .conditions(id: header.id, schemaVersion: header.schemaVersion)
        default:
            throw DataFileError.unsupportedSchemaVersion(
                kind: Self.kind, found: header.schemaVersion, supported: Self.supportedSchemaVersions)
        }
    }

    fileprivate init(name: String, strength: ClosedRange<Double>, shift: Shift, trend: Trend?, build: Build?, puffs: Puffs,
                     keyedWind: KeyedWind?) {
        self.name = name
        self.strength = strength
        self.shift = shift
        self.trend = trend
        self.build = build
        self.puffs = puffs
        self.keyedWind = keyedWind
    }
}

public typealias ConditionsFile = DataFile<Conditions>

// MARK: - Schemas 1 and 2

/// The conditions file, schema versions 1 and 2, as written: knots, degrees, seconds, metres, fractions.
/// Schema 2 is schema 1 plus `shift.wobbleDegrees`, `trend.rampFraction`, `build.overSeconds` and
/// `build.rampFraction` (#75): required in schema 2, refused in schema 1.
private struct ConditionsSchema: Decodable {
    /// `{ "min": a, "max": b }`, in the unit its key names.
    struct Range: Decodable {
        let min: Double
        let max: Double
    }

    struct Strength: Decodable {
        let minKnots: Double
        let maxKnots: Double
    }

    struct Shift: Decodable {
        let amplitudeDegrees: Double
        let periodSeconds: Range
        /// Schema 2.
        let wobbleDegrees: Double?
    }

    struct Trend: Decodable {
        let minDegrees: Double
        let maxDegrees: Double
        let overSeconds: Double
        /// Schema 2.
        let rampFraction: Range?
    }

    struct Build: Decodable {
        let minFraction: Double
        let maxFraction: Double
        /// Schema 2.
        let overSeconds: Double?
        /// Schema 2.
        let rampFraction: Range?
    }

    struct Puffs: Decodable {
        let coverage: Double
        let diameterMetres: Range
        let lifetimeSeconds: Range
        let driftFraction: Range
        let fanDegrees: Double
        let puffGain: Range
        let lullShare: Double
        let lullLoss: Range
    }

    let name: String
    let strength: Strength
    let shift: Shift
    let trend: Trend?
    let build: Build?
    let puffs: Puffs

    func conditions(id: String, schemaVersion: Int) throws -> Conditions {
        func check(_ condition: Bool, _ reason: @autoclosure () -> String) throws {
            if !condition { throw DataFileError.invalidContent(kind: Conditions.kind, id: id, reason: reason()) }
        }
        /// Finite, ascending, and every value in `allowed`.
        func range(_ min: Double, _ max: Double, in allowed: ClosedRange<Double>, _ what: String) throws -> ClosedRange<Double> {
            try check(min.isFinite && max.isFinite && min <= max, "\(what) must run from min to max, min ≤ max")
            try check(allowed.contains(min) && allowed.contains(max), "\(what) must lie in \(allowed)")
            return min...max
        }
        func bounds(_ r: Range, in allowed: ClosedRange<Double>, _ what: String) throws -> ClosedRange<Double> {
            try range(r.min, r.max, in: allowed, what)
        }
        let positive = Double.leastNonzeroMagnitude...Double.greatestFiniteMagnitude
        let fraction: ClosedRange<Double> = 0...1

        try check(!name.isEmpty, "name is empty")
        let knots = try range(strength.minKnots, strength.maxKnots, in: positive, "strength")

        try check(shift.amplitudeDegrees.isFinite && shift.amplitudeDegrees >= 0 && shift.amplitudeDegrees < 90,
                  "shift amplitude must be 0…90°")
        let period = try bounds(shift.periodSeconds, in: Conditions.shiftPeriodEnvelope, "shift period")

        var parsedTrend: Conditions.Trend?
        if let trend {
            let degrees = try range(trend.minDegrees, trend.maxDegrees, in: 0...90, "trend size")
            try check(trend.overSeconds.isFinite && trend.overSeconds > 0, "trend duration must be positive")
            parsedTrend = .init(size: deg2rad(degrees.lowerBound)...deg2rad(degrees.upperBound), duration: trend.overSeconds)
        }
        var parsedBuild: Conditions.Build?
        if let build {
            parsedBuild = .init(fraction: try range(build.minFraction, build.maxFraction, in: fraction, "build"))
        }

        try check(puffs.coverage > 0 && puffs.coverage < 1, "puff coverage must be between 0 and 1")
        try check(puffs.fanDegrees.isFinite && puffs.fanDegrees >= 0 && puffs.fanDegrees < 90, "puff fan must be 0…90°")
        try check(fraction.contains(puffs.lullShare), "lull share must be 0…1")
        let parsedPuffs = Conditions.Puffs(
            coverage: puffs.coverage,
            diameter: try bounds(puffs.diameterMetres, in: positive, "puff diameter"),
            lifetime: try bounds(puffs.lifetimeSeconds, in: positive, "puff lifetime"),
            drift: try bounds(puffs.driftFraction, in: fraction, "puff drift"),
            fan: deg2rad(puffs.fanDegrees),
            gain: try bounds(puffs.puffGain, in: 0...Double.greatestFiniteMagnitude, "puff gain"),
            lullShare: puffs.lullShare,
            // A lull of 100 % would stop the wind.
            lullLoss: try bounds(puffs.lullLoss, in: 0...0.99, "lull loss")
        )

        // Schema 2's keyed-wind fields: all present (for whichever of trend and build the file has),
        // or in schema 1 none of them.
        var keyedWind: Conditions.KeyedWind?
        if schemaVersion >= 2 {
            func required<T>(_ value: T?, _ field: String) throws -> T {
                guard let value else {
                    throw DataFileError.malformed(kind: Conditions.kind, reason: "schema \(schemaVersion) needs \(field)")
                }
                return value
            }
            // A ramp takes some time, and at most the whole span.
            let rampFractions = Double.leastNonzeroMagnitude...1
            let wobble = try required(shift.wobbleDegrees, "shift.wobbleDegrees")
            try check(wobble.isFinite && wobble >= 0 && (wobble < shift.amplitudeDegrees || wobble == 0),
                      "shift wobble must be at least 0° and smaller than the amplitude")
            let trendRamp = try trend.map { try bounds(try required($0.rampFraction, "trend.rampFraction"), in: rampFractions, "trend ramp") }
            var buildDuration: Double?
            var buildRamp: ClosedRange<Double>?
            if let build {
                let over = try required(build.overSeconds, "build.overSeconds")
                try check(over.isFinite && over > 0, "build duration must be positive")
                buildDuration = over
                buildRamp = try bounds(try required(build.rampFraction, "build.rampFraction"), in: rampFractions, "build ramp")
            }
            keyedWind = .init(wobble: deg2rad(wobble), trendRamp: trendRamp, buildDuration: buildDuration, buildRamp: buildRamp)
        } else {
            try check(shift.wobbleDegrees == nil && trend?.rampFraction == nil && build?.overSeconds == nil
                        && build?.rampFraction == nil,
                      "shift.wobbleDegrees, trend.rampFraction, build.overSeconds and build.rampFraction need schema 2")
        }

        return Conditions(
            name: name,
            strength: metresPerSecond(knots: knots.lowerBound)...metresPerSecond(knots: knots.upperBound),
            shift: .init(amplitude: deg2rad(shift.amplitudeDegrees), period: period),
            trend: parsedTrend,
            build: parsedBuild,
            puffs: parsedPuffs,
            keyedWind: keyedWind
        )
    }
}
