import Foundation
import RegattaCore

/// The offline geometry check for a venue × conditions pairing (#12, #83): run over every shipped pairing
/// by the tests, never at race time. Venue files are checked for shape when they load
/// (docs/venue-file.md, *Validation*); this checks what a file alone can't show, over the courses races
/// derive from it.
///
/// At every seeded rotation of the mean direction (`rotationStep` apart, ±`WindSetup.meanDirectionSpread`):
/// - the longest course's race area is clear of land (#12: "the longest beat at the widest rotation, plus
///   its race area, stays clear of land"), and inside the pairing's geographic grid and the venue's
///   current grid, so no boat or puff meets a grid's edge;
/// - no land is within `markClearance` of a mark or a line end, on the longest or the shortest course;
/// - at a venue with current, the race area of both the longest and the shortest course holds channel
///   water and shallows (#11, #12: "The estuary's channel and shallows sit inside the race area").
public enum VenueOfflineCheck {
    /// Radians between the rotations checked.
    public static let rotationStep = deg2rad(0.5)
    /// Metres of water every mark and line end keeps from land.
    public static let markClearance = 50.0
    /// Channel water is at least this fraction of the venue's deepest node.
    public static let channelDepthFraction = 0.8
    /// Shallows are wet and at most this fraction of the venue's deepest node.
    public static let shallowsDepthFraction = 0.4
    /// Metres between the points sampled over a race area.
    public static let sampleSpacing = 10.0

    /// Everything the pairing gets wrong, one line each, at the first rotation it goes wrong; empty
    /// when it passes.
    public static func problems(_ pairingCase: VenuePairingCase) -> [String] {
        let venue = pairingCase.venue.content
        var problems: [String] = []
        func report(_ problem: String, _ rotation: Double) {
            let line = "\(pairingCase.name): \(problem), at \(Self.degrees(rotation))"
            if !problems.contains(where: { $0.hasPrefix("\(pairingCase.name): \(problem),") }) { problems.append(line) }
        }
        for rotation in VenuePairingCase.rotations(step: rotationStep) {
            let longest = pairingCase.longestCourse(rotation: rotation)
            let shortest = pairingCase.shortestCourse(rotation: rotation)
            for (index, polygon) in venue.land.enumerated() where longest.raceArea.overlaps(polygon) {
                report("land \(index) reaches into the race area", rotation)
            }
            let corners = longest.raceArea.corners
            if corners.contains(where: { pairingCase.pairing.geographicGrid.grid.cell(containing: $0) == nil }) {
                report("the geographic grid doesn't cover the race area", rotation)
            }
            for course in [longest, shortest] {
                for mark in course.obstacles {
                    for (index, polygon) in venue.land.enumerated() where polygon.distance(to: mark.position) < markClearance {
                        report("land \(index) is within \(Int(markClearance)) m of the \(mark.name)", rotation)
                    }
                }
            }
            if let current = venue.current {
                if corners.contains(where: { current.grid.cell(containing: $0) == nil }) {
                    report("the current grid doesn't cover the race area", rotation)
                }
                let field = CurrentField(current: current, tideStateAtGun: 0)
                for (course, which) in [(longest, "longest"), (shortest, "shortest")] {
                    let depths = course.raceArea.lattice(spacing: sampleSpacing)
                        .filter(course.isInRaceArea)
                        .map(field.depth(at:))
                    if !depths.contains(where: { $0 >= channelDepthFraction * current.maxDepth }) {
                        report("the \(which) course's race area has no channel water", rotation)
                    }
                    if !depths.contains(where: { $0 > 0 && $0 <= shallowsDepthFraction * current.maxDepth }) {
                        report("the \(which) course's race area has no shallows", rotation)
                    }
                }
            }
        }
        return problems
    }

    static func degrees(_ radians: Double) -> String {
        let tenths = (rad2deg(radians) * 10).rounded() / 10
        return "\(tenths == 0 ? 0 : tenths)°"
    }
}
