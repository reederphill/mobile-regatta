import Testing
import RegattaBots
import RegattaClient
import RegattaCore
import RegattaProtocol
@testable import Regatta

/// The online driver (#68) against `FakeRaceServer` over a `FaultInjectingLink`, on a virtual clock: the
/// server polls every millisecond, the app draws at 60 Hz.
@MainActor final class OnlineRig {
    /// The network between them: while it's down, a new connection fails at once.
    nonisolated final class Network {
        let link: FaultInjectingLink
        let server: FakeRaceServer
        var isUp = true
        private(set) var attempts = 0

        init(link: FaultInjectingLink, server: FakeRaceServer) {
            self.link = link
            self.server = server
        }

        func connect() -> RaceTransport {
            attempts += 1
            guard isUp else { return link.client }
            link.reconnect()
            server.accept(link.server)
            return link.client
        }
    }

    static let frame: UInt64 = 16_667
    static let token: [UInt8] = [1, 2, 3]

    let clock: VirtualClock
    let link: FaultInjectingLink
    let server: FakeRaceServer
    let network: Network
    let driver: OnlineDriver
    let session: GameSession
    /// Every event the driver handed the session, and when.
    private(set) var shown: [(time: UInt64, event: RaceEvent)] = []

    /// Seed 3's race, as the fake server sails it: a bot fouls another (port/starboard, 4 on 8) at tick
    /// −209, three seconds into the ten-second sequence.
    init(seed: UInt64 = 3, uplink: LinkFaults = .none, downlink: LinkFaults = .none) throws {
        let clock = VirtualClock(now: 1_000_000)
        let link = FaultInjectingLink(clock: clock, uplink: uplink, downlink: downlink, seed: 1)
        let server = try FakeRaceServer(seed: seed, transport: link.server, clock: clock)
        let network = Network(link: link, server: server)
        let join = RaceJoin(connection: link.client, token: Self.token, clientBuild: "test", now: clock.now)
        while !join.isFinished {
            clock.advance(by: 1000)
            server.poll()
            join.poll(now: clock.now)
        }
        guard case .joined(let start) = join.state, let transport = join.transport else {
            throw RigError.notJoined(join.state)
        }
        (self.clock, self.link, self.server, self.network) = (clock, link, server, network)
        driver = OnlineDriver(start: start, transport: transport, token: Self.token, clientBuild: "test",
                              now: { clock.now }, connect: { network.connect() })
        session = GameSession(online: driver)
    }

    enum RigError: Error { case notJoined(RaceJoin.State) }

    /// Runs for `micros`, calling `frame` after each display frame; stops early when it returns true.
    func run(for micros: UInt64, until done: (UInt64) -> Bool = { _ in false }) {
        let end = clock.now + micros
        var next = clock.now
        while clock.now < end {
            clock.advance(by: 1000)
            server.poll()
            guard clock.now >= next else { continue }
            next += Self.frame
            driver.tick(Double(Self.frame) / 1_000_000)
            let events = driver.drainEvents()
            shown += events.map { (clock.now, $0) }
            session.consume(events)
            session.refreshHUD()
            if done(clock.now) { return }
        }
    }
}

@MainActor @Suite struct OnlineDriverTests {
    private static func isRuleCall(_ event: RaceEvent) -> Bool {
        if case .ruleCall = event.kind { true } else { false }
    }

    /// Injected delay (acceptance): with 300 ms on the way down, the prediction sails past the tick of the
    /// server's rule call well before the call arrives, and nothing is shown until it does, then exactly
    /// the server's call.
    @Test func injectedDelayShowsNoRuleCallBeforeTheServerEvent() throws {
        let delay: UInt64 = 300_000
        let rig = try OnlineRig(uplink: LinkFaults(delay: 40_000, inOrder: true), downlink: LinkFaults(delay: delay, inOrder: true))
        var predictedTicks: [(time: UInt64, tick: Int)] = []
        var ruleMessagesBeforeTheCall = 0
        rig.run(for: 8_000_000) { now in
            predictedTicks.append((now, rig.driver.client.predicted.tick))
            if !rig.shown.contains(where: { Self.isRuleCall($0.event) }) {
                ruleMessagesBeforeTheCall += rig.session.messages.filter { $0.text.contains("Rule") || $0.text.contains("fouled") }.count
            }
            return false
        }

        let sent = try #require(rig.server.sentEvents.first { Self.isRuleCall($0.event) }, "the server's race makes a rule call")
        let shown = try #require(rig.shown.first { Self.isRuleCall($0.event) }, "the server's call is shown")
        #expect(shown.event == sent.event)
        #expect(shown.time >= sent.time + delay, "shown \(shown.time - sent.time) µs after the server sent it")
        let passed = try #require(predictedTicks.first { $0.tick >= sent.event.tick })
        #expect(passed.time + delay <= shown.time, "the prediction was at the call's tick \(shown.time - passed.time) µs before it was shown")
        #expect(ruleMessagesBeforeTheCall == 0)
        #expect(rig.session.messages.contains { $0.text.contains("fouled") }, "the session shows the server's call")
    }

    /// Fault-injected transport (acceptance): the connection drops mid-race, after the gun. The driver
    /// rejoins on a new connection with the same token once the network is back, the client asks for a
    /// `Resync` and sails from it, and the helm set as it lands is applied by the server within one
    /// snapshot interval (plus the client's lead) of the server tick the resync reached the client at.
    @Test func disconnectMidRaceReconnectsWithAResyncAndControlResumesWithinOneSnapshot() throws {
        let rig = try OnlineRig(uplink: LinkFaults(delay: 20_000, inOrder: true), downlink: LinkFaults(delay: 20_000, inOrder: true))
        rig.run(for: 12_000_000)
        #expect(rig.driver.currentFrame.tick > 0, "racing after the gun")
        #expect(rig.driver.connection == .connected)

        rig.network.isUp = false
        rig.link.disconnect()
        rig.run(for: 3_000_000)
        #expect(rig.driver.connection == .reconnecting)
        #expect(rig.driver.client.status == .disconnected)
        #expect(rig.network.attempts >= 2, "it keeps trying while the network is down")
        let resyncsBefore = rig.driver.client.stats.resyncsApplied

        rig.network.isUp = true
        var resyncAt: UInt64?
        rig.run(for: 3_000_000) { now in
            guard rig.driver.client.stats.resyncsApplied > resyncsBefore else { return false }
            resyncAt = now
            return true
        }
        let landed = try #require(resyncAt, "a resync after the reconnect")
        #expect(rig.server.joins == 2)
        #expect(rig.driver.reconnects == 1)
        #expect(rig.driver.client.status == .predicting, "sailing from the resync at once")
        #expect(rig.driver.connection == .connected)

        let helm = BoatInput(rudder: 0.5)
        rig.driver.submit(helm)
        rig.run(for: 1_000_000) { _ in rig.server.appliedHeld.contains { $0.rudder == helm.rudder } }
        let applied = try #require(rig.server.appliedHeld.first { $0.rudder == helm.rudder }, "the helm reaches the server")
        let resumedWithin = Double(applied.tick) - rig.server.serverTick(at: landed)
        #expect(resumedWithin <= Double(FakeRaceServer.snapshotEvery) + rig.driver.client.lead.lead,
                "applied \(resumedWithin) ticks after the resync landed, lead \(rig.driver.client.lead.lead)")
        #expect(rig.driver.connection == .connected)
    }

    /// `Hello` carries the simulation version and the bundled data files' refs; `UpdateRequired` ends the
    /// join at the update prompt.
    @Test func helloCarriesTheVersionAndFilesAndUpdateRequiredEndsTheJoin() throws {
        let clock = VirtualClock()
        let link = FaultInjectingLink(clock: clock, seed: 1)
        let server = try FakeRaceServer(seed: 3, transport: link.server, clock: clock)
        server.refusesUpdate = .simulationVersion
        var sent: [Frame] = []
        link.onSend = { direction, _, bytes in
            if direction == .uplink, let frame = try? Frame(decoding: bytes) { sent.append(frame) }
        }
        let join = RaceJoin(connection: link.client, token: [9], clientBuild: "test", now: clock.now)
        for _ in 0..<10 {
            clock.advance(by: 1000)
            server.poll()
            join.poll(now: clock.now)
        }
        #expect(join.state == .updateRequired(.simulationVersion))
        #expect(join.transport == nil)
        guard case .hello(let hello) = sent.first?.message else {
            Issue.record("first frame isn't Hello: \(String(describing: sent.first))")
            return
        }
        #expect(hello.simulationVersion == RegattaCore.simulationVersion)
        #expect(hello.files == RaceJoin.bundledFiles)
        #expect(Set(hello.files.map(\.id)) == ["ilca-dinghy", "classic-oscillating", "fleet-rules"])
        #expect(sent.count == 1, "no JoinRace after UpdateRequired")
    }

    @Test func aJoinWithNoAnswerTimesOut() {
        let clock = VirtualClock()
        let link = FaultInjectingLink(clock: clock, seed: 1)
        let join = RaceJoin(connection: link.client, token: [9], clientBuild: "test", now: clock.now)
        clock.advance(by: RaceJoin.timeout - 1)
        join.poll(now: clock.now)
        #expect(!join.isFinished)
        clock.advance(by: 1)
        join.poll(now: clock.now)
        #expect(join.state == .failed("no answer from the server"))
    }

    /// A rejoin the server answers with `UpdateRequired` stops the retries, and the race says so.
    @Test func updateRequiredOnARejoinStopsRetrying() throws {
        let rig = try OnlineRig()
        rig.run(for: 2_000_000)
        rig.server.refusesUpdate = .protocolVersion
        rig.link.disconnect()
        rig.run(for: 3_000_000)
        #expect(rig.driver.connection == .updateRequired(.protocolVersion))
        #expect(rig.network.attempts == 1)
        #expect(rig.session.messages.contains { $0.text.contains("Update Regatta") })
    }

    /// The server's close ends the race for the player: the results, no more ticks, no rejoin.
    @Test func theServersCloseEndsTheRace() throws {
        let rig = try OnlineRig()
        rig.run(for: 2_000_000)
        rig.server.close()
        rig.run(for: 200_000)
        rig.link.disconnect()
        rig.run(for: 2_000_000)
        #expect(rig.driver.connection == .closed)
        #expect(rig.driver.currentFrame.isOver)
        #expect(rig.session.playerDone)
        #expect(rig.shown.filter { $0.event.kind == .raceClosed }.count == 1)
        #expect(rig.network.attempts == 0)
        #expect(!rig.driver.tap(.tackGybe))
    }

    @Test func isNotPausable() throws {
        let rig = try OnlineRig()
        #expect(!rig.driver.isPausable)
        rig.session.setPaused(true)
        #expect(!rig.session.isPaused)
    }

    /// Round trips over 250 ms for about 5 s raise the lag warning; under it, none.
    @Test(arguments: [(150_000 as UInt64, true), (100_000, false)])
    func lagWarningAfterFiveSecondsOver250Milliseconds(oneWay: UInt64, warns: Bool) throws {
        let faults = LinkFaults(delay: oneWay, inOrder: true)
        let rig = try OnlineRig(uplink: faults, downlink: faults)
        rig.run(for: 4_000_000)
        #expect(!rig.driver.lagWarning, "not before about 5 s")
        rig.run(for: 3_000_000)
        #expect(rig.driver.lagWarning == warns)
    }

    @Test func lagMonitorWarnsOnAStalledConnection() {
        var clock = ClockSync()
        var monitor = LagMonitor()
        _ = clock.pingIfDue(now: 0)
        clock.receive(Pong(clientTime: 0, sinceTickMicros: 0), tick: 0, now: 50_000)
        monitor.record(clock, now: 50_000)
        #expect(!monitor.isWarning)
        monitor.record(clock, now: 50_000 + clock.interval + LagMonitor.threshold + 1)
        #expect(monitor.overSince != nil)
        monitor.record(clock, now: 50_000 + clock.interval + LagMonitor.threshold + 1 + LagMonitor.sustain)
        #expect(monitor.isWarning)
        clock.receive(Pong(clientTime: 6_000_000, sinceTickMicros: 0), tick: 180, now: 6_100_000)
        monitor.record(clock, now: 6_100_000)
        #expect(!monitor.isWarning, "a quick pong clears it")
    }

    /// A correction eases: right after a snapshot moves a boat, it's drawn where it was carried on to, not
    /// where the prediction jumped.
    @Test func snapshotCorrectionsAreEasedNotJumped() throws {
        let rig = try OnlineRig(uplink: LinkFaults(delay: 30_000, jitter: 20_000, inOrder: true),
                                downlink: LinkFaults(delay: 30_000, jitter: 20_000, inOrder: true))
        var worstJump = 0.0
        var previous: [Vec2]?
        rig.run(for: 14_000_000) { _ in
            let drawn = rig.driver.renderWorld.boats.map(\.position)
            if let previous {
                for (a, b) in zip(previous, drawn) { worstJump = max(worstJump, (b - a).length) }
            }
            previous = drawn
            return false
        }
        // A boat at 5 m/s covers under 0.1 m a frame; a hull length is 4.2 m.
        #expect(worstJump < rig.driver.boatClass.hull.length / 2, "worst jump between frames \(worstJump) m")
    }
}
