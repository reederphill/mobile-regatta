import RegattaClient
import RegattaCore
import RegattaProtocol
import Synchronization

/// Checks every frame a load client receives against the wind reveal rules (#95, ADR 0001): no key
/// before its reveal tick (`WindKeyWire.revealTick`), every due key in each `RaceStart` and `Resync`, and,
/// when the client knows it, never the wind seed's bytes.
public struct WindAudit: Sendable {
    public let windows: WindWindows
    /// The wind seed's 8 bytes in both byte orders, if the client knows the seed (a dev instant race).
    private let needles: [[UInt8]]
    /// What broke the rules, in words, in the order seen.
    public private(set) var violations: [String] = []

    public init(windows: WindWindows, windSeed: UInt64?) {
        self.windows = windows
        if let windSeed {
            let littleEndian = (0..<8).map { UInt8(truncatingIfNeeded: windSeed >> (8 * UInt64($0))) }
            needles = [littleEndian, littleEndian.reversed()]
        } else {
            needles = []
        }
    }

    /// The audit for the race `start` begins. `windSeed` derives the seed from the race seed, if the
    /// client can (the dev instant race: `InstantRaceRequest.windSeed(forRaceSeed:)`).
    public init(start: RaceStart, windSeed: ((UInt64) -> UInt64)?) {
        self.init(windows: WindWindows(startSequenceTicks: start.setup.startSequenceTicks),
                  windSeed: windSeed.map { $0(start.setup.raceSeed.value) })
    }

    /// Checks one frame as received. A frame that doesn't decode is the client's to count, not the audit's.
    public mutating func check(_ bytes: [UInt8]) {
        for needle in needles where Self.contains(bytes, needle) {
            let type = (try? Frame(decoding: bytes)).map { "\($0.message.type)" } ?? "an undecodable frame"
            violations.append("wind seed bytes in \(type)")
        }
        guard let frame = try? Frame(decoding: bytes) else { return }
        switch frame.message {
        case .raceStart(let start): checkAll(start.windKeys, in: "RaceStart", tick: frame.tick)
        case .resync(let resync): checkAll(resync.windKeys, in: "Resync", tick: frame.tick)
        case .windKey(let key): checkRevealed(key, in: "WindKey", tick: frame.tick)
        default: break
        }
    }

    /// A key may be on the wire only once the server tick has reached its reveal tick.
    private mutating func checkRevealed(_ key: WindKey, in message: String, tick: Int) {
        let reveal = WindKeyWire.revealTick(of: key.window, windows: windows)
        if reveal > tick { violations.append("\(message) at tick \(tick) holds key \(key.window), unrevealed until tick \(reveal)") }
    }

    /// A join or resync carries every key revealed by its tick, from window 0, and no other.
    private mutating func checkAll(_ keys: [WindKey], in message: String, tick: Int) {
        for key in keys { checkRevealed(key, in: message, tick: tick) }
        let last = WindKeyWire.lastRevealedWindow(atTick: tick, windows: windows)
        let expected = last >= 0 ? Array(0...last) : []
        let windows = keys.map(\.window)
        if windows != expected {
            violations.append("\(message) at tick \(tick) holds keys \(windows.first ?? -1)…\(windows.last ?? -1) (\(windows.count)), "
                              + "not 0…\(last)")
        }
    }

    static func contains(_ bytes: [UInt8], _ needle: [UInt8]) -> Bool {
        guard bytes.count >= needle.count else { return false }
        return (0...(bytes.count - needle.count)).contains { start in
            bytes[start..<(start + needle.count)].elementsEqual(needle)
        }
    }
}

/// A `RaceTransport` that audits every frame it hands the client (`WindAudit`).
final class AuditingTransport: RaceTransport, @unchecked Sendable {
    private let inner: any RaceTransport
    private let audit: Mutex<WindAudit>

    init(_ inner: any RaceTransport, audit: WindAudit) {
        self.inner = inner
        self.audit = Mutex(audit)
    }

    var violations: [String] { audit.withLock { $0.violations } }

    var isConnected: Bool { inner.isConnected }
    func send(_ frame: [UInt8]) { inner.send(frame) }

    func receive() -> [[UInt8]] {
        let frames = inner.receive()
        audit.withLock { audit in for frame in frames { audit.check(frame) } }
        return frames
    }
}
