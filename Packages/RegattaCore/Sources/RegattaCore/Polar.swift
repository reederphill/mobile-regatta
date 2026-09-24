/// Boat speed as a fraction of wind speed, by true wind angle.
///
/// The prototype's one-dimensional model, still sailed by `Race`. The boat class file's
/// `PolarTable` (TWA × TWS) replaces it when #70 moves the race onto class values.
public struct Polar: Sendable {
    public let anglesDegrees: [Double]
    public let ratios: [Double]
    /// Best-VMG angles, in radians.
    public let upwindTWA: Double
    public let downwindTWA: Double

    /// A single-handed dinghy: nothing inside ~30°, fastest on a reach.
    public static let dinghy = Polar(
        anglesDegrees: [0, 30, 38, 45, 60, 75, 90, 110, 135, 150, 165, 180],
        ratios: [0, 0, 0.35, 0.55, 0.62, 0.66, 0.68, 0.68, 0.64, 0.58, 0.52, 0.50],
        upwindTWA: deg2rad(45),
        downwindTWA: deg2rad(155)
    )

    public func ratio(twa: Double) -> Double {
        let d = rad2deg(abs(twa)).clamped(to: 0...180)
        let (i, t) = axisSegment(anglesDegrees, d)
        return ratios[i - 1] + (ratios[i] - ratios[i - 1]) * t
    }

    public func targetSpeed(twa: Double, windSpeed: Double) -> Double {
        ratio(twa: twa) * windSpeed
    }
}

/// The segment `axis[upper - 1] ... axis[upper]` of an ascending axis (at least two entries) that
/// holds `x`, and how far along it `x` lies, clamped to 0...1. Past either end it's the end segment,
/// with `t` at 0 or 1. A value exactly on an interior node lands at `t == 1` of the segment below it.
func axisSegment(_ axis: [Double], _ x: Double) -> (upper: Int, t: Double) {
    var i = 1
    while i < axis.count - 1 && axis[i] < x { i += 1 }
    let a0 = axis[i - 1], a1 = axis[i]
    return (i, ((x - a0) / (a1 - a0)).clamped(to: 0...1))
}
