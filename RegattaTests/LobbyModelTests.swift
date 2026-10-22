import Foundation
import RegattaCore
import RegattaServices
import Synchronization
import Testing
@testable import Regatta

/// A lobby that counts the calls Home makes on it (#142): no read or post may reach a lobby she can't see.
final class CountingLobby: LobbyService {
    struct Counts: Equatable {
        var history = 0
        var feed = 0
        var posts = 0
    }

    let base: any LobbyService
    private let counted = Mutex(Counts())

    init(_ base: any LobbyService) { self.base = base }

    var counts: Counts { counted.withLock { $0 } }
    private func count(_ change: (inout Counts) -> Void) { counted.withLock { change(&$0) } }

    func state() async throws -> LobbyState { try await base.state() }
    func history() async throws -> [LobbyMessage] {
        count { $0.history += 1 }
        return try await base.history()
    }
    func feed() -> AsyncStream<LobbyEvent> {
        count { $0.feed += 1 }
        return base.feed()
    }
    func post(_ text: String) async throws -> LobbyMessage {
        count { $0.posts += 1 }
        return try await base.post(text)
    }
    func post(_ quickChat: QuickChat) async throws -> LobbyMessage {
        count { $0.posts += 1 }
        return try await base.post(quickChat)
    }
    func block(_ player: GamePlayerID) async throws { try await base.block(player) }
    func unblock(_ player: GamePlayerID) async throws { try await base.unblock(player) }
    func blockedPlayers() async throws -> [BlockedPlayer] { try await base.blockedPlayers() }
    func report(message: MessageID) async throws { try await base.report(message: message) }
    func report(player: GamePlayerID) async throws { try await base.report(player: player) }
    func report(race: RaceID, seat: Int, reason: RaceReportReason) async throws { try await base.report(race: race, seat: seat, reason: reason) }
    func boatCard(_ player: GamePlayerID) async throws -> BoatCard { try await base.boatCard(player) }
}

/// The reopen delays the lobby asked for: each goes on at once while `allowed` lasts, else waits for `allow`. The
/// minute tick never goes on.
final class LobbySleeps: Sendable {
    private struct State {
        var asked: [Duration] = []
        var allowed = 0
        var waiting: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    var asked: [Duration] { state.withLock { $0.asked } }

    func allow(_ more: Int) {
        let resumed = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            let now = Array(state.waiting.prefix(more))
            state.waiting.removeFirst(now.count)
            state.allowed += more - now.count
            return now
        }
        for continuation in resumed { continuation.resume() }
    }

    func sleep(_ duration: Duration) async {
        guard duration < .seconds(60) else {
            try? await Task.sleep(for: .seconds(3600))
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let goesOn = state.withLock { state -> Bool in
                state.asked.append(duration)
                guard state.allowed > 0 else {
                    state.waiting.append(continuation)
                    return false
                }
                state.allowed -= 1
                return true
            }
            if goesOn { continuation.resume() }
        }
    }
}

/// The lobby on Home (#142): when it reads and when it never does, its lines from the history and the feed, and
/// what posting, blocking and reporting do to them.
@MainActor @Suite struct LobbyModelTests {
    @MainActor struct Rig {
        let status: OnlineStatus
        let lobby: CountingLobby
        let sleeps: LobbySleeps

        var model: LobbyModel { status.lobby }
        var scripted: ScriptedLobbyService { lobby.base as! ScriptedLobbyService }
    }

    static func rig(_ scenario: FakeServiceScenario, hidesChat: Bool = false, lobby: (any LobbyService)? = nil,
                    sleeps: LobbySleeps = LobbySleeps()) async -> Rig {
        var services = ServiceSet.fake(scenario)
        let counting = CountingLobby(lobby ?? services.lobby)
        services.lobby = counting
        let status = OnlineStatus(services: services, isInitiallyOnline: scenario != .offline,
                                  lobbySleep: { await sleeps.sleep($0) })
        status.lobby.hidesChat = hidesChat
        await status.refreshAccount()
        await settle()
        return Rig(status: status, lobby: counting, sleeps: sleeps)
    }

    static func settle() async {
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(10))
            await Task.yield()
        }
    }

    /// Hidden, underage, communication-restricted, signed out, terms due or offline: no history, feed or post, ever.
    @Test func noLobbyCallWhileHiddenOrRestricted() async {
        for (scenario, hides) in [(FakeServiceScenario.joinable, true), (.underage, false), (.communicationRestricted, false),
                                  (.signedOut, false), (.termsBump, false), (.offline, false)] {
            let rig = await Self.rig(scenario, hidesChat: hides)
            await rig.model.post(.gg)
            await rig.model.send()
            #expect(rig.lobby.counts == CountingLobby.Counts(), "\(scenario), hidden \(hides)")
            #expect(rig.model.phase == .closed, "\(scenario)")
        }
    }

    /// A multiplayer-restricted player still chats (#34): the lobby's gate is the chat rules.
    @Test func aMultiplayerRestrictedPlayerChats() async {
        let rig = await Self.rig(.multiplayerRestricted)
        #expect(rig.model.phase == .open)
        #expect(rig.lobby.counts.history == 1)
    }

    /// Opening reads the history once, then holds the feed; a feed that ends reopens with one more read, after a
    /// growing wait; nothing polls.
    @Test func opensWithOneReadAndReopensAfterADrop() async {
        let sleeps = LobbySleeps()
        let rig = await Self.rig(.joinable, sleeps: sleeps)
        #expect(rig.model.phase == .open)
        #expect(rig.model.feed.lines.count == 7)
        #expect(rig.lobby.counts == CountingLobby.Counts(history: 1, feed: 1, posts: 0))
        // The scripted feed ends at once: the reopen waits.
        #expect(sleeps.asked == [.seconds(1)])
        sleeps.allow(2)
        await Self.settle()
        #expect(rig.lobby.counts.history == 3 && rig.lobby.counts.feed == 3, "one read each reopen")
        #expect(sleeps.asked == [.seconds(1), .seconds(2), .seconds(4)], "the waits grow")
        #expect(rig.model.feed.lines.count == 7, "the same lines, once each")
    }

    /// Signing in and agreeing opens the lobby (`signed-out`'s fakes follow the sign-in, T6).
    @Test func signingInAndAgreeingOpensIt() async {
        let rig = await Self.rig(.signedOut)
        #expect(rig.model.phase == .closed)
        _ = await rig.status.signIn(analytics: .discarding())
        await Self.settle()
        #expect(rig.model.phase == .closed && rig.lobby.counts.history == 0, "the terms are due")
        #expect(await rig.status.acceptTerms(analytics: .discarding()))
        await Self.settle()
        #expect(rig.model.phase == .open && rig.lobby.counts.history == 1)
    }

    /// Hide lobby chat closes the feed and drops the field's focus; turning it off reads the history once more.
    @Test func hideLobbyChatClosesTheFeed() async {
        let rig = await Self.rig(.joinable)
        rig.model.isFieldFocused = true
        rig.model.hidesChat = true
        #expect(rig.model.phase == .closed && !rig.model.isFieldFocused)
        await Self.settle()
        let counts = rig.lobby.counts
        rig.model.hidesChat = false
        await Self.settle()
        #expect(rig.model.phase == .open)
        #expect(rig.lobby.counts.history == counts.history + 1)
    }

    /// The scene in the background lets the feed go; back in front, one read.
    @Test func theBackgroundClosesIt() async {
        let rig = await Self.rig(.joinable)
        rig.status.setSceneActive(false)
        #expect(rig.model.phase == .closed)
        rig.status.setSceneActive(true)
        await Self.settle()
        #expect(rig.model.phase == .open && rig.lobby.counts.history == 2)
    }

    /// The silence window (`rejoinable`): no lines, no composer, the feed held for the state that ends it; then the
    /// last hour is read again.
    @Test func theSilenceWindowHoldsTheFeedAndEndsWithARead() async throws {
        let silent = await Self.rig(.rejoinable)
        #expect(silent.model.phase == .silent && silent.model.feed.lines.isEmpty)
        #expect(silent.lobby.counts.feed == 1, "the feed stays open")
        await silent.model.post(.gg)
        #expect(silent.lobby.counts.posts == 0)

        let me = LobbyAuthor(gamePlayerID: GamePlayerID("G:fake-1"), nickname: "Sailor", rating: Rating(value: 1500, isProvisional: true),
                             chip: LiveryChip(deck: SwatchID("sky-blue"), sail: SwatchID("white")))
        let open = LobbyState(access: .open, canPostFreeText: true)
        let ending = ScriptedLobbyService(LobbyScenario(
            player: me, state: LobbyState(access: .closed(.racing), canPostFreeText: false),
            history: [LobbyMessage(id: MessageID("h1"), kind: .system(.winner(venue: "Fellmere", nickname: "Wren")))],
            background: [.state(open)]))
        let rig = await Self.rig(.joinable, lobby: ending)
        #expect(rig.model.phase == .open)
        #expect(rig.model.feed.lines.map(\.id) == [MessageID("h1")])
        #expect(rig.lobby.counts.history == 2, "the read that found the silence, and the one after it")
        #expect(rig.model.composer.canPostFreeText, "the state's free text")
    }

    /// Quick-chat posts and her line shows, once; her own line has no menu.
    @Test func quickChatPostsAndTheLineShows() async {
        let rig = await Self.rig(.joinable)
        await rig.model.post(.gg)
        let last = rig.model.feed.lines.last
        #expect(last?.message.post?.body == .quickChat(.gg))
        #expect(last?.message.post?.author.nickname == "Sailor")
        #expect(rig.model.feed.lines.count == 8)
        #expect(rig.model.actions(for: last!.message).isEmpty)
        #expect(rig.model.opensCard(last!.message) == nil, "her own chip opens nothing")
        #expect(rig.model.mode(at: Date()) == .resting, "3 s before the next")
        #expect(rig.lobby.counts.posts == 1)
    }

    /// A blocked post is hers alone, greyed "Not sent"; the field empties.
    @Test func aBlockedPostIsGreyedNotSent() async throws {
        let rig = await Self.rig(.lobbyFreeText)
        rig.model.text = "what a badword"
        await rig.model.send()
        let last = rig.model.feed.lines.last
        #expect(last?.isNotSent == true)
        #expect(last?.message.post?.body == .text("what a badword"))
        #expect(rig.model.text.isEmpty)
        #expect(try await rig.scripted.history().contains { $0.id == last?.id } == false)
    }

    /// Block: Wren's lines go, and she's on the blocked list. Report: the line goes at once, and is filed.
    @Test func blockAndReport() async throws {
        let rig = await Self.rig(.joinable)
        let wren = GamePlayerID("G:fake-2")
        let wrens = rig.model.feed.lines.filter { $0.message.post?.author.gamePlayerID == wren }
        #expect(!wrens.isEmpty)
        let line = try #require(wrens.first)
        #expect(rig.model.actions(for: line.message) == [.report, .block])
        #expect(rig.model.opensCard(line.message)?.nickname == "Wren")
        #expect(await rig.model.block(wren))
        #expect(!rig.model.feed.lines.contains { $0.message.post?.author.gamePlayerID == wren })
        #expect(try await rig.lobby.blockedPlayers().map(\.gamePlayerID) == [wren])

        let kestrel = try #require(rig.model.feed.lines.first { $0.message.post?.author.nickname == "Kestrel" })
        let count = rig.model.feed.lines.count
        await rig.model.report(kestrel.id)
        #expect(rig.model.feed.lines.count == count - 1 && !rig.model.feed.lines.contains { $0.id == kestrel.id })
        #expect(await rig.scripted.filedReports == ["message \(kestrel.id.rawValue)"])
    }

    /// The boat card's read: Wren's current boat; none for herself.
    @Test func theBoatCardReadsHerCurrentBoat() async {
        let rig = await Self.rig(.joinable)
        let card = await rig.model.boatCard(GamePlayerID("G:fake-2"))
        #expect(card?.livery.sailNumber == 112 && card?.nickname == "Wren")
        #expect(await rig.model.boatCard(GamePlayerID("G:fake-1")) == nil)
        #expect(await rig.model.report(player: GamePlayerID("G:fake-2")))
    }

    /// Muted and banned read the feed and post nothing (`lobby-muted`, `lobby-banned`).
    @Test func mutedAndBannedReadAndDontPost() async {
        for scenario in [FakeServiceScenario.lobbyMuted, .lobbyBanned] {
            let rig = await Self.rig(scenario)
            #expect(rig.model.phase == .open && rig.model.feed.lines.count == 7, "\(scenario)")
            let mode = rig.model.mode(at: Date())
            if scenario == .lobbyBanned { #expect(mode == .banned) } else {
                #expect(mode == .muted(until: Date(timeIntervalSince1970: TimeInterval(FakeServiceScenario.mutedUntil))))
            }
            await rig.model.post(.gg)
            #expect(rig.lobby.counts.posts == 0, "\(scenario)")
        }
    }

    /// Fleet lock drops the field's focus (T12).
    @Test func fleetLockDropsTheFocus() async {
        let rig = await Self.rig(.joinable)
        rig.model.isFieldFocused = true
        rig.status.show(.fleetLocked)
        #expect(!rig.model.isFieldFocused)
    }
}

/// The lobby area's visibility matrix (#142): rows 1-5 from Home's gates before any lobby call, rows 6-8 from the
/// lobby's reads, first match wins.
@MainActor @Suite struct LobbyPanelStateTests {
    static func status(signedIn: Bool = true, terms: Bool = true, hides: Bool = false, canChat: Bool = true,
                       canRaceOnline: Bool = true, queued: Int? = nil) -> LobbyStatus {
        var status = LobbyStatus()
        status.isSignedIn = signedIn
        status.hasAcceptedTerms = terms
        status.hidesChat = hides
        status.canChat = canChat
        status.canRaceOnline = canRaceOnline
        status.queuedPlayers = queued
        return status
    }

    @Test func rowsAndTheirPrecedence() {
        let everything = Self.status(signedIn: false, terms: false, hides: true, canChat: false)
        #expect(LobbyPanelState(isOnline: false, status: everything, retryLine: .unreachable, lobby: .silent) == .offline, "row 1 first")
        #expect(LobbyPanelState(isOnline: true, status: everything, retryLine: .unreachable, lobby: .silent) == .tryAgain(.unreachable))
        #expect(LobbyPanelState(isOnline: true, status: everything, lobby: .silent) == .signIn)
        #expect(LobbyPanelState(isOnline: true, status: Self.status(terms: false, hides: true), lobby: .silent) == .acceptTerms)
        #expect(LobbyPanelState(isOnline: true, status: Self.status(hides: true, queued: 6), lobby: .silent) == .chatHidden(queuedPlayers: 6))
        #expect(LobbyPanelState(isOnline: true, status: Self.status(canChat: false), lobby: .open) == .chatHidden(queuedPlayers: nil),
                "underage or communication-restricted")
        let clear = Self.status()
        #expect(LobbyPanelState(isOnline: true, status: clear, lobby: .closed) == .loading)
        #expect(LobbyPanelState(isOnline: true, status: clear, lobby: .loading) == .loading)
        #expect(LobbyPanelState(isOnline: true, status: clear, lobby: .unreachable) == .unreachable)
        #expect(LobbyPanelState(isOnline: true, status: clear, lobby: .silent) == .silent)
        #expect(LobbyPanelState(isOnline: true, status: clear, lobby: .open) == .lobby)
        #expect(LobbyPanelState(isOnline: true, status: Self.status(canRaceOnline: false), lobby: .open) == .lobby,
                "multiplayer-restricted, can chat: row 8 (#34)")
        #expect(LobbyPanelState.lobby.fillsHome && !LobbyPanelState.silent.fillsHome && !LobbyPanelState.chatHidden(queuedPlayers: 6).fillsHome)
    }

    /// A service that says closed for a reason Home's gates don't (the unconnected fake beside a real session, before
    /// #164) is row 6, never row 3.
    @Test func aServiceClosedWhileSignedInCantReachTheLobby() async {
        var services = ServiceSet.fake(.joinable)
        services.lobby = ServiceSet.fake(.signedOut).lobby
        let status = OnlineStatus(services: services, lobbySleep: { _ in try? await Task.sleep(for: .seconds(3600)) })
        await status.refreshAccount()
        await LobbyModelTests.settle()
        #expect(status.lobbyStatus.isSignedIn)
        #expect(status.lobby.phase == .unreachable)
        #expect(LobbyPanelState(isOnline: true, status: status.lobbyStatus, lobby: status.lobby.phase) == .unreachable)
    }

    /// The composer's rows a-f, first match wins: banned, muted, the cooldown, the 3 s rest, free text locked, open.
    @Test func composerRows() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var composer = LobbyComposer()
        composer.canPostFreeText = true
        composer.posted(at: now, clearingText: false)
        composer.refused(.rateLimited(retryAfterSeconds: 30), at: now)
        composer.standing = .muted(until: Int64(now.timeIntervalSince1970) + 600, isAutomatic: false)
        var banned = composer
        banned.standing = .banned
        #expect(banned.mode(now: now) == .banned, "a")
        #expect(composer.mode(now: now) == .muted(until: now.addingTimeInterval(600)), "b")
        composer.standing = .clear
        #expect(composer.mode(now: now) == .cooldown, "c")
        #expect(composer.mode(now: now.addingTimeInterval(30)) == .open)
        var resting = LobbyComposer()
        resting.posted(at: now, clearingText: false)
        #expect(resting.mode(now: now) == .resting, "d")
        #expect(resting.mode(now: now.addingTimeInterval(3)) == .locked, "e")
        resting.canPostFreeText = true
        #expect(resting.mode(now: now.addingTimeInterval(3)) == .open, "f")
    }
}
