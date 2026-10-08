import Foundation
import Persistence
import RegattaCore
import RegattaProtocol
import RegattaServerKit
import RegattaServiceClient
import RegattaServices
import Testing

/// The service endpoint (#145) in process, accounts in memory: the handshake, sessions, the Terms gate and the
/// streams. `ServiceEndpointPersistenceTests` runs the gate against Postgres.
@Suite(.timeLimit(.minutes(1))) struct ServiceEndpointTests {
    @Test func helloIsAnsweredHelloAckAndAnOtherProtocolVersionUpdateRequired() async throws {
        _ = try await InProcessServiceLink.open(ServiceFixtures.endpoint())
        do {
            _ = try await InProcessServiceLink.open(ServiceFixtures.endpoint(), hello: Hello(protocolVersion: 99, clientBuild: "old", files: []))
            Issue.record("protocol 99 was let in")
        } catch let refused as InProcessServiceLink.HandshakeRefused {
            guard case .updateRequired(let update)? = refused.frames.first else {
                Issue.record("no UpdateRequired: \(refused.frames)")
                return
            }
            #expect(update.reason == .protocolVersion)
            #expect(refused.closed)
        }
    }

    @Test func aRaceMessageOnTheServiceConnectionClosesIt() async throws {
        let link = try await InProcessServiceLink.open(ServiceFixtures.endpoint())
        await link.handler.receive(try Frame(seq: 2, tick: 0, message: .ping(Ping(clientTime: 1))).encoded())
        #expect(link.closeReason != nil)
    }

    @Test func signingInOpensASessionThatResumesOnALaterConnection() async throws {
        let store = InMemoryAccountStore()
        let endpoint = ServiceFixtures.endpoint(store: store)
        let (_, connection, session) = try await ServiceFixtures.signedIn(endpoint, "alice")
        #expect(session.player.gamePlayerID == GamePlayerID("G:alice"))
        #expect(session.token.count == 32)
        let identity = RemoteIdentityService(connection)
        #expect(await identity.state() == .signedIn(session.player))
        let signature = try await identity.identitySignature()
        #expect(signature.teamPlayerID == "T:alice")
        #expect(await store.lastSession["T:alice"] != nil)

        let later = ServiceConnection(try await InProcessServiceLink.open(endpoint))
        let resumed = try await RemoteSession(later).resume(token: session.token, as: ServiceFixtures.player("alice"))
        #expect(resumed.player == session.player)
        #expect(await RemoteIdentityService(later).gamePlayerID() == GamePlayerID("G:alice"))

        try await RemoteSession(later).signOut()
        #expect(await RemoteIdentityService(later).state() == .signedOut)
        let after = ServiceConnection(try await InProcessServiceLink.open(endpoint))
        await #expect(throws: SessionError.refused(.sessionExpired)) {
            try await RemoteSession(after).resume(token: session.token, as: ServiceFixtures.player("alice"))
        }
    }

    @Test func badAndStaleSignaturesAreRefused() async throws {
        let connection = ServiceConnection(try await InProcessServiceLink.open(ServiceFixtures.endpoint()))
        let session = RemoteSession(connection)
        await #expect(throws: SessionError.refused(.invalidSignature)) {
            try await session.signIn(ServiceFixtures.signature("bob", signature: [0]), as: ServiceFixtures.player("bob"))
        }
        await #expect(throws: SessionError.refused(.staleSignature)) {
            try await session.signIn(ServiceFixtures.signature("bob", signature: [1]), as: ServiceFixtures.player("bob"))
        }
        // The player must be the signature's gamePlayerID.
        await #expect(throws: SessionError.refused(.invalidSignature)) {
            try await session.signIn(ServiceFixtures.signature("bob"), as: ServiceFixtures.player("carol"))
        }
        #expect(await RemoteIdentityService(connection).state() == .signedOut)
    }

    /// Acceptance (#145): a second teamPlayerID claiming an already-bound gamePlayerID is refused.
    @Test func aSecondTeamPlayerIDClaimingABoundGamePlayerIDIsRefused() async throws {
        let endpoint = ServiceFixtures.endpoint()
        _ = try await ServiceFixtures.signedIn(endpoint, "alice")
        let connection = ServiceConnection(try await InProcessServiceLink.open(endpoint))
        await #expect(throws: SessionError.refused(.gamePlayerIDConflict)) {
            try await RemoteSession(connection).signIn(ServiceFixtures.signature("alice", team: "T:mallory"), as: ServiceFixtures.player("alice"))
        }
    }

    /// Acceptance (#145): an unaccepted player can't open the queue or post; accepting opens both; bumping
    /// `termsVersion` re-gates.
    @Test func theTermsGateTheQueueAndTheLobby() async throws {
        try await GateScenario.run(store: InMemoryAccountStore())
    }

    @Test func signedOutAndRestrictedConnectionsAreTurnedAway() async throws {
        let queue = RecordingQueue()
        let endpoint = ServiceFixtures.endpoint(queue: queue)
        let signedOut = ServiceConnection(try await InProcessServiceLink.open(endpoint))
        await #expect(throws: QueueError.refused(.notSignedIn)) { try await RemoteQueueService(signedOut).join() }
        await #expect(throws: LobbyError.closed(.notSignedIn)) { try await RemoteLobbyService(signedOut).post("hi") }

        let (_, restricted, _) = try await ServiceFixtures.signedIn(endpoint, "kid", multiplayerRestricted: true, underage: true)
        _ = try await RemoteTermsService(restricted).accept(TermsVersion(1))
        await #expect(throws: QueueError.refused(.multiplayerRestricted)) { try await RemoteQueueService(restricted).join() }
        #expect(try await RemoteLobbyService(restricted).state().access == .closed(.communicationRestricted))
        #expect(await queue.joins == 0)
    }

    /// Terms on the wire: never accepted, a stale version refused, the current one recorded.
    @Test func termsAcceptanceIsRecordedForTheCurrentVersionOnly() async throws {
        let endpoint = ServiceFixtures.endpoint(termsVersion: 3)
        let (_, connection, _) = try await ServiceFixtures.signedIn(endpoint, "dana")
        let terms = RemoteTermsService(connection)
        #expect(try await terms.status() == .needsAcceptance(current: TermsVersion(3), lastAccepted: nil))
        await #expect(throws: TermsError.staleVersion(current: TermsVersion(3))) { try await terms.accept(TermsVersion(2)) }
        #expect(try await terms.accept(TermsVersion(3)) == .accepted(TermsVersion(3)))
    }

    /// A `StreamNext` with nothing to read doesn't hold up the requests behind it; a server-side change (signing out)
    /// reaches it when it happens.
    @Test func aWaitingStreamNextDoesntBlockRequests() async throws {
        let (_, connection, session) = try await ServiceFixtures.signedIn(ServiceFixtures.endpoint(), "erin")
        var updates = RemoteIdentityService(connection).stateUpdates().makeAsyncIterator()
        #expect(await updates.next() == .signedIn(session.player))
        async let next = updates.next()
        // The read above is waiting on the server; these go through regardless.
        #expect(try await RemoteTermsService(connection).status().isAccepted == false)
        try await RemoteSession(connection).signOut()
        #expect(await next == .signedOut)
    }

    @Test func aStreamNobodyReadsIsDroppedAfterTheIdleTimeout() async throws {
        let endpoint = ServiceFixtures.endpoint(idle: .milliseconds(200))
        let (link, connection, _) = try await ServiceFixtures.signedIn(endpoint, "finn")
        var updates = RemoteIdentityService(connection).stateUpdates().makeAsyncIterator()
        _ = await updates.next()
        #expect(await link.handler.openStreamCount == 1)
        try await Task.sleep(for: .milliseconds(600))
        #expect(await link.handler.openStreamCount == 0)
        // Read again: the server has dropped it, so the stream ends.
        #expect(await updates.next() == nil)
    }

    @Test func aFrameOverTheCapClosesTheConnection() async throws {
        let link = try await InProcessServiceLink.open(ServiceFixtures.endpoint(frameCap: 64))
        let batch = try Frame(seq: 2, tick: 0, message: .lobbyRequest(ServiceRequest(id: 1, call: .postText(String(repeating: "x", count: 200)))))
            .encoded()
        await link.handler.receive(batch)
        #expect(link.closeReason == "frame over the cap")
    }
}

/// The Terms gate, the same against either store.
enum GateScenario {
    static func run(store: any AccountStore) async throws {
        let queue = RecordingQueue()
        let v1 = ServiceFixtures.endpoint(store: store, termsVersion: 1, queue: queue)
        let name = "gate-\(UUID().uuidString.prefix(8))"
        let (_, connection, _) = try await ServiceFixtures.signedIn(v1, name)

        // Not accepted: the queue refuses with the Terms reason, its state says so, and the lobby is closed.
        await #expect(throws: QueueError.refused(.termsNotAccepted)) { try await RemoteQueueService(connection).join() }
        var states = RemoteQueueService(connection).stateUpdates().makeAsyncIterator()
        #expect(await states.next() == .unavailable(.termsNotAccepted))
        await #expect(throws: LobbyError.closed(.termsNotAccepted)) { try await RemoteLobbyService(connection).post("hello") }
        await #expect(throws: LobbyError.closed(.termsNotAccepted)) { try await RemoteLobbyService(connection).post(.goodRace) }
        #expect(try await RemoteLobbyService(connection).state().access == .closed(.termsNotAccepted))
        #expect(await queue.joins == 0)

        // Accepted: through to the queue.
        _ = try await RemoteTermsService(connection).accept(TermsVersion(1))
        try await RemoteQueueService(connection).join()
        #expect(await queue.joins == 1)

        // The terms change: version 2 re-gates the same player on a new connection.
        let v2 = ServiceFixtures.endpoint(store: store, termsVersion: 2, queue: queue)
        let (_, bumped, _) = try await ServiceFixtures.signedIn(v2, name)
        await #expect(throws: QueueError.refused(.termsNotAccepted)) { try await RemoteQueueService(bumped).join() }
        #expect(try await RemoteTermsService(bumped).status() == .needsAcceptance(current: TermsVersion(2), lastAccepted: TermsVersion(1)))
        _ = try await RemoteTermsService(bumped).accept(TermsVersion(2))
        try await RemoteQueueService(bumped).join()
        #expect(await queue.joins == 2)
    }
}
