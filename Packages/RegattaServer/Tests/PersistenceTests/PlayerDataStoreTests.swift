import Foundation
import Persistence
import PostgresNIO
import RegattaCore
import Testing

/// #160: Delete my online data in Postgres: what the plan reads, the erase in one transaction, the inactivity read,
/// the leaderboard queue and the audit.
@Suite(TestDatabase.available) struct PlayerDataStoreTests {
    static let time = Date(timeIntervalSince1970: 1_800_000_000)

    /// Every kind of online data for `T:a` (and some for `T:b`): a closed rated race between them, its log and results,
    /// a mirrored rating, terms, a session, a livery, lobby lines (hers and a winner's line naming her), blocks both
    /// ways, a briefing leave, a server analytics event, a report each way, a penalty of hers.
    static func everything(_ database: Database) async throws -> ClosedRaceRecord {
        for id in ["T:a", "T:b"] { _ = try await PlayerStore(database).signIn(teamPlayerID: id, gamePlayerID: "G" + id, displayName: "N" + id) }
        let race = try await RaceRegistryStore(database).create(players: [RaceSeatHolder(playerID: "T:a", seat: 0), RaceSeatHolder(playerID: "T:b", seat: 1)])
        let record = ClosedRaceRecord(
            id: race.id, log: Data(#"{"log":"T:a and T:b"}"#.utf8), digest: 42, simulationVersion: "sim/1", toolchain: "swift-test",
            results: Data(#"{"rows":2}"#.utf8), incidents: Data("{}".utf8), rated: true,
            rating: RatingInput(participants: [.init(playerID: "T:a", place: 1), .init(playerID: "T:b", place: 2)], ratedAt: time),
            stats: [PlayerRaceStat(playerID: "T:a", completed: true, won: true), PlayerRaceStat(playerID: "T:b", completed: true, won: false)])
        _ = try await RaceResultStore(database).closing(record)
        try await RatingStore(database).mirrored("T:a", rating: 1662)
        try await TermsStore(database).accept(playerID: "T:a", version: 1, at: time)
        _ = try await SessionStore(database).create(playerID: "T:a", tokenHash: Data([1, 2, 3]), expiresAt: time + 3600, createdAt: time)
        try await PlayerLiveryStore(database).save(Livery(design: DesignID("skiff-plain"), colours: [SwatchID("charcoal"), SwatchID("off-white")],
                                                          sailNumber: 7), for: "T:a", at: time)
        let lobby = LobbyMessageStore(database)
        let author = StoredLobbyLine.Author(gamePlayerID: "GT:a", nickname: "NT:a", rating: 1500, isProvisional: true, chipDeck: "white", chipSail: "white")
        _ = try await lobby.append(StoredLobbyLine(kind: .text, authorID: "T:a", author: author, body: "fair winds", createdAt: time))
        _ = try await lobby.append(StoredLobbyLine(kind: .winner, subjectID: "T:a", venue: "Bay", winnerName: "NT:a", createdAt: time))
        _ = try await lobby.append(StoredLobbyLine(kind: .gun, venue: "Bay", boats: 10, humans: 2, createdAt: time))
        try await lobby.block("T:b", by: "T:a", at: time)
        try await lobby.block("T:a", by: "T:b", at: time)
        try await PlayerRestrictionStore(database).recordBriefingLeave("T:a", race: race.id, at: time)
        try await AnalyticsEventStore(database).recordServer(StoredAnalyticsEvent(source: .server, playerID: "T:a", name: "earned_unlock",
                                                                                  day: StoredAnalyticsEvent.day(of: time), occurredAt: time,
                                                                                  receivedAt: time))
        let moderation = ModerationRecordStore(database)
        _ = try await moderation.file(StoredReport(kind: .player, reporterID: "T:a", subjectID: "T:b", subjectNickname: "NT:b", createdAt: time,
                                                   dueAt: time + 86_400))
        let against = try await moderation.file(StoredReport(kind: .player, reporterID: "T:b", subjectID: "T:a", subjectNickname: "NT:a",
                                                             createdAt: time, dueAt: time + 86_400))
        _ = try await moderation.add(StoredPenalty(playerID: "T:a", kind: .chatBan, actorID: "admin-1", reportID: against.id, startsAt: time))
        return record
    }

    /// Every (table, column) whose value is one of `values`, across every text column of every table.
    static func references(_ database: Database, to values: [String]) async throws -> Set<String> {
        let columns = try await database.client.query("""
            SELECT table_name::text, column_name::text FROM information_schema.columns
            WHERE table_schema = current_schema() AND data_type = 'text'
            """)
        var all: [(String, String)] = []
        for try await column in columns.decode((String, String).self) { all.append(column) }
        var found: Set<String> = []
        for (table, column) in all {
            let rows = try await database.client.query(PostgresQuery(unsafeSQL: "SELECT count(*) FROM \(table) WHERE \(column) = ANY($1)",
                                                                     binds: try { var binds = PostgresBindings(); try binds.append(values); return binds }()))
            for try await count in rows.decode(Int.self) where count > 0 { found.insert("\(table).\(column)") }
        }
        return found
    }

    @Test func thePlanReadsEveryKind() async throws {
        try await TestDatabase.withMigratedSchema { database in
            _ = try await Self.everything(database)
            let store = PlayerDataStore(database)
            #expect(try await store.held(by: "T:a") == HeldOnlineData(kinds: Set(StoredOnlineData.allCases), hasRaced: true))
            #expect(try await store.held(by: "T:b") == HeldOnlineData(kinds: [.profile, .rating, .reportsFiled], hasRaced: true))
            #expect(try await store.held(by: "T:nobody").isEmpty)
        }
    }

    /// Acceptance: after deletion no row references the Game Center ids but the records #28 keeps; her past race still
    /// replays (its log, digest and results unchanged, her seat held by an anonymous id), and the other player's
    /// results and rating are unchanged.
    @Test func eraseLeavesOnlyWhatRetentionKeeps() async throws {
        try await TestDatabase.withMigratedSchema { database in
            let record = try await Self.everything(database)
            let archive = RaceResultStore(database), ratings = RatingStore(database)
            let resultsBefore = try await archive.results(for: record.id)
            let otherBefore = try await ratings.ratings(of: ["T:b"]), otherHistory = try await ratings.changes(of: record.id).filter { $0.playerID == "T:b" }
            let store = PlayerDataStore(database)
            #expect(try await store.erase("T:a", as: "deleted:x", reason: .request, at: Self.time + 60))
            #expect(try await !store.erase("T:a", as: "deleted:y", reason: .request, at: Self.time + 60))

            #expect(try await Self.references(database, to: ["T:a", "GT:a"])
                == ["moderation_penalties.player_id", "moderation_reports.subject_id", "data_deletions.game_player_id"])
            #expect(try await store.held(by: "T:a").isEmpty)
            #expect(try await archive.players(of: record.id) == [RaceSeatHolder(playerID: "deleted:x", seat: 0), RaceSeatHolder(playerID: "T:b", seat: 1)])
            #expect(try await RaceLogStore(database).log(for: record.id) == record.log)
            #expect(try await RaceRegistryStore(database).race(record.id)?.digest == record.digest)
            #expect(try await archive.results(for: record.id) == resultsBefore)
            #expect(try await ratings.ratings(of: ["T:b"]) == otherBefore)
            #expect(try await ratings.changes(of: record.id).filter { $0.playerID == "T:b" } == otherHistory)
            // The other player's report on her and the penalty stay; the report she filed, and her blocks, go.
            #expect(try await ModerationRecordStore(database).reports(by: "T:a").isEmpty)
            #expect(try await ModerationRecordStore(database).penalties(of: "T:a").count == 1)
            #expect(try await LobbyMessageStore(database).recent(since: .distantPast, limit: 10).map(\.kind) == [.gun])
            // Her analytics event is the anonymous id's.
            let anonymous = try await database.client.query("SELECT count(*) FROM analytics_events WHERE player_id = 'deleted:x'")
            for try await count in anonymous.decode(Int.self) { #expect(count == 1) }
            let audit = try await store.deletions(limit: 10)
            #expect(audit == [DeletionRecord(id: audit[0].id, reason: .request, deletedAt: Self.time + 60, gamePlayerID: "GT:a", scoresBlocked: nil)])
            // She may come back: a new row, and the penalty against her applies again.
            _ = try await PlayerStore(database).signIn(teamPlayerID: "T:a", gamePlayerID: "GT:a", displayName: "back")
            #expect(try await store.held(by: "T:a").isEmpty)
        }
    }

    @Test func scoreBlocksAreQueuedUntilDone() async throws {
        try await TestDatabase.withMigratedSchema { database in
            for id in ["T:a", "T:b"] { _ = try await PlayerStore(database).signIn(teamPlayerID: id, gamePlayerID: "G" + id, displayName: id) }
            let store = PlayerDataStore(database)
            try await store.erase("T:a", as: "deleted:a", reason: .request, at: Self.time)
            try await store.erase("T:b", as: "deleted:b", reason: .inactive, at: Self.time + 1)
            let pending = try await store.pendingScoreBlocks(limit: 10)
            #expect(pending.map(\.gamePlayerID) == ["GT:a", "GT:b"] && pending.map(\.failures) == [0, 0])
            try await store.scoreBlockFailed(pending[0].id)
            try await store.scoresBlocked(pending[1].id, count: 3, at: Self.time + 2)
            #expect(try await store.pendingScoreBlocks(limit: 10) == [PendingScoreBlock(id: pending[0].id, gamePlayerID: "GT:a", failures: 1)])
            let audit = try await store.deletions(limit: 10)
            #expect(audit.map(\.reason) == [.inactive, .request])
            #expect(audit[0].gamePlayerID == nil && audit[0].scoresBlocked == 3)
        }
    }

    @Test func inactivePlayersAreThoseWithoutARecentSession() async throws {
        try await TestDatabase.withMigratedSchema { database in
            let players = PlayerStore(database)
            for id in ["T:old", "T:older", "T:new"] { _ = try await players.signIn(teamPlayerID: id, gamePlayerID: "G" + id, displayName: id) }
            try await players.touchSession(teamPlayerID: "T:old", at: Self.time - 800 * 86_400)
            try await players.touchSession(teamPlayerID: "T:older", at: Self.time - 900 * 86_400)
            try await players.touchSession(teamPlayerID: "T:new", at: Self.time - 10 * 86_400)
            let store = PlayerDataStore(database)
            let cutoff = Self.time - 730 * 86_400
            #expect(try await store.inactivePlayers(lastSessionBefore: cutoff, limit: 10) == ["T:older", "T:old"])
            #expect(try await store.inactivePlayers(lastSessionBefore: cutoff, limit: 1) == ["T:older"])
            // An anonymous player is never deleted for inactivity: her seats are other players' races.
            try await store.erase("T:older", as: "deleted:o", reason: .inactive, at: Self.time - 800 * 86_400)
            #expect(try await store.inactivePlayers(lastSessionBefore: Self.time, limit: 10) == ["T:old", "T:new"])
        }
    }

    /// #28: reports and penalties are kept a year, or as long as a penalty lasts if longer.
    @Test func moderationIsPrunedAfterAYearOrThePenalty() async throws {
        try await TestDatabase.withMigratedSchema { database in
            let store = ModerationRecordStore(database), time = Self.time, year: TimeInterval = 365 * 86_400
            func report(_ at: Date) async throws -> StoredReport {
                try await store.file(StoredReport(kind: .player, reporterID: "T:r", subjectID: "T:s", subjectNickname: "s", createdAt: at, dueAt: at + 86_400))
            }
            let old = try await report(time - year - 1), recent = try await report(time - year + 1)
            let banned = try await report(time - 2 * year), muted = try await report(time - 2 * year)
            let ban = try await store.add(StoredPenalty(playerID: "T:s", kind: .chatBan, actorID: "a", reportID: banned.id, startsAt: time - 2 * year))
            _ = try await store.add(StoredPenalty(playerID: "T:s", kind: .chatMute, actorID: "a", reportID: muted.id, startsAt: time - 2 * year,
                                                  endsAt: time - 2 * year + 86_400))
            let lifted = try await store.add(StoredPenalty(playerID: "T:s", kind: .racingBan, actorID: "a", startsAt: time - year - 5))
            _ = try await store.lift(lifted.id, by: "a", at: time - year)
            let young = try await store.add(StoredPenalty(playerID: "T:s", kind: .racingWarning, actorID: "a", startsAt: time - 10))
            #expect(try await store.prune(before: time - year, at: time) == (penalties: 2, reports: 2))
            #expect(try await store.penalties(of: "T:s").map(\.id) == [ban.id, young.id])
            #expect(try await store.reports(against: "T:s", since: .distantPast).map(\.id).sorted() == [recent.id, banned.id].sorted())
            _ = old
        }
    }
}
