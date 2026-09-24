/// Small deterministic RNG so a race seed reproduces the same wind and fleet.
///
/// Deliberately not a standard library random number generator: the standard library says its
/// range, coin and shuffle algorithms may change in a future Swift, which would change replays
/// with no code change of ours (ADR 0002). Map output to values with the methods below instead.
public struct SplitMix64: Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    /// An independent stream of `seed`, named by a fixed `stream` tag: the tag is mixed into the seed
    /// through one SplitMix64 output, and the stream starts there. Drawing from it never advances the
    /// plain `SplitMix64(seed: seed)` stream, so a new stream never moves an existing draw (ADR 0002).
    /// The mixing is invertible, so a stream of a public seed is public too: never use it for anything
    /// secret (ADR 0001).
    public init(seed: UInt64, stream: UInt64) {
        var mixer = SplitMix64(seed: seed ^ stream)
        self.init(seed: mixer.next())
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1): the top 53 bits of the next value, scaled by 2⁻⁵³.
    public mutating func unit() -> Double {
        Double(next() >> 11) * 0x1p-53
    }

    /// Uniform in [a, b], almost always below b: `unit()` is below 1, but `a + (b - a) * u` can
    /// round up to exactly b. Callers must not rely on b being excluded.
    public mutating func range(_ a: Double, _ b: Double) -> Double {
        a + (b - a) * unit()
    }

    /// A fair coin: the top bit of the next value.
    public mutating func bool() -> Bool {
        next() >> 63 == 1
    }

    /// Uniform in `range`, without modulo bias.
    public mutating func int(in range: Range<Int>) -> Int {
        precondition(!range.isEmpty, "int(in:) needs a non-empty range")
        return int(from: range.lowerBound, span: UInt64(truncatingIfNeeded: range.upperBound &- range.lowerBound))
    }

    /// Uniform in `range`, inclusive of both ends. Works up to `Int.max` and for `Int.min...Int.max`.
    public mutating func int(in range: ClosedRange<Int>) -> Int {
        // Wrapping: the span of Int.min...Int.max is 2⁶⁴, which wraps to 0.
        let span = UInt64(truncatingIfNeeded: range.upperBound &- range.lowerBound) &+ 1
        return span == 0 ? Int(truncatingIfNeeded: next()) : int(from: range.lowerBound, span: span)
    }

    /// `lower + [0, span)`, by Lemire's multiply-and-reject. `span` must be non-zero.
    private mutating func int(from lower: Int, span: UInt64) -> Int {
        var product = next().multipliedFullWidth(by: span)
        if product.low < span {
            let threshold = (0 &- span) % span
            while product.low < threshold {
                product = next().multipliedFullWidth(by: span)
            }
        }
        return lower &+ Int(truncatingIfNeeded: product.high)
    }

    /// Fisher–Yates shuffle, in place.
    public mutating func shuffle<T>(_ array: inout [T]) {
        guard array.count > 1 else { return }
        for i in stride(from: array.count - 1, to: 0, by: -1) {
            array.swapAt(i, int(in: 0...i))
        }
    }
}
