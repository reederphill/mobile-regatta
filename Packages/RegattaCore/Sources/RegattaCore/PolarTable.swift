import Foundation

/// A boat class's polar: boat speed through the water by true wind angle (TWA) × true wind speed
/// (TWS), bilinear between the table's nodes. In code units: radians and m/s.
///
/// The best upwind and downwind angles and their VMG are derived from the table when it loads,
/// once per TWS column, never stored in the file (ADR 0004). Laylines, bots, course sizing and the
/// start use `bestUpwind(tws:)` and `bestDownwind(tws:)`.
public struct PolarTable: Sendable {
    /// Best VMG at one wind speed.
    public struct Optimum: Sendable, Equatable {
        /// True wind angle, radians, 0...π.
        public let twa: Double
        /// Boat speed at `twa`, m/s.
        public let speed: Double
        /// Speed made good straight upwind (upwind optimum) or straight downwind (downwind), m/s.
        public let vmg: Double
    }

    /// TWA rows, radians, ascending from 0 to π.
    public let twaAxis: [Double]
    /// TWS columns, m/s, ascending from 0. Wind above the last column sails like the last column.
    public let twsAxis: [Double]
    /// `speeds[column][row]`: boat speed in m/s at `twsAxis[column]`, `twaAxis[row]`.
    public let speeds: [[Double]]
    /// Best upwind and downwind VMG per TWS column, derived at load.
    public let upwindOptima: [Optimum]
    public let downwindOptima: [Optimum]
    /// How far past dead downwind the boat may sail by the lee before the boom crosses (a gybe),
    /// in radians, at the wind speeds in `byTheLeeLimitTWS` (m/s); linear between them, flat beyond.
    public let byTheLeeLimitTWS: [Double]
    public let byTheLeeLimits: [Double]
    /// Fraction of polar speed lost while sailing by the lee (0.02 = 2 % slower).
    public let byTheLeePenalty: Double

    public enum TableError: Error, Equatable, CustomStringConvertible {
        case invalid(String)
        public var description: String { switch self { case .invalid(let reason): reason } }
    }

    public init(
        twaAxis: [Double], twsAxis: [Double], speeds: [[Double]],
        byTheLeeLimitTWS: [Double], byTheLeeLimits: [Double], byTheLeePenalty: Double
    ) throws {
        func check(_ condition: Bool, _ reason: @autoclosure () -> String) throws {
            if !condition { throw TableError.invalid(reason()) }
        }
        try check(twaAxis.count >= 2 && twaAxis[0] == 0 && abs(twaAxis[twaAxis.count - 1] - .pi) < 1e-12,
                  "TWA rows must run from 0° to 180°")
        try check(Self.isStrictlyAscending(twaAxis), "TWA rows must be strictly ascending")
        try check(twsAxis.count >= 2 && twsAxis.first == 0, "TWS columns must start at 0 kn, with at least two")
        try check(Self.isStrictlyAscending(twsAxis), "TWS columns must be strictly ascending")
        try check(speeds.count == twsAxis.count, "one speed column per TWS")
        for (c, column) in speeds.enumerated() {
            try check(column.count == twaAxis.count, "TWS column \(c) needs one speed per TWA row")
            try check(column.allSatisfy { $0.isFinite && $0 >= 0 }, "TWS column \(c) has a negative or non-finite speed")
        }
        try check(!byTheLeeLimitTWS.isEmpty && byTheLeeLimitTWS.count == byTheLeeLimits.count,
                  "by-the-lee limit needs at least one point")
        try check(Self.isStrictlyAscending(byTheLeeLimitTWS), "by-the-lee limit points must be in ascending TWS")
        try check(byTheLeeLimits.allSatisfy { $0 >= 0 && $0 <= .pi / 2 }, "by-the-lee limits must be 0°...90°")
        try check(byTheLeePenalty >= 0 && byTheLeePenalty < 1, "by-the-lee penalty must be in 0..<1")

        self.twaAxis = twaAxis
        self.twsAxis = twsAxis
        self.speeds = speeds
        self.byTheLeeLimitTWS = byTheLeeLimitTWS
        self.byTheLeeLimits = byTheLeeLimits
        self.byTheLeePenalty = byTheLeePenalty
        upwindOptima = Self.optima(twaAxis: twaAxis, speeds: speeds, direction: 1)
        downwindOptima = Self.optima(twaAxis: twaAxis, speeds: speeds, direction: -1)
    }

    // MARK: - Queries

    /// Boat speed in m/s at true wind angle `twa` (radians; sign ignored, and angles past 180°
    /// mirror, so by the lee reads as the same angle on the other side, before `byTheLeePenalty`)
    /// and true wind speed `tws` (m/s; capped at the last column, 0 below 0).
    public func speed(twa: Double, tws: Double) -> Double {
        let (c, t) = axisSegment(twsAxis, tws)
        let a = Self.foldedTWA(twa)
        return Self.lerp(Self.columnSpeed(twaAxis, speeds[c - 1], a), Self.columnSpeed(twaAxis, speeds[c], a), t)
    }

    /// Best upwind VMG at `tws` (m/s). Exact at the table's columns; between them the angle is
    /// interpolated and the speed and VMG are read from the polar at that angle.
    public func bestUpwind(tws: Double) -> Optimum { optimum(upwindOptima, tws: tws, direction: 1) }

    /// Best downwind VMG at `tws` (m/s), as `bestUpwind(tws:)`.
    public func bestDownwind(tws: Double) -> Optimum { optimum(downwindOptima, tws: tws, direction: -1) }

    /// How far by the lee the boat may sail at `tws` (m/s) before she gybes, radians.
    public func byTheLeeLimit(tws: Double) -> Double {
        guard byTheLeeLimitTWS.count > 1 else { return byTheLeeLimits[0] }
        let (i, t) = axisSegment(byTheLeeLimitTWS, tws)
        return Self.lerp(byTheLeeLimits[i - 1], byTheLeeLimits[i], t)
    }

    private func optimum(_ optima: [Optimum], tws: Double, direction: Double) -> Optimum {
        let (c, t) = axisSegment(twsAxis, tws)
        let twa = Self.lerp(optima[c - 1].twa, optima[c].twa, t)
        let boatSpeed = speed(twa: twa, tws: tws)
        return Optimum(twa: twa, speed: boatSpeed, vmg: direction * boatSpeed * cos(twa))
    }

    // MARK: - Interpolation

    /// Exact at both ends: `t == 0` gives `a` and `t == 1` gives `b`, so table nodes read back as stored.
    static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { (1 - t) * a + t * b }

    /// |TWA| folded into 0...π. Angles already in range pass through untouched, so nodes stay exact.
    static func foldedTWA(_ twa: Double) -> Double {
        let a = abs(twa)
        return a <= .pi ? a : abs(wrapAngle(a))
    }

    static func columnSpeed(_ twaAxis: [Double], _ column: [Double], _ twa: Double) -> Double {
        let (i, t) = axisSegment(twaAxis, twa)
        return lerp(column[i - 1], column[i], t)
    }

    private static func isStrictlyAscending(_ values: [Double]) -> Bool {
        values.allSatisfy(\.isFinite) && zip(values, values.dropFirst()).allSatisfy { $0 < $1 }
    }

    // MARK: - Derived optima

    /// Best VMG per TWS column. `direction` is +1 for upwind, −1 for downwind.
    ///
    /// The optimum comes from the table's rows, as the research checked them: straight-line
    /// interpolation between two rows can bulge slightly past both (by a few hundredths of a knot of
    /// VMG just short of dead downwind), and that bulge is an artefact, not a better angle.
    ///
    /// Takes the best TWA row, then refines it with the vertex of the parabola through that row's
    /// VMG and its neighbours', keeping the refined angle only if the table's own speed there makes
    /// at least as much VMG as the row. At 0° and 180° the polar is symmetric, so the best row there
    /// is already the vertex. A column with no drive anywhere (0 kn) borrows the nearest driving
    /// column's angle, so a best angle is defined at every wind speed.
    static func optima(twaAxis: [Double], speeds: [[Double]], direction: Double) -> [Optimum] {
        let found: [Optimum?] = speeds.map { column in
            let vmg = zip(column, twaAxis).map { direction * $0 * cos($1) }
            var best = 0
            for r in vmg.indices where vmg[r] > vmg[best] { best = r }
            guard vmg[best] > 0 else { return nil }

            var twa = twaAxis[best]
            if best > 0 && best < twaAxis.count - 1 {
                // Parabola f(h) = vmg[best] + p·h + q·h² through the neighbours at h0 < 0 < h2.
                let h0 = twaAxis[best - 1] - twaAxis[best], d0 = vmg[best - 1] - vmg[best]
                let h2 = twaAxis[best + 1] - twaAxis[best], d2 = vmg[best + 1] - vmg[best]
                let q = (d0 / h0 - d2 / h2) / (h0 - h2)
                let p = d0 / h0 - q * h0
                if q < 0 {
                    let refined = twaAxis[best] + (-p / (2 * q)).clamped(to: h0...h2)
                    if direction * columnSpeed(twaAxis, column, refined) * cos(refined) >= vmg[best] { twa = refined }
                }
            }
            let boatSpeed = columnSpeed(twaAxis, column, twa)
            return Optimum(twa: twa, speed: boatSpeed, vmg: direction * boatSpeed * cos(twa))
        }
        return found.indices.map { c in
            if let optimum = found[c] { return optimum }
            let borrowed = nearestDriving(found, to: c)?.twa ?? (direction > 0 ? .pi / 4 : .pi)
            return Optimum(twa: borrowed, speed: 0, vmg: 0)
        }
    }

    private static func nearestDriving(_ found: [Optimum?], to c: Int) -> Optimum? {
        for distance in 1..<max(found.count, 1) {
            if c + distance < found.count, let optimum = found[c + distance] { return optimum }
            if c - distance >= 0, let optimum = found[c - distance] { return optimum }
        }
        return nil
    }
}
