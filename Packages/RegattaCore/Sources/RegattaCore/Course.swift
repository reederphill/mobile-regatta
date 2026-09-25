public enum MarkKind: Sendable {
    case windward
    case leeward
}

public struct Mark: Sendable {
    public let name: String
    public let position: Vec2
    public let radius: Double
    public let kind: MarkKind
}

public enum Leg: Sendable, Equatable {
    /// Round `marks[index]`, leaving it to port.
    case round(Int)
    /// Cross the start/finish line from the course side.
    case finish
}

/// Which side a boat leaves a mark on as she rounds it (rule 28).
public enum RoundingSide: Sendable, Equatable {
    case port
    case starboard
}

/// Two rays from mark position `m` that a boat approaching it along `approach` (a unit vector) crosses,
/// in order, as she rounds it leaving it to `side`. Each ray is oriented so the rounding crosses it
/// to its left (`crossing(from:to:over:) == 1`): the first reaches `length` square to `approach` on
/// the side she passes, the second `length` straight on past the mark, which she crosses as she turns.
public func roundingRays(around m: Vec2, approach: Vec2, side: RoundingSide, length: Double) -> [Segment] {
    switch side {
    case .port:
        [Segment(m, m + approach.rightPerp * length), Segment(m, m + approach * length)]
    case .starboard:
        [Segment(m - approach.rightPerp * length, m), Segment(m + approach * length, m)]
    }
}

/// Something a boat can hit that counts as a mark under Rule 31.
public struct Obstacle: Sendable {
    public let name: String
    public let position: Vec2
    public let radius: Double
}

/// A windward-leeward course. The start line doubles as the finish line.
public struct Course: Sendable {
    /// Compass bearing from the start line up to the windward mark.
    public let axis: Double
    /// Port (left) end of the start line.
    public let pin: Vec2
    /// Starboard (right) end of the start line.
    public let committee: Vec2
    public let marks: [Mark]
    public let legs: [Leg]
    public let pinRadius = 1.0
    public let committeeRadius = 2.5
    /// Rule 18 zone radius, metres: the rules configuration's zone in hull lengths of the boat class
    /// sailing it (`RulesConfig.zoneRadius(hullLength:)`, 3 L in `fleet-rules@1`).
    public let zoneRadius: Double
    /// How far the rounding gates extend from each mark.
    public static let gateLength = 250.0

    /// `zoneRadius`: the rule 18 zone, metres (`RulesConfig.zoneRadius(hullLength:)`).
    public init(axis: Double, pin: Vec2, committee: Vec2, marks: [Mark], legs: [Leg], zoneRadius: Double) {
        self.zoneRadius = zoneRadius
        self.axis = axis
        self.pin = pin
        self.committee = committee
        self.marks = marks
        self.legs = legs
    }

    /// `laps` windward roundings, with a leeward rounding between each, then a downwind finish.
    public static func standard(
        laps: Int = 2, beat: Double = 450, lineLength: Double = 160, axis: Double = 0, zoneRadius: Double
    ) -> Course {
        let up = Vec2.heading(axis)
        let right = up.rightPerp
        let marks = [
            Mark(name: "windward mark", position: up * beat, radius: 1.2, kind: .windward),
            Mark(name: "leeward mark", position: up * 70, radius: 1.2, kind: .leeward),
        ]
        let laps = max(1, laps)
        var legs: [Leg] = []
        for lap in 1...laps {
            legs.append(.round(0))
            if lap < laps { legs.append(.round(1)) }
        }
        legs.append(.finish)
        return Course(axis: axis, pin: -right * lineLength / 2, committee: right * lineLength / 2, marks: marks, legs: legs,
                      zoneRadius: zoneRadius)
    }

    public var upwind: Vec2 { .heading(axis) }
    public var right: Vec2 { upwind.rightPerp }
    public var lineCenter: Vec2 { (pin + committee) / 2 }
    public var startLine: Segment { Segment(pin, committee) }

    /// Signed distance from the start line (or its extensions). Positive = course side.
    public func lineSide(_ p: Vec2) -> Double {
        (committee - pin).normalized.cross(p - pin)
    }

    /// Two rays a boat must cross, in order and in the port-rounding direction, to round the mark.
    public func gates(forMark index: Int) -> [Segment] {
        let mark = marks[index]
        let approach = mark.kind == .windward ? upwind : -upwind
        return roundingRays(around: mark.position, approach: approach, side: .port, length: Course.gateLength)
    }

    public var obstacles: [Obstacle] {
        marks.map { Obstacle(name: $0.name, position: $0.position, radius: $0.radius) } + [
            Obstacle(name: "pin", position: pin, radius: pinRadius),
            Obstacle(name: "committee boat", position: committee, radius: committeeRadius),
        ]
    }

    public func targetPosition(for leg: Leg) -> Vec2 {
        switch leg {
        case .round(let index): marks[index].position
        case .finish: lineCenter
        }
    }

    public func name(of leg: Leg) -> String {
        switch leg {
        case .round(let index): marks[index].name
        case .finish: "finish line"
        }
    }
}
