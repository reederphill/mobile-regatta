/// The laylines to the mark a boat is sailing for (CONTEXT.md, "Layline"): the two tracks that arrive at
/// it at the polar's best angle to the wind there, one on each tack. Drawn from the wind at the mark only,
/// never from the current. The scene draws them (#15) and a bot sees them (`SeatView.laylines`), from this
/// one formula.
///
/// Upwind to the windward mark and downwind to the leeward gate's centre. The reach to the offset mark is
/// laid across the wind, so a boat fetches it: it has none, and nor has the finish.
public struct Laylines: Sendable, Equatable {
    /// Where they meet: the windward mark, or the gate's centre.
    public let mark: Vec2
    /// The groove they're sailed at: upwind to the windward mark, downwind to the gate.
    public let groove: Autohelm.Groove
    /// Where the wind at `mark` blows from, radians.
    public let windDirection: Double
    /// The polar's best angle to that wind, for its strength, radians.
    public let angle: Double

    /// The heading a boat on starboard tack arrives on (the wind over her starboard side).
    public var starboardHeading: Double { windDirection - angle }
    /// The heading a boat on port tack arrives on.
    public var portHeading: Double { windDirection + angle }

    /// The laylines to `leg`'s mark in `course`, at `polar`'s best angle in the ground wind `wind` gives at
    /// that mark, or nil for a leg with none, or where `wind` has no wind to give (a race without the key).
    public init?(for leg: CourseLayout.Leg, in course: CourseLayout, polar: PolarTable, wind: (Vec2) -> GroundWind?) {
        guard case .round(let index) = leg else { return nil }
        let groove: Autohelm.Groove
        switch index {
        case CourseLayout.windwardIndex: groove = .upwind
        case CourseLayout.gateIndex: groove = .downwind
        default: return nil
        }
        let mark = course.targetPosition(for: leg)
        guard let ground = wind(mark) else { return nil }
        self.mark = mark
        self.groove = groove
        windDirection = ground.direction
        angle = groove == .upwind ? polar.bestUpwind(tws: ground.speed).twa : polar.bestDownwind(tws: ground.speed).twa
    }
}

extension CourseLayout {
    /// The leg a boat with `status` on leg `legIndex` is sailing for: her leg while racing, the first before
    /// she has started (in the sequence, late or OCS), and the finish once she has stopped.
    public func legSailed(status: BoatStatus, legIndex: Int) -> Leg {
        switch status {
        case .racing: legs[legIndex]
        case .prestart, .ocs: legs[0]
        case .finished, .dsq: .finish
        }
    }
}
