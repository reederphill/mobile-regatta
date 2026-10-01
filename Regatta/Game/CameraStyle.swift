import Foundation

/// How the race camera frames the race, in one value (#113, #322): the boat-up lag, the heading lead, each shot's
/// zoom and the thresholds, dwell and easing between shots, the pre-start composition, the pinch-zoom limits, and
/// the north-up fixture cameras'. The debug tuning panel (#232) puts a slider on each, and `GameScene.cameraStyle`
/// takes a new one live. App-side and never logged: nothing here reaches the simulation. Every default is a
/// placeholder until tuned there.
nonisolated struct CameraStyle: Codable, Equatable, Sendable {
    /// Seconds of your boat's velocity the north-up follow camera (render fixtures) centres ahead of her.
    var lookAheadSeconds = 2.0
    /// How fast the north-up follow camera's centre closes on its target: the share of the gap it closes in a
    /// second is 1 − e^−rate.
    var followRate = 3.0
    /// The north-up follow camera's zoom (render fixtures): 1 is a point per point, larger is closer.
    var defaultZoom = 0.8
    /// The north-up course camera's view over the whole course (render fixtures), as a multiple of its extent.
    var courseMargin = 1.2

    // MARK: View heading (#13)

    /// Boat-up's lag behind your heading, seconds: the time constant τ of its ease, so a step in heading is 63 %
    /// turned after τ. A change of camera turns the same way.
    var boatUpLagSeconds = 1.0

    // MARK: Heading lead (#322)

    /// How far the centre leads your boat along screen-up when she heads up the screen: a share of half the
    /// screen's height, the same at every zoom and speed.
    var leadAlong = 0.35
    /// How far the centre leads your boat across the screen when she heads across it: a share of half its width.
    var leadAcross = 0.25
    /// The lead's direction follows your heading with this time constant τ, seconds, the short way round.
    var leadDirectionSeconds = 2.0
    /// The heading's rate of turn is smoothed over this many seconds to measure its unsteadiness.
    var leadUnsteadinessSeconds = 1.0
    /// A smoothed rate of turn, degrees a second, at which the lead is gone: it shrinks in proportion up to it.
    var leadGoneTurnRate = 40.0

    // MARK: Shots (#322)

    /// The open-water shot's zoom.
    var openWaterZoom = 0.7
    /// The mark-rounding shot's zoom, before it widens to keep the mark on screen.
    var markRoundingZoom = 0.9
    /// The close-quarters shot's zoom.
    var closeQuartersZoom = 1.6
    /// Close quarters comes on when a boat is within this many hull lengths of yours …
    var closeQuartersOnHullLengths = 4.0
    /// … for this many seconds.
    var closeQuartersOnSeconds = 1.0
    /// Close quarters goes off when no boat is within this many hull lengths …
    var closeQuartersOffHullLengths = 6.0
    /// … for this many seconds.
    var closeQuartersOffSeconds = 3.0
    /// Mark rounding comes on inside this many times the zone of the next mark.
    var markRoundingZones = 2.0
    /// A shot holds at least this many seconds before another replaces it, unless that one has higher precedence.
    var shotDwellSeconds = 4.0
    /// A change of shot eases its zoom over this many seconds.
    var shotTransitionSeconds = 1.5
    /// The share of the screen's half-width and half-height a mark (mark rounding) or a line end (pre-start) is kept
    /// inside.
    var edgeMargin = 0.9

    // MARK: Pre-start shot (#322)

    /// Your boat's height up the screen before the gun, below the line (above it, the composition flips).
    var preStartBoatHeight = 0.4
    /// The share of the screen's width, about its middle, your boat stays inside before the gun.
    var preStartBoatWidth = 0.7
    /// The flip from below the line to above it eases over this many line lengths either side of it.
    var preStartFlipLineLengths = 0.25
    /// Your boat's speed, m/s, at which the heading lead has taken the pre-start composition over from the line's
    /// (smoothly from rest), so a boat sailing keeps open water ahead of her bow.
    var preStartLeadSpeed = 1.5
    /// The share of the heading lead's strength before the gun: enough for open water ahead, not enough to swing the
    /// view while manoeuvring.
    var preStartLeadShare = 0.5
    /// Your boat's offset from the screen's centre eases to the pre-start composition's with this time constant,
    /// seconds, so crossing the line, a change of speed or a turn never slides her faster.
    var preStartOffsetSeconds = 1.5
    /// Seconds after the gun the pre-start shot hands over to the heading lead.
    var gunHandOverSeconds = 3.0

    // MARK: Pinch-zoom

    /// The widest the camera zooms out: 1 is a point per point. Raised to the zoom that fits the whole course
    /// when that is closer, so the widest view is never wider than the course.
    var minZoom = 0.35
    /// The closest the camera zooms in.
    var maxZoom = 2.2

    /// The shipped placeholders.
    static let standard = CameraStyle()
}

/// Lenient: a field missing from a saved style (one saved before the field existed) takes its standard value, and
/// a field it no longer has (#113's framing, the pinch hold) is ignored, so an older tuning keeps the rest of its
/// camera.
nonisolated extension CameraStyle {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var style = CameraStyle.standard
        func read(_ key: CodingKeys, _ path: WritableKeyPath<CameraStyle, Double>) throws {
            if let value = try c.decodeIfPresent(Double.self, forKey: key) { style[keyPath: path] = value }
        }
        try read(.lookAheadSeconds, \.lookAheadSeconds)
        try read(.followRate, \.followRate)
        try read(.defaultZoom, \.defaultZoom)
        try read(.courseMargin, \.courseMargin)
        try read(.boatUpLagSeconds, \.boatUpLagSeconds)
        try read(.leadAlong, \.leadAlong)
        try read(.leadAcross, \.leadAcross)
        try read(.leadDirectionSeconds, \.leadDirectionSeconds)
        try read(.leadUnsteadinessSeconds, \.leadUnsteadinessSeconds)
        try read(.leadGoneTurnRate, \.leadGoneTurnRate)
        try read(.openWaterZoom, \.openWaterZoom)
        try read(.markRoundingZoom, \.markRoundingZoom)
        try read(.closeQuartersZoom, \.closeQuartersZoom)
        try read(.closeQuartersOnHullLengths, \.closeQuartersOnHullLengths)
        try read(.closeQuartersOnSeconds, \.closeQuartersOnSeconds)
        try read(.closeQuartersOffHullLengths, \.closeQuartersOffHullLengths)
        try read(.closeQuartersOffSeconds, \.closeQuartersOffSeconds)
        try read(.markRoundingZones, \.markRoundingZones)
        try read(.shotDwellSeconds, \.shotDwellSeconds)
        try read(.shotTransitionSeconds, \.shotTransitionSeconds)
        try read(.edgeMargin, \.edgeMargin)
        try read(.preStartBoatHeight, \.preStartBoatHeight)
        try read(.preStartBoatWidth, \.preStartBoatWidth)
        try read(.preStartFlipLineLengths, \.preStartFlipLineLengths)
        try read(.preStartLeadSpeed, \.preStartLeadSpeed)
        try read(.preStartLeadShare, \.preStartLeadShare)
        try read(.preStartOffsetSeconds, \.preStartOffsetSeconds)
        try read(.gunHandOverSeconds, \.gunHandOverSeconds)
        try read(.minZoom, \.minZoom)
        try read(.maxZoom, \.maxZoom)
        self = style
    }
}
