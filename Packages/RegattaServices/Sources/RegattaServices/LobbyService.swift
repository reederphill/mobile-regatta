// The one global lobby (#17, #34): a chat feed on the home screen, readable by anyone signed in who has accepted
// the terms, with free text through a server-side filter and a quick-chat row. No chat from fleet lock until the
// player finishes. Block and report on a long-press; reports go to an admin queue reviewed within 24 h.

/// A lobby message, opaque here.
public struct MessageID: Hashable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// Who posted a line, as the lobby shows them: the Game Center nickname as it is, the rating with its provisional
/// badge, and the livery chip (#17, #21).
public struct LobbyAuthor: Equatable, Sendable {
    public var gamePlayerID: GamePlayerID
    public var nickname: String
    public var rating: Rating
    public var chip: LiveryChip

    public init(gamePlayerID: GamePlayerID, nickname: String, rating: Rating, chip: LiveryChip) {
        self.gamePlayerID = gamePlayerID
        self.nickname = nickname
        self.rating = rating
        self.chip = chip
    }
}

/// The quick-chat row: posted with one tap, open from a player's first visit (#17).
public enum QuickChat: String, CaseIterable, Sendable {
    case gg
    case goodRace
    case oneMore
    case wave

    /// What the line reads.
    public var text: String {
        switch self {
        case .gg: "gg"
        case .goodRace: "good race"
        case .oneMore: "one more?"
        case .wave: "👋⛵"
        }
    }
}

public enum PostBody: Equatable, Sendable {
    /// Free text as the filter passed it: links, email addresses and phone numbers stripped.
    case text(String)
    case quickChat(QuickChat)
}

public enum Delivery: Equatable, Sendable {
    case sent
    /// The filter blocked it: only the sender sees it, greyed out and marked "not sent" (#17). No masking.
    case notSent
}

/// A player's line.
public struct LobbyPost: Equatable, Sendable {
    public var author: LobbyAuthor
    public var body: PostBody
    public var delivery: Delivery

    public init(author: LobbyAuthor, body: PostBody, delivery: Delivery = .sent) {
        self.author = author
        self.body = body
        self.delivery = delivery
    }
}

/// A line the server posts, styled apart, never filtered or reported (#17). Only these two kinds.
public enum SystemLine: Equatable, Sendable {
    /// A race's gun.
    case gun(venue: String, boats: Int, humans: Int)
    /// A race's winner, at the close.
    case winner(venue: String, nickname: String)
}

public struct LobbyMessage: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case post(LobbyPost)
        case system(SystemLine)
    }

    public var id: MessageID
    public var kind: Kind

    public init(id: MessageID, kind: Kind) {
        self.id = id
        self.kind = kind
    }

    public var post: LobbyPost? {
        if case .post(let post) = kind { post } else { nil }
    }
}

/// Why the lobby is closed to the player.
public enum LobbyClosure: Hashable, Sendable {
    /// Game Center has no player: "Sign in to Game Center to chat" (#25).
    case notSignedIn
    /// "Accept the terms to chat and race online" (#34).
    case termsNotAccepted
    /// Game Center's `isUnderage` or `isPersonalizedCommunicationRestricted` (#17, #34): the player never sees
    /// chat or quick-chat; the home screen shows the queued count and the leaderboard instead.
    case communicationRestricted
    /// The silence window: from the player's fleet lock until she finishes (#17). No reading or posting.
    case racing
}

public enum LobbyAccess: Hashable, Sendable {
    case open
    case closed(LobbyClosure)
}

/// Where the player stands under the chat penalties (#17). Chat penalties never touch racing, and a muted player
/// is always told: no shadow-mutes.
public enum ChatStanding: Equatable, Sendable {
    case clear
    /// A 24 h or 7-day mute, or the automatic 24 h mute after reports from 3 players within 24 h, until a review.
    /// `until` is seconds since the epoch.
    case muted(until: Int64, isAutomatic: Bool)
    /// A permanent chat ban.
    case banned
}

/// The lobby as the player sees it now.
public struct LobbyState: Equatable, Sendable {
    public var access: LobbyAccess
    /// Free text unlocks after one completed online race (finished, by distance, DSQ or OCS; never RET or a
    /// cancelled race, #17 G6). Quick-chat is open before it.
    public var canPostFreeText: Bool
    public var standing: ChatStanding

    public init(access: LobbyAccess, canPostFreeText: Bool, standing: ChatStanding = .clear) {
        self.access = access
        self.canPostFreeText = canPostFreeText
        self.standing = standing
    }
}

/// One item of the lobby feed.
public enum LobbyEvent: Equatable, Sendable {
    /// The lobby's state: first, then at each change (a mute notice, the silence window starting or ending,
    /// free text unlocking).
    case state(LobbyState)
    /// A new line.
    case message(LobbyMessage)
    /// A line to take down: an upheld report removed it for everyone, the player reported it, or its author is
    /// now blocked.
    case removed(MessageID)
}

/// Why a player reports another's racing, from a results row (#26).
public enum RaceReportReason: Hashable, Sendable {
    case unsportingConduct
    case suspectedCheating
}

/// A player on the blocked list in Settings.
public struct BlockedPlayer: Equatable, Sendable {
    public var gamePlayerID: GamePlayerID
    public var nickname: String

    public init(gamePlayerID: GamePlayerID, nickname: String) {
        self.gamePlayerID = gamePlayerID
        self.nickname = nickname
    }
}

public enum LobbyError: Error, Equatable, Sendable {
    /// The lobby is closed to the player: reading and posting both.
    case closed(LobbyClosure)
    /// Free text before the player's first completed online race.
    case freeTextLocked
    /// Nothing to post once trimmed.
    case empty
    /// Over `LobbyLimits.maxCharacters`.
    case tooLong(limit: Int)
    /// One message every `LobbyLimits.secondsBetweenPosts`, and a short cooldown after repeated blocked messages.
    case rateLimited(retryAfterSeconds: Int)
    case muted(until: Int64)
    case banned
    /// No such message in the lobby the player can see.
    case unknownMessage
    /// The player's own message or seat, a system line, or a bot's seat (bots can't be reported, #26).
    case notReportable
    /// Blocking yourself.
    case cannotBlockSelf
}

public enum LobbyLimits {
    /// The history holds the last 50 messages or the last hour, whichever is fewer (#17).
    public static let historyCount = 50
    public static let historySeconds = 3600
    public static let maxCharacters = 200
    public static let secondsBetweenPosts = 3
}

public protocol LobbyService: Sendable {
    /// The lobby's state now, and whether free text is unlocked.
    func state() async throws -> LobbyState
    /// The lines the lobby shows on opening, oldest first: at most `LobbyLimits.historyCount`, none older than
    /// `historySeconds`. Excludes lines the player reported and lines to or from players either has blocked.
    /// Throws `LobbyError.closed` when the lobby is closed.
    func history() async throws -> [LobbyMessage]
    /// The feed: the state now, then lines and changes as they come, for as long as the stream is held. A blocked
    /// player's new lines never arrive on it.
    func feed() -> AsyncStream<LobbyEvent>
    /// Posts free text, returned as the filter left it and as the player sees it (`Delivery.notSent` when it was
    /// blocked). A refused post doesn't count against the rate limit.
    func post(_ text: String) async throws -> LobbyMessage
    /// Posts a quick-chat line: open before free text unlocks, but not to a muted or banned player.
    func post(_ quickChat: QuickChat) async throws -> LobbyMessage

    /// Blocks a player: stored on the server by player ID, hiding chat both ways, with no effect on matchmaking.
    /// Blocking someone already blocked changes nothing. Their lines leave the feed as `.removed`.
    func block(_ player: GamePlayerID) async throws
    /// Unblocks a player: their earlier lines show in `history()` again (the feed doesn't resend them).
    func unblock(_ player: GamePlayerID) async throws
    /// The blocked list, for Settings.
    func blockedPlayers() async throws -> [BlockedPlayer]

    /// Reports a line: hidden from the player at once (#34), and queued for review.
    func report(message: MessageID) async throws
    /// Reports a player, for their chat or a bad nickname (#34).
    func report(player: GamePlayerID) async throws
    /// Reports another human's racing in a race the player sailed, by seat, from the results screen (#26).
    func report(race: RaceID, seat: Int, reason: RaceReportReason) async throws
}
