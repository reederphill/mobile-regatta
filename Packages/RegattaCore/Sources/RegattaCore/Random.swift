/// Small deterministic RNG so a race seed reproduces the same wind and fleet.
///
/// Deliberately not a standard library random number generator: the standard library says its
/// range, coin and shuffle algorithms may change in a future Swift, which would change replays
/// with no code change of ours (ADR 0002). Map output to values with the methods below instead.
public struct SplitMix64: Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

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

    /// Uniform in [a, b).
    public mutating func range(_ a: Double, _ b: Double) -> Double {
        a + (b - a) * unit()
    }

    /// A fair coin: the top bit of the next value.
    public mutating func bool() -> Bool {
        next() >> 63 == 1
    }

    /// Uniform in `range`, without modulo bias (Lemire's multiply-and-reject).
    public mutating func int(in range: Range<Int>) -> Int {
        precondition(!range.isEmpty, "int(in:) needs a non-empty range")
        let span = UInt64(truncatingIfNeeded: range.upperBound &- range.lowerBound)
        var product = next().multipliedFullWidth(by: span)
        if product.low < span {
            let threshold = (0 &- span) % span
            while product.low < threshold {
                product = next().multipliedFullWidth(by: span)
            }
        }
        return range.lowerBound &+ Int(truncatingIfNeeded: product.high)
    }

    /// Uniform in `range`, inclusive of both ends.
    public mutating func int(in range: ClosedRange<Int>) -> Int {
        int(in: range.lowerBound ..< range.upperBound + 1)
    }

    /// Fisher–Yates shuffle, in place.
    public mutating func shuffle<T>(_ array: inout [T]) {
        guard array.count > 1 else { return }
        for i in stride(from: array.count - 1, to: 0, by: -1) {
            array.swapAt(i, int(in: 0...i))
        }
    }
}
