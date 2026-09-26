import Foundation

/// A boat class: a boat design's hull, polar and handling, loaded from its immutable, versioned
/// data file (ADR 0004). Load one with `DataFile<BoatClass>(data:)` or `BoatClassFile.bundled(id:version:)`.
///
/// Files use knots, degrees, seconds and hull lengths; everything here is converted once at load
/// to m/s, radians, seconds and metres.
///
/// Values are checked once, at load. The scalars are `var` so a test or a tuning tool can edit a copy;
/// a race sails the file as loaded.
public struct BoatClass: DataFileContent {
    public static let kind = "boat class"
    public static let bundleDirectory = "boat-classes"
    /// Schema 2 added the autohelm's steering values (#230). This build sails no schema-1 class: RegattaCore
    /// holds no boat constants (ADR 0004), so it has nothing to fill them with. Logs sailed on one replay on
    /// the simulation version that sailed them (ADR 0002).
    public static let supportedSchemaVersions = [2]

    /// Name shown to players.
    public var name: String
    public var hull: Hull
    public var polar: PolarTable
    public var momentum: Momentum
    public var steering: Steering
    public var windShadow: WindShadow
    public var contact: Contact
    public var ease: Ease

    public struct Hull: Sendable, Equatable {
        /// Metres.
        public var length: Double
        public var beam: Double
        /// Convex collision outline in metres, in the boat's frame: x to starboard, y towards the bow.
        public var outline: [Vec2]
    }

    /// Time constants of the approach to polar speed.
    public struct Momentum: Sendable, Equatable {
        /// Seconds, when the polar target is above the boat's speed.
        public var speedingUp: Double
        /// Seconds, when the target is below it with the sail drawing (lulls, shadow).
        public var slowingDown: Double
        /// Seconds, inside the no-go zone.
        public var noGo: Double
    }

    public struct Steering: Sendable, Equatable {
        /// Full-rudder turn rate at full speed, radians per second.
        public var topTurnRate: Double
        /// Full-rudder turn rate however slow the boat is, radians per second.
        public var minTurnRate: Double
        /// Fraction of `topTurnRate` by speed through the water: speeds in m/s, ascending, and the
        /// fraction at each. Linear between points, flat beyond them.
        public let turnRateCurveSpeeds: [Double]
        public let turnRateCurveFractions: [Double]
        /// How fast a boat head to wind falls off towards close-hauled on her own, radians per second.
        public var headToWindFallOffRate: Double
        /// Fraction of speed lost per second at full rudder.
        public var rudderDrag: Double
        /// How fast the rudder moves, in full rudder (1.0) per second.
        public var rudderSlew: Double
        /// How the autohelm steers (ADR 0007).
        public var autohelm: AutohelmTuning

        /// Full-rudder turn rate at speed through the water `speed` (m/s), radians per second.
        public func turnRate(speed: Double) -> Double {
            let fraction: Double
            if turnRateCurveSpeeds.count == 1 {
                fraction = turnRateCurveFractions[0]
            } else {
                let (i, t) = axisSegment(turnRateCurveSpeeds, speed)
                fraction = PolarTable.lerp(turnRateCurveFractions[i - 1], turnRateCurveFractions[i], t)
            }
            return max(minTurnRate, topTurnRate * fraction)
        }
    }

    /// The autohelm's steering values (`Autohelm`, ADR 0007): tuning values, live-tunable as debug sliders
    /// before they're written into a class file.
    public struct AutohelmTuning: Sendable, Equatable {
        /// Let go within this of the upwind groove, the autohelm takes the groove. Radians.
        public var upwindSnap: Double
        /// The same for the downwind groove. Radians.
        public var downwindSnap: Double
        /// Rudder (−1 … 1) it asks for per radian between the angle she sails and the one it holds.
        public var gain: Double
        /// How far short of dead downwind it sails a groove at 180° (the dead-run rule). Radians.
        public var deadRunMargin: Double
        /// How far short of the by-the-lee limit it holds an angle by the lee. Radians.
        public var byTheLeeMargin: Double
    }

    /// The disturbed air behind a boat's sails, and the backwind just to windward of them.
    public struct WindShadow: Sendable, Equatable {
        /// Length of the shadow cone downwind of the boat, metres.
        public var coneLength: Double
        /// Full width of the cone at the boat and at its downwind end, metres.
        public var coneWidthAtBoat: Double
        public var coneWidthAtEnd: Double
        /// Fraction of wind speed lost right behind the boat (0.25 = 25 %).
        public var lossCloseIn: Double
        /// Lowest wind multiplier from stacked shadows (0.6 = never below 60 % of the wind).
        public var stackingFloor: Double
        /// The backwind zone: how far it reaches to windward of the boat and how wide it is,
        /// metres, and the fraction of wind speed a boat inside it loses.
        public var backwindLength: Double
        public var backwindWidth: Double
        public var backwindLoss: Double
    }

    /// Speed multipliers on contact.
    public struct Contact: Sendable, Equatable {
        /// Hitting another boat.
        public var boat: Double
        /// Hitting a mark.
        public var mark: Double
    }

    /// Letting the sheets go so the boat slows.
    public struct Ease: Sendable, Equatable {
        /// Fraction of polar speed the boat slows to while eased.
        public var speedFraction: Double
        /// Time constant of slowing down when eased, seconds.
        public var timeConstant: Double
    }

    public init(fileData: Data, header: DataFileHeader) throws {
        switch header.schemaVersion {
        case 2:
            self = try JSONDecoder().decode(BoatClassSchema2.self, from: fileData).boatClass(id: header.id)
        default:
            throw DataFileError.unsupportedSchemaVersion(
                kind: Self.kind, found: header.schemaVersion, supported: Self.supportedSchemaVersions)
        }
    }

    fileprivate init(
        name: String, hull: Hull, polar: PolarTable, momentum: Momentum, steering: Steering,
        windShadow: WindShadow, contact: Contact, ease: Ease
    ) {
        self.name = name
        self.hull = hull
        self.polar = polar
        self.momentum = momentum
        self.steering = steering
        self.windShadow = windShadow
        self.contact = contact
        self.ease = ease
    }
}

public typealias BoatClassFile = DataFile<BoatClass>

// MARK: - Schema 2

/// The boat class file, schema version 2, as written: knots, degrees, seconds, hull lengths. Schema 1 without
/// `steering.autohelm`.
private struct BoatClassSchema2: Decodable {
    struct Hull: Decodable {
        let lengthMetres: Double
        let beamMetres: Double
        /// [x, y] points, metres: x to starboard, y towards the bow.
        let outlineMetres: [[Double]]
    }

    struct Polar: Decodable {
        struct Column: Decodable {
            let twsKnots: Double
            /// One per row of `twaDegrees`.
            let speedKnots: [Double]
        }

        struct ByTheLeeLimit: Decodable {
            let twsKnots: Double
            let degrees: Double
        }

        let twaDegrees: [Double]
        let columns: [Column]
        let byTheLeeLimit: [ByTheLeeLimit]
        let byTheLeePenalty: Double
    }

    struct Momentum: Decodable {
        let speedingUpSeconds: Double
        let slowingDownSeconds: Double
        let noGoSeconds: Double
    }

    struct Steering: Decodable {
        struct CurvePoint: Decodable {
            let speedKnots: Double
            let fraction: Double
        }

        /// Schema 2 (#230).
        struct Autohelm: Decodable {
            let upwindSnapDegrees: Double
            let downwindSnapDegrees: Double
            /// Rudder (−1 … 1) per degree of error.
            let gainRudderPerDegree: Double
            let deadRunMarginDegrees: Double
            let byTheLeeMarginDegrees: Double
        }

        let topTurnRateDegreesPerSecond: Double
        let minTurnRateDegreesPerSecond: Double
        let turnRateCurve: [CurvePoint]
        let headToWindFallOffDegreesPerSecond: Double
        let rudderDragPerSecond: Double
        let rudderSlewPerSecond: Double
        let autohelm: Autohelm
    }

    struct WindShadow: Decodable {
        struct Backwind: Decodable {
            let lengthHullLengths: Double
            let widthHullLengths: Double
            let loss: Double
        }

        let coneLengthHullLengths: Double
        let coneWidthAtBoatHullLengths: Double
        let coneWidthAtEndHullLengths: Double
        let lossCloseIn: Double
        let stackingFloor: Double
        let backwind: Backwind
    }

    struct Contact: Decodable {
        let boatSpeedFactor: Double
        let markSpeedFactor: Double
    }

    struct Ease: Decodable {
        let speedFraction: Double
        let timeConstantSeconds: Double
    }

    let name: String
    let hull: Hull
    let polar: Polar
    let momentum: Momentum
    let steering: Steering
    let windShadow: WindShadow
    let contact: Contact
    let ease: Ease

    func boatClass(id: String) throws -> BoatClass {
        func invalid(_ reason: String) -> DataFileError {
            DataFileError.invalidContent(kind: BoatClass.kind, id: id, reason: reason)
        }
        func check(_ condition: Bool, _ reason: @autoclosure () -> String) throws {
            if !condition { throw invalid(reason()) }
        }
        func positive(_ value: Double) -> Bool { value.isFinite && value > 0 }
        func fraction(_ value: Double) -> Bool { value >= 0 && value <= 1 }

        try check(!name.isEmpty, "name is empty")
        try check(positive(hull.lengthMetres) && positive(hull.beamMetres), "hull length and beam must be positive")
        try check(hull.outlineMetres.count >= 3 && hull.outlineMetres.allSatisfy { $0.count == 2 && $0.allSatisfy(\.isFinite) },
                  "hull outline needs at least three [x, y] points")
        let outline = hull.outlineMetres.map { Vec2($0[0], $0[1]) }
        try check(Self.isConvexClockwise(outline),
                  "hull outline must be convex and run clockwise (bow, starboard side, stern, port side), as Boat.hull(outline:) does")
        try check(polar.twaDegrees.first == 0 && polar.twaDegrees.last == 180, "polar TWA rows must run from 0° to 180°")

        let table: PolarTable
        do {
            table = try PolarTable(
                twaAxis: polar.twaDegrees.map(deg2rad),
                twsAxis: polar.columns.map { metresPerSecond(knots: $0.twsKnots) },
                speeds: polar.columns.map { $0.speedKnots.map { metresPerSecond(knots: $0) } },
                byTheLeeLimitTWS: polar.byTheLeeLimit.map { metresPerSecond(knots: $0.twsKnots) },
                byTheLeeLimits: polar.byTheLeeLimit.map { deg2rad($0.degrees) },
                byTheLeePenalty: polar.byTheLeePenalty
            )
        } catch let error as PolarTable.TableError {
            throw invalid("polar: \(error)")
        }

        try check(positive(momentum.speedingUpSeconds) && positive(momentum.slowingDownSeconds) && positive(momentum.noGoSeconds),
                  "momentum time constants must be positive")

        let curveSpeeds = steering.turnRateCurve.map { metresPerSecond(knots: $0.speedKnots) }
        try check(!curveSpeeds.isEmpty && zip(curveSpeeds, curveSpeeds.dropFirst()).allSatisfy { $0 < $1 },
                  "turn rate curve needs points in ascending speed")
        try check(steering.turnRateCurve.allSatisfy { fraction($0.fraction) }, "turn rate curve fractions must be 0...1")
        try check(positive(steering.topTurnRateDegreesPerSecond) && positive(steering.minTurnRateDegreesPerSecond)
                  && steering.minTurnRateDegreesPerSecond <= steering.topTurnRateDegreesPerSecond,
                  "turn rates must be positive, with min ≤ top")
        try check(steering.headToWindFallOffDegreesPerSecond >= 0 && steering.rudderDragPerSecond >= 0
                  && positive(steering.rudderSlewPerSecond), "steering rates must not be negative")
        let helm = steering.autohelm
        try check([helm.upwindSnapDegrees, helm.downwindSnapDegrees, helm.deadRunMarginDegrees, helm.byTheLeeMarginDegrees]
                    .allSatisfy { $0 >= 0 && $0 < 90 }, "autohelm snap widths and margins must be 0..<90°")
        try check(positive(helm.gainRudderPerDegree), "autohelm gain must be positive")

        try check(positive(windShadow.coneLengthHullLengths) && positive(windShadow.coneWidthAtBoatHullLengths)
                  && positive(windShadow.coneWidthAtEndHullLengths), "shadow cone sizes must be positive")
        try check(fraction(windShadow.lossCloseIn) && fraction(windShadow.stackingFloor) && fraction(windShadow.backwind.loss),
                  "shadow losses and floor must be 0...1")
        try check(windShadow.backwind.lengthHullLengths >= 0 && windShadow.backwind.widthHullLengths >= 0,
                  "backwind size must not be negative")
        try check(fraction(contact.boatSpeedFactor) && fraction(contact.markSpeedFactor), "contact factors must be 0...1")
        try check(fraction(ease.speedFraction) && positive(ease.timeConstantSeconds), "ease needs a 0...1 fraction and a positive time")

        let length = hull.lengthMetres
        return BoatClass(
            name: name,
            hull: .init(length: length, beam: hull.beamMetres, outline: outline),
            polar: table,
            momentum: .init(speedingUp: momentum.speedingUpSeconds, slowingDown: momentum.slowingDownSeconds,
                            noGo: momentum.noGoSeconds),
            steering: .init(
                topTurnRate: deg2rad(steering.topTurnRateDegreesPerSecond),
                minTurnRate: deg2rad(steering.minTurnRateDegreesPerSecond),
                turnRateCurveSpeeds: curveSpeeds,
                turnRateCurveFractions: steering.turnRateCurve.map(\.fraction),
                headToWindFallOffRate: deg2rad(steering.headToWindFallOffDegreesPerSecond),
                rudderDrag: steering.rudderDragPerSecond,
                rudderSlew: steering.rudderSlewPerSecond,
                autohelm: .init(
                    upwindSnap: deg2rad(helm.upwindSnapDegrees),
                    downwindSnap: deg2rad(helm.downwindSnapDegrees),
                    gain: helm.gainRudderPerDegree * 180 / .pi,
                    deadRunMargin: deg2rad(helm.deadRunMarginDegrees),
                    byTheLeeMargin: deg2rad(helm.byTheLeeMarginDegrees)
                )
            ),
            windShadow: .init(
                coneLength: windShadow.coneLengthHullLengths * length,
                coneWidthAtBoat: windShadow.coneWidthAtBoatHullLengths * length,
                coneWidthAtEnd: windShadow.coneWidthAtEndHullLengths * length,
                lossCloseIn: windShadow.lossCloseIn,
                stackingFloor: windShadow.stackingFloor,
                backwindLength: windShadow.backwind.lengthHullLengths * length,
                backwindWidth: windShadow.backwind.widthHullLengths * length,
                backwindLoss: windShadow.backwind.loss
            ),
            contact: .init(boat: contact.boatSpeedFactor, mark: contact.markSpeedFactor),
            ease: .init(speedFraction: ease.speedFraction, timeConstant: ease.timeConstantSeconds)
        )
    }

    /// A simple convex polygon wound clockwise in the boat's frame (x to starboard, y towards the bow):
    /// every corner turns right, and the turns add up to exactly one full turn (a star turns twice).
    /// Separating-axis collision needs convex hulls.
    static func isConvexClockwise(_ points: [Vec2]) -> Bool {
        var turning = 0.0
        for k in points.indices {
            let a = points[k], b = points[(k + 1) % points.count], c = points[(k + 2) % points.count]
            let e1 = b - a, e2 = c - b
            let turn = e1.cross(e2)
            guard turn < 0 else { return false }
            turning += atan2(turn, e1.dot(e2))
        }
        return abs(turning + 2 * .pi) < 1e-6
    }
}
