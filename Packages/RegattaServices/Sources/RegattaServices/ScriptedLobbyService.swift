/// What a `ScriptedLobbyService` plays.
public struct LobbyScenario: Sendable {
    /// The player, as her own lines show her.
    public var player: LobbyAuthor
    public var state: LobbyState
    /// The lobby's lines on opening, oldest first.
    public var history: [LobbyMessage]
    /// What the feed brings after the state with no one acting, one per read: a mute notice, the silence window
    /// ending, other players' lines.
    public var background: [LobbyEvent]
    /// Words the filter blocks, matched case-insensitively anywhere in the text.
    public var filteredWords: [String]
    /// Races the player sailed, and who sailed each seat: the seats a report may name.
    public var races: [RaceID: [RaceSeat]]

    public enum RaceSeat: Equatable, Sendable {
        case player
        case human(GamePlayerID)
        case bot
    }

    public init(
        player: LobbyAuthor, state: LobbyState, history: [LobbyMessage] = [], background: [LobbyEvent] = [],
        filteredWords: [String] = [], races: [RaceID: [RaceSeat]] = [:]
    ) {
        self.player = player
        self.state = state
        self.history = history
        self.background = background
        self.filteredWords = filteredWords
        self.races = races
    }
}

/// A `LobbyService` that plays its scenario and keeps what the player does in memory. Time only moves by
/// `advance(seconds:)`, so the rate limit holds until a test moves it on. The feed gives the state, then one
/// event per read: the scenario's background, then what the player's calls caused, finishing when there is
/// nothing left (a real feed would wait). Each feed reads the events with its own cursor (#314).
///
/// Blocking hides a player's lines without deleting them (#314): the feed drops their new lines and removes the
/// old ones from view, and unblocking brings the old ones back to `history()`. Only reports delete.
public actor ScriptedLobbyService: LobbyService {
    private var current: LobbyState
    private let player: LobbyAuthor
    private var lines: [LobbyMessage]
    private let initialState: LobbyState
    private let script: StreamScript<LobbyEvent>
    /// The `.removed` events `block` queued: they hide a line, and unblocking shows it again.
    private var hiddenByBlock: Set<MessageID> = []
    private let filteredWords: [String]
    private let races: [RaceID: [LobbyScenario.RaceSeat]]
    private var blocked: [BlockedPlayer] = []
    private var reported: Set<MessageID> = []
    private var reports: [String] = []
    private var now = 0
    private var lastPost: Int?
    private var posted = 0

    public init(_ scenario: LobbyScenario) {
        current = scenario.state
        initialState = scenario.state
        player = scenario.player
        lines = scenario.history
        script = StreamScript(scenario.background)
        filteredWords = scenario.filteredWords.map { $0.lowercased() }
        races = scenario.races
    }

    /// Moves the fake's clock on, for the rate limit.
    public func advance(seconds: Int) { now += seconds }

    /// What the player has reported, in order, for tests.
    public var filedReports: [String] { reports }

    public func state() -> LobbyState { current }

    public func history() throws -> [LobbyMessage] {
        if case .closed(let closure) = current.access { throw LobbyError.closed(closure) }
        return Array(lines.filter(isVisible).suffix(LobbyLimits.historyCount))
    }

    public nonisolated func feed() -> AsyncStream<LobbyEvent> {
        let cursor = script.cursor()
        return AsyncStream { await self.next(cursor) }
    }

    private func next(_ cursor: StreamCursor) -> LobbyEvent? {
        let loaded = cursor.load()
        var position = loaded.position
        guard loaded.hasStarted else {
            let (start, before) = script.steps(before: position)
            cursor.store(start)
            let state = before.reversed().lazy.compactMap { if case .state(let state) = $0 { state } else { nil } }.first
            return .state(state ?? initialState)
        }
        defer { cursor.store(position) }
        while let (_, event, isFirstRead) = script.next(&position) {
            if isFirstRead { apply(event) }
            // A blocked player's lines are kept, for unblocking, but never reach the feed.
            if case .message(let message) = event, isBlocked(message) { continue }
            return event
        }
        return nil
    }

    private func apply(_ event: LobbyEvent) {
        switch event {
        case .state(let state): current = state
        case .message(let message):
            // The player's own sent lines are in `lines` from `send`.
            if !lines.contains(where: { $0.id == message.id }) { lines.append(message) }
        case .removed(let id):
            if !hiddenByBlock.contains(id) { lines.removeAll { $0.id == id } }
        }
    }

    public func post(_ text: String) throws -> LobbyMessage {
        try requireCanPost()
        guard current.canPostFreeText else { throw LobbyError.freeTextLocked }
        let cleaned = Self.stripContacts(text)
        guard !cleaned.isEmpty else { throw LobbyError.empty }
        guard text.count <= LobbyLimits.maxCharacters else { throw LobbyError.tooLong(limit: LobbyLimits.maxCharacters) }
        try requireRateLimit()
        let lowered = cleaned.lowercased()
        let blocked = filteredWords.contains { lowered.contains($0) }
        return send(.text(cleaned), delivery: blocked ? .notSent : .sent)
    }

    public func post(_ quickChat: QuickChat) throws -> LobbyMessage {
        try requireCanPost()
        try requireRateLimit()
        return send(.quickChat(quickChat), delivery: .sent)
    }

    private func requireCanPost() throws {
        if case .closed(let closure) = current.access { throw LobbyError.closed(closure) }
        switch current.standing {
        case .clear: break
        case .muted(let until, _): throw LobbyError.muted(until: until)
        case .banned: throw LobbyError.banned
        }
    }

    private func requireRateLimit() throws {
        if let lastPost, now - lastPost < LobbyLimits.secondsBetweenPosts {
            throw LobbyError.rateLimited(retryAfterSeconds: LobbyLimits.secondsBetweenPosts - (now - lastPost))
        }
    }

    private func send(_ body: PostBody, delivery: Delivery) -> LobbyMessage {
        posted += 1
        lastPost = now
        let message = LobbyMessage(id: MessageID("own-\(posted)"), kind: .post(LobbyPost(author: player, body: body, delivery: delivery)))
        // A blocked line reaches no one else, so the feed doesn't carry it; the sender has it from this return.
        if delivery == .sent {
            lines.append(message)
            script.append(.message(message))
        }
        return message
    }

    /// Drops the words that are links, email addresses or phone numbers (#17). Best-effort, by design (owner
    /// ruling, #314): spaced-out digits or "name at mail dot com" get through. Moderation (#153) is the backstop,
    /// so don't grow this into a detector.
    static func stripContacts(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).filter { word in
            let lowered = word.lowercased()
            let isLink = lowered.contains("://") || lowered.hasPrefix("www.")
                || [".com", ".net", ".org", ".io"].contains { lowered.hasSuffix($0) || lowered.contains($0 + "/") }
            let isEmail = word.contains("@") && word.contains(".")
            let isPhone = word.filter(\.isNumber).count >= 7
            return !isLink && !isEmail && !isPhone
        }.joined(separator: " ")
    }

    private func isVisible(_ message: LobbyMessage) -> Bool {
        !reported.contains(message.id) && !isBlocked(message)
    }

    private func isBlocked(_ message: LobbyMessage) -> Bool {
        guard let author = message.post?.author.gamePlayerID else { return false }
        return blocked.contains { $0.gamePlayerID == author }
    }

    public func block(_ other: GamePlayerID) throws {
        guard other != player.gamePlayerID else { throw LobbyError.cannotBlockSelf }
        guard !blocked.contains(where: { $0.gamePlayerID == other }) else { return }
        let nickname = lines.compactMap(\.post?.author).first { $0.gamePlayerID == other }?.nickname ?? other.rawValue
        blocked.append(BlockedPlayer(gamePlayerID: other, nickname: nickname))
        for message in lines where message.post?.author.gamePlayerID == other && !reported.contains(message.id) {
            hiddenByBlock.insert(message.id)
            script.append(.removed(message.id))
        }
    }

    public func unblock(_ other: GamePlayerID) {
        blocked.removeAll { $0.gamePlayerID == other }
    }

    public func blockedPlayers() -> [BlockedPlayer] { blocked }

    public func report(message id: MessageID) throws {
        guard let message = lines.first(where: { $0.id == id }), isVisible(message) else { throw LobbyError.unknownMessage }
        guard let post = message.post, post.author.gamePlayerID != player.gamePlayerID else { throw LobbyError.notReportable }
        reported.insert(id)
        reports.append("message \(id.rawValue)")
        hiddenByBlock.remove(id)
        script.append(.removed(id))
    }

    public func report(player other: GamePlayerID) throws {
        guard other != player.gamePlayerID else { throw LobbyError.notReportable }
        reports.append("player \(other.rawValue)")
    }

    public func report(race: RaceID, seat: Int, reason: RaceReportReason) throws {
        guard let seats = races[race], seats.indices.contains(seat), case .human(let other) = seats[seat] else {
            throw LobbyError.notReportable
        }
        reports.append("race \(race.rawValue) seat \(seat) \(other.rawValue) \(reason)")
    }
}
