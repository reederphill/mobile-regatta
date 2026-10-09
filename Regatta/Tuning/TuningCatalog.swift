#if DEBUG
import Foundation
import RegattaCore

/// One of the three kinds of data file the tuning panel writes tuned copies of (#232).
enum TuningSlot: String, Codable, CaseIterable, Sendable {
    case boatClass, conditions, rulesConfiguration

    var title: String {
        switch self {
        case .boatClass: "Boat class"
        case .conditions: "Conditions"
        case .rulesConfiguration: "Rules"
        }
    }
}

/// A slider on the tuning panel: what it tunes, and the range and step it moves in, in the tuned value's own
/// units (a data file's knots, degrees, seconds and fractions; a render value's).
struct TuningSlider: Identifiable {
    enum Target {
        /// The number at a JSON Pointer in a data file.
        case file(TuningSlot, pointer: String)
        /// The best upwind angle of the boat class's polar column (`TunedCopy.upwindAngleSpeeds`), degrees.
        case groove(column: Int)
        /// A render value: app-side, live, never logged.
        case water(WritableKeyPath<WaterStyle, Double>)
        case camera(WritableKeyPath<CameraStyle, Double>)
        case boat(WritableKeyPath<BoatStyle, Double>)
        /// A hint threshold (#129): app-side, live, never logged.
        case hint(WritableKeyPath<HintTuning, Double>)
    }

    let id: String
    let title: String
    let unit: String
    let range: ClosedRange<Double>
    let step: Double
    let target: Target

    init(_ slot: TuningSlot, _ pointer: String, _ title: String, unit: String = "", _ range: ClosedRange<Double>, step: Double) {
        self.init(id: "\(slot.rawValue):\(pointer)", title: title, unit: unit, range: range, step: step,
                  target: .file(slot, pointer: pointer))
    }

    init(id: String, title: String, unit: String = "", range: ClosedRange<Double>, step: Double, target: Target) {
        self.id = id
        self.title = title
        self.unit = unit
        self.range = range
        self.step = step
        self.target = target
    }

    /// The key its value is kept under in its slot's values: the pointer, or `upwind:<column>` for a groove.
    var valueKey: String? {
        switch target {
        case .file(_, let pointer): pointer
        case .groove(let column): TuningSlider.grooveKey(column)
        case .water, .camera, .boat, .hint: nil
        }
    }

    var slot: TuningSlot? {
        switch target {
        case .file(let slot, _): slot
        case .groove: .boatClass
        case .water, .camera, .boat, .hint: nil
        }
    }

    static func grooveKey(_ column: Int) -> String { "upwind:\(column)" }

    /// The column a groove key names, or nil for a pointer.
    static func grooveColumn(_ key: String) -> Int? {
        key.hasPrefix("upwind:") ? Int(key.dropFirst("upwind:".count)) : nil
    }

    /// Decimal places its step needs.
    var decimals: Int {
        var places = 0
        var scaled = step
        while abs(scaled - scaled.rounded()) > 1e-9, places < 4 {
            scaled *= 10
            places += 1
        }
        return places
    }

    func format(_ value: Double) -> String {
        String(format: "%.\(decimals)f", value) + unit
    }
}

/// A group of sliders with one reset (#232): the sim's apply at the next race start, as tuned copies of their
/// files; the render values apply live.
struct TuningGroup: Identifiable {
    enum Applies {
        case nextRace, live, later
    }

    let id: String
    let title: String
    let note: String
    let applies: Applies
    let sliders: [TuningSlider]
    /// Rows for values later tickets bring: shown, not yet tunable.
    var later: [LaterValue] = []

    /// A value a later ticket brings, and which.
    struct LaterValue: Identifiable {
        let title: String
        let ticket: String
        var id: String { title }
    }
}

/// Every group, in the order the panel shows them: the conditions first, the values the #238 fun pass found the
/// fleet's skill gap most sensitive to, then the polar's grooves and the boat's handling, the race format, and
/// the render values.
enum TuningCatalog {
    /// `grooveColumns`: each driving polar column of the boat class being tuned, and its wind speed in knots.
    /// `fullSteeragePoint`: the index of its turn-rate curve's last point, from whose speed she turns at the top
    /// rate; nil if it has none.
    static func groups(grooveColumns: [(column: Int, knots: Double)], fullSteeragePoint: Int?) -> [TuningGroup] {
        [
            // Prototype (proto-tiller, never merged).
            TuningGroup(
                id: "steering", title: "Steering",
                note: "Prototype. Auto tiller 1: your autohelm holds her angle to the wind when you let go of the rudder (main's behaviour). 0: a centred rudder sails straight on and every shift is yours to steer; the tack/gybe tap still sails the turn and hands back on the new groove. Applies live.",
                applies: .live,
                sliders: [boat("autoTiller", "Auto tiller (1 on, 0 off)", \.autoTiller, 0...1, 1)]),
            TuningGroup(
                id: "conditions", title: "Conditions",
                note: "The wind's oscillation, puffs and pressure field (#221, #220, #286, #287, #288). Period, wobble, fan and lane bend decide how often the favoured tack changes; the pressure side and lanes, where the pressure is; the side tendency and lane spots, how much the venue's geography steers it; lane length, drift and weak share, how far lanes reach up the course and how many are lows; puff coverage and choices, how many puffs there are and how closely they keep to the pressure.",
                applies: .nextRace,
                sliders: [
                    TuningSlider(.conditions, "/shift/periodSeconds/min", "Period, shortest", unit: " s", 60...180, step: 5),
                    TuningSlider(.conditions, "/shift/periodSeconds/max", "Period, longest", unit: " s", 60...180, step: 5),
                    TuningSlider(.conditions, "/shift/amplitudeDegrees", "Amplitude", unit: "°", 0...25, step: 0.5),
                    TuningSlider(.conditions, "/shift/wobbleDegrees", "Wobble", unit: "°", 0...10, step: 0.5),
                    TuningSlider(.conditions, "/puffs/coverage", "Puff coverage", 0.02...0.5, step: 0.01),
                    TuningSlider(.conditions, "/puffs/fanDegrees", "Puff fan", unit: "°", 0...30, step: 0.5),
                    TuningSlider(.conditions, "/puffs/lullLoss/min", "Lull loss, least", 0...0.6, step: 0.01),
                    TuningSlider(.conditions, "/puffs/lullLoss/max", "Lull loss, most", 0...0.6, step: 0.01),
                    // The pressure field (#286), in schema-3 conditions (version 4 on): "Not in this file" before.
                    TuningSlider(.conditions, "/pressureField/side/strength", "Pressure side strength", 0...0.3, step: 0.01),
                    TuningSlider(.conditions, "/pressureField/side/persistenceSeconds", "Pressure side persistence", unit: " s",
                                 60...1200, step: 30),
                    TuningSlider(.conditions, "/pressureField/side/bendDegrees", "Pressure side bend", unit: "°", 0...10, step: 0.5),
                    TuningSlider(.conditions, "/pressureField/lanes/count", "Pressure lanes", 0...24, step: 0.5),
                    TuningSlider(.conditions, "/pressureField/lanes/strength/min", "Lane strength, least", 0...0.3, step: 0.01),
                    TuningSlider(.conditions, "/pressureField/lanes/strength/max", "Lane strength, most", 0...0.3, step: 0.01),
                    TuningSlider(.conditions, "/pressureField/lanes/widthMetres/min", "Lane width, narrowest", unit: " m",
                                 50...800, step: 10),
                    TuningSlider(.conditions, "/pressureField/lanes/widthMetres/max", "Lane width, widest", unit: " m",
                                 50...800, step: 10),
                    TuningSlider(.conditions, "/pressureField/lanes/lifetimeSeconds/min", "Lane life, shortest", unit: " s",
                                 30...600, step: 10),
                    TuningSlider(.conditions, "/pressureField/lanes/lifetimeSeconds/max", "Lane life, longest", unit: " s",
                                 30...600, step: 10),
                    TuningSlider(.conditions, "/pressureField/lanes/driftMetresPerSecond", "Lane drift", unit: " m/s", 0...2,
                                 step: 0.05),
                    TuningSlider(.conditions, "/pressureField/lanes/bendDegrees", "Lane edge bend", unit: "°", 0...20, step: 0.5),
                    // How much the venue's geography steers the pressure field (#287), in schema-4 conditions (version 5 on).
                    TuningSlider(.conditions, "/pressureField/side/tendencyScale/min", "Side tendency, weakest", -1...1,
                                 step: 0.05),
                    TuningSlider(.conditions, "/pressureField/side/tendencyScale/max", "Side tendency, strongest", 0...3,
                                 step: 0.05),
                    TuningSlider(.conditions, "/pressureField/lanes/spotShare", "Lanes at the venue's spots", 0...1, step: 0.05),
                    // Where puffs and lulls form in the pressure field (#288), in schema-5 conditions (version 6 on).
                    TuningSlider(.conditions, "/pressureField/puffChoices", "Puff choices", 1...8, step: 1),
                    // Finite lanes that drift down the wind and may weaken it, in schema-6 conditions (version 7 on).
                    TuningSlider(.conditions, "/pressureField/lanes/lengthMetres/min", "Lane length, shortest", unit: " m",
                                 100...1500, step: 20),
                    TuningSlider(.conditions, "/pressureField/lanes/lengthMetres/max", "Lane length, longest", unit: " m",
                                 100...1500, step: 20),
                    TuningSlider(.conditions, "/pressureField/lanes/alongDriftFraction/min", "Lane drift downwind, least",
                                 0...1, step: 0.05),
                    TuningSlider(.conditions, "/pressureField/lanes/alongDriftFraction/max", "Lane drift downwind, most",
                                 0...1, step: 0.05),
                    TuningSlider(.conditions, "/pressureField/lanes/weakShare", "Lanes that weaken the wind", 0...1, step: 0.05),
                ]),
            TuningGroup(
                id: "grooves", title: "Upwind grooves",
                note: "Each wind strength's best upwind angle, so pinching and footing pay. The polar's speeds are warped to put the groove there, keeping its VMG; the rows are 5–7° apart, so it lands within about 2° (shown under each).",
                applies: .nextRace,
                sliders: grooveColumns.map { column, knots in
                    TuningSlider(id: "groove:\(column)", title: "\(TuningSlider.knots(knots)) kn", unit: "°", range: 30...60, step: 0.5,
                                 target: .groove(column: column))
                }),
            TuningGroup(
                id: "autohelm", title: "Autohelm",
                note: "How hard it steers, how close to the groove it snaps, and how long the groove's wind is averaged.",
                applies: .nextRace,
                sliders: [
                    TuningSlider(.boatClass, "/steering/autohelm/gainRudderPerDegree", "Gain", unit: " /°", 0.01...0.5, step: 0.01),
                    TuningSlider(.boatClass, "/steering/autohelm/upwindSnapDegrees", "Upwind snap", unit: "°", 0...15, step: 0.5),
                    TuningSlider(.boatClass, "/steering/autohelm/downwindSnapDegrees", "Downwind snap", unit: "°", 0...20, step: 0.5),
                    TuningSlider(.boatClass, "/steering/autohelm/grooveWindAverageSeconds", "Groove wind average", unit: " s",
                                 0...120, step: 5),
                ]),
            TuningGroup(
                id: "handling", title: "Handling",
                note: "Momentum and turning (#220): how heavy the boat feels. Rudder drag and the speed she steers fully from decide what a tack costs: slower than that she turns slower, so she stays longer in the no-go.",
                applies: .nextRace,
                sliders: [
                    TuningSlider(.boatClass, "/momentum/speedingUpSeconds", "Speeding up", unit: " s", 0.5...10, step: 0.1),
                    TuningSlider(.boatClass, "/momentum/slowingDownSeconds", "Slowing down", unit: " s", 0.5...10, step: 0.1),
                    TuningSlider(.boatClass, "/momentum/noGoSeconds", "Stopping in the no-go", unit: " s", 0.5...10, step: 0.1),
                    TuningSlider(.boatClass, "/steering/topTurnRateDegreesPerSecond", "Top turn rate", unit: "°/s", 5...60, step: 1),
                    TuningSlider(.boatClass, "/steering/minTurnRateDegreesPerSecond", "Least turn rate", unit: "°/s", 1...30, step: 0.5),
                    TuningSlider(.boatClass, "/steering/rudderSlewPerSecond", "Rudder slew", unit: " /s", 1...20, step: 0.5),
                    TuningSlider(.boatClass, "/steering/rudderDragPerSecond", "Rudder drag", unit: " /s", 0...0.8, step: 0.005),
                ] + (fullSteeragePoint.map {
                    [TuningSlider(.boatClass, "/steering/turnRateCurve/\($0)/speedKnots", "Full steering from", unit: " kn",
                                  0.5...10, step: 0.5)]
                } ?? [])),
            TuningGroup(
                id: "shadow", title: "Wind shadow",
                note: "The turbulence ribbons a boat leaves (#377, from skiff@6): a point every few tenths of a second, drifting down her apparent wind and widening as it ages, joined into ribbons. A boat in one loses speed, not wind, at the shadow's own rate. Strength and widths at her and at the end of a point's life (hull lengths), how long a point lives (cone lengths over her apparent wind), how far apart two points still join, the speed below which she sheds none, and how long her shedding takes to build back after an ease or a tack, full at the sail angle below.",
                applies: .nextRace,
                sliders: [
                    TuningSlider(.boatClass, "/windShadow/ribbons/peakLoss", "Loss at its strongest", 0...0.9, step: 0.01),
                    TuningSlider(.boatClass, "/windShadow/stackingFloor", "Stacked ribbons floor", 0.1...1, step: 0.01),
                    TuningSlider(.boatClass, "/windShadow/slowingDownSeconds", "Slowing down in it", unit: " s", 0.5...10, step: 0.1),
                    TuningSlider(.boatClass, "/windShadow/coneLengthHullLengths", "Cone length", 1...20, step: 0.5),
                    TuningSlider(.boatClass, "/windShadow/ribbons/lifeConeLengths", "Point life", unit: " cones", 0.1...3, step: 0.05),
                    TuningSlider(.boatClass, "/windShadow/ribbons/emitSeconds", "Point every", unit: " s", 0.1...2, step: 0.05),
                    TuningSlider(.boatClass, "/windShadow/ribbons/startWidthHullLengths", "Width at her", 0.1...4, step: 0.05),
                    TuningSlider(.boatClass, "/windShadow/ribbons/endWidthHullLengths", "Width at its end", 0.5...12, step: 0.1),
                    TuningSlider(.boatClass, "/windShadow/ribbons/joinCapHullLengths", "Joins points within", 0.2...4, step: 0.05),
                    TuningSlider(.boatClass, "/windShadow/ribbons/stoppedKnots", "Sheds none below", unit: " kn", 0...3, step: 0.1),
                    TuningSlider(.boatClass, "/windShadow/ribbons/buildSeconds", "Builds back over", unit: " s", 0...6, step: 0.1),
                    TuningSlider(.boatClass, "/windShadow/ribbons/fullAngleDegrees", "Full at sail angle", unit: "°", 2...45, step: 0.5),
                ]),
            TuningGroup(
                id: "backwind", title: "Backwind",
                note: "The zone astern of a boat on her windward quarter (#298), from skiff@6 a header (#377): a boat in it has her wind turned towards her bow, stacked up to a cap, after a lag, with an optional lull. Cast only off a working sail, as hard as it works; it fades out on its old side over the fade time before building on the new one, and she casts none below the floor speed, building in over the span above it. Its shape: how far astern it reaches (hull lengths; its length scales with her speed, full size at the speed below), and the true wind angle from which she is running and casts none. From skiff@6 the header's zone is the upwash beside her sail instead: on her windward side from her mast (a share of her length back from her bow) past her stern to its length astern of her stern (hull lengths), a fan narrow at her mast and widening straight to its aft end (its widths out from her side at each, hull lengths), full at her side and fading to nothing at its width out, fading in at its mast end and from full at her stern to nothing at its aft end; it doesn't grow with her speed.",
                applies: .nextRace,
                sliders: [
                    TuningSlider(.boatClass, "/windShadow/header/degrees", "Header", unit: "°", 0...20, step: 0.5),
                    TuningSlider(.boatClass, "/windShadow/header/capDegrees", "Stacked header cap", unit: "°", 0...30, step: 0.5),
                    TuningSlider(.boatClass, "/windShadow/header/lullLoss", "Lull in it", 0...0.6, step: 0.01),
                    TuningSlider(.boatClass, "/windShadow/header/lagSeconds", "Header lag", unit: " s", 0...4, step: 0.1),
                    TuningSlider(.boatClass, "/windShadow/backwind/fadeSeconds", "Fades out over", unit: " s", 0...5, step: 0.1),
                    TuningSlider(.boatClass, "/windShadow/backwind/floorKnots", "None below", unit: " kn", 0...8, step: 0.1),
                    TuningSlider(.boatClass, "/windShadow/backwind/floorBuildKnots", "Builds in over", unit: " kn", 0...6, step: 0.1),
                    TuningSlider(.boatClass, "/windShadow/backwind/mastStationFromBow", "Mast back from bow", 0...0.9, step: 0.01),
                    TuningSlider(.boatClass, "/windShadow/backwind/upwashWidthAtMastHullLengths", "Width at her mast", 0...3, step: 0.05),
                    TuningSlider(.boatClass, "/windShadow/backwind/upwashWidthAftHullLengths", "Width at its aft end", 0.1...4, step: 0.05),
                    TuningSlider(.boatClass, "/windShadow/backwind/upwashEndFadeHullLengths", "Fades in at its mast over", 0...0.5, step: 0.01),
                    TuningSlider(.boatClass, "/windShadow/backwind/upwashAftHullLengths", "Runs on astern of her stern", 0.1...3, step: 0.05),
                    TuningSlider(.boatClass, "/windShadow/backwind/innerLengthHullLengths", "Short edge length", 0.25...4, step: 0.05),
                    TuningSlider(.boatClass, "/windShadow/backwind/lengthHullLengths", "Long edge length", 0.5...4, step: 0.05),
                    TuningSlider(.boatClass, "/windShadow/backwind/widthHullLengths", "Width at her stern", 0.25...3, step: 0.05),
                    TuningSlider(.boatClass, "/windShadow/backwind/runningFromDegrees", "Off running from", unit: "°", 60...180, step: 1),
                    TuningSlider(.boatClass, "/windShadow/backwind/runningFadeDegrees", "Off over", unit: "°", 0...60, step: 1),
                    TuningSlider(.boatClass, "/windShadow/backwind/speedScale/referenceKnots", "Full size at", unit: "kn", 2...16, step: 0.5),
                ]),
            TuningGroup(
                id: "rollTack", title: "Roll tack",
                note: "The second tap through a tack (#222, #263): within the window of the boom crossing it keeps back part of her speed loss until close-hauled; outside it, her speed takes the miss.",
                applies: .nextRace,
                sliders: [
                    TuningSlider(.boatClass, "/rollTack/windowSeconds", "Window", unit: " s", 0.05...1, step: 0.05),
                    TuningSlider(.boatClass, "/rollTack/hitLossFraction", "Loss on a hit", 0...1, step: 0.05),
                    TuningSlider(.boatClass, "/rollTack/missSpeedFactor", "Speed after a miss", 0.5...1, step: 0.01),
                ]),
            TuningGroup(
                id: "raceFormat", title: "Race format",
                note: "The race area's width (a fraction of the beat) and how widely the fleet starts (line lengths, #223).",
                applies: .nextRace,
                sliders: [
                    TuningSlider(.rulesConfiguration, "/raceFormat/raceArea/acrossAxisBeatFraction", "Race-area width",
                                 0.3...1.5, step: 0.05),
                    TuningSlider(.rulesConfiguration, "/raceFormat/startRow/spreadLineLengths", "Start-row spread", 0.5...3, step: 0.1),
                ]),
            TuningGroup(
                id: "water", title: "Water",
                note: "How the pressure, puffs, lulls and whitecaps draw (#116, #289). Drawn only: never logged.",
                applies: .live,
                sliders: [
                    water("fullTonePuffGain", "Puff at full tone", \.fullTonePuffGain, 0.05...0.6, 0.01),
                    water("fullToneLullLoss", "Lull at full tone", \.fullToneLullLoss, 0.05...0.5, 0.01),
                    water("catspaw", "Catspaw texture", \.catspaw, 0...1, 0.05),
                    water("fullTonePressureGain", "Pressure at full tone", \.fullTonePressureGain, 0.03...0.5, 0.01),
                    water("fullTonePressureLoss", "Low pressure at full tone", \.fullTonePressureLoss, 0.03...0.5, 0.01),
                    water("rippleAlpha", "Ripple strength", \.rippleAlpha, 0...1, 0.05),
                    water("whitecapOnsetKnots", "Whitecaps from", \.whitecapOnsetKnots, 0...25, 0.5, unit: " kn"),
                    water("whitecapFullKnots", "Whitecaps full at", \.whitecapFullKnots, 5...35, 0.5, unit: " kn"),
                    water("whitecapMaxShare", "Whitecap share", \.whitecapMaxShare, 0...1, 0.05),
                    water("whitecapAlpha", "Whitecap strength", \.whitecapAlpha, 0...1, 0.05),
                ]),
            TuningGroup(
                id: "camera", title: "Camera",
                note: "How the camera frames you (#113, #322): boat-up's lag, the heading lead, each shot's zoom and the "
                    + "thresholds, dwell and easing between them, the pre-start shot, the pinch-zoom limits, and the "
                    + "north-up fixture cameras. Drawn only: never logged.",
                applies: .live,
                sliders: [
                    camera("boatUpLagSeconds", "Boat-up lag", \.boatUpLagSeconds, 0.1...3, 0.1, unit: " s"),
                    camera("leadAlong", "Lead up the screen", \.leadAlong, 0...0.8, 0.05),
                    camera("leadAcross", "Lead across", \.leadAcross, 0...0.8, 0.05),
                    camera("leadDirectionSeconds", "Lead turn lag", \.leadDirectionSeconds, 0.1...6, 0.1, unit: " s"),
                    camera("leadUnsteadinessSeconds", "Turn-rate smoothing", \.leadUnsteadinessSeconds, 0.1...4, 0.1, unit: " s"),
                    camera("leadGoneTurnRate", "Lead gone at turn rate", \.leadGoneTurnRate, 5...120, 5, unit: "°/s"),
                    camera("openWaterZoom", "Open water zoom", \.openWaterZoom, 0.2...2.2, 0.05),
                    camera("markRoundingZoom", "Mark rounding zoom", \.markRoundingZoom, 0.2...2.2, 0.05),
                    camera("closeQuartersZoom", "Close quarters zoom", \.closeQuartersZoom, 0.2...3, 0.05),
                    camera("closeQuartersOnHullLengths", "Close quarters on within", \.closeQuartersOnHullLengths, 1...10, 0.5, unit: " L"),
                    camera("closeQuartersOnSeconds", "Close quarters on after", \.closeQuartersOnSeconds, 0...5, 0.25, unit: " s"),
                    camera("closeQuartersOffHullLengths", "Close quarters off beyond", \.closeQuartersOffHullLengths, 1...15, 0.5, unit: " L"),
                    camera("closeQuartersOffSeconds", "Close quarters off after", \.closeQuartersOffSeconds, 0...10, 0.25, unit: " s"),
                    camera("markRoundingZones", "Mark rounding within", \.markRoundingZones, 1...5, 0.25, unit: " zones"),
                    camera("shotDwellSeconds", "Shot dwell", \.shotDwellSeconds, 0...10, 0.5, unit: " s"),
                    camera("shotTransitionSeconds", "Shot transition", \.shotTransitionSeconds, 0.1...5, 0.1, unit: " s"),
                    camera("edgeMargin", "Mark and line kept inside", \.edgeMargin, 0.5...1, 0.05),
                    camera("preStartBoatHeight", "Pre-start boat height", \.preStartBoatHeight, 0.1...0.5, 0.05),
                    camera("preStartBoatWidth", "Pre-start boat width", \.preStartBoatWidth, 0.2...1, 0.05),
                    camera("preStartFlipLineLengths", "Pre-start flip over", \.preStartFlipLineLengths, 0.05...2, 0.05, unit: " lines"),
                    camera("preStartLeadSpeed", "Pre-start lead from speed", \.preStartLeadSpeed, 0.25...5, 0.25, unit: " m/s"),
                    camera("preStartLeadShare", "Pre-start lead strength", \.preStartLeadShare, 0...1, 0.05),
                    camera("preStartOffsetSeconds", "Pre-start boat easing", \.preStartOffsetSeconds, 0.1...5, 0.1, unit: " s"),
                    camera("gunHandOverSeconds", "Hand-over after the gun", \.gunHandOverSeconds, 0...10, 0.5, unit: " s"),
                    camera("minZoom", "Widest zoom", \.minZoom, 0.1...1, 0.05),
                    camera("maxZoom", "Closest zoom", \.maxZoom, 1...4, 0.1),
                    camera("followRate", "Follow rate (north-up)", \.followRate, 0.5...10, 0.25, unit: " /s"),
                    camera("lookAheadSeconds", "Look-ahead (north-up)", \.lookAheadSeconds, 0...6, 0.25, unit: " s"),
                    camera("defaultZoom", "Zoom (north-up)", \.defaultZoom, 0.45...2.2, 0.05),
                    camera("courseMargin", "Course view margin", \.courseMargin, 1...2, 0.05),
                ]),
            TuningGroup(
                id: "boat", title: "Boat",
                note: "How boats heel, flutter and flog, their wakes and shadow hatches, and the boat-side cues and rule cues (#117, #121, #122, #123, #220, #222). Drawn only: never logged.",
                applies: .live,
                sliders: [
                    // Past 1 still counts: heel is capped at 1 after the gain, so more heels her sooner and
                    // off the beam (`BoatStyle.heelScale`).
                    boat("heelScale", "Heel", \.heelScale, 0...2, 0.05),
                    boat("heelFullKnots", "Overpowered at", \.heelFullKnots, 8...30, 0.5, unit: " kn"),
                    boat("starvedFullLoss", "Starved flutter at", \.starvedFullLoss, 0.1...0.8, 0.05),
                    boat("flutterDegrees", "Flutter", \.flutterDegrees, 0...20, 0.5, unit: "°"),
                    boat("flogSeconds", "Roll-miss flog", \.flogSeconds, 0...4, 0.1, unit: " s"),
                    boat("rollRingAlpha", "Roll ring", \.rollRingAlpha, 0...1, 0.05),
                    boat("rollRingHulls", "Roll ring size", \.rollRingHulls, 0.5...3, 0.1, unit: " hulls"),
                    boat("rollRingSeconds", "Roll result shows", \.rollRingSeconds, 0.2...2, 0.1, unit: " s"),
                    boat("ghostAlpha", "Ghost fade", \.ghostAlpha, 0.1...0.9, 0.05),
                    // #121: wakes, cones and backwind.
                    boat("wakeMaxHulls", "Wake length", \.wakeMaxHulls, 0...10, 0.25, unit: " hulls"),
                    boat("wakeTrailSeconds", "Wake string length", \.wakeTrailSeconds, 0.5...8, 0.1, unit: " s"),
                    boat("wakeTrailWidth", "Wake string width", \.wakeTrailWidth, 0.5...4, 0.25, unit: " pt"),
                    boat("wakeSpreadDegrees", "Wake spread", \.wakeSpreadDegrees, 2...40, 1, unit: "°"),
                    boat("wakePressureFan", "Wake pressure fan", \.wakePressureFan, 0...3, 0.1),
                    boat("wakeAlpha", "Wake alpha", \.wakeAlpha, 0...1, 0.02),
                    boat("wakePlaningBoost", "Planing wake", \.wakePlaningBoost, 1...2.5, 0.05),
                    boat("wakeFlareGain", "Roll-hit flare", \.wakeFlareGain, 0...2, 0.1),
                    boat("coneAlpha", "Cone hatch", \.coneAlpha, 0...0.4, 0.01),
                    boat("backwindShare", "Backwind hatch", \.backwindShare, 0...6, 0.1),
                    boat("backwindFeather", "Backwind edge softness", \.backwindFeather, 0...8, 0.5, unit: " pt"),
                    boat("shadowFollowSeconds", "Shadow and backwind trail", \.shadowFollowSeconds, 0...4, 0.1, unit: " s"),
                    // #122: the boat-side cues.
                    boat("vaneLengthHulls", "Vane length", \.vaneLengthHulls, 0.5...2, 0.1, unit: " hulls"),
                    boat("vaneLockDegrees", "Vane locks within", \.vaneLockDegrees, 0...5, 0.25, unit: "°"),
                    boat("grooveCueDeadbandDegrees", "Pinch/foot shows past", \.grooveCueDeadbandDegrees, 0...5, 0.25,
                         unit: "°"),
                    boat("grooveCueFullDegrees", "Sail cue full at", \.grooveCueFullDegrees, 2...20, 0.5, unit: "°"),
                    boat("grooveCueReachDegrees", "Reach past groove", \.grooveCueReachDegrees, 5...40, 1, unit: "°"),
                    boat("pinchLuffDegrees", "Pinched luff lift", \.pinchLuffDegrees, 0...10, 0.5, unit: "°"),
                    boat("pinchFlatten", "Pinched flatten", \.pinchFlatten, 0...0.6, 0.05),
                    boat("footEaseDegrees", "Footed ease", \.footEaseDegrees, 0...15, 0.5, unit: "°"),
                    boat("footFullness", "Footed fullness", \.footFullness, 0...0.6, 0.05),
                    boat("laylineAlpha", "Layline alpha", \.laylineAlpha, 0.05...1, 0.05),
                    boat("ladderLineAlpha", "Ladder line alpha", \.ladderLineAlpha, 0.03...0.6, 0.01),
                    boat("ladderSpacingMetres", "Ladder spacing", \.ladderSpacingMetres, 25...300, 5, unit: " m"),
                    boat("edgeArrowInsetSide", "Edge arrow side inset", \.edgeArrowInsetSide, 0...80, 2, unit: " pt"),
                    boat("edgeArrowClearance", "Edge arrow HUD clearance", \.edgeArrowClearance, 0...60, 2, unit: " pt"),
                    // #123: the rule cues.
                    boat("glowRangeHulls", "Right-of-way glow starts", \.glowRangeHulls, 1...20, 0.5, unit: " hulls"),
                    boat("glowFullHulls", "Right-of-way glow full", \.glowFullHulls, 0.5...10, 0.5, unit: " hulls"),
                    boat("glowMaxAlpha", "Right-of-way glow alpha", \.glowMaxAlpha, 0.1...1, 0.05),
                    boat("rightOfWayGlowBlur", "Right-of-way glow blur", \.rightOfWayGlowBlur, 2...20, 1, unit: " pt"),
                    boat("ruleCallLineSeconds", "Rule-call line", \.ruleCallLineSeconds, 2...20, 0.5, unit: " s"),
                    boat("ruleCallFadeSeconds", "Rule-call line fade", \.ruleCallFadeSeconds, 0...5, 0.25, unit: " s"),
                    boat("penaltyArcRadiusHulls", "Penalty arc radius", \.penaltyArcRadiusHulls, 0.5...2, 0.1, unit: " hulls"),
                    boat("penaltyArcWidth", "Penalty arc width", \.penaltyArcWidth, 1...10, 0.5, unit: " pt"),
                    // #127: the serious thermal tier's far boats.
                    boat("farBoatHulls", "Far boat (thermal tier)", \.farBoatHulls, 2...30, 0.5, unit: " hulls"),
                ]),
            TuningGroup(
                id: "hints", title: "Hints",
                note: "When the hints fire (#129): letting go after this long steering, sooner in the first race; the wind-shift hint's turn and smoothing; how long a situation is off before its hint may show again.",
                applies: .live,
                sliders: [
                    hint("lettingGoSeconds", "Letting go after", \.lettingGoSeconds, 5...60, 1, unit: " s"),
                    hint("lettingGoFirstRaceSeconds", "Letting go, first race", \.lettingGoFirstRaceSeconds, 1...30, 0.5,
                         unit: " s"),
                    hint("shiftDegrees", "Shift hint past", \.shiftDegrees, 2...20, 0.5, unit: "°"),
                    hint("shiftSmoothingSeconds", "Shift smoothing", \.shiftSmoothingSeconds, 0...30, 1, unit: " s"),
                    hint("rearmSeconds", "Hint again after off", \.rearmSeconds, 1...30, 0.5, unit: " s"),
                ]),
            TuningGroup(
                id: "later", title: "Later",
                note: "Values later tickets bring, tuned here once they're in a file.",
                applies: .later, sliders: [],
                later: [.init(title: "Surge sizes", ticket: "#220"), .init(title: "Lift bonus", ticket: "#222"),
                        .init(title: "Timing windows", ticket: "#222")]),
        ]
    }

    /// The group whose panel carries the pressure overlay's toggle (#289).
    static let pressureOverlayGroup = "water"

    private static func water(_ name: String, _ title: String, _ path: WritableKeyPath<WaterStyle, Double>,
                              _ range: ClosedRange<Double>, _ step: Double, unit: String = "") -> TuningSlider {
        TuningSlider(id: "water.\(name)", title: title, unit: unit, range: range, step: step, target: .water(path))
    }

    private static func boat(_ name: String, _ title: String, _ path: WritableKeyPath<BoatStyle, Double>,
                             _ range: ClosedRange<Double>, _ step: Double, unit: String = "") -> TuningSlider {
        TuningSlider(id: "boat.\(name)", title: title, unit: unit, range: range, step: step, target: .boat(path))
    }

    private static func hint(_ name: String, _ title: String, _ path: WritableKeyPath<HintTuning, Double>,
                             _ range: ClosedRange<Double>, _ step: Double, unit: String = "") -> TuningSlider {
        TuningSlider(id: "hint.\(name)", title: title, unit: unit, range: range, step: step, target: .hint(path))
    }

    private static func camera(_ name: String, _ title: String, _ path: WritableKeyPath<CameraStyle, Double>,
                               _ range: ClosedRange<Double>, _ step: Double, unit: String = "") -> TuningSlider {
        TuningSlider(id: "camera.\(name)", title: title, unit: unit, range: range, step: step, target: .camera(path))
    }
}

extension TuningSlider {
    /// A wind speed as a column heading: whole knots without a point.
    static func knots(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
#endif
