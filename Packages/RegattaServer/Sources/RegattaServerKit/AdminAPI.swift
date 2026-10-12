import Crypto
import Foundation
import NIOHTTP1
import Persistence
import RegattaCore
import RegattaServices

// The admin tool (#154; #17, #26, #34): the admin queue, each report's detail (the line, the player, the race) and each
// fair-play flag's (#155), the decisions and penalties, the nickname override and the audit, as JSON routes under `/admin/` on the server's port.
// Every request carries an admin's token (`Authorization: Bearer …`, `REGATTA_ADMIN_TOKENS`), and every action is taken
// as the admin it names: a request without a known token is refused, whatever it asks for. A server without admin
// tokens has no `/admin/` routes (404). `regatta-admin` is the command line over them.

/// Who may use the admin tool: each admin's id by her token.
public struct AdminSettings: Sendable {
    /// Admin ids by token. Empty: the server has no admin tool.
    public var tokens: [String: String] = [:]
    /// The most queue items or audit rows one request returns.
    public var maxListed = 500

    public init(tokens: [String: String] = [:]) { self.tokens = tokens }

    /// A token is at least this long: it is the admin's only credential.
    public static let minTokenLength = 32

    /// `REGATTA_ADMIN_TOKENS`: comma-separated `id:token` pairs, each id once and each token at least `minTokenLength`
    /// characters. Nil when it isn't well formed.
    public static func parse(_ text: String) -> [String: String]? {
        var tokens: [String: String] = [:]
        var ids: Set<String> = []
        for pair in text.split(separator: ",") {
            let parts = pair.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, (try? AdminActor(parts[0])) != nil, parts[1].count >= minTokenLength,
                  ids.insert(parts[0]).inserted, tokens[parts[1]] == nil else { return nil }
            tokens[parts[1]] = parts[0]
        }
        return tokens.isEmpty ? nil : tokens
    }
}

/// The admin routes. Pure over moderation and the race archive: the HTTP server hands it each `/admin/` request.
public struct AdminAPI: Sendable {
    public let settings: AdminSettings
    public let moderation: Moderation
    /// Where a race report's race is read; nil: none is shown.
    public let archive: (any RaceArchive)?
    /// Each token's SHA-256, so a token is compared in constant time.
    private let digests: [(digest: SHA256.Digest, admin: String)]

    public init(settings: AdminSettings, moderation: Moderation, archive: (any RaceArchive)?) {
        self.settings = settings
        self.moderation = moderation
        self.archive = archive
        digests = settings.tokens.map { (SHA256.hash(data: Data($0.key.utf8)), $0.value) }
    }

    /// The admin a request's `Authorization: Bearer` token names, or nil.
    public func authenticate(_ headers: HTTPHeaders) -> AdminActor? {
        guard let value = headers.first(name: "Authorization"), value.lowercased().hasPrefix("bearer ") else { return nil }
        let given = SHA256.hash(data: Data(value.dropFirst("bearer ".count).trimmingCharacters(in: .whitespaces).utf8))
        // Every token is compared, all the way: how long it takes says nothing about which matched.
        var found: String?
        for (digest, admin) in digests where Self.same(digest, given) { found = admin }
        return found.flatMap { try? AdminActor($0) }
    }

    private static func same(_ a: SHA256.Digest, _ b: SHA256.Digest) -> Bool {
        zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// Answers an `/admin/…` request: 401 without an admin's token, then the route.
    public func respond(method: HTTPMethod, path: String, query: String, headers: HTTPHeaders) async -> HTTPReply {
        guard let admin = authenticate(headers) else { return HTTPReply(.unauthorized, error: "an admin token is required") }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map { $0.removingPercentEncoding ?? String($0) }
        let params = Self.parameters(query)
        guard parts.first == "admin" else { return HTTPReply(.notFound, error: "not found") }
        guard let route = AdminRoute(Array(parts.dropFirst())) else { return HTTPReply(.notFound, error: "not found") }
        guard method == route.method else { return HTTPReply(.methodNotAllowed, error: "method not allowed") }
        do {
            switch route {
            case .queue:
                return HTTPReply(.ok, json: try await queue(limit: limit(params)))
            case .report(let id):
                guard let id = Int64(id), let detail = try await report(id) else { return HTTPReply(.notFound, error: "no such report") }
                return HTTPReply(.ok, json: detail)
            case .decide(let id):
                guard let id = Int64(id) else { return HTTPReply(.notFound, error: "no such report") }
                guard let decision = params["decision"].flatMap(ReviewDecision.init(name:)) else {
                    return HTTPReply(.badRequest, error: "decision is one of \(ReviewDecision.all.map(\.name).joined(separator: ", "))")
                }
                let penalty = try await moderation.decide(id, decision, by: admin)
                let now = moderation.now()
                return HTTPReply(.ok, json: AdminDecided(report: try await moderation.store.report(id).map { AdminReport($0, at: now) },
                                                         penalty: penalty.map { AdminPenalty($0, at: now) }))
            case .player(let player):
                return HTTPReply(.ok, json: try await self.player(player))
            case .penalize(let player):
                guard let penalty = params["penalty"].flatMap(RacingPenalty.init(rawValue:)) else {
                    return HTTPReply(.badRequest, error: "penalty is one of \(RacingPenalty.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                return HTTPReply(.ok, json: AdminPenalty(try await moderation.penalize(player, penalty, by: admin), at: moderation.now()))
            case .mute(let player):
                return HTTPReply(.ok, json: AdminPenalty(try await moderation.muteNext(player, by: admin), at: moderation.now()))
            case .nicknameOverride(let player):
                return HTTPReply(.ok, json: AdminPenalty(try await moderation.overrideNickname(player, by: admin), at: moderation.now()))
            case .lift(let player, let id):
                guard let id = Int64(id) else { return HTTPReply(.notFound, error: "no such penalty of that player") }
                try await moderation.lift(id, of: player, by: admin)
                return HTTPReply(.ok, json: try await self.player(player))
            case .flag(let id):
                guard let id = Int64(id), let detail = try await flag(id) else { return HTTPReply(.notFound, error: "no such flag") }
                return HTTPReply(.ok, json: detail)
            case .decideFlag(let id):
                guard let id = Int64(id) else { return HTTPReply(.notFound, error: "no such flag") }
                guard let decision = params["decision"].flatMap(FlagDecision.init(rawValue:)) else {
                    return HTTPReply(.badRequest, error: "decision is one of \(FlagDecision.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                return HTTPReply(.ok, json: AdminFlag(try await moderation.decideFlag(id, decision, by: admin), at: moderation.now()))
            case .audit:
                let actions = try await moderation.store.actions(about: params["player"], limit: limit(params))
                return HTTPReply(.ok, json: AdminAudit(actions: actions.map(AdminAuditEntry.init)))
            }
        } catch let error as ModerationError {
            return Self.reply(error)
        } catch {
            Moderation.log("admin \(admin.id): \(method) \(path) failed: \(error)")
            return HTTPReply(.internalServerError, error: "the store failed: try again")
        }
    }

    static func reply(_ error: ModerationError) -> HTTPReply {
        switch error {
        case .noAdmin: HTTPReply(.unauthorized, error: "an admin token is required")
        case .unknownReport: HTTPReply(.notFound, error: "no such report")
        case .unknownPenalty: HTTPReply(.notFound, error: "no such penalty of that player")
        case .unknownFlag: HTTPReply(.notFound, error: "no such flag")
        case .alreadyDecided: HTTPReply(.conflict, error: "the report was decided already")
        case .decisionDoesntFit: HTTPReply(.unprocessableEntity, error: "that decision doesn't fit the report's kind")
        }
    }

    private func limit(_ params: [String: String]) -> Int {
        min(max(params["limit"].flatMap(Int.init) ?? 100, 1), settings.maxListed)
    }

    static func parameters(_ query: String) -> [String: String] {
        var params: [String: String] = [:]
        for item in URLComponents(string: "?" + query)?.queryItems ?? [] where params[item.name] == nil {
            params[item.name] = item.value ?? ""
        }
        return params
    }

    // MARK: Views

    /// The admin queue (#34): the reports and fair-play flags (#155) that wait for a decision, the first due first.
    func queue(limit: Int) async throws -> AdminQueue {
        let now = moderation.now()
        let reports = try await moderation.queue(limit: limit).map { AdminQueueItem(report: AdminReport($0, at: now)) }
        let flags = try await moderation.flagQueue(limit: limit).map { AdminQueueItem(flag: AdminFlag($0, at: now)) }
        let items = (reports + flags).sorted { ($0.dueAt, $0.type, $0.id) < ($1.dueAt, $1.type, $1.id) }
        return AdminQueue(now: Self.seconds(now), items: Array(items.prefix(limit)))
    }

    /// A flag and what an admin looks at it with: the player's penalties and her other flags.
    func flag(_ id: Int64) async throws -> AdminFlagDetail? {
        guard let flag = try await moderation.store.flag(id) else { return nil }
        let now = moderation.now()
        return AdminFlagDetail(flag: AdminFlag(flag, at: now),
                               penalties: try await moderation.store.penalties(of: flag.playerID).map { AdminPenalty($0, at: now) },
                               otherFlags: try await moderation.store.flags(of: flag.playerID).filter { $0.id != id }.map { AdminFlag($0, at: now) })
    }

    /// A report and what an admin decides it on: the reported player's penalties and the other reports on her, and
    /// for a race report the race.
    func report(_ id: Int64) async throws -> AdminReportDetail? {
        guard let report = try await moderation.store.report(id) else { return nil }
        let now = moderation.now()
        let others = try await moderation.store.reports(against: report.subjectID, since: .distantPast).filter { $0.id != id }
        return AdminReportDetail(report: AdminReport(report, at: now),
                                 penalties: try await moderation.store.penalties(of: report.subjectID).map { AdminPenalty($0, at: now) },
                                 otherReports: others.map { AdminReport($0, at: now) },
                                 race: try await race(of: report))
    }

    /// The race a race report names, as the results showed it, with the incidents the reported seat was in.
    private func race(of report: StoredReport) async throws -> AdminRace? {
        guard report.kind == .race, let archive, let raceID = report.raceID, let id = UUID(uuidString: raceID),
              let closed = try await archive.closedRace(id) else { return nil }
        let summary = try RaceSummary(decoding: closed.results)
        let incidents = try RaceResultsFeed.decodeIncidents(closed.incidents)
        let players = try await archive.seats(of: id)?.humans ?? []
        let rows = summary.rows.map { row in
            AdminRace.Row(seat: row.seat, place: row.place, code: row.code, name: summary.roster.indices.contains(row.seat) ? summary.roster[row.seat].name : "",
                          isBot: summary.roster.indices.contains(row.seat) && summary.roster[row.seat].isBot,
                          playerID: players.first { $0.seat == row.seat }?.playerID)
        }
        return AdminRace(raceID: raceID, venue: summary.venue, rated: summary.rated, rows: rows,
                         incidents: report.seat.map { AdminRace.incidents(of: $0, in: incidents) } ?? [])
    }

    /// A player as moderation holds her: her chat standing, her override, her penalties, and the reports on her.
    func player(_ playerID: String) async throws -> AdminPlayer {
        let now = moderation.now()
        let penalties = try await moderation.store.penalties(of: playerID)
        return AdminPlayer(playerID: playerID, chat: AdminPlayer.chat(Moderation.standing(penalties, at: now)),
                           nicknameOverridden: penalties.contains { $0.kind == .nicknameOverride && $0.applies(at: now) },
                           penalties: penalties.map { AdminPenalty($0, at: now) },
                           reports: try await moderation.store.reports(against: playerID, since: .distantPast).map { AdminReport($0, at: now) },
                           reportsFiled: try await moderation.store.reports(by: playerID).count)
    }

    static func seconds(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970.rounded(.down)) }
}

/// An admin route, from the path's segments after `admin`.
enum AdminRoute: Equatable {
    case queue
    case report(String)
    case decide(String)
    case player(String)
    case penalize(String)
    case mute(String)
    case nicknameOverride(String)
    case lift(String, penalty: String)
    case flag(String)
    case decideFlag(String)
    case audit

    init?(_ parts: [String]) {
        switch (parts.count, parts.first) {
        case (1, "queue"): self = .queue
        case (1, "audit"): self = .audit
        case (2, "reports"): self = .report(parts[1])
        case (3, "reports") where parts[2] == "decide": self = .decide(parts[1])
        case (2, "flags"): self = .flag(parts[1])
        case (3, "flags") where parts[2] == "decide": self = .decideFlag(parts[1])
        case (2, "players"): self = .player(parts[1])
        case (3, "players"):
            switch parts[2] {
            case "penalize": self = .penalize(parts[1])
            case "mute": self = .mute(parts[1])
            case "nickname-override": self = .nicknameOverride(parts[1])
            default: return nil
            }
        case (5, "players") where parts[2] == "penalties" && parts[4] == "lift": self = .lift(parts[1], penalty: parts[3])
        default: return nil
        }
    }

    /// Reads are GETs; everything that changes something is a POST.
    var method: HTTPMethod {
        switch self {
        case .queue, .report, .player, .flag, .audit: .GET
        case .decide, .penalize, .mute, .nicknameOverride, .lift, .decideFlag: .POST
        }
    }
}

// MARK: - JSON

/// The admin queue: each item due by `dueAt`, Unix seconds.
struct AdminQueue: Encodable {
    var now: Int64
    var items: [AdminQueueItem]
}

struct AdminQueueItem: Encodable {
    /// "report" or "flag".
    var type: String
    var id: Int64
    var dueAt: Int64
    var overdue: Bool
    var report: AdminReport?
    var flag: AdminFlag?

    init(report: AdminReport) {
        type = "report"
        id = report.id
        dueAt = report.dueAt
        overdue = report.overdue
        self.report = report
    }

    init(flag: AdminFlag) {
        type = "flag"
        id = flag.id
        dueAt = flag.dueAt
        overdue = flag.overdue
        self.flag = flag
    }
}

/// A fair-play flag (#155): what the scan measured, the threshold it reached, and the races.
struct AdminFlag: Encodable {
    var id: Int64
    var kind: String
    var playerID: String
    var value: Double
    var threshold: Double
    var raceIDs: [String]
    var detail: String
    var createdAt: Int64
    var dueAt: Int64
    var overdue: Bool
    var decision: String?
    var decidedAt: Int64?
    var decidedBy: String?

    init(_ flag: StoredFlag, at now: Date) {
        id = flag.id
        kind = flag.kind.rawValue
        playerID = flag.playerID
        value = flag.value
        threshold = flag.threshold
        raceIDs = flag.raceIDs
        detail = flag.detail
        createdAt = AdminAPI.seconds(flag.createdAt)
        dueAt = AdminAPI.seconds(flag.dueAt)
        overdue = flag.decision == nil && flag.dueAt < now
        decision = flag.decision?.rawValue
        decidedAt = flag.decidedAt.map(AdminAPI.seconds)
        decidedBy = flag.decidedBy
    }
}

struct AdminFlagDetail: Encodable {
    var flag: AdminFlag
    var penalties: [AdminPenalty]
    var otherFlags: [AdminFlag]
}

struct AdminReport: Encodable {
    var id: Int64
    var kind: String
    var reporterID: String
    var subjectID: String
    var subjectNickname: String
    var messageID: Int64?
    var messageBody: String?
    var messagePostedAt: Int64?
    var raceID: String?
    var seat: Int?
    var reason: String?
    var createdAt: Int64
    var dueAt: Int64
    /// Waiting past its due time.
    var overdue: Bool
    var decision: String?
    var decidedAt: Int64?
    var decidedBy: String?

    init(_ report: StoredReport, at now: Date = Date()) {
        id = report.id
        kind = report.kind.rawValue
        reporterID = report.reporterID
        subjectID = report.subjectID
        subjectNickname = report.subjectNickname
        messageID = report.messageID
        messageBody = report.messageBody
        messagePostedAt = report.messagePostedAt.map(AdminAPI.seconds)
        raceID = report.raceID
        seat = report.seat
        reason = report.reason?.rawValue
        createdAt = AdminAPI.seconds(report.createdAt)
        dueAt = AdminAPI.seconds(report.dueAt)
        overdue = report.decision == nil && report.dueAt < now
        decision = report.decision?.rawValue
        decidedAt = report.decidedAt.map(AdminAPI.seconds)
        decidedBy = report.decidedBy
    }
}

struct AdminPenalty: Encodable {
    var id: Int64
    var playerID: String
    var kind: String
    var automatic: Bool
    var actorID: String?
    var reportID: Int64?
    var startsAt: Int64
    var endsAt: Int64?
    var liftedAt: Int64?
    var liftedBy: String?
    var inForce: Bool

    init(_ penalty: StoredPenalty, at now: Date = Date()) {
        id = penalty.id
        playerID = penalty.playerID
        kind = penalty.kind.rawValue
        automatic = penalty.automatic
        actorID = penalty.actorID
        reportID = penalty.reportID
        startsAt = AdminAPI.seconds(penalty.startsAt)
        endsAt = penalty.endsAt.map(AdminAPI.seconds)
        liftedAt = penalty.liftedAt.map(AdminAPI.seconds)
        liftedBy = penalty.liftedBy
        inForce = penalty.applies(at: now)
    }
}

struct AdminDecided: Encodable {
    var report: AdminReport?
    var penalty: AdminPenalty?
}

struct AdminReportDetail: Encodable {
    var report: AdminReport
    /// The reported player's penalties, lifted or not.
    var penalties: [AdminPenalty]
    /// The other reports on her, decided or not.
    var otherReports: [AdminReport]
    var race: AdminRace?
}

struct AdminRace: Encodable {
    struct Row: Encodable {
        var seat: Int
        var place: Int
        var code: String
        var name: String
        var isBot: Bool
        /// The human who sat there.
        var playerID: String?
    }

    /// Something that happened to the reported seat: a rule call, a contact, a protest or a mark touch.
    struct Incident: Encodable {
        var tick: Int
        /// "call", "no_call", "pending", "contact", "protest" or "mark_touch".
        var kind: String
        var rule: String?
        /// The seats it was between; for a call the offender first.
        var seats: [Int]
    }

    var raceID: String
    var venue: String
    var rated: Bool
    var rows: [Row]
    var incidents: [Incident]

    /// `seat`'s incidents, contacts, protests and penalised mark touches, by tick.
    static func incidents(of seat: Int, in index: IncidentIndex) -> [Incident] {
        var found: [Incident] = []
        for incident in index.incidents where incident.parties.contains(seat) {
            switch incident.outcome {
            case .called(let call): found.append(Incident(tick: call.tick, kind: "call", rule: call.rule.rawValue, seats: [call.offender, call.victim]))
            case .noCall: found.append(Incident(tick: incident.tick, kind: "no_call", seats: [incident.parties.low, incident.parties.high]))
            case .pending: found.append(Incident(tick: incident.tick, kind: "pending", seats: [incident.parties.low, incident.parties.high]))
            }
        }
        for contact in index.contacts where contact.parties.contains(seat) && contact.incidentId == nil {
            found.append(Incident(tick: contact.tick, kind: "contact", seats: [contact.parties.low, contact.parties.high]))
        }
        for protest in index.protests where protest.protester == seat || protest.protested == seat {
            found.append(Incident(tick: protest.tick, kind: "protest", seats: [protest.protester, protest.protested]))
        }
        for touch in index.markTouches where touch.seat == seat {
            found.append(Incident(tick: touch.tick, kind: "mark_touch", rule: RacingRule.touchingMark.rawValue, seats: [seat]))
        }
        return found.sorted { $0.tick < $1.tick }
    }
}

struct AdminPlayer: Encodable {
    var playerID: String
    /// "clear", "muted" or "banned".
    var chat: String
    var nicknameOverridden: Bool
    var penalties: [AdminPenalty]
    /// Reports on her, decided or not.
    var reports: [AdminReport]
    var reportsFiled: Int

    static func chat(_ standing: ChatStanding) -> String {
        switch standing {
        case .clear: "clear"
        case .muted: "muted"
        case .banned: "banned"
        }
    }
}

struct AdminAudit: Encodable {
    var actions: [AdminAuditEntry]
}

struct AdminAuditEntry: Encodable {
    var id: Int64
    var actorID: String
    var action: String
    var playerID: String?
    var reportID: Int64?
    var penaltyID: Int64?
    var detail: String
    var at: Int64

    init(_ action: StoredAdminAction) {
        id = action.id
        actorID = action.actorID
        self.action = action.action
        playerID = action.playerID
        reportID = action.reportID
        penaltyID = action.penaltyID
        detail = action.detail
        at = AdminAPI.seconds(action.at)
    }
}
