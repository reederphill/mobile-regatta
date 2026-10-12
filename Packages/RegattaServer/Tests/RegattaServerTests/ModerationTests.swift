import Crypto
import Foundation
import Persistence
import Ratings
import RegattaCore
@testable import RegattaServerKit
import RegattaServices
import Testing

/// Moderation over the lobby rig (#153): the hub on a virtual clock, with reports, penalties, restrictions, ratings and
/// race seatings the test holds.
struct ModerationRig {
    let lobby: LobbyRig
    let store = InMemoryModerationStore()
    let restrictions = InMemoryRestrictionStore()
    let archive = InMemoryRaceArchive()
    let moderation: Moderation
    let admin = try! AdminActor("admin-1")

    init() {
        let clock = VirtualClock(), book = InMemoryRatingBook(), store = store, restrictions = restrictions, archive = archive
        moderation = Moderation(store: store, restrictions: restrictions, ratings: book, seats: { try await archive.seating(of: $0) },
                                now: { clock.now })
        lobby = LobbyRig(clock: clock, book: book, moderation: moderation)
        moderation.attach(lobby.hub)
    }

    var clock: VirtualClock { lobby.clock }
    var hub: LobbyHub { lobby.hub }

    /// `name`'s lobby line, posted now.
    func line(by name: String, _ text: String = "fair winds") async throws -> LobbyMessage {
        lobby.nextSlot()
        return try await lobby.service(name).post(text)
    }

    func standing(_ name: String) async throws -> ChatStanding { try await moderation.standing(of: "T:\(name)") }
}

@Suite(.timeLimit(.minutes(2))) struct ModerationTests {
    // MARK: Reports and the automatic mute

    @Test func aReportedLineIsHiddenFromTheReporterAloneAndQueued() async throws {
        let rig = ModerationRig()
        let line = try await rig.line(by: "gull")
        let wren = rig.lobby.service("wren"), tern = rig.lobby.service("tern")
        try await wren.report(message: line.id)
        #expect(try await !wren.history().contains { $0.id == line.id })
        #expect(try await tern.history().contains { $0.id == line.id })
        await #expect(throws: LobbyError.unknownMessage) { try await wren.report(message: line.id) }
        let queued = try await rig.moderation.queue()
        #expect(queued.count == 1)
        #expect(queued.first?.kind == .message && queued.first?.reporterID == "T:wren" && queued.first?.subjectID == "T:gull")
        #expect(queued.first?.messageBody == "fair winds" && queued.first?.subjectNickname == "gull")
        #expect(queued.first?.dueAt == rig.clock.now + 24 * 3600)
        #expect(try await rig.standing("gull") == .clear)
    }

    /// Acceptance: auto-mute never triggers on 3 reports from one reporter.
    @Test func threeReportsFromOneReporterNeverMute() async throws {
        let rig = ModerationRig()
        let wren = rig.lobby.service("wren")
        for _ in 0..<3 {
            let line = try await rig.line(by: "gull")
            try await wren.report(message: line.id)
        }
        try await wren.report(player: GamePlayerID("G:gull"))
        try await wren.report(player: GamePlayerID("G:gull"))
        #expect(try await rig.standing("gull") == .clear)
        // A second reporter makes two.
        let line = try await rig.line(by: "gull")
        try await rig.lobby.service("tern").report(message: line.id)
        #expect(try await rig.standing("gull") == .clear)
        // A repeated player report while the first waits files nothing.
        #expect(try await rig.moderation.queue().filter { $0.kind == .player }.count == 1)
    }

    @Test func threeReportersWithin24HoursMuteFor24HoursAndSheIsTold() async throws {
        let rig = ModerationRig()
        let gull = rig.lobby.service("gull")
        let (feed, _) = await rig.lobby.feed(gull)
        let line = try await rig.line(by: "gull")
        _ = await feed.next()
        try await rig.lobby.service("wren").report(message: line.id)
        try await rig.lobby.service("tern").report(player: GamePlayerID("G:gull"))
        rig.clock.advance(23 * 3600)
        // The lobby shows the last hour: the third reports a newer line.
        let later = try await rig.line(by: "gull", "still here")
        _ = await feed.next()
        try await rig.lobby.service("skua").report(message: later.id)
        let until = Int64((rig.clock.now + 24 * 3600).timeIntervalSince1970)
        #expect(try await rig.standing("gull") == .muted(until: until, isAutomatic: true))
        // No shadow mute: her feed is told, with the end time.
        #expect(await feed.next() == .state(LobbyState(access: .open, canPostFreeText: true, standing: .muted(until: until, isAutomatic: true))))
        rig.lobby.nextSlot()
        await #expect(throws: LobbyError.muted(until: until)) { _ = try await gull.post(.gg) }
        // A fourth reporter doesn't stack another.
        try await rig.lobby.service("tern2").report(message: later.id)
        #expect(try await rig.store.penalties(of: "T:gull").count == 1)
        // It ends by itself after 24 h.
        rig.clock.advance(24 * 3600)
        #expect(try await rig.standing("gull") == .clear)
    }

    @Test func reportsOlderThan24HoursOrDismissedDontCount() async throws {
        let rig = ModerationRig()
        _ = try await rig.line(by: "gull")
        try await rig.lobby.service("wren").report(player: GamePlayerID("G:gull"))
        rig.clock.advance(24 * 3600 + 1)
        let line = try await rig.line(by: "gull")
        try await rig.lobby.service("tern").report(message: line.id)
        let dismissed = try #require(try await rig.moderation.queue().last)
        try await rig.moderation.decide(dismissed.id, .dismiss, by: rig.admin)
        try await rig.lobby.service("skua").report(message: line.id)
        try await rig.lobby.service("tern2").report(message: line.id)
        #expect(try await rig.standing("gull") == .clear)
        try await rig.lobby.service("puffin").report(message: line.id)
        #expect(try await rig.standing("gull") != .clear)
    }

    // MARK: Decisions

    @Test func dismissingLiftsTheAutomaticMuteOnceNothingWaits() async throws {
        let rig = ModerationRig()
        let line = try await rig.line(by: "gull")
        for name in ["wren", "tern", "skua"] { try await rig.lobby.service(name).report(message: line.id) }
        guard case .muted(_, true) = try await rig.standing("gull") else { Issue.record("not muted"); return }
        let queued = try await rig.moderation.queue()
        try await rig.moderation.decide(queued[0].id, .dismiss, by: rig.admin)
        try await rig.moderation.decide(queued[1].id, .dismiss, by: rig.admin)
        #expect(try await rig.standing("gull") != .clear)
        try await rig.moderation.decide(queued[2].id, .dismiss, by: rig.admin)
        #expect(try await rig.standing("gull") == .clear)
        await #expect(throws: ModerationError.alreadyDecided) { try await rig.moderation.decide(queued[2].id, .dismiss, by: rig.admin) }
        await #expect(throws: ModerationError.unknownReport) { try await rig.moderation.decide(999, .dismiss, by: rig.admin) }
        #expect(try await rig.moderation.queue().isEmpty)
    }

    /// Upheld: the line comes down for everyone and she is muted, 24 h → 7 days → permanent; the automatic mute goes.
    @Test func upheldChatEscalatesAndTakesTheLineDownForEveryone() async throws {
        let rig = ModerationRig()
        let tern = rig.lobby.service("tern")
        let (feed, _) = await rig.lobby.feed(tern)
        var steps: [ChatStanding] = [], given: [StoredPenalty] = []
        for round in 0..<3 {
            let line = try await rig.line(by: "gull", "round \(round)")
            _ = await feed.next()
            for name in ["wren", "skua", "puffin"] { try await rig.lobby.service(name).report(message: line.id) }
            let report = try #require(try await rig.moderation.queue().first { $0.messageID.map(String.init) == line.id.rawValue })
            let penalty = try await rig.moderation.decide(report.id, .upholdChat, by: rig.admin)
            if let penalty { given.append(penalty) }
            #expect(penalty?.actorID == "admin-1" && penalty?.reportID == report.id && penalty?.automatic == false)
            #expect(try await !tern.history().contains { $0.id == line.id })
            let events = await feed.read { $0 == .removed(line.id) }
            #expect(events.last == .removed(line.id))
            steps.append(try await rig.standing("gull"))
            for report in try await rig.moderation.queue() { try await rig.moderation.decide(report.id, .dismiss, by: rig.admin) }
            rig.clock.advance(8 * 86_400)
        }
        #expect(given.map(\.kind) == [.chatMute, .chatMute, .chatBan])
        #expect(given.map { penalty in penalty.endsAt.map { $0.timeIntervalSince(penalty.startsAt) } ?? 0 } == [86_400, 7 * 86_400, 0])
        #expect(steps == [.muted(until: Int64(given[0].endsAt!.timeIntervalSince1970), isAutomatic: false),
                          .muted(until: Int64(given[1].endsAt!.timeIntervalSince1970), isAutomatic: false), .banned])
        // The automatic mutes were lifted, not left to run.
        #expect(try await rig.store.penalties(of: "T:gull").filter(\.automatic).allSatisfy { $0.liftedBy == "admin-1" })
    }

    /// Three reports on one line, each upheld, are one incident: one step, not a ban.
    @Test func oneIncidentIsOneStep() async throws {
        let rig = ModerationRig()
        let line = try await rig.line(by: "gull")
        for name in ["wren", "skua", "puffin"] { try await rig.lobby.service(name).report(message: line.id) }
        try await rig.lobby.service("tern").report(player: GamePlayerID("G:gull"))
        var given: [Int64] = []
        for report in try await rig.moderation.queue() {
            if let penalty = try await rig.moderation.decide(report.id, .upholdChat, by: rig.admin) { given.append(penalty.id) }
        }
        #expect(Set(given).count == 1)
        guard case .muted(_, false) = try await rig.standing("gull") else { Issue.record("not muted 24 h"); return }
        // A report filed after it is a new incident (muted, her chat is reported as a player).
        rig.clock.advance(60)
        try await rig.lobby.service("wren").report(player: GamePlayerID("G:gull"))
        let report = try #require(try await rig.moderation.queue().first)
        let next = try await rig.moderation.decide(report.id, .upholdChat, by: rig.admin)
        #expect(next.flatMap { $0.endsAt?.timeIntervalSince($0.startsAt) } == TimeInterval(7 * 86_400))
    }

    /// Reports already reviewed don't mute again, even inside the window.
    @Test func reviewedReportsDontCountTowardTheAutomaticMute() async throws {
        let rig = ModerationRig()
        let line = try await rig.line(by: "gull")
        for name in ["wren", "skua"] { try await rig.lobby.service(name).report(message: line.id) }
        for report in try await rig.moderation.queue() {
            let penalty = try await rig.moderation.decide(report.id, .upholdChat, by: rig.admin)
            if let penalty { try await rig.moderation.lift(penalty.id, of: "T:gull", by: rig.admin) }
        }
        let later = try await rig.line(by: "gull", "later")
        try await rig.lobby.service("puffin").report(message: later.id)
        #expect(try await rig.standing("gull") == .clear)
    }

    @Test func signInWritesOnlyTheSuspensionsModerationGave() async throws {
        let rig = ModerationRig()
        try await rig.restrictions.setSuspension("T:wren", .permanent)
        try await rig.moderation.syncSuspension("T:wren")
        #expect(try await rig.restrictions.restrictions(of: "T:wren").suspension == .permanent)
        _ = try await rig.moderation.penalize("T:gull", .suspension7d, by: rig.admin)
        try await rig.restrictions.setSuspension("T:gull", nil)
        try await rig.moderation.syncSuspension("T:gull")
        #expect(try await rig.restrictions.restrictions(of: "T:gull").suspension == StoredSuspension(until: rig.clock.now + 7 * 86_400))
    }

    @Test func aLiftedChatPenaltyIsNoStep() async throws {
        let rig = ModerationRig()
        let first = try await rig.moderation.muteNext("T:gull", by: rig.admin)
        try await rig.moderation.lift(first.id, of: "T:gull", by: rig.admin)
        #expect(try await rig.standing("gull") == .clear)
        let again = try await rig.moderation.muteNext("T:gull", by: rig.admin)
        #expect(again.endsAt == rig.clock.now + 86_400)
        await #expect(throws: ModerationError.unknownPenalty) { try await rig.moderation.lift(again.id, of: "T:wren", by: rig.admin) }
    }

    @Test func decisionsMustFitTheReport() async throws {
        let rig = ModerationRig()
        let line = try await rig.line(by: "gull")
        try await rig.lobby.service("wren").report(message: line.id)
        try await rig.lobby.service("wren").report(player: GamePlayerID("G:gull"))
        let race = try await rig.raceReport()
        let queued = try await rig.moderation.queue()
        let message = try #require(queued.first { $0.kind == .message }), player = try #require(queued.first { $0.kind == .player })
        await #expect(throws: ModerationError.decisionDoesntFit) { try await rig.moderation.decide(message.id, .overrideNickname, by: rig.admin) }
        await #expect(throws: ModerationError.decisionDoesntFit) { try await rig.moderation.decide(message.id, .racing(.warning), by: rig.admin) }
        await #expect(throws: ModerationError.decisionDoesntFit) { try await rig.moderation.decide(player.id, .racing(.permanent), by: rig.admin) }
        await #expect(throws: ModerationError.decisionDoesntFit) { try await rig.moderation.decide(race.id, .upholdChat, by: rig.admin) }
        await #expect(throws: ModerationError.decisionDoesntFit) { try await rig.moderation.decide(race.id, .overrideNickname, by: rig.admin) }
        #expect(try await rig.moderation.queue().count == 3)
    }

    /// Acceptance: a player report on a nickname enters the admin queue; upheld, she shows as "Sailor" and her sail
    /// number from her next sign-in.
    @Test func aNicknameReportIsQueuedAndOverridesTheNickname() async throws {
        let rig = ModerationRig()
        _ = try await rig.line(by: "gull")
        try await rig.lobby.service("wren").report(player: GamePlayerID("G:gull"))
        let report = try #require(try await rig.moderation.queue().first)
        #expect(report.kind == .player && report.subjectID == "T:gull" && report.subjectNickname == "gull" && report.decision == nil)
        #expect(try await !rig.moderation.nicknameOverridden("T:gull"))
        let penalty = try await rig.moderation.decide(report.id, .overrideNickname, by: rig.admin)
        #expect(penalty?.kind == .nicknameOverride)
        #expect(try await rig.moderation.nicknameOverridden("T:gull"))
        #expect(try await rig.standing("gull") == .clear)
        #expect(Moderation.overriddenNickname(sailNumber: 42) == "Sailor 42")
    }

    /// The server shows an overridden nickname from sign-in: "Sailor" and her sail number.
    @Test func theServerSignsAnOverriddenPlayerInAsSailor() async throws {
        let endpoint = try ServiceEndpoint.make(config: .dev(), store: InMemoryAccountStore(), wordList: .empty)
        let moderation = try #require(endpoint.moderation)
        let gull = AccountPlayer(teamPlayerID: "T:gull", gamePlayerID: "G:gull", alias: "rude name")
        #expect(try await endpoint.sessions.nickname(gull) == "rude name")
        try await moderation.report(player: LobbyPlayerRef(teamPlayerID: "T:gull", gamePlayerID: "G:gull", nickname: "rude name"), by: "T:wren")
        let report = try #require(try await moderation.queue().first)
        try await moderation.decide(report.id, .overrideNickname, by: try AdminActor("admin-1"))
        let number = try await StarterLiveries(boatClass: RaceFiles.defaults.boatClass.ref.id).livery(of: gull).sailNumber
        #expect(try await endpoint.sessions.nickname(gull) == "Sailor \(number)")
        #expect(try await endpoint.sessions.nickname(AccountPlayer(teamPlayerID: "T:wren", gamePlayerID: "G:wren", alias: "wren")) == "wren")
    }

    // MARK: Racing

    /// Acceptance: a racing penalty can't be created without an admin actor id.
    @Test func racingPenaltiesNeedAnAdmin() async throws {
        #expect(throws: ModerationError.noAdmin) { _ = try AdminActor("") }
        #expect(throws: ModerationError.noAdmin) { _ = try AdminActor(" \n") }
        #expect(try AdminActor(" ops-7 ").id == "ops-7")
        let rig = ModerationRig()
        for racing in RacingPenalty.allCases {
            let given = try await rig.moderation.penalize("T:gull", racing, by: rig.admin)
            #expect(given.actorID == "admin-1" && !given.automatic)
        }
    }

    @Test func racingSuspensionsAreWrittenForTheQueueAndLiftedAgain() async throws {
        let rig = ModerationRig()
        let warning = try await rig.moderation.penalize("T:gull", .warning, by: rig.admin)
        #expect(warning.kind == .racingWarning && warning.endsAt == nil)
        #expect(try await rig.restrictions.restrictions(of: "T:gull").refusal(at: rig.clock.now) == nil)
        let day = try await rig.moderation.penalize("T:gull", .suspension24h, by: rig.admin)
        let week = try await rig.moderation.penalize("T:gull", .suspension7d, by: rig.admin)
        let weekEnd = rig.clock.now + 7 * 86_400
        #expect(try await rig.restrictions.restrictions(of: "T:gull").suspension == StoredSuspension(until: weekEnd))
        // Told with the end time.
        #expect(try await rig.restrictions.restrictions(of: "T:gull").refusal(at: rig.clock.now)
            == .suspended(until: Int64(weekEnd.timeIntervalSince1970)))
        try await rig.moderation.lift(week.id, of: "T:gull", by: rig.admin)
        #expect(try await rig.restrictions.restrictions(of: "T:gull").suspension == StoredSuspension(until: day.endsAt))
        let ban = try await rig.moderation.penalize("T:gull", .permanent, by: rig.admin)
        #expect(try await rig.restrictions.restrictions(of: "T:gull").suspension == .permanent)
        try await rig.moderation.lift(ban.id, of: "T:gull", by: rig.admin)
        try await rig.moderation.lift(day.id, of: "T:gull", by: rig.admin)
        #expect(try await rig.restrictions.restrictions(of: "T:gull").suspension == nil)
    }

    @Test func aRatingResetPutsHerBackToTheStart() async throws {
        let rig = ModerationRig()
        rig.lobby.book.set(PlayerRating(glicko: Glicko2(rating: 1900, deviation: 60, volatility: 0.06), established: true), for: "T:gull")
        let reset = try await rig.moderation.penalize("T:gull", .ratingReset, by: rig.admin)
        #expect(reset.kind == .ratingReset)
        let rating = try #require(try await rig.lobby.book.ratings(of: ["T:gull"])["T:gull"])
        #expect(rating.glicko.rating == 1500 && !rating.established)
    }

    /// Acceptance: a chat penalty never blocks queue join, and a racing penalty never blocks chat.
    @Test func chatAndRacingPenaltiesStayApart() async throws {
        let rig = ModerationRig()
        for _ in 0..<3 { _ = try await rig.moderation.muteNext("T:gull", by: rig.admin) }
        #expect(try await rig.standing("gull") == .banned)
        #expect(try await rig.restrictions.restrictions(of: "T:gull") == .none)
        let clock = rig.clock
        let matchmaker = QueueMatchmaker(settings: QueueSettings(), registry: RaceRegistry(),
                                         draw: RaceDraw(pairings: OnlinePairing.bundled(), seeds: FixtureWindSeedPools(poolSize: 8)),
                                         tokenKey: QueueMatchmakerTests.key, tokenLifetime: 600, now: { clock.now }, restrictions: rig.restrictions)
        let gull = AccountPlayer(teamPlayerID: "T:gull", gamePlayerID: "G:gull", alias: "gull")
        try await matchmaker.join(gull)
        try await matchmaker.leave(gull.teamPlayerID)

        _ = try await rig.moderation.penalize("T:wren", .permanent, by: rig.admin)
        await #expect(throws: QueueError.self) { try await matchmaker.join(AccountPlayer(teamPlayerID: "T:wren", gamePlayerID: "G:wren", alias: "wren")) }
        #expect(try await rig.standing("wren") == .clear)
        let sent = try await rig.line(by: "wren")
        #expect(sent.post?.delivery == .sent)
    }

    @Test func raceReportsTakeOnlyAHumanSheRacedAgainst() async throws {
        let rig = ModerationRig()
        let race = UUID()
        try await rig.archive.register(race, players: [RaceSeatHolder(playerID: "T:wren", seat: 0), RaceSeatHolder(playerID: "T:gull", seat: 1),
                                                       RaceSeatHolder(playerID: "T:skua", seat: 3)])
        let id = RaceID(race.uuidString)
        let wren = rig.lobby.service("wren")
        try await wren.report(race: id, seat: 1, reason: .suspectedCheating)
        // A bot's seat, her own, a seat nobody sat, a race she didn't sail, a race nobody knows.
        await #expect(throws: LobbyError.notReportable) { try await wren.report(race: id, seat: 2, reason: .unsportingConduct) }
        await #expect(throws: LobbyError.notReportable) { try await wren.report(race: id, seat: 0, reason: .unsportingConduct) }
        await #expect(throws: LobbyError.notReportable) { try await wren.report(race: id, seat: 9, reason: .unsportingConduct) }
        await #expect(throws: LobbyError.notReportable) {
            try await rig.lobby.service("tern").report(race: id, seat: 1, reason: .unsportingConduct)
        }
        await #expect(throws: LobbyError.notReportable) { try await wren.report(race: RaceID(UUID().uuidString), seat: 1, reason: .unsportingConduct) }
        await #expect(throws: LobbyError.notReportable) { try await wren.report(race: RaceID("not-a-race"), seat: 1, reason: .unsportingConduct) }
        // A seat a bot took over before the gun is a bot's.
        #expect(RaceSeating(humans: [RaceSeatHolder(playerID: "T:skua", seat: 3)], takenOver: [3]).human(at: 3) == nil)
        let queued = try await rig.moderation.queue()
        #expect(queued.count == 1)
        #expect(queued.first?.kind == .race && queued.first?.subjectID == "T:gull" && queued.first?.seat == 1
            && queued.first?.reason == .suspectedCheating && queued.first?.raceID == race.uuidString)
        // Race reports never mute.
        for name in ["skua"] { try await rig.lobby.service(name).report(race: id, seat: 1, reason: .unsportingConduct) }
        #expect(try await rig.standing("gull") == .clear)
        // Upheld with a penalty.
        let penalty = try await rig.moderation.decide(queued[0].id, .racing(.suspension24h), by: rig.admin)
        #expect(penalty?.kind == .racingSuspension && penalty?.reportID == queued[0].id)
        #expect(try await rig.restrictions.restrictions(of: "T:gull").suspension != nil)
    }

    @Test func theQueueIsOrderedByItsDueTime() async throws {
        let rig = ModerationRig()
        let line = try await rig.line(by: "gull")
        try await rig.lobby.service("wren").report(message: line.id)
        rig.clock.advance(60)
        try await rig.lobby.service("tern").report(player: GamePlayerID("G:gull"))
        rig.clock.advance(60)
        _ = try await rig.raceReport()
        let queued = try await rig.moderation.queue()
        #expect(queued.map(\.kind) == [.message, .player, .race])
        #expect(queued.map(\.dueAt) == queued.map(\.dueAt).sorted())
        #expect(try await rig.moderation.queue(limit: 2).count == 2)
    }
}

extension ModerationRig {
    /// Wren reports gull's racing in a race they both sailed.
    func raceReport() async throws -> StoredReport {
        let race = UUID()
        try await archive.register(race, players: [RaceSeatHolder(playerID: "T:wren", seat: 0), RaceSeatHolder(playerID: "T:gull", seat: 1)])
        try await lobby.service("wren").report(race: RaceID(race.uuidString), seat: 1, reason: .unsportingConduct)
        return try #require(try await moderation.queue().first { $0.raceID == race.uuidString })
    }
}
