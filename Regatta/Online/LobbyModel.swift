import Foundation
import Observation
import RegattaServices

// The lobby on Home (#17, #25, #142): the lines it shows (`LobbyFeed`), what the composer lets her post
// (`LobbyComposer`), and the reads and posts between them and the lobby service (`LobbyModel`, held by
// `OnlineStatus` so pushed pages and sheets keep the feed).

/// The lobby's lines as Home shows them, oldest first (#17): the newest 50 of the last hour, by the time each line
/// reached the phone (lines carry no time, T3: a history read stamps its lines with the read's). One line per id (the
/// feed echoes her own posts, T4); a blocked author's or a reported line goes at once and leaves no stub; her own
/// posts the filter blocked are kept here only, greyed, until she leaves Home or relaunches (G7).
struct LobbyFeed: Equatable {
    struct Line: Equatable, Identifiable {
        let message: LobbyMessage
        /// When the line reached the phone.
        let arrivedAt: Date

        var id: MessageID { message.id }
        /// Her post the filter blocked: only she sees it.
        var isNotSent: Bool { message.post?.delivery == .notSent }
    }

    /// What a long-press on a line offers (G9).
    enum Action: Equatable {
        case report, block
    }

    private(set) var lines: [Line] = []
    /// Authors she blocked and lines she reported here: kept out, whatever the feed or a history read brings.
    private var hiddenAuthors: Set<GamePlayerID> = []
    private var hiddenMessages: Set<MessageID> = []

    /// The lobby's first read, or the read after the silence window: these lines, and nothing kept from before.
    mutating func replace(with history: [LobbyMessage], at now: Date) {
        lines = history.filter(isShown).map { Line(message: $0, arrivedAt: now) }
        trim(now: now)
    }

    /// The read after a feed that ended (T1): the lines it still has keep their place and time, the ones it no longer
    /// has go (taken down meanwhile), new ones come at the end; her not-sent lines stay where they were.
    mutating func merge(history: [LobbyMessage], at now: Date) {
        let read = Set(history.map(\.id))
        let had = Set(lines.map(\.id))
        lines.removeAll { !$0.isNotSent && !read.contains($0.id) }
        lines += history.filter { !had.contains($0.id) && isShown($0) }.map { Line(message: $0, arrivedAt: now) }
        trim(now: now)
    }

    /// A line from the feed, or her own post's return: once per id.
    mutating func receive(_ message: LobbyMessage, at now: Date) {
        guard isShown(message), !lines.contains(where: { $0.id == message.id }) else { return }
        lines.append(Line(message: message, arrivedAt: now))
        trim(now: now)
    }

    /// The feed took a line down.
    mutating func remove(_ id: MessageID) {
        lines.removeAll { $0.id == id }
    }

    /// She blocked `author`: every line of hers goes, and any that comes later.
    mutating func hide(author: GamePlayerID) {
        hiddenAuthors.insert(author)
        lines.removeAll { $0.message.post?.author.gamePlayerID == author }
    }

    /// She reported `message`: it goes at once (#34).
    mutating func hide(message: MessageID) {
        hiddenMessages.insert(message)
        remove(message)
    }

    /// Drops what is past the hour, then all but the newest `LobbyLimits.historyCount`.
    mutating func trim(now: Date) {
        lines.removeAll { now.timeIntervalSince($0.arrivedAt) > TimeInterval(LobbyLimits.historySeconds) }
        if lines.count > LobbyLimits.historyCount { lines.removeFirst(lines.count - LobbyLimits.historyCount) }
    }

    private func isShown(_ message: LobbyMessage) -> Bool {
        guard !hiddenMessages.contains(message.id) else { return false }
        guard let author = message.post?.author.gamePlayerID else { return true }
        return !hiddenAuthors.contains(author)
    }

    /// What a long-press on `message` offers (G9): Report and Block on another player's post; nothing on her own
    /// lines, sent or not, or on a system line, which are never reported (#17).
    static func actions(for message: LobbyMessage, me: GamePlayerID?) -> [Action] {
        guard let post = message.post, post.delivery == .sent, post.author.gamePlayerID != me else { return [] }
        return [.report, .block]
    }
}

/// The composer under the feed (#17, #142): the quick-chat row, the free-text field and Send, by her standing, free
/// text, the 3 s between posts and the server's cooldown. Pure: the time is passed in.
struct LobbyComposer: Equatable {
    /// What she may do now, first match wins (the brief's composer rows a-f).
    enum Mode: Equatable {
        /// a: banned for good, "Chat closed".
        case banned
        /// b: muted until a time, said.
        case muted(until: Date)
        /// c: the server's cooldown after repeated blocked posts: everything off, her text kept (G8).
        case cooldown
        /// d: the seconds after a post: quick-chat and Send dimmed, typing allowed.
        case resting
        /// e: free text not yet unlocked: quick-chat only.
        case locked
        /// f: everything open.
        case open
    }

    /// The server's two limits on a post (ChatText): characters after trimming, and UTF-8 bytes.
    static let maxCharacters = LobbyLimits.maxCharacters
    static let maxBytes = 800
    /// The counter shows in the last this many characters (G6).
    static let counterWindow = 20

    private(set) var text = ""
    var canPostFreeText = false
    var standing = ChatStanding.clear
    /// Until when the composer rests after a post or a short `rateLimited`.
    private(set) var restingUntil: Date?
    /// Until when the server's cooldown holds.
    private(set) var cooldownUntil: Date?
    /// The server said the last text was too long: the counter reads 0 until she edits it (T11).
    private(set) var isTooLong = false

    func mode(now: Date) -> Mode {
        switch standing {
        case .banned: return .banned
        case .muted(let until, _):
            let end = Date(timeIntervalSince1970: TimeInterval(until))
            if end > now { return .muted(until: end) }
        case .clear: break
        }
        if let cooldownUntil, cooldownUntil > now { return .cooldown }
        if let restingUntil, restingUntil > now { return .resting }
        return canPostFreeText ? .open : .locked
    }

    /// The text as it would be posted.
    var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Characters left, counted conservatively against both limits (T11): a character may take 4 bytes.
    var remaining: Int {
        guard !isTooLong else { return 0 }
        let characters = Self.maxCharacters - trimmed.count
        let bytes = (Self.maxBytes - trimmed.utf8.count) / 4
        return max(0, min(characters, bytes))
    }

    var showsCounter: Bool { remaining <= Self.counterWindow }

    /// Typing allowed: open, or resting after a post.
    func fieldEnabled(now: Date) -> Bool {
        switch mode(now: now) {
        case .open, .resting: true
        default: false
        }
    }

    func quickChatEnabled(now: Date) -> Bool {
        switch mode(now: now) {
        case .open, .locked: true
        default: false
        }
    }

    func canSend(now: Date) -> Bool {
        mode(now: now) == .open && !trimmed.isEmpty && !isTooLong && Self.fits(trimmed)
    }

    /// Whether `text` is inside both of the server's limits.
    static func fits(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= maxCharacters && trimmed.utf8.count <= maxBytes
    }

    /// The text Send took, until she types something else: the field's late write-back of it is not new typing.
    private(set) var sending: String?

    /// What she typed: typing stops at the limits (G6), so a paste is cut to fit. Right after Send emptied the
    /// field, the keyboard can hand the sent text back (an autocorrection it commits late): that is dropped, so the
    /// field stays empty and her next typing starts afresh.
    mutating func type(_ new: String) {
        if let sending {
            if text.isEmpty, new.trimmingCharacters(in: .whitespacesAndNewlines) == sending { return }
            self.sending = nil
        }
        var new = new
        while !Self.fits(new), !new.isEmpty { new.removeLast() }
        if new != text { isTooLong = false }
        text = new
    }

    /// Send: the text as it reads now, trimmed. The field empties at once, before the server answers, so what she
    /// types next is never lost to a late clear; a refusal gives the text back.
    mutating func takeForSend() -> String {
        let taken = trimmed
        text = ""
        sending = taken
        return taken
    }

    /// A refused Send: her text comes back to the field, unless she has typed something since.
    mutating func giveBack(_ taken: String) {
        if text.isEmpty { text = taken }
        sending = nil
    }

    /// A post went through: the text goes, and the composer rests for the seconds between posts.
    mutating func posted(at now: Date, clearingText: Bool) {
        if clearingText { text = "" }
        restingUntil = now.addingTimeInterval(TimeInterval(LobbyLimits.secondsBetweenPosts))
    }

    /// The server refused a post: a short wait rests, a longer one is the cooldown; her text is kept.
    mutating func refused(_ error: LobbyError, at now: Date) {
        switch error {
        case .rateLimited(let seconds):
            let until = now.addingTimeInterval(TimeInterval(seconds))
            if seconds > LobbyLimits.secondsBetweenPosts { cooldownUntil = until } else { restingUntil = until }
        case .tooLong: isTooLong = true
        case .muted(let until): standing = .muted(until: until, isAutomatic: false)
        case .banned: standing = .banned
        case .freeTextLocked: canPostFreeText = false
        default: break
        }
    }

    /// The next moment the mode may change by itself, for the view's clock.
    func nextChange(after now: Date) -> Date? {
        [restingUntil, cooldownUntil].compactMap { $0 }.filter { $0 > now }.min()
    }
}

/// The lobby between Home and the lobby service (#142, T1): it opens (one history read, then the feed) while
/// `OnlineStatus` allows it and Hide lobby chat is off, and closes otherwise; it never polls. A feed that ends (cut
/// behind, the socket gone) reopens with one more read, after 1, 2, 4 … 30 s (T13). The silence window keeps the
/// feed open for the state that ends it, then reads the history again.
@MainActor @Observable
final class LobbyModel {
    enum Phase: Equatable {
        /// Not asked: hidden, restricted, signed out, offline, or the scene in the background.
        case closed
        /// The history read is out.
        case loading
        /// The read failed, or the service said closed for a reason Home's gates don't: "Can't reach the lobby".
        case unreachable
        /// The silence window: from her fleet lock until she finishes (#17).
        case silent
        case open
    }

    private(set) var phase = Phase.closed
    private(set) var feed = LobbyFeed()
    private(set) var composer = LobbyComposer()
    /// The field's focus (T12): fleet lock, Hide lobby chat and leaving the open lobby drop it.
    var isFieldFocused = false
    /// Settings' Hide lobby chat, pushed in from the app's device settings (T1).
    var hidesChat = false {
        didSet { if hidesChat != oldValue { update() } }
    }
    /// The signed-in player: her own lines get no menu and no card.
    var me: GamePlayerID?

    private let lobby: any LobbyService
    private let now: () -> Date
    private let sleep: @Sendable (Duration) async -> Void
    /// What `OnlineStatus` allows: Home's gates passed, the lobby may be asked, the scene is active.
    private var isAllowed = false
    /// Bumped by every open and close, so a stale read or feed lets go.
    private var generation = 0
    private var task: Task<Void, Never>?
    private var tick: Task<Void, Never>?
    private var reopenDelay = Duration.seconds(1)

    init(lobby: any LobbyService, now: @escaping () -> Date = Date.init,
         sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.lobby = lobby
        self.now = now
        self.sleep = sleep
    }

    /// Whether the lobby may be read now, from `OnlineStatus`.
    func setAllowed(_ allowed: Bool) {
        guard allowed != isAllowed else { return }
        isAllowed = allowed
        update()
    }

    private var isWanted: Bool { isAllowed && !hidesChat }

    private func update() {
        if isWanted, phase == .closed {
            reopenDelay = .seconds(1)
            open()
        } else if !isWanted, phase != .closed {
            close()
        }
    }

    /// The unreachable panel's Try again.
    func retry() {
        guard isWanted, phase == .unreachable else { return }
        open()
    }

    private func open(replacing: Bool = false) {
        generation += 1
        let generation = generation
        task?.cancel()
        // A reopen after a dropped feed keeps the open lobby on screen while it reads: a spinner would take the
        // composer down with her text's focus, every time the feed flaps.
        if phase != .open || replacing { phase = .loading }
        task = Task { [weak self] in await self?.run(generation, replacing: replacing) }
        if tick == nil {
            tick = Task { [weak self, sleep] in
                while !Task.isCancelled {
                    await sleep(.seconds(60))
                    guard !Task.isCancelled else { return }
                    self?.trim()
                }
            }
        }
    }

    private func close() {
        generation += 1
        task?.cancel()
        task = nil
        tick?.cancel()
        tick = nil
        phase = .closed
        isFieldFocused = false
    }

    /// The minute tick (T3): lines past the hour go.
    func trim() { feed.trim(now: now()) }

    /// Fleet lock's takeover (T12).
    func dropFocus() { isFieldFocused = false }

    private func isCurrent(_ generation: Int) -> Bool { generation == self.generation && !Task.isCancelled }

    /// One open: the history, then the feed until it ends or the lobby closes.
    private func run(_ generation: Int, replacing: Bool) async {
        do {
            let history = try await lobby.history()
            guard isCurrent(generation) else { return }
            if replacing || feed.lines.isEmpty { feed.replace(with: history, at: now()) } else { feed.merge(history: history, at: now()) }
            phase = .open
        } catch LobbyError.closed(.racing) {
            guard isCurrent(generation) else { return }
            phase = .silent
            isFieldFocused = false
        } catch {
            guard isCurrent(generation) else { return }
            phase = .unreachable
            isFieldFocused = false
            return
        }
        let opened = now()
        for await event in lobby.feed() {
            guard isCurrent(generation) else { return }
            switch handle(event) {
            case .carryOn: continue
            case .silenceEnded:
                // The last hour returns (#152): the lines go, and the history is read again.
                return open(replacing: true)
            case .unreachable:
                phase = .unreachable
                return
            }
        }
        guard isCurrent(generation) else { return }
        // A feed that lived a while was no flap: the next reopen is quick again.
        if now().timeIntervalSince(opened) >= 60 { reopenDelay = .seconds(1) }
        let delay = reopenDelay
        reopenDelay = min(reopenDelay * 2, .seconds(30))
        await sleep(delay)
        guard isCurrent(generation), isWanted else { return }
        open()
    }

    private enum Outcome {
        case carryOn, silenceEnded, unreachable
    }

    private func handle(_ event: LobbyEvent) -> Outcome {
        switch event {
        case .state(let state):
            composer.canPostFreeText = state.canPostFreeText
            composer.standing = state.standing
            switch state.access {
            case .open:
                if phase == .silent { return .silenceEnded }
            case .closed(.racing):
                phase = .silent
                isFieldFocused = false
            case .closed:
                return .unreachable
            }
        case .message(let message):
            if phase == .open { feed.receive(message, at: now()) }
        case .removed(let id):
            feed.remove(id)
        }
        return .carryOn
    }

    // MARK: Posting

    /// When the composer's rest or cooldown last ran out: the view reads it to redraw then.
    private(set) var refreshedAt = Date.distantPast
    private var refresh: Task<Void, Never>?

    /// Marks the composer's next change by itself (the 3 s rest, the cooldown), so the view redraws with no timer.
    private func scheduleRefresh() {
        refresh?.cancel()
        guard let next = composer.nextChange(after: now()) else { return }
        let wait = next.timeIntervalSince(now())
        refresh = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            refreshedAt = self.now()
            scheduleRefresh()
        }
    }

    /// The field's text, cut to the limits as she types.
    var text: String {
        get { composer.text }
        set { composer.type(newValue) }
    }

    func post(_ quickChat: QuickChat) async {
        guard phase == .open, composer.quickChatEnabled(now: now()) else { return }
        await post(clearingText: false) { try await $0.post(quickChat) }
    }

    /// Send: the field's text as it reads now (the view commits a pending autocorrection first). The field empties
    /// before the call, and gets the text back if the post is refused.
    func send() async {
        guard phase == .open, composer.canSend(now: now()) else { return }
        let text = composer.takeForSend()
        await post(clearingText: false, givingBack: text) { try await $0.post(text) }
    }

    private func post(clearingText: Bool, givingBack taken: String? = nil,
                      _ call: (any LobbyService) async throws -> LobbyMessage) async {
        do {
            let message = try await call(lobby)
            // Hers, sent or not: the feed's echo of a sent one is the same id (T4).
            feed.receive(message, at: now())
            composer.posted(at: now(), clearingText: clearingText)
            scheduleRefresh()
        } catch let error as LobbyError {
            if let taken { composer.giveBack(taken) }
            composer.refused(error, at: now())
            scheduleRefresh()
        } catch {
            if let taken { composer.giveBack(taken) }
        }
    }

    // MARK: Block, report, card

    /// Report on a long-press (G9): the line goes at once, with no confirm, whatever the call says.
    func report(_ message: MessageID) async {
        feed.hide(message: message)
        try? await lobby.report(message: message)
    }

    /// Block, confirmed: her lines go once the service has it. False when it didn't take (a full list, say).
    @discardableResult func block(_ player: GamePlayerID) async -> Bool {
        do {
            try await lobby.block(player)
        } catch {
            return false
        }
        feed.hide(author: player)
        return true
    }

    /// The boat card's Report player: false when it didn't take.
    func report(player: GamePlayerID) async -> Bool {
        (try? await lobby.report(player: player)) != nil
    }

    /// The boat card's current boat (#142): nil when the lobby gives none, and the sheet shows the line's fields.
    func boatCard(_ player: GamePlayerID) async -> BoatCard? {
        try? await lobby.boatCard(player)
    }

    /// What a long-press on `message` offers.
    func actions(for message: LobbyMessage) -> [LobbyFeed.Action] { LobbyFeed.actions(for: message, me: me) }

    /// Whether a line's chip or name opens a card: another player's post.
    func opensCard(_ message: LobbyMessage) -> LobbyAuthor? {
        guard let author = message.post?.author, author.gamePlayerID != me else { return nil }
        return author
    }

    /// The composer's mode now.
    func mode(at date: Date) -> LobbyComposer.Mode { composer.mode(now: date) }
}
