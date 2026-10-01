import Foundation

/// The offline venue check (#12, #14, #83): whether every pairing of a venue lays a course that fits its water.
/// Run by the tests over every bundled venue, and by `regatta-venue-png`; never by a race. Pure.
///
/// For each pairing it lays the course the way a race does (`CourseLayout.derive`) for the largest fleet
/// (`RaceSetup.fleetSizes`) and the longest beat (one lap, at the strength in the conditions' range whose beat is
/// longest), at every rotation of the mean the race seed may draw (`WindSetup.meanDirectionSpread`, in
/// `rotationStepDegrees` steps from one extreme to the other), and finds:
///
/// - land reaching into the race area's rectangle: land is only at the edges (#12), beyond the rectangle;
/// - land within `landClearanceMetres` of the start line (its ends and the segment between) or any mark;
/// - a geographic grid that doesn't cover the rectangle (outside the grid the shift is neutral, a cliff);
/// - for a venue with current: a current grid that doesn't cover the rectangle, deepest water (every node at the
///   deepest depth) outside it, or no shallows node (deeper than 0, shallower than the channel) inside it. The
///   channel is the water at least `channelFraction` of the deepest; its deepest part and the shallows beside it
///   sit inside the race area (#12).
///
/// The check recomputes the course from the class and rules files, so a retuned polar is re-checked (#14).
public enum VenueCheck {
    /// Metres land must keep from the start line and every mark (a placeholder, #83).
    public static let landClearanceMetres = 30.0
    /// Water at least this fraction of the deepest node's depth is the channel; shallower water is shallows.
    public static let channelFraction = 0.5
    /// Degrees between the rotations of the mean the check lays a course at, across ±`meanDirectionSpread`.
    public static let rotationStepDegrees = 2.5
    /// How many strengths across the conditions' range the check sizes the beat at, to find the longest.
    static let strengthSamples = 9

    /// Something wrong with a pairing's course, at one rotation of its mean.
    public struct Finding: Sendable, Equatable, CustomStringConvertible {
        /// The pairing's conditions.
        public let pairing: DataFileKey
        /// Degrees the mean was turned from the pairing's authored direction, or nil for the pairing as a whole.
        public let rotationDegrees: Double?
        public let reason: String

        public var description: String {
            let rotation = rotationDegrees.map { String(format: " at %+.1f°", $0) } ?? ""
            return "\(pairing.id)@\(pairing.version)\(rotation): \(reason)"
        }
    }

    /// The rotations of the mean the check lays a course at, radians, from −spread to +spread.
    public static var rotations: [Double] {
        let spread = rad2deg(WindSetup.meanDirectionSpread)
        let steps = Int((2 * spread / rotationStepDegrees).rounded())
        return (0...steps).map { deg2rad(-spread + Double($0) * rotationStepDegrees) }
    }

    /// The courses a pairing is checked on: one per rotation (`rotations`), for the largest fleet and the longest
    /// beat. `conditions` is the pairing's conditions file.
    public static func layouts(
        venue: Venue, pairing: Venue.Pairing, conditions: ConditionsFile, boatClass: BoatClass, rules: RulesConfig
    ) -> [(rotation: Double, layout: CourseLayout)] {
        let range = conditions.content.strength
        let strengths = (0..<strengthSamples).map {
            range.lowerBound + (range.upperBound - range.lowerBound) * Double($0) / Double(strengthSamples - 1)
        }
        let strength = strengths.max {
            CourseLayout.beat(laps: 1, tws: $0, boatClass: boatClass, rules: rules)
                < CourseLayout.beat(laps: 1, tws: $1, boatClass: boatClass, rules: rules)
        }!
        return rotations.map { rotation in
            let setup = WindSetup(conditions: conditions, pairing: pairing,
                                  meanDirection: pairing.meanDirection + rotation, baseStrength: strength)
            let layout = CourseLayout.derive(windSetup: setup, land: venue.land, fleetSize: RaceSetup.fleetSizes.upperBound,
                                             laps: 1, boatClass: boatClass, rules: rules)
            return (rotation, layout)
        }
    }

    /// Every finding for every pairing of `venue`, in pairing order: empty if the venue passes. A pairing whose
    /// conditions file can't be loaded is a finding too. Never throws: the findings say what is wrong.
    public static func check(
        _ venue: Venue,
        boatClass: BoatClass = RaceFiles.defaults.boatClass.content,
        rules: RulesConfig = RaceFiles.defaults.rulesConfiguration.content,
        conditions: (DataFileKey) throws -> ConditionsFile = { try ConditionsFile.bundled(id: $0.id, version: $0.version) }
    ) -> [Finding] {
        var findings: [Finding] = []
        for pairing in venue.pairings {
            guard let file = try? conditions(pairing.conditions) else {
                findings.append(Finding(pairing: pairing.conditions, rotationDegrees: nil, reason: "conditions file not found"))
                continue
            }
            for (rotation, layout) in layouts(venue: venue, pairing: pairing, conditions: file, boatClass: boatClass, rules: rules) {
                for reason in problems(venue: venue, pairing: pairing, layout: layout) {
                    findings.append(Finding(pairing: pairing.conditions, rotationDegrees: rad2deg(rotation), reason: reason))
                }
            }
        }
        return findings
    }

    /// What is wrong with one course of `pairing` at `venue`: empty if nothing.
    static func problems(venue: Venue, pairing: Venue.Pairing, layout: CourseLayout) -> [String] {
        var problems: [String] = []
        let area = layout.raceArea
        for (i, land) in venue.land.enumerated() where area.overlaps(land) {
            problems.append("land \(i) reaches into the race area")
        }

        let line = layout.startLine
        let marks = layout.elements.flatMap(\.marks) + [line.pin, line.committee]
        for (i, land) in venue.land.enumerated() {
            let lineDistance = distance(line.segment, land.points)
            if lineDistance < landClearanceMetres {
                problems.append(String(format: "land %d is %.0f m from the start line", i, lineDistance))
            }
            for mark in marks {
                let d = distance(mark.position, land.points)
                if d < landClearanceMetres {
                    problems.append(String(format: "land %d is %.0f m from the ", i, d) + mark.name)
                }
            }
        }

        if !area.corners.allSatisfy({ pairing.geographicGrid.grid.cell(containing: $0) != nil }) {
            problems.append("the geographic grid doesn't cover the race area")
        }

        if let current = venue.current {
            if !area.corners.allSatisfy({ current.grid.cell(containing: $0) != nil }) {
                problems.append("the current grid doesn't cover the race area")
            }
            let grid = current.grid
            let channel = channelFraction * current.maxDepth
            var deepestOutside = false
            var shallowsInside = false
            for row in 0..<grid.rows {
                for column in 0..<grid.columns {
                    let position = grid.position(column: column, row: row)
                    let depth = current.depth(column: column, row: row)
                    let inside = area.contains(position)
                    if depth == current.maxDepth && !inside { deepestOutside = true }
                    if depth > 0 && depth < channel && inside { shallowsInside = true }
                }
            }
            if deepestOutside {
                problems.append("the deepest water lies outside the race area")
            }
            if !shallowsInside {
                problems.append("no shallows inside the race area")
            }
        }
        return problems
    }

    /// Metres from `p` to the simple polygon `polygon`: 0 on or in it.
    static func distance(_ p: Vec2, _ polygon: [Vec2]) -> Double {
        if Collision.contains(simplePolygon: polygon, p) { return 0 }
        return edges(polygon).map { (Collision.closestPoint(on: $0, to: p) - p).length }.min() ?? .infinity
    }

    /// Metres from segment `s` to the simple polygon `polygon`: 0 where they meet.
    static func distance(_ s: Segment, _ polygon: [Vec2]) -> Double {
        let ends = [s.a, s.b]
        if ends.contains(where: { Collision.contains(simplePolygon: polygon, $0) }) { return 0 }
        var best = Double.infinity
        for edge in edges(polygon) {
            if Collision.intersects(s, edge) { return 0 }
            for p in ends { best = min(best, (Collision.closestPoint(on: edge, to: p) - p).length) }
            for p in [edge.a, edge.b] { best = min(best, (Collision.closestPoint(on: s, to: p) - p).length) }
        }
        return best
    }

    private static func edges(_ polygon: [Vec2]) -> [Segment] {
        polygon.indices.map { Segment(polygon[$0], polygon[($0 + 1) % polygon.count]) }
    }
}
