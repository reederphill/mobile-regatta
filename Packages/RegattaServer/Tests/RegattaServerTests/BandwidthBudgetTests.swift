import RaceHost
import RegattaClient
import RegattaCore
import RegattaDevAPI
import RegattaLoadClient
import RegattaProtocol
@testable import RegattaServerKit
import Synchronization
import Testing

/// #27 with a full fleet of humans, measured in memory on a virtual clock (#216): the instant race's
/// `RaceSession` and 16 `RaceClient`s sailing it as the load client does, joined by links that count what
/// a WebSocket would carry. No sockets, no sleeping: the same race on a loaded machine is the same race.
/// Sockets are `EndToEndTests`' (one client) and CI's container job's (16 real clients, `--check-bandwidth`).
struct BandwidthBudgetTests {
    /// A clock the test moves by hand.
    final class VirtualClock: HostClock {
        private let time: Mutex<UInt64>

        init(now: UInt64 = 1_000_000) { time = Mutex(now) }

        func now() -> UInt64 { time.withLock { $0 } }
        func set(_ now: UInt64) { time.withLock { $0 = max($0, now) } }
    }

    /// One seat's connection, both ends: the host's `SeatTransport` and the client's `RaceTransport`.
    /// Each frame takes `oneWay` to arrive, either way, so the client's clock sync and lead see a network.
    final class Link: SeatTransport {
        private struct State {
            var inbox: [(at: UInt64, bytes: [UInt8])] = []
            var outbox: [(at: UInt64, bytes: [UInt8])] = []
            var closed = false
            /// What the client has received, as TCP would carry it: payload plus the server frame header.
            var bytesDelivered = 0
        }

        private let state = Mutex(State())
        private let clock: VirtualClock
        private let oneWay: UInt64

        init(clock: VirtualClock, oneWay: UInt64) {
            self.clock = clock
            self.oneWay = oneWay
        }

        /// RFC 6455 server frame header (unmasked): 2 bytes, 4 with a 16-bit length, 10 with a 64-bit one.
        static func headerBytes(payload: Int) -> Int { payload < 126 ? 2 : payload <= 0xFFFF ? 4 : 10 }

        var bytesReceived: Int { state.withLock { $0.bytesDelivered } }

        // Host side.
        func send(_ frame: [UInt8]) {
            let at = clock.now() + oneWay
            state.withLock { if !$0.closed { $0.inbox.append((at, frame)) } }
        }

        func close() { state.withLock { $0.closed = true } }

        /// The client's frames that have reached the host by now, oldest first.
        func arrivedAtHost() -> [[UInt8]] {
            let now = clock.now()
            return state.withLock { state in
                let due = state.outbox.prefix { $0.at <= now }
                state.outbox.removeFirst(due.count)
                return due.map(\.bytes)
            }
        }

        // Client side.
        var isConnected: Bool { state.withLock { !$0.closed || !$0.inbox.isEmpty } }

        func receive() -> [[UInt8]] {
            let now = clock.now()
            return state.withLock { state in
                let due = state.inbox.prefix { $0.at <= now }
                state.inbox.removeFirst(due.count)
                state.bytesDelivered += due.reduce(0) { $0 + $1.bytes.count + Self.headerBytes(payload: $1.bytes.count) }
                return due.map(\.bytes)
            }
        }

        func clientSend(_ frame: [UInt8]) {
            let at = clock.now() + oneWay
            state.withLock { $0.outbox.append((at, frame)) }
        }
    }

    /// `RaceTransport.send` is the client's; the host's `SeatTransport.send` has the same name.
    final class ClientEnd: RaceTransport {
        let link: Link
        init(_ link: Link) { self.link = link }
        var isConnected: Bool { link.isConnected }
        func send(_ frame: [UInt8]) { link.clientSend(frame) }
        func receive() -> [[UInt8]] { link.receive() }
    }

    struct SeatResult {
        var seat: Int
        var status: RaceClient.Status
        var bytesReceived: Int
        var joinBytes: Int
        var downstreamBytesPerSecond: Double
        var stats: RaceClient.Stats
    }

    /// The instant race the old socket test asked the dev server for, sailed by `clients` load-client
    /// helms at 30 updates a second, to its close.
    func sail(_ request: InstantRaceRequest, oneWay: UInt64 = 20_000) async throws -> [SeatResult] {
        let clock = VirtualClock()
        let session = try RaceSession.instant(request, clock: clock)
        let host = session.host
        let seats = session.humanSeats.sorted()
        let links = seats.map { _ in Link(clock: clock, oneWay: oneWay) }
        for (seat, link) in zip(seats, links) { try await session.join(seat: seat, transport: link) }

        // The RaceStart arrives one way later; the join is what came with it. (The upgrade and HelloAck
        // aren't modelled: a few hundred bytes against the 1 MB bound.)
        clock.set(clock.now() + oneWay)
        var clients: [RaceClient] = []
        var joinBytes: [Int] = []
        var startedAt: [UInt64] = []
        for link in links {
            let frames = link.receive()
            let first = try #require(frames.first)
            guard case .raceStart(let start) = try Frame(decoding: first).message else {
                Issue.record("expected RaceStart")
                return []
            }
            #expect(frames.count == 1, "nothing but the RaceStart before the race steps")
            joinBytes.append(link.bytesReceived)
            startedAt.append(clock.now())
            clients.append(RaceClient(start: start, transport: ClientEnd(link)))
        }

        // LoadClient.sail's frame, on the virtual clock: one client update per 1/30 s step.
        let frame = UInt64(1_000_000 / 30)
        var lastSeconds = Array(repeating: 0.0, count: clients.count)
        var endedAt: [UInt64?] = Array(repeating: nil, count: clients.count)
        var open = true
        var steps = 0
        while endedAt.contains(nil) {
            steps += 1
            try #require(steps < 30 * 120, "the race should close well inside two minutes of virtual time")
            clock.set(clock.now() + frame)
            if open, await host.driveStep(closeAtTick: session.closeAtTick) == nil {
                open = false
                for seat in seats { await host.disconnect(seat: seat) }
            }
            let now = clock.now()
            for (index, client) in clients.enumerated() where endedAt[index] == nil {
                let seconds = Double(now - startedAt[index]) / 1_000_000
                client.setHeld(InputScript.weave.held(at: seconds, seat: client.seat))
                if InputScript.weave.tacks(from: lastSeconds[index], to: seconds) { client.tap(.tackGybe, now: now) }
                lastSeconds[index] = seconds
                client.update(now: now)
                _ = client.drainServerEvents()
                if client.status == .finished || client.status == .disconnected { endedAt[index] = now }
            }
            if open {
                for (seat, link) in zip(seats, links) {
                    for bytes in link.arrivedAtHost() { await host.receive(bytes, from: seat) }
                }
            }
        }

        return clients.indices.map { index in
            let received = links[index].bytesReceived
            let raceSeconds = max(0.001, Double(endedAt[index]! - startedAt[index]) / 1_000_000)
            return SeatResult(seat: clients[index].seat, status: clients[index].status, bytesReceived: received,
                              joinBytes: joinBytes[index],
                              downstreamBytesPerSecond: Double(received - joinBytes[index]) / raceSeconds,
                              stats: clients[index].stats)
        }
    }

    /// #27 with a full fleet of humans: every client's downstream about 5 KB/s at most, and under 1 MB
    /// for the race with its join. Printed for the PR; see the README for how it scales with race length.
    @Test func sixteenLoadClientsInOneRaceStayWithinTheBandwidthBudget() async throws {
        let request = InstantRaceRequest(clients: 16, raceSeconds: 8, startSeconds: 2, seed: 16)
        #expect(request.fleetSize == 16)
        let results = try await sail(request)
        #expect(results.count == 16)
        #expect(Set(results.map(\.seat)) == Set(0..<16))
        for result in results {
            #expect(result.status == .finished, "seat \(result.seat): \(result.status)")
            #expect(BandwidthBudget.issue27.violations(seat: result.seat, downstreamBytesPerSecond: result.downstreamBytesPerSecond,
                                                       bytesReceived: result.bytesReceived) == [])
            #expect(result.downstreamBytesPerSecond > 1000, "a 16-boat race sends snapshots at 10 Hz")
            #expect(result.stats.heldSent > 0)
            #expect(result.stats.snapshotsRefused == 0)
            #expect(result.stats.undecodableFrames == 0)
        }
        let worst = results.map(\.downstreamBytesPerSecond).max() ?? 0
        let most = results.map(\.bytesReceived).max() ?? 0
        let join = results.map(\.joinBytes).max() ?? 0
        print("16 clients: worst downstream \(Int(worst)) B/s, most bytes \(most) B (join \(join) B) in \((request.startSeconds ?? 0) + (request.raceSeconds ?? 0)) s")
    }
}
