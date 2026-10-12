import ChatFilter
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
    /// registered, streamed and closed by the lifecycle (#148) into `archive` (memory by default: a dev server); its
    /// suspensions, attestation flags and briefing-leave cooldowns in `restrictions` (#147). Ratings (#151) are read
    /// from `ratings` (an in-memory archive's own book by default, so a dev server shows what its closes rated): one
    /// read per fleet lock for the briefing and the bots' level, one per profile request. With `config.leaderboard`
    /// the Game Center leaderboard mirrors each rated close (`submitter`: App Store Connect unless a test passes one).
    ///
    /// The lobby (#152) keeps its lines and blocks in `lobbyStore` (memory by default). Its free text is filtered by
    /// `wordList` (the build's bundled list unless a test passes one; a build without one starts only in dev, on the
    /// dev phrases alone) and then by `classifier`: OpenAI's, only when its key is configured, unless a test passes
    /// one.
    ///
    /// Moderation (#153) keeps its reports and penalties in `moderationStore` (memory by default): the lobby's
    /// standings and reports, race reports read from `archive`, racing suspensions written to `restrictions`, and
    /// nicknames it overrode shown from sign-in. The nightly fair-play scan (#155) reads `archive`'s races and raises
    /// its flags in `moderationStore`.
    ///
    /// Usage analytics (#156) go to `analyticsStore` (memory by default), rolled up and purged by the retention job the
    /// HTTP server runs; so do the measures (#157): the queue's waits, fleets and briefing leaves, and each seat's round
    /// trips, read back with the window's races by the admin routes. Players' liveries (#159) are kept in `liveryStore` (memory by default): the profile stores and
    /// shows them, the briefing reads them at fleet lock, the lobby shows their chips, and a close that earns a design
    /// tells analytics.
    ///
    /// Delete my online data and the retention job (#160) erase through `onlineData`: Postgres's in production; by
    /// default, over the in-memory stores when the accounts are in memory (none otherwise). A deleted player's
    /// leaderboard scores are blocked by `scoreBlocker`: App Store Connect's when the leaderboard's resource id is
    /// configured, unless a test passes one.
    public static func make(config: ServerConfig, store: any AccountStore, archive: any RaceArchive = InMemoryRaceArchive(),
                            restrictions: any RestrictionStore = InMemoryRestrictionStore(), ratings: (any RatingBook)? = nil,
                            registry: RaceRegistry? = nil, fetcher: (any CertificateFetching)? = nil,
                            submitter: (any LeaderboardSubmitting)? = nil, lobbyStore: (any LobbyStore)? = nil,
                            wordList: ChatWordList? = nil, classifier: (any ToxicityClassifier)? = nil,
                            moderationStore: (any ModerationStore)? = nil, analyticsStore: (any AnalyticsStore)? = nil,
                            liveryStore: (any LiveryStore)? = nil, onlineData: (any OnlineDataStore)? = nil,
                            scoreBlocker: (any ScoreBlocking)? = nil) throws -> ServiceEndpoint {
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
        let book: any RatingBook = ratings ?? (archive as? InMemoryRaceArchive)?.ratings ?? InMemoryRatingBook()
        let rating = config.lifecycle.rating
        var sender = submitter
        if sender == nil, let key = config.leaderboard { sender = try AppStoreConnectLeaderboard(config: key, poster: try NIOHTTPSPoster()) }
        var rated: (@Sendable ([String]) -> Void)?
        if let sender {
            let mirror = LeaderboardMirror(book: book, submitter: sender, settings: config.leaderboardMirror)
            rated = { players in Task { await mirror.rated(players) } }
            Task { await mirror.start() }
        }
        let words = try chatWordList(config: config) { try wordList ?? ChatWordList.bundled() }
        var checker = classifier
        if checker == nil, let key = config.chat.moderationKey { checker = try OpenAIModerationClassifier(key: key) }
        var lobbySettings = config.chat.lobby
        lobbySettings.rating = rating
        // The livery lock reads the queue, which is made below and reads the liveries.
        let queueBox = LateBound<QueueMatchmaker>()
        let liveryStore = liveryStore ?? InMemoryLiveryStore(), moderationStore = moderationStore ?? InMemoryModerationStore()
        let lobbyStore = lobbyStore ?? InMemoryLobbyStore()
        let liveries = StoredLiveries(store: liveryStore, ratings: book,
                                      isLocked: { await queueBox.value?.holdsLivery($0) ?? false })
        let moderation = Moderation(store: moderationStore, restrictions: restrictions, ratings: book,
                                    ratingConfig: rating, seats: { try await archive.seating(of: $0) })
        let hub = LobbyHub(settings: lobbySettings, store: lobbyStore, ratings: book,
                           moderation: moderation, wordList: words, classifier: checker.map { ClassifierGate($0) },
                           chip: { await liveries.chip(of: $0) })
        moderation.attach(hub)
        let analyticsStore = analyticsStore ?? InMemoryAnalyticsStore()
        let online: (any OnlineDataStore)? = onlineData ?? (store as? InMemoryAccountStore).map {
            InMemoryOnlineData(accounts: $0, ratings: book as? InMemoryRatingBook, liveries: liveryStore as? InMemoryLiveryStore,
                               lobby: lobbyStore as? InMemoryLobbyStore, moderation: moderationStore as? InMemoryModerationStore,
                               archive: archive as? InMemoryRaceArchive, analytics: analyticsStore as? InMemoryAnalyticsStore)
        }
        var blocker = scoreBlocker
        if blocker == nil, let key = config.leaderboard, let resource = key.leaderboardResourceID {
            let poster = try NIOHTTPSPoster()
            blocker = AppStoreConnectScoreModeration(tokens: try AppStoreConnectLeaderboard(config: key, poster: poster),
                                                     leaderboardResourceID: resource, requester: poster)
        }
        // The queue is made below and reads the lobby, which this tells: it reaches the queue late.
        let deletion = online.map { OnlineDataDeletion(store: $0, scores: blocker, beforeErase: { await queueBox.value?.forget($0) }) }
        deletion?.attach(hub)
        let retention = deletion.map { RetentionJobs(deletion: $0, moderation: moderationStore, lobby: hub) }
        let analytics = AnalyticsIngest(settings: config.analytics, store: analyticsStore)
        let measures = ServerMeasures(analytics: analytics, archive: archive, ratings: book, pingInterval: config.roundTripPingInterval)
        let unlocks = EarnedUnlocks(ratings: book, earned: liveries.earned, analytics: analytics)
        let lifecycle = RaceLifecycle(settings: config.lifecycle, archive: archive, tokenKey: config.tokenKey,
                                      tokenLifetime: config.tokenLifetime, toolchain: config.serverBuild, registry: registry, rated: rated,
                                      completed: { players in Task { await unlocks.completed(players) } }, lobby: hub)
        let matchmaker = QueueMatchmaker(
            settings: queue, registry: registry,
            draw: RaceDraw(pairings: OnlinePairing.bundled(venues: queue.venues),
                           seeds: FixtureWindSeedPools(poolSize: queue.windSeedPoolSize, reuseCap: queue.windSeedReuseCap)),
            tokenKey: config.tokenKey, tokenLifetime: config.tokenLifetime, restrictions: restrictions, runningRaces: lifecycle,
            liveries: { await liveries.raceLivery(of: $0) },
            fleetRatings: { humans in try await book.ratings(of: humans.map(\.teamPlayerID)).mapValues(\.displayed) },
            seatReleased: { await lifecycle.seatReleased($0, race: $1) }, lobby: hub, launch: lifecycle.launcher(),
            events: { measures.queue($0) })
        queueBox.set(matchmaker)
        let earned = liveries.earned
        return ServiceEndpoint(
            config: ServiceEndpointConfig(termsVersion: identity.termsVersion, sessionLifetime: identity.sessionLifetime,
                                          streamIdleTimeout: identity.streamIdleTimeout, frameCap: identity.frameCap,
                                          signInDeadline: identity.signInDeadline, idleTimeout: identity.connectionIdleTimeout,
                                          serverBuild: config.serverBuild),
            sessions: SessionAuthority(store: store, verifier: verifier, lifetime: identity.sessionLifetime,
                                       absoluteLifetime: identity.absoluteSessionLifetime,
                                       maxSessionsPerPlayer: identity.maxSessionsPerPlayer,
                                       nickname: { player in
                                           guard try await moderation.nicknameOverridden(player.teamPlayerID) else { return player.alias }
                                           return Moderation.overriddenNickname(sailNumber: try await liveries.livery(of: player).sailNumber)
                                       },
                                       signedIn: { player in
                                           do {
                                               try await moderation.syncSuspension(player.teamPlayerID)
                                           } catch {
                                               Moderation.log("can't write \(player.teamPlayerID)'s suspension at sign-in: \(error)")
                                           }
                                       }),
            backends: ServiceBackends(queue: { ServerQueueService(matchmaker: matchmaker, player: $0, lifecycle: lifecycle) },
                                      raceSession: { ServerRaceSessionService(matchmaker: matchmaker, player: $0, lifecycle: lifecycle) },
                                      lobby: { ServerLobbyService(hub: hub, player: $0) },
                                      profile: { ServerProfileService(player: $0, ratings: book, restrictions: restrictions, liveries: liveries,
                                                                      progress: { earned.progress(completedRaces: $1) }, config: rating) },
                                      analytics: { analytics.service(for: $0) },
                                      deletion: { player in deletion.map { ServerDataDeletionService(deletion: $0, player: player) } }),
            matchmaker: matchmaker, lifecycle: lifecycle, lobby: hub, analytics: analytics,
            analyticsRetention: AnalyticsRetention(settings: config.analytics, store: analyticsStore), ratings: book,
            moderation: moderation, deletion: deletion, retention: retention, archive: archive,
            fairPlay: FairPlayJob(store: moderationStore, archive: archive), measures: measures)
    }

    /// The lobby's word list (#152, owner 2026-10-11: the offline list always applies). Outside `ENV=dev` it is the
    /// build's list, and a build without one doesn't start. A dev server without one says so and goes on; in dev the
    /// extra phrases are added.
    static func chatWordList(config: ServerConfig, bundled: () throws -> ChatWordList) throws -> ChatWordList {
        let isDev = config.environment.isDev
        do {
            let words = try bundled()
            return isDev ? words.adding(config.chat.extraBlockedPhrases) : words
        } catch {
            guard isDev else { throw ServerConfigError.invalid(variable: "the chat word list", value: "(not bundled)", expected: "\(error)") }
            FileHandle.standardError.write(Data("RegattaServer: \(error): free text is filtered by CHAT_EXTRA_BLOCKED_PHRASES alone (dev)\n".utf8))
            return ChatWordList.empty.adding(config.chat.extraBlockedPhrases)
        }
    }

    /// `POST /dev/situation` (dev only): puts the test account in the contract situation asked for, and says how
    /// the client signs in for it. Only the suites this server serves: Identity and Terms (#145), Queue (#146),
    /// RaceSession (#148), Lobby (#152, its reports #153), AnalyticsTransport (#156), Profile (#159), DataDeletion (#160).
    func arrange(_ request: DevSituationRequest) async -> HTTPReply {
        let current = config.termsVersion
        func signedIn(accepting version: Int?, multiplayerRestricted: Bool = false, underage: Bool = false,
                      then arrange: (QueueMatchmaker) async -> Void = { _ in }) async -> HTTPReply {
            do {
                _ = try await store.signIn(teamPlayerID: request.teamPlayerID, gamePlayerID: request.gamePlayerID, alias: "Contract")
                if let version { try await store.acceptTerms(playerID: request.teamPlayerID, version: version, at: sessions.now()) }
                if let matchmaker { await arrange(matchmaker) }
                return HTTPReply(.ok, json: DevSituationResponse(signIn: true, isUnderage: underage,
                                                                 isMultiplayerGamingRestricted: multiplayerRestricted))
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
        if request.service == "LobbyService", lobby == nil || matchmaker == nil {
            return HTTPReply(.notFound, error: "this server has no lobby")
        }
        if request.service == "AnalyticsTransport", analytics == nil {
            return HTTPReply(.notFound, error: "this server takes no analytics")
        }
        if request.service == "ProfileService", matchmaker == nil || ratings == nil {
            return HTTPReply(.notFound, error: "this server has no profiles")
        }
        if request.service == "DataDeletionService", deletion == nil || lobby == nil {
            return HTTPReply(.notFound, error: "this server deletes no online data")
        }
        let account = AccountPlayer(teamPlayerID: request.teamPlayerID, gamePlayerID: request.gamePlayerID, alias: "Contract")
        let lifecycle = lifecycle, lobby = lobby, analytics = analytics, ratings = ratings, moderation = moderation, deletion = deletion
        /// The test account's online data gone, as a deletion takes it, so each Data Deletion situation starts clean.
        func forgotten() async {
            do {
                _ = try await deletion?.erase(player, reason: .request)
            } catch {
                FileHandle.standardError.write(Data("RegattaServer: can't clear the test account: \(error)\n".utf8))
            }
        }
        /// The lobby, open to her (#152): free text unlocked unless `locked`, and the room holding a system line and then
        /// a line by another player, seeded here. `standing`: hers, given by the "dev" admin (#153). The contract's race
        /// is seated: her in seat 0, the other player in 1, a bot in 2.
        func lobbyOpen(locked: Bool = false, standing: ChatStanding = .clear) async -> HTTPReply {
            await signedIn(accepting: current) { _ in
                guard let lobby else { return }
                if !locked { lobby.devUnlock(player) }
                let other = AccountPlayer(teamPlayerID: player + "-other", gamePlayerID: request.gamePlayerID + "-other", alias: "Contract Crew")
                do {
                    try await moderation?.devSet(standing, for: player)
                } catch {
                    FileHandle.standardError.write(Data("RegattaServer: can't arrange a chat standing: \(error)\n".utf8))
                }
                moderation?.devSeat(Self.contractRace, RaceSeating(humans: [RaceSeatHolder(playerID: player, seat: 0),
                                                                           RaceSeatHolder(playerID: other.teamPlayerID, seat: 1)]))
                guard (try? await store.signIn(teamPlayerID: other.teamPlayerID, gamePlayerID: other.gamePlayerID, alias: other.alias)) != nil else { return }
                lobby.gun(race: UUID(), venue: "Dev Bay", boats: 10, humans: 2)
                await lobby.settled()
                await lobby.devPost("fair winds", by: other)
            }
        }
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
        // The queue (#146). Cooldown and suspension are written to the restriction store (#147), as the briefing-leave
        // rule and #153's suspensions write them.
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
        // The lobby (#152). `racing`: the queue locks her fleet (the silence window), and she gives her seat up a
        // moment after her feed has opened, so the feed shows the lobby opening again.
        case ("LobbyService", "open"): return await lobbyOpen()
        case ("LobbyService", "freeTextLocked"): return await lobbyOpen(locked: true)
        case ("LobbyService", "muted"):
            return await lobbyOpen(standing: .muted(until: Int64(sessions.now().timeIntervalSince1970) + 3600, isAutomatic: false))
        case ("LobbyService", "banned"): return await lobbyOpen(standing: .banned)
        case ("LobbyService", "racing"):
            return await signedIn(accepting: current) { matchmaker in
                guard let lobby, let race = await matchmaker.arrangeLock(account) else { return }
                lobby.devAfterNextFeed(of: player) {
                    try? await Task.sleep(for: Self.contractSilenceHold)
                    await matchmaker.arrangeRelease(player, race: race)
                }
            }
        case ("LobbyService", "notSignedIn"): return HTTPReply(.ok, json: DevSituationResponse(signIn: false))
        case ("LobbyService", "termsNotAccepted"): return await signedIn(accepting: nil)
        case ("LobbyService", "communicationRestricted"): return await signedIn(accepting: current, underage: true)
        // Analytics (#156): the suite sends as a fresh install each run, so `accepting` needs nothing cleared.
        // `unavailable`: her batches are answered as a store that can't be reached.
        case ("AnalyticsTransport", "accepting"): return await signedIn(accepting: current)
        case ("AnalyticsTransport", "unavailable"):
            return await signedIn(accepting: current) { _ in analytics?.devSetUnavailable(player) }
        // The profile (#159). `established`: 12 completed races and 2 wins, set on the dev server's in-memory rating
        // book (the first earned design is at 10); `liveryLocked`: the queue locks her fleet now.
        case ("ProfileService", "signedOut"): return HTTPReply(.ok, json: DevSituationResponse(signIn: false))
        case ("ProfileService", "newPlayer"): return await signedIn(accepting: current)
        case ("ProfileService", "established"):
            guard let book = ratings as? InMemoryRatingBook else { return HTTPReply(.notFound, error: "established needs the dev server's rating book") }
            return await signedIn(accepting: current) { _ in book.setStats(completedRaces: 12, wins: 2, for: player) }
        case ("ProfileService", "suspended"):
            return await signedIn(accepting: current) { await $0.arrangeSuspension(player, until: Int64(sessions.now().timeIntervalSince1970) + 3600) }
        case ("ProfileService", "banned"): return await signedIn(accepting: current) { await $0.arrangeSuspension(player, until: nil) }
        case ("ProfileService", "liveryLocked"): return await signedIn(accepting: current) { await $0.arrangeLock(account) }
        // Delete my online data (#160). `hasOnlineData`: every kind the server holds, on the dev server's in-memory
        // stores, and a line of hers in the lobby; `nothingHeld`: signed in, terms not yet accepted, nothing else.
        case ("DataDeletionService", "signedOut"): return HTTPReply(.ok, json: DevSituationResponse(signIn: false))
        case ("DataDeletionService", "nothingHeld"):
            await forgotten()
            return await signedIn(accepting: nil)
        case ("DataDeletionService", "hasOnlineData"):
            guard let memory = deletion?.store as? InMemoryOnlineData else {
                return HTTPReply(.notFound, error: "hasOnlineData needs the dev server's in-memory stores")
            }
            await forgotten()
            return await signedIn(accepting: current) { _ in
                do {
                    try await memory.devHoldEverything(account, reporting: player + "-other", at: sessions.now())
                } catch {
                    FileHandle.standardError.write(Data("RegattaServer: can't arrange online data: \(error)\n".utf8))
                }
                await lobby?.devPost("fair winds", by: account)
            }
        default:
            return HTTPReply(.notFound, error: "\(request.service).\(request.situation) isn't served yet")
        }
    }
}

extension ServiceEndpoint {
    /// The Queue contract's `cooldown` situation: long enough to show a countdown, short enough for the runner.
    static let contractCooldownSeconds: TimeInterval = 3
    /// The Lobby contract's `racing` situation: how long after her feed opens she stays silent. Long enough for the
    /// suite to read the feed's first words and the state they must equal, one call later.
    static let contractSilenceHold: Duration = .seconds(2)
    /// The Lobby contract's race (`LobbyServiceContract.race`), whose seats it reports.
    static let contractRace = RaceID("contract-race")
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
