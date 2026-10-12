import Foundation
import NIOHTTP1
import Persistence
import RegattaAdminClient
import RegattaCore
import RegattaProtocol
@testable import RegattaServerKit
import RegattaServices
import Testing

/// The admin tool's stores and the API over them (#154), on a virtual clock: memory, or Postgres.
struct AdminWorld {
    static let token = String(repeating: "a", count: 40)
    static let other = String(repeating: "b", count: 40)

    let store: any ModerationStore
    let restrictions: any RestrictionStore
    let ratings: any RatingBook
    let accounts: any AccountStore
    let clock = VirtualClock()
    let moderation: Moderation
    let api: AdminAPI

    init(store: any ModerationStore = InMemoryModerationStore(), restrictions: any RestrictionStore = InMemoryRestrictionStore(),
         ratings: any RatingBook = InMemoryRatingBook(), accounts: any AccountStore = InMemoryAccountStore(),
         archive: (any RaceArchive)? = nil) {
        self.store = store
        self.restrictions = restrictions
        self.ratings = ratings
        self.accounts = accounts
        let clock = clock
        moderation = Moderation(store: store, restrictions: restrictions, ratings: ratings,
                                seats: { race in try await archive?.seating(of: race) }, now: { clock.now })
        api = AdminAPI(settings: AdminSettings(tokens: [Self.token: "alice", Self.other: "bob"]), moderation: moderation, archive: archive)
    }

    /// The API's answer to `method path?query` as `token`'s admin.
    func call(_ method: HTTPMethod, _ uri: String, token: String? = AdminWorld.token) async -> (status: HTTPResponseStatus, json: [String: Any]) {
        var headers = HTTPHeaders()
        if let token { headers.add(name: "Authorization", value: "Bearer \(token)") }
        let (path, query) = RequestHandler.split(uri)
        let reply = await api.respond(method: method, path: path, query: query, headers: headers)
        return (reply.status, (try? JSONSerialization.jsonObject(with: Data(reply.body))) as? [String: Any] ?? [:])
    }

    /// A pending report filed now, due a day later.
    func file(_ kind: StoredReport.Kind, by reporter: String, on subject: String, race: UUID? = nil, seat: Int? = nil) async throws -> StoredReport {
        let now = clock.now
        return try await store.file(StoredReport(
            kind: kind, reporterID: reporter, subjectID: subject, subjectNickname: subject.replacingOccurrences(of: "T:", with: ""),
            messageID: kind == .message ? 7 : nil, messageBody: kind == .message ? "you sail like a crab" : nil,
            messagePostedAt: kind == .message ? now : nil, raceID: kind == .race ? (race ?? UUID()).uuidString : nil,
            seat: kind == .race ? (seat ?? 1) : nil, reason: kind == .race ? .unsportingConduct : nil, createdAt: now, dueAt: now + 24 * 3600))
    }

    func signIn(_ names: [String]) async throws {
        for name in names { _ = try await accounts.signIn(teamPlayerID: "T:\(name)", gamePlayerID: "G:\(name)", alias: name) }
    }
}

/// Every admin action, and the store state it leaves (acceptance #154). Run on memory here, on Postgres in
/// `AdminAPIPersistenceTests`.
enum AdminScenario {
    static func run(_ world: AdminWorld) async throws {
        try await world.signIn(["wren", "gull", "skua", "tern"])
        let line = try await world.file(.message, by: "T:wren", on: "T:gull")
        world.clock.advance(60)
        let nickname = try await world.file(.player, by: "T:wren", on: "T:skua")
        world.clock.advance(60)
        let racing = try await world.file(.race, by: "T:tern", on: "T:gull")

        // The queue, the first due first.
        let queue = await world.call(.GET, "/admin/queue")
        #expect(queue.status == .ok)
        let items = try #require(queue.json["items"] as? [[String: Any]])
        #expect(items.compactMap { $0["id"] as? Int } == [line.id, nickname.id, racing.id].map(Int.init))
        #expect(items.allSatisfy { $0["type"] as? String == "report" && $0["overdue"] as? Bool == false })
        let detail = await world.call(.GET, "/admin/reports/\(line.id)")
        #expect((detail.json["report"] as? [String: Any])?["messageBody"] as? String == "you sail like a crab")
        #expect((detail.json["otherReports"] as? [[String: Any]])?.compactMap { $0["id"] as? Int } == [Int(racing.id)])

        // An upheld chat report: decided by her, and the first step of the ladder.
        #expect(await world.call(.POST, "/admin/reports/\(line.id)/decide?decision=uphold_chat").status == .ok)
        let decided = try #require(try await world.store.report(line.id))
        #expect(decided.decision == .upheld && decided.decidedBy == "alice" && decided.decidedAt == world.clock.now)
        var gull = try await world.store.penalties(of: "T:gull")
        #expect(gull.count == 1 && gull[0].kind == .chatMute && gull[0].actorID == "alice" && gull[0].reportID == line.id)
        #expect(gull[0].endsAt == world.clock.now + 24 * 3600)
        // Decided once only; a decision that doesn't fit the report is refused.
        #expect(await world.call(.POST, "/admin/reports/\(line.id)/decide?decision=dismiss").status == .conflict)
        #expect(await world.call(.POST, "/admin/reports/\(racing.id)/decide?decision=uphold_chat").status == .unprocessableEntity)
        #expect(await world.call(.POST, "/admin/reports/\(racing.id)/decide?decision=jail").status == .badRequest)
        #expect(await world.call(.POST, "/admin/reports/999999/decide?decision=dismiss").status == .notFound)

        // A nickname override from a player report.
        #expect(await world.call(.POST, "/admin/reports/\(nickname.id)/decide?decision=override_nickname").status == .ok)
        #expect(try await world.store.penalties(of: "T:skua").map(\.kind) == [.nicknameOverride])
        #expect(try await world.moderation.nicknameOverridden("T:skua"))

        // A race report upheld with a suspension: written where the queue reads it, by bob.
        #expect(await world.call(.POST, "/admin/reports/\(racing.id)/decide?decision=suspension_24h", token: AdminWorld.other).status == .ok)
        gull = try await world.store.penalties(of: "T:gull")
        let suspension = try #require(gull.first { $0.kind == .racingSuspension })
        #expect(suspension.actorID == "bob" && suspension.reportID == racing.id && suspension.endsAt == world.clock.now + 24 * 3600)
        #expect(try await world.restrictions.restrictions(of: "T:gull").suspension?.until == world.clock.now + 24 * 3600)
        #expect(try await world.store.pending(limit: 10).isEmpty)

        // Penalties outright: a warning, the next chat step, a rating reset, a nickname override.
        #expect(await world.call(.POST, "/admin/players/T:gull/penalize?penalty=warning").status == .ok)
        #expect(await world.call(.POST, "/admin/players/T:gull/mute").status == .ok)
        gull = try await world.store.penalties(of: "T:gull")
        #expect(gull.map(\.kind) == [.chatMute, .racingSuspension, .racingWarning, .chatMute])
        #expect(gull[3].endsAt == world.clock.now + 7 * 86_400 && gull[3].reportID == nil)
        #expect(await world.call(.POST, "/admin/players/T:tern/penalize?penalty=rating_reset").status == .ok)
        #expect(try await world.store.penalties(of: "T:tern").map(\.kind) == [.ratingReset])
        #expect(try await world.ratings.ratings(of: ["T:tern"])["T:tern"]?.glicko.rating == 1500)
        #expect(await world.call(.POST, "/admin/players/T:tern/nickname-override").status == .ok)
        #expect(try await world.moderation.nicknameOverridden("T:tern"))
        #expect(await world.call(.POST, "/admin/players/T:tern/penalize?penalty=keelhaul").status == .badRequest)

        // Lifting the suspension clears it where the queue reads it.
        let lifted = await world.call(.POST, "/admin/players/T:gull/penalties/\(suspension.id)/lift")
        #expect(lifted.status == .ok)
        #expect(try await world.store.penalties(of: "T:gull").first { $0.id == suspension.id }?.liftedBy == "alice")
        #expect(try await world.restrictions.restrictions(of: "T:gull").suspension == nil)
        #expect(await world.call(.POST, "/admin/players/T:wren/penalties/\(suspension.id)/lift").status == .notFound)

        // The player view.
        let player = await world.call(.GET, "/admin/players/T:gull")
        #expect(player.json["chat"] as? String == "muted" && (player.json["penalties"] as? [Any])?.count == 4)
        #expect((player.json["reports"] as? [Any])?.count == 2)

        // Every action is in the audit, newest first, with who took it.
        let actions = try await world.store.actions(about: nil, limit: 50)
        #expect(actions.map(\.action) == ["lift_penalty", "override_nickname", "penalize", "mute", "penalize", "decide_report", "decide_report",
                                          "decide_report"])
        #expect(actions.allSatisfy { $0.at == world.clock.now })
        #expect(actions.first { $0.reportID == racing.id }?.actorID == "bob")
        #expect(actions.first { $0.reportID == racing.id }?.detail == "suspension_24h")
        let audit = await world.call(.GET, "/admin/audit?player=T:tern")
        #expect((audit.json["actions"] as? [[String: Any]])?.compactMap { $0["action"] as? String } == ["override_nickname", "penalize"])
    }
}

@Suite(.timeLimit(.minutes(1))) struct AdminAPITests {
    @Test func everyActionLeavesTheExpectedStateInMemory() async throws {
        try await AdminScenario.run(AdminWorld())
    }

    /// Acceptance (#154): unauthenticated access refused: no token, a wrong one, another scheme, on every route.
    @Test func unauthenticatedAccessIsRefused() async throws {
        let world = AdminWorld()
        let report = try await world.file(.message, by: "T:wren", on: "T:gull")
        let routes: [(HTTPMethod, String)] = [
            (.GET, "/admin/queue"), (.GET, "/admin/reports/\(report.id)"), (.POST, "/admin/reports/\(report.id)/decide?decision=dismiss"),
            (.GET, "/admin/players/T:gull"), (.POST, "/admin/players/T:gull/penalize?penalty=permanent"), (.POST, "/admin/players/T:gull/mute"),
            (.POST, "/admin/players/T:gull/nickname-override"), (.POST, "/admin/players/T:gull/penalties/1/lift"), (.GET, "/admin/audit"),
            (.GET, "/admin/nowhere"),
        ]
        for (method, uri) in routes {
            for token in [nil, "wrong", String(repeating: "a", count: 39), AdminWorld.token + "a"] {
                #expect(await world.call(method, uri, token: token).status == .unauthorized, "\(method) \(uri)")
            }
            var headers = HTTPHeaders()
            headers.add(name: "Authorization", value: "Basic \(AdminWorld.token)")
            let (path, query) = RequestHandler.split(uri)
            #expect(await world.api.respond(method: method, path: path, query: query, headers: headers).status == .unauthorized)
        }
        // Nothing changed.
        #expect(try await world.store.report(report.id)?.decision == nil)
        #expect(try await world.store.penalties(of: "T:gull").isEmpty)
        #expect(try await world.store.actions(about: nil, limit: 10).isEmpty)
        // With a token: an unknown route, or the wrong method.
        #expect(await world.call(.GET, "/admin/nowhere").status == .notFound)
        #expect(await world.call(.GET, "/admin/players/T:gull/mute").status == .methodNotAllowed)
        #expect(await world.call(.POST, "/admin/queue").status == .methodNotAllowed)
    }

    /// The routes on the server's port: only with admin tokens configured; a dev server without has none.
    @Test func theServerHasAdminRoutesOnlyWithTokens() async throws {
        var config = ServerConfig.dev()
        let services = try ServiceEndpoint.make(config: config, store: InMemoryAccountStore())
        var authorized = HTTPHeaders()
        authorized.add(name: "Authorization", value: "Bearer \(AdminWorld.token)")
        let without = RequestHandler(config: config, registry: RaceRegistry(maxRaces: 1), services: services)
        #expect(without.admin == nil)
        #expect(await without.respond(method: .GET, uri: "/admin/queue", headers: authorized).status == .notFound)
        config.admin = AdminSettings(tokens: [AdminWorld.token: "alice"])
        let with = RequestHandler(config: config, registry: RaceRegistry(maxRaces: 1), services: services)
        #expect(await with.respond(method: .GET, uri: "/admin/queue").status == .unauthorized)
        #expect(await with.respond(method: .GET, uri: "/admin/queue", headers: authorized).status == .ok)
        #expect(await with.respond(method: .GET, uri: "/administrator", headers: authorized).status == .notFound)
    }

    @Test func aRaceReportShowsItsRaceAndTheSeatsIncidents() async throws {
        let archive = InMemoryRaceArchive()
        let world = AdminWorld(archive: archive)
        let race = UUID()
        try await archive.register(race, players: [RaceSeatHolder(playerID: "T:tern", seat: 0), RaceSeatHolder(playerID: "T:gull", seat: 1)])
        var index = IncidentIndex()
        let incident = index.open(between: 0, and: 1, tick: 300, leg: 0)
        var called = incident
        called.outcome = .called(RuleCall(incidentId: incident.id, tick: 301, rule: .portStarboard, offender: 1, victim: 0, leg: 0, turnsOwed: 1,
                                          startDeadlineTick: nil, completeDeadlineTick: nil))
        index.update(called)
        index.recordProtest(Protest(tick: 320, leg: 0, protester: 0, protested: 1, matchedIncidentId: incident.id))
        let setup = try RaceSetup(raceSeed: RaceSeed(1), seats: [.human, .human, .bot], laps: 1, startSequenceTicks: 300)
        let summary = RaceSummary(venue: "Harbour", roster: [RosterEntry(name: "tern", colorIndex: 0), RosterEntry(name: "gull", colorIndex: 1),
                                                             RosterEntry(name: "Bot", colorIndex: 2, isBot: true)],
                                  results: RaceResults(rows: [SeatResult(seat: 0, place: 1, code: .finished, finishTick: 900),
                                                              SeatResult(seat: 2, place: 2, code: .finished, finishTick: 950),
                                                              SeatResult(seat: 1, place: 3, code: .ret, finishTick: nil)], rated: true),
                                  turnsServed: [0, 0, 0])
        try await archive.close(ClosedRaceRecord(
            id: race, log: try RaceLog(header: .init(setup: setup, windSeed: WindSeed(1), tideStateAtGun: nil), finalTick: 1000).jsonData(),
            digest: 1, simulationVersion: setup.simulationVersion, toolchain: "test", results: try summary.encoded(),
            incidents: try RaceResultsFeed.encode(index), rated: true))
        let report = try await world.file(.race, by: "T:tern", on: "T:gull", race: race, seat: 1)
        let detail = await world.call(.GET, "/admin/reports/\(report.id)")
        let shown = try #require(detail.json["race"] as? [String: Any])
        #expect(shown["venue"] as? String == "Harbour")
        let rows = try #require(shown["rows"] as? [[String: Any]])
        #expect(rows.map { $0["seat"] as? Int } == [0, 2, 1])
        #expect(rows.last?["playerID"] as? String == "T:gull" && rows.last?["code"] as? String == "RET")
        #expect(rows[1]["isBot"] as? Bool == true && rows[1]["playerID"] == nil)
        let incidents = try #require(shown["incidents"] as? [[String: Any]])
        #expect(incidents.map { $0["kind"] as? String } == ["call", "protest"])
        #expect(incidents.first?["rule"] as? String == "10" && incidents.first?["seats"] as? [Int] == [1, 0])
    }

    @Test func theTokensVariable() throws {
        let long = String(repeating: "x", count: 32)
        #expect(AdminSettings.parse("alice:\(long)") == [long: "alice"])
        #expect(AdminSettings.parse("alice:\(long), bob:\(long)y") == [long: "alice", long + "y": "bob"])
        // Short, missing, repeated, or no admin.
        for bad in ["alice:short", "alice", ":\(long)", "alice:\(long),alice:\(long)y", "alice:\(long),bob:\(long)", ""] {
            #expect(AdminSettings.parse(bad) == nil, "\(bad)")
        }
        var env = ["ENV": "dev", "REGATTA_ADMIN_TOKENS": "alice:\(long)"]
        #expect(try ServerConfig.load(from: env).admin.tokens == [long: "alice"])
        env["REGATTA_ADMIN_TOKENS"] = "alice:short"
        #expect(throws: ServerConfigError.self) { try ServerConfig.load(from: env) }
        #expect(try ServerConfig.load(from: ["ENV": "dev"]).admin.tokens.isEmpty)
    }

    /// `regatta-admin`'s commands, as the requests they make.
    @Test func theCommandLinesRequests() throws {
        let base = try #require(URL(string: "http://127.0.0.1:8080"))
        func url(_ words: String) throws -> String {
            let request = try AdminCommand.request(words.split(separator: " ").map(String.init))
            return "\(request.method) \(request.url(on: base)?.absoluteString ?? "")"
        }
        #expect(try url("queue") == "GET http://127.0.0.1:8080/admin/queue")
        #expect(try url("queue 20") == "GET http://127.0.0.1:8080/admin/queue?limit=20")
        #expect(try url("report 12") == "GET http://127.0.0.1:8080/admin/reports/12")
        #expect(try url("decide 12 suspension_24h") == "POST http://127.0.0.1:8080/admin/reports/12/decide?decision=suspension_24h")
        #expect(try url("player T:a/b") == "GET http://127.0.0.1:8080/admin/players/T:a%2Fb")
        #expect(try url("penalize T:gull warning") == "POST http://127.0.0.1:8080/admin/players/T:gull/penalize?penalty=warning")
        #expect(try url("mute T:gull") == "POST http://127.0.0.1:8080/admin/players/T:gull/mute")
        #expect(try url("nickname-override T:gull") == "POST http://127.0.0.1:8080/admin/players/T:gull/nickname-override")
        #expect(try url("lift T:gull 4") == "POST http://127.0.0.1:8080/admin/players/T:gull/penalties/4/lift")
        #expect(try url("audit T:gull") == "GET http://127.0.0.1:8080/admin/audit?player=T:gull")
        for bad in ["", "report", "report x", "decide 1", "lift T:gull x", "launch"] {
            #expect(throws: AdminCommandError.self) { try url(bad) }
        }
        // Each command's path is a route the API takes, with the method it takes.
        for words in ["queue", "report 1", "decide 1 dismiss", "player T:g", "penalize T:g warning", "mute T:g", "nickname-override T:g",
                      "lift T:g 1", "audit"] {
            let request = try AdminCommand.request(words.split(separator: " ").map(String.init))
            let parts = request.path.split(separator: "/").map { $0.removingPercentEncoding ?? String($0) }
            let route = try #require(AdminRoute(Array(parts.dropFirst())), "\(words)")
            #expect(route.method.rawValue == request.method)
        }
    }
}

/// The scenario against Postgres (#154: "each action produces the expected DB state"). Named `…PersistenceTests` so
/// CI's persistence job runs it.
@Suite(EndpointDatabase.available, .timeLimit(.minutes(1))) struct AdminAPIPersistenceTests {
    @Test func everyActionLeavesTheExpectedStateInPostgres() async throws {
        try await EndpointDatabase.withMigratedSchema { database in
            try await AdminScenario.run(AdminWorld(store: ModerationRecordStore(database), restrictions: PlayerRestrictionStore(database),
                                                   ratings: RatingStore(database), accounts: PostgresAccountStore(database)))
        }
    }

    /// The fair-play job over races closed in Postgres (#155): read back from their stored log, results and incidents.
    @Test func theFairPlayJobReadsRacesFromPostgres() async throws {
        try await EndpointDatabase.withMigratedSchema { database in
            let world = AdminWorld(store: ModerationRecordStore(database), restrictions: PlayerRestrictionStore(database),
                                   ratings: RatingStore(database), accounts: PostgresAccountStore(database))
            try await world.signIn(["gull", "wren"])
            let archive = PostgresRaceArchive(database)
            for _ in 0..<5 {
                let race = try RaceFixture.race(["T:gull", "T:wren"], calls: [.init(offender: 0, victim: 1)], rated: false)
                try await archive.register(race.id, players: race.seating.humans)
                try await archive.close(RaceFixture.record(race))
            }
            let raised = await FairPlayJob(store: world.store, archive: archive, now: { Date() + 1 }).runOnce()
            #expect(raised.map(\.playerID) == ["T:gull"] && raised.first?.raceIDs.count == 5)
            #expect(try await world.store.pendingFlags(limit: 10).map(\.id) == raised.map(\.id))
            #expect(try await world.store.penalties(of: "T:gull").isEmpty)
        }
    }
}
