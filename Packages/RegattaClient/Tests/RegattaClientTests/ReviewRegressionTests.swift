import RegattaCore
import RegattaProtocol
import Testing
@testable import RegattaClient

/// A transport a test fills and empties by hand.
final class ManualTransport: RaceTransport {
    var isConnected = true
    var inbox: [[UInt8]] = []
    var outbox: [Frame] = []

    func send(_ frame: [UInt8]) {
        if let decoded = try? Frame(decoding: frame) { outbox.append(decoded) }
    }

    func receive() -> [[UInt8]] {
        defer { inbox.removeAll() }
        return inbox
    }

    func deliver(_ frame: Frame) throws { inbox.append(try frame.encoded()) }
}

/// Regressions from the #64 review: each was a probe that showed the bug.
@Suite struct ReviewRegressionTests {
    /// An authoritative race of `seats` (seat 0 human, the rest bots) and its key generator.
    static func host(seats: Int = 4) throws -> (BotSailedRace, WindKeyGenerator) {
        let kinds: [SeatKind] = (0..<seats).map { $0 == 0 ? .human : .bot }
        let setup = try RaceSetup(raceSeed: RaceSeed(64), seats: kinds, laps: 1, startSequenceTicks: 600)
        let race = Race(setup: setup, windSeed: WindSeed(0x5EED))
        let keys = try WindKeyGenerator(windSeed: WindSeed(0x5EED), setup: race.windSetup, windows: race.wind.windows)
        return (BotSailedRace(race, humanSeat: 0), keys)
    }

    static func start(_ host: BotSailedRace, keys: [WindKey]) -> RaceStart {
        RaceStart(yourSeat: 0, setup: host.setup, roster: roster(of: host.race), windKeys: keys)
    }

    /// The client's update loop stalls (a frame hitch, a brief suspension) with the helm moving. Its
    /// inputs were stamped from the tick it had reached, behind the server, so they arrived late and the
    /// late feedback wound the lead up (a 400 ms hitch: 11 ticks late, lead 12.9). Now they're stamped
    /// from the clock: none arrive late, and the lead doesn't move.
    @Test(arguments: [150_000, 400_000, 1_000_000] as [UInt64])
    func anUpdateStallDoesntStampLate(pause: UInt64) throws {
        let faults = LinkFaults(delay: 50_000, jitter: 10_000)
        let h = try Harness(uplink: faults, downlink: faults, linkSeed: 2)
        let start = h.clock.now
        var nextFrame = h.clock.now
        var leadBefore = 0.0, maxLead = 0.0, maxFeedback = 0.0
        while h.clock.now < start + 12_000_000 {
            h.clock.advance(by: 1000)
            h.host.poll()
            let elapsed = h.clock.now - start
            guard h.clock.now >= nextFrame else { continue }
            nextFrame += 16_667
            if (6_000_000..<(6_000_000 + pause)).contains(elapsed) { continue }
            h.client.setHeld(BoatInput(rudder: Int8(truncatingIfNeeded: Int(elapsed / 500_000) % 3 * 40 - 40)))
            h.client.update(now: h.clock.now)
            if elapsed < 6_000_000 { leadBefore = h.client.lead.lead }
            maxLead = max(maxLead, h.client.lead.lead)
            maxFeedback = max(maxFeedback, h.client.lead.feedback)
        }
        let late = h.host.arrivals.filter { $0.margin < 0 }.map(\.margin)
        print("REGRESSION stall \(pause / 1000) ms: lead before \(leadBefore), max \(maxLead), feedback \(maxFeedback), late \(late)")
        #expect(late.isEmpty)
        #expect(maxFeedback == 0)
        #expect(maxLead <= leadBefore + 0.5)
    }

    /// A host that acks an input on arrival, before the tick it's stamped for: the input stays in the
    /// prediction (it was dropped, and the own boat was predicted with the rudder centred).
    @Test func anInputStampedAfterTheSnapshotSurvivesAnEarlyAck() throws {
        var (host, generator) = try Self.host()
        let start = Self.start(host, keys: generator.keys(through: 10))
        for _ in 0..<700 { host.step() }
        let t = host.tick
        let predicted = PredictedRace(start: start)
        predicted.advance(to: t + 5)
        let input = StampedInput(seq: 1, tick: t + 3, kind: .held(BoatInput(rudder: 1.0)))
        predicted.sent(input)
        let early = try Snapshot(world: host.exportSnapshot(), ack: InputAck(seq: 1, appliedTick: t + 3, margin: 2))
        try predicted.apply(early, tick: t)
        predicted.advance(to: t + 10)
        #expect(predicted.race.heldInputs[0] == BoatInput(rudder: 127 as Int8))

        // Once a snapshot at or past its stamp acks it, it's gone: the server's state has it.
        for _ in 0..<6 { host.step() }
        host.apply(BoatInput(rudder: 127 as Int8), seat: 0, atTick: t + 3) // late for the host: lands at t + 7
        host.step()
        let later = try Snapshot(world: host.exportSnapshot(), ack: InputAck(seq: 1, appliedTick: t + 7, margin: -4))
        try predicted.apply(later, tick: host.tick)
        #expect(predicted.race.heldInputs[0] == BoatInput(rudder: 127 as Int8))
    }

    /// A second `RaceStart` (a rejoin) built a fresh race at the start of the sequence, and the next
    /// update sailed it all the way to the server's tick in one frame. Now nothing sails until the
    /// resync is in; then the race starts from the resync.
    @Test func aRejoinWaitsForTheResyncInsteadOfSailingTheWholeRace() throws {
        var (host, generator) = try Self.host(seats: 8)
        var revealed = generator.keys(through: 1)
        let transport = ManualTransport()
        let client = RaceClient(start: Self.start(host, keys: revealed), transport: transport)
        try transport.deliver(Frame(seq: 1, tick: host.tick, message: .pong(Pong(clientTime: 0, sinceTickMicros: 0))))
        client.update(now: 0)
        #expect(client.status == .predicting)

        while host.tick < 3000 { host.step() }
        while generator.nextWindow <= host.wind.windows.window(containing: host.tick) + 1 { revealed.append(generator.next()) }
        try transport.deliver(Frame(seq: 2, tick: host.tick, message: .raceStart(Self.start(host, keys: revealed))))
        // The clock says the server is at 3000 now.
        let now = UInt64(Double(3600) * ClockSync.tickMicros)
        client.update(now: now)
        #expect(client.status == .awaitingResync)
        #expect(client.predicted.tick == -600)
        #expect(transport.outbox.contains { $0.message == .requestResync })

        // A snapshot while waiting is ignored: the fresh race is nowhere near it.
        try transport.deliver(Frame(seq: 3, tick: host.tick, message: .snapshot(Snapshot(world: host.exportSnapshot()))))
        client.update(now: now + 16_667)
        #expect(client.predicted.tick == -600 && client.stats.snapshotsRefused == 0)

        let resync = try Resync(raceSeed: host.setup.raceSeed, world: host.exportSnapshot(), windKeys: revealed, nextEventSeq: 40)
        try transport.deliver(Frame(seq: 4, tick: host.tick, message: .resync(resync)))
        client.update(now: now + 33_334)
        #expect(client.status == .predicting)
        #expect(client.predicted.tick >= host.tick && client.predicted.tick <= host.tick + 31)
    }

    /// The same for a client built for a race under way.
    @Test func aClientJoiningUnderwayWaitsForTheResync() throws {
        var (host, generator) = try Self.host()
        let revealed = generator.keys(through: 3)
        while host.tick < 900 { host.step() }
        let transport = ManualTransport()
        let client = RaceClient(start: Self.start(host, keys: revealed), transport: transport, joiningUnderway: true)
        try transport.deliver(Frame(seq: 1, tick: host.tick, message: .pong(Pong(clientTime: 0, sinceTickMicros: 0))))
        client.update(now: 0)
        #expect(client.status == .awaitingResync && client.predicted.tick == -600)
        #expect(transport.outbox.contains { $0.message == .requestResync })
        let resync = try Resync(raceSeed: host.setup.raceSeed, world: host.exportSnapshot(), windKeys: revealed, nextEventSeq: 1)
        try transport.deliver(Frame(seq: 2, tick: host.tick, message: .resync(resync)))
        client.update(now: 16_667)
        #expect(client.status == .predicting && client.predicted.tick >= host.tick)
    }

    /// Reliable frame N (key 2) reaches the client just before a resync whose `nextEventSeq` is N. The
    /// resync's keys lack key 2 and the server will never send frame N again: the client kept the
    /// stream where it was and lost the key, then stopped at tick −1 for good. Now it re-applies the
    /// frames it already had on top of the resync.
    @Test func aReliableFrameThatBeatsAnOlderResyncIsKept() throws {
        var (host, generator) = try Self.host()
        var revealed = generator.keys(through: 1)
        let transport = ManualTransport()
        let client = RaceClient(start: Self.start(host, keys: revealed), transport: transport)
        while host.tick < -40 { host.step() }
        let resync = try Resync(raceSeed: host.setup.raceSeed, world: host.exportSnapshot(), windKeys: revealed, nextEventSeq: 1)
        let key2 = generator.next()
        revealed.append(key2)
        try transport.deliver(Frame(seq: 1, tick: host.tick, message: .windKey(key2)))
        try transport.deliver(Frame(seq: 1, tick: host.tick, message: .resync(resync)))
        client.update(now: 1_000_000)
        #expect(client.predicted.race.wind.keys[2] == key2)
        #expect(client.predicted.events.nextEventSeq == 2)

        try transport.deliver(Frame(seq: 2, tick: host.tick, message: .pong(Pong(clientTime: 1_000_000, sinceTickMicros: 0))))
        var now: UInt64 = 1_000_000
        var statuses: [RaceClient.Status] = []
        for _ in 0..<120 {
            now += 16_667
            client.update(now: now)
            if statuses.last != client.status { statuses.append(client.status) }
        }
        #expect(statuses == [.predicting])
        #expect(client.predicted.tick > 0)
        // A frame after it still follows in order.
        let gun = RaceEvent(tick: 0, kind: .gun)
        try transport.deliver(Frame(seq: 2, event: gun))
        client.update(now: now + 16_667)
        #expect(client.drainServerEvents() == [gun])
    }

    /// A resync of another race is refused, and the prediction is unchanged.
    @Test func aResyncOfAnotherRaceIsRefused() throws {
        var (host, generator) = try Self.host()
        let keys = generator.keys(through: 2)
        let predicted = PredictedRace(start: Self.start(host, keys: keys))
        for _ in 0..<60 { host.step() }
        let resync = try Resync(raceSeed: RaceSeed(65), world: host.exportSnapshot(), windKeys: keys, nextEventSeq: 1)
        #expect(throws: PredictedRaceError.otherRace(RaceSeed(65))) { try predicted.apply(resync, tick: host.tick) }
        #expect(predicted.tick == -600)
    }

    /// A `RaceStart` without the keys for its first tick: the prediction says which key it needs rather
    /// than leave a race whose wind would trap when drawn.
    @Test func aRaceStartWithoutItsFirstKeysReportsTheMissingKey() throws {
        let (host, _) = try Self.host()
        let predicted = PredictedRace(start: Self.start(host, keys: []))
        #expect(predicted.missingWindKey == 0)
        predicted.advance(to: -500)
        #expect(predicted.missingWindKey == 0 && predicted.tick == -600)
    }

    /// Taps don't go stale: one made while the client can't send is dropped after 250 ms, and a
    /// disconnect drops those not yet sent.
    @Test func staleTapsAreDropped() throws {
        var stamper = InputStamper()
        let first = stamper.tap(.tackGybe, now: 0)
        #expect(first)
        let late = stamper.outgoing(now: 300_000, tick: 10)
        #expect(late.allSatisfy { $0.kind != .tap(.tackGybe) })
        let second = stamper.tap(.tackGybe, now: 400_000)
        #expect(second)
        let prompt = stamper.outgoing(now: 500_000, tick: 11)
        #expect(prompt.contains { $0.kind == .tap(.tackGybe) })

        let (host, _) = try Self.host()
        let transport = ManualTransport()
        let client = RaceClient(start: Self.start(host, keys: []), transport: transport)
        try transport.deliver(Frame(seq: 1, tick: host.tick, message: .pong(Pong(clientTime: 0, sinceTickMicros: 0))))
        client.update(now: 0)
        transport.isConnected = false
        client.tap(.tackGybe, now: 10_000)
        client.update(now: 20_000)
        transport.isConnected = true
        client.update(now: 30_000)
        #expect(!transport.outbox.contains { if case .inputTap = $0.message { true } else { false } })
    }

    /// The lead falls when the link gets faster: through the measured target, as the slow samples
    /// leave the clock-sync window, at up to 8 ticks a second.
    @Test func theLeadFallsWhenTheLatencyDrops() throws {
        let harness = try Harness(uplink: LinkFaults(delay: 200_000), downlink: LinkFaults(delay: 200_000), linkSeed: 8)
        harness.run(for: 10_000_000)
        let high = harness.client.lead.lead
        harness.link.uplink.delay = 40_000
        harness.link.downlink.delay = 40_000
        var leads: [Double] = []
        harness.run(for: 25_000_000) { h, _ in leads.append(h.client.lead.lead) }
        let low = harness.client.lead.lead
        let target = 40_000 / ClockSync.tickMicros + 1
        print("REGRESSION lead falls: \(high) at 200 ms, \(low) at 40 ms (target \(target)); late \(harness.host.arrivals.filter { $0.margin < 0 }.count)")
        #expect(abs(high - (200_000 / ClockSync.tickMicros + 1)) < 1)
        #expect(abs(low - target) < 0.5)
        // Never faster than 8 ticks a second: frames land on the 1 ms grid, so at most 17 ms apart.
        #expect(zip(leads, leads.dropFirst()).allSatisfy { $0 - $1 <= 8.0 * 0.017 + 1e-9 })
        #expect(harness.host.arrivals.allSatisfy { $0.margin >= 0 })
    }
}
