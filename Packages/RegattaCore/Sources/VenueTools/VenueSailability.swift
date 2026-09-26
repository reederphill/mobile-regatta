import Foundation
import RegattaCore

/// The offline sailability check for a venue × conditions pairing (#11, #14, #83), in a lull of `lull` on
/// the conditions' lightest strength, at peak current (flood and ebb):
/// 1. somewhere across the beat, a close-hauled boat makes at least `minimumBestProgress` upwind over
///    the ground;
/// 2. nowhere in the race area is a close-hauled boat swept backwards over the ground.
///
/// Analytic, with no race sailed: a close-hauled boat at `p` makes the polar's best upwind VMG in the
/// local wind (the lulled strength times the geographic grid's speed factor there), plus the current along
/// the local upwind direction (the mean direction turned by the grid's bend there). Either tack makes the
/// same progress upwind: the current adds the same to both. "At peak current" is each point's own peak:
/// the tide state at which the channel term there is strongest, with the shallows' lead (`CurrentField`).
///
/// Checked at every seeded rotation of the mean direction (`rotationStep` apart), over the longest
/// course's race area (which holds every other course's at that rotation), sampled `sampleSpacing` apart.
/// The beat is the part of it between the start line and the windward mark.
public enum VenueSailability {
    /// The lull, as a fraction of the conditions' lightest strength (#14: "a 25% lull").
    public static let lull = 0.25
    /// Upwind progress over the ground somewhere across the beat, m/s (#14: "at least 1 kn").
    public static let minimumBestProgress = metresPerSecond(knots: 1)
    /// Radians between the rotations checked.
    public static let rotationStep = deg2rad(1)
    /// Metres between the points sampled over the race area.
    public static let sampleSpacing = 10.0

    public struct Report: Sendable, Equatable {
        /// The least upwind progress over the ground anywhere in the race area, over every rotation and
        /// tide peak, m/s; negative is swept backwards.
        public let worstProgress: Double
        /// Where, and at which rotation (radians) and tide peak (radians of tide state, nil without
        /// current), `worstProgress` was found.
        public let worstAt: Vec2
        public let worstRotation: Double
        public let worstTidePeak: Double?
        /// Over every rotation and tide peak, the least of the most upwind progress over the ground
        /// anywhere on the beat, m/s.
        public let bestProgressOnBeat: Double

        /// Neither boat swept backwards anywhere, and the beat always has somewhere making
        /// `minimumBestProgress`.
        public var passes: Bool { worstProgress > 0 && bestProgressOnBeat >= VenueSailability.minimumBestProgress }

        public var summary: String {
            let tide = worstTidePeak.map { $0 < .pi ? "peak flood" : "peak ebb" } ?? "no current"
            func kn(_ metresPerSecond: Double) -> String { String(format: "%.2f kn", knots(metresPerSecond: metresPerSecond)) }
            let at = String(format: "(%.0f, %.0f)", worstAt.x, worstAt.y)
            return "worst \(kn(worstProgress)) at \(at), rotation \(VenueOfflineCheck.degrees(worstRotation)), \(tide); "
                + "best on the beat \(kn(bestProgressOnBeat))"
        }
    }

    /// The lulled strength sailability is checked in, m/s, before the geographic grid's speed factor.
    public static func lulledStrength(_ pairingCase: VenuePairingCase) -> Double {
        pairingCase.conditions.content.strength.lowerBound * (1 - lull)
    }

    public static func report(_ pairingCase: VenuePairingCase) -> Report {
        let current = pairingCase.venue.content.current
        let tidePeaks: [Double?] = current == nil ? [nil] : [.pi / 2, 3 * .pi / 2]
        let strength = lulledStrength(pairingCase)
        var worst = (progress: Double.infinity, at: Vec2.zero, rotation: 0.0, peak: nil as Double?)
        var bestOnBeat = Double.infinity
        for rotation in VenuePairingCase.rotations(step: rotationStep) {
            let course = pairingCase.longestCourse(rotation: rotation)
            let anchor = pairingCase.pairing.startLineCentre
            let points = course.raceArea.lattice(spacing: sampleSpacing).filter(course.isInRaceArea)
            for peak in tidePeaks {
                var best = -Double.infinity
                for p in points {
                    let made = progress(at: p, axis: course.axis, strength: strength, pairingCase: pairingCase, tidePeak: peak)
                    if made < worst.progress { worst = (made, p, rotation, peak) }
                    let along = (p - anchor).dot(course.upwind)
                    if along >= 0, along <= course.beat { best = max(best, made) }
                }
                bestOnBeat = min(bestOnBeat, best)
            }
        }
        return Report(worstProgress: worst.progress, worstAt: worst.at, worstRotation: worst.rotation,
                      worstTidePeak: worst.peak, bestProgressOnBeat: bestOnBeat)
    }

    /// Upwind progress over the ground of a close-hauled boat at `p`, m/s, on a course up `axis`, in a
    /// wind of `strength` m/s before the geographic grid, at the local peak `tidePeak` (π/2 flood, 3π/2
    /// ebb; ignored without current).
    public static func progress(
        at p: Vec2, axis: Double, strength: Double, pairingCase: VenuePairingCase, tidePeak: Double?
    ) -> Double {
        let shift = pairingCase.pairing.geographicGrid.sample(p)
        let upwind = Vec2.heading(axis + shift.directionDelta)
        let vmg = pairingCase.boatClass.polar.bestUpwind(tws: strength * shift.speedFactor).vmg
        guard let current = pairingCase.venue.content.current, let tidePeak else { return vmg }
        let depth = CurrentField(current: current, tideStateAtGun: 0).depth(at: p)
        let field = CurrentField(current: current, tideStateAtGun: tidePeak - current.phaseLead(depth: depth))
        return vmg + field.sample(p, tick: 0).dot(upwind)
    }
}
