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
        case .water, .camera, .boat: nil
        }
    }

    var slot: TuningSlot? {
        switch target {
        case .file(let slot, _): slot
        case .groove: .boatClass
        case .water, .camera, .boat: nil
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
                note: "What sailing in another boat's shadow costs, and how far it reaches (hull lengths). From skiff@3 (#263) the loss is off her speed, not the wind, and she slows to it at the shadow's own rate.",
                applies: .nextRace,
                sliders: [
                    TuningSlider(.boatClass, "/windShadow/lossCloseIn", "Loss close in", 0...0.9, step: 0.01),
                    TuningSlider(.boatClass, "/windShadow/stackingFloor", "Stacked cones floor", 0.1...1, step: 0.01),
                    TuningSlider(.boatClass, "/windShadow/slowingDownSeconds", "Slowing down in it", unit: " s", 0.5...10, step: 0.1),
                    TuningSlider(.boatClass, "/windShadow/coneLengthHullLengths", "Cone length", 1...20, step: 0.5),
                    TuningSlider(.boatClass, "/windShadow/coneWidthAtEndHullLengths", "Cone width at its end", 0.5...10, step: 0.1),
                ]),
            TuningGroup(
                id: "backwind", title: "Backwind",
                note: "The zone astern of a boat on her windward quarter that slows a boat she lee-bows (#298, from skiff@4): its loss at her stern, fading to nothing at its far edge, and how far astern it reaches (hull lengths).",
                applies: .nextRace,
                sliders: [
                    TuningSlider(.boatClass, "/windShadow/backwind/loss", "Loss at her stern", 0...0.6, step: 0.01),
                    TuningSlider(.boatClass, "/windShadow/backwind/innerLengthHullLengths", "Inner edge length", 0.25...4, step: 0.05),
                    TuningSlider(.boatClass, "/windShadow/backwind/lengthHullLengths", "Outer edge length", 0.5...4, step: 0.05),
                    TuningSlider(.boatClass, "/windShadow/backwind/widthHullLengths", "Width at her stern", 0.25...3, step: 0.05),
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
                note: "How the boat camera frames you (#224's framing; its auto zoom isn't built yet). Drawn only: never logged.",
                applies: .live,
                sliders: [
                    camera("lookAheadSeconds", "Look-ahead", \.lookAheadSeconds, 0...6, 0.25, unit: " s"),
                    camera("followRate", "Follow rate", \.followRate, 0.5...10, 0.25, unit: " /s"),
                    camera("defaultZoom", "Zoom", \.defaultZoom, 0.45...2.2, 0.05),
                    camera("courseMargin", "Course view margin", \.courseMargin, 1...2, 0.05),
                ]),
            TuningGroup(
                id: "boat", title: "Boat",
                note: "How boats heel, flutter and flog, and their wakes and shadow hatches (#117, #121, #220, #222). Drawn only: never logged.",
                applies: .live,
                sliders: [
                    // Past 1 still counts: heel is capped at 1 after the gain, so more heels her sooner and
                    // off the beam (`BoatStyle.heelScale`).
                    boat("heelScale", "Heel", \.heelScale, 0...2, 0.05),
                    boat("heelFullKnots", "Overpowered at", \.heelFullKnots, 8...30, 0.5, unit: " kn"),
                    boat("starvedFullLoss", "Starved flutter at", \.starvedFullLoss, 0.1...0.8, 0.05),
                    boat("flutterDegrees", "Flutter", \.flutterDegrees, 0...20, 0.5, unit: "°"),
                    boat("flogSeconds", "Roll-miss flog", \.flogSeconds, 0...4, 0.1, unit: " s"),
                    boat("ghostAlpha", "Ghost fade", \.ghostAlpha, 0.1...0.9, 0.05),
                    // #121: wakes, cones and backwind.
                    boat("wakeMaxHulls", "Wake length", \.wakeMaxHulls, 0...10, 0.25, unit: " hulls"),
                    boat("wakeSpreadDegrees", "Wake spread", \.wakeSpreadDegrees, 2...40, 1, unit: "°"),
                    boat("wakePressureFan", "Wake pressure fan", \.wakePressureFan, 0...3, 0.1),
                    boat("wakeAlpha", "Wake alpha", \.wakeAlpha, 0...1, 0.02),
                    boat("wakePlaningBoost", "Planing wake", \.wakePlaningBoost, 1...2.5, 0.05),
                    boat("wakeFlareGain", "Roll-hit flare", \.wakeFlareGain, 0...2, 0.1),
                    boat("coneAlpha", "Cone hatch", \.coneAlpha, 0...0.5, 0.01),
                    boat("backwindShare", "Backwind hatch", \.backwindShare, 0...1, 0.05),
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
