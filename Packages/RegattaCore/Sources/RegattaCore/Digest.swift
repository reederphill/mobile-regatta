/// 64-bit FNV-1a over little-endian bit patterns, so the same state hashes the same on every platform.
public struct FNV1a: Sendable {
    public private(set) var value: UInt64 = 0xCBF2_9CE4_8422_2325

    public init() {}

    public mutating func combine(_ bits: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) {
            value = (value ^ (bits >> UInt64(shift) & 0xFF)) &* 0x0100_0000_01B3
        }
    }

    public mutating func combine(_ x: Int) { combine(UInt64(bitPattern: Int64(x))) }
    public mutating func combine(_ x: Double) { combine(x.bitPattern) }
    public mutating func combine(_ x: Bool) { combine(UInt64(x ? 1 : 0)) }

    public mutating func combine(_ x: Double?) {
        combine(x != nil)
        if let x { combine(x) }
    }

    public mutating func combine(_ x: Int?) {
        combine(x != nil)
        if let x { combine(x) }
    }

    public mutating func combine(_ s: String) {
        combine(s.utf8.count)
        for byte in s.utf8 { combine(UInt64(byte)) }
    }
}

public extension Race {
    /// Golden digest: FNV-1a over the tick, the bit pattern of every field of every boat (her autohelm's
    /// target and tap, planing, spinnaker and averaged groove wind included), and each seat's held input, then every pair's overlap as of the last point of certainty. Equal digests on the replay platform mean bit-for-bit equal races (ADR 0002).
    func digest() -> UInt64 {
        var h = FNV1a()
        h.combine(tick)
        h.combine(boats.count)
        for (seat, b) in boats.enumerated() {
            h.combine(Int(heldInputs[seat].rudder))
            h.combine(heldInputs[seat].ease)
            h.combine(b.id)
            h.combine(b.isPlayer)
            h.combine(b.colorIndex)
            h.combine(b.position.x)
            h.combine(b.position.y)
            h.combine(b.heading)
            h.combine(b.speed)
            h.combine(b.rudder)
            h.combine(b.desiredRudder)
            h.combine(b.autohelm?.target.digestCode)
            h.combine(b.autohelm?.target.angle)
            h.combine(b.autohelm?.isTapping ?? false)
            h.combine(b.boomSide.digestCode)
            h.combine(b.status.digestCode)
            h.combine(b.legIndex)
            h.combine(b.roundingStage)
            h.combine(b.penaltyTurnsOwed)
            h.combine(b.penaltyProgress)
            h.combine(b.isTacking)
            h.combine(b.isPlaning)
            h.combine(b.spinnaker.digestCode)
            h.combine(b.spinnaker.remaining)
            h.combine(b.averagedWindSpeed)
            h.combine(b.windOverGround.direction)
            h.combine(b.windOverGround.speed)
            h.combine(b.sailingWind.direction)
            h.combine(b.sailingWind.speed)
            h.combine(b.apparentWind.direction)
            h.combine(b.apparentWind.speed)
            h.combine(b.current.x)
            h.combine(b.current.y)
            h.combine(b.shadow)
            h.combine(b.finishTime)
            h.combine(b.place)
        }
        overlaps.combine(into: &h)
        return h.value
    }
}

extension BoatStatus {
    /// Stable codes for the digest, independent of the enum's declaration order.
    var digestCode: Int {
        switch self {
        case .prestart: 0
        case .ocs: 1
        case .racing: 2
        case .finished: 3
        case .dsq: 4
        // 5 was `dnf`, removed by #86 (a boat still racing at the close keeps `racing`): retired, never reused.
        }
    }
}

extension Autohelm.Target {
    /// Stable codes for the digest, independent of the enum's declaration order.
    var digestCode: Int {
        switch self {
        case .angle: 0
        case .groove(.upwind): 1
        case .groove(.downwind): 2
        }
    }
}

extension Spinnaker {
    /// Stable codes for the digest, independent of the enum's declaration order.
    var digestCode: Int {
        switch self {
        case .down: 0
        case .hoisting: 1
        case .up: 2
        case .dropping: 3
        }
    }
}

extension BoomSide {
    /// Stable codes for the digest, independent of the enum's declaration order.
    var digestCode: Int {
        switch self {
        case .port: 0
        case .starboard: 1
        }
    }
}

/// A digest or seed as "0x" and 16 lowercase hex digits.
public func hex64(_ value: UInt64) -> String {
    let digits = String(value, radix: 16)
    return "0x" + String(repeating: "0", count: 16 - digits.count) + digits
}

/// Parses "0x" and 1…16 hex digits.
public func parseHex64(_ text: String) -> UInt64? {
    let digits = text.dropFirst(2)
    guard text.hasPrefix("0x"), (1...16).contains(digits.count), digits.allSatisfy(\.isHexDigit) else { return nil }
    return UInt64(digits, radix: 16)
}
