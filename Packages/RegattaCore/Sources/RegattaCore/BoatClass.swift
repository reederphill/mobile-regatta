import Foundation

/// A boat class: a boat design's hull, polar and handling, loaded from its immutable, versioned
/// data file (ADR 0004). Load one with `DataFile<BoatClass>(data:)` or `BoatClassFile.bundled(id:version:)`.
///
/// Files use knots, degrees, seconds and hull lengths; everything here is converted once at load
/// to m/s, radians, seconds and metres.
///
/// Values are checked once, at load. The scalars are `var` so a test or a tuning tool can edit a copy;
/// a race sails the file as loaded.
public struct BoatClass: DataFileContent, Equatable {
    public static let kind = "boat class"
    public static let bundleDirectory = "boat-classes"
    /// Schema 2 added the autohelm's steering values (#230). Schema 3 (#248, the skiff) adds planing, the
    /// automatic spinnaker, a graded by-the-lee penalty and the autohelm's averaged groove wind; a schema-2
    /// class has none of them (`planing`, `spinnaker` and `byTheLee` are nil, and its grooves read the wind
    /// at the boat right now), so it sails exactly as #230 sailed it. This build sails no schema-1 class:
    /// RegattaCore holds no boat constants (ADR 0004), so it has nothing to fill the autohelm's values with.
    /// Logs sailed on one replay on the simulation version that sailed them (ADR 0002).
    public static let supportedSchemaVersions = [2, 3]

    /// Name shown to players.
    public var name: String
    public var hull: Hull
    public var polar: PolarTable
    public var momentum: Momentum
    public var steering: Steering
    public var windShadow: WindShadow
    public var contact: Contact
    public var ease: Ease
    /// How she gets on and off the plane (schema 3), or nil for a class that never planes: she sails the
    /// polar as is.
    public var planing: PlaningTuning?
    /// Her automatic spinnaker (schema 3), or nil for a class without one: the polar is all she sails.
    public var spinnaker: SpinnakerTuning?
    /// The graded by-the-lee penalty and where the spinnaker collapses (schema 3), or nil: only the
    /// polar's flat `byTheLeePenalty`.
    public var byTheLee: ByTheLeeTuning?
    /// The roll tack (#222, #263; schema 3, optional), or nil for a class without one: a second tack/gybe tap
    /// during a tack is an ordinary tap, as before.
    public var rollTack: RollTackTuning?

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
        /// The time constant, seconds, of the average of the wind strength at the boat that the grooves
        /// follow (`Boat.averagedWindSpeed`, #245): a puff shorter than this barely moves the groove, a
        /// build longer than it does. 0 (every schema-2 class) is no average: the grooves read the wind at
        /// the boat right now.
        public var grooveWindAverage: Double
    }

    /// How the boat gets on and off the plane (schema 3, #248). Downwind and reaching only: forward of
    /// `fromTWA` she sails the polar as is. The polar is the on-plane speed; off the plane, from `fromTWA`
    /// on, the target is `offPlaneSpeed(twa:tws:polar:)`. The thresholds overlap, so the same heading can
    /// hold two speeds (#244 §4.4): knocked off the plane she heads up to get back on it.
    public struct PlaningTuning: Sendable, Equatable {
        /// She gets on the plane only at or past this true wind angle, radians.
        public var fromTWA: Double
        /// She drops off it forward of this true wind angle, radians (≤ `fromTWA`).
        public var offBelowTWA: Double
        /// She gets on the plane at this speed through the water or more, m/s...
        public var onSpeed: Double
        /// ...with the apparent wind no further aft than this, radians: the sails fed from forward.
        public var onMaxAWA: Double
        /// She drops off it below this speed through the water, m/s (≤ `onSpeed`).
        public var offSpeed: Double
        /// Off the plane she sails the polar's speeds at this true wind speed, m/s...
        public var offPlaneReferenceTWS: Double
        /// ...scaled by 1 + this × (TWS − `offPlaneReferenceTWS`), per m/s, and never faster than the polar.
        public var offPlaneGain: Double

        /// The off-the-plane speed at `twa` (radians) in `tws` (m/s): the reference column's speed at
        /// `twa`, scaled by the wind strength, capped at the polar's (on-plane) speed.
        public func offPlaneSpeed(twa: Double, tws: Double, polar: PolarTable) -> Double {
            let scaled = polar.speed(twa: twa, tws: offPlaneReferenceTWS) * (1 + offPlaneGain * (tws - offPlaneReferenceTWS))
            return min(polar.speed(twa: twa, tws: tws), max(0, scaled))
        }
    }

    /// The automatic spinnaker (schema 3, #248): it goes up when she bears away past `hoistAboveTWA` and
    /// comes down when she heads up past `dropBelowTWA`, taking `transitionTime` each way, during which
    /// she sails at two-sail speed. The polar's rows from `twoSailFullTWA` aft assume it is up.
    public struct SpinnakerTuning: Sendable, Equatable {
        /// True wind angles, radians: hoisted past `hoistAboveTWA`, dropped forward of `dropBelowTWA`.
        public var hoistAboveTWA: Double
        public var dropBelowTWA: Double
        /// Seconds a hoist or a drop takes.
        public var transitionTime: Double
        /// Without the spinnaker drawing she sails the polar × this from `twoSailFullTWA` aft...
        public var twoSailSpeedFactor: Double
        /// ...and the polar as is forward of `twoSailFromTWA` (radians), linear between.
        public var twoSailFromTWA: Double
        public var twoSailFullTWA: Double

        /// The two-sail speed factor at `twa` (radians, 0...π).
        public func twoSailFactor(twa: Double) -> Double {
            if twa <= twoSailFromTWA { return 1 }
            if twa >= twoSailFullTWA { return twoSailSpeedFactor }
            return PolarTable.lerp(1, twoSailSpeedFactor, (twa - twoSailFromTWA) / (twoSailFullTWA - twoSailFromTWA))
        }
    }

    /// Sailing by the lee (schema 3, #248), on top of the polar's flat `byTheLeePenalty`.
    public struct ByTheLeeTuning: Sendable, Equatable {
        /// Fraction of speed lost per radian by the lee (never below nothing).
        public var speedLossPerRadian: Double
        /// A hoisted spinnaker collapses more than this far by the lee, radians: it stops drawing.
        public var spinnakerCollapse: Double

        /// The speed factor `angle` radians by the lee.
        public func speedFactor(byTheLee angle: Double) -> Double { max(0, 1 - speedLossPerRadian * angle) }
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
        /// Seconds: the time constant a shadowed boat slows down at (#220, #263; schema 3, optional). With it the
        /// shadow is a speed loss: her polar reads the clean wind and her target speed is the polar's × the shadow's
        /// multiplier (`Boat.shadow`), approached at this. Nil (every class before skiff@3): the shadow slows the
        /// wind her polar reads (`Boat.polarWindSpeed(in:)`), as #10 built it.
        public var slowingDown: Double?

        /// Whether the shadow slows the boat rather than the wind her polar reads (`slowingDown`).
        public var isSpeedLoss: Bool { slowingDown != nil }
    }

    /// The roll tack (#222, #263): a second tack/gybe tap during a tack, timed on the boom crossing. A hit, within
    /// `window` of the crossing either way, keeps `hitLossFraction` of each tick's speed loss from the tap (or the
    /// crossing, for a tap before it) until she is close-hauled: no floor and no jump, so a rolled tack never beats
    /// not tacking. A miss, outside it, multiplies her speed by `missSpeedFactor` once. One roll a tack.
    public struct RollTackTuning: Sendable, Equatable {
        /// Seconds either side of the boom crossing that a roll tap hits.
        public var window: Double
        /// The fraction of each tick's speed loss a hit still takes (0.5: she loses half as much).
        public var hitLossFraction: Double
        /// Her speed is multiplied by this on a miss.
        public var missSpeedFactor: Double

        /// `window` in whole ticks at `Race.tickRate`: a tap `window` ticks or fewer from the crossing hits.
        public var windowTicks: Int { Int((window * Double(Race.tickRate) + 1e-9).rounded(.down)) }
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
        case 3:
            // Schema 3 is schema 2's fields with its additions: both read the same file.
            var boatClass = try JSONDecoder().decode(BoatClassSchema2.self, from: fileData).boatClass(id: header.id)
            try JSONDecoder().decode(BoatClassSchema3Additions.self, from: fileData).apply(to: &boatClass, id: header.id)
            self = boatClass
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
                    byTheLeeMargin: deg2rad(helm.byTheLeeMarginDegrees),
                    grooveWindAverage: 0
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
                backwindLoss: windShadow.backwind.loss,
                slowingDown: nil
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

// MARK: - Schema 3

/// What the boat class file's schema 3 adds to schema 2 (#248, the skiff), as written: knots and degrees.
/// Every field is required: RegattaCore holds no boat constants to default one to (ADR 0004).
private struct BoatClassSchema3Additions: Decodable {
    struct Steering: Decodable {
        struct Autohelm: Decodable {
            let grooveWindAverageSeconds: Double
        }

        let autohelm: Autohelm
    }

    struct Planing: Decodable {
        struct OffPlane: Decodable {
            let referenceTWSKnots: Double
            /// Fraction of the reference column's speed gained per knot of true wind above its own.
            let gainPerKnot: Double
        }

        let fromTWADegrees: Double
        let offBelowTWADegrees: Double
        let onSpeedKnots: Double
        let onMaxAWADegrees: Double
        let offSpeedKnots: Double
        let offPlane: OffPlane
    }

    struct Spinnaker: Decodable {
        struct TwoSail: Decodable {
            let speedFactor: Double
            let fromTWADegrees: Double
            let fullTWADegrees: Double
        }

        let hoistAboveTWADegrees: Double
        let dropBelowTWADegrees: Double
        let transitionSeconds: Double
        let twoSail: TwoSail
    }

    struct ByTheLee: Decodable {
        /// Fraction of speed lost per degree by the lee.
        let speedLossPerDegree: Double
        let spinnakerCollapseDegrees: Double
    }

    /// #263: the shadow's own slow-down (`BoatClass.WindShadow.slowingDown`). Optional: a schema-3 class without
    /// it (skiff@1, skiff@2) keeps the shadow a wind loss.
    struct WindShadow: Decodable {
        let slowingDownSeconds: Double?
    }

    /// #263: the roll tack (`BoatClass.RollTackTuning`). Optional: a class without it has none.
    struct RollTack: Decodable {
        let windowSeconds: Double
        let hitLossFraction: Double
        let missSpeedFactor: Double
    }

    let steering: Steering
    let planing: Planing
    let spinnaker: Spinnaker
    let byTheLee: ByTheLee
    let windShadow: WindShadow?
    let rollTack: RollTack?

    /// The longest hoist or drop the wire snapshot carries (`RegattaProtocol`: a byte of ticks).
    static let maxTransitionSeconds = 8.0

    func apply(to boatClass: inout BoatClass, id: String) throws {
        func check(_ condition: Bool, _ reason: @autoclosure () -> String) throws {
            if !condition { throw DataFileError.invalidContent(kind: BoatClass.kind, id: id, reason: reason()) }
        }
        func positive(_ value: Double) -> Bool { value.isFinite && value > 0 }
        func angle(_ degrees: Double) -> Bool { degrees >= 0 && degrees <= 180 }

        let average = steering.autohelm.grooveWindAverageSeconds
        try check(average.isFinite && average >= 0, "autohelm groove wind average must not be negative")

        let p = planing
        try check(angle(p.fromTWADegrees) && angle(p.offBelowTWADegrees) && p.offBelowTWADegrees <= p.fromTWADegrees,
                  "planing angles must be 0...180°, dropping off the plane no further aft than it gets on")
        try check(positive(p.onSpeedKnots) && positive(p.offSpeedKnots) && p.offSpeedKnots <= p.onSpeedKnots,
                  "planing speeds must be positive, dropping off at no more than it gets on")
        try check(p.onMaxAWADegrees > 0 && p.onMaxAWADegrees <= 180, "planing apparent wind angle must be in 0 exclusive ...180°")
        try check(positive(p.offPlane.referenceTWSKnots) && p.offPlane.gainPerKnot.isFinite && p.offPlane.gainPerKnot >= 0,
                  "off-plane reference wind must be positive and its gain not negative")

        let k = spinnaker
        try check(angle(k.hoistAboveTWADegrees) && angle(k.dropBelowTWADegrees) && k.dropBelowTWADegrees <= k.hoistAboveTWADegrees,
                  "spinnaker angles must be 0...180°, dropping it no further aft than it goes up")
        try check(positive(k.transitionSeconds) && k.transitionSeconds <= Self.maxTransitionSeconds,
                  "spinnaker transition must be positive and at most \(Self.maxTransitionSeconds) s")
        try check(k.twoSail.speedFactor >= 0 && k.twoSail.speedFactor <= 1, "two-sail speed factor must be 0...1")
        try check(angle(k.twoSail.fromTWADegrees) && angle(k.twoSail.fullTWADegrees)
                  && k.twoSail.fromTWADegrees < k.twoSail.fullTWADegrees,
                  "two-sail angles must be 0...180°, the ramp's start forward of its end")

        try check(byTheLee.speedLossPerDegree >= 0 && byTheLee.speedLossPerDegree <= 1, "by-the-lee speed loss must be 0...1 per degree")
        try check(byTheLee.spinnakerCollapseDegrees >= 0 && byTheLee.spinnakerCollapseDegrees <= 90,
                  "spinnaker collapse must be 0...90° by the lee")

        if let seconds = windShadow?.slowingDownSeconds {
            try check(positive(seconds), "shadow slow-down time must be positive")
            boatClass.windShadow.slowingDown = seconds
        }
        if let roll = rollTack {
            try check(roll.windowSeconds.isFinite && roll.windowSeconds >= 0, "roll tack window must not be negative")
            try check(roll.hitLossFraction >= 0 && roll.hitLossFraction <= 1 && roll.missSpeedFactor >= 0 && roll.missSpeedFactor <= 1,
                      "roll tack hit loss and miss factor must be 0...1")
            boatClass.rollTack = .init(window: roll.windowSeconds, hitLossFraction: roll.hitLossFraction,
                                       missSpeedFactor: roll.missSpeedFactor)
        }
        boatClass.steering.autohelm.grooveWindAverage = average
        boatClass.planing = .init(
            fromTWA: deg2rad(p.fromTWADegrees),
            offBelowTWA: deg2rad(p.offBelowTWADegrees),
            onSpeed: metresPerSecond(knots: p.onSpeedKnots),
            onMaxAWA: deg2rad(p.onMaxAWADegrees),
            offSpeed: metresPerSecond(knots: p.offSpeedKnots),
            offPlaneReferenceTWS: metresPerSecond(knots: p.offPlane.referenceTWSKnots),
            offPlaneGain: p.offPlane.gainPerKnot / metresPerSecond(knots: 1)
        )
        boatClass.spinnaker = .init(
            hoistAboveTWA: deg2rad(k.hoistAboveTWADegrees),
            dropBelowTWA: deg2rad(k.dropBelowTWADegrees),
            transitionTime: k.transitionSeconds,
            twoSailSpeedFactor: k.twoSail.speedFactor,
            twoSailFromTWA: deg2rad(k.twoSail.fromTWADegrees),
            twoSailFullTWA: deg2rad(k.twoSail.fullTWADegrees)
        )
        boatClass.byTheLee = .init(
            speedLossPerRadian: byTheLee.speedLossPerDegree * 180 / .pi,
            spinnakerCollapse: deg2rad(byTheLee.spinnakerCollapseDegrees)
        )
    }
}
