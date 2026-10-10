import Foundation
import GameCenterIdentity
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import Persistence
import RegattaDevAPI
import RegattaServices
import X509

extension ServiceEndpoint {
    /// The endpoint `config` describes, over `store`: the real Game Center verifier when Apple's root is configured,
    /// the dev verifier otherwise (only in `ENV=dev`); the queue (#146) locking its races onto `registry`, each race
    /// registered, streamed and closed by the lifecycle (#148) into `archive` (memory by default: a dev server).
    public static func make(config: ServerConfig, store: any AccountStore, archive: any RaceArchive = InMemoryRaceArchive(),
                            registry: RaceRegistry? = nil, fetcher: (any CertificateFetching)? = nil) throws -> ServiceEndpoint {
        let identity = config.identity
        let verifier: any GameCenterVerifier
        if let pem = identity.appleRootsPEM {
            let pinned = try GameCenterVerifierConfig.certificates(pem: pem)
            verifier = AppleGameCenterVerifier(
                config: GameCenterVerifierConfig(bundleID: identity.bundleID, pinned: pinned, freshness: identity.signatureFreshness),
                fetcher: try fetcher ?? HTTPSCertificateFetcher())
        } else if config.environment.isDev {
            verifier = DevGameCenterVerifier(freshness: identity.signatureFreshness)
        } else {
            throw ServerConfigError.invalid(variable: "REGATTA_APPLE_ROOT_PEM", value: "(unset)", expected: "Apple's root outside ENV=dev")
        }
        let queue = config.queue
        let registry = registry ?? RaceRegistry(maxRaces: config.maxRaces)
        let lifecycle = RaceLifecycle(settings: config.lifecycle, archive: archive, tokenKey: config.tokenKey,
                                      tokenLifetime: config.tokenLifetime, toolchain: config.serverBuild, registry: registry)
        let matchmaker = QueueMatchmaker(
            settings: queue, registry: registry,
            draw: RaceDraw(pairings: OnlinePairing.bundled(venues: queue.venues),
                           seeds: FixtureWindSeedPools(poolSize: queue.windSeedPoolSize, reuseCap: queue.windSeedReuseCap)),
            tokenKey: config.tokenKey, tokenLifetime: config.tokenLifetime, launch: lifecycle.launcher())
        return ServiceEndpoint(
            config: ServiceEndpointConfig(termsVersion: identity.termsVersion, sessionLifetime: identity.sessionLifetime,
                                          streamIdleTimeout: identity.streamIdleTimeout, frameCap: identity.frameCap,
                                          signInDeadline: identity.signInDeadline, idleTimeout: identity.connectionIdleTimeout,
                                          serverBuild: config.serverBuild),
            sessions: SessionAuthority(store: store, verifier: verifier, lifetime: identity.sessionLifetime,
                                       absoluteLifetime: identity.absoluteSessionLifetime,
                                       maxSessionsPerPlayer: identity.maxSessionsPerPlayer),
            backends: ServiceBackends(queue: { ServerQueueService(matchmaker: matchmaker, player: $0, lifecycle: lifecycle) },
                                      raceSession: { ServerRaceSessionService(matchmaker: matchmaker, player: $0, lifecycle: lifecycle) }),
            matchmaker: matchmaker, lifecycle: lifecycle)
    }

    /// `POST /dev/situation` (dev only): puts the test account in the contract situation asked for, and says how
    /// the client signs in for it. Only the suites this server serves: Identity and Terms (#145), Queue (#146),
    /// RaceSession (#148).
    func arrange(_ request: DevSituationRequest) async -> HTTPReply {
        let current = config.termsVersion
        func signedIn(accepting version: Int?, multiplayerRestricted: Bool = false,
                      then arrange: (QueueMatchmaker) async -> Void = { _ in }) async -> HTTPReply {
            do {
                _ = try await store.signIn(teamPlayerID: request.teamPlayerID, gamePlayerID: request.gamePlayerID, alias: "Contract")
                if let version { try await store.acceptTerms(playerID: request.teamPlayerID, version: version, at: sessions.now()) }
                if let matchmaker { await arrange(matchmaker) }
                return HTTPReply(.ok, json: DevSituationResponse(signIn: true, isMultiplayerGamingRestricted: multiplayerRestricted))
            } catch {
                return HTTPReply(.conflict, error: "can't arrange the test account: \(error)")
            }
        }
        let player = request.teamPlayerID
        if request.service == "QueueService", matchmaker == nil {
            return HTTPReply(.notFound, error: "this server has no queue")
        }
        if request.service == "RaceSessionService", matchmaker == nil || lifecycle == nil {
            return HTTPReply(.notFound, error: "this server has no races")
        }
        let account = AccountPlayer(teamPlayerID: request.teamPlayerID, gamePlayerID: request.gamePlayerID, alias: "Contract")
        let lifecycle = lifecycle
        /// A race of hers, arranged on the lifecycle, then `then` with its id.
        func raced(graceTicks: Int? = nil, pastGun: Bool = false,
                   then: @escaping (RaceLifecycle, UUID) async -> Void = { _, _ in }) async -> HTTPReply {
            await signedIn(accepting: current) { _ in
                guard let lifecycle else { return }
                do {
                    let race = try await lifecycle.arrangeRace(for: account, graceTicks: graceTicks, pastGun: pastGun)
                    await then(lifecycle, race)
                } catch {
                    FileHandle.standardError.write(Data("RegattaServer: can't arrange a race: \(error)\n".utf8))
                }
            }
        }
        switch (request.service, request.situation) {
        case ("IdentityService", "signedOut"): return HTTPReply(.ok, json: DevSituationResponse(signIn: false))
        case ("IdentityService", "signedIn"): return HTTPReply(.ok, json: DevSituationResponse(signIn: true))
        case ("IdentityService", "multiplayerRestricted"):
            return HTTPReply(.ok, json: DevSituationResponse(signIn: true, isMultiplayerGamingRestricted: true))
        case ("TermsService", "neverAccepted"): return await signedIn(accepting: nil)
        case ("TermsService", "accepted"): return await signedIn(accepting: current)
        case ("TermsService", "versionBumped"):
            guard current >= 2 else { return HTTPReply(.conflict, error: "versionBumped needs TERMS_VERSION of 2 or more") }
            return await signedIn(accepting: current - 1)
        // The queue (#146). Cooldown and suspension are dev-arranged in the matchmaker (#146 Q1): the real cooldown
        // rule is #147's, suspensions #26's.
        case ("QueueService", "joinable"): return await signedIn(accepting: current)
        case ("QueueService", "cooldown"):
            return await signedIn(accepting: current) { await $0.arrangeCooldown(player, seconds: Self.contractCooldownSeconds) }
        case ("QueueService", "suspended"):
            return await signedIn(accepting: current) { await $0.arrangeSuspension(player, until: nil) }
        case ("QueueService", "notSignedIn"): return HTTPReply(.ok, json: DevSituationResponse(signIn: false))
        case ("QueueService", "termsNotAccepted"): return await signedIn(accepting: nil)
        case ("QueueService", "multiplayerRestricted"): return await signedIn(accepting: current, multiplayerRestricted: true)
        // The race session (#148): a fleet locked by the queue, or a race of hers arranged on the lifecycle: past the gun
        // with her boat dropped (to rejoin), closing a second after it starts (every human gone, unrated), or cancelled.
        case ("RaceSessionService", "fleetLocked"): return await signedIn(accepting: current) { await $0.arrangeLock(account) }
        case ("RaceSessionService", "inProgress"): return await raced(pastGun: true)
        case ("RaceSessionService", "closed"): return await raced(graceTicks: 1)
        case ("RaceSessionService", "cancelled"):
            return await raced { lifecycle, race in await lifecycle.cancel(race, reason: .unspecified) }
        case ("RaceSessionService", "noRace"): return await signedIn(accepting: current)
        default:
            return HTTPReply(.notFound, error: "\(request.service).\(request.situation) isn't served yet")
        }
    }
}

extension ServiceEndpoint {
    /// The Queue contract's `cooldown` situation: long enough to show a countdown, short enough for the runner.
    static let contractCooldownSeconds: TimeInterval = 3
}

/// Fetches Game Center's certificate over HTTPS (HTTP/1.1 on NIO with NIOSSL: no FoundationNetworking on Linux). The
/// verifier has already checked the URL is Game Center's key host and path; the TLS trust is the system's, loaded
/// once into the context every fetch shares.
public struct HTTPSCertificateFetcher: CertificateFetching {
    /// Game Center's certificate is a couple of KB.
    static let maxBody = 64 * 1024
    let group: any EventLoopGroup
    let timeout: Duration
    let context: NIOSSLContext

    public init(group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton, timeout: Duration = .seconds(10)) throws {
        self.group = group
        self.timeout = timeout
        context = try NIOSSLContext(configuration: .makeClientConfiguration())
    }

    public enum FetchError: Error, Equatable, Sendable {
        case badURL
        case status(Int)
        case tooLarge
        case incomplete
    }

    /// The request line's target: the path and query as the URL encodes them (never decoded, so a `%0d%0a` stays
    /// three characters each and can't break the request line), and nothing outside printable ASCII.
    static func requestTarget(_ url: URL) throws -> String {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw FetchError.badURL }
        let path = parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath
        let target = path + (parts.percentEncodedQuery.map { "?" + $0 } ?? "")
        guard target.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }) else { throw FetchError.badURL }
        return target
    }

    public func fetch(_ url: URL) async throws -> [UInt8] {
        guard let host = url.host, url.scheme == "https" else { throw FetchError.badURL }
        let port = url.port ?? 443
        let path = try Self.requestTarget(url)
        let context = context
        let channel = try await ClientBootstrap(group: group)
            .connectTimeout(.seconds(Int64(timeout.components.seconds)))
            .connect(host: host, port: port) { channel in
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
            headers.add(name: "Connection", value: "close")
            try await outbound.write(contentsOf: [
                .head(HTTPRequestHead(version: .http1_1, method: .GET, uri: path, headers: headers)),
                .end(nil),
            ])
            var status = 0
            var body: [UInt8] = []
            for try await part in inbound {
                switch part {
                case .head(let head): status = Int(head.status.code)
                case .body(let buffer):
                    body += Array(buffer: buffer)
                    guard body.count <= Self.maxBody else { throw FetchError.tooLarge }
                case .end:
                    guard status == 200 else { throw FetchError.status(status) }
                    return body
                }
            }
            throw FetchError.incomplete
        }
    }
}
