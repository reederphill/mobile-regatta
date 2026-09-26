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

    /// The pairing for exactly this conditions file, id and version: e.g. `pairing(for: setup.conditions.key)`.
    /// Nil when the venue has no pairing for that version, even if it has one for another.
    public func pairing(for conditions: DataFileKey) -> Pairing? {
        pairings.first { $0.conditions == conditions }
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

    /// One venue × conditions pairing (#10, #12): what a race's `WindSetup` is drawn around.
    public struct Pairing: Sendable, Hashable {
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
    /// with no persistent trend. `WindSetup.trend` holds the result: veer is `.right`, back `.left`.
    public enum TrendDirection: String, Sendable, Equatable, Codable, CaseIterable {
        case veer
        case back
        case either
    }

    /// Where the nodes of a venue grid lie. Node (column, row) is at
    /// `origin + column × cellSize × columnAxis + row × cellSize × rowAxis`.
    public struct Grid: Sendable, Hashable {
        /// Node (0, 0), metres.
        public let origin: Vec2
        /// Distance between neighbouring nodes, metres.
        public let cellSize: Double
        /// Compass bearing of `rowAxis`, radians in [0, 2π). At 0 the row index grows northward and the
        /// column index eastward.
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

        /// How far from a node, in cells, a point counts as on it: absorbs the rounding of a rotated
        /// grid, so a node's own `position` lands exactly on it and an edge point stays inside.
        static let nodeSnap = 1e-9

        /// The cell a point lies in, and where in it: node (`column`, `row`) is the cell's corner nearest
        /// the origin, and the fractions run 0...1 along `columnAxis` and `rowAxis` from it.
        public struct Cell: Sendable, Hashable {
            /// In 0...columns − 2 and 0...rows − 2, so the cell's far corner is always a node.
            public let column: Int
            public let row: Int
            public let columnFraction: Double
            public let rowFraction: Double
        }

        /// The cell `p` lies in, or nil beyond the outer nodes. A point on the edge is inside: on the far
        /// edges it is in the last cell with fraction 1.
        public func cell(containing p: Vec2) -> Cell? {
            let offset = p - origin
            guard let (column, columnFraction) = Self.split(offset.dot(columnAxis) / cellSize, nodes: columns),
                  let (row, rowFraction) = Self.split(offset.dot(rowAxis) / cellSize, nodes: rows)
            else { return nil }
            return Cell(column: column, row: row, columnFraction: columnFraction, rowFraction: rowFraction)
        }

        /// Bilinear interpolation of per-node `values` (row-major, `index`) across `cell`. Exact at the
        /// nodes, the far ones included.
        public func bilinear(_ values: [Double], at cell: Cell) -> Double {
            func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a * (1 - t) + b * t }
            let (c, r, u, v) = (cell.column, cell.row, cell.columnFraction, cell.rowFraction)
            let near = lerp(values[index(column: c, row: r)], values[index(column: c + 1, row: r)], u)
            let far = lerp(values[index(column: c, row: r + 1)], values[index(column: c + 1, row: r + 1)], u)
            return lerp(near, far, v)
        }

        /// Splits a position along one axis, in cells from node 0, into the cell's lower node and the
        /// fraction across it, for an axis of `nodes` nodes; nil beyond the outer nodes (or NaN).
        private static func split(_ position: Double, nodes: Int) -> (Int, Double)? {
            let nearest = position.rounded()
            let x = abs(position - nearest) <= nodeSnap ? nearest : position
            guard x >= 0, x <= Double(nodes - 1) else { return nil }
            let lower = min(Int(x), nodes - 2)
            return (lower, x - Double(lower))
        }
    }

    /// How the venue turns and scales the wind at a point, for one pairing (#10).
    public struct GeographicShift: Sendable, Hashable {
        /// Change in wind direction, radians; positive veers (clockwise), as in `WindField`.
        public let directionDelta: Double
        /// Multiplier on wind speed.
        public let speedFactor: Double

        /// No shift: outside the geographic grid.
        public static let neutral = GeographicShift(directionDelta: 0, speedFactor: 1)

        public init(directionDelta: Double, speedFactor: Double) {
            self.directionDelta = directionDelta
            self.speedFactor = speedFactor
        }
    }

    /// Geographic shift over the venue for one pairing (#10), with land shadow baked into the speed
    /// factor. Values are per node, row-major (`grid.index`). `sample` reads it anywhere; `WindField.sample`
    /// composes it into the wind (#81).
    public struct GeographicGrid: Sendable, Hashable {
        public let grid: Grid
        /// Change in wind direction, radians; positive veers (clockwise), as in `WindField`.
        public let directionDeltas: [Double]
        /// Multiplier on wind speed, > 0.
        public let speedFactors: [Double]

        public func directionDelta(column: Int, row: Int) -> Double { directionDeltas[grid.index(column: column, row: row)] }
        public func speedFactor(column: Int, row: Int) -> Double { speedFactors[grid.index(column: column, row: row)] }

        /// The shift at `p`: bilinear between the four nodes around it, each value on its own (direction
        /// deltas as plain numbers, which is fine at |Δ| < 180°), and `.neutral` beyond the outer nodes.
        /// Pure: no state, no randomness.
        public func sample(_ p: Vec2) -> GeographicShift {
            guard let cell = grid.cell(containing: p) else { return .neutral }
            return GeographicShift(directionDelta: grid.bilinear(directionDeltas, at: cell),
                                   speedFactor: grid.bilinear(speedFactors, at: cell))
        }
    }

    /// The venue's current (#11, ADR 0003): public, with no random part. `CurrentField` (#78) turns it
    /// into the current at a position and race time from the tide state at the gun.
    ///
    /// Tide state is the phase of the tidal cycle, radians: at the deepest node the current is
    /// `peak × sin(phase)` along the flood direction, so 0 is slack before the flood, π/2 peak flood,
    /// π slack before the ebb, 3π/2 peak ebb. The channel current reverses, never rotates; eddies add to it.
    public struct Current: Sendable, Equatable {
        /// Speed of the principal lunar semidiurnal constituent M2, degrees per hour (NOAA CO-OPS,
        /// harmonic constituents: https://tidesandcurrents.noaa.gov/about_harmonic_constituents.html).
        public static let m2DegreesPerHour = 28.984_104_2
        /// One tidal cycle, the M2 period (12.420 601 2 h ≈ 44 714.164 s), in tide-clock seconds.
        public static let tidalCycle: Double = 360 / m2DegreesPerHour * 3600

        /// Strength at the venue's deepest point at peak tide, m/s (0.5–2 kn, #11).
        public let peak: Double
        /// A tidal venue's tide clock runs faster than real time, so the current changes during a race.
        public let isTidal: Bool
        /// Tide-clock seconds per race second: > 1 when tidal (about 19, so slack to peak takes about
        /// 10 min), exactly 1 when not, so the current is steady within a race (#11). Only approximately:
        /// at 1 the phase still advances about 10° in a 20-minute race.
        public let tideClockRate: Double
        /// Tide states a race may start at; drawn per race from the race seed (#11, #78).
        public let allowedTideStatesAtGun: TideStateRange
        /// Where the depth and flood-direction nodes lie.
        public let grid: Grid
        /// Water depth per node, metres, ≥ 0. Zero is dry: no current.
        public let depths: [Double]
        /// Compass bearing the flood flows towards, per node, radians. The ebb flows the opposite way.
        public let floodDirections: [Double]
        /// Strength at depth d is `peak × (d / maxDepth)^strengthExponent`. Authored; 2/3 recommended (Manning).
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

    /// Tide states from `from` forward to `to`, radians, wrapping through 0 when `to < from`. Equal ends
    /// mean one tide state. `from` is in [0, 2π) and `to` in [0, 2π), except that `from == 0, to == 2π` is
    /// the whole cycle: any tide state.
    public struct TideStateRange: Sendable, Equatable {
        public let from: Double
        public let to: Double

        /// Radians from `from` forward to `to`, in [0, 2π]; 2π for the whole cycle.
        public var width: Double {
            let w = to - from
            return w < 0 ? w + 2 * .pi : w
        }

        public var isWholeCycle: Bool { from == 0 && to == 2 * .pi }

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
        /// Solid-body rotation inside this radius, metres; outside it the speed falls as `coreRadius / r`,
        /// tapered to zero at `outerRadius` (`relativeSpeed(atDistance:)`).
        public let coreRadius: Double
        /// The eddy has no effect from this radius out, metres.
        public let outerRadius: Double
        /// Speed at the core radius at peak tide, m/s. Each centre scales it by the tide running its way
        /// at that centre: `max(0, ±sin(local phase))` (docs/venue-file.md).
        public let peak: Double
        public let floodRotation: Rotation

        public var ebbRotation: Rotation { floodRotation.reversed }

        /// Fraction of the eddy's speed at distance `r` (metres) from its active centre, in 0...1:
        /// solid-body `r / coreRadius` inside the core, then Rankine `coreRadius / r` tapered linearly to
        /// zero at `outerRadius`, so the speed is continuous everywhere, 1 at the core radius and 0 from
        /// the outer radius out. The velocity is this × the eddy's tide-scaled speed, tangential to the
        /// centre in the active rotation (docs/venue-file.md).
        public func relativeSpeed(atDistance r: Double) -> Double {
            guard r > 0 else { return 0 }
            if r <= coreRadius { return r / coreRadius }
            guard r < outerRadius else { return 0 }
            return coreRadius / r * (outerRadius - r) / (outerRadius - coreRadius)
        }
    }

    /// A simple polygon of land: its edges never cross or touch except at shared corners.
    public struct LandPolygon: Sendable, Equatable {
        /// Corners, metres, anticlockwise, without the closing point repeated.
        public let points: [Vec2]

        /// Whether `p` is inside (even-odd rule). Points exactly on an edge may go either way.
        public func contains(_ p: Vec2) -> Bool { Collision.contains(simplePolygon: points, p) }
    }

    public init(fileData: Data, header: DataFileHeader) throws {
        switch header.schemaVersion {
        case 1:
            // Duplicate keys were already refused by `DataFile`, so every parse below reads the same file.
            let document = try JSONDecoder().decode(VenueSchema1.self, from: fileData)
            try document.rejectUnknownFields(in: fileData)
            self = try document.venue(id: header.id)
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

    enum CodingKeys: String, CodingKey, CaseIterable { case schemaVersion, id, version, placeholders, notes, displayName, landmarks, land, pairings, current }

    public struct Landmark: Codable, Equatable, Sendable {
        public var asset: String
        public var positionMetres: [Double]

        enum CodingKeys: String, CodingKey, CaseIterable { case asset, positionMetres }
    }

    public struct Land: Codable, Equatable, Sendable {
        /// `[x, y]` corners; the last repeats the first, closing the ring.
        public var outlineMetres: [[Double]]

        enum CodingKeys: String, CodingKey, CaseIterable { case outlineMetres }
    }

    public struct Pairing: Codable, Equatable, Sendable {
        public var conditionsRef: DataFileKey
        public var meanDirectionDegrees: Double
        public var trendDirection: Venue.TrendDirection
        public var startLineCentreMetres: [Double]
        public var geographicGrid: GeographicGrid

        enum CodingKeys: String, CodingKey, CaseIterable { case conditionsRef, meanDirectionDegrees, trendDirection, startLineCentreMetres, geographicGrid }
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

        enum CodingKeys: String, CodingKey, CaseIterable { case originMetres, cellSizeMetres, orientationDegrees, columns, rows, directionDeltaDegrees, speedFactor }
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

        enum CodingKeys: String, CodingKey, CaseIterable { case hasCurrent, peakKnots, tidal, tideClockRate, allowedTideStatesAtGun, grid, byDepth, eddies }
    }

    public struct TideStateRange: Codable, Equatable, Sendable {
        public var fromDegrees: Double
        public var toDegrees: Double

        enum CodingKeys: String, CodingKey, CaseIterable { case fromDegrees, toDegrees }
    }

    public struct CurrentGrid: Codable, Equatable, Sendable {
        public var originMetres: [Double]
        public var cellSizeMetres: Double
        public var orientationDegrees: Double
        public var columns: Int
        public var rows: Int
        public var depthMetres: [[Double]]
        public var floodDirectionDegrees: [[Double]]

        enum CodingKeys: String, CodingKey, CaseIterable { case originMetres, cellSizeMetres, orientationDegrees, columns, rows, depthMetres, floodDirectionDegrees }
    }

    public struct ByDepth: Codable, Equatable, Sendable {
        public var strengthExponent: Double
        public var shallowsLeadDegrees: Double

        enum CodingKeys: String, CodingKey, CaseIterable { case strengthExponent, shallowsLeadDegrees }
    }

    public struct Eddy: Codable, Equatable, Sendable {
        public var floodCentreMetres: [Double]
        public var ebbCentreMetres: [Double]
        public var coreRadiusMetres: Double
        public var outerRadiusMetres: Double
        public var peakKnots: Double
        public var floodRotation: Venue.Eddy.Rotation

        enum CodingKeys: String, CodingKey, CaseIterable { case floodCentreMetres, ebbCentreMetres, coreRadiusMetres, outerRadiusMetres, peakKnots, floodRotation }
    }

    /// Throws `malformed` naming the first field in `data` that schema 1 doesn't have (such as a typo,
    /// `"eddys"`), or that is `null`, which the decoder would otherwise ignore. A released file can't be
    /// fixed, so it mustn't ship with a field nothing reads. Call after decoding, so type errors come first.
    func rejectUnknownFields(in data: Data) throws {
        let document = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        if let pointer = Self.fields.firstUnknownField(in: document, at: "") {
            throw DataFileError.malformed(kind: Venue.kind, reason: "unknown or null field \(pointer): a venue file has only its schema's fields")
        }
    }

    /// Every field schema 1 has, from each type's `CodingKeys`, so it can't drift from the decoder.
    static let fields: FieldTree = .object(CodingKeys.self, [
        .landmarks: .array(.object(Landmark.CodingKeys.self)),
        .land: .array(.object(Land.CodingKeys.self)),
        .pairings: .array(.object(Pairing.CodingKeys.self, [
            .conditionsRef: .object(DataFileKey.CodingKeys.self),
            .geographicGrid: .object(GeographicGrid.CodingKeys.self),
        ])),
        .current: .object(Current.CodingKeys.self, [
            .allowedTideStatesAtGun: .object(TideStateRange.CodingKeys.self),
            .grid: .object(CurrentGrid.CodingKeys.self),
            .byDepth: .object(ByDepth.CodingKeys.self),
            .eddies: .array(.object(Eddy.CodingKeys.self)),
        ]),
    ])

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
            if Collision.signedArea(ring) < 0 { ring.reverse() }
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
        for i in 0..<n {
            let a = points[i], b = points[(i + 1) % n]
            // Neighbouring edge b → c must not double back over a → b.
            let c = points[(i + 2) % n]
            if orientation(a, b, c) == 0 && (a - b).dot(c - b) > 0 { return "doubles back on itself at corner \((i + 1) % n)" }
            for j in stride(from: i + 2, to: n, by: 1) where !(i == 0 && j == n - 1) {
                if Collision.intersects(Segment(a, b), Segment(points[j], points[(j + 1) % n])) {
                    return "is self-intersecting: edge \(i) meets edge \(j)"
                }
            }
        }
        guard Collision.signedArea(points) != 0 else { return "has no area" }
        return nil
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
        let states = allowedTideStatesAtGun
        let range: Venue.TideStateRange
        if states.fromDegrees == 0 && states.toDegrees == 360 {
            range = Venue.TideStateRange(from: 0, to: 2 * .pi) // the whole cycle
        } else {
            range = Venue.TideStateRange(
                from: try v.bearing(states.fromDegrees, "current allowedTideStatesAtGun.fromDegrees"),
                to: try v.bearing(states.toDegrees,
                                  "current allowedTideStatesAtGun.toDegrees (or 0 to 360 for the whole cycle)"))
        }
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

/// The object keys a data file may have, for rejecting unknown fields. Leaves (`value`) aren't walked,
/// so the numbers in a grid cost nothing.
indirect enum FieldTree: Sendable {
    case value
    case object([String: FieldTree])
    case array(FieldTree)

    static func object<Key: CodingKey & CaseIterable & Hashable>(_: Key.Type, _ nested: [Key: FieldTree] = [:]) -> FieldTree {
        .object(Dictionary(uniqueKeysWithValues: Key.allCases.map { ($0.stringValue, nested[$0] ?? .value) }))
    }

    /// JSON Pointer of the first member, in key order, that isn't in the tree or is null. Values of the
    /// wrong shape are left to the decoder.
    func firstUnknownField(in value: Any, at path: String) -> String? {
        switch self {
        case .value:
            return nil
        case .object(let fields):
            guard let members = value as? [String: Any] else { return nil }
            for key in members.keys.sorted() {
                let pointer = path + "/" + key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
                guard let field = fields[key], let member = members[key], !(member is NSNull) else { return pointer }
                if let found = field.firstUnknownField(in: member, at: pointer) { return found }
            }
            return nil
        case .array(let element):
            guard let elements = value as? [Any] else { return nil }
            for (k, member) in elements.enumerated() {
                if let found = element.firstUnknownField(in: member, at: path + "/\(k)") { return found }
            }
            return nil
        }
    }
}
