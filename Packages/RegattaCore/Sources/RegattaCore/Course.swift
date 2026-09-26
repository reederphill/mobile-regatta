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
