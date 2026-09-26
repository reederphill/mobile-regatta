import Foundation

/// A 2D vector in metres. x = east, y = north.
public typealias Vec2 = SIMD2<Double>

public extension SIMD2 where Scalar == Double {
    /// Unit vector for a compass heading in radians (0 = north, positive clockwise).
    static func heading(_ angle: Double) -> SIMD2<Double> { SIMD2(sin(angle), cos(angle)) }

    var length: Double { lengthSquared.squareRoot() }
    var lengthSquared: Double { x * x + y * y }

    var normalized: SIMD2<Double> {
        let l = length
        return l > 1e-12 ? self / l : .zero
    }

    func dot(_ other: SIMD2<Double>) -> Double { x * other.x + y * other.y }

    /// z of the 3D cross product: positive when `other` is counter-clockwise of `self`.
    func cross(_ other: SIMD2<Double>) -> Double { x * other.y - y * other.x }

    /// This vector rotated 90° clockwise — i.e. to starboard, if `self` is a heading.
    var rightPerp: SIMD2<Double> { SIMD2(y, -x) }

    /// Compass bearing of this vector in radians.
    var bearing: Double { atan2(x, y) }
}

/// Wraps an angle into [-π, π).
@inlinable public func wrapAngle(_ angle: Double) -> Double {
    var r = fmod(angle + .pi, 2 * .pi)
    if r < 0 { r += 2 * .pi }
    return r - .pi
}

@inlinable public func deg2rad(_ degrees: Double) -> Double { degrees * .pi / 180 }
@inlinable public func rad2deg(_ radians: Double) -> Double { radians * 180 / .pi }

/// Metres per second in one knot (1852 m per hour). Data files use knots; code uses m/s.
public let metresPerSecondPerKnot = 1852.0 / 3600.0

@inlinable public func metresPerSecond(knots: Double) -> Double { knots * metresPerSecondPerKnot }
@inlinable public func knots(metresPerSecond: Double) -> Double { metresPerSecond / metresPerSecondPerKnot }

public extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

public struct Segment: Sendable, Equatable {
    public var a: Vec2
    public var b: Vec2
    public init(_ a: Vec2, _ b: Vec2) { self.a = a; self.b = b }
}

/// Directed crossing of segment `s` (a→b) by something moving from `p0` to `p1`.
/// Returns +1 when it crosses to the left of a→b, -1 to the right, 0 for no crossing.
/// Half-open on the line itself so a crossing is never counted twice or missed.
public func crossing(from p0: Vec2, to p1: Vec2, over s: Segment) -> Int {
    let ab = s.b - s.a
    let side0 = ab.cross(p0 - s.a)
    let side1 = ab.cross(p1 - s.a)
    let direction: Int
    if side0 <= 0 && side1 > 0 {
        direction = 1
    } else if side0 > 0 && side1 <= 0 {
        direction = -1
    } else {
        return 0
    }
    let move = p1 - p0
    let e0 = move.cross(s.a - p0)
    let e1 = move.cross(s.b - p0)
    return e0 * e1 <= 0 ? direction : 0
}

public enum Collision {
    /// How a hull touches an obstruction: the move that clears it, and which way the obstruction faces.
    public struct Contact: Sendable, Equatable {
        /// The translation that moves the hull clear.
        public var push: Vec2
        /// Unit vector out of the obstruction, into the water.
        public var normal: Vec2

        public init(push: Vec2, normal: Vec2) {
            self.push = push
            self.normal = normal
        }

        public var depth: Double { push.length }
    }

    /// How the convex `hull` (either winding) reaches into `polygon`, a simple polygon that may be concave
    /// (`Venue.LandPolygon.points`), or nil if it doesn't. The deeper of two cases (#82):
    /// - a hull corner inside the polygon (even-odd), moved to the nearest point of its outline;
    /// - a polygon corner inside the hull, the hull moved off it back along the outward normal of its
    ///   nearest side.
    ///
    /// The deepest single corner decides, so a hull reaching into a corner of the polygon narrower than
    /// itself may still touch the other side after the push: `RaceEdges.resolve` makes several passes.
    public static func penetration(convex hull: [Vec2], simplePolygon polygon: [Vec2]) -> Contact? {
        var best: Contact?
        var bestDepth = 0.0
        for v in hull where contains(simplePolygon: polygon, v) {
            var nearest = v
            var distance = Double.infinity
            for i in polygon.indices {
                let q = closestPoint(on: Segment(polygon[i], polygon[(i + 1) % polygon.count]), to: v)
                let d = (q - v).length
                if d < distance {
                    distance = d
                    nearest = q
                }
            }
            if distance > bestDepth {
                bestDepth = distance
                best = Contact(push: nearest - v, normal: (nearest - v) / distance)
            }
        }
        // A clockwise hull's outward normals are its edges' left perpendiculars.
        let winding: Double = signedArea(hull) < 0 ? -1 : 1
        for p in polygon where contains(hull, p) {
            var distance = Double.infinity
            var outward = Vec2.zero
            for i in hull.indices {
                let n = (hull[(i + 1) % hull.count] - hull[i]).rightPerp.normalized * winding
                let d = (hull[i] - p).dot(n)
                if d < distance {
                    distance = d
                    outward = n
                }
            }
            if distance > bestDepth {
                bestDepth = distance
                best = Contact(push: -outward * distance, normal: -outward)
            }
        }
        return best
    }

    /// Whether `p` is inside the simple polygon `polygon` (even-odd rule; either winding). Points exactly
    /// on an edge may go either way.
    public static func contains(simplePolygon polygon: [Vec2], _ p: Vec2) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > p.y) != (b.y > p.y) {
                let x = a.x + (p.y - a.y) / (b.y - a.y) * (b.x - a.x)
                if p.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    /// Whether segments `s` and `t` meet, ends and collinear overlaps included.
    public static func intersects(_ s: Segment, _ t: Segment) -> Bool {
        let d1 = (s.b - s.a).cross(t.a - s.a), d2 = (s.b - s.a).cross(t.b - s.a)
        let d3 = (t.b - t.a).cross(s.a - t.a), d4 = (t.b - t.a).cross(s.b - t.a)
        if ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0)) { return true }
        func onSegment(_ p: Vec2, _ seg: Segment) -> Bool {
            min(seg.a.x, seg.b.x) <= p.x && p.x <= max(seg.a.x, seg.b.x)
                && min(seg.a.y, seg.b.y) <= p.y && p.y <= max(seg.a.y, seg.b.y)
        }
        return (d1 == 0 && onSegment(t.a, s)) || (d2 == 0 && onSegment(t.b, s))
            || (d3 == 0 && onSegment(s.a, t)) || (d4 == 0 && onSegment(s.b, t))
    }

    /// The polygon's signed area, positive when it winds anticlockwise.
    static func signedArea(_ polygon: [Vec2]) -> Double {
        var sum = 0.0
        for i in polygon.indices { sum += polygon[i].cross(polygon[(i + 1) % polygon.count]) }
        return sum / 2
    }

    /// Separating-axis test for two convex polygons. Returns the minimum translation
    /// that pushes `a` out of `b`, or nil if they don't overlap.
    public static func penetration(_ a: [Vec2], _ b: [Vec2]) -> Vec2? {
        var bestOverlap = Double.infinity
        var bestAxis = Vec2.zero
        for poly in [a, b] {
            for i in poly.indices {
                let edge = poly[(i + 1) % poly.count] - poly[i]
                let axis = Vec2(-edge.y, edge.x).normalized
                let (aMin, aMax) = project(a, on: axis)
                let (bMin, bMax) = project(b, on: axis)
                let overlap = min(aMax, bMax) - max(aMin, bMin)
                if overlap <= 0 { return nil }
                if overlap < bestOverlap {
                    bestOverlap = overlap
                    bestAxis = axis
                }
            }
        }
        if (centroid(a) - centroid(b)).dot(bestAxis) < 0 { bestAxis = -bestAxis }
        return bestAxis * bestOverlap
    }

    /// Translation that pushes a convex polygon out of a circle, or nil if they don't touch.
    public static func penetration(polygon: [Vec2], circle center: Vec2, radius: Double) -> Vec2? {
        var closest = polygon[0]
        var closestDistance = Double.infinity
        for i in polygon.indices {
            let q = closestPoint(on: Segment(polygon[i], polygon[(i + 1) % polygon.count]), to: center)
            let d = (q - center).length
            if d < closestDistance {
                closestDistance = d
                closest = q
            }
        }
        if contains(polygon, center) {
            // Circle centre is inside the hull: push the nearest edge past the circle.
            let direction = closestDistance > 1e-9 ? (center - closest) / closestDistance : Vec2(1, 0)
            return direction * (closestDistance + radius)
        }
        guard closestDistance < radius else { return nil }
        return (closest - center) / max(closestDistance, 1e-9) * (radius - closestDistance)
    }

    public static func contains(_ polygon: [Vec2], _ p: Vec2) -> Bool {
        var sign = 0.0
        for i in polygon.indices {
            let a = polygon[i]
            let b = polygon[(i + 1) % polygon.count]
            let c = (b - a).cross(p - a)
            if c == 0 { continue }
            if sign == 0 {
                sign = c
            } else if (c > 0) != (sign > 0) {
                return false
            }
        }
        return true
    }

    public static func closestPoint(on s: Segment, to p: Vec2) -> Vec2 {
        let ab = s.b - s.a
        let lengthSquared = ab.lengthSquared
        guard lengthSquared > 0 else { return s.a }
        let t = ((p - s.a).dot(ab) / lengthSquared).clamped(to: 0...1)
        return s.a + ab * t
    }

    static func project(_ polygon: [Vec2], on axis: Vec2) -> (Double, Double) {
        var lo = Double.infinity
        var hi = -Double.infinity
        for p in polygon {
            let d = p.dot(axis)
            lo = min(lo, d)
            hi = max(hi, d)
        }
        return (lo, hi)
    }

    static func centroid(_ polygon: [Vec2]) -> Vec2 {
        polygon.reduce(Vec2.zero, +) / Double(polygon.count)
    }
}
