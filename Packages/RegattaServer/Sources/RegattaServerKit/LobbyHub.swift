import ChatFilter
import Foundation
import Persistence
import Ratings
import RegattaCore
import RegattaServices
import Synchronization

// The lobby (#17, #152, ADR 0013): one global room. The hub holds who is reading (the feeds), the last hour's lines,
// who blocks whom, who is racing (the silence window) and the posting limits, all in memory; lines and blocks are
// written through to the store before anyone is told, so a restart loses only the limits, the feeds and the silence
// (and a crash cancels the races that silenced anyone).
//
// A post goes through, in this order: the silence window, the player's chat standing, the free-text unlock, the
// text's clean-up and limits, the rate limits, the word list, the classifier, the store, the fan-out. Only the word
// list and a classifier's "flagged" block a post; a classifier that can't answer lets it through (owner 2026-10-11).
// A post the store can't record isn't sent. A blocked post goes back to its sender alone, marked not sent: it is
// never stored, fanned out or logged.

/// What the queue and the race lifecycle tell the lobby (#152): the silence window's edges and the two system lines.
/// Only queue races: a dev-arranged or instant race tells it nothing.
public protocol LobbyRaceEvents: Sendable {
    /// The fleet locked: its humans (teamPlayerIDs) are silent from now.
    func fleetLocked(race: UUID, humans: [String])
    /// Her seat has a result: she may read and post again.
    func finished(race: UUID, player: String)
    /// She gave her seat up for good.
    func left(race: UUID, player: String)
    /// The race closed, was cancelled, or never started: whoever of `players` it still silences is free.
    func raceEnded(race: UUID, players: [String])
    /// The gun, with the humans at it by the rating rule (`RaceLog.humanSeatsAtGun`). No line for none.
    func gun(race: UUID, venue: String, boats: Int, humans: Int)
    /// A human won (`RaceSummary.winnerLine(sailedWhileGone:)` decides: never a bot, never a covered finish).
    func winner(race: UUID, venue: String, nickname: String, playerID: String)
}

/// The lobby's numbers.
public struct LobbySettings: Sendable {
    /// One post per player this often, quick-chat and free text together, across her connections.
    public var postInterval: TimeInterval = TimeInterval(LobbyLimits.secondsBetweenPosts)
    /// This many blocked posts inside `blockedPostWindow` start a cooldown: `cooldown`, or `repeatCooldown` when the
    /// last one began less than `repeatWindow` ago.
    public var blockedPostsForCooldown = 3
    public var blockedPostWindow: TimeInterval = 60
    public var cooldown: TimeInterval = 30
    public var repeatCooldown: TimeInterval = 120
    public var repeatWindow: TimeInterval = 600
    /// The whole room: posts a second, and the burst it allows. System lines are exempt.
    public var roomPostsPerSecond = 6.0
    public var roomBurst = 12.0
    public var maxBlocksPerPlayer = 1000
    /// Events a feed holds unread; one more ends it (the client reopens and reads the history again).
    public var feedBuffer = 64
    public var feedsPerPlayer = 2
    /// Lines kept in memory (the history shows at most `LobbyLimits.historyCount` of the last hour).
    public var ringCount = 200
    /// The silence window ends by itself this long after the lock, whatever became of the race.
    public var silenceLimit: TimeInterval = 1800
    /// Every store read and write on a player's path is given this long.
    public var storeDeadline: Duration = .seconds(2)
    public var standingDeadline: Duration = .seconds(2)
    /// Posts waiting for the store at once; more aren't sent.
    public var maxPendingCommits = 32
    public var rating = RatingConfig()

    public init() {}
}

/// What the lobby has counted since it started: for logs and tests. Never a message, a nickname or a key.
public struct LobbyCounters: Sendable, Equatable {
    public var sent = 0
    public var blockedByWordList = 0
    public var blockedByClassifier = 0
    /// Free-text posts that went through without the classifier's answer, by why it had none.
    public var classifierUnavailablePasses: [ToxicityScreening.Unavailable: Int] = [:]
    public var storeFailures = 0
    public var standingReadFailures = 0
    /// Feeds ended because their reader fell `feedBuffer` events behind.
    public var slowReaderCuts = 0
    public var systemLines = 0
}

/// The chip beside a player's lines.
public typealias LobbyChipSource = @Sendable (AccountPlayer) async -> LiveryChip

public final class LobbyHub: LobbyRaceEvents, Sendable {
    typealias Continuation = AsyncStream<LobbyEvent>.Continuation

    /// A line in memory.
    struct Line: Sendable {
        let id: Int64
        let createdAt: Date
        let message: LobbyMessage
        let authorID: String?
        let subjectID: String?
    }

    private struct Feed {
        let player: String
        let continuation: Continuation
        let order: UInt64
        var primed = false
    }

    private struct Facts {
        var canPostFreeText: Bool
        var standing: ChatStanding
    }

    private struct State {
        var finished = false
        var loading: Task<Void, any Error>?
        var loaded = false
        var feeds: [UUID: Feed] = [:]
        var order: UInt64 = 0
        /// Bumped by each `refresh` of a player with feeds: a feed being primed meanwhile reads her facts again.
        var epochs: [String: Int] = [:]
        var ring: [Line] = []
        var blocks: [String: Set<String>] = [:]
        var silenced: [String: (race: UUID, since: Date)] = [:]
        /// Players known to have completed a race: free text never locks again.
        var unlocked: Set<String> = []
        var directory: [String: LobbyPlayerRef] = [:]
        // The limits.
        var lastPost: [String: Date] = [:]
        var blockedPosts: [String: [Date]] = [:]
        var cooldownUntil: [String: Date] = [:]
        var lastCooldown: [String: Date] = [:]
        var roomTokens: Double
        var roomAt: Date?
        var posts = 0
        // The commit chain.
        var tail: Task<Void, Never>?
        var pending = 0
        var unsent: UInt64 = 0
        var counters = LobbyCounters()
        var onPrimed: [String: @Sendable () async -> Void] = [:]

        func isSilenced(_ player: String, at time: Date, limit: TimeInterval) -> Bool {
            silenced[player].map { time.timeIntervalSince($0.since) < limit } ?? false
        }

        func hides(_ line: Line, from viewer: String) -> Bool {
            guard let author = line.authorID, author != viewer else { return false }
            return blocks[viewer]?.contains(author) == true || blocks[author]?.contains(viewer) == true
        }
    }

    public let settings: LobbySettings
    public let store: any LobbyStore
    public let moderation: any LobbyModeration
    private let ratings: any RatingBook
    private let wordList: ChatWordList
    private let classifier: ClassifierGate?
    private let chip: LobbyChipSource
    private let now: @Sendable () -> Date
    private let state: Mutex<State>

    public init(settings: LobbySettings = LobbySettings(), store: any LobbyStore = InMemoryLobbyStore(), ratings: any RatingBook,
                moderation: any LobbyModeration = NoModeration(), wordList: ChatWordList, classifier: ClassifierGate? = nil,
                chip: @escaping LobbyChipSource = LobbyHub.starterChip, now: @escaping @Sendable () -> Date = { Date() }) {
        self.settings = settings
        self.store = store
        self.ratings = ratings
        self.moderation = moderation
        self.wordList = wordList
        self.classifier = classifier
        self.chip = chip
        self.now = now
        state = Mutex(State(roomTokens: settings.roomBurst))
    }

    /// Until #159 stores liveries: the chip of the starter livery the briefing shows for her.
    public static let starterChip: LobbyChipSource = { player in
        let fallback = LiveryChip(deck: SwatchID("sky-blue"), sail: SwatchID("white"))
        guard let livery = try? await StarterLiveries().livery(of: player),
              let design = OnlineBriefing.catalogue?.design(livery.design) else { return fallback }
        func colour(_ slot: LiverySlot) -> SwatchID? {
            design.slots.firstIndex(of: slot).flatMap { livery.colours.indices.contains($0) ? livery.colours[$0] : nil }
        }
        return LiveryChip(deck: colour(.deck) ?? fallback.deck, sail: colour(.sail) ?? fallback.sail)
    }

    public var counters: LobbyCounters { state.withLock { $0.counters } }
    /// Feeds open now.
    public var feedCount: Int { state.withLock { $0.feeds.count } }

    // MARK: Loading

    /// The block graph and the last hour's lines, read from the store once (again after a failure).
    private func ensureLoaded() async throws {
        let task: Task<Void, any Error>? = state.withLock { state in
            if state.loaded { return nil }
            if let loading = state.loading { return loading }
            let task = Task { try await self.load() }
            state.loading = task
            return task
        }
        guard let task else { return }
        do {
            try await task.value
        } catch {
            state.withLock { state in
                if !state.loaded { state.loading = nil }
            }
            throw error
        }
    }

    private func load() async throws {
        let store = store, since = now().addingTimeInterval(-TimeInterval(LobbyLimits.historySeconds)), count = settings.ringCount
        let blocks = try await withDeadline(settings.storeDeadline) { try await store.blocks().map { [$0.blocker, $0.blocked] } }
        let lines = try await withDeadline(settings.storeDeadline) { try await store.recent(since: since, limit: count) }
        state.withLock { state in
            guard !state.loaded else { return }
            for pair in blocks { state.blocks[pair[0], default: []].insert(pair[1]) }
            // Lines committed while the store was read are already there, and newer.
            let have = Set(state.ring.map(\.id))
            state.ring = (lines.compactMap(Self.line).filter { !have.contains($0.id) } + state.ring).sorted { $0.id < $1.id }
            state.loaded = true
        }
    }

    // MARK: Lines

    static func line(_ stored: StoredLobbyLine) -> Line? {
        let kind: LobbyMessage.Kind
        switch stored.kind {
        case .text, .quick:
            guard let author = stored.author else { return nil }
            let body: PostBody
            if stored.kind == .text {
                guard let text = stored.body else { return nil }
                body = .text(text)
            } else {
                guard let quick = stored.quick.flatMap(QuickChat.init(rawValue:)) else { return nil }
                body = .quickChat(quick)
            }
            kind = .post(LobbyPost(author: LobbyAuthor(
                gamePlayerID: GamePlayerID(author.gamePlayerID), nickname: author.nickname,
                rating: Rating(value: author.rating, isProvisional: author.isProvisional),
                chip: LiveryChip(deck: SwatchID(author.chipDeck), sail: SwatchID(author.chipSail))), body: body))
        case .gun:
            guard let venue = stored.venue, let boats = stored.boats, let humans = stored.humans else { return nil }
            kind = .system(.gun(venue: venue, boats: boats, humans: humans))
        case .winner:
            guard let venue = stored.venue, let name = stored.winnerName else { return nil }
            kind = .system(.winner(venue: venue, nickname: name))
        }
        return Line(id: stored.id, createdAt: stored.createdAt, message: LobbyMessage(id: MessageID(String(stored.id)), kind: kind),
                    authorID: stored.authorID, subjectID: stored.subjectID)
    }

    /// Stores `line`, then tells the room, one line at a time: ids, the ring and every feed see the same order. Nil
    /// when the store didn't take it inside its deadline, or too many posts are waiting for it: not sent.
    private func commit(_ line: StoredLobbyLine, bounded: Bool = true) async -> Line? {
        guard let task = enqueue(line, bounded: bounded) else {
            state.withLock { $0.counters.storeFailures += 1 }
            return nil
        }
        return await task.value
    }

    /// Puts `line` on the commit chain, now: lines are stored and told in the order this is called.
    private func enqueue(_ line: StoredLobbyLine, bounded: Bool) -> Task<Line?, Never>? {
        state.withLock { state in
            guard !state.finished, !bounded || state.pending < settings.maxPendingCommits else { return nil }
            state.pending += 1
            let previous = state.tail
            let task = Task { () -> Line? in
                await previous?.value
                return await self.write(line)
            }
            state.tail = Task { _ = await task.value }
            return task
        }
    }

    private func write(_ line: StoredLobbyLine) async -> Line? {
        let store = store
        var stored = line
        do {
            stored.id = try await withDeadline(settings.storeDeadline) { try await store.append(line) }
        } catch {
            state.withLock { state in
                state.pending -= 1
                state.counters.storeFailures += 1
            }
            return nil
        }
        let made = Self.line(stored)
        let time = now()
        let cut: [Continuation] = state.withLock { state in
            state.pending -= 1
            guard let made else { return [] }
            state.ring.append(made)
            let oldest = time.addingTimeInterval(-TimeInterval(LobbyLimits.historySeconds))
            state.ring.removeAll { $0.createdAt < oldest }
            if state.ring.count > settings.ringCount { state.ring.removeFirst(state.ring.count - settings.ringCount) }
            if made.authorID == nil { state.counters.systemLines += 1 } else { state.counters.sent += 1 }
            return deliver(.message(made.message), &state, at: time) { feed, state in !state.hides(made, from: feed.player) }
        }
        for continuation in cut { continuation.finish() }
        expireSilences()
        return made
    }

    /// To every primed feed that isn't silent and that `wanted` lets it reach. A feed whose buffer is full is cut:
    /// returned, to be finished outside the lock.
    private func deliver(_ event: LobbyEvent, _ state: inout State, at time: Date,
                         where wanted: (Feed, State) -> Bool = { _, _ in true }) -> [Continuation] {
        var cut: [Continuation] = []
        for (token, feed) in state.feeds where feed.primed {
            if case .state = event {} else if state.isSilenced(feed.player, at: time, limit: settings.silenceLimit) { continue }
            guard wanted(feed, state) else { continue }
            if case .dropped = feed.continuation.yield(event) {
                state.feeds[token] = nil
                state.counters.slowReaderCuts += 1
                cut.append(feed.continuation)
            }
        }
        return cut
    }

    // MARK: Feeds

    /// A feed for `player`, registered before this returns and removed the moment it ends. It says nothing until it
    /// is primed with the lobby's state; a third feed of one player ends her oldest.
    public func openFeed(_ player: AccountPlayer) -> (stream: AsyncStream<LobbyEvent>, token: UUID) {
        let (stream, continuation) = AsyncStream<LobbyEvent>.makeStream(bufferingPolicy: .bufferingOldest(settings.feedBuffer))
        let token = UUID(), id = player.teamPlayerID
        let ended: [Continuation] = state.withLock { state in
            guard !state.finished else { return [continuation] }
            state.order += 1
            state.feeds[token] = Feed(player: id, continuation: continuation, order: state.order)
            let hers = state.feeds.filter { $0.value.player == id }.sorted { $0.value.order < $1.value.order }
            return hers.dropLast(settings.feedsPerPlayer).map { key, feed in
                state.feeds[key] = nil
                return feed.continuation
            }
        }
        continuation.onTermination = { [weak self] _ in self?.forget(token) }
        for continuation in ended { continuation.finish() }
        Task { await self.prime(token, id) }
        return (stream, token)
    }

    private func forget(_ token: UUID) {
        state.withLock { state in
            guard let feed = state.feeds.removeValue(forKey: token) else { return }
            if !state.feeds.values.contains(where: { $0.player == feed.player }) { state.epochs[feed.player] = nil }
        }
    }

    /// Ends these feeds (a connection ended, or signed in as someone who may not chat).
    public func closeFeeds(_ tokens: [UUID]) {
        let ended = state.withLock { state in tokens.compactMap { state.feeds.removeValue(forKey: $0)?.continuation } }
        for continuation in ended { continuation.finish() }
    }

    private func prime(_ token: UUID, _ player: String) async {
        do {
            try await ensureLoaded()
            for _ in 0..<4 {
                let epoch = state.withLock { $0.epochs[player, default: 0] }
                let facts = try await facts(of: player)
                let time = now()
                let (done, cut): (Bool, Continuation?) = state.withLock { state in
                    guard var feed = state.feeds[token] else { return (true, nil) }
                    guard state.epochs[player, default: 0] == epoch else { return (false, nil) }
                    feed.primed = true
                    state.feeds[token] = feed
                    if case .dropped = feed.continuation.yield(.state(lobbyState(player, facts, state, at: time))) {
                        state.feeds[token] = nil
                        return (true, feed.continuation)
                    }
                    return (true, nil)
                }
                cut?.finish()
                if done { break }
            }
        } catch {
            state.withLock { $0.counters.standingReadFailures += 1 }
            closeFeeds([token])
            return
        }
        if let then = state.withLock({ $0.onPrimed.removeValue(forKey: player) }) { await then() }
    }

    private func lobbyState(_ player: String, _ facts: Facts, _ state: State, at time: Date) -> LobbyState {
        let silent = state.isSilenced(player, at: time, limit: settings.silenceLimit)
        return LobbyState(access: silent ? .closed(.racing) : .open, canPostFreeText: facts.canPostFreeText, standing: facts.standing)
    }

    private func facts(of player: String) async throws -> Facts {
        let moderation = moderation
        let standing = try await withDeadline(settings.standingDeadline) { try await moderation.standing(of: player) }
        return Facts(canPostFreeText: try await canPostFreeText(player), standing: standing)
    }

    /// Free text unlocks with her first completed online race (`player_stats.completed_races`, counted at each close
    /// by `RaceLifecycleSettings.earnedProgressResultCodes`).
    private func canPostFreeText(_ player: String) async throws -> Bool {
        if state.withLock({ $0.unlocked.contains(player) }) { return true }
        let ratings = ratings
        let completed = try await withDeadline(settings.storeDeadline) { try await ratings.standing(of: player)?.completedRaces ?? 0 }
        if completed >= 1 { unlock(player) }
        return completed >= 1
    }

    private func unlock(_ player: String) {
        state.withLock { state in
            if state.unlocked.count >= 100_000 { state.unlocked = [] }
            state.unlocked.insert(player)
        }
    }

    /// The lobby as `player` sees it now. Throws when her standing or her races can't be read.
    public func state(of player: String) async throws -> LobbyState {
        try await ensureLoaded()
        expireSilences()
        let facts = try await facts(of: player)
        let time = now()
        return state.withLock { lobbyState(player, facts, $0, at: time) }
    }

    /// Tells each of `players`' open feeds the lobby's state as it is now: her standing changed (#153), her race
    /// closed (free text may have unlocked), her silence began or ended.
    public func refresh(players: [String]) async {
        for player in Set(players) {
            let watched = state.withLock { state in
                guard state.feeds.values.contains(where: { $0.player == player }) else { return false }
                state.epochs[player, default: 0] += 1
                return true
            }
            guard watched else { continue }
            guard let facts = try? await facts(of: player) else {
                state.withLock { $0.counters.standingReadFailures += 1 }
                continue
            }
            let time = now()
            let cut = state.withLock { state in
                deliver(.state(lobbyState(player, facts, state, at: time)), &state, at: time) { feed, _ in feed.player == player }
            }
            for continuation in cut { continuation.finish() }
        }
    }

    /// The lines `player` sees on opening: the last hour's, at most `LobbyLimits.historyCount`, oldest first, without
    /// the lines to or from players either has blocked and the ones she reported.
    public func history(for player: String) async throws -> [LobbyMessage] {
        try await ensureLoaded()
        expireSilences()
        let time = now()
        if state.withLock({ $0.isSilenced(player, at: time, limit: settings.silenceLimit) }) { throw LobbyError.closed(.racing) }
        let moderation = moderation
        let hidden = try await withDeadline(settings.standingDeadline) { try await moderation.hiddenMessages(for: player) }
        return Array(visibleLines(to: player, at: time).filter { !hidden.contains($0.id) }.map(\.message).suffix(LobbyLimits.historyCount))
    }

    private func visibleLines(to player: String, at time: Date) -> [Line] {
        let oldest = time.addingTimeInterval(-TimeInterval(LobbyLimits.historySeconds))
        return state.withLock { state in state.ring.filter { $0.createdAt >= oldest && !state.hides($0, from: player) } }
    }

    // MARK: Posting

    public enum Draft: Sendable, Equatable {
        case text(String)
        case quickChat(QuickChat)
    }

    /// Posts for `player`. Returns the line as she sees it: sent, or not sent. Throws `LobbyError` for a refusal.
    public func post(_ draft: Draft, by player: AccountPlayer) async throws -> LobbyMessage {
        let id = player.teamPlayerID
        try? await ensureLoaded()
        expireSilences()
        // 1. The silence window.
        if state.withLock({ $0.isSilenced(id, at: now(), limit: settings.silenceLimit) }) { throw LobbyError.closed(.racing) }
        // 2. Her standing; a read that fails, fails closed.
        let moderation = moderation, ratings = ratings
        var readable = true
        do {
            switch try await withDeadline(settings.standingDeadline, { try await moderation.standing(of: id) }) {
            case .clear: break
            case .muted(let until, _): throw LobbyError.muted(until: until)
            case .banned: throw LobbyError.banned
            }
        } catch let error as LobbyError {
            throw error
        } catch {
            state.withLock { $0.counters.standingReadFailures += 1 }
            readable = false
        }
        // Her name, rating and races, in one read: the unlock and what her line shows.
        let rated = try? await withDeadline(settings.storeDeadline) { try await ratings.standing(of: id) ?? PlayerStanding() }
        if rated == nil { state.withLock { $0.counters.storeFailures += 1 } }
        // 3. Free text needs a completed race.
        let body: PostBody
        switch draft {
        case .quickChat(let quick):
            body = .quickChat(quick)
        case .text(let raw):
            if let rated {
                if rated.completedRaces >= 1 { unlock(id) }
                guard state.withLock({ $0.unlocked.contains(id) }) else { throw LobbyError.freeTextLocked }
            }
            // 4. Cleaned, and inside the limits.
            do {
                body = .text(try ChatText.clean(raw))
            } catch ChatText.Refusal.empty {
                throw LobbyError.empty
            } catch {
                throw LobbyError.tooLong(limit: LobbyLimits.maxCharacters)
            }
        }
        let rating = rated?.rating ?? PlayerRating(settings.rating)
        let author = LobbyAuthor(gamePlayerID: GamePlayerID(player.gamePlayerID), nickname: rated?.displayName ?? player.alias,
                                 rating: Rating(value: rating.displayed, isProvisional: rating.isProvisional), chip: await chip(player))
        func notSent() -> LobbyMessage {
            let number = state.withLock { state in
                state.unsent += 1
                return state.unsent
            }
            return LobbyMessage(id: MessageID("unsent-\(number)"), kind: .post(LobbyPost(author: author, body: body, delivery: .notSent)))
        }
        guard readable, rated != nil else { return notSent() }
        // 5. The limits: hers, then the room's. From here the post has used her slot, sent or not.
        let time = now()
        if let wait = state.withLock({ takeSlot(id, &$0, at: time) }) { throw LobbyError.rateLimited(retryAfterSeconds: wait) }
        if case .text(let text) = body {
            // 6. The word list: always.
            if wordList.blocks(text) {
                state.withLock { state in
                    state.counters.blockedByWordList += 1
                    noteBlocked(id, &state, at: time)
                }
                return notSent()
            }
            // 7. The classifier, when there is one and it answers.
            switch await classifier?.screen(text) ?? .clean {
            case .clean: break
            case .flagged:
                state.withLock { state in
                    state.counters.blockedByClassifier += 1
                    noteBlocked(id, &state, at: time)
                }
                return notSent()
            case .unavailable(let why):
                state.withLock { $0.counters.classifierUnavailablePasses[why, default: 0] += 1 }
            }
        }
        // 8. Stored, then 9. told to the room.
        var line = StoredLobbyLine(kind: .quick, authorID: id, createdAt: now())
        line.author = .init(gamePlayerID: player.gamePlayerID, nickname: author.nickname, rating: author.rating.value,
                            isProvisional: author.rating.isProvisional, chipDeck: author.chip.deck.rawValue, chipSail: author.chip.sail.rawValue)
        switch body {
        case .text(let text):
            line.kind = .text
            line.body = text
        case .quickChat(let quick):
            line.quick = quick.rawValue
        }
        guard let sent = await commit(line) else { return notSent() }
        return sent.message
    }

    /// Her slot, if she may post at `time`; else how long to wait. Her cooldown, her interval, then the room.
    private func takeSlot(_ player: String, _ state: inout State, at time: Date) -> Int? {
        if let until = state.cooldownUntil[player] {
            if until > time { return max(1, Int(until.timeIntervalSince(time).rounded(.up))) }
            state.cooldownUntil[player] = nil
        }
        if let last = state.lastPost[player] {
            let left = settings.postInterval - time.timeIntervalSince(last)
            if left > 0 { return min(max(1, Int(left.rounded(.up))), max(1, Int(settings.postInterval.rounded(.up)))) }
        }
        if let at = state.roomAt {
            state.roomTokens = min(settings.roomBurst, state.roomTokens + max(0, time.timeIntervalSince(at)) * settings.roomPostsPerSecond)
        }
        state.roomAt = time
        guard state.roomTokens >= 1 else { return 1 }
        state.roomTokens -= 1
        state.lastPost[player] = time
        state.posts += 1
        if state.posts % 512 == 0 {
            // Nobody's limits outlive their use.
            let stale = time.addingTimeInterval(-settings.repeatWindow)
            state.lastPost = state.lastPost.filter { $0.value > stale }
            state.lastCooldown = state.lastCooldown.filter { $0.value > stale }
            state.blockedPosts = state.blockedPosts.filter { ($0.value.last ?? stale) > stale }
        }
        return nil
    }

    /// A post of hers was blocked by the filter (never by a failure): enough of them start a cooldown.
    private func noteBlocked(_ player: String, _ state: inout State, at time: Date) {
        let recent = (state.blockedPosts[player] ?? []).filter { time.timeIntervalSince($0) < settings.blockedPostWindow } + [time]
        guard recent.count >= settings.blockedPostsForCooldown else {
            state.blockedPosts[player] = recent
            return
        }
        state.blockedPosts[player] = nil
        let again = state.lastCooldown[player].map { time.timeIntervalSince($0) < settings.repeatWindow } ?? false
        state.cooldownUntil[player] = time.addingTimeInterval(again ? settings.repeatCooldown : settings.cooldown)
        state.lastCooldown[player] = time
    }

    // MARK: Blocks

    /// A player has a connection: the lobby can find her by her gamePlayerID.
    public func known(_ player: AccountPlayer) {
        state.withLock { state in
            if state.directory.count >= 100_000 { state.directory = [:] }
            state.directory[player.gamePlayerID] = LobbyPlayerRef(teamPlayerID: player.teamPlayerID, gamePlayerID: player.gamePlayerID,
                                                                  nickname: player.alias)
        }
    }

    private func resolve(_ gamePlayerID: String) async throws -> LobbyPlayerRef? {
        if let known = state.withLock({ $0.directory[gamePlayerID] }) { return known }
        let store = store
        return try await withDeadline(settings.storeDeadline) { try await store.player(gamePlayerID: gamePlayerID) }
    }

    /// Hides `target` and `player` from each other, stored. Her lines the player can see leave the player's feeds.
    /// Nothing for someone already blocked, or a gamePlayerID nobody has.
    public func block(_ target: GamePlayerID, by player: AccountPlayer) async throws {
        guard target.rawValue != player.gamePlayerID else { throw LobbyError.cannotBlockSelf }
        try await ensureLoaded()
        guard let other = try await resolve(target.rawValue) else { return }
        let id = player.teamPlayerID
        guard other.teamPlayerID != id else { throw LobbyError.cannotBlockSelf }
        let held = state.withLock { $0.blocks[id] ?? [] }
        guard !held.contains(other.teamPlayerID) else { return }
        // No wire error for a full list: an hour's wait says "not now" to a client that got here.
        guard held.count < settings.maxBlocksPerPlayer else { throw LobbyError.rateLimited(retryAfterSeconds: 3600) }
        let store = store, time = now()
        try await withDeadline(settings.storeDeadline) { try await store.block(other, by: id, at: time) }
        let cut: [Continuation] = state.withLock { state in
            state.blocks[id, default: []].insert(other.teamPlayerID)
            let oldest = time.addingTimeInterval(-TimeInterval(LobbyLimits.historySeconds))
            var cut: [Continuation] = []
            for line in state.ring where line.authorID == other.teamPlayerID && line.createdAt >= oldest {
                cut += deliver(.removed(line.message.id), &state, at: time) { feed, _ in feed.player == id }
            }
            return cut
        }
        for continuation in cut { continuation.finish() }
    }

    /// Her earlier lines show in the history again; the feed doesn't resend them.
    public func unblock(_ target: GamePlayerID, by player: AccountPlayer) async throws {
        try await ensureLoaded()
        guard let other = try await resolve(target.rawValue) else { return }
        let store = store, id = player.teamPlayerID
        try await withDeadline(settings.storeDeadline) { try await store.unblock(other.teamPlayerID, by: id) }
        state.withLock { state in
            state.blocks[id]?.remove(other.teamPlayerID)
            if state.blocks[id]?.isEmpty == true { state.blocks[id] = nil }
        }
    }

    public func blockedPlayers(of player: String) async throws -> [BlockedPlayer] {
        let store = store
        return try await withDeadline(settings.storeDeadline) { try await store.blockedPlayers(of: player) }
            .map { BlockedPlayer(gamePlayerID: GamePlayerID($0.gamePlayerID), nickname: $0.nickname) }
    }

    // MARK: Reports (#153 decides; the lobby checks what it knows)

    /// Reports a line she can see: not her own, not a system line. Moderation takes it (or refuses); then it is hidden
    /// from her at once.
    public func report(message: MessageID, by player: String) async throws {
        try await ensureLoaded()
        let time = now(), moderation = moderation
        if state.withLock({ $0.isSilenced(player, at: time, limit: settings.silenceLimit) }) { throw LobbyError.closed(.racing) }
        let hidden = try await withDeadline(settings.standingDeadline) { try await moderation.hiddenMessages(for: player) }
        guard let id = Int64(message.rawValue), !hidden.contains(id),
              let line = visibleLines(to: player, at: time).first(where: { $0.id == id }) else { throw LobbyError.unknownMessage }
        guard let author = line.authorID, author != player else { throw LobbyError.notReportable }
        let reported = ReportedLine(id: id, authorID: author, message: line.message, postedAt: line.createdAt)
        try await withDeadline(settings.standingDeadline) { try await moderation.report(line: reported, by: player) }
        let cut = state.withLock { state in deliver(.removed(message), &state, at: time) { feed, _ in feed.player == player } }
        for continuation in cut { continuation.finish() }
    }

    public func report(player target: GamePlayerID, by player: AccountPlayer) async throws {
        guard target.rawValue != player.gamePlayerID, let other = try await resolve(target.rawValue) else { throw LobbyError.notReportable }
        let moderation = moderation, id = player.teamPlayerID
        try await withDeadline(settings.standingDeadline) { try await moderation.report(player: other, by: id) }
    }

    public func report(race: RaceID, seat: Int, reason: RaceReportReason, by player: String) async throws {
        let moderation = moderation
        try await withDeadline(settings.standingDeadline) { try await moderation.report(race: race, seat: seat, reason: reason, by: player) }
    }

    // MARK: Taking lines down (#153, #160)

    /// Takes lines down for everyone (an upheld report): marked in the store, gone from the history, `.removed` on
    /// every feed. No stub is left.
    public func remove(ids: [Int64], reason: String) async throws {
        let store = store, time = now()
        drop(try await withDeadline(settings.storeDeadline) { try await store.remove(ids: ids, reason: reason, at: time) })
    }

    /// Takes down every line `playerID` posted.
    public func remove(allOf playerID: String, reason: String) async throws {
        let store = store, time = now()
        drop(try await withDeadline(settings.storeDeadline) { try await store.removeAll(of: playerID, reason: reason, at: time) })
    }

    /// The retention prune (#28: 30 days; #160 schedules it). Returns how many lines the store deleted.
    @discardableResult
    public func prune(before time: Date) async throws -> Int {
        let store = store
        let count = try await withDeadline(settings.storeDeadline) { try await store.prune(before: time) }
        state.withLock { $0.ring.removeAll { $0.createdAt < time } }
        return count
    }

    /// Deletes what the lobby holds of the player (#160): her lines and the winner's lines naming her (taken off every
    /// feed), the blocks she made, her limits; her feeds end. Blocks against her stay.
    public func deleteAll(of playerID: String) async throws {
        let store = store
        let ids = try await withDeadline(settings.storeDeadline) { try await store.deleteAll(of: playerID) }
        drop(ids)
        let ended: [Continuation] = state.withLock { state in
            // Whatever of hers the ring still held (a line stored a moment ago).
            state.ring.removeAll { $0.authorID == playerID || $0.subjectID == playerID }
            state.blocks[playerID] = nil
            state.unlocked.remove(playerID)
            state.silenced[playerID] = nil
            state.directory = state.directory.filter { $0.value.teamPlayerID != playerID }
            for key in [playerID] {
                state.lastPost[key] = nil
                state.blockedPosts[key] = nil
                state.cooldownUntil[key] = nil
                state.lastCooldown[key] = nil
                state.epochs[key] = nil
            }
            let hers = state.feeds.filter { $0.value.player == playerID }
            for key in hers.keys { state.feeds[key] = nil }
            return hers.values.map(\.continuation)
        }
        for continuation in ended { continuation.finish() }
    }

    private func drop(_ ids: [Int64]) {
        let gone = Set(ids), time = now()
        let cut: [Continuation] = state.withLock { state in
            let shown = state.ring.filter { gone.contains($0.id) }
            state.ring.removeAll { gone.contains($0.id) }
            return shown.flatMap { deliver(.removed($0.message.id), &state, at: time) }
        }
        for continuation in cut { continuation.finish() }
    }

    // MARK: The silence window and the system lines

    public func fleetLocked(race: UUID, humans: [String]) {
        let time = now()
        state.withLock { state in
            for player in humans { state.silenced[player] = (race, time) }
        }
        Task { await self.refresh(players: humans) }
    }

    public func finished(race: UUID, player: String) { release(race, [player]) }
    public func left(race: UUID, player: String) { release(race, [player]) }
    public func raceEnded(race: UUID, players: [String]) { release(race, players, always: true) }

    /// Ends `race`'s silence for `players`, and tells their feeds. `always`: tells them even if they weren't silent
    /// (a close may have unlocked free text).
    private func release(_ race: UUID, _ players: [String], always: Bool = false) {
        let freed = state.withLock { state in
            players.filter { player in
                guard state.silenced[player]?.race == race else { return always && state.silenced[player] == nil }
                state.silenced[player] = nil
                return true
            }
        }
        if !freed.isEmpty { Task { await self.refresh(players: freed) } }
    }

    /// The leak guard: a silence older than `silenceLimit` is over, whatever became of its race.
    private func expireSilences() {
        let time = now()
        let expired = state.withLock { state in
            let expired = state.silenced.filter { time.timeIntervalSince($0.value.since) >= settings.silenceLimit }.map(\.key)
            for player in expired { state.silenced[player] = nil }
            return expired
        }
        if !expired.isEmpty { Task { await self.refresh(players: expired) } }
    }

    /// Whether `player` is in the silence window now.
    public func isSilenced(_ player: String) -> Bool {
        state.withLock { $0.isSilenced(player, at: now(), limit: settings.silenceLimit) }
    }

    public func gun(race: UUID, venue: String, boats: Int, humans: Int) {
        guard humans > 0 else { return }
        _ = enqueue(StoredLobbyLine(kind: .gun, venue: venue, boats: boats, humans: humans, createdAt: now()), bounded: false)
    }

    public func winner(race: UUID, venue: String, nickname: String, playerID: String) {
        _ = enqueue(StoredLobbyLine(kind: .winner, subjectID: playerID, venue: venue, winnerName: nickname, createdAt: now()), bounded: false)
    }

    /// Everything committed so far has been stored and told (or refused): for tests and the dev arrangements.
    public func settled() async {
        await state.withLock { $0.tail }?.value
    }

    // MARK: Shutdown and dev

    /// Server shutdown: every feed ends, and nothing more is stored.
    public func finish() {
        let ended = state.withLock { state in
            state.finished = true
            defer { state.feeds = [:] }
            return state.feeds.values.map(\.continuation)
        }
        for continuation in ended { continuation.finish() }
    }

    /// Dev only (`POST /dev/situation`): free text is unlocked for `player` without a race.
    public func devUnlock(_ player: String) { unlock(player) }

    /// Dev only: a line by `player`, past the limits and the filter.
    public func devPost(_ text: String, by player: AccountPlayer) async {
        let chip = await chip(player)
        var line = StoredLobbyLine(kind: .text, authorID: player.teamPlayerID, body: text, createdAt: now())
        line.author = .init(gamePlayerID: player.gamePlayerID, nickname: player.alias, rating: PlayerRating(settings.rating).displayed,
                            isProvisional: true, chipDeck: chip.deck.rawValue, chipSail: chip.sail.rawValue)
        known(player)
        _ = await commit(line, bounded: false)
    }

    /// Dev only: `then` runs once, after `player`'s next feed has said its first words.
    public func devAfterNextFeed(of player: String, _ then: @escaping @Sendable () async -> Void) {
        state.withLock { $0.onPrimed[player] = then }
    }
}
