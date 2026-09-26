import Foundation
import RegattaCore

/// The v1.0 venues (#12, #36): bundled in RegattaCore for the app and the server.
public enum ShippedVenues {
    /// Hollin Bay (the open bay), Saltings Reach (the tidal estuary) and Fellmere (the hill-ringed lake).
    public static let keys = [
        DataFileKey(id: "hollin-bay", version: 1),
        DataFileKey(id: "saltings-reach", version: 1),
        DataFileKey(id: "fellmere", version: 1),
    ]

    /// Every pairing of every shipped venue, venue by venue in `keys` order, each venue's in file order.
    public static func pairings() throws -> [VenuePairingCase] {
        try keys.flatMap { key in
            let venue = try VenueFile.bundled(id: key.id, version: key.version)
            return try venue.content.pairings.map { pairing in
                try VenuePairingCase(
                    venue: venue,
                    conditions: .bundled(id: pairing.conditions.id, version: pairing.conditions.version)
                )
            }
        }
    }
}

/// One venue × conditions pairing with the files its course is laid out from: what the offline venue
/// checks (`VenueOfflineCheck`, `VenueSailability`) and the overview PNGs (`VenueOverview`) run over (#83).
///
/// A race lays its course up the pairing's mean direction turned by its seed (up to
/// `WindSetup.meanDirectionSpread` either way), with a beat sized in its drawn strength and laps, and a
/// line sized for its fleet (#12, #80). The checks cover that whole envelope: every rotation, and the
/// longest and the shortest course.
public struct VenuePairingCase: Sendable {
    /// The lap counts a race sails: the first race one (#23), every other race `RaceSetup.defaultLaps` (#8).
    public static let laps = 1...RaceSetup.defaultLaps

    public let venue: VenueFile
    public let conditions: ConditionsFile
    public let pairing: Venue.Pairing
    public let boatClass: BoatClass
    public let rules: RulesConfig

    /// Throws `RaceFilesError.noPairing` if `venue` has no pairing for `conditions`. The boat class and
    /// rules default to the races' (`RaceFiles.defaults`).
    public init(
        venue: VenueFile, conditions: ConditionsFile,
        boatClass: BoatClass = RaceFiles.defaults.boatClass.content,
        rules: RulesConfig = RaceFiles.defaults.rulesConfiguration.content
    ) throws {
        guard let pairing = venue.content.pairing(for: conditions.ref.key) else {
            throw RaceFilesError.noPairing(venue: venue.ref, conditions: conditions.ref)
        }
        self.venue = venue
        self.conditions = conditions
        self.pairing = pairing
        self.boatClass = boatClass
        self.rules = rules
    }

    /// "hollin-bay@1 × classic-oscillating@2".
    public var name: String { "\(venue.ref.key) × \(conditions.ref.key)" }

    /// The seeded rotations of the mean direction, radians: from −`WindSetup.meanDirectionSpread` to
    /// +spread in steps of at most `step`, both ends included.
    public static func rotations(step: Double) -> [Double] {
        let spread = WindSetup.meanDirectionSpread
        let count = Int((2 * spread / step).rounded(.up))
        return (0...count).map { -spread + 2 * spread * Double($0) / Double(count) }
    }

    /// The longest beat any race sails here, metres: the longest `CourseLayout.beat` for any lap count in
    /// `laps` and any strength in the conditions' range (sampled every 1 % of it, ends included).
    public var longestBeat: Double { beats.max()! }

    /// The shortest beat any race sails here, metres, over the same range.
    public var shortestBeat: Double { beats.min()! }

    /// The longest course at `rotation` (radians off the authored mean direction): the longest beat and
    /// the line for the largest fleet. Its race area holds every other course's at that rotation.
    public func longestCourse(rotation: Double) -> CourseLayout {
        course(rotation: rotation, beat: longestBeat, fleetSize: RaceSetup.fleetSizes.upperBound)
    }

    /// The shortest course at `rotation`: the shortest beat and the line for the smallest fleet.
    public func shortestCourse(rotation: Double) -> CourseLayout {
        course(rotation: rotation, beat: shortestBeat, fleetSize: RaceSetup.fleetSizes.lowerBound)
    }

    /// The course at `rotation` with a beat of `beat` metres and the line for `fleetSize` boats.
    public func course(rotation: Double, beat: Double, fleetSize: Int) -> CourseLayout {
        CourseLayout.derive(
            axis: wrapAngle(pairing.meanDirection + rotation), anchor: pairing.startLineCentre, beat: beat,
            land: venue.content.land, fleetSize: fleetSize, laps: Self.laps.lowerBound, boatClass: boatClass,
            rules: rules
        )
    }

    private var beats: [Double] {
        let strength = conditions.content.strength
        let steps = 100
        return Self.laps.flatMap { laps in
            (0...steps).map { i in
                let tws = strength.lowerBound + (strength.upperBound - strength.lowerBound) * Double(i) / Double(steps)
                return CourseLayout.beat(laps: laps, tws: tws, boatClass: boatClass, rules: rules)
            }
        }
    }
}

extension RaceArea {
    /// Points on a lattice `spacing` metres apart, square to the axis, covering the rectangle, sides
    /// included: row by row from the downwind end, each row from the left side looking upwind.
    func lattice(spacing: Double) -> [Vec2] {
        let up = Vec2.heading(axis)
        let right = up.rightPerp
        let across = Int((2 * halfWidth / spacing).rounded(.up))
        let along = Int((2 * halfLength / spacing).rounded(.up))
        var points: [Vec2] = []
        points.reserveCapacity((across + 1) * (along + 1))
        for j in 0...along {
            let a = -halfLength + 2 * halfLength * Double(j) / Double(along)
            for i in 0...across {
                let c = -halfWidth + 2 * halfWidth * Double(i) / Double(across)
                points.append(centre + up * a + right * c)
            }
        }
        return points
    }
}

extension Venue.LandPolygon {
    /// Metres from `p` to the polygon: 0 inside it.
    func distance(to p: Vec2) -> Double {
        if contains(p) { return 0 }
        var least = Double.infinity
        for i in points.indices {
            let edge = Segment(points[i], points[(i + 1) % points.count])
            least = min(least, (Collision.closestPoint(on: edge, to: p) - p).length)
        }
        return least
    }
}
