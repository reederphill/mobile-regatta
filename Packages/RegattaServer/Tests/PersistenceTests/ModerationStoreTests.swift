import Foundation
import Persistence
import PostgresNIO
import Testing

/// #153: reports and penalties in Postgres: filed and read back, the admin queue by due time, decided once, lifted
/// once; a penalty other than the automatic mute names its admin; and both outlive the player's row (#160, #28).
@Suite(TestDatabase.available) struct ModerationStoreTests {
    static let time = Date(timeIntervalSince1970: 1_791_460_800)

    static func report(_ kind: StoredReport.Kind, by reporter: String = "T:a", against subject: String = "T:b", at time: Date = time) -> StoredReport {
        switch kind {
        case .message:
            StoredReport(kind: .message, reporterID: reporter, subjectID: subject, subjectNickname: "b", messageID: 7, messageBody: "fair winds",
                         messagePostedAt: time - 60, createdAt: time, dueAt: time + 86_400)
        case .player:
            StoredReport(kind: .player, reporterID: reporter, subjectID: subject, subjectNickname: "b", createdAt: time, dueAt: time + 86_400)
        case .race:
            StoredReport(kind: .race, reporterID: reporter, subjectID: subject, subjectNickname: "", raceID: UUID().uuidString, seat: 3,
                         reason: .suspectedCheating, createdAt: time, dueAt: time + 86_400)
        }
    }

    @Test func reportsAreFiledQueuedByDueTimeAndDecidedOnce() async throws {
        try await TestDatabase.withMigratedSchema { database in
            let store = ModerationRecordStore(database), time = Self.time
            let race = try await store.file(Self.report(.race, at: time + 120))
            let message = try await store.file(Self.report(.message))
            let player = try await store.file(Self.report(.player, by: "T:c", at: time + 60))
            #expect(message.id > 0 && player.id > message.id)
            #expect(try await store.report(message.id) == message)
            #expect(try await store.report(race.id) == race)
            #expect(try await store.pending(limit: 10).map(\.id) == [message.id, player.id, race.id])
            #expect(try await store.pending(limit: 2).count == 2)
            #expect(try await store.reports(against: "T:b", since: time + 60).map(\.id) == [player.id, race.id])
            #expect(try await store.reports(by: "T:a").map(\.id) == [message.id, race.id])
            #expect(try await store.decide(message.id, .upheld, by: "admin-1", at: time + 600))
            #expect(try await !store.decide(message.id, .dismissed, by: "admin-1", at: time + 700))
            #expect(try await !store.decide(999_999, .dismissed, by: "admin-1", at: time))
            let decided = try #require(try await store.report(message.id))
            #expect(decided.decision == .upheld && decided.decidedBy == "admin-1" && decided.decidedAt == time + 600)
            #expect(try await store.pending(limit: 10).map(\.id) == [player.id, race.id])
            await #expect(throws: (any Error).self) { try await store.decide(player.id, .upheld, by: "", at: time) }
            // A report on yourself, a line report without its words, a race report without its seat.
            await #expect(throws: (any Error).self) { _ = try await store.file(Self.report(.player, by: "T:b")) }
            var wordless = Self.report(.message)
            wordless.messageBody = nil
            await #expect(throws: (any Error).self) { _ = try await store.file(wordless) }
            var seatless = Self.report(.race)
            seatless.seat = nil
            await #expect(throws: (any Error).self) { _ = try await store.file(seatless) }
        }
    }

    /// Acceptance: a racing penalty can't be stored without an admin; only the automatic mute has none.
    @Test func penaltiesNameTheirAdminAndAreLiftedOnce() async throws {
        try await TestDatabase.withMigratedSchema { database in
            let store = ModerationRecordStore(database), time = Self.time
            let mute = try await store.add(StoredPenalty(playerID: "T:b", kind: .chatMute, automatic: true, actorID: nil, startsAt: time,
                                                         endsAt: time + 86_400))
            let suspension = try await store.add(StoredPenalty(playerID: "T:b", kind: .racingSuspension, actorID: "admin-1", startsAt: time,
                                                               endsAt: time + 7 * 86_400))
            let reset = try await store.add(StoredPenalty(playerID: "T:b", kind: .ratingReset, actorID: "admin-1", startsAt: time + 1))
            #expect(try await store.penalties(of: "T:b") == [mute, suspension, reset])
            #expect(try await store.penalties(of: "T:a").isEmpty)
            for kind in StoredPenalty.Kind.allCases {
                await #expect(throws: (any Error).self) {
                    _ = try await store.add(StoredPenalty(playerID: "T:b", kind: kind, actorID: nil, startsAt: time,
                                                          endsAt: kind == .chatMute || kind == .racingSuspension ? time + 60 : nil))
                }
                await #expect(throws: (any Error).self) {
                    _ = try await store.add(StoredPenalty(playerID: "T:b", kind: kind, actorID: "", startsAt: time,
                                                          endsAt: kind == .chatMute || kind == .racingSuspension ? time + 60 : nil))
                }
            }
            // Only a mute is automatic; a mute or suspension has an end after its start, the rest none.
            await #expect(throws: (any Error).self) {
                _ = try await store.add(StoredPenalty(playerID: "T:b", kind: .racingSuspension, automatic: true, actorID: nil, startsAt: time,
                                                      endsAt: time + 60))
            }
            await #expect(throws: (any Error).self) {
                _ = try await store.add(StoredPenalty(playerID: "T:b", kind: .chatMute, actorID: "admin-1", startsAt: time))
            }
            await #expect(throws: (any Error).self) {
                _ = try await store.add(StoredPenalty(playerID: "T:b", kind: .chatBan, actorID: "admin-1", startsAt: time, endsAt: time + 60))
            }
            await #expect(throws: (any Error).self) {
                _ = try await store.add(StoredPenalty(playerID: "T:b", kind: .chatMute, actorID: "admin-1", startsAt: time, endsAt: time))
            }
            #expect(try await store.lift(mute.id, by: "admin-1", at: time + 60))
            #expect(try await !store.lift(mute.id, by: "admin-1", at: time + 120))
            let lifted = try #require(try await store.penalties(of: "T:b").first)
            #expect(lifted.liftedAt == time + 60 && lifted.liftedBy == "admin-1" && !lifted.applies(at: time + 61))
            #expect(suspension.applies(at: time) && !suspension.applies(at: time + 7 * 86_400))
        }
    }

    /// Penalties and reports against a player outlive her row (Delete my online data deletes it, #160): they stay for
    /// their #28 retention and apply again if she returns.
    @Test func penaltiesAndReportsOutliveThePlayersRow() async throws {
        try await TestDatabase.withMigratedSchema { database in
            for name in ["a", "b"] { _ = try await PlayerStore(database).signIn(teamPlayerID: "T:\(name)", gamePlayerID: "G:\(name)", displayName: name) }
            let store = ModerationRecordStore(database), time = Self.time
            let report = try await store.file(Self.report(.player))
            let ban = try await store.add(StoredPenalty(playerID: "T:b", kind: .chatBan, actorID: "admin-1", reportID: report.id, startsAt: time))
            try await database.client.query("DELETE FROM players WHERE team_player_id = 'T:b'")
            #expect(try await store.penalties(of: "T:b") == [ban])
            #expect(try await store.reports(against: "T:b", since: .distantPast) == [report])
        }
    }

    /// The admin audit (#154): newest first, for everyone or one player, and pruned with the moderation tables at a year.
    @Test func theAdminAuditIsKeptAYear() async throws {
        try await TestDatabase.withMigratedSchema { database in
            let store = ModerationRecordStore(database), time = Self.time
            let old = try await store.record(StoredAdminAction(actorID: "alice", action: "mute", playerID: "T:a", at: time))
            let report = try await store.record(StoredAdminAction(actorID: "bob", action: "decide_report", playerID: "T:b", reportID: 4,
                                                                  penaltyID: 9, detail: "uphold_chat", at: time + 60))
            let nobody = try await store.record(StoredAdminAction(actorID: "bob", action: "note", at: time + 120))
            #expect(try await store.actions(limit: 10) == [nobody, report, old])
            #expect(try await store.actions(limit: 2) == [nobody, report])
            #expect(try await store.actions(about: "T:b", limit: 10) == [report])
            await #expect(throws: (any Error).self) { try await store.record(StoredAdminAction(actorID: "", action: "mute", at: time)) }
            _ = try await store.prune(before: time + 30, at: time + 30)
            #expect(try await store.actions(limit: 10) == [nobody, report])
        }
    }

    /// Fair-play flags (#155): raised, queued by due time, decided once, and pruned at a year.
    @Test func flagsAreRaisedQueuedAndDecidedOnce() async throws {
        try await TestDatabase.withMigratedSchema { database in
            let store = ModerationRecordStore(database), time = Self.time
            let late = try await store.raise(StoredFlag(kind: .lateDrops, playerID: "T:a", value: 3, threshold: 3, raceIDs: ["r1", "r2", "r3"],
                                                        detail: "gone", createdAt: time, dueAt: time + 7200))
            let calls = try await store.raise(StoredFlag(kind: .ruleCalls, playerID: "T:b", value: 1.2, threshold: 0.75, raceIDs: [],
                                                         detail: "calls", createdAt: time + 60, dueAt: time + 3600))
            #expect(late.id > 0 && late.raceIDs == ["r1", "r2", "r3"])
            #expect(try await store.flag(late.id) == late)
            #expect(try await store.pendingFlags(limit: 10) == [calls, late])
            #expect(try await store.decideFlag(calls.id, .upheld, by: "alice", at: time + 120))
            #expect(try await !store.decideFlag(calls.id, .dismissed, by: "alice", at: time + 180))
            #expect(try await store.pendingFlags(limit: 10) == [late])
            let decided = try #require(try await store.flag(calls.id))
            #expect(decided.decision == .upheld && decided.decidedBy == "alice" && decided.decidedAt == time + 120)
            #expect(try await store.flags(of: "T:b") == [decided])
            _ = try await store.prune(before: time + 30, at: time + 30)
            #expect(try await store.flag(late.id) == nil)
            #expect(try await store.flag(calls.id) != nil)
        }
    }
}
