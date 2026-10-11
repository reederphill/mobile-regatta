import Foundation
import NIOCore
import NIOHTTP1
import Persistence
import RegattaLoadClient
import RegattaProtocol
@testable import RegattaServerKit
import RegattaServiceClient
import RegattaServices
import Synchronization
import Testing

/// #145's review, left for #146 before the queue and race backends go live on `/service`: deadlines and connection
/// caps (R4), pending reads that never outlive their stream or connection (R6), and sessions with an absolute lifetime,
/// a per-player cap, a sweep, and one per connection (R11).
@Suite(.timeLimit(.minutes(1))) struct ServiceEndpointLimitsTests {
    private static func send(_ message: Message, on link: InProcessServiceLink) async throws {
        await link.handler.receive(try Frame(seq: 9, tick: 0, message: message).encoded())
    }

    private static func endpoint(store: any AccountStore = InMemoryAccountStore(), signIn: Duration = .seconds(30),
                                 idle: Duration = .seconds(30), queue: (any QueueService)? = nil,
                                 sessions: SessionAuthority? = nil) -> ServiceEndpoint {
        ServiceEndpoint(
            config: ServiceEndpointConfig(signInDeadline: signIn, idleTimeout: idle),
            sessions: sessions ?? SessionAuthority(store: store, verifier: StubVerifier()),
            backends: ServiceBackends(queue: { _ in queue }))
    }

    /// Waits up to `limit` for `condition`, checking every 20 ms.
    private static func eventually(_ limit: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + limit
        repeat {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        return await condition()
    }

    // MARK: R4

    @Test func aConnectionThatDoesntSignInInTimeIsClosed() async throws {
        // No sleep here is compared against the deadline, as in the idle test below (#473, #469): the fixture used to
        // have to sign in inside a 200 ms deadline, which a loaded runner misses. The close is timed from before the
        // connection opened and must come no sooner than the deadline; the connection that signs in is checked after
        // its own deadline has certainly passed.
        let deadline = Duration.seconds(1)
        let endpoint = Self.endpoint(signIn: deadline)
        let opened = ContinuousClock.now
        let late = try await InProcessServiceLink.open(endpoint)
        let beforeSignIn = ContinuousClock.now
        // On a runner stalled past the whole deadline the sign-in itself comes too late and fails: then only that it
        // wasn't refused inside the deadline is checked.
        let prompt = try? await ServiceFixtures.signedIn(endpoint, "prompt")
        if prompt == nil {
            #expect(ContinuousClock.now - beforeSignIn >= deadline, "the sign-in failed on a connection inside its deadline")
        }
        #expect(await Self.eventually(.seconds(20)) { late.closeReason != nil })
        #expect(ContinuousClock.now - opened >= deadline, "closed before the sign-in deadline")
        #expect(late.closeReason == "no sign-in in time")
        if let (signedIn, held, _) = prompt {
            // Past the signed-in connection's own deadline, however late it opened: it stays.
            try await ContinuousClock().sleep(until: ContinuousClock.now + deadline + .milliseconds(200))
            #expect(signedIn.closeReason == nil)
            withExtendedLifetime(held) {}
        }
    }

    @Test func signingOutStartsTheSignInDeadlineAgain() async throws {
        let endpoint = Self.endpoint(signIn: .milliseconds(300))
        let (link, connection, _) = try await ServiceFixtures.signedIn(endpoint, "leaver")
        try await Task.sleep(for: .milliseconds(400))
        #expect(link.closeReason == nil)
        try await RemoteSession(connection).signOut()
        #expect(await Self.eventually { link.closeReason != nil })
        #expect(link.closeReason == "no sign-in in time")
    }

    @Test func aConnectionWithNoFramesForTheIdleTimeoutIsClosed() async throws {
        // No sleep here is compared against the timeout (a loaded CI runner stalled this test for over a second,
        // #473): the close is timed from the last moment a frame can have crossed, and must come no sooner.
        let idle = Duration.seconds(2)
        let endpoint = Self.endpoint(idle: idle)
        var quietSince = ContinuousClock.now
        // On a runner stalled past the whole timeout even the sign-in comes too late and finds the connection closed
        // (#493's CI run): then only that it wasn't closed inside the timeout is checked.
        guard let (link, connection, _) = try? await ServiceFixtures.signedIn(endpoint, "quiet") else {
            #expect(ContinuousClock.now - quietSince >= idle, "the sign-in failed on a connection that wasn't idle yet")
            return
        }
        // A request part-way through starts the timeout again. On a runner stalled past the whole timeout the
        // connection has already idled out and the request fails: then the close is timed from the sign-in.
        try await Task.sleep(for: .milliseconds(300))
        let beforeRequest = ContinuousClock.now
        if (try? await RemoteTermsService(connection).status()) != nil {
            #expect(link.closeReason == nil)
            quietSince = beforeRequest
        } else {
            #expect(beforeRequest - quietSince >= idle, "the request failed on a connection that wasn't idle yet")
        }
        #expect(await Self.eventually(.seconds(20)) { link.closeReason != nil })
        #expect(ContinuousClock.now - quietSince >= idle, "closed before the idle timeout")
        #expect(link.closeReason == "idle")
    }

    @Test func connectionCountsAreCappedPerAddressAndInAll() {
        let counter = ConnectionCounter(perAddress: 2, total: 3)
        let a = try? SocketAddress(ipAddress: "10.0.0.1", port: 1)
        let b = try? SocketAddress(ipAddress: "10.0.0.2", port: 1)
        let first = counter.acquire(a), second = counter.acquire(a)
        #expect(first != nil && second != nil)
        #expect(counter.acquire(a) == nil)
        let third = counter.acquire(b)
        #expect(third != nil)
        #expect(counter.acquire(b) == nil)
        first?.release()
        #expect(counter.acquire(b) != nil)
        #expect(counter.open.total == 3)
    }

    /// Over the socket: the third `/service` connection from one address is closed before it's read.
    @Test func theServerClosesAServiceConnectionOverItsAddressCap() async throws {
        var config = ServerConfig.dev()
        config.connectionLimits.servicePerAddress = 2
        let server = try await RegattaHTTPServer.start(config: config)
        defer { Task { await server.shutdown() } }
        func hello(_ link: WebSocketServiceLink) async throws -> Bool {
            link.send(try Frame(seq: 1, tick: 0, message: .hello(Hello(clientBuild: "test", files: []))).encoded())
            guard let reply = await link.nextOpeningFrame() else { return false }
            if case .helloAck = try Frame(decoding: reply).message { return true }
            return false
        }
        let one = try await WebSocketServiceLink.connect(host: "127.0.0.1", port: server.port)
        let two = try await WebSocketServiceLink.connect(host: "127.0.0.1", port: server.port)
        #expect(try await hello(one))
        #expect(try await hello(two))
        let three = try await WebSocketServiceLink.connect(host: "127.0.0.1", port: server.port)
        #expect(try await hello(three) == false)
        one.close()
        #expect(await Self.eventually { server.serviceConnections.open.total == 1 })
        let four = try await WebSocketServiceLink.connect(host: "127.0.0.1", port: server.port)
        #expect(try await hello(four))
        two.close()
        four.close()
    }

    // MARK: Behind a proxy (#469)

    private static let proxy = try? SocketAddress(ipAddress: "10.0.0.1", port: 443)

    /// No header is trusted by default: whatever a client sends, its connection counts under the socket's address.
    @Test func noForwardedAddressIsTrustedUnlessConfigured() {
        let headers = HTTPHeaders([("X-Forwarded-For", "203.0.113.7"), ("Fly-Client-IP", "203.0.113.7"), ("Forwarded", "for=203.0.113.7")])
        #expect(ClientAddressRule().key(remote: Self.proxy, headers: headers) == "10.0.0.1")
        #expect(ServerConfig.dev().clientAddress == ClientAddressRule())
        #expect(ServerConfig.dev().clientAddress.header == nil)
    }

    /// With the proxy's header named, the caps count the client the proxy vouches for: two clients behind one proxy
    /// have a cap each, where before they shared the proxy's.
    @Test func addressCapsCountTheForwardedClientNotTheProxy() {
        let rule = ClientAddressRule(header: "Fly-Client-IP")
        func key(_ client: String) -> String? { rule.key(remote: Self.proxy, headers: HTTPHeaders([("fly-client-ip", client)])) }
        #expect(key("203.0.113.7") == "203.0.113.7")
        let counter = ConnectionCounter(perAddress: 2, total: 10)
        let held = [counter.acquire(key: key("203.0.113.7")), counter.acquire(key: key("203.0.113.7"))]
        #expect(held.allSatisfy { $0 != nil })
        #expect(counter.acquire(key: key("203.0.113.7")) == nil)
        #expect(counter.acquire(key: key("198.51.100.9")) != nil)
        // By the socket's address, as before the setting, the third connection of all would have been refused.
        let unaware = ConnectionCounter(perAddress: 2, total: 10)
        #expect(unaware.acquire(Self.proxy) != nil && unaware.acquire(Self.proxy) != nil)
        #expect(unaware.acquire(Self.proxy) == nil)
        // A connection without the header, or with something that isn't an address, counts under the socket's.
        #expect(rule.key(remote: Self.proxy, headers: HTTPHeaders()) == "10.0.0.1")
        #expect(key("unknown") == "10.0.0.1")
        #expect(key("") == "10.0.0.1")
    }

    /// A list header: the entry the trusted proxies vouch for, counted from the right; what the client wrote to its
    /// left is never used.
    @Test func aForwardedListIsReadFromTheRightByTrustedHops() {
        let headers = HTTPHeaders([("X-Forwarded-For", "192.0.2.66, 203.0.113.7"), ("X-Forwarded-For", "198.51.100.9")])
        func key(_ hops: Int) -> String? {
            ClientAddressRule(header: "X-Forwarded-For", trustedHops: hops).key(remote: Self.proxy, headers: headers)
        }
        #expect(key(1) == "198.51.100.9")
        #expect(key(2) == "203.0.113.7")
        #expect(key(3) == "192.0.2.66")
        // Fewer entries than trusted proxies: not a request that came through them all.
        #expect(key(4) == "10.0.0.1")
        // The forms a proxy writes an address in.
        for (entry, expected) in [("203.0.113.7:4711", "203.0.113.7"), (" 203.0.113.7 ", "203.0.113.7"),
                                  ("[2001:db8:1:2::9]:4711", "2001:db8:1:2::/64"), ("2001:db8:1:2::9", "2001:db8:1:2::/64")] {
            #expect(ClientAddressRule(header: "X-Real-IP").key(remote: Self.proxy, headers: HTTPHeaders([("X-Real-IP", entry)])) == expected)
        }
    }

    /// An IPv6 client is capped by its /64: other addresses of the same prefix don't get a cap of their own.
    @Test func ipv6ClientsAreCappedByTheir64Prefix() throws {
        func address(_ text: String) throws -> SocketAddress { try SocketAddress(ipAddress: text, port: 1) }
        #expect(ClientAddressRule.key(try address("2001:db8:1:2::1")) == "2001:db8:1:2::/64")
        #expect(ClientAddressRule.key(try address("2001:db8:1:2:ffff:ffff:ffff:ffff")) == "2001:db8:1:2::/64")
        #expect(ClientAddressRule.key(try address("2001:db8:1:3::1")) == "2001:db8:1:3::/64")
        // IPv4, and IPv4 reaching a dual-stack socket, are the IPv4 address either way.
        #expect(ClientAddressRule.key(try address("::ffff:10.0.0.1")) == "10.0.0.1")
        #expect(ClientAddressRule.key(try address("10.0.0.1")) == "10.0.0.1")
        #expect(ClientAddressRule.key(nil) == nil)

        let counter = ConnectionCounter(perAddress: 2, total: 10)
        let held = [counter.acquire(try address("2001:db8:1:2::1")), counter.acquire(try address("2001:db8:1:2::2"))]
        #expect(held.allSatisfy { $0 != nil })
        #expect(counter.acquire(try address("2001:db8:1:2:aaaa::3")) == nil)
        #expect(counter.acquire(try address("2001:db8:1:3::1")) != nil)
        #expect(counter.open.addresses == 2)
        held[0]?.release()
        #expect(counter.acquire(try address("2001:db8:1:2:aaaa::3")) != nil)
    }

    @Test func theServerConfigReadsTheClientAddressSetting() throws {
        #expect(try ServerConfig.load(from: ["ENV": "dev"]).clientAddress == ClientAddressRule())
        #expect(try ServerConfig.load(from: ["ENV": "dev", "CLIENT_ADDRESS_HEADER": "Fly-Client-IP"]).clientAddress
            == ClientAddressRule(header: "Fly-Client-IP", trustedHops: 1))
        #expect(try ServerConfig.load(from: ["ENV": "dev", "CLIENT_ADDRESS_HEADER": "X-Forwarded-For", "CLIENT_ADDRESS_TRUSTED_HOPS": "2"])
            .clientAddress == ClientAddressRule(header: "X-Forwarded-For", trustedHops: 2))
        for bad in [["CLIENT_ADDRESS_HEADER": ""], ["CLIENT_ADDRESS_HEADER": "X Forwarded: For"], ["CLIENT_ADDRESS_TRUSTED_HOPS": "2"],
                    ["CLIENT_ADDRESS_HEADER": "X-Forwarded-For", "CLIENT_ADDRESS_TRUSTED_HOPS": "0"]] {
            #expect(throws: ServerConfigError.self) { try ServerConfig.load(from: bad.merging(["ENV": "dev"]) { first, _ in first }) }
        }
    }

    /// Over the socket, every connection from one address as behind a proxy: with the proxy's header configured each
    /// client has its own cap, and a client over its cap is closed before it's read.
    @Test func theServerCapsByTheForwardedAddressBehindAProxy() async throws {
        var config = ServerConfig.dev()
        config.connectionLimits.servicePerAddress = 1
        config.clientAddress = ClientAddressRule(header: "Fly-Client-IP")
        let server = try await RegattaHTTPServer.start(config: config)
        defer { Task { await server.shutdown() } }
        func hello(_ client: String?) async throws -> (link: WebSocketServiceLink, accepted: Bool) {
            let link = try await WebSocketServiceLink.connect(host: "127.0.0.1", port: server.port,
                                                              headers: client.map { [("Fly-Client-IP", $0)] } ?? [])
            link.send(try Frame(seq: 1, tick: 0, message: .hello(Hello(clientBuild: "test", files: []))).encoded())
            guard let reply = await link.nextOpeningFrame() else { return (link, false) }
            if case .helloAck = try Frame(decoding: reply).message { return (link, true) }
            return (link, false)
        }
        let first = try await hello("203.0.113.7"), second = try await hello("198.51.100.9")
        #expect(first.accepted && second.accepted)
        #expect(try await hello("203.0.113.7").accepted == false)
        // IPv6 clients of one /64 share a cap.
        let third = try await hello("2001:db8:1:2::1")
        #expect(third.accepted)
        #expect(try await hello("2001:db8:1:2::2").accepted == false)
        // Without the header the connection counts under the socket's own address.
        let direct = try await hello(nil)
        #expect(direct.accepted)
        #expect(try await hello(nil).accepted == false)
        for held in [first, second, third, direct] { held.link.close() }
    }

    // MARK: R6

    /// A queue whose state stream says nothing after `.idle`, and reports when it ends.
    final class SilentQueue: QueueService, @unchecked Sendable {
        let ended: AsyncStream<Void>
        private let endedContinuation: AsyncStream<Void>.Continuation

        init() { (ended, endedContinuation) = AsyncStream<Void>.makeStream() }

        /// Held, so the streams stay open: a stream whose continuations are all gone finishes.
        private let held = Mutex<[AsyncStream<QueueState>.Continuation]>([])

        func stateUpdates() -> AsyncStream<QueueState> {
            let signal = endedContinuation
            let (stream, continuation) = AsyncStream<QueueState>.makeStream(bufferingPolicy: .bufferingNewest(1))
            continuation.yield(.idle)
            continuation.onTermination = { _ in signal.yield() }
            held.withLock { $0.append(continuation) }
            return stream
        }

        func join() throws {}
        func leave() throws {}
    }

    private static func openQueueStream(_ link: InProcessServiceLink) async throws {
        try await send(.queueRequest(ServiceRequest(id: 5, call: .openStateUpdates)), on: link)
        try await send(.streamNext(StreamNext(id: 6, stream: 5)), on: link)
        // The first read answers `.idle` at once; the second waits on a stream with nothing more to say.
        try await Task.sleep(for: .milliseconds(100))
        try await send(.streamNext(StreamNext(id: 7, stream: 5)), on: link)
    }

    /// Signed in with the terms accepted over the bare link (no `ServiceConnection`, which would take the replies to the
    /// raw `StreamNext`s for a protocol violation and close the link).
    private static func signedInAccepted(_ endpoint: ServiceEndpoint, _ name: String) async throws -> InProcessServiceLink {
        let link = try await InProcessServiceLink.open(endpoint)
        let signature = WireIdentitySignature(gamePlayerID: "G:\(name)", teamPlayerID: "T:\(name)", publicKeyURL: "https://dev.invalid/k.cer",
                                              signature: [9], salt: [1], timestamp: 0)
        let player = WirePlayer(gamePlayerID: "G:\(name)", alias: name, isUnderage: false, isPersonalizedCommunicationRestricted: false,
                                isMultiplayerGamingRestricted: false)
        try await send(.sessionRequest(ServiceRequest(id: 1, call: .signIn(signature: signature, player: player))), on: link)
        try await send(.termsRequest(ServiceRequest(id: 2, call: .accept(version: 1))), on: link)
        return link
    }

    @Test func closingAStreamCancelsItsPendingRead() async throws {
        let queue = SilentQueue()
        let link = try await Self.signedInAccepted(Self.endpoint(queue: queue), "closer")
        try await Self.openQueueStream(link)
        let open = await link.handler.openStreamCount
        #expect(open == 1)
        #expect(link.closeReason == nil)
        try await Self.send(.streamClose(StreamClose(stream: 5)), on: link)
        var ended = queue.ended.makeAsyncIterator()
        #expect(await ended.next() != nil)
        #expect(await link.handler.openStreamCount == 0)
    }

    @Test func endingTheConnectionCancelsEveryPendingRead() async throws {
        let queue = SilentQueue()
        let link = try await Self.signedInAccepted(Self.endpoint(queue: queue), "dropper")
        try await Self.openQueueStream(link)
        #expect(link.closeReason == nil)
        link.close()
        var ended = queue.ended.makeAsyncIterator()
        #expect(await ended.next() != nil)
    }

    // MARK: R11

    private static func clocked(_ store: InMemoryAccountStore, _ now: @escaping @Sendable () -> Date, lifetime: TimeInterval = 3_600,
                                absolute: TimeInterval = 7_200, cap: Int = 5) -> ServiceEndpoint {
        endpoint(sessions: SessionAuthority(store: store, verifier: StubVerifier(), lifetime: lifetime, absoluteLifetime: absolute,
                                            maxSessionsPerPlayer: cap, now: now))
    }

    private static func resume(_ endpoint: ServiceEndpoint, _ token: [UInt8], _ name: String) async throws -> OpenSession {
        let link = try await InProcessServiceLink.open(endpoint)
        let connection = ServiceConnection(link)
        return try await RemoteSession(connection).resume(token: token, as: ServiceFixtures.player(name))
    }

    @Test func aSessionEndsAtItsAbsoluteLifetimeHoweverOftenItSlides() async throws {
        let start = Date(timeIntervalSince1970: 1_791_460_800)
        let clock = Mutex(start)
        let store = InMemoryAccountStore()
        let endpoint = Self.clocked(store, { clock.withLock { $0 } })
        let (_, _, session) = try await ServiceFixtures.signedIn(endpoint, "slider")
        clock.withLock { $0 = start + 3_000 }
        _ = try await Self.resume(endpoint, session.token, "slider")
        clock.withLock { $0 = start + 6_000 }
        _ = try await Self.resume(endpoint, session.token, "slider")
        // Slid to 9 000 s, but the absolute lifetime ends it at 7 200 s.
        #expect(await store.sessions(playerID: "T:slider").first?.expiresAt == start + 7_200)
        clock.withLock { $0 = start + 7_300 }
        await #expect(throws: (any Error).self) { _ = try await Self.resume(endpoint, session.token, "slider") }
    }

    @Test func aPlayerHoldsAtMostTheCapOfSessions() async throws {
        let start = Date(timeIntervalSince1970: 1_791_460_800)
        let clock = Mutex(start)
        let store = InMemoryAccountStore()
        let endpoint = Self.clocked(store, { clock.withLock { $0 } }, cap: 2)
        var tokens: [[UInt8]] = []
        var held: [ServiceConnection] = []
        for step in 0..<3 {
            clock.withLock { $0 = start + Double(step) }
            let (_, connection, session) = try await ServiceFixtures.signedIn(endpoint, "many")
            tokens.append(session.token)
            held.append(connection)
        }
        #expect(await store.sessions(playerID: "T:many").count == 2)
        await #expect(throws: (any Error).self) { _ = try await Self.resume(endpoint, tokens[0], "many") }
        _ = try await Self.resume(endpoint, tokens[2], "many")
        withExtendedLifetime(held) {}
    }

    @Test func expiredSessionsAreSwept() async throws {
        let start = Date(timeIntervalSince1970: 1_791_460_800)
        let clock = Mutex(start)
        let store = InMemoryAccountStore()
        let endpoint = Self.clocked(store, { clock.withLock { $0 } })
        let (_, held, _) = try await ServiceFixtures.signedIn(endpoint, "sweep")
        #expect(await endpoint.sessions.sweepExpired() == 0)
        clock.withLock { $0 = start + 3_601 }
        #expect(await endpoint.sessions.sweepExpired() == 1)
        #expect(await store.sessions(playerID: "T:sweep").isEmpty)
        withExtendedLifetime(held) {}
    }

    @Test func aNewSignInEndsTheConnectionsPreviousSession() async throws {
        let store = InMemoryAccountStore()
        let endpoint = Self.endpoint(store: store)
        let (_, connection, first) = try await ServiceFixtures.signedIn(endpoint, "twice")
        let second = try await RemoteSession(connection).signIn(ServiceFixtures.signature("twice"), as: ServiceFixtures.player("twice"))
        #expect(second.token != first.token)
        #expect(await store.sessions(playerID: "T:twice").count == 1)
        await #expect(throws: (any Error).self) { _ = try await Self.resume(endpoint, first.token, "twice") }
        _ = try await Self.resume(endpoint, second.token, "twice")
    }
}
