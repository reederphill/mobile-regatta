import Crypto
import Foundation
import RegattaContractRunner
import RegattaCore
import RegattaLoadClient
import RegattaProtocol
@testable import RegattaServerKit
import RegattaServiceClient
import RegattaServices
import Testing

/// #146: the queue and the race hand-off behind `/service`, in process and over the real server.
@Suite(.timeLimit(.minutes(2))) struct QueueEndpointTests {
    /// Acceptance: a client on another simulation version is refused with `UpdateRequired` at `Hello`, before it can
    /// reach the queue (#18; #146 Q2: the check is the connection's, not a field of the join).
    @Test func aMismatchedSimulationVersionIsRefusedWithUpdateRequired() async throws {
        do {
            _ = try await InProcessServiceLink.open(ServiceFixtures.endpoint(),
                                                    hello: Hello(clientBuild: "old", simulationVersion: "0/old", files: []))
            Issue.record("a client on simulation 0/old was let in")
        } catch let refused as InProcessServiceLink.HandshakeRefused {
            guard case .updateRequired(let update)? = refused.frames.first else {
                Issue.record("no UpdateRequired: \(refused.frames)")
                return
            }
            #expect(update.reason == .simulationVersion)
            #expect(refused.closed)
        }
    }

    private static func endpoint(_ matchmaker: QueueMatchmaker) -> ServiceEndpoint {
        ServiceEndpoint(
            config: ServiceEndpointConfig(),
            sessions: SessionAuthority(store: InMemoryAccountStore(), verifier: StubVerifier()),
            backends: ServiceBackends(queue: { ServerQueueService(matchmaker: matchmaker, player: $0) },
                                      raceSession: { ServerRaceSessionService(matchmaker: matchmaker, player: $0) }),
            matchmaker: matchmaker)
    }

    /// Join, fleet lock, hand-off: the token is for the player's seat in the race the matchmaker launched.
    @Test func aPlayerQueuesLocksAndIsHandedOffOverTheEndpoint() async throws {
        let clock = VirtualClock(), log = LaunchLog()
        let matchmaker = QueueMatchmakerTests.make(clock, log)
        let endpoint = Self.endpoint(matchmaker)
        let (_, connection, _) = try await ServiceFixtures.signedIn(endpoint, "sailor")
        let queue = RemoteQueueService(connection), race = RemoteRaceSessionService(connection)
        await #expect(throws: QueueError.refused(.termsNotAccepted)) { try await queue.join() }
        _ = try await RemoteTermsService(connection).accept(TermsVersion(1))
        await #expect(throws: RaceSessionError.noRace) { try await race.handOff() }

        var states = queue.stateUpdates().makeAsyncIterator()
        #expect(await states.next() == .idle)
        try await queue.join()
        #expect(await states.next() == .queued(QueuedStatus(queuedPlayers: 1, secondsToLock: 60)))
        clock.advance(60)
        await matchmaker.step()
        #expect(await states.next() == .fleetLocked)

        let fleet = try #require(await log.fleets.first)
        let handOff = try await race.handOff()
        let token = try RaceToken.verify(handOff.token.bytes, key: QueueMatchmakerTests.key, now: Int64(clock.now.timeIntervalSince1970))
        #expect(token.raceID == fleet.raceID)
        #expect(token.seat == 0)
        await #expect(throws: RaceSessionError.noRace) { try await race.rejoin() }
    }

    @Test func aConnectionThatEndsLeavesTheQueue() async throws {
        let clock = VirtualClock(), log = LaunchLog()
        let matchmaker = QueueMatchmakerTests.make(clock, log)
        let endpoint = Self.endpoint(matchmaker)
        let (link, connection, _) = try await ServiceFixtures.signedIn(endpoint, "brief")
        _ = try await RemoteTermsService(connection).accept(TermsVersion(1))
        try await RemoteQueueService(connection).join()
        #expect(await matchmaker.queuedCount == 1)
        link.close()
        let deadline = ContinuousClock.now + .seconds(5)
        repeat {
            if await matchmaker.queuedCount == 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        #expect(await matchmaker.queuedCount == 0)
    }

    /// The whole hand-off over the real server: queue on `/service`, fleet lock, the race token, and the seat taken on
    /// `/race` in the race the queue started (RaceHost).
    @Test func aHandedOffTokenTakesItsSeatInTheRace() async throws {
        var config = ServerConfig.dev()
        config.queue.lockAfter = 1
        let server = try await RegattaHTTPServer.start(config: config)
        do {
            let endpoint = "ws://127.0.0.1:\(server.port)"
            let link = try await WebSocketServiceConnector().connect(to: endpoint, service: "QueueService", situation: "joinable")
            let connection = ServiceConnection(link)
            let queue = RemoteQueueService(connection)
            var states = queue.stateUpdates().makeAsyncIterator()
            #expect(await states.next() == .idle)
            try await queue.join()
            var state = await states.next()
            while case .queued = state { state = await states.next() }
            #expect(state == .fleetLocked)
            let handOff = try await RemoteRaceSessionService(connection).handOff()
            #expect(await server.registry.count == 1)

            let transport = try await WebSocketRaceTransport.connect(host: "127.0.0.1", port: server.port, clock: { 0 })
            transport.send(try Frame(seq: 1, tick: 0, message: .hello(Hello(clientBuild: "test", files: []))).encoded())
            transport.send(try Frame(seq: 2, tick: 0, message: handOff.token.joinRace.message).encoded())
            var types: [MessageType] = []
            for _ in 0..<500 where !types.contains(.raceStart) && transport.isConnected {
                types += try transport.receive().map { try Frame(decoding: $0).message.type }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(types.contains(.raceStart))
            await transport.close()
        } catch {
            await server.shutdown()
            throw error
        }
        await server.shutdown()
    }
}

extension JoinRace {
    var message: Message { .joinRace(self) }
}
