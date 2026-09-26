import Foundation

/// The drawn boundary of the water a course's boats may sail in: a rectangle square to the course axis.
/// The race area itself is this rectangle less the venue's land in it (`CourseLayout.land`,
/// `CourseLayout.isInRaceArea(_:)`). `CourseLayout.derive` lays it out (#80), and the race attaches it
/// to its `WindSetup` (#81), where puffs spawn over the whole rectangle.
public struct RaceArea: Hashable, Sendable {
    /// Metres.
    public let centre: Vec2
    /// Compass bearing up the course, radians.
    public let axis: Double
    /// Metres from the centre to each side, across the axis.
    public let halfWidth: Double
    /// Metres from the centre to each end, along the axis.
    public let halfLength: Double

    public init(centre: Vec2, axis: Double, halfWidth: Double, halfLength: Double) {
        self.centre = centre
        self.axis = axis
        self.halfWidth = halfWidth
        self.halfLength = halfLength
    }

    /// The four corners, anticlockwise from the bottom left looking upwind.
    public var corners: [Vec2] {
        let up = Vec2.heading(axis) * halfLength
        let right = Vec2.heading(axis).rightPerp * halfWidth
        return [centre - right - up, centre + right - up, centre + right + up, centre - right + up]
    }

    /// Metres from `p` in to the nearest side: the least of its distances in from each side, so negative
    /// outside.
    public func inset(_ p: Vec2) -> Double {
        let offset = p - centre
        let up = Vec2.heading(axis)
        return min(halfWidth - abs(offset.dot(up.rightPerp)), halfLength - abs(offset.dot(up)))
    }

    /// Whether `p` is in the rectangle, its sides included. Land in it is `CourseLayout`'s.
    public func contains(_ p: Vec2) -> Bool { inset(p) >= 0 }

    /// Whether `polygon` and the rectangle share any point: a corner of either inside the other, or
    /// crossing edges.
    public func overlaps(_ polygon: Venue.LandPolygon) -> Bool {
        let corners = self.corners
        let points = polygon.points
        if points.contains(where: contains) || corners.contains(where: polygon.contains) { return true }
        for i in corners.indices {
            let side = Segment(corners[i], corners[(i + 1) % corners.count])
            for j in points.indices where Collision.intersects(side, Segment(points[j], points[(j + 1) % points.count])) {
                return true
            }
        }
        return false
    }

    /// How `hull` reaches past the sides, or nil if it is inside: each side it crosses pushes it back in,
    /// square to that side, by as far as its furthest corner reaches past it. `normal` is the push's
    /// direction, so in a corner it points between the two sides.
    public func penetration(of hull: [Vec2]) -> Collision.Contact? {
        let up = Vec2.heading(axis)
        let right = up.rightPerp
        var push = Vec2.zero
        for (outward, half) in [(up, halfLength), (-up, halfLength), (right, halfWidth), (-right, halfWidth)] {
            var reach = 0.0
            for v in hull { reach = max(reach, (v - centre).dot(outward) - half) }
            push -= outward * reach
        }
        guard push != .zero else { return nil }
        return Collision.Contact(push: push, normal: push.normalized)
    }
}

/// A boat touching the edges of the race area (#12, #82): its drawn boundary and the land in it, met the
/// same way. Pure: the race's step and anything that needs to know where a hull would end up (bots,
/// clients) call the same functions.
public enum RaceEdges {
    /// The most passes `resolve` makes over the boundary and the land.
    public static let maxPasses = 4
    /// A push sliding along the previous contact's surface is at most this many times its depth long:
    /// sides meeting more steeply than this are a slot, not a corner, and the push stays square.
    static let maxSlide = 4.0

    /// One kind of edge a hull touched.
    public struct Touch: Sendable, Equatable {
        public let kind: ObstructionKind
        /// Unit vector out of the edge, into the water: the direction of this kind's contacts' pushes
        /// added up, before any slide.
        public let normal: Vec2
    }

    public struct Resolution: Sendable, Equatable {
        /// The translation that clears the hull: every contact's push, added up.
        public let push: Vec2
        /// Each kind touched, in `ObstructionKind.allCases` order; empty if the hull was clear.
        public let touches: [Touch]
    }

    /// Moves `hull` out of the edges of the race area: back inside `area`'s sides, then out of each of
    /// `land` in order, repeated for up to `maxPasses` passes until nothing penetrates. Each contact is
    /// `RaceArea.penetration(of:)` or `Collision.penetration(convex:simplePolygon:)`, but when its push
    /// would drive the hull back into the previous contact, the hull slides along that contact's surface
    /// instead, as far as clears the new one: so a hull in a corner narrower than itself (a notch in the
    /// land, land meeting the boundary) comes straight out rather than creeping out one side at a time.
    public static func resolve(hull: [Vec2], area: RaceArea, land: [Venue.LandPolygon]) -> Resolution {
        let kinds = ObstructionKind.allCases
        var hull = hull
        var total = Vec2.zero
        var pushes = [Vec2](repeating: .zero, count: kinds.count)
        var firstNormals = [Vec2?](repeating: nil, count: kinds.count)
        var previous: Vec2?
        func apply(_ contact: Collision.Contact, _ kind: ObstructionKind) {
            let push = slide(contact.push, along: previous)
            previous = contact.normal
            for i in hull.indices { hull[i] += push }
            total += push
            let k = kinds.firstIndex(of: kind)!
            pushes[k] += contact.push
            if firstNormals[k] == nil { firstNormals[k] = contact.normal }
        }
        for _ in 0..<maxPasses {
            var clear = true
            if let contact = area.penetration(of: hull) {
                apply(contact, .boundary)
                clear = false
            }
            for polygon in land {
                if let contact = Collision.penetration(convex: hull, simplePolygon: polygon.points) {
                    apply(contact, .land)
                    clear = false
                }
            }
            if clear { break }
        }
        let touches = kinds.indices.compactMap { k -> Touch? in
            guard let first = firstNormals[k] else { return nil }
            // Opposite sides of a slot cancel out: fall back to the first side met.
            return Touch(kind: kinds[k], normal: pushes[k].length > 1e-9 ? pushes[k].normalized : first)
        }
        return Resolution(push: total, touches: touches)
    }

    /// `push`, turned to slide along the surface facing `previous` when it would drive the hull back into
    /// it: along that surface, as far as moves the hull `push`'s depth along `push`.
    static func slide(_ push: Vec2, along previous: Vec2?) -> Vec2 {
        guard let previous, push.dot(previous) < 0 else { return push }
        let depth = push.length
        var tangent = previous.rightPerp
        if tangent.dot(push) < 0 { tangent = -tangent }
        let cosine = tangent.dot(push) / depth
        guard cosine * maxSlide > 1 else { return push }
        return tangent * (depth / cosine)
    }

    /// A boat's speed after touching an edge that faces `normal`, from her speed `speed` going in. While
    /// she heads into it (`forward · normal < 0`) she keeps only her speed along it,
    /// `|forward · tangent| × speed`, and on the tick the touch begins only `retention` of that
    /// (`CourseLayout.edgeSpeedRetention`): bow on she stops, and held there she stays stopped. Heading
    /// along it or away she keeps her speed. Her heading, rudder and boom are never touched, so she can
    /// always steer away.
    public static func speed(_ speed: Double, forward: Vec2, normal: Vec2, begins: Bool, retention: Double) -> Double {
        guard forward.dot(normal) < 0 else { return speed }
        let along = abs(forward.dot(normal.rightPerp))
        return (begins ? retention : 1) * along * speed
    }
}
