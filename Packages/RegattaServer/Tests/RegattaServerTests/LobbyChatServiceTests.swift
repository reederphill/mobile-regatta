import ChatFilter
import Foundation
import Persistence
import RaceHost
import RegattaCore
import RegattaProtocol
@testable import RegattaServerKit
import RegattaServiceClient
import RegattaServices
import Synchronization
import Testing

/// A lobby store that fails or never answers, as told.
final class FaultyLobbyStore: LobbyStore {
    struct Down: Error {}
    enum Mode: Sendable { case works, fails, hangs }

    let inner = InMemoryLobbyStore()
    private let state = Mutex<(mode: Mode, waiting: [CheckedContinuation<Void, Never>])>((.works, []))

    func set(_ mode: Mode) {
        let waiting = state.withLock { state in
            defer { state.waiting = [] }
            state.mode = mode
            return state.waiting
        }
        for continuation in waiting { continuation.resume() }
    }

    private func gate() async throws {
        switch state.withLock({ $0.mode }) {
        case .works: return
        case .fails: throw Down()
        case .hangs:
            await withCheckedContinuation { continuation in state.withLock { $0.waiting.append(continuation) } }
            throw Down()
        }
    }

    func append(_ line: StoredLobbyLine) async throws -> Int64 {
        try await gate()
        return try await inner.append(line)
    }

    func recent(since: Date, limit: Int) async throws -> [StoredLobbyLine] {
        try await gate()
        return try await inner.recent(since: since, limit: limit)
    }

    func remove(ids: [Int64], reason: String, at time: Date) async throws -> [Int64] { try await inner.remove(ids: ids, reason: reason, at: time) }
    func removeAll(of playerID: String, reason: String, at time: Date) async throws -> [Int64] {
        try await inner.removeAll(of: playerID, reason: reason, at: time)
    }
    func prune(before time: Date) async throws -> Int { try await inner.prune(before: time) }
    func deleteAll(of playerID: String) async throws -> [Int64] { try await inner.deleteAll(of: playerID) }
    func blocks() async throws -> [(blocker: String, blocked: String)] {
        try await gate()
        return try await inner.blocks()
    }
    func block(_ blocked: LobbyPlayerRef, by blocker: String, at time: Date) async throws {
        try await gate()
        try await inner.block(blocked, by: blocker, at: time)
    }
    func unblock(_ blocked: String, by blocker: String) async throws { try await inner.unblock(blocked, by: blocker) }
    func blockedPlayers(of blocker: String) async throws -> [LobbyPlayerRef] { try await inner.blockedPlayers(of: blocker) }
    func player(gamePlayerID: String) async throws -> LobbyPlayerRef? { try await inner.player(gamePlayerID: gamePlayerID) }
}

/// Moderation whose standing read fails or never answers.
final class UnreadableModeration: LobbyModeration {
    struct Down: Error {}
    private let hanging = Mutex<(hangs: Bool, waiting: [CheckedContinuation<Void, Never>])>((false, []))

    init(hangs: Bool = false) { hanging.withLock { $0.hangs = hangs } }

    func release() {
        let waiting = hanging.withLock { state in
            defer { state.waiting = [] }
            return state.waiting
        }
        for continuation in waiting { continuation.resume() }
    }

    func standing(of playerID: String) async throws -> ChatStanding {
        if hanging.withLock({ $0.hangs }) {
            await withCheckedContinuation { continuation in hanging.withLock { $0.waiting.append(continuation) } }
        }
        throw Down()
    }

    func hiddenMessages(for playerID: String) async throws -> Set<Int64> { [] }
    func report(line: ReportedLine, by playerID: String) async throws { throw LobbyError.notReportable }
    func report(player: LobbyPlayerRef, by playerID: String) async throws { throw LobbyError.notReportable }
    func report(race: RaceID, seat: Int, reason: RaceReportReason, by playerID: String) async throws { throw LobbyError.notReportable }
    func nicknameOverridden(_ playerID: String) async throws -> Bool { throw Down() }
}

/// A feed a test reads one event at a time.
final class FeedReader: @unchecked Sendable {
    // @unchecked: one test task reads it.
    private var iterator: AsyncStream<LobbyEvent>.Iterator

    init(_ stream: AsyncStream<LobbyEvent>) { iterator = stream.makeAsyncIterator() }

    func next() async -> LobbyEvent? { await iterator.next() }

    /// The events up to and including the first that satisfies `isLast`; all of them if the feed ended first.
    func read(through isLast: (LobbyEvent) -> Bool) async -> [LobbyEvent] {
        var events: [LobbyEvent] = []
        while let event = await next() {
            events.append(event)
            if isLast(event) { break }
        }
        return events
    }
}

/// The hub on a virtual clock, over a store, a rating book, moderation and a classifier the test holds.
struct LobbyRig {
    static let words = ["bitch", "asshole", "contract filtered phrase"]

    let clock: VirtualClock
    let store = FaultyLobbyStore()
    let book: InMemoryRatingBook
    let moderation = NoModeration()
    let classifier: FakeToxicityClassifier?
    let hub: LobbyHub

    init(settings: LobbySettings = LobbySettings(), classifier: FakeToxicityClassifier? = nil, classifierTimeout: Duration = .seconds(30),
         clock: VirtualClock = VirtualClock(), book: InMemoryRatingBook = InMemoryRatingBook(), moderation custom: (any LobbyModeration)? = nil,
         card: @escaping LobbyCardSource = LobbyHub.starterCard) {
        self.clock = clock
        self.book = book
        self.classifier = classifier
        hub = Self.hub(settings: settings, store: store, book: book, moderation: custom ?? moderation, classifier: classifier,
                       classifierTimeout: classifierTimeout, clock: clock, card: card)
    }

    static func hub(settings: LobbySettings = LobbySettings(), store: any LobbyStore, book: InMemoryRatingBook, moderation: any LobbyModeration,
                    classifier: FakeToxicityClassifier? = nil, classifierTimeout: Duration = .seconds(30), clock: VirtualClock,
                    card: @escaping LobbyCardSource = LobbyHub.starterCard) -> LobbyHub {
        LobbyHub(settings: settings, store: store, ratings: book, moderation: moderation, wordList: ChatWordList(entries: words),
                 classifier: classifier.map { ClassifierGate($0, timeout: classifierTimeout, now: { clock.now.timeIntervalSince1970 }) },
                 card: card, now: { clock.now })
    }

    /// A player who has completed `races` online races.
    func player(_ name: String, races: Int = 1) -> AccountPlayer {
        book.setStats(completedRaces: races, wins: 0, for: "T:\(name)")
        return AccountPlayer(teamPlayerID: "T:\(name)", gamePlayerID: "G:\(name)", alias: name)
    }

    func service(_ name: String, races: Int = 1) -> ServerLobbyService { ServerLobbyService(hub: hub, player: player(name, races: races)) }

    /// A feed of `service`, read past its first words (the state).
    func feed(_ service: ServerLobbyService) async -> (FeedReader, LobbyEvent?) {
        let reader = FeedReader(service.feed())
        return (reader, await reader.next())
    }

    /// The next free slot for every player.
    func nextSlot() { clock.advance(3) }

    static let open = LobbyState(access: .open, canPostFreeText: true, standing: .clear)
    static let racing = LobbyState(access: .closed(.racing), canPostFreeText: true, standing: .clear)
}

func isMessage(_ event: LobbyEvent) -> Bool {
    if case .message = event { true } else { false }
}

/// #152: the lobby's chat on the server: posting and its limits, the filter (the word list always, the classifier
/// when it answers), blocks, the silence window, the system lines, history and the hooks #153 and #160 use.
@Suite(.timeLimit(.minutes(2))) struct LobbyChatServiceTests {
    // MARK: Posting

    @Test func quickChatReachesAnotherFeed() async throws {
        let rig = LobbyRig()
        let wren = rig.service("wren"), newcomer = rig.service("newcomer", races: 0)
        let (feed, first) = await rig.feed(wren)
        #expect(first == .state(LobbyRig.open))
        // Quick-chat is open before a first race; free text isn't.
        #expect(try await newcomer.state() == LobbyState(access: .open, canPostFreeText: false))
        let sent = try await newcomer.post(.gg)
        #expect(sent.post?.body == .quickChat(.gg) && sent.post?.delivery == .sent)
        #expect(sent.post?.author.gamePlayerID == GamePlayerID("G:newcomer") && sent.post?.author.nickname == "newcomer")
        #expect(sent.post?.author.rating == Rating(value: 1500, isProvisional: true))
        #expect(await feed.next() == .message(sent))
        #expect(try await wren.history() == [sent])
        // Ids are the store's, as decimal strings.
        #expect(Int64(sent.id.rawValue) != nil)
        #expect(rig.store.inner.allLines.map(\.quick) == ["gg"])
    }

    @Test func rateLimitSharedByQuickChatAndText() async throws {
        let rig = LobbyRig()
        let wren = rig.service("wren"), elsewhere = rig.service("wren")
        _ = try await wren.post("fair winds")
        await #expect(throws: LobbyError.rateLimited(retryAfterSeconds: 3)) { _ = try await wren.post(.gg) }
        rig.clock.advance(1.25)
        // Across her connections, and for either kind of post.
        await #expect(throws: LobbyError.rateLimited(retryAfterSeconds: 2)) { _ = try await elsewhere.post("again") }
        rig.clock.advance(1.5)
        await #expect(throws: LobbyError.rateLimited(retryAfterSeconds: 1)) { _ = try await wren.post(.wave) }
        rig.clock.advance(0.25)
        #expect(try await elsewhere.post(.wave).post?.delivery == .sent)
    }

    @Test func refusedPostsDontUseTheSlot() async throws {
        let rig = LobbyRig()
        let wren = rig.service("wren"), newcomer = rig.service("newcomer", races: 0)
        await #expect(throws: LobbyError.tooLong(limit: 200)) { _ = try await wren.post(String(repeating: "a", count: 201)) }
        await #expect(throws: LobbyError.empty) { _ = try await wren.post("   ") }
        await #expect(throws: LobbyError.freeTextLocked) { _ = try await newcomer.post("hello") }
        #expect(try await wren.post(String(repeating: "b", count: 200)).post?.delivery == .sent)
        #expect(try await newcomer.post(.gg).post?.delivery == .sent)
        // A blocked post did use it.
        rig.nextSlot()
        #expect(try await wren.post("you bitch").post?.delivery == .notSent)
        await #expect(throws: LobbyError.rateLimited(retryAfterSeconds: 3)) { _ = try await wren.post("sorry") }
    }

    @Test func graphemeAndByteLimits() async throws {
        let rig = LobbyRig()
        let wren = rig.service("wren")
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
        await #expect(throws: LobbyError.tooLong(limit: 200)) { _ = try await wren.post(String(repeating: family, count: 40)) }
        let accents = String(repeating: "é", count: 200)
        #expect(try await wren.post(accents).post?.body == .text(accents))
    }

    @Test func controlAndBidiStripped() async throws {
        let rig = LobbyRig()
        let wren = rig.service("wren")
        #expect(try await wren.post("  fair\u{202E} winds\n\n\u{200B}all\u{2066} ").post?.body == .text("fair winds all"))
        rig.nextSlot()
        await #expect(throws: LobbyError.empty) { _ = try await wren.post("\u{202E}\u{200B}") }
    }

    @Test func contactsStripped() async throws {
        let rig = LobbyRig()
        let wren = rig.service("wren")
        let sent = try await wren.post("race me https://example.com or mail sailor@example.com or call 5551234567")
        #expect(sent.post?.body == .text("race me or mail or call"))
        #expect(rig.store.inner.allLines.map(\.body) == ["race me or mail or call"])
        // Only a link: nothing to post, and the slot isn't used... but the first post took it.
        rig.nextSlot()
        await #expect(throws: LobbyError.empty) { _ = try await wren.post("www.example.com") }
    }

    // MARK: The filter

    @Test func wordListBlocksOnlySenderSees() async throws {
        let rig = LobbyRig()
        let wren = rig.service("wren"), finn = rig.service("finn")
        let (feed, _) = await rig.feed(finn)
        let blocked = try await wren.post("what a B!TCH")
        #expect(blocked.post?.delivery == .notSent && blocked.post?.body == .text("what a B!TCH"))
        #expect(Int64(blocked.id.rawValue) == nil)
        // Never stored, never in the history, never on a feed: the next thing Finn's feed says is the next line.
        #expect(rig.store.inner.allLines.isEmpty)
        rig.nextSlot()
        let fine = try await wren.post("fair winds")
        #expect(await feed.next() == .message(fine))
        #expect(try await finn.history() == [fine])
        #expect(try await wren.history() == [fine])
        #expect(rig.hub.counters.blockedByWordList == 1 && rig.hub.counters.sent == 1)
        // A blocked id isn't a line anyone can report.
        await #expect(throws: LobbyError.unknownMessage) { _ = try await finn.report(message: blocked.id) }
    }

    @Test func classifierFlagBlocks() async throws {
        let classifier = FakeToxicityClassifier(flagging: ["toxic"])
        let rig = LobbyRig(classifier: classifier)
        let wren = rig.service("wren")
        #expect(try await wren.post("so Toxic").post?.delivery == .notSent)
        rig.nextSlot()
        #expect(try await wren.post("fair winds").post?.delivery == .sent)
        // It is handed the cleaned text and nothing else; quick-chat and word-list blocks never reach it.
        rig.nextSlot()
        _ = try await wren.post(.gg)
        rig.nextSlot()
        _ = try await wren.post("asshole")
        #expect(classifier.asked == ["so Toxic", "fair winds"])
        #expect(rig.hub.counters.blockedByClassifier == 1 && rig.hub.counters.blockedByWordList == 1)
        #expect(rig.store.inner.allLines.count == 2)
    }

    /// Owner 2026-10-11: the classifier is an extra. A classifier that fails lets the message through on the word list.
    @Test func classifierErrorLetsTheMessageThrough() async throws {
        let rig = LobbyRig(classifier: FakeToxicityClassifier(.fails))
        let wren = rig.service("wren"), finn = rig.service("finn")
        let (feed, _) = await rig.feed(finn)
        let sent = try await wren.post("fair winds")
        #expect(sent.post?.delivery == .sent)
        #expect(await feed.next() == .message(sent))
        #expect(rig.hub.counters.classifierUnavailablePasses == [.error: 1])
        // The word list still blocks.
        rig.nextSlot()
        #expect(try await wren.post("you asshole").post?.delivery == .notSent)
        #expect(rig.classifier?.asked == ["fair winds"])
    }

    /// A classifier that doesn't answer in time lets the message through; the post waits no longer than the limit.
    @Test func classifierTimeoutLetsTheMessageThrough() async throws {
        let classifier = FakeToxicityClassifier(.hangs)
        let rig = LobbyRig(classifier: classifier, classifierTimeout: .milliseconds(50))
        let wren = rig.service("wren")
        #expect(try await wren.post("fair winds").post?.delivery == .sent)
        #expect(rig.hub.counters.classifierUnavailablePasses == [.timeout: 1])
        rig.nextSlot()
        #expect(try await wren.post("b i t c h").post?.delivery == .notSent)
        #expect(classifier.asked == ["fair winds"])
        classifier.release()
    }

    /// Five failures in a row open the breaker: the classifier isn't asked, and messages still go through on the word
    /// list. After 30 s one probe is let out; its answer closes the breaker and the classifier blocks again.
    @Test func breakerOpensAfterFiveAndProbes() async throws {
        let classifier = FakeToxicityClassifier(.fails, flagging: ["toxic"])
        let rig = LobbyRig(classifier: classifier)
        let wren = rig.service("wren")
        for _ in 0..<5 {
            #expect(try await wren.post("fair winds").post?.delivery == .sent)
            rig.nextSlot()
        }
        #expect(classifier.asked.count == 5)
        // Open: not asked, passed, counted. The word list still blocks.
        #expect(try await wren.post("so toxic").post?.delivery == .sent)
        rig.nextSlot()
        #expect(try await wren.post("you bitch").post?.delivery == .notSent)
        #expect(classifier.asked.count == 5)
        #expect(rig.hub.counters.classifierUnavailablePasses == [.error: 5, .breakerOpen: 1])
        // 30 s after it opened, a probe; it fails, so the breaker stays open another 30 s.
        rig.clock.advance(30)
        #expect(try await wren.post("fair winds").post?.delivery == .sent)
        #expect(classifier.asked.count == 6)
        rig.nextSlot()
        #expect(try await wren.post("fair winds").post?.delivery == .sent)
        #expect(classifier.asked.count == 6)
        // The service is back: the next probe closes the breaker, and a flagged message is blocked again.
        classifier.set(.answers)
        rig.clock.advance(30)
        #expect(try await wren.post("fair winds").post?.delivery == .sent)
        rig.nextSlot()
        #expect(try await wren.post("so toxic").post?.delivery == .notSent)
        #expect(classifier.asked.count == 8)
    }

    /// A message the store can't record isn't sent, and nobody else sees it: a failing store, then one that hangs.
    @Test func storeFailureIsNotSent() async throws {
        var settings = LobbySettings()
        settings.storeDeadline = .milliseconds(50)
        let rig = LobbyRig(settings: settings)
        let wren = rig.service("wren"), finn = rig.service("finn")
        let (feed, _) = await rig.feed(finn)
        _ = try await wren.state()
        rig.store.set(.fails)
        #expect(try await wren.post("fair winds").post?.delivery == .notSent)
        rig.nextSlot()
        rig.store.set(.hangs)
        #expect(try await wren.post(.gg).post?.delivery == .notSent)
        rig.nextSlot()
        rig.store.set(.works)
        let sent = try await wren.post("back again")
        #expect(sent.post?.delivery == .sent)
        #expect(await feed.next() == .message(sent))
        #expect(rig.hub.counters.storeFailures == 2 && rig.hub.counters.sent == 1)
    }

    @Test func threeBlocksStartCooldown() async throws {
        let rig = LobbyRig()
        let wren = rig.service("wren")
        for _ in 0..<3 {
            #expect(try await wren.post("bitch").post?.delivery == .notSent)
            rig.nextSlot()
        }
        // Three in a minute: 30 s from the third, for any post.
        await #expect(throws: LobbyError.rateLimited(retryAfterSeconds: 27)) { _ = try await wren.post("fair winds") }
        await #expect(throws: LobbyError.rateLimited(retryAfterSeconds: 27)) { _ = try await wren.post(.gg) }
        rig.clock.advance(27)
        #expect(try await wren.post("fair winds").post?.delivery == .sent)
        // Again inside ten minutes: two minutes.
        for _ in 0..<3 {
            rig.nextSlot()
            #expect(try await wren.post("asshole").post?.delivery == .notSent)
        }
        await #expect(throws: LobbyError.rateLimited(retryAfterSeconds: 120)) { _ = try await wren.post(.gg) }
        // Blocked posts a minute apart never add up.
        let finn = rig.service("finn")
        for _ in 0..<4 {
            #expect(try await finn.post("bitch").post?.delivery == .notSent)
            rig.clock.advance(31)
        }
        #expect(try await finn.post(.gg).post?.delivery == .sent)
    }

    @Test func providerFailureDoesNotCountTowardCooldown() async throws {
        let rig = LobbyRig(classifier: FakeToxicityClassifier(.fails))
        let wren = rig.service("wren")
        _ = try await wren.state()
        rig.store.set(.fails)
        for _ in 0..<4 {
            #expect(try await wren.post("fair winds").post?.delivery == .notSent)
            rig.nextSlot()
        }
        rig.store.set(.works)
        #expect(try await wren.post("fair winds").post?.delivery == .sent)
    }

    @Test func roomCeiling() async throws {
        let rig = LobbyRig()
        let finn = rig.service("finn")
        let (feed, _) = await rig.feed(finn)
        // A burst of 12 at one instant; the 13th waits a second.
        for index in 0..<12 { #expect(try await rig.service("p\(index)").post(.gg).post?.delivery == .sent) }
        await #expect(throws: LobbyError.rateLimited(retryAfterSeconds: 1)) { _ = try await rig.service("p12").post(.gg) }
        // The room's refusal didn't use her slot, and system lines are exempt.
        rig.hub.gun(race: UUID(), venue: "Bay", boats: 10, humans: 3)
        await rig.hub.settled()
        rig.clock.advance(1)
        for index in 12..<18 { #expect(try await rig.service("p\(index)").post(.gg).post?.delivery == .sent) }
        await #expect(throws: LobbyError.rateLimited(retryAfterSeconds: 1)) { _ = try await rig.service("p18").post(.gg) }
        var read: [LobbyEvent] = []
        for _ in 0..<19 {
            if let event = await feed.next() { read.append(event) }
        }
        #expect(read.count == 19 && read[12] == .message(LobbyMessage(id: MessageID("13"), kind: .system(.gun(venue: "Bay", boats: 10, humans: 3)))))
    }

    // MARK: Who may post

    /// Free text unlocks with the first completed online race (the close counts it by
    /// `RaceLifecycleSettings.earnedProgressResultCodes`: `RatingCloseTests`), and her open feed is told at the close.
    @Test func freeTextUnlock() async throws {
        let rig = LobbyRig()
        let wren = rig.service("wren", races: 0)
        let (feed, first) = await rig.feed(wren)
        #expect(first == .state(LobbyState(access: .open, canPostFreeText: false)))
        await #expect(throws: LobbyError.freeTextLocked) { _ = try await wren.post("hello") }
        // Her race closes without counting (a retirement): still locked, and the feed says so.
        let race = UUID()
        rig.hub.fleetLocked(race: race, humans: ["T:wren"])
        #expect(await feed.next() == .state(LobbyState(access: .closed(.racing), canPostFreeText: false)))
        rig.hub.raceEnded(race: race, players: ["T:wren"])
        #expect(await feed.next() == .state(LobbyState(access: .open, canPostFreeText: false)))
        // The next one counts.
        rig.book.setStats(completedRaces: 1, wins: 0, for: "T:wren")
        rig.hub.raceEnded(race: UUID(), players: ["T:wren"])
        #expect(await feed.next() == .state(LobbyRig.open))
        #expect(try await wren.post("hello").post?.delivery == .sent)
    }

    @Test func mutedStandingRefusesAndNotifies() async throws {
        let rig = LobbyRig()
        let wren = rig.service("wren"), finn = rig.service("finn")
        let (feed, _) = await rig.feed(wren)
        let line = try await finn.post("fair winds")
        #expect(await feed.next() == .message(line))
        // #153 sets a mute and refreshes her: the feed tells her (no shadow mutes).
        let until = Int64(rig.clock.now.timeIntervalSince1970) + 86_400
        rig.moderation.set(.muted(until: until, isAutomatic: true), for: "T:wren")
        await rig.hub.refresh(players: ["T:wren"])
        let muted = LobbyState(access: .open, canPostFreeText: true, standing: .muted(until: until, isAutomatic: true))
        #expect(await feed.next() == .state(muted))
        #expect(try await wren.state() == muted)
        await #expect(throws: LobbyError.muted(until: until)) { _ = try await wren.post("hello") }
        await #expect(throws: LobbyError.muted(until: until)) { _ = try await wren.post(.gg) }
        // Reading stays open to her.
        #expect(try await wren.history() == [line])
        rig.moderation.set(.banned, for: "T:wren")
        await #expect(throws: LobbyError.banned) { _ = try await wren.post(.gg) }
        // And its end is pushed too.
        rig.moderation.set(.clear, for: "T:wren")
        await rig.hub.refresh(players: ["T:wren"])
        _ = await feed.read { $0 == .state(LobbyRig.open) }
        #expect(try await wren.post(.gg).post?.delivery == .sent)
    }

    /// A standing that can't be read, or isn't read in time, fails closed: not sent, never a post by a muted player.
    @Test func readFailureOfStandingFailsClosed() async throws {
        for hangs in [false, true] {
            var settings = LobbySettings()
            settings.standingDeadline = .milliseconds(50)
            let moderation = UnreadableModeration(hangs: hangs)
            let rig = LobbyRig(settings: settings, moderation: moderation)
            let wren = rig.service("wren")
            #expect(try await wren.post("fair winds").post?.delivery == .notSent)
            #expect(try await wren.post(.gg).post?.delivery == .notSent)
            #expect(rig.store.inner.allLines.isEmpty)
            // Nothing she can't post is stored against her slot either: no rate limit was hit above.
            await #expect(throws: (any Error).self) { _ = try await wren.state() }
            moderation.release()
        }
    }

    // MARK: Blocks

    @Test func twoBlockedPlayersNeverSeeEachOther() async throws {
        let rig = LobbyRig()
        let wren = rig.service("wren"), finn = rig.service("finn"), cleo = rig.service("cleo")
        let old = try await finn.post("ahoy")
        let (wrenFeed, _) = await rig.feed(wren)
        let (finnFeed, _) = await rig.feed(finn)
        let (cleoFeed, _) = await rig.feed(cleo)
        try await wren.block(GamePlayerID("G:finn"))
        // His line she could see leaves her feed; blocking again changes nothing.
        #expect(await wrenFeed.next() == .removed(old.id))
        try await wren.block(GamePlayerID("G:finn"))
        #expect(try await wren.blockedPlayers() == [BlockedPlayer(gamePlayerID: GamePlayerID("G:finn"), nickname: "finn")])
        #expect(try await finn.blockedPlayers().isEmpty)
        rig.nextSlot()
        let his = try await finn.post("anyone racing?")
        let hers = try await wren.post("not with you")
        rig.nextSlot()
        let third = try await cleo.post("me")
        // Neither sees the other's line, on the feed or in the history; a third player sees both.
        #expect(await wrenFeed.read(through: isMessage) == [.message(hers)])
        #expect(await wrenFeed.next() == .message(third))
        #expect(await finnFeed.read(through: { $0 == .message(third) }) == [.message(his), .message(third)])
        #expect(await cleoFeed.read(through: { $0 == .message(third) }) == [.message(his), .message(hers), .message(third)])
        #expect(try await wren.history() == [hers, third])
        #expect(try await finn.history() == [old, his, third])
        #expect(try await cleo.history() == [old, his, hers, third])
        // Unblocking brings his lines back to her history.
        try await wren.unblock(GamePlayerID("G:finn"))
        #expect(try await wren.blockedPlayers().isEmpty)
        #expect(try await wren.history() == [old, his, hers, third])
        // Yourself, and nobody.
        await #expect(throws: LobbyError.cannotBlockSelf) { _ = try await wren.block(GamePlayerID("G:wren")) }
        try await wren.block(GamePlayerID("G:nobody"))
        #expect(try await rig.store.inner.blocks().isEmpty)
    }

    @Test func theBlockListIsCapped() async throws {
        var settings = LobbySettings()
        settings.maxBlocksPerPlayer = 2
        let rig = LobbyRig(settings: settings)
        let wren = rig.service("wren")
        for name in ["a", "b", "c"] { _ = rig.service(name) }
        try await wren.block(GamePlayerID("G:a"))
        try await wren.block(GamePlayerID("G:b"))
        await #expect(throws: LobbyError.rateLimited(retryAfterSeconds: 3600)) { _ = try await wren.block(GamePlayerID("G:c")) }
        try await wren.unblock(GamePlayerID("G:a"))
        try await wren.block(GamePlayerID("G:c"))
    }

    /// A restart keeps the blocks and rebuilds the last hour from the store; the limits and feeds start afresh.
    @Test func blockSurvivesRestart() async throws {
        let rig = LobbyRig()
        let wren = rig.service("wren"), finn = rig.service("finn")
        let before = try await finn.post("ahoy")
        try await wren.block(GamePlayerID("G:finn"))
        rig.hub.finish()

        let restarted = LobbyRig.hub(store: rig.store, book: rig.book, moderation: rig.moderation, clock: rig.clock)
        let wrenAgain = ServerLobbyService(hub: restarted, player: wren.player), finnAgain = ServerLobbyService(hub: restarted, player: finn.player)
        let feed = FeedReader(wrenAgain.feed())
        #expect(await feed.next() == .state(LobbyRig.open))
        // The limiter is gone with the old process: he may post at once. She still doesn't see him.
        let his = try await finnAgain.post("still here")
        let hers = try await wrenAgain.post(.wave)
        #expect(await feed.next() == .message(hers))
        #expect(try await wrenAgain.history() == [hers])
        #expect(try await finnAgain.history() == [before, his])
        #expect(try await wrenAgain.blockedPlayers().map(\.gamePlayerID) == [GamePlayerID("G:finn")])
    }

    // MARK: Feeds and history

    @Test func historyFiftyWithinHour() async throws {
        let rig = LobbyRig()
        let wren = rig.service("wren")
        for index in 0..<60 {
            rig.hub.gun(race: UUID(), venue: "Bay \(index)", boats: 10, humans: 2)
            rig.clock.advance(1)
        }
        await rig.hub.settled()
        let history = try await wren.history()
        // The newest fifty, oldest first, system lines among them.
        #expect(history.count == 50)
        #expect(history.first?.kind == .system(.gun(venue: "Bay 10", boats: 10, humans: 2)))
        #expect(history.last?.kind == .system(.gun(venue: "Bay 59", boats: 10, humans: 2)))
        // An hour on, only what was said within the hour.
        rig.clock.advance(3_600 - 30)
        #expect(try await wren.history().count == 30)
        rig.clock.advance(60)
        let sent = try await wren.post("anyone here?")
        #expect(try await wren.history() == [sent])
    }

    @Test func historyRebuiltAfterRestart() async throws {
        let rig = LobbyRig()
        let wren = rig.service("wren")
        let first = try await wren.post("fair winds")
        rig.hub.gun(race: UUID(), venue: "Bay", boats: 10, humans: 2)
        rig.hub.winner(race: UUID(), venue: "Bay", nickname: "wren", playerID: "T:wren")
        await rig.hub.settled()
        let shown = try await wren.history()
        #expect(shown.count == 3 && shown.first == first)
        // An older line the store still keeps (30 days) isn't history.
        rig.clock.advance(3_000)
        rig.hub.gun(race: UUID(), venue: "Late", boats: 10, humans: 1)
        await rig.hub.settled()
        rig.clock.advance(700)
        let restarted = LobbyRig.hub(store: rig.store, book: rig.book, moderation: rig.moderation, clock: rig.clock)
        let again = ServerLobbyService(hub: restarted, player: wren.player)
        #expect(try await again.history().map(\.kind) == [.system(.gun(venue: "Late", boats: 10, humans: 1))])
        #expect(rig.store.inner.allLines.count == 4)
    }

    /// A reader 64 events behind is cut, with no gap in what it did get; everyone else reads on.
    @Test func slowReaderCutOthersUnaffected() async throws {
        var settings = LobbySettings()
        settings.feedBuffer = 4
        let rig = LobbyRig(settings: settings)
        let slow = rig.service("slow"), quick = rig.service("quick")
        let (slowFeed, _) = await rig.feed(slow)
        let (quickFeed, _) = await rig.feed(quick)
        var read: [LobbyEvent] = []
        for index in 0..<6 {
            rig.hub.gun(race: UUID(), venue: "Bay \(index)", boats: 10, humans: 2)
            await rig.hub.settled()
            if let event = await quickFeed.next() { read.append(event) }
        }
        #expect(read.count == 6)
        #expect(rig.hub.counters.slowReaderCuts == 1 && rig.hub.feedCount == 1)
        // The slow feed holds the first four, in order, then ends: the client reopens and reads the history.
        let got = await slowFeed.read { _ in false }
        #expect(got == Array(read.prefix(4)))
        let (reopened, first) = await rig.feed(slow)
        #expect(first == .state(LobbyRig.open))
        #expect(try await slow.history().count == 6)
        withExtendedLifetime((reopened, quickFeed)) {}
    }

    @Test func thirdFeedReplacesOldest() async throws {
        let rig = LobbyRig()
        let wren = rig.service("wren"), elsewhere = rig.service("wren")
        let (first, _) = await rig.feed(wren)
        let (second, _) = await rig.feed(elsewhere)
        let (third, _) = await rig.feed(wren)
        #expect(await first.next() == nil)
        #expect(rig.hub.feedCount == 2)
        let line = try await rig.service("finn").post(.gg)
        #expect(await second.next() == .message(line))
        #expect(await third.next() == .message(line))
    }

    @Test func connectionEndRemovesWatchers() async throws {
        let rig = LobbyRig()
        let wren = rig.service("wren"), finn = rig.service("finn")
        let (feed, _) = await rig.feed(wren)
        // A stream dropped unread is gone at once.
        _ = finn.feed()
        #expect(rig.hub.feedCount == 1)
        let held = [finn.feed(), finn.feed()]
        #expect(rig.hub.feedCount == 3)
        await finn.connectionEnded()
        #expect(rig.hub.feedCount == 1)
        await wren.connectionEnded()
        #expect(await feed.next() == nil)
        #expect(rig.hub.feedCount == 0)
        withExtendedLifetime(held) {}
    }

    @Test func hubShutdownFinishesEveryFeed() async throws {
        let rig = LobbyRig()
        let wren = rig.service("wren")
        let (feed, _) = await rig.feed(wren)
        rig.hub.finish()
        #expect(await feed.next() == nil)
        // A feed opened after it ends at once, and nothing more is sent.
        #expect(await FeedReader(wren.feed()).next() == nil)
        #expect(try await wren.post(.gg).post?.delivery == .notSent)
    }

    // MARK: The silence window

    /// From her fleet's lock to her own finish: no reading, no posting, and her feed carries the state only. After it
    /// she sees what was said meanwhile (owner 2026-10-11: the last hour's lines).
    // MARK: Boat cards (#142)

    @Test func theBoatCardShowsHerCurrentBoat() async throws {
        let stored = Livery(design: DesignID("stripe"), colours: [SwatchID("red"), SwatchID("white")], sailNumber: 207)
        let rig = LobbyRig(card: { player in
            if player.teamPlayerID == "T:gull" { return stored }
            return try await StarterLiveries().livery(of: player)
        })
        let gull = rig.service("gull"), wren = rig.service("wren", races: 3)
        // Her line keeps its chip; the card reads her boat now, and her rating now.
        rig.book.setStats(completedRaces: 3, wins: 0, for: "T:gull")
        let card = try await wren.boatCard(GamePlayerID("G:gull"))
        #expect(card == BoatCard(gamePlayerID: GamePlayerID("G:gull"), nickname: "gull", rating: Rating(value: 1500, isProvisional: true),
                                 livery: stored))
        // One who stored none sails her starter.
        let starter = try await StarterLiveries().livery(of: rig.player("wren", races: 3))
        #expect(try await gull.boatCard(GamePlayerID("G:wren")).livery == starter)
    }

    @Test func noBoatCardForHerselfAStrangerOrABlockedPair() async throws {
        let rig = LobbyRig()
        let wren = rig.service("wren"), gull = rig.service("gull"), tern = rig.service("tern")
        await #expect(throws: LobbyError.unknownPlayer) { try await wren.boatCard(GamePlayerID("G:wren")) }
        await #expect(throws: LobbyError.unknownPlayer) { try await wren.boatCard(GamePlayerID("G:nobody")) }
        try await wren.block(GamePlayerID("G:gull"))
        // Both ways, and only for the pair.
        await #expect(throws: LobbyError.unknownPlayer) { try await wren.boatCard(GamePlayerID("G:gull")) }
        await #expect(throws: LobbyError.unknownPlayer) { try await gull.boatCard(GamePlayerID("G:wren")) }
        #expect(try await tern.boatCard(GamePlayerID("G:gull")).nickname == "gull")
        try await wren.unblock(GamePlayerID("G:gull"))
        #expect(try await gull.boatCard(GamePlayerID("G:wren")).nickname == "wren")
    }

    @Test func noBoatCardWhileSilencedOrClosed() async throws {
        let rig = LobbyRig()
        let wren = rig.service("wren")
        _ = rig.service("gull")
        rig.hub.fleetLocked(race: UUID(), humans: ["T:wren"])
        await #expect(throws: LobbyError.closed(.racing)) { try await wren.boatCard(GamePlayerID("G:gull")) }
        for closure in [LobbyClosure.notSignedIn, .termsNotAccepted, .communicationRestricted] {
            await #expect(throws: LobbyError.closed(closure)) { try await ClosedLobbyService(closure: closure).boatCard(GamePlayerID("G:gull")) }
        }
    }

    @Test func silenceFromLockToFinish() async throws {
        let rig = LobbyRig()
        let wren = rig.service("wren"), finn = rig.service("finn")
        let (feed, _) = await rig.feed(wren)
        let race = UUID()
        rig.hub.fleetLocked(race: race, humans: ["T:wren", "T:other"])
        #expect(await feed.next() == .state(LobbyRig.racing))
        #expect(try await wren.state() == LobbyRig.racing)
        await #expect(throws: LobbyError.closed(.racing)) { _ = try await wren.history() }
        await #expect(throws: LobbyError.closed(.racing)) { _ = try await wren.post("hello") }
        await #expect(throws: LobbyError.closed(.racing)) { _ = try await wren.post(.gg) }
        // A feed she opens while racing says so, and nothing else.
        let (second, first) = await rig.feed(wren)
        #expect(first == .state(LobbyRig.racing))
        let meanwhile = try await finn.post("good luck out there")
        rig.hub.gun(race: race, venue: "Bay", boats: 10, humans: 2)
        await rig.hub.settled()
        // Another race's finish, or someone else's, isn't hers.
        rig.hub.finished(race: UUID(), player: "T:wren")
        rig.hub.finished(race: race, player: "T:other")
        #expect(rig.hub.isSilenced("T:wren"))
        rig.hub.finished(race: race, player: "T:wren")
        // The first thing either feed says after the lock's state is that the lobby is open again.
        #expect(await feed.next() == .state(LobbyRig.open))
        #expect(await second.next() == .state(LobbyRig.open))
        #expect(try await wren.history().first == meanwhile)
        #expect(try await wren.history().count == 2)
        rig.nextSlot()
        let after = try await finn.post("well sailed")
        #expect(await feed.next() == .message(after))
        // The close later changes nothing for her but says the state again.
        rig.hub.raceEnded(race: race, players: ["T:wren", "T:other"])
        #expect(await feed.next() == .state(LobbyRig.open))
    }

    @Test func leaveReopens() async throws {
        let rig = LobbyRig()
        let wren = rig.service("wren")
        let (feed, _) = await rig.feed(wren)
        let race = UUID()
        rig.hub.fleetLocked(race: race, humans: ["T:wren"])
        #expect(await feed.next() == .state(LobbyRig.racing))
        rig.hub.left(race: race, player: "T:wren")
        #expect(await feed.next() == .state(LobbyRig.open))
        #expect(try await wren.post(.gg).post?.delivery == .sent)
        // She queues again and locks into the next race; the one she left closing doesn't open the lobby to her.
        _ = await feed.next()
        let next = UUID()
        rig.hub.fleetLocked(race: next, humans: ["T:wren"])
        #expect(await feed.next() == .state(LobbyRig.racing))
        rig.hub.raceEnded(race: race, players: ["T:wren"])
        rig.hub.left(race: race, player: "T:wren")
        #expect(rig.hub.isSilenced("T:wren"))
        rig.hub.raceEnded(race: next, players: ["T:wren"])
        #expect(await feed.next() == .state(LobbyRig.open))
    }

    /// A fleet whose race never starts: the queue tells the lobby the race ended (`QueueMatchmakerTests`), and the
    /// lobby opens again.
    @Test func launchFailureReleasesSilence() async throws {
        let rig = LobbyRig()
        let wren = rig.service("wren")
        let (feed, _) = await rig.feed(wren)
        let race = UUID()
        rig.hub.fleetLocked(race: race, humans: ["T:wren", "T:finn"])
        #expect(await feed.next() == .state(LobbyRig.racing))
        rig.hub.raceEnded(race: race, players: ["T:wren", "T:finn"])
        #expect(await feed.next() == .state(LobbyRig.open))
        #expect(!rig.hub.isSilenced("T:finn"))
    }

    @Test func silenceLeakGuard() async throws {
        let rig = LobbyRig()
        let wren = rig.service("wren")
        let (feed, _) = await rig.feed(wren)
        rig.hub.fleetLocked(race: UUID(), humans: ["T:wren"])
        #expect(await feed.next() == .state(LobbyRig.racing))
        rig.clock.advance(1_799)
        #expect(try await wren.state() == LobbyRig.racing)
        // Half an hour after the lock, whatever became of the race.
        rig.clock.advance(1)
        #expect(try await wren.state() == LobbyRig.open)
        #expect(await feed.next() == .state(LobbyRig.open))
        #expect(try await wren.post(.gg).post?.delivery == .sent)
    }

    // MARK: System lines

    /// The gun's line counts the humans at the gun by the rating rule: of two human seats, the one who never joined
    /// wasn't at it. The race session fires it once, from its driver.
    @Test func gunLineHumansByRatingRule() async throws {
        let rig = LobbyRig()
        let wren = rig.service("wren")
        let (feed, _) = await rig.feed(wren)
        let hub = rig.hub, id = UUID()
        let setup = try RaceSetup(raceSeed: RaceSeed(152), seats: [.human, .human, .bot, .bot], laps: 1, startSequenceTicks: 30)
        let clock = ManualHostClock()
        let fired = Kept<Int>()
        let session = RaceSession(id: id, setup: setup, windSeed: WindSeed(152), closeAtTick: 3, clock: clock, onGun: { humans in
            fired.append(humans)
            hub.gun(race: id, venue: "Test Bay", boats: setup.fleetSize, humans: humans)
        })
        // Seat 0 joins and holds her helm through the start sequence; seat 1 never joins.
        try await session.join(seat: 0, transport: KeptTransport())
        var seq: UInt32 = 0
        var tick = await session.host.tick
        while tick < -1 {
            seq += 1
            await session.host.receive(try Frame(seq: seq, tick: tick + 1, message: .inputHeld(BoatInput(rudder: 0 as Int8))).encoded(), from: 0)
            tick = min(tick + 10, -1)
            clock.set(await session.host.time(ofTick: tick))
            await session.host.advance()
        }
        await session.host.receive(try Frame(seq: seq + 1, tick: 0, message: .inputHeld(BoatInput(rudder: 0 as Int8))).encoded(), from: 0)
        #expect(fired.all.isEmpty)
        // The driver runs every tick due: past the gun, to the tick the race is closed at.
        clock.set(await session.host.time(ofTick: 3))
        _ = await session.run()
        #expect(fired.all == [1])
        #expect(await feed.next() == .message(LobbyMessage(id: MessageID("1"), kind: .system(.gun(venue: "Test Bay", boats: 4, humans: 1)))))
        // Nobody at the gun: no line.
        rig.hub.gun(race: UUID(), venue: "Empty Bay", boats: 10, humans: 0)
        await rig.hub.settled()
        #expect(rig.store.inner.allLines.count == 1)
    }

    /// System lines skip the filter and the limits, are stored, and can't be reported; nor can her own line, a line
    /// that isn't there, or (until #153) anyone's.
    @Test func systemLinesAreStoredAndUnreportable() async throws {
        let rig = LobbyRig()
        let wren = rig.service("wren"), finn = rig.service("finn")
        rig.hub.winner(race: UUID(), venue: "Asshole Bay", nickname: "finn", playerID: "T:finn")
        await rig.hub.settled()
        let mine = try await wren.post("fair winds"), his = try await finn.post("ahoy")
        let history = try await wren.history()
        #expect(history.first?.kind == .system(.winner(venue: "Asshole Bay", nickname: "finn")))
        #expect(rig.store.inner.allLines.first?.subjectID == "T:finn" && rig.store.inner.allLines.first?.authorID == nil)
        let system = try #require(history.first)
        await #expect(throws: LobbyError.notReportable) { _ = try await wren.report(message: system.id) }
        await #expect(throws: LobbyError.notReportable) { _ = try await wren.report(message: mine.id) }
        await #expect(throws: LobbyError.unknownMessage) { _ = try await wren.report(message: MessageID("no-such-line")) }
        await #expect(throws: LobbyError.unknownMessage) { _ = try await wren.report(message: MessageID("9999")) }
        await #expect(throws: LobbyError.notReportable) { _ = try await wren.report(message: his.id) }
        await #expect(throws: LobbyError.notReportable) { _ = try await wren.report(player: GamePlayerID("G:finn")) }
        await #expect(throws: LobbyError.notReportable) { _ = try await wren.report(race: RaceID("r"), seat: 1, reason: .unsportingConduct) }
    }

    // MARK: Moderation's and deletion's hooks

    /// #153: an upheld report takes lines down for everyone. No stub is left: the line is gone from the feed and the
    /// history, and kept, marked, in the store.
    @Test func removedLinesLeaveEveryFeedAndTheHistory() async throws {
        let rig = LobbyRig()
        let wren = rig.service("wren"), finn = rig.service("finn")
        let (feed, _) = await rig.feed(wren)
        let first = try await finn.post("one")
        rig.nextSlot()
        let second = try await finn.post("two")
        let other = try await wren.post("three")
        _ = await feed.read { $0 == .message(other) }
        try await rig.hub.remove(ids: [try #require(Int64(first.id.rawValue))], reason: "report")
        #expect(await feed.next() == .removed(first.id))
        #expect(try await wren.history() == [second, other])
        try await rig.hub.remove(allOf: "T:finn", reason: "ban")
        #expect(await feed.next() == .removed(second.id))
        #expect(try await finn.history() == [other])
        #expect(rig.store.inner.allLines.count == 3)
        #expect(try await rig.store.inner.recent(since: .distantPast, limit: 10).map(\.body) == ["three"])
    }

    /// #160: deleting a player takes her lines and the winner's lines naming her off every feed, ends her feeds and
    /// drops the blocks she made; blocks against her stay.
    @Test func deleteAllEmitsRemoved() async throws {
        let rig = LobbyRig()
        let wren = rig.service("wren"), finn = rig.service("finn")
        let (finnFeed, _) = await rig.feed(finn)
        let (wrenFeed, _) = await rig.feed(wren)
        let hers = try await wren.post("fair winds")
        rig.hub.winner(race: UUID(), venue: "Bay", nickname: "wren", playerID: "T:wren")
        await rig.hub.settled()
        let his = try await finn.post("ahoy")
        try await wren.block(GamePlayerID("G:cleo-unknown"))
        _ = rig.service("cleo")
        try await wren.block(GamePlayerID("G:cleo"))
        let before = await finnFeed.read { $0 == .message(his) }
        #expect(before.count == 3)
        try await finn.block(GamePlayerID("G:wren"))
        #expect(await finnFeed.next() == .removed(hers.id))

        try await rig.hub.deleteAll(of: "T:wren")
        let removed = [await finnFeed.next(), await finnFeed.next()]
        #expect(removed.contains(.removed(hers.id)) && removed.contains(.removed(MessageID("2"))))
        _ = await wrenFeed.read { _ in false }
        #expect(rig.hub.feedCount == 1)
        withExtendedLifetime(finnFeed) {}
        #expect(try await finn.history() == [his])
        #expect(rig.store.inner.allLines.map(\.body) == ["ahoy"])
        #expect(try await rig.store.inner.blocks().map { "\($0.blocker)>\($0.blocked)" } == ["T:finn>T:wren"])
    }

    @Test func pruneDropsOldLines() async throws {
        let rig = LobbyRig()
        let wren = rig.service("wren")
        _ = try await wren.post("old")
        rig.clock.advance(1_000)
        let kept = try await wren.post("new")
        #expect(try await rig.hub.prune(before: rig.clock.now.addingTimeInterval(-500)) == 1)
        #expect(try await wren.history() == [kept])
        #expect(rig.store.inner.allLines.count == 1)
    }
}
