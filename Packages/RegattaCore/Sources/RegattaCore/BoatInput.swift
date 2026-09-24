/// A seat's held input (#18): the rudder as int8 and the ease bit. It stays in force until the
/// seat sends a different one, so the race log records it only when it changes.
public struct BoatInput: Hashable, Sendable {
    /// −127 (hard to port) … 127 (hard to starboard). −128 is out of range and never stored.
    public let rudder: Int8
    /// Sheets let out: the boat slows (#13).
    public let ease: Bool

    public static let neutral = BoatInput(rudder: 0 as Int8, ease: false)
    public static let rudderRange: ClosedRange<Int8> = -127...127

    /// Clamps −128 to −127, the only out-of-range int8.
    public init(rudder: Int8, ease: Bool = false) {
        self.rudder = max(rudder, BoatInput.rudderRange.lowerBound)
        self.ease = ease
    }

    /// Quantises a rudder value in −1…1 (clamped) to int8, as a client does before sending it.
    public init(rudder value: Double, ease: Bool = false) {
        let clamped = value.isNaN ? 0 : value.clamped(to: -1...1)
        self.init(rudder: Int8((clamped * 127).rounded()), ease: ease)
    }

    /// The int8 → rudder mapping the simulation uses: −1…1.
    public var rudderValue: Double { Double(rudder) / 127 }
}

extension BoatInput: Codable {
    private enum CodingKeys: String, CodingKey { case rudder, ease }

    /// Range-checks rather than clamps, so a log with an out-of-range rudder is rejected, not altered.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode(Int.self, forKey: .rudder)
        guard let input = BoatInput(checkedRudder: raw, ease: try c.decode(Bool.self, forKey: .ease)) else {
            throw DecodingError.dataCorruptedError(forKey: .rudder, in: c, debugDescription: "rudder \(raw) is outside −127…127")
        }
        self = input
    }

    /// nil unless `raw` is in −127…127.
    init?(checkedRudder raw: Int, ease: Bool) {
        guard let rudder = Int8(exactly: raw), BoatInput.rudderRange.contains(rudder) else { return nil }
        self.init(rudder: rudder, ease: ease)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Int(rudder), forKey: .rudder)
        try c.encode(ease, forKey: .ease)
    }
}

/// A one-off input, stamped with the tick it applies at (#18). Applied once, never held.
public enum BoatTap: Hashable, Sendable {
    /// Mirror the heading across the wind with a brief autopilot; any rudder input cancels it (#13).
    case tackGybe
    /// Protest another seat. Recorded, never changes a result in v1.0.
    case protest(target: Int)
}
