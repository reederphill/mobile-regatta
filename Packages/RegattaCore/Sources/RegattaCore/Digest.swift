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
    /// Golden digest: FNV-1a over the tick and the bit pattern of every field of every boat.
    /// Equal digests on the replay platform mean bit-for-bit equal races (ADR 0002).
    func digest() -> UInt64 {
        var h = FNV1a()
        h.combine(tick)
        h.combine(boats.count)
        for b in boats {
            h.combine(b.id)
            h.combine(b.name)
            h.combine(b.isPlayer)
            h.combine(b.colorIndex)
            h.combine(b.position.x)
            h.combine(b.position.y)
            h.combine(b.heading)
            h.combine(b.speed)
            h.combine(b.rudder)
            h.combine(b.desiredRudder)
            h.combine(b.autopilot)
            h.combine(b.status.digestCode)
            h.combine(b.legIndex)
            h.combine(b.roundingStage)
            h.combine(b.penaltyTurnsOwed)
            h.combine(b.penaltyProgress)
            h.combine(b.isTacking)
            h.combine(b.windDirection)
            h.combine(b.windSpeed)
            h.combine(b.shadow)
            h.combine(b.finishTime)
            h.combine(b.place)
        }
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
        case .dnf: 5
        }
    }
}
