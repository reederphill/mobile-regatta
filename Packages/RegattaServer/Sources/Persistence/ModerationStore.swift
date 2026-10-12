import Foundation
import PostgresNIO

/// A player's report (#153, #17, #26, #34), as stored.
public struct StoredReport: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        /// A lobby line.
        case message
        /// A player, for her chat or a bad nickname (#34).
        case player
        /// A human's racing, by seat, from the results (#26).
        case race
    }

    public enum Reason: String, Sendable, Equatable {
        case unsportingConduct = "unsporting_conduct"
        case suspectedCheating = "suspected_cheating"
    }

    public enum Decision: String, Sendable, Equatable {
        case dismissed, upheld
    }

    /// Assigned by the store; 0 on a report not yet filed.
    public var id: Int64
    public var kind: Kind
    /// Who reported, and whom (teamPlayerIDs).
    public var reporterID: String
    public var subjectID: String
    /// The reported player's nickname as the reporter saw it.
    public var subjectNickname: String
    /// A reported line: its lobby id, and its words and time as they were (the lobby prunes it at 30 days).
    public var messageID: Int64?
    public var messageBody: String?
    public var messagePostedAt: Date?
    /// A reported seat's race and seat, and why.
    public var raceID: String?
    public var seat: Int?
    public var reason: Reason?
    public var createdAt: Date
    /// When the admin queue should have reviewed it (24 h, #34).
    public var dueAt: Date
    public var decision: Decision?
    public var decidedAt: Date?
    /// The admin who decided it.
    public var decidedBy: String?

    public init(id: Int64 = 0, kind: Kind, reporterID: String, subjectID: String, subjectNickname: String, messageID: Int64? = nil,
                messageBody: String? = nil, messagePostedAt: Date? = nil, raceID: String? = nil, seat: Int? = nil, reason: Reason? = nil,
                createdAt: Date, dueAt: Date, decision: Decision? = nil, decidedAt: Date? = nil, decidedBy: String? = nil) {
        self.id = id
        self.kind = kind
        self.reporterID = reporterID
        self.subjectID = subjectID
        self.subjectNickname = subjectNickname
        self.messageID = messageID
        self.messageBody = messageBody
        self.messagePostedAt = messagePostedAt
        self.raceID = raceID
        self.seat = seat
        self.reason = reason
        self.createdAt = createdAt
        self.dueAt = dueAt
        self.decision = decision
        self.decidedAt = decidedAt
        self.decidedBy = decidedBy
    }

    /// A report on a player's chat: a line, or the player.
    public var isChat: Bool { kind != .race }
}

/// A penalty (#153), as stored.
public struct StoredPenalty: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable, CaseIterable {
        /// No posting until `endsAt` (#17).
        case chatMute = "chat_mute"
        /// No posting, for good.
        case chatBan = "chat_ban"
        /// Racing (#26): recorded, nothing stopped.
        case racingWarning = "racing_warning"
        /// No queueing until `endsAt`.
        case racingSuspension = "racing_suspension"
        /// No queueing, for good.
        case racingBan = "racing_ban"
        /// Her rating went back to the start.
        case ratingReset = "rating_reset"
        /// She shows as "Sailor" and her sail number (#34).
        case nicknameOverride = "nickname_override"

        public var isChat: Bool { self == .chatMute || self == .chatBan }
        public var isRacing: Bool { self == .racingWarning || self == .racingSuspension || self == .racingBan || self == .ratingReset }
    }

    public var id: Int64
    public var playerID: String
    public var kind: Kind
    /// The mute after reports from 3 players in 24 h (#17). The only penalty without an admin.
    public var automatic: Bool
    /// The admin who gave it; nil only on the automatic mute.
    public var actorID: String?
    /// The report it decided, if one did.
    public var reportID: Int64?
    public var startsAt: Date
    /// A mute's or a suspension's end; nil on the rest.
    public var endsAt: Date?
    public var liftedAt: Date?
    public var liftedBy: String?

    public init(id: Int64 = 0, playerID: String, kind: Kind, automatic: Bool = false, actorID: String?, reportID: Int64? = nil,
                startsAt: Date, endsAt: Date? = nil, liftedAt: Date? = nil, liftedBy: String? = nil) {
        self.id = id
        self.playerID = playerID
        self.kind = kind
        self.automatic = automatic
        self.actorID = actorID
        self.reportID = reportID
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.liftedAt = liftedAt
        self.liftedBy = liftedBy
    }

    /// In force at `time`: started, not lifted, not ended.
    public func applies(at time: Date) -> Bool {
        liftedAt == nil && startsAt <= time && endsAt.map { $0 > time } ?? true
    }
}

/// Reports and penalties in Postgres (#153, migration 0014). Keyed by teamPlayerID with no reference to `players`:
/// they outlive the player's row (#160).
public struct ModerationRecordStore: Sendable {
    let database: Database
    public init(_ database: Database) { self.database = database }

    static let reportColumns = """
        id, kind, reporter_id, subject_id, subject_nickname, message_id, message_body, message_posted_at, race_id, seat, reason,
        created_at, due_at, decision, decided_at, decided_by
        """

    /// Files `report` and returns it with its id.
    public func file(_ report: StoredReport) async throws -> StoredReport {
        let seat = report.seat.map(Int32.init)
        let rows = try await database.client.query("""
            INSERT INTO moderation_reports (kind, reporter_id, subject_id, subject_nickname, message_id, message_body, message_posted_at,
                race_id, seat, reason, created_at, due_at)
            VALUES (\(report.kind.rawValue), \(report.reporterID), \(report.subjectID), \(report.subjectNickname), \(report.messageID),
                \(report.messageBody), \(report.messagePostedAt), \(report.raceID), \(seat), \(report.reason?.rawValue), \(report.createdAt),
                \(report.dueAt))
            RETURNING id
            """, logger: database.logger)
        for try await id in rows.decode(Int64.self) {
            var filed = report
            filed.id = id
            return filed
        }
        throw ModerationWriteFailed()
    }

    public func report(_ id: Int64) async throws -> StoredReport? {
        try await reports(try await database.client.query("SELECT \(unescaped: Self.reportColumns) FROM moderation_reports WHERE id = \(id)", logger: database.logger)).first
    }

    /// The reports awaiting a decision, the first due first (the admin queue, #34).
    public func pending(limit: Int) async throws -> [StoredReport] {
        try await reports(try await database.client.query("""
            SELECT \(unescaped: Self.reportColumns) FROM moderation_reports WHERE decision IS NULL ORDER BY due_at, id LIMIT \(Int64(limit))
            """, logger: database.logger))
    }

    /// Every report against `subjectID` filed at or after `since`, oldest first.
    public func reports(against subjectID: String, since: Date) async throws -> [StoredReport] {
        try await reports(try await database.client.query("""
            SELECT \(unescaped: Self.reportColumns) FROM moderation_reports WHERE subject_id = \(subjectID) AND created_at >= \(since) ORDER BY created_at, id
            """, logger: database.logger))
    }

    /// Every report `reporterID` filed, oldest first.
    public func reports(by reporterID: String) async throws -> [StoredReport] {
        try await reports(try await database.client.query("""
            SELECT \(unescaped: Self.reportColumns) FROM moderation_reports WHERE reporter_id = \(reporterID) ORDER BY created_at, id
            """, logger: database.logger))
    }

    /// Decides a pending report. False when it was decided already, or there is no such report.
    public func decide(_ id: Int64, _ decision: StoredReport.Decision, by actorID: String, at time: Date) async throws -> Bool {
        let rows = try await database.client.query("""
            UPDATE moderation_reports SET decision = \(decision.rawValue), decided_at = \(time), decided_by = \(actorID)
            WHERE id = \(id) AND decision IS NULL RETURNING id
            """, logger: database.logger)
        for try await _ in rows.decode(Int64.self) { return true }
        return false
    }

    /// Gives `penalty` and returns it with its id.
    public func add(_ penalty: StoredPenalty) async throws -> StoredPenalty {
        let rows = try await database.client.query("""
            INSERT INTO moderation_penalties (player_id, kind, automatic, actor_id, report_id, starts_at, ends_at)
            VALUES (\(penalty.playerID), \(penalty.kind.rawValue), \(penalty.automatic), \(penalty.actorID), \(penalty.reportID),
                \(penalty.startsAt), \(penalty.endsAt))
            RETURNING id
            """, logger: database.logger)
        for try await id in rows.decode(Int64.self) {
            var added = penalty
            added.id = id
            return added
        }
        throw ModerationWriteFailed()
    }

    /// Every penalty `playerID` was given, lifted or not, oldest first.
    public func penalties(of playerID: String) async throws -> [StoredPenalty] {
        let rows = try await database.client.query("""
            SELECT id, player_id, kind, automatic, actor_id, report_id, starts_at, ends_at, lifted_at, lifted_by
            FROM moderation_penalties WHERE player_id = \(playerID) ORDER BY starts_at, id
            """, logger: database.logger)
        var penalties: [StoredPenalty] = []
        for try await (id, player, kind, automatic, actor, report, starts, ends, lifted, liftedBy)
            in rows.decode((Int64, String, String, Bool, String?, Int64?, Date, Date?, Date?, String?).self) {
            guard let kind = StoredPenalty.Kind(rawValue: kind) else { continue }
            penalties.append(StoredPenalty(id: id, playerID: player, kind: kind, automatic: automatic, actorID: actor, reportID: report,
                                           startsAt: starts, endsAt: ends, liftedAt: lifted, liftedBy: liftedBy))
        }
        return penalties
    }

    /// Lifts a penalty not lifted yet. False when it was, or there is no such penalty.
    public func lift(_ id: Int64, by actorID: String, at time: Date) async throws -> Bool {
        let rows = try await database.client.query("""
            UPDATE moderation_penalties SET lifted_at = \(time), lifted_by = \(actorID)
            WHERE id = \(id) AND lifted_at IS NULL RETURNING id
            """, logger: database.logger)
        for try await _ in rows.decode(Int64.self) { return true }
        return false
    }

    /// Deletes every report `reporterID` filed (#160: Delete my online data). Returns how many.
    @discardableResult
    public func deleteReports(by reporterID: String) async throws -> Int {
        let rows = try await database.client.query("DELETE FROM moderation_reports WHERE reporter_id = \(reporterID) RETURNING id",
                                                   logger: database.logger)
        var count = 0
        for try await _ in rows.decode(Int64.self) { count += 1 }
        return count
    }

    /// The retention prune (#28, #160): a penalty given before `cutoff` that is no longer in force at `time`, then a
    /// report filed before `cutoff` that no remaining penalty decided. A penalty in force stays as long as it lasts,
    /// and so does its report.
    public func prune(before cutoff: Date, at time: Date) async throws -> (penalties: Int, reports: Int) {
        try await database.transaction { connection in
            let penalties = try await connection.query("""
                DELETE FROM moderation_penalties WHERE starts_at < \(cutoff)
                    AND (lifted_at IS NOT NULL OR (ends_at IS NOT NULL AND ends_at <= \(time)))
                RETURNING id
                """, logger: database.logger)
            var penaltyCount = 0
            for try await _ in penalties.decode(Int64.self) { penaltyCount += 1 }
            let reports = try await connection.query("""
                DELETE FROM moderation_reports r WHERE r.created_at < \(cutoff)
                    AND NOT EXISTS (SELECT 1 FROM moderation_penalties p WHERE p.report_id = r.id)
                RETURNING id
                """, logger: database.logger)
            var reportCount = 0
            for try await _ in reports.decode(Int64.self) { reportCount += 1 }
            return (penaltyCount, reportCount)
        }
    }

    private func reports(_ rows: PostgresRowSequence) async throws -> [StoredReport] {
        var reports: [StoredReport] = []
        for try await row in rows {
            let cells = row.makeRandomAccess()
            func read<T: PostgresDecodable>(_ column: String, _ type: T.Type = T.self) throws -> T { try cells[column].decode(T.self, context: .default) }
            guard let kind = StoredReport.Kind(rawValue: try read("kind", String.self)) else { continue }
            reports.append(StoredReport(
                id: try read("id"), kind: kind, reporterID: try read("reporter_id"), subjectID: try read("subject_id"),
                subjectNickname: try read("subject_nickname"), messageID: try read("message_id"), messageBody: try read("message_body"),
                messagePostedAt: try read("message_posted_at"), raceID: try read("race_id"), seat: try read("seat", Int32?.self).map(Int.init),
                reason: try read("reason", String?.self).flatMap(StoredReport.Reason.init(rawValue:)), createdAt: try read("created_at"),
                dueAt: try read("due_at"), decision: try read("decision", String?.self).flatMap(StoredReport.Decision.init(rawValue:)),
                decidedAt: try read("decided_at"), decidedBy: try read("decided_by")))
        }
        return reports
    }
}

/// An insert gave no id back.
public struct ModerationWriteFailed: Error, Equatable, Sendable {}
