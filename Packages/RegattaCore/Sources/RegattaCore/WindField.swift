import Foundation

/// The wind over the ground at one place and tick, before any boat's shadow (#79).
public struct GroundWind: Hashable, Sendable {
    /// Compass direction the wind blows from, radians in [−π, π).
    public let direction: Double
    /// Metres per second.
    public let speed: Double

    public init(direction: Double, speed: Double) {
        self.direction = direction
        self.speed = speed
    }
}

public enum WindFieldError: Error, Equatable, Sendable {
    /// Sampling needs key `window`, which the field doesn't hold. The field never extrapolates past its
    /// keys (ADR 0001): a caller without the key must get it, not guess.
    case missingKey(Int)
    /// `tick` is before the origin of the window grid.
    case beforeOrigin(tick: Int)
}

/// The race's true wind: a pure function of the public `WindSetup`, the window grid, the keys held,
/// the race clock and position (ADR 0001). A value: sampling never changes it, so samples can be taken
/// in any order, by any number of readers, and give the same answer every time.
///
/// The shift from the mean direction and the strength channel are fleet-wide: the same everywhere at a
/// tick. Propagating them across the course would need keys beyond the 30 s reveal lead (ADR 0001).
/// Position matters only through the puffs (#76) and the geographic grid (#77), neither of which is in yet.
public struct WindField: Hashable, Sendable {
    /// The knot at the origin, starting window 0: no shift, base strength, level. It stands in for a key
    /// −1 that doesn't exist. A race never samples window 0 (`WindWindows(startSequenceTicks:)`), so it
    /// never feels this knot.
    public static let firstKnot = (shift: WindKnot(value: 0, slope: 0), strength: WindKnot(value: 1, slope: 0))

    public let setup: WindSetup
    public let windows: WindWindows
    public private(set) var keys: WindKeyChain

    public init(setup: WindSetup, windows: WindWindows, keys: WindKeyChain = WindKeyChain()) {
        self.setup = setup
        self.windows = windows
        self.keys = keys
    }

    /// Adds a revealed key, replacing any held for its window.
    public mutating func add(_ key: WindKey) {
        keys.insert(key)
    }

    /// The ground wind at `p` at `tick`. Throws `missingKey(k)` if it needs a key the field doesn't hold:
    /// window k needs keys k − 1 and k.
    public func sample(_ p: Vec2, tick: Int) throws(WindFieldError) -> GroundWind {
        let c = try channels(atTick: tick)
        // The strength channel stays inside the forecast strength range (#10: the forecast is never
        // wrong); the generator caps its knots, and this catches any overshoot between them.
        let speed = (setup.baseStrength * c.strength).clamped(to: setup.conditions.strength)
        return GroundWind(direction: wrapAngle(setup.meanDirection + c.shift), speed: speed)
    }

    /// The fleet-wide shift from the mean direction at `tick`, radians, positive veering (clockwise).
    public func shift(atTick tick: Int) throws(WindFieldError) -> Double {
        try channels(atTick: tick).shift
    }

    /// Puffs and lulls alive at `tick`, for rendering and bots. Always empty until keyed puffs (#76).
    public func activePuffs(atTick tick: Int) -> [Puff] {
        []
    }

    // MARK: - Evaluation

    /// Both channels and their slopes, per second, at `tick`.
    func channels(atTick tick: Int) throws(WindFieldError) -> Channels {
        let k = windows.window(containing: tick)
        guard k >= 0 else { throw .beforeOrigin(tick: tick) }
        let fraction = Double(tick - windows.start(of: k)) / Double(WindWindows.ticksPerWindow)
        return try channels(window: k, fraction: fraction)
    }

    /// Both channels at `fraction` (0…1) of the way through `window`: a cubic Hermite curve from the knot in
    /// key `window − 1` (or `firstKnot`) to the knot in key `window`, plus the window's wobble on the shift.
    /// Fraction 1 gives the knot itself, as the start of the next window does.
    func channels(window k: Int, fraction s: Double) throws(WindFieldError) -> Channels {
        let from: (shift: WindKnot, strength: WindKnot)
        if k == 0 {
            from = Self.firstKnot
        } else {
            guard let previous = keys[k - 1] else { throw .missingKey(k - 1) }
            from = (previous.shift, previous.strength)
        }
        guard let key = keys[k] else { throw .missingKey(k) }
        let shift = Self.hermite(from.shift, key.shift, s)
        let wobble = Self.wobble(key.wobble, s)
        let strength = Self.hermite(from.strength, key.strength, s)
        return Channels(shift: shift.value + wobble.value, shiftSlope: shift.slope + wobble.slope,
                        strength: strength.value, strengthSlope: strength.slope)
    }

    struct Channels: Equatable {
        /// Radians, and radians per second.
        let shift: Double
        let shiftSlope: Double
        /// Factor of base strength, and per second.
        let strength: Double
        let strengthSlope: Double
    }

    /// Cubic Hermite from `a` to `b` over one window, at fraction `s`; the slope is per second. Written
    /// as `a` plus changes, so it gives `a` exactly at `s` = 0 and stays exactly level between equal,
    /// level knots.
    static func hermite(_ a: WindKnot, _ b: WindKnot, _ s: Double) -> (value: Double, slope: Double) {
        let h = WindWindows.seconds
        let s2 = s * s, s3 = s2 * s
        let rise = b.value - a.value
        let value = a.value + rise * (3 * s2 - 2 * s3) + h * (a.slope * (s3 - 2 * s2 + s) + b.slope * (s3 - s2))
        let perFraction = rise * (6 * s - 6 * s2) + h * (a.slope * (3 * s2 - 4 * s + 1) + b.slope * (3 * s2 - 2 * s))
        return (value, perFraction / h)
    }

    /// Peak of `2 sin²x cos x`, at `tan² x = 2`: the wiggle's shape divided by it peaks at 1.
    static let wigglePeak = 4 / (3 * 3.0.squareRoot())

    /// The wobble at fraction `s`, and its slope per second. Both shapes and their slopes are zero at
    /// `s` = 0 and 1, so the wobble never moves a knot or its slope.
    static func wobble(_ w: WindWobble, _ s: Double) -> (value: Double, slope: Double) {
        guard w != .none else { return (0, 0) }
        let x = Double.pi * s
        let sine = sin(x), cosine = cos(x)
        let hump = sine * sine
        let humpSlope = 2 * sine * cosine * .pi
        let wiggle = 2 * sine * sine * cosine / wigglePeak
        let wiggleSlope = 2 * (2 * sine * cosine * cosine - sine * sine * sine) * .pi / wigglePeak
        return (w.hump * hump + w.wiggle * wiggle, (w.hump * humpSlope + w.wiggle * wiggleSlope) / WindWindows.seconds)
    }
}

/// A patch of stronger (puff) or weaker (lull) breeze drifting down the course. Kept from the
/// prototype for keyed puffs (#76), which reuse its fade and falloff; none exist until then.
public struct Puff: Sendable {
    public var center: Vec2
    public var radius: Double
    /// Peak change in wind speed as a fraction; negative for a lull.
    public var strength: Double
    public var age: Double
    public var lifetime: Double

    /// Current strength, fading in and out over the puff's life.
    public var intensity: Double {
        strength * sin(.pi * (age / lifetime).clamped(to: 0...1))
    }

    func influence(at p: Vec2) -> Double {
        let d2 = (p - center).lengthSquared / (radius * radius)
        guard d2 < 1 else { return 0 }
        let f = 1 - d2
        return intensity * f * f
    }
}
