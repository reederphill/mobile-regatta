import RaceHost
import RegattaCore
import RegattaProtocol
import Synchronization
import Testing

/// A clock the test moves by hand.
final class VirtualClock: HostClock {
    private let time: Mutex<UInt64>

    init(now: UInt64 = 1_000_000) { time = Mutex(now) }

    func now() -> UInt64 { time.withLock { $0 } }
    func set(_ now: UInt64) { time.withLock { $0 = now } }
    func advance(by micros: UInt64) { time.withLock { $0 += micros } }
}

/// A seat transport that keeps every frame the host sent it.
final class RecordingTransport: SeatTransport {
    private let state = Mutex<(frames: [[UInt8]], closed: Bool)>(([], false))

    func send(_ frame: [UInt8]) { state.withLock { $0.frames.append(frame) } }
    func close() { state.withLock { $0.closed = true } }

    var isClosed: Bool { state.withLock { $0.closed } }
    var frames: [Frame] { state.withLock { $0.frames }.map { try! Frame(decoding: $0) } }
    var events: [RaceEvent] { frames.compactMap(\.raceEvent) }
    var snapshotTicks: [Int] {
        frames.compactMap { if case .snapshot = $0.message { $0.tick } else { nil } }
    }
}

/// A host on a virtual clock: seat 0 human, the rest bots.
///
/// The rig's seats send only what a test sends, not a real client's heartbeat every 200 ms, so unless
/// `firstInputHold` is set the host waits for ever for a seat's first held input after an attach.
struct Rig {
    let clock = VirtualClock()
    let host: RaceHost
    let setup: RaceSetup
    let seat0 = RecordingTransport()
    private let alerts = AlertLog()
    private let allGoneLog = AllGoneLog()
    /// Every behind alert, in ticks behind.
    var behindAlerts: [Int] { alerts.ticks }
    /// Every time the all-gone hook fired.
    var allGones: [AllGone] { allGoneLog.fired }

    init(humans: Int = 1, seats: Int = 4, startSequenceTicks: Int = 300, options: RaceHostOptions = RaceHostOptions(),
         firstInputHold: Bool = false) async throws {
        var options = options
        if !firstInputHold { options.firstInputHoldTicks = .max / 2 }
        let kinds: [SeatKind] = (0..<seats).map { $0 < humans ? .human : .bot }
        setup = try RaceSetup(raceSeed: RaceSeed(65), seats: kinds, laps: 1, startSequenceTicks: startSequenceTicks)
        let alerts = alerts
        let allGoneLog = allGoneLog
        host = RaceHost(setup: setup, windSeed: WindSeed(0x65), clock: clock, options: options,
                        onBehind: { ticks in alerts.append(ticks) },
                        onAllGone: { allGone in allGoneLog.append(allGone) })
        #expect(await host.attach(seat: 0, transport: seat0))
    }

    /// Moves the clock to when `tick` is simulated, and lets the host simulate up to it.
    func run(to tick: Int) async {
        clock.set(await host.time(ofTick: tick))
        await host.advance()
    }

    /// Sends a frame from `seat`.
    func send(_ message: Message, seq: UInt32, stamp: Int, from seat: Int = 0) async {
        await host.receive(try! Frame(seq: seq, tick: stamp, message: message).encoded(), from: seat)
    }
}

final class AlertLog: Sendable {
    private let log = Mutex<[Int]>([])
    func append(_ ticks: Int) { log.withLock { $0.append(ticks) } }
    var ticks: [Int] { log.withLock { $0 } }
}

final class AllGoneLog: Sendable {
    private let log = Mutex<[AllGone]>([])
    func append(_ allGone: AllGone) { log.withLock { $0.append(allGone) } }
    var fired: [AllGone] { log.withLock { $0 } }
}
