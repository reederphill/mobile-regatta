import Foundation
import Persistence
import RegattaProtocol
import RegattaServerKit
import RegattaServiceClient
import RegattaServices
import Synchronization
import Testing

/// The #145 review's hardening of the service endpoint: one gate in front of every service, deny by default; the
/// last online session time moving with use; a cap on open streams.
@Suite(.timeLimit(.minutes(1))) struct ServiceEndpointHardeningTests {
    /// Every gated request a connection can make that has no refusal shape of its own: race sessions, profile,
    /// analytics. (Data deletion needs only the sign-in: `deletionNeedsOnlyTheSignIn`.)
    static let ungatedShapes: [(String, Message)] = [
        ("race session", .raceSessionRequest(ServiceRequest(id: 7, call: .openResults))),
        ("profile", .profileRequest(ServiceRequest(id: 7, call: .profile))),
        ("analytics", .analyticsRequest(ServiceRequest(id: 7, call: WireAnalyticsBatch(installID: "i", events: [])))),
    ]

    private static func send(_ message: Message, on link: InProcessServiceLink) async throws {
        await link.handler.receive(try Frame(seq: 9, tick: 0, message: message).encoded())
    }

    /// Signed out or terms unaccepted, each of them is refused before its service is looked up; with the terms
    /// accepted the same request gets past the gate (to the missing backend, which closes as before).
    @Test func everyServiceWithoutItsOwnRefusalIsDeniedByDefault() async throws {
        for (name, message) in Self.ungatedShapes {
            let endpoint = ServiceFixtures.endpoint()
            let signedOut = try await InProcessServiceLink.open(endpoint)
            try await Self.send(message, on: signedOut)
            #expect(signedOut.closeReason == "\(name) refused: not signed in")

            // (The connection is held: dropping it closes the link.)
            let (unaccepted, held, _) = try await ServiceFixtures.signedIn(endpoint, "u-\(name)")
            try await Self.send(message, on: unaccepted)
            #expect(unaccepted.closeReason == "\(name) refused: terms not accepted")
            withExtendedLifetime(held) {}

            let (accepted, connection, _) = try await ServiceFixtures.signedIn(endpoint, "a-\(name)")
            _ = try await RemoteTermsService(connection).accept(TermsVersion(1))
            try await Self.send(message, on: accepted)
            #expect(accepted.closeReason == "no \(name) service")
            withExtendedLifetime(connection) {}
        }
    }

    /// Owner ruling (2026-10-08): "Delete my online data" needs only the sign-in. Refused signed out; signed in, it
    /// gets past the gate (to the missing backend) with the terms unaccepted and the player restricted.
    @Test func deletionNeedsOnlyTheSignIn() async throws {
        let message = Message.deletionRequest(ServiceRequest(id: 7, call: .plan))
        let endpoint = ServiceFixtures.endpoint()
        let signedOut = try await InProcessServiceLink.open(endpoint)
        try await Self.send(message, on: signedOut)
        #expect(signedOut.closeReason == "deletion refused: not signed in")

        let (unaccepted, held, _) = try await ServiceFixtures.signedIn(endpoint, "u-deletion", multiplayerRestricted: true)
        try await Self.send(message, on: unaccepted)
        #expect(unaccepted.closeReason == "no deletion service")
        withExtendedLifetime(held) {}
    }

    @Test func aRaceSessionIsDeniedToAMultiplayerRestrictedPlayer() async throws {
        let endpoint = ServiceFixtures.endpoint()
        let (link, connection, _) = try await ServiceFixtures.signedIn(endpoint, "kid", multiplayerRestricted: true)
        _ = try await RemoteTermsService(connection).accept(TermsVersion(1))
        try await Self.send(.raceSessionRequest(ServiceRequest(id: 7, call: .openResults)), on: link)
        #expect(link.closeReason == "race session refused: multiplayer restricted")
    }

    /// G8: the last online session time moves when the player uses the queue (or the lobby, or a race), not only at
    /// sign-in, at most once per `sessionTouchInterval`.
    @Test func theLastSessionTimeMovesWithQueueUse() async throws {
        let start = Date(timeIntervalSince1970: 1_791_460_800)
        let clock = Mutex(start)
        let store = InMemoryAccountStore()
        let queue = RecordingQueue()
        let endpoint = ServiceEndpoint(
            config: ServiceEndpointConfig(sessionTouchInterval: 3_600),
            sessions: SessionAuthority(store: store, verifier: StubVerifier(), now: { clock.withLock { $0 } }),
            backends: ServiceBackends(queue: { _ in queue }))
        let (_, connection, _) = try await ServiceFixtures.signedIn(endpoint, "gale")
        #expect(await store.lastSession["T:gale"] == start)
        _ = try await RemoteTermsService(connection).accept(TermsVersion(1))

        clock.withLock { $0 = start.addingTimeInterval(600) }
        try await RemoteQueueService(connection).join()
        #expect(await store.lastSession["T:gale"] == start)

        clock.withLock { $0 = start.addingTimeInterval(7_200) }
        try await RemoteQueueService(connection).join()
        #expect(await store.lastSession["T:gale"] == start.addingTimeInterval(7_200))
        #expect(await queue.joins == 2)

        // A refused call isn't use.
        clock.withLock { $0 = start.addingTimeInterval(20_000) }
        let (_, other, _) = try await ServiceFixtures.signedIn(endpoint, "hal")
        clock.withLock { $0 = start.addingTimeInterval(30_000) }
        await #expect(throws: QueueError.refused(.termsNotAccepted)) { try await RemoteQueueService(other).join() }
        #expect(await store.lastSession["T:hal"] == start.addingTimeInterval(20_000))
    }

    @Test func openStreamsAreCappedPerConnection() async throws {
        let endpoint = ServiceEndpoint(
            config: ServiceEndpointConfig(maxOpenStreams: 16, maxOpenStreamsBeforeSignIn: 4),
            sessions: SessionAuthority(store: InMemoryAccountStore(), verifier: StubVerifier()))
        let open = { (id: UInt32) in Message.identityRequest(ServiceRequest(id: id, call: .openStateUpdates)) }

        let signedOut = try await InProcessServiceLink.open(endpoint)
        for id in UInt32(1)...4 { try await Self.send(open(id), on: signedOut) }
        #expect(await signedOut.handler.openStreamCount == 4)
        #expect(signedOut.closeReason == nil)
        try await Self.send(open(5), on: signedOut)
        #expect(signedOut.closeReason == "more than 4 streams open")

        // (The connection is held: dropping it closes the link.)
        let (signedIn, held, _) = try await ServiceFixtures.signedIn(endpoint, "ivy")
        for id in UInt32(100)...115 { try await Self.send(open(id), on: signedIn) }
        #expect(await signedIn.handler.openStreamCount == 16)
        #expect(signedIn.closeReason == nil)
        try await Self.send(open(116), on: signedIn)
        #expect(signedIn.closeReason == "more than 16 streams open")
        withExtendedLifetime(held) {}
    }
}
