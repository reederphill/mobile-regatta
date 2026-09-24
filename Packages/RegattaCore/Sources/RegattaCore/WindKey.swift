// ADR 0001 and #18: the wind is a pure function of a chain of per-window keys. Windows are 30 s long;
// the knot at each window boundary carries the shift's value and slope, and window k is a cubic Hermite
// curve from the knot in key k − 1 to the knot in key k, so it reads only keys up to k. The server
// reveals key k one window ahead of the knot it carries, before window k starts.

/// The 30 s time windows the wind is keyed by, laid on the race clock from an origin.
///
/// Window k covers ticks `[origin + 900k, origin + 900(k + 1))`. Its key carries the knot at its end.
public struct WindWindows: Hashable, Sendable {
    /// Ticks per window: 30 s at 30 Hz (#18).
    public static let ticksPerWindow = 30 * Race.tickRate
    /// Seconds per window.
    public static let seconds = Double(ticksPerWindow) / Double(Race.tickRate)

    /// Race tick at which window 0 starts.
    public let origin: Int

    public init(origin: Int) {
        self.origin = origin
    }

    /// The window grid of a race whose start sequence is `startSequenceTicks` long (simulation revision 3).
    ///
    /// Knots fall on whole windows from the gun, and the origin is one whole window before the window
    /// holding the race's first tick: `origin = −900 · (⌈startSequenceTicks / 900⌉ + 1)`. So window 0
    /// ends at or before the first tick and is never sampled by the race, and the fixed knot at the
    /// origin (`WindField.firstKnot`) is never felt: every tick the race samples lies between two knots
    /// that came from keys. For the default 60 s sequence the origin is tick −2700 and the race
    /// starts at the start of window 1.
    public init(startSequenceTicks: Int) {
        precondition(startSequenceTicks >= 1, "a race has a start sequence")
        let windowsBeforeGun = (startSequenceTicks + Self.ticksPerWindow - 1) / Self.ticksPerWindow
        origin = -Self.ticksPerWindow * (windowsBeforeGun + 1)
    }

    /// The window holding `tick`: negative before the origin.
    public func window(containing tick: Int) -> Int {
        let offset = tick - origin
        return offset >= 0 ? offset / Self.ticksPerWindow : -((-offset + Self.ticksPerWindow - 1) / Self.ticksPerWindow)
    }

    /// The first tick of `window`, which is also the tick of the knot ending `window − 1`.
    public func start(of window: Int) -> Int {
        origin + window * Self.ticksPerWindow
    }

    /// Race tick of the knot key `window` carries: the end of the window.
    public func knotTick(of window: Int) -> Int {
        start(of: window + 1)
    }
}

/// A value and its rate of change at a knot, per second.
public struct WindKnot: Hashable, Sendable {
    public let value: Double
    /// Per second.
    public let slope: Double

    public init(value: Double, slope: Double) {
        self.value = value
        self.slope = slope
    }
}

/// A window's keyed wobble: the smaller, faster wiggle on the shift within one window (#10). Its two
/// shapes vanish, with their slopes, at both ends of the window, so the knots stay exactly as keyed.
public struct WindWobble: Hashable, Sendable {
    /// Radians at the middle of the window of a single swell one way: `hump · sin²(πs)` at fraction `s`.
    public let hump: Double
    /// Peak radians of a full swing one way then the other, positive first: `wiggle · 2 sin²(πs) cos(πs) / (4 / 3√3)`.
    public let wiggle: Double

    public static let none = WindWobble(hump: 0, wiggle: 0)

    public init(hump: Double, wiggle: Double) {
        self.hump = hump
        self.wiggle = wiggle
    }
}

/// One window's key (ADR 0001): everything a client needs to evaluate window `window`, given key
/// `window − 1` for the knot it starts from. Derived on the server from the wind seed's HMAC chain
/// (`WindKeyGenerator`); a client only ever holds keys, never the seed.
public struct WindKey: Hashable, Sendable {
    /// Byte length of `bytes`.
    public static let byteCount = 64

    /// The window this key covers; its knots are at the end of the window.
    public let window: Int
    /// The base shift from the mean direction at the knot ending the window, radians (positive veers,
    /// clockwise), and its slope, radians per second. Fleet-wide: it has no position (ADR 0001).
    public let shift: WindKnot
    /// The strength channel at the knot: a factor of the base strength (1 = base), and its slope per
    /// second. The build and any ramp ride it (#10).
    public let strength: WindKnot
    /// The wobble within this window.
    public let wobble: WindWobble
    /// Seeds this window's puff and lull spawns (#76).
    public let puffSeed: UInt64

    public init(window: Int, shift: WindKnot, strength: WindKnot, wobble: WindWobble, puffSeed: UInt64) {
        precondition(window >= 0, "window keys start at window 0")
        self.window = window
        self.shift = shift
        self.strength = strength
        self.wobble = wobble
        self.puffSeed = puffSeed
    }

    /// A fixed 64-byte encoding, for the wire and for comparing chains byte for byte: eight big-endian
    /// 64-bit fields, `window` (two's complement), then the IEEE 754 bit patterns of shift value and
    /// slope, strength value and slope, wobble hump and wiggle, then `puffSeed`.
    public var bytes: [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(Self.byteCount)
        let fields: [UInt64] = [
            UInt64(bitPattern: Int64(window)),
            shift.value.bitPattern, shift.slope.bitPattern,
            strength.value.bitPattern, strength.slope.bitPattern,
            wobble.hump.bitPattern, wobble.wiggle.bitPattern,
            puffSeed,
        ]
        for field in fields {
            for shiftBits in stride(from: 56, through: 0, by: -8) { out.append(UInt8(truncatingIfNeeded: field >> UInt64(shiftBits))) }
        }
        return out
    }

    /// Decodes `bytes`; nil unless they are exactly 64 bytes with a window of at least 0 and every value finite.
    public init?(bytes: [UInt8]) {
        guard bytes.count == Self.byteCount else { return nil }
        var fields: [UInt64] = []
        for start in stride(from: 0, to: Self.byteCount, by: 8) {
            var field: UInt64 = 0
            for byte in bytes[start..<(start + 8)] { field = field << 8 | UInt64(byte) }
            fields.append(field)
        }
        let window = Int64(bitPattern: fields[0])
        let values = fields[1...6].map { Double(bitPattern: $0) }
        guard window >= 0, window <= Int64(Int.max), values.allSatisfy(\.isFinite) else { return nil }
        self.init(
            window: Int(window),
            shift: WindKnot(value: values[0], slope: values[1]),
            strength: WindKnot(value: values[2], slope: values[3]),
            wobble: WindWobble(hump: values[4], wiggle: values[5]),
            puffSeed: fields[7]
        )
    }
}

/// The keys a party holds, by window. The server's chain is complete; a client's runs up to the last
/// key revealed (ADR 0001). Keys may arrive in any order, and a missing one is simply absent: nothing
/// is ever guessed in its place.
public struct WindKeyChain: Hashable, Sendable {
    /// `slots[k]` is key k, if held.
    private var slots: [WindKey?] = []

    public init() {}

    public init(_ keys: [WindKey]) {
        for key in keys { insert(key) }
    }

    /// Adds `key`, replacing any key already held for its window.
    public mutating func insert(_ key: WindKey) {
        if key.window >= slots.count { slots += Array(repeating: nil, count: key.window - slots.count + 1) }
        slots[key.window] = key
    }

    /// Drops the key for `window`, if held.
    public mutating func remove(window: Int) {
        guard slots.indices.contains(window) else { return }
        slots[window] = nil
        while let last = slots.last, last == nil { slots.removeLast() }
    }

    public subscript(window: Int) -> WindKey? {
        slots.indices.contains(window) ? slots[window] : nil
    }

    /// The keys held, in window order.
    public var keys: [WindKey] { slots.compactMap { $0 } }

    /// One past the highest window held; 0 when empty.
    public var endWindow: Int { slots.count }

    /// Every key held, in window order, as `WindKey.bytes`.
    public var bytes: [UInt8] { keys.flatMap(\.bytes) }
}
