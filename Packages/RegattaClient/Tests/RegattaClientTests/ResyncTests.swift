import RegattaCore
import RegattaProtocol
import Testing
@testable import RegattaClient

/// Missing wind keys, lost reliable frames, disconnects and `Resync` (#64).
@Suite struct ResyncTests {
    /// Key 2 starts the window at the gun (a 20 s sequence: windows start at −1800, −900, 0, …) and is
    /// revealed at server tick −30 (#95). A 1.5 s lag spike on the downlink around then makes it late:
    /// the client stops before tick 0 rather than guess the wind, asks for a resync, and sails on when
    /// the key comes. At no frame does its race stand on a tick it lacks a key for, or hold a key the
    /// server hasn't revealed.
    @Test func aLateWindKeyStopsThePredictionAndRequestsAResync() throws {
        let harness = try Harness(uplink: LinkFaults(delay: 50_000), downlink: LinkFaults(delay: 50_000, inOrder: true), linkSeed: 4)
        var sawWaiting = false
        var worstGap = 0
        var violations: [String] = []
        harness.run(for: 40_000_000) { h, _ in
            let serverTick = h.host.race.tick
            h.link.downlink.delay = (-90 ..< 0).contains(serverTick) ? 1_500_000 : 50_000
            let race = h.client.predicted.race
            if case .waitingForWindKey(let key) = h.client.status {
                sawWaiting = true
                if key != 2 { violations.append("waiting for key \(key)") }
            }
            if (try? race.wind.shift(atTick: race.tick)) == nil { violations.append("no wind at tick \(race.tick)") }
            if race.wind.keys.endWindow > h.host.revealed.count { violations.append("unrevealed key held at \(serverTick)") }
            if race.wind.keys[2] == nil && race.tick >= 0 { violations.append("sailed tick \(race.tick) without key 2") }
            worstGap = max(worstGap, h.client.clientTick - race.tick)
        }
        let stats = harness.client.stats
        print("RESYNC late key: waited \(sawWaiting), stalled up to \(worstGap) ticks, requests \(stats.resyncRequests), "
              + "applied \(stats.resyncsApplied)")
        #expect(violations.isEmpty, "\(violations.prefix(5))")
        #expect(sawWaiting)
        #expect(stats.resyncRequests >= 1 && harness.host.resyncsSent >= 1)
        #expect(stats.resyncsApplied >= 1)
        #expect(harness.client.status == .predicting)
        #expect(harness.client.predicted.race.tick > 500)
        #expect(harness.client.predicted.race.wind.keys.keys == Array(harness.host.revealed.prefix(harness.client.predicted.race.wind.keys.endWindow)))
    }

    /// A lost `Event` (the gun) leaves a gap in the reliable stream; once the next event shows it, the
    /// client waits `gapTimeout` for it, then asks for a resync, which restores the event state.
    @Test func aLostReliableFrameBringsAResync() throws {
        let harness = try Harness(uplink: LinkFaults(delay: 40_000), downlink: LinkFaults(delay: 40_000), linkSeed: 5)
        var dropped = 0
        harness.link.drop = { direction, bytes in
            guard direction == .downlink, dropped == 0, let frame = try? Frame(decoding: bytes), frame.message == .event(.gun) else {
                return false
            }
            dropped += 1
            return true
        }
        harness.run(for: 40_000_000)
        let predicted = harness.client.predicted
        let stats = harness.client.stats
        print("RESYNC lost gun event: requests \(stats.resyncRequests), applied \(stats.resyncsApplied), next seq \(predicted.events.nextEventSeq)")
        #expect(dropped == 1)
        #expect(stats.resyncRequests >= 1 && stats.resyncsApplied >= 1)
        let server = EventState(world: harness.host.race.exportSnapshot(), nextEventSeq: predicted.events.nextEventSeq)
        #expect(predicted.events == server)
        #expect(harness.client.status == .predicting)
    }

    /// Cut mid-race and reconnected 3 s later over a new connection: the client shows it's disconnected,
    /// then on `attach` asks for a resync and predicts from it within a snapshot or two.
    @Test func aDisconnectThenReconnectResyncs() throws {
        let faults = LinkFaults(delay: 60_000, jitter: 20_000)
        let harness = try Harness(uplink: faults, downlink: faults, linkSeed: 6)
        var statuses: [RaceClient.Status] = []
        let start = harness.clock.now
        var drawn: [(tick: Int, position: Vec2)] = []
        harness.run(for: 50_000_000) { h, now in
            let elapsed = now - start
            if elapsed >= 30_000_000 && h.link.isConnected && statuses.last != .disconnected && !statuses.contains(.disconnected) {
                h.link.disconnect()
            }
            if elapsed >= 33_000_000 && !h.link.isConnected {
                h.link.reconnect()
                h.host.transport = h.link.server
                h.client.attach(h.link.client)
            }
            h.client.setHeld(BoatInput(rudder: Int8(truncatingIfNeeded: Int(elapsed / 2_000_000) % 3 * 40 - 40)))
            if elapsed >= 35_000_000 { drawn.append((h.client.predicted.race.tick, h.client.predicted.race.boats[0].position)) }
            if statuses.last != h.client.status { statuses.append(h.client.status) }
        }
        let worst = drawn.compactMap { d in harness.host.ownPosition(atTick: d.tick).map { (d.position - $0).length } }.max() ?? .infinity
        print("RESYNC disconnect: statuses \(statuses); resyncs applied \(harness.client.stats.resyncsApplied); worst error after \(worst) m")
        #expect(statuses.contains(.disconnected))
        #expect(harness.client.status == .predicting)
        #expect(harness.client.stats.resyncsApplied >= 1)
        #expect(worst < Boat.length)
    }

    /// A `Resync` rebuilds a fresh prediction from the snapshot, the revealed keys and the event state.
    @Test func aResyncRebuildsFromSnapshotKeysAndEventState() throws {
        let harness = try Harness(linkSeed: 7)
        // Sail the host alone to past the gun.
        while harness.host.race.tick < 450 {
            harness.clock.advance(by: 1000)
            harness.host.poll()
        }
        _ = harness.link.client.receive()
        let host = harness.host.race
        let resync = try Resync(raceSeed: host.setup.raceSeed, world: host.exportSnapshot(), windKeys: harness.host.revealed,
                                nextEventSeq: 17)
        let predicted = PredictedRace(start: harness.host.raceStart())
        #expect(predicted.tick == -600)
        try predicted.apply(resync, tick: host.tick)
        #expect(predicted.tick == host.tick)
        #expect(predicted.race.wind.keys.keys == harness.host.revealed)
        #expect(predicted.events == resync.eventState)
        #expect(predicted.events.nextEventSeq == 17)
        for (a, b) in zip(predicted.race.boats, host.boats) {
            #expect((a.position - b.position).length < 0.01)
            #expect(a.status == b.status)
        }
        // It sails on through the next window on the revealed keys.
        predicted.advance(to: host.tick + 300)
        #expect(predicted.tick == host.tick + 300)
        #expect(predicted.missingWindKey == nil)
    }

    // MARK: - The reliable stream

    static func frame(_ seq: UInt32) -> Frame { Frame(seq: seq, tick: Int(seq), message: .event(.gun)) }

    @Test func theReliableStreamDeliversInOrderAndDropsDuplicates() {
        var stream = ReliableStream(next: 1)
        #expect(stream.receive(Self.frame(2), now: 0).isEmpty)
        #expect(stream.receive(Self.frame(3), now: 10).isEmpty)
        #expect(stream.receive(Self.frame(1), now: 20).map(\.seq) == [1, 2, 3])
        #expect(stream.receive(Self.frame(2), now: 30).isEmpty)
        #expect(stream.receive(Self.frame(4), now: 40).map(\.seq) == [4])
        #expect(!stream.isBroken(now: 10_000_000))
    }

    @Test func aGapThatLastsBreaksTheStreamAndARestartMendsIt() {
        var stream = ReliableStream(next: 1)
        _ = stream.receive(Self.frame(1), now: 0)
        _ = stream.receive(Self.frame(3), now: 100_000)
        #expect(!stream.isBroken(now: 599_999))
        #expect(stream.isBroken(now: 600_000))
        stream.restart(at: 3)
        #expect(!stream.isBroken(now: 700_000))
        #expect(stream.drain(now: 700_000).map(\.seq) == [3])
        #expect(stream.receive(Self.frame(4), now: 800_000).map(\.seq) == [4])
    }
}
