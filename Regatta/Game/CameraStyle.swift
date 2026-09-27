import Foundation

/// How the race camera frames the race, in one value: the boat camera's look-ahead, how fast it follows and its
/// zoom, and the course camera's margin. The debug tuning panel (#232) puts a slider on each, for #224's framing,
/// and `GameScene.cameraStyle` takes a new one live. App-side and never logged: nothing here reaches the
/// simulation. Every default is a placeholder until tuned there; #224's auto zoom (tight in traffic, wider when
/// alone) isn't built yet.
nonisolated struct CameraStyle: Codable, Equatable, Sendable {
    /// Seconds of your boat's velocity the boat camera centres ahead of her.
    var lookAheadSeconds = 2.0
    /// How fast the boat camera closes on that point: the share of the gap it closes in a second is
    /// 1 − e^−rate.
    var followRate = 3.0
    /// The boat camera's zoom until you pinch: 1 is a point per point, larger is closer.
    var defaultZoom = 0.8
    /// The course camera's view over the whole course, as a multiple of the course's extent.
    var courseMargin = 1.2

    /// The shipped placeholders.
    static let standard = CameraStyle()
}
