import Foundation

/// What the race's ambience follows (#22), all of it on screen: the ground wind the HUD reads (before shadow), your
/// boat's speed and whether her sail is eased. A struct so a later layer can add an input (#220's water hiss).
struct AmbienceInput: Equatable {
    var windKnots: Double
    var boatKnots: Double
    var isEasing: Bool
}

/// Each ambience layer's gain, 0…1. A layer with no entry is silent.
nonisolated struct AmbienceGains: Equatable, Sendable {
    var values: [AmbienceLayer: Double] = [:]

    static let silent = AmbienceGains()

    subscript(layer: AmbienceLayer) -> Double {
        get { values[layer] ?? 0 }
        set { values[layer] = newValue }
    }

    var isSilent: Bool { values.values.allSatisfy { $0 <= 0 } }

    /// Equal when every layer's gain is, a missing layer counting as silent.
    static func == (lhs: AmbienceGains, rhs: AmbienceGains) -> Bool {
        AmbienceLayer.allCases.allSatisfy { lhs[$0] == rhs[$0] }
    }
}

/// The race's ambience mix (#22): wind crossfaded light → medium → strong by the wind's strength, water slow → fast by
/// your speed, each crossfade constant-power, and the sail flogging while you ease. Every number is a guess for a
/// later fun pass to tune, here in one place.
enum AmbienceMix {
    /// The wind's light, medium and strong layers each sound alone at these knots, crossfading between.
    static let windLightKnots = 6.0
    static let windMediumKnots = 12.0
    static let windStrongKnots = 18.0
    /// The wind layers' summed level from a calm to `windStrongKnots` and up.
    static let windLevel = (calm: 0.3, strong: 0.8)
    /// The water's slow and fast layers each sound alone at these knots of boat speed.
    static let waterSlowKnots = 1.5
    static let waterFastKnots = 6.0
    /// The water's summed level from a stopped boat to `waterFastKnots` and up.
    static let waterLevel = (stopped: 0.1, fast: 0.7)
    /// The sail flog's gain while easing.
    static let flogGain = 0.6
    /// How long a layer takes to ramp from silent to full (`ramp`).
    static let rampSeconds = 0.4

    /// The gains `input` calls for.
    static func gains(for input: AmbienceInput) -> AmbienceGains {
        var out = AmbienceGains()
        let wind = max(0, input.windKnots)
        let windLevel = lerp(Self.windLevel.calm, Self.windLevel.strong, unit(wind / windStrongKnots))
        let lightToMedium = unit((wind - windLightKnots) / (windMediumKnots - windLightKnots))
        let mediumToStrong = unit((wind - windMediumKnots) / (windStrongKnots - windMediumKnots))
        if mediumToStrong > 0 {
            let (medium, strong) = constantPower(mediumToStrong)
            out[.windMedium] = windLevel * medium
            out[.windStrong] = windLevel * strong
        } else {
            let (light, medium) = constantPower(lightToMedium)
            out[.windLight] = windLevel * light
            out[.windMedium] = windLevel * medium
        }
        let speed = max(0, input.boatKnots)
        let waterLevel = lerp(Self.waterLevel.stopped, Self.waterLevel.fast, unit(speed / waterFastKnots))
        let (slow, fast) = constantPower(unit((speed - waterSlowKnots) / (waterFastKnots - waterSlowKnots)))
        out[.waterSlow] = waterLevel * slow
        out[.waterFast] = waterLevel * fast
        out[.sailFlog] = input.isEasing ? flogGain : 0
        return out
    }

    /// `current` moved towards `target` over `seconds`: each layer by at most `seconds / rampSeconds` of full scale.
    static func ramp(_ current: AmbienceGains, toward target: AmbienceGains, over seconds: Double) -> AmbienceGains {
        let step = max(0, seconds) / rampSeconds
        var out = AmbienceGains()
        for layer in AmbienceLayer.allCases {
            let from = current[layer], to = target[layer]
            out[layer] = from + min(max(to - from, -step), step)
        }
        return out
    }

    /// The two gains of a constant-power crossfade at `t` (0…1): their squares sum to 1.
    static func constantPower(_ t: Double) -> (Double, Double) {
        (cos(t * .pi / 2), sin(t * .pi / 2))
    }

    private static func unit(_ x: Double) -> Double { min(max(x, 0), 1) }
    private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
}
