import Foundation
import RegattaCore

/// The chart's shapes (#115), pure geometry in metres with no SpriteKit: the race area's hatched band, the land's
/// coasts and relief strips, and the shallows' tint weight from the depth grid.
nonisolated enum ChartGeometry {
    // MARK: - Race-area hatch

    /// The hatch of the band `width` metres outside `area`'s rectangle: lines at 45° to its sides, `spacing` metres
    /// apart, each clipped to the band (the outer rectangle less the area), so none crosses into the race area.
    static func hatch(around area: RaceArea, width: Double, spacing: Double) -> [Segment] {
        guard width > 0, spacing > 0 else { return [] }
        let up = Vec2.heading(area.axis), right = up.rightPerp
        let hw = area.halfWidth, hl = area.halfLength
        let ow = hw + width, ol = hl + width
        func world(_ u: Double, _ v: Double) -> Vec2 { area.centre + right * u + up * v }

        // Lines v = u - c in the area's frame (u across, v along), c stepping across the outer rectangle by
        // spacing·√2, so neighbouring lines are `spacing` apart.
        var segments: [Segment] = []
        let reach = ow + ol, step = spacing * 2.0.squareRoot()
        var c = -reach
        while c <= reach {
            // u along the line, clipped to the outer rectangle: |u| ≤ ow and |u − c| ≤ ol.
            let lo = max(-ow, c - ol), hi = min(ow, c + ol)
            if lo < hi {
                // The part inside the area's rectangle: |u| ≤ hw and |u − c| ≤ hl.
                let ilo = max(-hw, c - hl), ihi = min(hw, c + hl)
                let pieces: [(Double, Double)] = ilo < ihi ? [(lo, ilo), (ihi, hi)] : [(lo, hi)]
                for (a, b) in pieces where b - a > 1e-6 {
                    segments.append(Segment(world(a, a - c), world(b, b - c)))
                }
            }
            c += step
        }
        return segments
    }

    // MARK: - Land

    /// An edge of one of the land polygons: from `points[index]` to the next corner.
    struct Edge: Equatable, Sendable {
        var polygon: Int
        var index: Int
        var a: Vec2
        var b: Vec2
    }

    /// The edges of `polygons` that meet water: every edge but those two polygons share (Fellmere's four pieces meet
    /// along diagonals, which are inland). Within `tolerance` metres, either way round.
    static func coastEdges(of polygons: [[Vec2]], tolerance: Double = 0.01) -> [Edge] {
        let all = edges(of: polygons)
        func same(_ p: Vec2, _ q: Vec2) -> Bool { (p - q).length <= tolerance }
        return all.filter { edge in
            !all.contains { other in
                other.polygon != edge.polygon
                    && ((same(other.a, edge.a) && same(other.b, edge.b)) || (same(other.a, edge.b) && same(other.b, edge.a)))
            }
        }
    }

    static func edges(of polygons: [[Vec2]]) -> [Edge] {
        polygons.enumerated().flatMap { p, points in
            points.indices.map { i in Edge(polygon: p, index: i, a: points[i], b: points[(i + 1) % points.count]) }
        }
    }

    /// One band of relief: a quadrilateral strip in from a coast edge, and how strongly it is shaded.
    struct ReliefStrip: Equatable, Sendable {
        /// Corners, anticlockwise: the outer edge's two ends, then the inner edge's.
        var corners: [Vec2]
        /// Whether it faces the light (lit) or away from it (shaded).
        var isLit: Bool
        /// 0…1: how squarely the coast faces to or from the light, fading band by band inland.
        var weight: Double
    }

    /// Soft relief from the polygons' shape alone (#115: no height data): `steps` bands reaching `depth` metres in
    /// from every coast edge, each lit or shaded by how its coast faces the light from compass bearing `light`. A
    /// band's ends are mitred along the bisector with the next coast edge, so bands neither overlap nor spill past a
    /// reflex corner into the water; where a coast meets an inland edge the band ends square.
    static func relief(of polygons: [[Vec2]], depth: Double, steps: Int, light: Double) -> [ReliefStrip] {
        guard depth > 0, steps > 0 else { return [] }
        let coast = coastEdges(of: polygons)
        let isCoast = Set(coast.map { PolygonEdge(polygon: $0.polygon, index: $0.index) })
        let toLight = Vec2.heading(light)
        var strips: [ReliefStrip] = []
        for edge in coast {
            let points = polygons[edge.polygon]
            let n = points.count
            let direction = (edge.b - edge.a).normalized
            guard direction != .zero else { continue }
            // Anticlockwise, so the land is on the left: inward is the left perpendicular.
            let inward = -direction.rightPerp
            let facing = (-inward).dot(toLight)
            guard abs(facing) > 1e-6 else { continue }
            let previous = PolygonEdge(polygon: edge.polygon, index: (edge.index - 1 + n) % n)
            let next = PolygonEdge(polygon: edge.polygon, index: (edge.index + 1) % n)
            let startMitre = isCoast.contains(previous)
                ? mitre(inward, inwardNormal(points, previous.index)) : inward
            let endMitre = isCoast.contains(next)
                ? mitre(inward, inwardNormal(points, next.index)) : inward
            let band = depth / Double(steps)
            for step in 0..<steps {
                let d0 = band * Double(step), d1 = band * Double(step + 1)
                let corners = [edge.a + startMitre * d0, edge.b + endMitre * d0,
                               edge.b + endMitre * d1, edge.a + startMitre * d1]
                let fade = 1 - Double(step) / Double(steps)
                strips.append(ReliefStrip(corners: corners, isLit: facing > 0, weight: abs(facing) * fade))
            }
        }
        return strips
    }

    private struct PolygonEdge: Hashable {
        var polygon: Int
        var index: Int
    }

    private static func inwardNormal(_ points: [Vec2], _ i: Int) -> Vec2 {
        -(points[(i + 1) % points.count] - points[i]).normalized.rightPerp
    }

    /// The offset direction at a corner between two edges with inward normals `n1` and `n2`: along their bisector,
    /// long enough that a band of depth d keeps depth d from both edges; at most 3 d, so a hairpin can't spike.
    private static func mitre(_ n1: Vec2, _ n2: Vec2) -> Vec2 {
        let sum = n1 + n2
        guard sum.length > 1e-6 else { return n1 }
        let bisector = sum.normalized
        let cosine = max(bisector.dot(n1), 1.0 / 3)
        return bisector / cosine
    }

    // MARK: - Shallows

    /// How strongly water `depth` metres deep takes the shallows tint: fully at 0 (and dry), none at `fraction` of
    /// the venue's deepest node (`maxDepth`) and deeper.
    static func shallowsWeight(depth: Double, maxDepth: Double, fraction: Double) -> Double {
        let limit = maxDepth * fraction
        guard limit > 0 else { return 0 }
        return 1 - (max(depth, 0) / limit).clamped(to: 0...1)
    }
}

/// Blending in OKLab (`RegattaCore.OKLab`): a blend of two colours of equal `L` keeps that `L`, so the shallows tint
/// changes hue only (#11).
nonisolated extension OKLab {
    init(_ token: PaletteToken) {
        self.init(rgb: token.rgb)
    }

    func mixed(with other: OKLab, _ t: Double) -> OKLab {
        OKLab(L: L + (other.L - L) * t, a: a + (other.a - a) * t, b: b + (other.b - b) * t)
    }

    /// Gamma-encoded sRGB components, 0…1, clipped to the gamut.
    var srgb: [Double] {
        let l = pow(L + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(L - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(L - 0.0894841775 * a - 1.2914855480 * b, 3)
        let linear = [4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                      -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                      -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s]
        return linear.map { c in
            let c = c.clamped(to: 0...1)
            return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
        }
    }

    /// `srgb` as 8-bit levels.
    var rgb8: [UInt8] { srgb.map { UInt8(($0 * 255).rounded()) } }
}

/// The shallows' colour at a depth (#11, #15): the water blended in OKLab towards `ChartPalette.shallowsTint` by
/// `ChartGeometry.shallowsWeight`. Both are the same lightness, so the tint changes hue, not lightness, and never
/// reads as a puff or a lull.
nonisolated enum ShallowsTint {
    static func colour(weight: Double) -> OKLab {
        OKLab(ChartPalette.water).mixed(with: OKLab(ChartPalette.shallowsTint), weight.clamped(to: 0...1))
    }
}
