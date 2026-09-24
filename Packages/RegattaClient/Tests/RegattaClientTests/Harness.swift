import RegattaClient
import RegattaCore
import RegattaProtocol

/// One client sailing against a `ScriptedHost` over a `FaultInjectingLink`, on a virtual clock that
/// moves a millisecond at a time. The host polls every millisecond; the client updates once a frame.
final class Harness {
    let clock = VirtualClock(now: 1_000_000)
    let link: FaultInjectingLink
    let host: ScriptedHost
    let client: RaceClient
    /// Every frame the client sent: when, and its type.
    private(set) var clientSends: [(time: UInt64, type: MessageType)] = []

    init(seats: Int = 8, startSequenceTicks: Int = 600, raceSeed: UInt64 = 64, windSeed: UInt64 = 0x5EED,
         uplink: LinkFaults = .none, downlink: LinkFaults = .none, linkSeed: UInt64 = 1,
         limits: InputLimits = InputLimits()) throws {
        link = FaultInjectingLink(clock: clock, uplink: uplink, downlink: downlink, seed: linkSeed)
        let kinds: [SeatKind] = (0..<seats).map { $0 == 0 ? .human : .bot }
        let setup = try RaceSetup(raceSeed: RaceSeed(raceSeed), seats: kinds, laps: 1, startSequenceTicks: startSequenceTicks)
        host = try ScriptedHost(setup: setup, windSeed: WindSeed(windSeed), clientSeat: 0, transport: link.server, clock: clock)
        client = RaceClient(start: host.raceStart(), transport: link.client, limits: limits)
        link.onSend = { [unowned self] direction, time, bytes in
            if direction == .uplink, let type = MessageType(rawValue: bytes[0]) { clientSends.append((time, type)) }
        }
    }

    /// Runs for `micros`, calling `frame` before each client update (every `frameEvery` µs).
    func run(for micros: UInt64, frameEvery: UInt64 = 16_667, frame: (Harness, UInt64) -> Void = { _, _ in }) {
        let end = clock.now + micros
        var nextFrame = clock.now
        while clock.now < end {
            clock.advance(by: 1000)
            host.poll()
            if clock.now >= nextFrame {
                nextFrame += frameEvery
                frame(self, clock.now)
                client.update(now: clock.now)
            }
        }
    }

    /// The most frames of `types` the client sent in any `window` µs.
    func maxSends(of types: Set<MessageType>, in window: UInt64 = 1_000_000) -> Int {
        let times = clientSends.filter { types.contains($0.type) }.map(\.time)
        var most = 0, first = 0
        for last in times.indices {
            while times[last] - times[first] >= window { first += 1 }
            most = max(most, last - first + 1)
        }
        return most
    }

    /// The most inputs of a kind that arrived at the host in any `window` µs.
    func maxArrivals(taps: Bool, in window: UInt64 = 1_000_000) -> Int {
        let times = host.arrivals.filter { $0.isTap == taps }.map(\.time)
        var most = 0, first = 0
        for last in times.indices {
            while times[last] - times[first] >= window { first += 1 }
            most = max(most, last - first + 1)
        }
        return most
    }
}
