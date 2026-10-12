import Foundation
import Persistence
import Ratings
import RegattaServices
import Synchronization

// Moderation (#153; #17, #26, #34). Players report a lobby line (hidden from the reporter at once), a player (for her
// chat or a bad nickname) or another human's racing by seat. Every report goes to the admin queue, due within 24 h.
// Reports from 3 players within 24 h on someone's chat mute her for 24 h until a review. An upheld chat report takes
// the line down for everyone and mutes her, escalating 24 h → 7 days → permanent; a dismissed one lifts the automatic
// mute once nothing else of hers waits. Racing penalties (a warning, 24 h, 7 days, permanent, a rating reset) are
// only ever an admin's. A chat penalty never touches the queue and a racing penalty never touches the chat: the lobby
// reads chat standings from here, the queue reads suspensions from the restriction store, which only racing writes.
// A muted or suspended player is always told, with the end time: no shadow mutes.

/// Where reports and penalties are kept: Postgres in production (`ModerationRecordStore`, migration 0014), memory for a
/// dev server without a database and for tests.
public protocol ModerationStore: Sendable {
    func file(_ report: StoredReport) async throws -> StoredReport
    func report(_ id: Int64) async throws -> StoredReport?
    /// The reports awaiting a decision, the first due first.
    func pending(limit: Int) async throws -> [StoredReport]
    /// Every report against `subjectID` filed at or after `since`, oldest first.
    func reports(against subjectID: String, since: Date) async throws -> [StoredReport]
    /// Every report `reporterID` filed, oldest first.
    func reports(by reporterID: String) async throws -> [StoredReport]
    /// Decides a pending report; false when it was decided already, or there is none.
    func decide(_ id: Int64, _ decision: StoredReport.Decision, by actorID: String, at time: Date) async throws -> Bool
    func add(_ penalty: StoredPenalty) async throws -> StoredPenalty
    /// Every penalty the player was given, lifted or not, oldest first.
    func penalties(of playerID: String) async throws -> [StoredPenalty]
    /// Lifts a penalty; false when it was lifted already, or there is none.
    func lift(_ id: Int64, by actorID: String, at time: Date) async throws -> Bool
}

extension ModerationRecordStore: ModerationStore {}

/// Reports and penalties in memory. Lost on restart.
public final class InMemoryModerationStore: ModerationStore {
    private struct State {
        var reports: [StoredReport] = []
        var penalties: [StoredPenalty] = []
        var nextID: Int64 = 1
    }

    private let state = Mutex(State())

    public init() {}

    public func file(_ report: StoredReport) async throws -> StoredReport {
        state.withLock { state in
            var filed = report
            filed.id = state.nextID
            state.nextID += 1
            state.reports.append(filed)
            return filed
        }
    }

    public func report(_ id: Int64) async throws -> StoredReport? { state.withLock { $0.reports.first { $0.id == id } } }

    public func pending(limit: Int) async throws -> [StoredReport] {
        state.withLock { state in
            Array(state.reports.filter { $0.decision == nil }.sorted { ($0.dueAt, $0.id) < ($1.dueAt, $1.id) }.prefix(limit))
        }
    }

    public func reports(against subjectID: String, since: Date) async throws -> [StoredReport] {
        state.withLock { $0.reports.filter { $0.subjectID == subjectID && $0.createdAt >= since } }
    }

    public func reports(by reporterID: String) async throws -> [StoredReport] {
        state.withLock { $0.reports.filter { $0.reporterID == reporterID } }
    }

    public func decide(_ id: Int64, _ decision: StoredReport.Decision, by actorID: String, at time: Date) async throws -> Bool {
        state.withLock { state in
            guard let index = state.reports.firstIndex(where: { $0.id == id }), state.reports[index].decision == nil else { return false }
            state.reports[index].decision = decision
            state.reports[index].decidedAt = time
            state.reports[index].decidedBy = actorID
            return true
        }
    }

    public func add(_ penalty: StoredPenalty) async throws -> StoredPenalty {
        state.withLock { state in
            var added = penalty
            added.id = state.nextID
            state.nextID += 1
            state.penalties.append(added)
            return added
        }
    }

    public func penalties(of playerID: String) async throws -> [StoredPenalty] {
        state.withLock { $0.penalties.filter { $0.playerID == playerID } }
    }

    public func lift(_ id: Int64, by actorID: String, at time: Date) async throws -> Bool {
        state.withLock { state in
            guard let index = state.penalties.firstIndex(where: { $0.id == id }), state.penalties[index].liftedAt == nil else { return false }
            state.penalties[index].liftedAt = time
            state.penalties[index].liftedBy = actorID
            return true
        }
    }
}

/// An admin, by id (#153): whoever decides a report or gives a penalty. A racing penalty can't be given without one.
public struct AdminActor: Sendable, Equatable {
    public let id: String

    /// Throws `ModerationError.noAdmin` for an id that is empty once trimmed.
    public init(_ id: String) throws(ModerationError) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .noAdmin }
        self.id = trimmed
    }
}

public enum ModerationError: Error, Equatable, Sendable {
    /// No admin actor id.
    case noAdmin
    case unknownReport
    case alreadyDecided
    /// The decision doesn't fit the report: a racing penalty for a chat report, a chat one for a race report, a
    /// nickname override for a line.
    case decisionDoesntFit
    case unknownPenalty
}

/// A racing penalty (#26), always an admin's.
public enum RacingPenalty: Sendable, Equatable, CaseIterable {
    case warning
    case suspension24h
    case suspension7d
    case permanent
    case ratingReset
}

/// What an admin decides about a report.
public enum ReviewDecision: Sendable, Equatable {
    /// Nothing was wrong. A chat report dismissed lifts the automatic mute once none of the player's chat reports wait.
    case dismiss
    /// Her chat broke the rules: a reported line comes down for everyone, and she is muted one step up the ladder.
    case upholdChat
    /// A player report on her nickname: she shows as "Sailor" and her sail number from her next sign-in (#34).
    case overrideNickname
    /// A race report upheld, with the penalty.
    case racing(RacingPenalty)
}

public struct ModerationSettings: Sendable, Equatable {
    /// Reports on someone's chat from this many players...
    public var autoMuteReporters = 3
    /// ...within this long, mute her for `autoMuteLength`, until a review (#17).
    public var autoMuteWindow: TimeInterval = 24 * 3600
    public var autoMuteLength: TimeInterval = 24 * 3600
    /// The admin queue's SLA (#34).
    public var reviewWithin: TimeInterval = 24 * 3600
    /// The chat ladder: the first upheld report's mute, the second's; after them, permanent (#17).
    public var chatMutes: [TimeInterval] = [24 * 3600, 7 * 86_400]
    public var racingSuspensions: (short: TimeInterval, long: TimeInterval) = (24 * 3600, 7 * 86_400)

    public init() {}

    public static func == (lhs: ModerationSettings, rhs: ModerationSettings) -> Bool {
        lhs.autoMuteReporters == rhs.autoMuteReporters && lhs.autoMuteWindow == rhs.autoMuteWindow
            && lhs.autoMuteLength == rhs.autoMuteLength && lhs.reviewWithin == rhs.reviewWithin && lhs.chatMutes == rhs.chatMutes
            && lhs.racingSuspensions == rhs.racingSuspensions
    }
}

/// Who sat where in a race, as moderation reads it to take a race report.
public struct RaceSeating: Sendable, Equatable {
    /// The humans registered at fleet lock, by seat.
    public var humans: [RaceSeatHolder]
    /// Seats a bot took from their human before the gun (#149): bots' now.
    public var takenOver: Set<Int>

    public init(humans: [RaceSeatHolder], takenOver: Set<Int> = []) {
        self.humans = humans
        self.takenOver = takenOver
    }

    /// The human who sailed `seat`, if a human did.
    public func human(at seat: Int) -> String? {
        guard !takenOver.contains(seat) else { return nil }
        return humans.first { $0.seat == seat }?.playerID
    }
}

/// Moderation (#153): the lobby's `LobbyModeration`, the admin queue, and the penalties.
public final class Moderation: LobbyModeration {
    public let store: any ModerationStore
    public let restrictions: any RestrictionStore
    public let ratings: any RatingBook
    public let ratingConfig: RatingConfig
    public let settings: ModerationSettings
    let seats: @Sendable (RaceID) async throws -> RaceSeating?
    let now: @Sendable () -> Date
    /// The lobby, told of standings that change and of lines to take down. Made after this, as it reads it.
    private let lobby = LateBound<LobbyHub>()
    /// Each player's writes one after another (by the player reported or penalized): three reports at once still mute
    /// once. Other players' writes don't wait on hers.
    private let tails = Mutex<[String: Task<Void, Never>]>([:])
    /// Dev: race seatings the contract's situations arrange.
    private let devSeatings = Mutex<[RaceID: RaceSeating]>([:])

    /// `seats`: a race's seating, nil for a race that isn't known.
    public init(store: any ModerationStore, restrictions: any RestrictionStore, ratings: any RatingBook, ratingConfig: RatingConfig = RatingConfig(),
                settings: ModerationSettings = ModerationSettings(), seats: @escaping @Sendable (RaceID) async throws -> RaceSeating?,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.restrictions = restrictions
        self.ratings = ratings
        self.ratingConfig = ratingConfig
        self.settings = settings
        self.seats = seats
        self.now = now
    }

    /// The lobby to tell. Once, after it is made.
    public func attach(_ hub: LobbyHub) { lobby.set(hub) }

    // MARK: The lobby's seam

    public func standing(of playerID: String) async throws -> ChatStanding {
        Self.standing(try await store.penalties(of: playerID), at: now())
    }

    /// The chat standing `penalties` make at `time`: banned over muted, and the mute that ends last.
    static func standing(_ penalties: [StoredPenalty], at time: Date) -> ChatStanding {
        let active = penalties.filter { $0.kind.isChat && $0.applies(at: time) }
        if active.contains(where: { $0.kind == .chatBan }) { return .banned }
        guard let last = active.max(by: { ($0.endsAt ?? .distantPast, $0.id) < ($1.endsAt ?? .distantPast, $1.id) }), let ends = last.endsAt else {
            return .clear
        }
        return .muted(until: Int64(ends.timeIntervalSince1970.rounded(.up)), isAutomatic: last.automatic)
    }

    public func hiddenMessages(for playerID: String) async throws -> Set<Int64> {
        Set(try await store.reports(by: playerID).compactMap { $0.kind == .message ? $0.messageID : nil })
    }

    public func report(line: ReportedLine, by playerID: String) async throws {
        let body: String
        switch line.message.post?.body {
        case .text(let text): body = text
        case .quickChat(let quick): body = quick.text
        case nil: throw LobbyError.notReportable
        }
        let time = now()
        try await file(StoredReport(kind: .message, reporterID: playerID, subjectID: line.authorID,
                                    subjectNickname: line.message.post?.author.nickname ?? "", messageID: line.id, messageBody: body,
                                    messagePostedAt: line.postedAt, createdAt: time, dueAt: time + settings.reviewWithin))
    }

    /// A second report on the same player while the first waits files nothing.
    public func report(player: LobbyPlayerRef, by playerID: String) async throws {
        guard player.teamPlayerID != playerID else { throw LobbyError.notReportable }
        let time = now()
        try await file(StoredReport(kind: .player, reporterID: playerID, subjectID: player.teamPlayerID, subjectNickname: player.nickname,
                                    createdAt: time, dueAt: time + settings.reviewWithin))
    }

    /// Only a human she raced against: not her own seat, not a bot's (nor one a bot took over), not a race she didn't
    /// sail. A second report on the same seat while the first waits files nothing.
    public func report(race: RaceID, seat: Int, reason: RaceReportReason, by playerID: String) async throws {
        guard let seating = try await seating(of: race), seating.humans.contains(where: { $0.playerID == playerID }),
              let subject = seating.human(at: seat), subject != playerID else { throw LobbyError.notReportable }
        let time = now()
        let stored: StoredReport.Reason = switch reason {
        case .unsportingConduct: .unsportingConduct
        case .suspectedCheating: .suspectedCheating
        }
        try await file(StoredReport(kind: .race, reporterID: playerID, subjectID: subject, subjectNickname: "", raceID: race.rawValue,
                                    seat: seat, reason: stored, createdAt: time, dueAt: time + settings.reviewWithin))
    }

    private func seating(of race: RaceID) async throws -> RaceSeating? {
        if let arranged = devSeatings.withLock({ $0[race] }) { return arranged }
        return try await seats(race)
    }

    /// Files `report` unless the same reporter's same report waits already, then mutes on a third reporter.
    private func file(_ report: StoredReport) async throws {
        let muted: Bool = try await serially(report.subjectID) { [self] in
            let waiting = try await store.reports(by: report.reporterID).contains {
                $0.decision == nil && $0.kind == report.kind && $0.subjectID == report.subjectID && $0.messageID == report.messageID
                    && $0.raceID == report.raceID && $0.seat == report.seat
            }
            if !waiting { _ = try await store.file(report) }
            return report.isChat ? try await autoMute(report.subjectID, at: report.createdAt) : false
        }
        if muted { await lobby.value?.refresh(players: [report.subjectID]) }
    }

    /// Mutes `subjectID` for `autoMuteLength` when players enough reported her chat within the window and no chat
    /// penalty holds her already. Only reports awaiting review count; one reporter counts once, however often she reports.
    private func autoMute(_ subjectID: String, at time: Date) async throws -> Bool {
        let reporters = Set(try await store.reports(against: subjectID, since: time - settings.autoMuteWindow)
            .filter { $0.isChat && $0.decision == nil }.map(\.reporterID))
        guard reporters.count >= settings.autoMuteReporters else { return false }
        guard !(try await store.penalties(of: subjectID)).contains(where: { $0.kind.isChat && $0.applies(at: time) }) else { return false }
        _ = try await store.add(StoredPenalty(playerID: subjectID, kind: .chatMute, automatic: true, actorID: nil, startsAt: time,
                                              endsAt: time + settings.autoMuteLength))
        return true
    }

    // MARK: The admin queue

    /// The reports awaiting a decision, the first due first (#34: within 24 h of filing).
    public func queue(limit: Int = 100) async throws -> [StoredReport] { try await store.pending(limit: limit) }

    /// Decides a report. Returns the penalty it gave, if it gave one.
    @discardableResult
    public func decide(_ reportID: Int64, _ decision: ReviewDecision, by actor: AdminActor) async throws -> StoredPenalty? {
        let time = now()
        guard let filed = try await store.report(reportID) else { throw ModerationError.unknownReport }
        let (penalty, removed): (StoredPenalty?, Int64?) = try await serially(filed.subjectID) { [self] in
            guard let report = try await store.report(reportID) else { throw ModerationError.unknownReport }
            guard report.decision == nil else { throw ModerationError.alreadyDecided }
            switch (report.kind, decision) {
            case (_, .dismiss), (.message, .upholdChat), (.player, .upholdChat), (.player, .overrideNickname), (.race, .racing): break
            default: throw ModerationError.decisionDoesntFit
            }
            guard try await store.decide(reportID, decision == .dismiss ? .dismissed : .upheld, by: actor.id, at: time) else {
                throw ModerationError.alreadyDecided
            }
            switch decision {
            case .dismiss:
                if report.isChat { try await liftAutoMute(report.subjectID, unlessWaiting: true, by: actor, at: time) }
                return (nil, nil)
            case .upholdChat:
                try await liftAutoMute(report.subjectID, unlessWaiting: false, by: actor, at: time)
                // One step per incident: a chat penalty given since this report was filed covers it.
                let covering = try await store.penalties(of: report.subjectID).first {
                    $0.kind.isChat && !$0.automatic && $0.startsAt >= report.createdAt && $0.applies(at: time)
                }
                if let covering { return (covering, report.messageID) }
                return (try await escalate(report.subjectID, report: reportID, by: actor, at: time), report.messageID)
            case .overrideNickname:
                let active = try await store.penalties(of: report.subjectID).first { $0.kind == .nicknameOverride && $0.applies(at: time) }
                if let active { return (active, nil) }
                return (try await store.add(StoredPenalty(playerID: report.subjectID, kind: .nicknameOverride, actorID: actor.id,
                                                          reportID: reportID, startsAt: time)), nil)
            case .racing(let racing):
                return (try await give(racing, to: report.subjectID, report: reportID, by: actor, at: time), nil)
            }
        }
        // The decision is stored: what the lobby does with it can't undo it. A line that can't be taken down now is
        // logged (an admin takes it down by hand); her feeds are told whatever happened.
        if let removed {
            do {
                try await lobby.value?.remove(ids: [removed], reason: "report upheld")
            } catch {
                Self.log("can't take down line \(removed) after report \(reportID) was upheld: \(error)")
            }
        }
        if filed.isChat { await lobby.value?.refresh(players: [filed.subjectID]) }
        return penalty
    }

    /// Lifts the player's automatic mute: when a report is upheld (a real one replaces it), or dismissed and no chat
    /// report of hers waits any more (`unlessWaiting`).
    private func liftAutoMute(_ playerID: String, unlessWaiting: Bool, by actor: AdminActor, at time: Date) async throws {
        if unlessWaiting {
            let waiting = try await store.reports(against: playerID, since: .distantPast).contains { $0.isChat && $0.decision == nil }
            guard !waiting else { return }
        }
        for penalty in try await store.penalties(of: playerID) where penalty.automatic && penalty.applies(at: time) {
            _ = try await store.lift(penalty.id, by: actor.id, at: time)
        }
    }

    /// The next step of the chat ladder: each upheld chat penalty she was given before (and not lifted) is a step.
    private func escalate(_ playerID: String, report: Int64?, by actor: AdminActor, at time: Date) async throws -> StoredPenalty {
        let steps = try await store.penalties(of: playerID).filter { $0.kind.isChat && !$0.automatic && $0.liftedAt == nil }.count
        let penalty = steps < settings.chatMutes.count
            ? StoredPenalty(playerID: playerID, kind: .chatMute, actorID: actor.id, reportID: report, startsAt: time,
                            endsAt: time + settings.chatMutes[steps])
            : StoredPenalty(playerID: playerID, kind: .chatBan, actorID: actor.id, reportID: report, startsAt: time)
        return try await store.add(penalty)
    }

    // MARK: Penalties

    /// Gives a racing penalty (#26): only an admin can, and always with her id.
    @discardableResult
    public func penalize(_ playerID: String, _ penalty: RacingPenalty, by actor: AdminActor, report: Int64? = nil) async throws -> StoredPenalty {
        let time = now()
        return try await serially(playerID) { [self] in try await give(penalty, to: playerID, report: report, by: actor, at: time) }
    }

    private func give(_ racing: RacingPenalty, to playerID: String, report: Int64?, by actor: AdminActor, at time: Date) async throws -> StoredPenalty {
        let kind: StoredPenalty.Kind, ends: Date?
        switch racing {
        case .warning: (kind, ends) = (.racingWarning, nil)
        case .suspension24h: (kind, ends) = (.racingSuspension, time + settings.racingSuspensions.short)
        case .suspension7d: (kind, ends) = (.racingSuspension, time + settings.racingSuspensions.long)
        case .permanent: (kind, ends) = (.racingBan, nil)
        case .ratingReset: (kind, ends) = (.ratingReset, nil)
        }
        if racing == .ratingReset {
            _ = try await ratings.reset(playerID, reason: "moderation: \(actor.id)", at: time, config: ratingConfig)
        }
        let given = try await store.add(StoredPenalty(playerID: playerID, kind: kind, actorID: actor.id, reportID: report, startsAt: time,
                                                      endsAt: ends))
        if kind == .racingSuspension || kind == .racingBan { try await syncSuspension(playerID, at: time) }
        return given
    }

    /// An admin gives a chat penalty outright: the next step of the ladder.
    @discardableResult
    public func muteNext(_ playerID: String, by actor: AdminActor) async throws -> StoredPenalty {
        let time = now()
        let given = try await serially(playerID) { [self] in try await escalate(playerID, report: nil, by: actor, at: time) }
        await lobby.value?.refresh(players: [playerID])
        return given
    }

    /// Lifts one of the player's penalties (an appeal, or a mistake). A lifted chat penalty no longer counts as a step.
    public func lift(_ penaltyID: Int64, of playerID: String, by actor: AdminActor) async throws {
        let time = now()
        let lifted = try await serially(playerID) { [self] () -> StoredPenalty in
            guard let penalty = try await store.penalties(of: playerID).first(where: { $0.id == penaltyID }) else {
                throw ModerationError.unknownPenalty
            }
            _ = try await store.lift(penaltyID, by: actor.id, at: time)
            if penalty.kind == .racingSuspension || penalty.kind == .racingBan { try await syncSuspension(playerID, at: time) }
            return penalty
        }
        if lifted.kind.isChat { await lobby.value?.refresh(players: [playerID]) }
    }

    /// Writes the player's racing suspension to the restriction store, where the queue and the profile read it: a ban
    /// over a suspension, and the suspension that ends last; none lifts it. #160 calls it again when a deleted player
    /// returns, as her row (and the columns on it) went with her.
    /// The server calls it at each sign-in. A player moderation never suspended is left alone.
    public func syncSuspension(_ playerID: String) async throws {
        let time = now()
        try await serially(playerID) { [self] in
            guard try await store.penalties(of: playerID).contains(where: { $0.kind == .racingSuspension || $0.kind == .racingBan }) else { return }
            try await syncSuspension(playerID, at: time)
        }
    }

    private func syncSuspension(_ playerID: String, at time: Date) async throws {
        let active = try await store.penalties(of: playerID).filter { ($0.kind == .racingSuspension || $0.kind == .racingBan) && $0.applies(at: time) }
        let suspension: StoredSuspension? = if active.contains(where: { $0.kind == .racingBan }) {
            .permanent
        } else {
            active.compactMap(\.endsAt).max().map { StoredSuspension(until: $0) }
        }
        try await restrictions.setSuspension(playerID, suspension)
    }

    /// Whether the player shows as "Sailor" and her sail number (#34).
    public func nicknameOverridden(_ playerID: String) async throws -> Bool {
        let time = now()
        return try await store.penalties(of: playerID).contains { $0.kind == .nicknameOverride && $0.applies(at: time) }
    }

    /// The nickname an overridden player shows.
    public static func overriddenNickname(sailNumber: Int) -> String { "Sailor \(sailNumber)" }

    // MARK: Dev

    /// Dev: `playerID`'s chat standing from now on, for the Lobby contract's situations: her chat penalties lifted,
    /// then `standing`'s given by the "dev" admin.
    public func devSet(_ standing: ChatStanding, for playerID: String) async throws {
        let actor = try AdminActor("dev"), time = now()
        try await serially(playerID) { [self] in
            for penalty in try await store.penalties(of: playerID) where penalty.kind.isChat && penalty.applies(at: time) {
                _ = try await store.lift(penalty.id, by: actor.id, at: time)
            }
            switch standing {
            case .clear: break
            case .muted(let until, let automatic):
                _ = try await store.add(StoredPenalty(playerID: playerID, kind: .chatMute, automatic: automatic, actorID: automatic ? nil : actor.id,
                                                      startsAt: time, endsAt: Date(timeIntervalSince1970: TimeInterval(until))))
            case .banned:
                _ = try await store.add(StoredPenalty(playerID: playerID, kind: .chatBan, actorID: actor.id, startsAt: time))
            }
        }
    }

    /// Dev: `race`'s seating, for the Lobby contract's race reports.
    public func devSeat(_ race: RaceID, _ seating: RaceSeating) { devSeatings.withLock { $0[race] = seating } }

    // MARK: -

    /// Runs `work` after every earlier write of `playerID`'s.
    private func serially<T: Sendable>(_ playerID: String, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let (task, marker): (Task<T, any Error>, Task<Void, Never>) = tails.withLock { tails in
            let previous = tails[playerID]
            let task = Task { _ = await previous?.value; return try await work() }
            let marker = Task { _ = try? await task.value }
            tails[playerID] = marker
            return (task, marker)
        }
        defer {
            Task { [self] in
                await marker.value
                tails.withLock { if $0[playerID] == marker { $0[playerID] = nil } }
            }
        }
        return try await task.value
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("RegattaServer: moderation: \(message)\n".utf8))
    }
}

extension RaceArchive {
    /// The seating a race report reads.
    func seating(of race: RaceID) async throws -> RaceSeating? {
        guard let id = UUID(uuidString: race.rawValue) else { return nil }
        return try await seats(of: id)
    }
}
