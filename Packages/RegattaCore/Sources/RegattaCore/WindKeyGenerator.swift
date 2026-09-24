import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum WindKeyGeneratorError: Error, Equatable, Sendable {
    /// The conditions file predates the keyed wind (schema 1), so it has no wobble or ramp tuning.
    case conditionsPredateKeyedWind(FileRef)
}

/// Makes a race's wind key chain from its secret wind seed (ADR 0001, #18). Runs where the seed is
/// held: on the race server, or on the device for a practice race. Clients online get only the keys.
///
/// **Key material.** Every number key k draws comes from `material(windSeed:window:)`,
/// HMAC-SHA256 keyed by the wind seed over the window index. HMAC is one-way, so revealed keys never
/// give away the seed or any other key's material; a SplitMix64 of the seed would (it is invertible).
/// The 32 bytes are read as sixteen big-endian 16-bit lanes, and each draw reads its own lane, so what
/// one draw reveals says nothing about another. A lane `n` maps to `n / 65535` in [0, 1]:
///
/// | Lanes | Draw |
/// |---|---|
/// | 0–3 | `puffSeed`, the first 8 bytes as a big-endian UInt64 |
/// | 4 | this window's oscillator period, uniform in `shift.period` |
/// | 5, 6 | this window's wobble: hump and wiggle, each uniform in ±`wobble` / 2 |
/// | 7 | key 0 only: the oscillator's phase at the origin, uniform in [0, 2π] |
/// | 8, 9, 10 | key 0 only: the trend's size, longest duration and start |
/// | 11, 12, 13 | key 0 only: the build's size, longest duration and start |
/// | 14, 15 | this window's pace of the trend and of the build, each uniform in 1…2 |
///
/// **Knots.** The shift at the knot ending window k is `amplitude · sin φₖ` plus the trend, with
/// `φₖ = φₖ₋₁ + 2π · 30 s / Pₖ` and `Pₖ` window k's period; its slope is `amplitude · (2π / Pₖ) · cos φₖ`
/// plus the trend's. The strength channel is 1 plus the build. The phase and the trend and build so far
/// are the only state carried between windows, and each follows from keys 0…k alone.
///
/// **Trend and build** (`Ramp`). Each is a keyed ramp toward its drawn size: the trend toward
/// `WindSetup.trend`, the build upward, capped so the wind never passes the top of the forecast strength
/// range (#75: the forecast is never wrong). Key 0 draws the size, a longest duration (the drawn fraction
/// of the span) and a start, placed so the longest duration ends at the last knot within the span
/// (`trend.duration` or `buildDuration` seconds from the gun). From the start, each window adds its
/// pace × size × 30 s / longest duration, so the ramp finishes somewhere between half and all of the
/// longest duration after its start, at a rate each window's key draws. Its net change over the span is
/// exactly the drawn size, and before its start it is zero. Its knots' slopes are eased where it starts or
/// finishes part-way through a window, so between knots it never turns back or overshoots.
///
/// The generator is sequential: `next()` makes key `nextWindow` and moves on.
public struct WindKeyGenerator: Sendable {
    public let setup: WindSetup
    public let windows: WindWindows
    /// The window whose key `next()` makes.
    public private(set) var nextWindow = 0

    private let windSeed: WindSeed
    private let amplitude: Double
    private let period: ClosedRange<Double>
    private let wobble: Double
    private var trend: Ramp?
    private var build: Ramp?
    /// Oscillator phase at the knot ending window `nextWindow − 1` (at the origin for window 0), in [0, 2π).
    private var phase: Double

    public init(windSeed: WindSeed, setup: WindSetup, windows: WindWindows) throws(WindKeyGeneratorError) {
        let c = setup.conditions
        guard let keyed = c.keyedWind else { throw .conditionsPredateKeyedWind(setup.conditionsRef) }
        self.windSeed = windSeed
        self.setup = setup
        self.windows = windows
        amplitude = c.shift.amplitude
        period = c.shift.period
        wobble = keyed.wobble

        // Race-long draws come from key 0's material, each in its own lane.
        let first = Lanes(Self.material(windSeed: windSeed, window: 0))
        phase = (2 * .pi * first.unit(7)).truncatingRemainder(dividingBy: 2 * .pi)
        if let t = c.trend, let direction = setup.trend, let ramp = keyed.trendRamp {
            trend = Ramp(size: direction.sign * lerp(t.size, first.unit(8)), spanEnd: Self.lastKnot(within: t.duration, windows),
                         fraction: lerp(ramp, first.unit(9)), start: first.unit(10))
        }
        if let b = c.build, let span = keyed.buildDuration, let ramp = keyed.buildRamp {
            // Cap the rise so base × (1 + rise) never passes the top of the strength range.
            let headroom = max(0, c.strength.upperBound / setup.baseStrength - 1)
            build = Ramp(size: min(lerp(b.fraction, first.unit(11)), headroom), spanEnd: Self.lastKnot(within: span, windows),
                         fraction: lerp(ramp, first.unit(12)), start: first.unit(13))
        }
    }

    /// Key material for `window`: HMAC-SHA256 with the wind seed's 8 bytes, big-endian, as the key and
    /// the window index's 8 bytes, big-endian, as the message.
    public static func material(windSeed: WindSeed, window: Int) -> [UInt8] {
        precondition(window >= 0, "window keys start at window 0")
        let key = SymmetricKey(data: bigEndianBytes(windSeed.value))
        return Array(HMAC<SHA256>.authenticationCode(for: bigEndianBytes(UInt64(window)), using: key))
    }

    /// Makes the key for `nextWindow` and moves on to the next window.
    public mutating func next() -> WindKey {
        nextParts().key
    }

    /// Makes keys up to and including `window` (none if it already has), and returns them.
    public mutating func keys(through window: Int) -> [WindKey] {
        var made: [WindKey] = []
        while nextWindow <= window { made.append(next()) }
        return made
    }

    /// A key and the parts its knots are the sum of.
    struct Parts {
        let key: WindKey
        /// The oscillator's part of the shift knot.
        let oscillation: WindKnot
        /// The trend's part of the shift knot; zero with no trend.
        let trend: WindKnot
        /// The build's part of the strength knot, above 1; zero with no build.
        let build: WindKnot
    }

    mutating func nextParts() -> Parts {
        let k = nextWindow
        let lanes = Lanes(Self.material(windSeed: windSeed, window: k))
        let omega = 2 * .pi / lerp(period, lanes.unit(4))
        phase = (phase + omega * WindWindows.seconds).truncatingRemainder(dividingBy: 2 * .pi)
        let oscillation = WindKnot(value: amplitude * sin(phase), slope: amplitude * omega * cos(phase))
        // Seconds from the gun to the knot ending window k.
        let t = Double(windows.knotTick(of: k)) / Double(Race.tickRate)
        let trendKnot = trend?.advance(to: t, pace: 1 + lanes.unit(14)) ?? WindKnot(value: 0, slope: 0)
        let buildKnot = build?.advance(to: t, pace: 1 + lanes.unit(15)) ?? WindKnot(value: 0, slope: 0)
        nextWindow += 1
        let key = WindKey(
            window: k,
            shift: WindKnot(value: oscillation.value + trendKnot.value, slope: oscillation.slope + trendKnot.slope),
            strength: WindKnot(value: 1 + buildKnot.value, slope: buildKnot.slope),
            wobble: WindWobble(hump: wobble / 2 * (2 * lanes.unit(5) - 1), wiggle: wobble / 2 * (2 * lanes.unit(6) - 1)),
            puffSeed: lanes.puffSeed
        )
        return Parts(key: key, oscillation: oscillation, trend: trendKnot, build: buildKnot)
    }

    /// Seconds from the gun to the last knot within `span` seconds of it, or to the first knot after the
    /// gun if the span is shorter than that.
    static func lastKnot(within span: Double, _ windows: WindWindows) -> Double {
        let rate = Double(Race.tickRate)
        let last = windows.start(of: windows.window(containing: Int((span * rate).rounded(.down))))
        let first = windows.start(of: windows.window(containing: 0) + 1)
        return Double(max(last, first)) / rate
    }
}

/// A persistent change toward `size`, made window by window at a keyed pace (see `WindKeyGenerator`).
private struct Ramp: Sendable {
    let size: Double
    /// Seconds from the gun.
    let onset: Double
    /// The longest the change can take, seconds.
    let duration: Double
    /// So far, as of the last knot.
    private var reached = 0.0
    private var finished = false

    /// A ramp whose longest duration is `fraction` of `spanEnd` seconds, starting `start` (0…1) of the way
    /// through the time left before `spanEnd`, so it always finishes by then.
    init(size: Double, spanEnd: Double, fraction: Double, start: Double) {
        self.size = size
        duration = spanEnd * fraction
        onset = (spanEnd - duration) * start
    }

    /// The ramp's knot at `t` seconds from the gun, the end of the window after the last knot, with that
    /// window's `pace` (1…2).
    mutating func advance(to t: Double, pace: Double) -> WindKnot {
        guard !finished else { return WindKnot(value: size, slope: 0) }
        let h = WindWindows.seconds
        let active = ((t - onset) / h).clamped(to: 0...1) // the part of this window after the onset
        guard active > 0 else { return WindKnot(value: 0, slope: 0) }
        let rate = size * pace / duration
        let next = reached + rate * active * h
        // Pace is at least 1, so the ramp is done by its longest duration; the time check only absorbs rounding.
        if abs(next) >= abs(size) || t >= onset + duration {
            reached = size
            finished = true
            return WindKnot(value: size, slope: 0)
        }
        let rise = abs(next - reached)
        reached = next
        // This window's rate, eased so neither neighbouring window's Hermite curve turns back: slope × 30 s
        // at most 3 × the rise either side (Fritsch–Carlson). The next window rises by at least half this
        // one's rate, or by all that's left.
        let limit = 3 * min(rise, abs(size - reached)) / h
        return WindKnot(value: reached, slope: (size < 0 ? -1 : 1) * min(abs(rate), limit))
    }
}

/// HMAC output read as sixteen big-endian 16-bit lanes.
private struct Lanes {
    let bytes: [UInt8]

    init(_ bytes: [UInt8]) {
        precondition(bytes.count == 32)
        self.bytes = bytes
    }

    /// Lane `i` as a value in [0, 1], both ends included.
    func unit(_ i: Int) -> Double {
        Double(UInt16(bytes[2 * i]) << 8 | UInt16(bytes[2 * i + 1])) / 65535
    }

    /// Lanes 0–3 as a big-endian UInt64.
    var puffSeed: UInt64 {
        bytes[0..<8].reduce(0) { $0 << 8 | UInt64($1) }
    }
}

private func lerp(_ range: ClosedRange<Double>, _ u: Double) -> Double {
    range.lowerBound + (range.upperBound - range.lowerBound) * u
}

private func bigEndianBytes(_ value: UInt64) -> [UInt8] {
    (0..<8).map { UInt8(truncatingIfNeeded: value >> (56 - 8 * UInt64($0))) }
}
