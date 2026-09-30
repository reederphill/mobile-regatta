import RegattaServices

/// What `LobbyService` promises (#17, #26, #34).
public struct LobbyServiceContract: ContractSuite {
    public enum Situation: Hashable, Sendable {
        /// The lobby is open and the player may post free text, in good standing. Its history holds at least one
        /// system line and one line by another player. The filter blocks `filteredText`. The player sailed `race`
        /// in `ownSeat`, against a human in `humanSeat` and a bot in `botSeat`.
        case open
        /// Open, but the player hasn't completed an online race yet.
        case freeTextLocked
        /// Open, and the player is muted.
        case muted
        /// Open, and the player is banned from chat.
        case banned
        /// The silence window: the player is racing. The feed then shows her finishing, the lobby opening again.
        case racing
        case notSignedIn
        case termsNotAccepted
        /// Game Center's `isUnderage` or `isPersonalizedCommunicationRestricted`.
        case communicationRestricted
    }

    /// Free text a runner's filter must block.
    public static let filteredText = "contract filtered phrase"
    public static let race = RaceID("contract-race")
    public static let ownSeat = 0
    public static let humanSeat = 1
    public static let botSeat = 2

    public let name = "LobbyService"

    public init() {}

    public func run(_ makeService: (Situation) async throws -> any LobbyService) async throws {
        try await openLobby(makeService(.open))
        try await posting(makeService(.open))
        try await refusedPostsDontCount(makeService(.open))
        try await contactsAreStripped(makeService(.open))
        try await filteredIsNotSent(makeService(.open))
        try await blocking(makeService(.open))
        try await reporting(makeService(.open))
        try await freeTextLocked(makeService(.freeTextLocked))
        try await muted(makeService(.muted))
        try await banned(makeService(.banned))
        try await silenceWindow(makeService(.racing))
        for closure in [LobbyClosure.notSignedIn, .termsNotAccepted, .communicationRestricted] {
            let situation: Situation = switch closure {
            case .notSignedIn: .notSignedIn
            case .termsNotAccepted: .termsNotAccepted
            default: .communicationRestricted
            }
            try await closed(makeService(situation), closure)
        }
    }

    /// The feed opens with the state; the history is short, unique and has both kinds of line.
    private func openLobby(_ service: any LobbyService) async throws {
        let state = try await service.state()
        try await require(state == LobbyState(access: .open, canPostFreeText: true, standing: .clear), "an open lobby's state is \(state)")
        try await require(await StreamReader.first(of: service.feed()) == .state(state), "the feed doesn't open with the state")
        let history = try await service.history()
        try await require(history.count <= LobbyLimits.historyCount, "\(history.count) lines of history, over \(LobbyLimits.historyCount)")
        try await require(Set(history.map(\.id)).count == history.count, "the history repeats a line")
        try await require(history.contains { $0.post == nil }, "the history has no system line")
        try await require(history.contains { $0.post != nil }, "the history has no player's line")
    }

    /// A post comes back as sent, arrives on the feed and in the history; the next one within the limit is refused.
    private func posting(_ service: any LobbyService) async throws {
        var feed = StreamReader(service.feed())
        _ = await feed.next()
        let message = try await service.post("fair winds")
        guard let post = message.post else { try fail("post() returned a system line") }
        try await require(post.body == .text("fair winds") && post.delivery == .sent, "post(\"fair winds\") came back as \(post)")
        let (events, arrived) = await feed.read { $0 == .message(message) }
        try await require(arrived, "the post never arrived on the feed; it read \(events)")
        try await require(try await service.history().contains(message), "the history doesn't show the post")

        try await requireRateLimited(service, "a second post straight after") { try await service.post("again") }
        try await requireRateLimited(service, "a quick-chat straight after a post") { try await service.post(.gg) }
    }

    private func requireRateLimited(_ service: any LobbyService, _ what: String, _ body: () async throws -> LobbyMessage) async throws {
        do {
            _ = try await body()
            try fail("\(what) wasn't rate limited")
        } catch LobbyError.rateLimited(let seconds) {
            try await require((1...LobbyLimits.secondsBetweenPosts).contains(seconds), "\(what): retry after \(seconds) s")
        }
    }

    /// Too long and empty posts are refused, and don't use up the rate limit.
    private func refusedPostsDontCount(_ service: any LobbyService) async throws {
        let long = String(repeating: "a", count: LobbyLimits.maxCharacters + 1)
        try await requireThrows(LobbyError.tooLong(limit: LobbyLimits.maxCharacters), "a \(long.count)-character post") {
            try await service.post(long)
        }
        try await requireThrows(LobbyError.empty, "a blank post") { try await service.post("   ") }
        let ok = try await service.post(String(repeating: "b", count: LobbyLimits.maxCharacters))
        try await require(ok.post?.delivery == .sent, "a post at the limit after two refused ones came back as \(ok)")
    }

    /// Links, email addresses and phone numbers are stripped.
    private func contactsAreStripped(_ service: any LobbyService) async throws {
        let message = try await service.post("race me https://example.com or mail sailor@example.com or call 5551234567")
        guard case .text(let text)? = message.post?.body else { try fail("a text post came back as \(message)") }
        for leak in ["https", "example.com", "@", "5551234567"] {
            try await require(!text.contains(leak), "\"\(leak)\" survived the filter: \(text)")
        }
        try await require(text.contains("race me"), "the filter took the words too: \(text)")
    }

    private func filteredIsNotSent(_ service: any LobbyService) async throws {
        let message = try await service.post(Self.filteredText)
        try await require(message.post?.delivery == .notSent, "a filtered post came back as \(message)")
    }

    /// The player's own ID, from a quick-chat: the history can hold her own lines, which she can't block or report.
    private func ownID(_ service: any LobbyService) async throws -> GamePlayerID {
        guard let me = try await service.post(.wave).post?.author.gamePlayerID else { try fail("a quick-chat came back as a system line") }
        return me
    }

    /// Blocking hides the other player's lines, is listed, is idempotent and undone by unblocking; blocking
    /// yourself is refused.
    private func blocking(_ service: any LobbyService) async throws {
        let me = try await ownID(service)
        guard let author = try await service.history().compactMap(\.post?.author).first(where: { $0.gamePlayerID != me }) else {
            try fail("no other player's line to block")
        }
        try await service.block(author.gamePlayerID)
        try await require(try await !service.history().contains { $0.post?.author.gamePlayerID == author.gamePlayerID },
                          "a blocked player's lines still show")
        try await service.block(author.gamePlayerID)
        let list = try await service.blockedPlayers()
        try await require(list.filter { $0.gamePlayerID == author.gamePlayerID }.count == 1, "the blocked list is \(list)")
        try await service.unblock(author.gamePlayerID)
        try await require(try await !service.blockedPlayers().contains { $0.gamePlayerID == author.gamePlayerID }, "unblocking didn't unlist")
        try await requireThrows(LobbyError.cannotBlockSelf, "block(yourself)") { try await service.block(me) }
    }

    /// A reported line is hidden from the reporter at once. System lines, own seats and bots can't be reported.
    private func reporting(_ service: any LobbyService) async throws {
        let me = try await ownID(service)
        let history = try await service.history()
        guard let line = history.first(where: { $0.post.map { $0.author.gamePlayerID != me } ?? false }), let author = line.post?.author,
              let system = history.first(where: { $0.post == nil }) else { try fail("the history lacks a line to report") }
        try await service.report(message: line.id)
        try await require(try await !service.history().contains { $0.id == line.id }, "a reported line still shows to the reporter")
        try await requireThrows(LobbyError.unknownMessage, "reporting a line already reported") { try await service.report(message: line.id) }
        try await requireThrows(LobbyError.unknownMessage, "reporting no line") {
            try await service.report(message: MessageID("contract-no-such-message"))
        }
        try await requireThrows(LobbyError.notReportable, "reporting a system line") { try await service.report(message: system.id) }
        try await service.report(player: author.gamePlayerID)

        try await service.report(race: Self.race, seat: Self.humanSeat, reason: .unsportingConduct)
        try await requireThrows(LobbyError.notReportable, "reporting a bot") {
            try await service.report(race: Self.race, seat: Self.botSeat, reason: .suspectedCheating)
        }
        try await requireThrows(LobbyError.notReportable, "reporting your own seat") {
            try await service.report(race: Self.race, seat: Self.ownSeat, reason: .unsportingConduct)
        }
    }

    /// Before a completed race, quick-chat works and free text doesn't.
    private func freeTextLocked(_ service: any LobbyService) async throws {
        let state = try await service.state()
        try await require(state.access == .open && !state.canPostFreeText, "a player yet to race has state \(state)")
        try await requireThrows(LobbyError.freeTextLocked, "free text before a completed race") { try await service.post("hello") }
        let quick = try await service.post(.goodRace)
        try await require(quick.post?.body == .quickChat(.goodRace) && quick.post?.delivery == .sent, "quick-chat came back as \(quick)")
    }

    /// A muted player is told, and can post nothing.
    private func muted(_ service: any LobbyService) async throws {
        guard case .muted(let until, _) = try await service.state().standing else { try fail("a muted player isn't told") }
        try await requireThrows(LobbyError.muted(until: until), "free text while muted") { try await service.post("hello") }
        try await requireThrows(LobbyError.muted(until: until), "quick-chat while muted") { try await service.post(.gg) }
    }

    private func banned(_ service: any LobbyService) async throws {
        try await require(try await service.state().standing == .banned, "a banned player isn't told")
        try await requireThrows(LobbyError.banned, "free text while banned") { try await service.post("hello") }
        try await requireThrows(LobbyError.banned, "quick-chat while banned") { try await service.post(.gg) }
    }

    /// No chat while racing; the lobby opens again when she finishes.
    private func silenceWindow(_ service: any LobbyService) async throws {
        try await closed(service, .racing, readsFeed: false)
        var feed = StreamReader(service.feed())
        try await require(await feed.next() == .state(try await service.state()), "the feed doesn't open with the state")
        let (events, reopened) = await feed.read { if case .state(let state) = $0 { state.access == .open } else { false } }
        try await require(reopened, "the lobby never opened again after the race; it read \(events)")
    }

    private func closed(_ service: any LobbyService, _ closure: LobbyClosure, readsFeed: Bool = true) async throws {
        let state = try await service.state()
        try await require(state.access == .closed(closure), "the lobby's access is \(state.access), not closed for \(closure)")
        if readsFeed {
            try await require(await StreamReader.first(of: service.feed()) == .state(state), "the feed doesn't open with the state")
        }
        try await requireThrows(LobbyError.closed(closure), "history() while closed for \(closure)") { try await service.history() }
        try await requireThrows(LobbyError.closed(closure), "free text while closed for \(closure)") { try await service.post("hello") }
        try await requireThrows(LobbyError.closed(closure), "quick-chat while closed for \(closure)") { try await service.post(.gg) }
    }
}
