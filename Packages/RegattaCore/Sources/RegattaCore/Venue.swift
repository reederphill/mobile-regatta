import Foundation

/// A venue: the water a race is sailed on, its land, the conditions it can have, and its current,
/// loaded from its immutable, versioned data file (ADR 0004). Load one with `DataFile<Venue>(data:)`
/// or `VenueFile.bundled(id:version:)`. The file format is `VenueSchema1`, documented in
/// `docs/venue-file.md`.
///
/// Positions are in the venue's own frame: metres, x east, y north, from an origin the file picks.
/// Files use metres, degrees and knots; everything here is converted once at load to metres, radians
/// and m/s. Directions are compass bearings (0 = north, clockwise).
public struct Venue: DataFileContent, Equatable {
    public static let kind = "venue"
    public static let bundleDirectory = "venues"
    public static let supportedSchemaVersions = [1]

    /// Name shown to players.
    public let displayName: String
    /// Landmark silhouettes drawn on the venue's land.
    public let landmarks: [Landmark]
    /// Land, as simple polygons (concave allowed). Only at the edges of the race area (#12).
    public let land: [LandPolygon]
    /// The conditions this venue can have, one pairing each, in file order.
    public let pairings: [Pairing]
    /// The venue's current, or nil if it has none (#11).
    public let current: Current?

    public var hasCurrent: Bool { current != nil }

    /// The pairing for conditions `id`, whatever its version.
    public func pairing(conditionsID id: String) -> Pairing? {
        pairings.first { $0.conditions.id == id }
    }

    /// Whether `p` is on any of the venue's land.
    public func isLand(_ p: Vec2) -> Bool {
        land.contains { $0.contains(p) }
    }

    /// A landmark silhouette placed on the venue.
    public struct Landmark: Sendable, Equatable {
        /// Asset name, as listed in `docs/assets-manifest.md` (#53). Checked only as non-empty here.
        public let asset: String
        /// Where the silhouette is anchored, metres.
        public let position: Vec2
    }

    /// One venue × conditions pairing (#10, #12).
    public struct Pairing: Sendable, Equatable {
        /// The conditions file this pairing is authored for. Pinned to a version, since the pairing's
        /// anchor and grid were checked against that conditions entry's wind range.
        public let conditions: DataFileKey
        /// Authored mean wind direction, the compass bearing the wind blows from, radians in [0, 2π).
        /// The race seed varies it by up to ±10° (#10, #77).
        public let meanDirection: Double
        /// Which way a persistent shift trends, if the conditions have one.
        public let trendDirection: TrendDirection
        /// Centre of the start line: the course is laid from here up the seeded mean direction,
        /// square to it, with no deliberate skew (#12).
        public let startLineCentre: Vec2
        /// The venue's geographic shift for this pairing, land shadow baked in.
        public let geographicGrid: GeographicGrid
    }

    /// The direction of a persistent shift. Veer is clockwise (a right shift, looking upwind);
    /// back is anticlockwise. `either` lets the race seed choose (#10, #77). Ignored for conditions
    /// with no persistent trend.
    public enum TrendDirection: String, Sendable, Equatable, Codable, CaseIterable {
        case veer
        case back
        case either
    }

    /// Where the nodes of a venue grid lie. Node (column, row) is at
    /// `origin + column × cellSize × columnAxis + row × cellSize × rowAxis`.
    public struct Grid: Sendable, Equatable {
        /// Node (0, 0), metres.
        public let origin: Vec2
        /// Distance between neighbouring nodes, metres.
        public let cellSize: Double
        /// Compass bearing of `rowAxis`, radians in [0, 2π). At 0, rows run north and columns east.
        public let orientation: Double
        /// Nodes per row and per column, at least 2 each.
        public let columns: Int
        public let rows: Int

        /// Unit vector along which the row index grows: `.heading(orientation)`.
        public var rowAxis: Vec2 { .heading(orientation) }
        /// Unit vector along which the column index grows: 90° clockwise of `rowAxis`.
        public var columnAxis: Vec2 { rowAxis.rightPerp }
        public var nodeCount: Int { columns * rows }

        /// Index of node (column, row) in a grid's row-major value arrays.
        public func index(column: Int, row: Int) -> Int { row * columns + column }

        public func position(column: Int, row: Int) -> Vec2 {
            origin + columnAxis * (Double(column) * cellSize) + rowAxis * (Double(row) * cellSize)
        }
    }

    /// Geographic shift over the venue for one pairing (#10), with land shadow baked into the speed
    /// factor. Values are per node, row-major (`grid.index`). Sampling, bilinear and neutral outside
    /// the grid, is #77.
    public struct GeographicGrid: Sendable, Equatable {
        public let grid: Grid
        /// Change in wind direction, radians; positive veers (clockwise), as in `WindField`.
        public let directionDeltas: [Double]
        /// Multiplier on wind speed, > 0.
        public let speedFactors: [Double]

        public func directionDelta(column: Int, row: Int) -> Double { directionDeltas[grid.index(column: column, row: row)] }
        public func speedFactor(column: Int, row: Int) -> Double { speedFactors[grid.index(column: column, row: row)] }
    }

    /// The venue's current (#11, ADR 0003): public, with no random part. `CurrentField` (#78) turns it
    /// into the current at a position and race time from the tide state at the gun.
    ///
    /// Tide state is the phase of the tidal cycle, radians: at the deepest node the current is
    /// `peak × sin(phase)` along the flood direction, so 0 is slack before the flood, π/2 peak flood,
    /// π slack before the ebb, 3π/2 peak ebb. It reverses, never rotates.
    public struct Current: Sendable, Equatable {
        /// One tidal cycle (the M2 constituent, 12 h 25 min 12 s) in real seconds.
        public static let tidalCycle: Double = 44_712

        /// Strength at the venue's deepest point at peak tide, m/s (0.5–2 kn, #11).
        public let peak: Double
        /// A tidal venue's tide clock runs faster than real time, so the current changes during a race.
        public let isTidal: Bool
        /// Tide-clock seconds per race second: > 1 when tidal (about 19, so slack to peak takes about
        /// 10 min), exactly 1 when not, so the current is steady within a race (#11).
        public let tideClockRate: Double
        /// Tide states a race may start at; drawn per race from the race seed (#11, #78).
        public let allowedTideStatesAtGun: TideStateRange
        /// Where the depth and flood-direction nodes lie.
        public let grid: Grid
        /// Water depth per node, metres, ≥ 0. Zero is dry: no current.
        public let depths: [Double]
        /// Compass bearing the flood flows towards, per node, radians. The ebb flows the opposite way.
        public let floodDirections: [Double]
        /// Strength at depth d is `peak × (d / maxDepth)^strengthExponent` (Manning: 2/3).
        public let strengthExponent: Double
        /// How far ahead of the deepest water a dry node's tide runs, radians of tide phase. At depth d
        /// the local phase is `phase + shallowsLead × (1 − d / maxDepth)`: the shallows turn first.
        public let shallowsLead: Double
        /// Headland eddies (optional).
        public let eddies: [Eddy]
        /// Deepest node, metres, > 0. Derived at load.
        public let maxDepth: Double

        /// Fraction of `peak` the current reaches at depth `depth` (metres), in 0...1.
        public func relativeStrength(depth: Double) -> Double {
            guard depth > 0 else { return 0 }
            return pow(min(depth / maxDepth, 1), strengthExponent)
        }

        /// Phase lead of the tide at depth `depth` (metres), radians, in 0...shallowsLead.
        public func phaseLead(depth: Double) -> Double {
            shallowsLead * (1 - (max(depth, 0) / maxDepth).clamped(to: 0...1))
        }

        public func depth(column: Int, row: Int) -> Double { depths[grid.index(column: column, row: row)] }
        public func floodDirection(column: Int, row: Int) -> Double { floodDirections[grid.index(column: column, row: row)] }
    }

    /// Tide states from `from` forward to `to`, radians in [0, 2π), wrapping through 0 when `to < from`.
    /// Equal ends mean one tide state.
    public struct TideStateRange: Sendable, Equatable {
        public let from: Double
        public let to: Double

        /// Radians from `from` forward to `to`, in [0, 2π).
        public var width: Double {
            let w = to - from
            return w < 0 ? w + 2 * .pi : w
        }

        /// Whether tide state `phase` (radians, any turn) lies in the range.
        public func contains(_ phase: Double) -> Bool {
            var offset = fmod(phase - from, 2 * .pi)
            if offset < 0 { offset += 2 * .pi }
            return offset <= width
        }
    }

    /// A headland eddy: a Rankine vortex on the down-current side of a headland, which follows the
    /// tide and flips to the other side, turning the other way, when the tide turns (#11, #78).
    public struct Eddy: Sendable, Equatable {
        public enum Rotation: String, Sendable, Equatable, Codable, CaseIterable {
            case clockwise
            case anticlockwise

            public var reversed: Rotation { self == .clockwise ? .anticlockwise : .clockwise }
        }

        /// Centre while the tide floods and while it ebbs, metres.
        public let floodCentre: Vec2
        public let ebbCentre: Vec2
        /// Solid-body rotation inside this radius, metres; speed falls as `coreRadius / r` outside it.
        public let coreRadius: Double
        /// The eddy has no effect beyond this radius, metres.
        public let outerRadius: Double
        /// Speed at the core radius at peak tide, m/s; scales with the strength of the tide.
        public let peak: Double
        public let floodRotation: Rotation

        public var ebbRotation: Rotation { floodRotation.reversed }
    }

    /// A simple polygon of land: its edges never cross or touch except at shared corners.
    public struct LandPolygon: Sendable, Equatable {
        /// Corners, metres, anticlockwise, without the closing point repeated.
        public let points: [Vec2]

        /// Whether `p` is inside (even-odd rule). Points exactly on an edge may go either way.
        public func contains(_ p: Vec2) -> Bool {
            var inside = false
            var j = points.count - 1
            for i in points.indices {
                let a = points[i], b = points[j]
                if (a.y > p.y) != (b.y > p.y) {
                    let x = a.x + (p.y - a.y) / (b.y - a.y) * (b.x - a.x)
                    if p.x < x { inside.toggle() }
                }
                j = i
            }
            return inside
        }
    }

    public init(fileData: Data, header: DataFileHeader) throws {
        switch header.schemaVersion {
        case 1:
            self = try JSONDecoder().decode(VenueSchema1.self, from: fileData).venue(id: header.id)
        default:
            throw DataFileError.unsupportedSchemaVersion(
                kind: Self.kind, found: header.schemaVersion, supported: Self.supportedSchemaVersions)
        }
    }

    fileprivate init(displayName: String, landmarks: [Landmark], land: [LandPolygon], pairings: [Pairing], current: Current?) {
        self.displayName = displayName
        self.landmarks = landmarks
        self.land = land
        self.pairings = pairings
        self.current = current
    }
}

public typealias VenueFile = DataFile<Venue>

// MARK: - Schema 1

/// The venue file, schema version 1, exactly as written: metres, degrees and knots, `[x, y]` points,
/// grids as arrays of rows. Encodable too, so tools can write venue files; decoding what it encodes
/// gives an equal value. Documented, with its validation rules, in `docs/venue-file.md`.
public struct VenueSchema1: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var id: String
    public var version: Int
    public var placeholders: [String]?
    public var notes: [String]?
    public var displayName: String
    public var landmarks: [Landmark]
    public var land: [Land]
    public var pairings: [Pairing]
    public var current: Current

    public struct Landmark: Codable, Equatable, Sendable {
        public var asset: String
        public var positionMetres: [Double]
    }

    public struct Land: Codable, Equatable, Sendable {
        /// `[x, y]` corners; the last repeats the first, closing the ring.
        public var outlineMetres: [[Double]]
    }

    public struct Pairing: Codable, Equatable, Sendable {
        public var conditionsRef: DataFileKey
        public var meanDirectionDegrees: Double
        public var trendDirection: Venue.TrendDirection
        public var startLineCentreMetres: [Double]
        public var geographicGrid: GeographicGrid
    }

    public struct GeographicGrid: Codable, Equatable, Sendable {
        public var originMetres: [Double]
        public var cellSizeMetres: Double
        public var orientationDegrees: Double
        public var columns: Int
        public var rows: Int
        /// `rows` arrays of `columns` values each; row 0 passes through the origin.
        public var directionDeltaDegrees: [[Double]]
        public var speedFactor: [[Double]]
    }

    public struct Current: Codable, Equatable, Sendable {
        /// When false, every other field must be absent.
        public var hasCurrent: Bool
        public var peakKnots: Double?
        public var tidal: Bool?
        /// Required when tidal, absent (1) when not.
        public var tideClockRate: Double?
        public var allowedTideStatesAtGun: TideStateRange?
        public var grid: CurrentGrid?
        public var byDepth: ByDepth?
        public var eddies: [Eddy]?
    }

    public struct TideStateRange: Codable, Equatable, Sendable {
        public var fromDegrees: Double
        public var toDegrees: Double
    }

    public struct CurrentGrid: Codable, Equatable, Sendable {
        public var originMetres: [Double]
        public var cellSizeMetres: Double
        public var orientationDegrees: Double
        public var columns: Int
        public var rows: Int
        public var depthMetres: [[Double]]
        public var floodDirectionDegrees: [[Double]]
    }

    public struct ByDepth: Codable, Equatable, Sendable {
        public var strengthExponent: Double
        public var shallowsLeadDegrees: Double
    }

    public struct Eddy: Codable, Equatable, Sendable {
        public var floodCentreMetres: [Double]
        public var ebbCentreMetres: [Double]
        public var coreRadiusMetres: Double
        public var outerRadiusMetres: Double
        public var peakKnots: Double
        public var floodRotation: Venue.Eddy.Rotation
    }

    /// Peak current allowed at a venue's strongest point, knots (#11).
    public static let peakKnotsRange = 0.5...2.0

    /// Validates the file and converts it to code units. Throws `DataFileError.invalidContent`.
    func venue(id: String) throws -> Venue {
        let v = VenueValidator(id: id)
        try v.check(!displayName.isEmpty, "displayName is empty")

        var landmarks: [Venue.Landmark] = []
        for (k, landmark) in self.landmarks.enumerated() {
            try v.check(!landmark.asset.isEmpty, "landmark \(k) has an empty asset name")
            landmarks.append(.init(asset: landmark.asset, position: try v.point(landmark.positionMetres, "landmark \(k) position")))
        }

        var land: [Venue.LandPolygon] = []
        for (k, polygon) in self.land.enumerated() {
            var ring = try polygon.outlineMetres.enumerated().map { try v.point($0.element, "land \(k) point \($0.offset)") }
            try v.check(ring.count >= 4 && ring.first == ring.last,
                        "land \(k) is not closed: its last point must repeat its first, with at least 3 corners")
            ring.removeLast()
            if let problem = Self.simplePolygonProblem(ring) { throw v.invalid("land \(k) \(problem)") }
            if Self.signedArea(ring) < 0 { ring.reverse() }
            land.append(.init(points: ring))
        }

        try v.check(!pairings.isEmpty, "a venue needs at least one pairing")
        var pairings: [Venue.Pairing] = []
        for (k, pairing) in self.pairings.enumerated() {
            let what = "pairing \(k) (\(pairing.conditionsRef))"
            let conditions = pairing.conditionsRef
            try v.check(DataFile<Venue>.isValidID(conditions.id) && conditions.version >= 1,
                        "\(what) conditionsRef needs a valid id and a version of at least 1")
            try v.check(!pairings.contains { $0.conditions.id == conditions.id },
                        "\(what) repeats conditions \(conditions.id): one pairing per conditions")
            let centre = try v.point(pairing.startLineCentreMetres, "\(what) startLineCentreMetres")
            try v.check(!land.contains { $0.contains(centre) }, "\(what) startLineCentreMetres is on land")
            let g = pairing.geographicGrid
            let geometry = try v.grid(
                "\(what) geographicGrid", origin: g.originMetres, cellSize: g.cellSizeMetres, orientation: g.orientationDegrees,
                columns: g.columns, rows: g.rows,
                values: [("directionDeltaDegrees", g.directionDeltaDegrees), ("speedFactor", g.speedFactor)])
            let deltas = g.directionDeltaDegrees.flatMap { $0 }
            let factors = g.speedFactor.flatMap { $0 }
            try v.check(deltas.allSatisfy { abs($0) < 180 }, "\(what) geographicGrid directionDeltaDegrees must be in (-180, 180)")
            try v.check(factors.allSatisfy { $0 > 0 }, "\(what) geographicGrid speedFactor must be positive")
            pairings.append(.init(
                conditions: conditions,
                meanDirection: try v.bearing(pairing.meanDirectionDegrees, "\(what) meanDirectionDegrees"),
                trendDirection: pairing.trendDirection,
                startLineCentre: centre,
                geographicGrid: .init(grid: geometry, directionDeltas: deltas.map(deg2rad), speedFactors: factors)
            ))
        }

        return Venue(displayName: displayName, landmarks: landmarks, land: land, pairings: pairings,
                     current: try current.current(v))
    }

    /// Why `points` (an open ring) isn't a simple polygon, or nil if it is: at least three corners,
    /// no repeated corner, no edge crossing or touching another except where neighbours meet, no
    /// edge doubling back along its neighbour, and some area.
    static func simplePolygonProblem(_ points: [Vec2]) -> String? {
        let n = points.count
        guard n >= 3 else { return "needs at least 3 corners" }
        for i in 0..<n where points[i] == points[(i + 1) % n] { return "repeats corner \(i)" }
        func orientation(_ a: Vec2, _ b: Vec2, _ c: Vec2) -> Double { (b - a).cross(c - a) }
        func onSegment(_ a: Vec2, _ b: Vec2, _ p: Vec2) -> Bool {
            min(a.x, b.x) <= p.x && p.x <= max(a.x, b.x) && min(a.y, b.y) <= p.y && p.y <= max(a.y, b.y)
        }
        func intersect(_ a: Vec2, _ b: Vec2, _ c: Vec2, _ d: Vec2) -> Bool {
            let o1 = orientation(a, b, c), o2 = orientation(a, b, d)
            let o3 = orientation(c, d, a), o4 = orientation(c, d, b)
            if ((o1 > 0 && o2 < 0) || (o1 < 0 && o2 > 0)) && ((o3 > 0 && o4 < 0) || (o3 < 0 && o4 > 0)) { return true }
            return (o1 == 0 && onSegment(a, b, c)) || (o2 == 0 && onSegment(a, b, d))
                || (o3 == 0 && onSegment(c, d, a)) || (o4 == 0 && onSegment(c, d, b))
        }
        for i in 0..<n {
            let a = points[i], b = points[(i + 1) % n]
            // Neighbouring edge b → c must not double back over a → b.
            let c = points[(i + 2) % n]
            if orientation(a, b, c) == 0 && (a - b).dot(c - b) > 0 { return "doubles back on itself at corner \((i + 1) % n)" }
            for j in stride(from: i + 2, to: n, by: 1) where !(i == 0 && j == n - 1) {
                if intersect(a, b, points[j], points[(j + 1) % n]) {
                    return "is self-intersecting: edge \(i) meets edge \(j)"
                }
            }
        }
        guard signedArea(points) != 0 else { return "has no area" }
        return nil
    }

    /// Shoelace area; positive when the ring runs anticlockwise (x east, y north).
    static func signedArea(_ points: [Vec2]) -> Double {
        var twice = 0.0
        for i in points.indices {
            twice += points[i].cross(points[(i + 1) % points.count])
        }
        return twice / 2
    }
}

/// The checks shared by every part of a venue file: each failure is `invalidContent` for this venue.
private struct VenueValidator {
    let id: String

    func invalid(_ reason: String) -> DataFileError {
        DataFileError.invalidContent(kind: Venue.kind, id: id, reason: reason)
    }

    func check(_ condition: Bool, _ reason: @autoclosure () -> String) throws {
        if !condition { throw invalid(reason()) }
    }

    func point(_ xy: [Double], _ what: @autoclosure () -> String) throws -> Vec2 {
        try check(xy.count == 2 && xy.allSatisfy(\.isFinite), "\(what()) must be a finite [x, y] point")
        return Vec2(xy[0], xy[1])
    }

    /// A compass bearing in [0, 360) degrees, as radians.
    func bearing(_ degrees: Double, _ what: @autoclosure () -> String) throws -> Double {
        try check(degrees >= 0 && degrees < 360, "\(what()) must be in [0, 360) degrees")
        return deg2rad(degrees)
    }

    /// A grid's geometry, checking that each of its value arrays has `rows` rows of `columns` finite values.
    func grid(_ what: String, origin: [Double], cellSize: Double, orientation: Double, columns: Int, rows: Int,
              values: [(name: String, rows: [[Double]])]) throws -> Venue.Grid {
        let origin = try point(origin, "\(what) originMetres")
        try check(cellSize.isFinite && cellSize > 0, "\(what) cellSizeMetres must be positive")
        try check(columns >= 2 && rows >= 2, "\(what) needs at least 2 columns and 2 rows, has \(columns) × \(rows)")
        for (name, values) in values {
            try check(values.count == rows, "\(what) \(name) has \(values.count) rows, expected \(rows)")
            for (r, row) in values.enumerated() {
                try check(row.count == columns, "\(what) \(name) row \(r) has \(row.count) values, expected \(columns)")
                try check(row.allSatisfy(\.isFinite), "\(what) \(name) row \(r) has a value that isn't finite")
            }
        }
        return Venue.Grid(origin: origin, cellSize: cellSize, orientation: try bearing(orientation, "\(what) orientationDegrees"),
                          columns: columns, rows: rows)
    }
}

private extension VenueSchema1.Current {
    func current(_ v: VenueValidator) throws -> Venue.Current? {
        guard hasCurrent else {
            try v.check(peakKnots == nil && tidal == nil && tideClockRate == nil && allowedTideStatesAtGun == nil
                        && grid == nil && byDepth == nil && eddies == nil,
                        "current: a venue with no current has no other current fields")
            return nil
        }
        guard let peakKnots, let tidal, let allowedTideStatesAtGun, let grid, let byDepth else {
            throw v.invalid("current: hasCurrent needs peakKnots, tidal, allowedTideStatesAtGun, grid and byDepth")
        }
        try v.check(VenueSchema1.peakKnotsRange.contains(peakKnots), "current: peakKnots must be 0.5–2 kn (#11)")
        let rate: Double
        if tidal {
            guard let tideClockRate else { throw v.invalid("current: a tidal venue needs tideClockRate") }
            try v.check(tideClockRate.isFinite && tideClockRate > 1, "current: a tidal venue's tideClockRate must be above 1")
            rate = tideClockRate
        } else {
            try v.check(tideClockRate == nil, "current: tideClockRate is only for tidal venues; steady current runs at 1")
            rate = 1
        }
        let range = Venue.TideStateRange(
            from: try v.bearing(allowedTideStatesAtGun.fromDegrees, "current allowedTideStatesAtGun.fromDegrees"),
            to: try v.bearing(allowedTideStatesAtGun.toDegrees, "current allowedTideStatesAtGun.toDegrees"))
        let geometry = try v.grid(
            "current grid", origin: grid.originMetres, cellSize: grid.cellSizeMetres, orientation: grid.orientationDegrees,
            columns: grid.columns, rows: grid.rows,
            values: [("depthMetres", grid.depthMetres), ("floodDirectionDegrees", grid.floodDirectionDegrees)])
        let depths = grid.depthMetres.flatMap { $0 }
        try v.check(depths.allSatisfy { $0 >= 0 }, "current grid depthMetres must not be negative")
        let maxDepth = depths.max() ?? 0
        try v.check(maxDepth > 0, "current grid needs some water deeper than 0 m")
        let floods = try grid.floodDirectionDegrees.flatMap { $0 }.map { try v.bearing($0, "current grid floodDirectionDegrees") }
        try v.check(byDepth.strengthExponent.isFinite && byDepth.strengthExponent > 0,
                    "current byDepth.strengthExponent must be positive")
        try v.check(byDepth.shallowsLeadDegrees >= 0 && byDepth.shallowsLeadDegrees < 90,
                    "current byDepth.shallowsLeadDegrees must be in [0, 90)")

        var eddies: [Venue.Eddy] = []
        for (k, eddy) in (self.eddies ?? []).enumerated() {
            let what = "current eddy \(k)"
            try v.check(eddy.coreRadiusMetres.isFinite && eddy.coreRadiusMetres > 0, "\(what) coreRadiusMetres must be positive")
            try v.check(eddy.outerRadiusMetres.isFinite && eddy.outerRadiusMetres > eddy.coreRadiusMetres,
                        "\(what) outerRadiusMetres must be larger than coreRadiusMetres")
            try v.check(eddy.peakKnots > 0 && eddy.peakKnots <= peakKnots,
                        "\(what) peakKnots must be positive and at most the venue's peakKnots")
            eddies.append(.init(
                floodCentre: try v.point(eddy.floodCentreMetres, "\(what) floodCentreMetres"),
                ebbCentre: try v.point(eddy.ebbCentreMetres, "\(what) ebbCentreMetres"),
                coreRadius: eddy.coreRadiusMetres, outerRadius: eddy.outerRadiusMetres,
                peak: metresPerSecond(knots: eddy.peakKnots), floodRotation: eddy.floodRotation))
        }

        return Venue.Current(
            peak: metresPerSecond(knots: peakKnots), isTidal: tidal, tideClockRate: rate,
            allowedTideStatesAtGun: range, grid: geometry, depths: depths, floodDirections: floods,
            strengthExponent: byDepth.strengthExponent, shallowsLead: deg2rad(byDepth.shallowsLeadDegrees),
            eddies: eddies, maxDepth: maxDepth)
    }
}
