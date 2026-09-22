/// Boat speed as a fraction of wind speed, by true wind angle.
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
        var i = 1
        while i < anglesDegrees.count - 1 && anglesDegrees[i] < d { i += 1 }
        let a0 = anglesDegrees[i - 1], a1 = anglesDegrees[i]
        let t = ((d - a0) / (a1 - a0)).clamped(to: 0...1)
        return ratios[i - 1] + (ratios[i] - ratios[i - 1]) * t
    }

    public func targetSpeed(twa: Double, windSpeed: Double) -> Double {
        ratio(twa: twa) * windSpeed
    }
}
