import CoreGraphics
import Foundation

/// How the chart is drawn (#115): the race scene's static layer of race area, land, shallows, marks and the start
/// line. Sizes are metres unless they say points; stroke widths are screen points at any zoom (`ChartLayer`).
/// Render-only. No Debug sliders: none of these is a feel threshold (#232).
nonisolated struct ChartStyle: Sendable {
    // MARK: Race-area boundary

    /// The boundary's solid line, screen points. tuning: 1.5.
    var boundaryLineWidth: CGFloat = 1.5
    /// How far the hatched band reaches outside the boundary, metres. tuning: 30.
    var hatchWidth = 30.0
    /// Metres between the band's 45° hatch lines. tuning: 6.
    var hatchSpacing = 6.0
    /// The hatch lines, screen points. tuning: 1.
    var hatchLineWidth: CGFloat = 1
    /// The hatch's alpha over the water. tuning: 0.45.
    var hatchAlpha: CGFloat = 0.45

    // MARK: Land

    /// How far the relief reaches in from a coast, metres: enough to read with the whole course in view. tuning: 20.
    var reliefDepth = 20.0
    /// The relief's bands, coast first, each fainter than the one outside it. tuning: 3.
    var reliefSteps = 3
    /// The relief's strongest alpha, a coast facing straight to or from the light. tuning: 0.8.
    var reliefAlpha = 0.8
    /// Where the light comes from, a compass bearing: the north-west of a printed chart's hill shading. tuning: 315°.
    var lightBearing = 315.0 * .pi / 180
    /// A landmark silhouette's size, metres: big enough to read with the whole course in view. tuning: 40.
    var landmarkSize = 40.0

    // MARK: Shallows

    /// Water shallower than this fraction of the venue's deepest node is tinted, fully at depth 0. tuning: 0.5.
    var shallowFraction = 0.5

    // MARK: Marks

    /// A mark's zone, the start line, the gate's connector and the rounding arrow, screen points. tuning: 1.5.
    var cueLineWidth: CGFloat = 1.5
    /// The dashes of the zone, the start line and the gate's connector, world points. tuning: 10 on, 8 off.
    var dashes: [CGFloat] = [10, 8]
    /// The rounding arrow's radius, as a fraction of the zone's. tuning: 0.5.
    var arrowRadiusFraction = 0.5
    /// How far round the mark the rounding arrow sweeps, radians. tuning: 150°.
    var arrowSweep = 150.0 * .pi / 180
    /// The rounding arrow's head, metres from tip to each barb. tuning: 4.
    var arrowHead = 4.0
    /// A buoy's smallest drawn radius, world points, so a 1.2 m mark still shows when zoomed out. tuning: 5.
    var minimumBuoyRadius: CGFloat = 5
    /// The dark hairline round every buoy and the committee boat, screen points. tuning: 1.
    var markEdgeWidth: CGFloat = 1
    /// The committee boat's hull, metres. tuning: 4.6 by 5.2.
    var committeeHull = CGSize(width: 4.6, height: 5.2)

    /// A camera zoom change smaller than this fraction keeps the strokes' widths, so a slow zoom doesn't
    /// rebuild every stroke every frame. tuning: 5 %.
    var rescaleThreshold: CGFloat = 0.05

    static let standard = ChartStyle()
}
