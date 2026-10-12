import Crypto
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import Persistence
import Synchronization

// The Game Center leaderboard mirrors the rating (#151): after a rated race is stored, each established participant's
// rounded rating is sent to App Store Connect, server to server; the client never submits a score. Provisional players
// are never sent. Never part of the close: a slow or failing App Store Connect holds up nothing but the leaderboard,
// and a sweep retries what failed. The leaderboard must be "Most Recent Score" (#55): a rating falls as well as rises.

/// Sends one player's rating to the leaderboard. Throws `LeaderboardSubmitError.status` for an HTTP refusal.
public protocol LeaderboardSubmitting: Sendable {
    func submit(_ entry: MirrorEntry) async throws
}

public enum LeaderboardSubmitError: Error, Equatable, Sendable {
    case status(Int)

    /// Worth one more try at once: rate limited, or App Store Connect's own failure.
    var isTransient: Bool {
        switch self { case .status(let code): code == 429 || (500...599).contains(code) }
    }
}

public struct LeaderboardMirrorSettings: Sendable, Equatable {
    /// How often everything still unsent is tried again.
    public var sweepInterval: Duration = .seconds(300)
    /// Failed tries, since the rating last changed, after which a player is left alone until it changes again.
    public var maxFailures = 5
    public var concurrency = 2
    public var timeout: Duration = .seconds(10)
    /// The most a sweep takes on at once.
    public var sweepBatch = 200

    public init() {}
}

public actor LeaderboardMirror {
    let book: any RatingBook
    let submitter: any LeaderboardSubmitting
    public nonisolated let settings: LeaderboardMirrorSettings
    private var inFlight: Set<String> = []
    private var sweeper: Task<Void, Never>?
    public private(set) var submitted = 0
    public private(set) var failed = 0

    public init(book: any RatingBook, submitter: any LeaderboardSubmitting, settings: LeaderboardMirrorSettings = LeaderboardMirrorSettings()) {
        self.book = book
        self.submitter = submitter
        self.settings = settings
    }

    /// A close just rated `playerIDs`: those established, whose rounded rating isn't the one the leaderboard has, are sent.
    public func rated(_ playerIDs: [String]) async {
        let book = book, settings = settings
        await send { try await book.mirrorPending(playerIDs, maxFailures: settings.maxFailures, limit: playerIDs.count) }
    }

    /// Everything still unsent, at most `sweepBatch` at once.
    public func sweep() async {
        let book = book, settings = settings
        await send { try await book.mirrorPending(nil, maxFailures: settings.maxFailures, limit: settings.sweepBatch) }
    }

    /// Sweeps every `sweepInterval` until `stop()`.
    public func start() {
        guard sweeper == nil else { return }
        sweeper = Task { await self.sweepUntilCancelled() }
    }

    private func sweepUntilCancelled() async {
        repeat {
            try? await Task.sleep(for: settings.sweepInterval)
            if Task.isCancelled { return }
            await sweep()
        } while true
    }

    public func stop() {
        sweeper?.cancel()
        sweeper = nil
    }

    private func send(_ pending: @Sendable () async throws -> [MirrorEntry]) async {
        let entries: [MirrorEntry]
        do {
            entries = try await pending().filter { !inFlight.contains($0.playerID) }
        } catch {
            return Self.log("can't read what to send: \(error)")
        }
        guard !entries.isEmpty else { return }
        for entry in entries { inFlight.insert(entry.playerID) }
        let submitter = submitter, book = book, timeout = settings.timeout, concurrency = max(1, settings.concurrency)
        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            var results: [Bool] = [], next = entries.makeIterator()
            func add() {
                guard let entry = next.next() else { return }
                group.addTask { await Self.deliver(entry, submitter: submitter, book: book, timeout: timeout) }
            }
            for _ in 0..<concurrency { add() }
            for await result in group {
                results.append(result)
                add()
            }
            return results
        }
        for entry in entries { inFlight.remove(entry.playerID) }
        submitted += results.filter { $0 }.count
        failed += results.filter { !$0 }.count
    }

    /// One player's submission: at most `timeout` a try, one more try at once after a 429 or a 5xx, then the store
    /// is told how it went.
    private static func deliver(_ entry: MirrorEntry, submitter: any LeaderboardSubmitting, book: any RatingBook, timeout: Duration) async -> Bool {
        @Sendable func attempt() async throws { try await withDeadline(timeout) { try await submitter.submit(entry) } }
        do {
            do {
                try await attempt()
            } catch let error as LeaderboardSubmitError where error.isTransient {
                try await attempt()
            }
            try await book.mirrored(entry.playerID, rating: entry.rating)
            return true
        } catch {
            log("\(entry.playerID) at \(entry.rating): \(error)")
            try? await book.mirrorFailed(entry.playerID)
            return false
        }
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("RegattaServer: leaderboard mirror: \(message)\n".utf8))
    }
}

// MARK: - App Store Connect

/// What the mirror needs of App Store Connect (#55, `docs/prerequisites.md`): an API key (team key id, issuer id and
/// its P-256 private key), the leaderboard's vendor identifier and the app's bundle id. Server config: `ASC_KEY_ID`,
/// `ASC_ISSUER_ID`, `ASC_PRIVATE_KEY_PEM` (a file), `GC_LEADERBOARD_ID`; all unset: no mirror.
public struct AppStoreConnectConfig: Sendable {
    public var keyID: String
    public var issuerID: String
    public var privateKeyPEM: String
    public var leaderboardID: String
    public var bundleID: String
    /// The leaderboard's App Store Connect resource id (`GC_LEADERBOARD_RESOURCE_ID`), for blocking a deleted player's
    /// scores (#160); nil: they aren't blocked, and the deletions wait for it.
    public var leaderboardResourceID: String?

    public init(keyID: String, issuerID: String, privateKeyPEM: String, leaderboardID: String, bundleID: String,
                leaderboardResourceID: String? = nil) {
        self.keyID = keyID
        self.issuerID = issuerID
        self.privateKeyPEM = privateKeyPEM
        self.leaderboardID = leaderboardID
        self.bundleID = bundleID
        self.leaderboardResourceID = leaderboardResourceID
    }
}

/// An HTTPS POST of JSON with a bearer token; returns the status. The seam the App Store Connect client is tested through.
public protocol HTTPSPosting: Sendable {
    func post(host: String, path: String, bearer: String, json: Data) async throws -> Int
}

/// `POST /v1/gameCenterLeaderboardEntrySubmissions` (App Store Connect API): one player's score on one leaderboard.
///
/// The request is Apple's `GameCenterLeaderboardEntrySubmissionCreateRequest`, read 2026-10-11 from the App Store
/// Connect API reference (developer.apple.com/documentation/appstoreconnectapi/post-v1-gamecenterleaderboardentrysubmissions
/// and its `Data` and `Data.Attributes` pages, which Apple generates from its OpenAPI specification): `data.type` is
/// `gameCenterLeaderboardEntrySubmissions`; the required attributes are `bundleId`, `scopedPlayerId`, `score` (a number)
/// and `vendorIdentifier`; `challengeIds`, `context`, `preReleased` and `submittedDate` are optional and not sent.
/// Success is 201; 400, 401, 403, 409, 422 and 429 carry an `ErrorResponse`.
/// `Tests/RegattaServerTests/Fixtures/leaderboard-submission.json` pins the body.
///
/// Not from the reference, which describes no field: that `scopedPlayerId` is the player's `gamePlayerID` (the id Game
/// Center scopes to the game; #151's brief's reading, and why `players.game_player_id` is kept, #145), and that
/// `vendorIdentifier` is the leaderboard's id. #55 confirms both with the first real submission.
public struct AppStoreConnectLeaderboard: LeaderboardSubmitting {
    public static let host = "api.appstoreconnect.apple.com"
    public static let path = "/v1/gameCenterLeaderboardEntrySubmissions"
    /// A token is asked to live 19 minutes and used for 15. App Store Connect refuses one whose `exp` is more than 20
    /// minutes on by its own clock, so the minute less is the room a server clock may run ahead of Apple's; the reuse
    /// window stays below the lifetime.
    static let tokenLifetime: TimeInterval = 19 * 60
    static let tokenReuse: TimeInterval = 15 * 60

    let config: AppStoreConnectConfig
    let key: P256.Signing.PrivateKey
    let poster: any HTTPSPosting
    let now: @Sendable () -> Date
    private let cache = TokenCache()

    public init(config: AppStoreConnectConfig, poster: any HTTPSPosting, now: @escaping @Sendable () -> Date = { Date() }) throws {
        self.config = config
        key = try P256.Signing.PrivateKey(pemRepresentation: config.privateKeyPEM)
        self.poster = poster
        self.now = now
    }

    private struct Body: Encodable {
        struct Entry: Encodable {
            struct Attributes: Encodable {
                var bundleId: String
                var scopedPlayerId: String
                var score: Int
                var vendorIdentifier: String
            }
            var type = "gameCenterLeaderboardEntrySubmissions"
            var attributes: Attributes
        }
        var data: Entry
    }

    /// The request body for `entry`: canonical JSON (sorted keys).
    public func body(for entry: MirrorEntry) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Body(data: .init(attributes: .init(
            bundleId: config.bundleID, scopedPlayerId: entry.gamePlayerID, score: entry.rating, vendorIdentifier: config.leaderboardID))))
    }

    /// An ES256 JWT as App Store Connect asks of a team key: header `alg`, `kid`, `typ`; claims `iss` (the issuer
    /// id), `iat`, `exp` (`tokenLifetime` on: under the 20 minutes allowed) and `aud` `appstoreconnect-v1`.
    public func token(at time: Date) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let issued = Int(time.timeIntervalSince1970)
        let header = try encoder.encode(["alg": "ES256", "kid": config.keyID, "typ": "JWT"])
        let claims = try encoder.encode(Claims(iss: config.issuerID, iat: issued, exp: issued + Int(Self.tokenLifetime), aud: "appstoreconnect-v1"))
        let signing = Self.base64URL(header) + "." + Self.base64URL(claims)
        return signing + "." + Self.base64URL(try key.signature(for: Data(signing.utf8)).rawRepresentation)
    }

    private struct Claims: Encodable {
        var iss: String
        var iat: Int
        var exp: Int
        var aud: String
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// A token for `time`: the cached one while it may be reused.
    public func bearer(at time: Date) throws -> String { try cache.token(at: time, reuse: Self.tokenReuse) { try token(at: time) } }

    public func submit(_ entry: MirrorEntry) async throws {
        let time = now()
        let bearer = try bearer(at: time)
        let status = try await poster.post(host: Self.host, path: Self.path, bearer: bearer, json: try body(for: entry))
        guard status == 201 else { throw LeaderboardSubmitError.status(status) }
    }

    private final class TokenCache: Sendable {
        private let state = Mutex<(token: String, made: Date)?>(nil)

        func token(at time: Date, reuse: TimeInterval, make: () throws -> String) throws -> String {
            try state.withLock { cached in
                if let cached, time >= cached.made, time.timeIntervalSince(cached.made) < reuse { return cached.token }
                let token = try make()
                cached = (token, time)
                return token
            }
        }
    }
}

/// HTTPS over NIO with NIOSSL, as `HTTPSCertificateFetcher` (no FoundationNetworking on Linux): one request per
/// connection, the system's trust roots.
public struct NIOHTTPSPoster: HTTPSPosting, HTTPSRequesting {
    let group: any EventLoopGroup
    let timeout: Duration
    let context: NIOSSLContext

    public init(group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton, timeout: Duration = .seconds(10)) throws {
        self.group = group
        self.timeout = timeout
        context = try NIOSSLContext(configuration: .makeClientConfiguration())
    }

    public func post(host: String, path: String, bearer: String, json: Data) async throws -> Int {
        try await send(.POST, host: host, target: path, bearer: bearer, json: json, readBody: false).status
    }

    public func request(_ method: HTTPSMethod, host: String, target: String, bearer: String, json: Data?) async throws -> HTTPSReply {
        let nio: HTTPMethod = switch method {
        case .get: .GET
        case .patch: .PATCH
        }
        return try await send(nio, host: host, target: target, bearer: bearer, json: json, readBody: true)
    }

    /// One request; the reply's body read only when asked (at most `maxBody` bytes).
    private func send(_ method: HTTPMethod, host: String, target: String, bearer: String, json: Data?, readBody: Bool) async throws -> HTTPSReply {
        let context = context
        let channel = try await ClientBootstrap(group: group)
            .connectTimeout(.seconds(Int64(timeout.components.seconds)))
            .connect(host: host, port: 443) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: context, serverHostname: host))
                    try channel.pipeline.syncOperations.addHTTPClientHandlers()
                    return try NIOAsyncChannel<HTTPClientResponsePart, HTTPClientRequestPart>(wrappingChannelSynchronously: channel)
                }
            }
        let deadline = Task {
            try await Task.sleep(for: timeout)
            try await channel.channel.close()
        }
        defer { deadline.cancel() }
        return try await channel.executeThenClose { inbound, outbound in
            var headers = HTTPHeaders()
            headers.add(name: "Host", value: host)
            headers.add(name: "Authorization", value: "Bearer \(bearer)")
            if let json {
                headers.add(name: "Content-Type", value: "application/json")
                headers.add(name: "Content-Length", value: String(json.count))
            }
            headers.add(name: "Connection", value: "close")
            var parts: [HTTPClientRequestPart] = [.head(HTTPRequestHead(version: .http1_1, method: method, uri: target, headers: headers))]
            if let json { parts.append(.body(.byteBuffer(ByteBuffer(bytes: json)))) }
            parts.append(.end(nil))
            try await outbound.write(contentsOf: parts)
            var status = 0
            var body: [UInt8] = []
            for try await part in inbound {
                switch part {
                case .head(let head):
                    status = Int(head.status.code)
                    if !readBody { return HTTPSReply(status: status, body: Data()) }
                case .body(let buffer):
                    body += Array(buffer: buffer)
                    guard body.count <= Self.maxBody else { throw HTTPSCertificateFetcher.FetchError.tooLarge }
                case .end:
                    return HTTPSReply(status: status, body: Data(body))
                }
            }
            throw HTTPSCertificateFetcher.FetchError.incomplete
        }
    }

    /// A page of App Store Connect's list is well under this.
    static let maxBody = 4 * 1024 * 1024
}
