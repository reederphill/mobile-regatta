import Foundation
import Testing
@testable import RegattaCore

/// The bundled class's polar, queried in knots and degrees.
@Suite struct PolarTableTests {
    let polar: PolarTable

    init() throws {
        polar = try Fixtures.boatClass().polar
    }

    /// Boat speed in knots at `twa` degrees and `tws` knots.
    func speed(_ twa: Double, _ tws: Double) -> Double {
        knots(metresPerSecond: polar.speed(twa: deg2rad(twa), tws: metresPerSecond(knots: tws)))
    }

    @Test func speedAtGridNodesEqualsTheTable() {
        #expect(polar.speed(twa: deg2rad(45), tws: metresPerSecond(knots: 12)) == metresPerSecond(knots: 5.3))
        #expect(polar.speed(twa: deg2rad(110), tws: metresPerSecond(knots: 20)) == metresPerSecond(knots: 12.6))
        #expect(polar.speed(twa: deg2rad(180), tws: metresPerSecond(knots: 6)) == metresPerSecond(knots: 4.1))
        #expect(polar.speed(twa: deg2rad(30), tws: metresPerSecond(knots: 8)) == metresPerSecond(knots: 3.0))
        for (c, tws) in polar.twsAxis.enumerated() {
            for (r, twa) in polar.twaAxis.enumerated() {
                #expect(polar.speed(twa: twa, tws: tws) == polar.speeds[c][r], "node \(rad2deg(twa))°, \(knots(metresPerSecond: tws)) kn")
                #expect(polar.speed(twa: -twa, tws: tws) == polar.speeds[c][r])
            }
        }
    }

    @Test func speedIsBilinearBetweenNodes() {
        // Midway between 40° and 45° and between 10 and 12 kn: the mean of 4.7, 5.1, 4.9 and 5.3.
        #expect(abs(speed(42.5, 11) - 5.0) < 1e-9)
        // A quarter of the way from 90° to 110° at 16 kn: 8.9 + (10.3 − 8.9) / 4.
        #expect(abs(speed(95, 16) - 9.25) < 1e-9)
    }

    @Test func windAbove25KnotsSailsLike25() {
        for twa in stride(from: 0.0, through: 180, by: 7.5) {
            #expect(speed(twa, 30) == speed(twa, 25))
            #expect(speed(twa, 60) == speed(twa, 25))
        }
    }

    @Test func noWindNoSpeed() {
        for twa in stride(from: 0.0, through: 180, by: 7.5) {
            #expect(speed(twa, 0) == 0)
            #expect(speed(twa, -1) == 0)
        }
    }

    /// As documented on `PolarTable`: NaN in, NaN out; infinite wind speed is clamped.
    @Test func nonFiniteInputsBehaveAsDocumented() {
        let w12 = metresPerSecond(knots: 12), w25 = metresPerSecond(knots: 25)
        #expect(polar.speed(twa: .nan, tws: w12).isNaN)
        #expect(polar.speed(twa: .infinity, tws: w12).isNaN)
        #expect(polar.speed(twa: -.infinity, tws: w12).isNaN)
        #expect(polar.speed(twa: deg2rad(45), tws: .nan).isNaN)
        #expect(polar.speed(twa: deg2rad(45), tws: .infinity) == polar.speed(twa: deg2rad(45), tws: w25))
        #expect(polar.speed(twa: deg2rad(45), tws: -.infinity) == 0)
        let nanUp = polar.bestUpwind(tws: .nan)
        #expect(nanUp.twa.isNaN && nanUp.speed.isNaN && nanUp.vmg.isNaN)
        #expect(polar.bestUpwind(tws: .infinity) == polar.bestUpwind(tws: w25))
        #expect(polar.bestDownwind(tws: .infinity) == polar.bestDownwind(tws: w25))
        #expect(polar.bestUpwind(tws: -.infinity) == polar.bestUpwind(tws: 0))
        #expect(polar.byTheLeeLimit(tws: .nan).isNaN)
        #expect(polar.byTheLeeLimit(tws: .infinity) == polar.byTheLeeLimit(tws: w25))
        #expect(polar.byTheLeeLimit(tws: -.infinity) == polar.byTheLeeLimit(tws: 0))
    }

    @Test func byTheLeeMirrorsDeadDownwind() {
        #expect(abs(speed(200, 12) - speed(160, 12)) < 1e-9)
        #expect(abs(speed(-200, 12) - speed(160, 12)) < 1e-9)
        #expect(abs(speed(350, 12) - speed(10, 12)) < 1e-9)
    }

    @Test(arguments: [
        (6.0, 2.62), (8.0, 3.29), (10.0, 3.62), (12.0, 3.75), (14.0, 3.79), (16.0, 3.83), (20.0, 3.91),
    ])
    func bestUpwindVMGMatchesTheResearch(tws: Double, vmg: Double) {
        let best = polar.bestUpwind(tws: metresPerSecond(knots: tws))
        #expect(abs(knots(metresPerSecond: best.vmg) - vmg) <= 0.05, "VMG \(knots(metresPerSecond: best.vmg)) kn")
        let angle = rad2deg(best.twa)
        #expect(angle >= 40 - 1e-9 && angle <= 45 + 1e-9, "best upwind TWA \(angle)°")
        #expect(abs(best.speed - polar.speed(twa: best.twa, tws: metresPerSecond(knots: tws))) < 1e-12)
        #expect(abs(best.vmg - best.speed * cos(best.twa)) < 1e-12)
    }

    @Test func bestDownwindIs165In6KnotsAnd180From8() {
        let light = polar.bestDownwind(tws: metresPerSecond(knots: 6))
        #expect(abs(rad2deg(light.twa) - 165) <= 2.5, "best downwind TWA \(rad2deg(light.twa))° at 6 kn")
        for tws in [8.0, 9, 10, 12, 14, 16, 20, 25, 30] {
            let best = polar.bestDownwind(tws: metresPerSecond(knots: tws))
            #expect(abs(rad2deg(best.twa) - 180) < 1e-9, "best downwind TWA \(rad2deg(best.twa))° at \(tws) kn")
            #expect(abs(best.vmg - best.speed) < 1e-12)
        }
    }

    /// The optima never lose to a table row. Between rows the straight-line interpolation can bulge
    /// a little past them (it puts dead downwind's best at 175–177° in a breeze), by under 0.05 kn.
    @Test func bestAnglesBeatEveryRowAndNearlyEveryAngle() {
        let tolerance = metresPerSecond(knots: 0.05)
        for (c, w) in polar.twsAxis.enumerated() {
            let up = polar.bestUpwind(tws: w), down = polar.bestDownwind(tws: w)
            for (r, twa) in polar.twaAxis.enumerated() {
                #expect(polar.speeds[c][r] * cos(twa) <= up.vmg + 1e-12, "upwind row \(rad2deg(twa))°, column \(c)")
                #expect(-polar.speeds[c][r] * cos(twa) <= down.vmg + 1e-12, "downwind row \(rad2deg(twa))°, column \(c)")
            }
            var bestUp = 0.0, bestDown = 0.0
            for tenths in 0...1800 {
                let twa = deg2rad(Double(tenths) / 10)
                let s = polar.speed(twa: twa, tws: w)
                bestUp = max(bestUp, s * cos(twa))
                bestDown = max(bestDown, -s * cos(twa))
            }
            #expect(bestUp <= up.vmg + tolerance && bestDown <= down.vmg + tolerance, "column \(c)")
        }
    }

    @Test func bestAnglesAreDefinedInNoWind() {
        let up = polar.bestUpwind(tws: 0), down = polar.bestDownwind(tws: 0)
        #expect(up.vmg == 0 && down.vmg == 0)
        #expect(up.twa == polar.upwindOptima[1].twa)
        #expect(down.twa == polar.downwindOptima[1].twa)
    }

    @Test func bestAnglesBetweenColumnsLieBetweenTheColumns() {
        let at10 = polar.bestUpwind(tws: metresPerSecond(knots: 10))
        let at12 = polar.bestUpwind(tws: metresPerSecond(knots: 12))
        let at11 = polar.bestUpwind(tws: metresPerSecond(knots: 11))
        #expect(at11.twa >= min(at10.twa, at12.twa) && at11.twa <= max(at10.twa, at12.twa))
        #expect(at11.vmg > at10.vmg && at11.vmg < at12.vmg)
    }

    @Test func upwindSpeedLevelsOffAndReachingSpeedJumps() {
        #expect(speed(45, 16) - speed(45, 12) <= 0.2)
        #expect(speed(110, 14) >= 1.1 * speed(110, 12))
    }

    /// #14: planing starts at about 12 kn on a reach and 13–14 kn on a run. The gain of the 1 kn step
    /// from `k` to `k + 1` kn is steepest for a step starting in 11–13 kn at 110° and 12–14 kn at 170°.
    /// Every step within 1e-9 kn of the steepest counts, so ties can't pass by rounding.
    @Test(arguments: [(110.0, 11.0...13.0), (170.0, 12.0...14.0)])
    func planingStepFallsWhereItShould(twa: Double, onset: ClosedRange<Double>) {
        let steps = (10..<16).map { k in (start: Double(k), gain: speed(twa, Double(k) + 1) - speed(twa, Double(k))) }
        let steepest = steps.map(\.gain).max()!
        let starts = steps.filter { $0.gain >= steepest - 1e-9 }.map(\.start)
        #expect(!starts.isEmpty && starts.allSatisfy { onset.contains($0) }, "steepest steps start at \(starts) kn")
    }
}
