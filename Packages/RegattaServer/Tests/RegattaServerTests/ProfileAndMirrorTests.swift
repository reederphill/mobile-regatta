import Crypto
import Foundation
import Persistence
import Ratings
import RegattaCore
import RegattaProtocol
@testable import RegattaServerKit
import RegattaServiceClient
import RegattaServiceContracts
import RegattaServices
import Synchronization
import Testing

private let someTime = Date(timeIntervalSince1970: 1_800_000_000)

private func established(_ rating: Double, deviation: Double = 70) -> PlayerRating {
    PlayerRating(glicko: Glicko2(rating: rating, deviation: deviation, volatility: 0.06), ratedRaces: 30, established: true, lastRatedAt: someTime)
}

/// #151: the profile's rating, badge, counts and suspension, from the rating and restriction stores.
@Suite struct ServerProfileServiceTests {
    static let player = AccountPlayer(teamPlayerID: "T:ann", gamePlayerID: "G:ann", alias: "Ann")

    @Test func ratingBadgeRacesWinsAndSuspension() async throws {
        let book = InMemoryRatingBook(), restrictions = InMemoryRestrictionStore()
        let service = ServerProfileService(player: Self.player, ratings: book, restrictions: restrictions, now: { someTime })

        // A new player: 1500 with the provisional badge, nothing counted, not suspended, a starter livery.
        let fresh = try await service.profile()
        #expect(fresh.rating == Rating(value: 1500, isProvisional: true))
        #expect(fresh.completedRaces == 0 && fresh.wins == 0 && fresh.suspension == nil)
        #expect(fresh.nickname == "Ann" && fresh.gamePlayerID == GamePlayerID("G:ann"))
        #expect(fresh.progress == EarnedProgress(earned: [], next: nil))
        #expect(try await service.profile().livery == fresh.livery, "the starter livery is stable")
        #expect(Livery.sailNumbers.contains(fresh.livery.sailNumber))

        // Rated, still provisional; then established: the badge goes, the number is the rounded rating.
        book.set(PlayerRating(glicko: Glicko2(rating: 1612.5, deviation: 140, volatility: 0.06), ratedRaces: 5), for: "T:ann")
        book.setStats(completedRaces: 7, wins: 2, for: "T:ann")
        var profile = try await service.profile()
        #expect(profile.rating == Rating(value: 1613, isProvisional: true) && profile.completedRaces == 7 && profile.wins == 2)
        book.set(established(1688.49), for: "T:ann")
        #expect(try await service.profile().rating == Rating(value: 1688, isProvisional: false))

        // A suspension shows with its end while it applies; a permanent one has none.
        try await restrictions.setSuspension("T:ann", StoredSuspension(until: someTime + 3_600))
        profile = try await service.profile()
        #expect(profile.suspension == RacingSuspension(until: Int64(someTime.timeIntervalSince1970) + 3_600))
        try await restrictions.setSuspension("T:ann", StoredSuspension(until: someTime - 1))
        #expect(try await service.profile().suspension == nil)
        try await restrictions.setSuspension("T:ann", .permanent)
        #expect(try await service.profile().suspension?.isPermanent == true)

        // An admin's reset: 1500, provisional again; the counts stay.
        #expect(try await book.reset("T:ann", reason: "test", at: someTime, config: RatingConfig()))
        profile = try await service.profile()
        #expect(profile.rating == Rating(value: 1500, isProvisional: true) && profile.completedRaces == 7)

        // Nobody signed in; and nothing stores a livery before #159.
        let nobody = ServerProfileService(player: nil, ratings: book, restrictions: restrictions)
        await #expect(throws: ProfileError.notSignedIn) { try await nobody.profile() }
        await #expect(throws: ProfileError.notSignedIn) { try await nobody.saveLivery(fresh.livery) }
        await #expect(throws: LiveryStorageUnavailable.self) { try await service.saveLivery(fresh.livery) }
    }

    /// The server's own wire test: the profile a client reads over `/service` is the server's, after a rated race.
    @Test func theProfileOverTheServiceEndpointShowsTheStoredRating() async throws {
        let archive = InMemoryRaceArchive()
        let endpoint = try ServiceEndpoint.make(config: .dev(), store: InMemoryAccountStore(), archive: archive)
        let (link, connection, _) = try await ServiceFixtures.signedIn(endpoint, "ann")
        _ = try await RemoteTermsService(connection).accept(TermsVersion(1))
        let profile = RemoteProfileService(connection)
        #expect(try await profile.profile().rating == Rating(value: 1500, isProvisional: true))

        let race = UUID()
        try await archive.register(race, players: [RaceSeatHolder(playerID: "T:ann", seat: 0), RaceSeatHolder(playerID: "T:bo", seat: 1)])
        try await archive.close(ClosedRaceRecord(
            id: race, log: Data(), digest: 1, simulationVersion: "s", toolchain: "t", results: Data(), incidents: Data(), rated: true,
            rating: RatingInput(participants: [.init(playerID: "T:ann", place: 1), .init(playerID: "T:bo", place: 2)], ratedAt: someTime),
            stats: [PlayerRaceStat(playerID: "T:ann", completed: true, won: true), PlayerRaceStat(playerID: "T:bo", completed: true, won: false)]))
        let after = try await profile.profile()
        #expect(after.rating == Rating(value: 1662, isProvisional: true) && after.completedRaces == 1 && after.wins == 1)
        #expect(after.nickname == "ann" && after.gamePlayerID == GamePlayerID("G:ann") && after.suspension == nil)
        link.close()
        await endpoint.matchmaker?.stop()
    }
}

/// The livery half of the profile, as #159 will provide it: here a fake, so the whole contract suite can run against
/// `ServerProfileService`'s rating, counts and suspension.
private final class FakeLiveries: LiveryProfileBackend {
    let catalogue: LiveryCatalogue
    let locked: Bool
    private let stored = Mutex<[String: Livery]>([:])

    init(catalogue: LiveryCatalogue, locked: Bool = false) {
        self.catalogue = catalogue
        self.locked = locked
    }

    func livery(of player: AccountPlayer) async throws -> Livery {
        if let own = stored.withLock({ $0[player.teamPlayerID] }) { return own }
        return try await StarterLiveries(boatClass: "skiff").livery(of: player)
    }

    func save(_ livery: Livery, for player: AccountPlayer) async throws -> Livery {
        guard !locked else { throw ProfileError.liveryLocked }
        do { try catalogue.validate(livery, boatClass: "skiff") } catch { throw ProfileError.invalidLivery(LiveryProblem(error)) }
        stored.withLock { $0[player.teamPlayerID] = livery }
        return livery
    }
}

@Suite struct ProfileServiceContractTests {
    /// The Profile contract suite, in process: the rating, counts and suspension are the server's; the livery and the
    /// earned designs are seam fakes. Passing it against the real server over `/service` is #159's gate.
    @Test func serverProfileServicePassesTheSuiteWithLiverySeamFakes() async throws {
        let catalogue = try #require(OnlineBriefing.catalogue)
        let milestones = [EarnedMilestone(design: DesignID("earned-10"), completedRaces: 10),
                          EarnedMilestone(design: DesignID("earned-50"), completedRaces: 50)]
        let progress: EarnedProgressSource = { _, completed in
            EarnedProgress(earned: milestones.filter { $0.completedRaces <= completed }.map(\.design),
                           next: milestones.first { $0.completedRaces > completed })
        }
        try await ProfileServiceContract().run { situation in
            let book = InMemoryRatingBook(), restrictions = InMemoryRestrictionStore()
            let player = AccountPlayer(teamPlayerID: "T:contract", gamePlayerID: "G:contract", alias: "Contract")
            switch situation {
            case .signedOut:
                return ServerProfileService(player: nil, ratings: book, restrictions: restrictions)
            case .newPlayer, .liveryLocked:
                break
            case .established:
                book.set(established(1730), for: player.teamPlayerID)
                book.setStats(completedRaces: 32, wins: 4, for: player.teamPlayerID)
            case .suspended:
                try await restrictions.setSuspension(player.teamPlayerID, StoredSuspension(until: Date() + 3_600))
            case .banned:
                try await restrictions.setSuspension(player.teamPlayerID, .permanent)
            }
            return ServerProfileService(player: player, ratings: book, restrictions: restrictions,
                                        liveries: FakeLiveries(catalogue: catalogue, locked: situation == .liveryLocked), progress: progress)
        }
    }
}

/// App Store Connect, mocked: what it was sent, and what it answers.
private final class MockLeaderboard: LeaderboardSubmitting {
    private let state = Mutex<(sent: [MirrorEntry], answers: [Int])>(([], []))

    /// The statuses the next submissions get, in order; 201 after them.
    func answer(_ statuses: [Int]) { state.withLock { $0.answers = statuses } }
    var sent: [MirrorEntry] { state.withLock { $0.sent } }

    func submit(_ entry: MirrorEntry) async throws {
        let status = state.withLock { state -> Int in
            state.sent.append(entry)
            return state.answers.isEmpty ? 201 : state.answers.removeFirst()
        }
        if status != 201 { throw LeaderboardSubmitError.status(status) }
    }
}

private final class MockPoster: HTTPSPosting {
    struct Request: Sendable {
        var host: String, path: String, bearer: String, json: Data
    }
    private let state = Mutex<[Request]>([])
    var requests: [Request] { state.withLock { $0 } }

    func post(host: String, path: String, bearer: String, json: Data) async throws -> Int {
        state.withLock { $0.append(Request(host: host, path: path, bearer: bearer, json: json)) }
        return 201
    }
}

/// #151: the Game Center leaderboard mirror, against a mocked App Store Connect.
@Suite struct LeaderboardMirrorTests {
    static func book(_ ratings: [String: PlayerRating]) -> InMemoryRatingBook {
        let book = InMemoryRatingBook()
        for (id, rating) in ratings {
            book.set(rating, for: id)
            book.bind(gamePlayerID: "G" + id.dropFirst(), to: id)
        }
        return book
    }

    static func decoded(_ part: Substring) throws -> [String: String] {
        var text = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        let object = try JSONSerialization.jsonObject(with: try #require(Data(base64Encoded: text))) as? [String: Any]
        return try #require(object).mapValues { "\($0)" }
    }

    private static func client(_ key: P256.Signing.PrivateKey, poster: MockPoster, now: @escaping @Sendable () -> Date = { someTime }) throws
        -> AppStoreConnectLeaderboard {
        try AppStoreConnectLeaderboard(
            config: AppStoreConnectConfig(keyID: "2X9R4HXF34", issuerID: "57246542-96fe-1a63-e053-0824d011072a",
                                          privateKeyPEM: key.pemRepresentation, leaderboardID: "regatta.rating", bundleID: "com.phillreeder.regatta"),
            poster: poster, now: now)
    }

    /// After a rated close, an established participant's rounded rating goes to App Store Connect: the documented
    /// POST, with a signed token and her gamePlayerID as `scopedPlayerId`; the body is the pinned fixture's.
    @Test func establishedRatingSubmittedWithJWTAndScopedPlayerID() async throws {
        let key = P256.Signing.PrivateKey(), poster = MockPoster()
        let book = Self.book(["T:ann": established(1712.5)])
        let mirror = LeaderboardMirror(book: book, submitter: try Self.client(key, poster: poster))
        await mirror.rated(["T:ann"])

        let request = try #require(poster.requests.first)
        #expect(poster.requests.count == 1)
        #expect(request.host == "api.appstoreconnect.apple.com" && request.path == "/v1/gameCenterLeaderboardEntrySubmissions")
        let fixture = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/leaderboard-submission.json"))
        let sent = try JSONSerialization.jsonObject(with: request.json) as? NSDictionary
        #expect(sent == (try JSONSerialization.jsonObject(with: fixture) as? NSDictionary))
        #expect(String(decoding: request.json, as: UTF8.self).contains("\"score\":1713"), "a number, not a string")
        let parts = request.bearer.split(separator: ".")
        #expect(parts.count == 3)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: try #require(Data(base64Encoded:
            parts[2].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "==")))
        #expect(key.publicKey.isValidSignature(signature, for: Data((parts[0] + "." + parts[1]).utf8)))
        #expect(book.mirroredRating(of: "T:ann") == 1713)
        #expect(await mirror.submitted == 1)
    }

    @Test func jwtClaims() async throws {
        let poster = MockPoster(), clock = Mutex(someTime)
        let client = try Self.client(P256.Signing.PrivateKey(), poster: poster, now: { clock.withLock { $0 } })
        let parts = try client.token(at: someTime).split(separator: ".")
        #expect(try Self.decoded(parts[0]) == ["alg": "ES256", "kid": "2X9R4HXF34", "typ": "JWT"])
        let issued = Int(someTime.timeIntervalSince1970)
        #expect(try Self.decoded(parts[1]) == ["iss": "57246542-96fe-1a63-e053-0824d011072a", "iat": "\(issued)", "exp": "\(issued + 1_200)",
                                                 "aud": "appstoreconnect-v1"])
        // One token serves 15 minutes of submissions, then a new one is signed.
        let entry = MirrorEntry(playerID: "T:a", gamePlayerID: "G:a", rating: 1500)
        try await client.submit(entry)
        clock.withLock { $0 += 14 * 60 }
        try await client.submit(entry)
        clock.withLock { $0 += 2 * 60 }
        try await client.submit(entry)
        let tokens = poster.requests.map(\.bearer)
        #expect(tokens[0] == tokens[1] && tokens[1] != tokens[2])
        #expect(try Self.decoded(tokens[2].split(separator: ".")[1])["iat"] == "\(issued + 16 * 60)")
        // Anything but 201 is a failure the mirror hears.
        struct Refusing: HTTPSPosting {
            func post(host: String, path: String, bearer: String, json: Data) async throws -> Int { 409 }
        }
        let refused = try AppStoreConnectLeaderboard(config: client.config, poster: Refusing())
        await #expect(throws: LeaderboardSubmitError.status(409)) { try await refused.submit(entry) }
    }

    @Test func provisionalNeverSubmitted() async throws {
        let leaderboard = MockLeaderboard()
        let provisional = PlayerRating(glicko: Glicko2(rating: 1820, deviation: 120, volatility: 0.06), ratedRaces: 6)
        let book = Self.book(["T:new": provisional, "T:old": established(1500)])
        let mirror = LeaderboardMirror(book: book, submitter: leaderboard)
        await mirror.rated(["T:new", "T:old", "T:unknown"])
        await mirror.sweep()
        #expect(leaderboard.sent == [MirrorEntry(playerID: "T:old", gamePlayerID: "G:old", rating: 1500)])
        #expect(book.mirroredRating(of: "T:new") == nil)
    }

    @Test func unchangedRatingNotResubmitted() async throws {
        let leaderboard = MockLeaderboard()
        let book = Self.book(["T:ann": established(1700.2)])
        let mirror = LeaderboardMirror(book: book, submitter: leaderboard)
        await mirror.rated(["T:ann"])
        // A race that moved her rating within the same whole number, and a sweep: nothing more is sent.
        book.set(established(1700.4), for: "T:ann")
        await mirror.rated(["T:ann"])
        await mirror.sweep()
        #expect(leaderboard.sent.map(\.rating) == [1700])
        // It falls: the lower rating is sent (the leaderboard keeps the most recent score, #55).
        book.set(established(1688.9), for: "T:ann")
        await mirror.rated(["T:ann"])
        #expect(leaderboard.sent.map(\.rating) == [1700, 1689])
    }

    /// App Store Connect is down, or rate limiting: each try is one retry at once, then the sweep tries again, and
    /// after `maxFailures` she is left alone until her rating changes. The close never waited on any of it.
    @Test func failureRetriedBySweepThenStops() async throws {
        let leaderboard = MockLeaderboard()
        let book = Self.book(["T:ann": established(1700)])
        var settings = LeaderboardMirrorSettings()
        settings.maxFailures = 3
        let mirror = LeaderboardMirror(book: book, submitter: leaderboard, settings: settings)

        // A 429 then a 201: the retry at once goes through.
        leaderboard.answer([429])
        await mirror.rated(["T:ann"])
        #expect(leaderboard.sent.count == 2 && book.mirroredRating(of: "T:ann") == 1700 && book.mirrorFailures(of: "T:ann") == 0)

        // Down for good: 2 tries per round, 3 rounds, then no more.
        book.set(established(1710), for: "T:ann")
        leaderboard.answer(Array(repeating: 503, count: 40))
        await mirror.rated(["T:ann"])
        #expect(leaderboard.sent.count == 4 && book.mirrorFailures(of: "T:ann") == 1 && book.mirroredRating(of: "T:ann") == 1700)
        for _ in 0..<4 { await mirror.sweep() }
        #expect(leaderboard.sent.count == 8 && book.mirrorFailures(of: "T:ann") == 3)
        #expect(await mirror.failed == 3)
        // A refusal that isn't transient is tried once per round.
        let other = MockLeaderboard()
        other.answer([403, 201])
        let strict = LeaderboardMirror(book: Self.book(["T:bo": established(1600)]), submitter: other)
        await strict.rated(["T:bo"])
        #expect(other.sent.count == 1)
        await strict.sweep()
        #expect(other.sent.count == 2)

        // Back up, and her rating changes at the next close: the failures are forgotten and it is sent.
        leaderboard.answer([])
        let archive = InMemoryRaceArchive(ratings: book)
        book.bind(gamePlayerID: "G:bo", to: "T:bo")
        let race = UUID()
        try await archive.register(race, players: [RaceSeatHolder(playerID: "T:ann", seat: 0), RaceSeatHolder(playerID: "T:bo", seat: 1)])
        try await archive.close(ClosedRaceRecord(
            id: race, log: Data(), digest: 1, simulationVersion: "s", toolchain: "t", results: Data(), incidents: Data(), rated: true,
            rating: RatingInput(participants: [.init(playerID: "T:ann", place: 1), .init(playerID: "T:bo", place: 2)], ratedAt: someTime + 86_400)))
        await mirror.rated(["T:ann", "T:bo"])
        #expect(leaderboard.sent.count == 9 && leaderboard.sent.last?.playerID == "T:ann", "the new player is provisional: not sent")
        #expect(book.mirroredRating(of: "T:ann") == leaderboard.sent.last?.rating)
    }

    /// A submission that never answers is given up at the timeout; the mirror goes on.
    @Test func aHungSubmissionTimesOut() async throws {
        struct Hung: LeaderboardSubmitting {
            func submit(_ entry: MirrorEntry) async throws { try await Task.sleep(for: .seconds(60)) }
        }
        var settings = LeaderboardMirrorSettings()
        settings.timeout = .milliseconds(50)
        let book = Self.book(["T:ann": established(1700), "T:bo": established(1600), "T:cy": established(1500)])
        let mirror = LeaderboardMirror(book: book, submitter: Hung(), settings: settings)
        let started = ContinuousClock.now
        await mirror.rated(["T:ann", "T:bo", "T:cy"])
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(await mirror.failed == 3 && book.mirrorFailures(of: "T:ann") == 1)
    }

    @Test func theServerConfigReadsTheMirrorSettings() throws {
        let base = ["ENV": "dev"]
        #expect(try ServerConfig.load(from: base).leaderboard == nil)
        #expect(try ServerConfig.load(from: base).lifecycle.rating.weightExponent == 0.5)
        var env = base
        env["RATING_WEIGHT_EXPONENT"] = "0.4"
        #expect(try ServerConfig.load(from: env).lifecycle.rating.weightExponent == 0.4)
        env["RATING_WEIGHT_EXPONENT"] = "2"
        #expect(throws: ServerConfigError.self) { try ServerConfig.load(from: env) }

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("regatta-asc-\(UUID().uuidString).pem")
        try P256.Signing.PrivateKey().pemRepresentation.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        env = base.merging(["ASC_KEY_ID": "K", "ASC_ISSUER_ID": "I", "ASC_PRIVATE_KEY_PEM": file.path, "GC_LEADERBOARD_ID": "regatta.rating",
                            "LEADERBOARD_SWEEP_SECONDS": "60"]) { $1 }
        let config = try ServerConfig.load(from: env)
        #expect(config.leaderboard?.keyID == "K" && config.leaderboard?.leaderboardID == "regatta.rating")
        #expect(config.leaderboard?.bundleID == config.identity.bundleID && config.leaderboardMirror.sweepInterval == .seconds(60))
        // Half a key is a mistake, not "off"; and the file must hold a P-256 private key.
        env["ASC_ISSUER_ID"] = nil
        #expect(throws: ServerConfigError.self) { try ServerConfig.load(from: env) }
        env["ASC_ISSUER_ID"] = "I"
        env["ASC_PRIVATE_KEY_PEM"] = "/nonexistent.pem"
        #expect(throws: ServerConfigError.self) { try ServerConfig.load(from: env) }
    }
}

/// #151: the briefing shows each human's stored rating, read once for the fleet; the number alone.
@Suite struct BriefingRatingTests {
    @Test func humansCarryStoredRatings() async throws {
        let clock = VirtualClock(), log = LaunchLog()
        let book = InMemoryRatingBook()
        book.set(established(1721.6), for: "T:0")
        book.set(PlayerRating(glicko: Glicko2(rating: 1388.2, deviation: 200, volatility: 0.06), ratedRaces: 3), for: "T:1")
        let reads = Mutex(0)
        let queue = QueueMatchmaker(settings: QueueSettings(), registry: RaceRegistry(),
                                    draw: RaceDraw(pairings: OnlinePairing.bundled(), seeds: FixtureWindSeedPools(poolSize: 8)),
                                    tokenKey: QueueMatchmakerTests.key, tokenLifetime: 600, random: SeededRandom(seed: 151),
                                    now: { clock.now },
                                    fleetRatings: { humans in
                                        reads.withLock { $0 += 1 }
                                        return try await book.ratings(of: humans.map(\.teamPlayerID)).mapValues(\.displayed)
                                    },
                                    launch: { fleet, closed in try await log.record(fleet, closed) })
        for index in 0..<3 { try await queue.join(QueueMatchmakerTests.player(index)) }
        clock.advance(60)
        await queue.step()
        let fleet = try #require(await log.fleets.first)
        #expect(reads.withLock { $0 } == 1, "one read for the fleet")
        #expect(fleet.ratings == [1722, 1388, 1500], "the stored rating rounded; a new player's 1500")
        #expect(fleet.fill.medianRating == 1500)
        let briefing = try #require(try await queue.handOff(for: "T:2").briefing)
        #expect(briefing.fleet.prefix(3).map(\.rating) == [1722, 1388, 1500])
        #expect(briefing.fleet.dropFirst(3).allSatisfy { $0.isBot && $0.rating == nil })
        await queue.stop()

        // A store that fails: everyone counts as 1500 and the fleet still locks.
        struct Down: Error {}
        let other = VirtualClock(), launches = LaunchLog()
        let failing = QueueMatchmaker(settings: QueueSettings(), registry: RaceRegistry(),
                                      draw: RaceDraw(pairings: OnlinePairing.bundled(), seeds: FixtureWindSeedPools(poolSize: 8)),
                                      tokenKey: QueueMatchmakerTests.key, tokenLifetime: 600, random: SeededRandom(seed: 151),
                                      now: { other.now }, fleetRatings: { _ in throw Down() },
                                      launch: { fleet, closed in try await launches.record(fleet, closed) })
        for index in 0..<2 { try await failing.join(QueueMatchmakerTests.player(index)) }
        other.advance(60)
        await failing.step()
        #expect(try #require(await launches.fleets.first).ratings == [1500, 1500])
        await failing.stop()
    }
}
