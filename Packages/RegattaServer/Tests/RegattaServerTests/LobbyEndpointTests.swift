import ChatFilter
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Persistence
import RegattaProtocol
@testable import RegattaServerKit
import RegattaServiceClient
import RegattaServices
import Synchronization
import Testing

/// #152: the lobby behind the service endpoint's gate: who gets chat frames at all, what a re-sign-in as a restricted
/// player does to open feeds, and the per-connection budget of lobby calls.
@Suite(.timeLimit(.minutes(2))) struct LobbyEndpointTests {
    struct Rig {
        let store = InMemoryAccountStore()
        let book = InMemoryRatingBook()
        let hub: LobbyHub
        let endpoint: ServiceEndpoint

        init() {
            let hub = LobbyHub(ratings: book, wordList: ChatWordList(entries: ["bitch"]))
            self.hub = hub
            endpoint = ServiceEndpoint(config: ServiceEndpointConfig(), sessions: SessionAuthority(store: store, verifier: StubVerifier()),
                                       backends: ServiceBackends(lobby: { ServerLobbyService(hub: hub, player: $0) }), lobby: hub,
                                       attestation: .devDefault())
        }

        /// A connection signed in as `name`, who has accepted the terms and completed a race.
        func connect(_ name: String, underage: Bool = false) async throws -> (InProcessServiceLink, ServiceConnection, RemoteLobbyService) {
            _ = try await store.signIn(teamPlayerID: "T:\(name)", gamePlayerID: "G:\(name)", alias: name)
            try await store.acceptTerms(playerID: "T:\(name)", version: 1, at: Date())
            book.setStats(completedRaces: 1, wins: 0, for: "T:\(name)")
            let (link, connection, _) = try await ServiceFixtures.signedIn(endpoint, name, underage: underage)
            return (link, connection, RemoteLobbyService(connection))
        }
    }

    static let open = LobbyState(access: .open, canPostFreeText: true, standing: .clear)

    /// Over the wire, through the gate: a post reaches another connection's feed, and a blocked one comes back not sent.
    @Test func chatOverTheEndpoint() async throws {
        let rig = Rig()
        let (_, _, wren) = try await rig.connect("wren")
        let (_, _, finn) = try await rig.connect("finn")
        let feed = FeedReader(finn.feed())
        #expect(await feed.next() == .state(Self.open))
        let sent = try await wren.post("fair winds")
        #expect(sent.post?.delivery == .sent && sent.post?.author.nickname == "wren")
        #expect(await feed.next() == .message(sent))
        #expect(try await finn.history() == [sent])
        #expect(try await finn.post("you bitch").post?.delivery == .notSent)
        await #expect(throws: LobbyError.rateLimited(retryAfterSeconds: 3)) { _ = try await finn.post(.gg) }
    }

    /// Game Center's `isUnderage` (or the communication restriction): the lobby is closed to her, and her connection
    /// never carries a chat frame.
    @Test func restrictedSessionReceivesNoChatFrames() async throws {
        let rig = Rig()
        let (_, _, wren) = try await rig.connect("wren")
        let (_, _, kid) = try await rig.connect("kid", underage: true)
        let closed = LobbyState(access: .closed(.communicationRestricted), canPostFreeText: false)
        #expect(try await kid.state() == closed)
        let feed = FeedReader(kid.feed())
        #expect(await feed.next() == .state(closed))
        _ = try await wren.post("fair winds")
        // The feed says the state and ends; the hub never had a feed of hers.
        #expect(await feed.next() == nil)
        #expect(rig.hub.feedCount == 0)
        await #expect(throws: LobbyError.closed(.communicationRestricted)) { _ = try await kid.history() }
        await #expect(throws: LobbyError.closed(.communicationRestricted)) { _ = try await kid.post(.gg) }
        await #expect(throws: LobbyError.closed(.communicationRestricted)) { try await kid.block(GamePlayerID("G:wren")) }
    }

    /// The same player signs in again on an open connection, now restricted: the feed she had ends there.
    @Test func reSignInRestrictedEndsFeeds() async throws {
        let rig = Rig()
        let (_, connection, wren) = try await rig.connect("wren")
        let (_, _, finn) = try await rig.connect("finn")
        let feed = FeedReader(wren.feed())
        #expect(await feed.next() == .state(Self.open))
        #expect(rig.hub.feedCount == 1)
        _ = try await RemoteSession(connection).signIn(ServiceFixtures.signature("wren"), as: ServiceFixtures.player("wren", underage: true))
        #expect(rig.hub.feedCount == 0)
        _ = try await finn.post("fair winds")
        #expect(await feed.next() == nil)
        #expect(try await wren.state().access == .closed(.communicationRestricted))
    }

    /// A connection that ends takes its feeds with it.
    @Test func aClosedConnectionsFeedsAreRemoved() async throws {
        let rig = Rig()
        let (link, _, wren) = try await rig.connect("wren")
        let feed = FeedReader(wren.feed())
        #expect(await feed.next() == .state(Self.open))
        #expect(rig.hub.feedCount == 1)
        link.close()
        for _ in 0..<2_000 where rig.hub.feedCount != 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(rig.hub.feedCount == 0)
    }

    /// 30 lobby calls at once, refilled 3 a second; reading the history costs 5. A connection past that is closed.
    @Test func lobbyRequestBudgetClosesConnection() async throws {
        let rig = Rig()
        let (link, _, wren) = try await rig.connect("wren")
        var answered = 0
        for _ in 0..<300 {
            guard (try? await wren.state()) != nil else { break }
            answered += 1
        }
        // The burst, and whatever was refilled while they were answered.
        #expect(answered >= 30 && answered < 300)
        #expect(link.closeReason == "too many lobby calls")

        let (other, _, finn) = try await rig.connect("finn")
        var histories = 0
        for _ in 0..<300 {
            guard (try? await finn.history()) != nil else { break }
            histories += 1
        }
        #expect(histories >= 6 && histories < 100)
        #expect(other.closeReason == "too many lobby calls")
    }

    /// An online racing suspension keeps a player out of the queue, never out of chat (#17).
    @Test func racingSuspensionDoesNotCloseChat() async throws {
        let restrictions = InMemoryRestrictionStore()
        let store = InMemoryAccountStore()
        _ = try await store.signIn(teamPlayerID: "T:wren", gamePlayerID: "G:wren", alias: "wren")
        try await restrictions.setSuspension("T:wren", .permanent)
        var config = ServerConfig.dev()
        config.chat.extraBlockedPhrases = ["contract filtered phrase"]
        let endpoint = try ServiceEndpoint.make(config: config, store: store, restrictions: restrictions, wordList: ChatWordList(entries: ["bitch"]))
        let matchmaker = try #require(endpoint.matchmaker), hub = try #require(endpoint.lobby)
        let player = AccountPlayer(teamPlayerID: "T:wren", gamePlayerID: "G:wren", alias: "wren")
        #expect(await matchmaker.state(of: "T:wren") == .unavailable(.suspended(until: nil)))
        let lobby = ServerLobbyService(hub: hub, player: player)
        #expect(try await lobby.state() == LobbyState(access: .open, canPostFreeText: false))
        #expect(try await lobby.post(.gg).post?.delivery == .sent)
        // A dev server's extra phrases are in the filter beside the word list.
        let finn = ServerLobbyService(hub: hub, player: AccountPlayer(teamPlayerID: "T:finn", gamePlayerID: "G:finn", alias: "finn"))
        hub.devUnlock("T:finn")
        #expect(try await finn.post("a contract filtered phrase").post?.delivery == .notSent)
        await matchmaker.stop()
    }

    /// The config: the classifier's key (never required in dev), and a dev server's extra blocked phrases.
    @Test func theServerConfigReadsTheChatSettings() throws {
        let plain = try ServerConfig.load(from: ["ENV": "dev"])
        #expect(plain.chat.moderationKey == nil && plain.chat.extraBlockedPhrases.isEmpty)
        let set = try ServerConfig.load(from: ["ENV": "dev", "OPENAI_MODERATION_API_KEY": "sk-test",
                                               "CHAT_EXTRA_BLOCKED_PHRASES": "contract filtered phrase, another one ,"])
        #expect(set.chat.moderationKey == "sk-test")
        #expect(set.chat.extraBlockedPhrases == ["contract filtered phrase", "another one"])
        // Without a key nothing is built that could call out.
        #expect(try ServiceEndpoint.make(config: plain, store: InMemoryAccountStore(), wordList: .empty).lobby != nil)
    }

    /// Owner 2026-10-11: the offline word list always applies. A build without one starts only in dev (on the dev
    /// phrases alone); outside dev it refuses, and the dev phrases are ignored there.
    @Test func aBuildWithoutTheWordListStartsOnlyInDev() throws {
        var dev = ServerConfig.dev()
        dev.chat.extraBlockedPhrases = ["contract filtered phrase"]
        var production = dev
        production.environment = .other("production")
        let list = ChatWordList(entries: ["bitch"])
        let missing: () throws -> ChatWordList = { throw ChatWordList.BundleError.missing }

        let devWithout = try ServiceEndpoint.chatWordList(config: dev, bundled: missing)
        #expect(devWithout.blocks("a contract filtered phrase") && !devWithout.blocks("bitch"))
        let devWith = try ServiceEndpoint.chatWordList(config: dev) { list }
        #expect(devWith.blocks("a contract filtered phrase") && devWith.blocks("bitch"))
        #expect(throws: ServerConfigError.self) { _ = try ServiceEndpoint.chatWordList(config: production, bundled: missing) }
        let live = try ServiceEndpoint.chatWordList(config: production) { list }
        #expect(live.blocks("bitch") && !live.blocks("a contract filtered phrase"))
    }
}

// MARK: - The classifier's adapter, against a stub

/// An HTTP server on a loopback port that answers every request as told, and keeps what it was sent.
final class StubHTTPServer: Sendable {
    struct Received: Sendable {
        let head: HTTPRequestHead
        let body: [UInt8]
    }

    typealias Respond = @Sendable (Received) -> (status: HTTPResponseStatus, body: [UInt8])?

    let channel: any Channel
    let received = Kept<Received>()
    var port: Int { channel.localAddress?.port ?? 0 }

    /// `respond` returning nil: the request is never answered.
    init(_ respond: @escaping Respond) async throws {
        let received = received
        channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    try channel.pipeline.syncOperations.addHandler(Handler(respond: respond, received: received))
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
    }

    func stop() async { try? await channel.close() }

    private final class Handler: ChannelInboundHandler {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        let respond: Respond
        let received: Kept<Received>
        var head: HTTPRequestHead?
        var body: [UInt8] = []

        init(respond: @escaping Respond, received: Kept<Received>) {
            self.respond = respond
            self.received = received
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch unwrapInboundIn(data) {
            case .head(let head):
                self.head = head
                body = []
            case .body(var buffer):
                body += buffer.readBytes(length: buffer.readableBytes) ?? []
            case .end:
                guard let head else { return }
                let request = Received(head: head, body: body)
                received.append(request)
                guard let (status, bytes) = respond(request) else { return }
                var headers = HTTPHeaders()
                headers.add(name: "Content-Length", value: String(bytes.count))
                headers.add(name: "Connection", value: "close")
                context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))), promise: nil)
                context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(bytes: bytes)))), promise: nil)
                context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
                context.close(promise: nil)
            }
        }
    }
}

/// #152: OpenAI's moderation endpoint as the lobby's classifier, against a stub on loopback. No test calls the real
/// service, and nothing is built that could unless the key is configured.
@Suite(.timeLimit(.minutes(1))) struct OpenAIModerationClassifierTests {
    static let key = "sk-test-0123456789"

    static func classifier(_ server: StubHTTPServer, timeout: Duration = .seconds(20)) throws -> OpenAIModerationClassifier {
        try OpenAIModerationClassifier(key: key, endpoint: "http://127.0.0.1:\(server.port)/v1/moderations", timeout: timeout)
    }

    static func answer(flagged: Bool) -> [UInt8] {
        Array(#"{"id":"modr-1","model":"omni-moderation-latest","results":[{"flagged":\#(flagged),"categories":{}}]}"#.utf8)
    }

    @Test func requestShapeAndAnswer() async throws {
        let server = try await StubHTTPServer { request in
            (.ok, Self.answer(flagged: String(decoding: request.body, as: UTF8.self).contains("nasty")))
        }
        let classifier = try Self.classifier(server)
        #expect(try await classifier.isFlagged("fair winds \"sailor\"") == false)
        #expect(try await classifier.isFlagged("something nasty") == true)
        let first = try #require(server.received.all.first)
        #expect(first.head.method == .POST && first.head.uri == "/v1/moderations")
        #expect(first.head.headers["Authorization"] == ["Bearer \(Self.key)"])
        #expect(first.head.headers["Content-Type"] == ["application/json"])
        // The text and the model: nothing about the player.
        let body = try #require(try JSONSerialization.jsonObject(with: Data(first.body)) as? [String: String])
        #expect(body == ["model": "omni-moderation-latest", "input": "fair winds \"sailor\""])
        await server.stop()
    }

    /// 429 and 5xx are failures (the gate lets the message through), and no error says the key, even when the service
    /// echoes it.
    @Test func refusalsAreFailuresAndTheKeyIsNotEchoed() async throws {
        for status in [HTTPResponseStatus.tooManyRequests, .internalServerError, .unauthorized] {
            let server = try await StubHTTPServer { request in
                (status, Array("bad key \(request.head.headers["Authorization"].first ?? "")".utf8))
            }
            let classifier = try Self.classifier(server)
            do {
                _ = try await classifier.isFlagged("fair winds")
                Issue.record("a \(status.code) was read as an answer")
            } catch {
                #expect(error as? OpenAIModerationClassifier.CallError == .status(Int(status.code)))
                #expect(!"\(error)".contains(Self.key) && !String(reflecting: error).contains(Self.key))
            }
            // Through the gate: unavailable, so the post passes on the word list.
            #expect(await ClassifierGate(classifier).screen("fair winds") == .unavailable(.error))
            await server.stop()
        }
    }

    @Test func anUnreadableOrOversizeAnswerIsAFailure() async throws {
        let garbled = try await StubHTTPServer { _ in (.ok, Array("<html>".utf8)) }
        await #expect(throws: OpenAIModerationClassifier.CallError.unreadable) { _ = try await Self.classifier(garbled).isFlagged("x") }
        await garbled.stop()
        let huge = try await StubHTTPServer { _ in (.ok, [UInt8](repeating: 0x20, count: 70 * 1024) + Self.answer(flagged: false)) }
        await #expect(throws: OpenAIModerationClassifier.CallError.responseTooLarge) { _ = try await Self.classifier(huge).isFlagged("x") }
        await huge.stop()
        // The request is capped too: lobby text never comes near it.
        #expect(try OpenAIModerationClassifier.body(for: String(repeating: "\"", count: ChatText.maxBytes)).count <= 2048)
        #expect(throws: OpenAIModerationClassifier.CallError.requestTooLarge) {
            _ = try OpenAIModerationClassifier.body(for: String(repeating: "\"", count: 1100))
        }
    }

    /// A service that never answers: the call gives up at its limit, and the gate reports a timeout no later.
    @Test func aServiceThatNeverAnswersTimesOut() async throws {
        let server = try await StubHTTPServer { _ in nil }
        let classifier = try Self.classifier(server, timeout: .milliseconds(200))
        await #expect(throws: (any Error).self) { _ = try await classifier.isFlagged("fair winds") }
        let patient = try Self.classifier(server, timeout: .seconds(60))
        #expect(await ClassifierGate(patient, timeout: .milliseconds(100)).screen("fair winds") == .unavailable(.timeout))
        await server.stop()
    }

    @Test func onlyHTTPSOrLoopbackAndNeverWithoutAKey() throws {
        #expect(throws: OpenAIModerationClassifier.CallError.badEndpoint) { _ = try OpenAIModerationClassifier(key: "") }
        #expect(throws: OpenAIModerationClassifier.CallError.badEndpoint) {
            _ = try OpenAIModerationClassifier(key: Self.key, endpoint: "http://example.com/v1/moderations")
        }
        _ = try OpenAIModerationClassifier(key: Self.key)
    }

    /// The gate's own limit: more than `maxInFlight` at once aren't asked.
    @Test func theGateBoundsCallsInFlight() async throws {
        let classifier = FakeToxicityClassifier(.hangs)
        let gate = ClassifierGate(classifier, timeout: .seconds(60), maxInFlight: 2)
        async let first = gate.screen("one")
        async let second = gate.screen("two")
        for _ in 0..<2_000 where classifier.asked.count < 2 { try await Task.sleep(for: .milliseconds(2)) }
        #expect(await gate.screen("three") == .unavailable(.busy))
        #expect(classifier.asked.count == 2)
        classifier.release()
        #expect(await [first, second] == [.unavailable(.error), .unavailable(.error)])
    }
}
