// The lobby on the wire (#17, #34, #241): its state and mute notices, the history, the feed, posting free text and
// quick-chat, blocking and reporting.

/// Who posted a line: Game Center nickname, rating and the livery chip's deck and sail swatches (#17, #21).
public struct WireLobbyAuthor: Equatable, Sendable {
    public var gamePlayerID: String
    public var nickname: String
    public var rating: WireRating
    public var deck: String
    public var sail: String

    public init(gamePlayerID: String, nickname: String, rating: WireRating, deck: String, sail: String) {
        self.gamePlayerID = gamePlayerID
        self.nickname = nickname
        self.rating = rating
        self.deck = deck
        self.sail = sail
    }

    func encode(to w: inout WireWriter) throws {
        try w.text(gamePlayerID, "gamePlayerID")
        try w.text(nickname, "nickname")
        rating.encode(to: &w)
        try w.text(deck, "deck")
        try w.text(sail, "sail")
    }

    init(from r: inout WireReader) throws {
        self.init(gamePlayerID: try r.text("gamePlayerID"), nickname: try r.text("nickname"), rating: try WireRating(from: &r),
                  deck: try r.text("deck"), sail: try r.text("sail"))
    }
}

/// The quick-chat row (#17).
public enum WireQuickChat: UInt8, Equatable, Sendable, CaseIterable {
    case gg
    case goodRace
    case oneMore
    case wave
}

public enum WirePostBody: Equatable, Sendable {
    case text(String)
    case quickChat(WireQuickChat)
}

/// Why a player reports another's racing (#26).
public enum WireRaceReportReason: UInt8, Equatable, Sendable, CaseIterable {
    case unsportingConduct
    case suspectedCheating
}

/// A lobby line: a player's post or a system line.
public struct WireLobbyMessage: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// `isSent` false: the filter blocked it, and only its author sees it (#17).
        case post(author: WireLobbyAuthor, body: WirePostBody, isSent: Bool)
        case gun(venue: String, boats: Int, humans: Int)
        case winner(venue: String, nickname: String)
    }

    public var id: String
    public var kind: Kind

    public init(id: String, kind: Kind) {
        self.id = id
        self.kind = kind
    }

    func encode(to w: inout WireWriter) throws {
        try w.text(id, "messageID")
        switch kind {
        case .post(let author, let body, let isSent):
            switch body {
            case .text(let text):
                w.u8(0)
                try w.string(text, limit: ServiceWireLimit.postText, "text")
            case .quickChat(let quick):
                w.u8(1)
                w.u8(quick.rawValue)
            }
            try author.encode(to: &w)
            w.bool(isSent)
        case .gun(let venue, let boats, let humans):
            w.u8(2)
            try w.text(venue, "venue")
            w.int(boats)
            w.int(humans)
        case .winner(let venue, let nickname):
            w.u8(3)
            try w.text(venue, "venue")
            try w.text(nickname, "nickname")
        }
    }

    init(from r: inout WireReader) throws {
        let id = try r.text("messageID")
        switch try r.u8() {
        case 0:
            let text = try r.string(limit: ServiceWireLimit.postText, "text")
            self.init(id: id, kind: .post(author: try WireLobbyAuthor(from: &r), body: .text(text), isSent: try r.bool("isSent")))
        case 1:
            let quick: WireQuickChat = try r.code("quickChat")
            self.init(id: id, kind: .post(author: try WireLobbyAuthor(from: &r), body: .quickChat(quick), isSent: try r.bool("isSent")))
        case 2: self.init(id: id, kind: .gun(venue: try r.text("venue"), boats: try r.int("boats"), humans: try r.int("humans")))
        case 3: self.init(id: id, kind: .winner(venue: try r.text("venue"), nickname: try r.text("nickname")))
        default: throw WireError.invalidValue("lobbyMessage")
        }
    }
}

/// Why the lobby is closed to the player.
public enum WireLobbyClosure: UInt8, Equatable, Sendable, CaseIterable {
    case notSignedIn
    case termsNotAccepted
    case communicationRestricted
    case racing
}

/// Where the player stands under the chat penalties (#17): the mute notice.
public enum WireChatStanding: Equatable, Sendable {
    case clear
    /// Seconds since the epoch.
    case muted(until: Int64, isAutomatic: Bool)
    case banned
}

public struct WireLobbyState: Equatable, Sendable {
    /// Nil when the lobby is open.
    public var closure: WireLobbyClosure?
    public var canPostFreeText: Bool
    public var standing: WireChatStanding

    public init(closure: WireLobbyClosure?, canPostFreeText: Bool, standing: WireChatStanding) {
        self.closure = closure
        self.canPostFreeText = canPostFreeText
        self.standing = standing
    }

    func encode(to w: inout WireWriter) {
        w.optional(closure) { $0.u8($1.rawValue) }
        w.bool(canPostFreeText)
        switch standing {
        case .clear: w.u8(0)
        case .muted(let until, let isAutomatic):
            w.u8(1)
            w.int64(until)
            w.bool(isAutomatic)
        case .banned: w.u8(2)
        }
    }

    init(from r: inout WireReader) throws {
        let closure: WireLobbyClosure? = try r.optional("closure") { try $0.code("closure") }
        let canPostFreeText = try r.bool("canPostFreeText")
        let standing: WireChatStanding
        switch try r.u8() {
        case 0: standing = .clear
        case 1: standing = .muted(until: try r.int64("until"), isAutomatic: try r.bool("isAutomatic"))
        case 2: standing = .banned
        default: throw WireError.invalidValue("standing")
        }
        self.init(closure: closure, canPostFreeText: canPostFreeText, standing: standing)
    }
}

/// One item of the feed.
public enum WireLobbyEvent: Equatable, Sendable {
    case state(WireLobbyState)
    case message(WireLobbyMessage)
    case removed(messageID: String)
}

public struct WireBlockedPlayer: Equatable, Sendable {
    public var gamePlayerID: String
    public var nickname: String

    public init(gamePlayerID: String, nickname: String) {
        self.gamePlayerID = gamePlayerID
        self.nickname = nickname
    }
}

public enum WireLobbyError: Equatable, Sendable {
    case closed(WireLobbyClosure)
    case freeTextLocked
    case empty
    case tooLong(limit: Int)
    case rateLimited(retryAfterSeconds: Int)
    case muted(until: Int64)
    case banned
    case unknownMessage
    case notReportable
    case cannotBlockSelf
}

public enum LobbyCall: Equatable, Sendable {
    case state
    case history
    /// Opens the feed: no reply; `StreamNext` reads it.
    case openFeed
    case postText(String)
    case postQuickChat(WireQuickChat)
    case block(gamePlayerID: String)
    case unblock(gamePlayerID: String)
    case blockedPlayers
    case reportMessage(messageID: String)
    case reportPlayer(gamePlayerID: String)
    case reportRace(raceID: String, seat: Int, reason: WireRaceReportReason)

    func encode(to w: inout WireWriter) throws {
        switch self {
        case .state: w.u8(0)
        case .history: w.u8(1)
        case .openFeed: w.u8(2)
        case .postText(let text):
            w.u8(3)
            try w.string(text, limit: ServiceWireLimit.postText, "text")
        case .postQuickChat(let quick):
            w.u8(4)
            w.u8(quick.rawValue)
        case .block(let id):
            w.u8(5)
            try w.text(id, "gamePlayerID")
        case .unblock(let id):
            w.u8(6)
            try w.text(id, "gamePlayerID")
        case .blockedPlayers: w.u8(7)
        case .reportMessage(let id):
            w.u8(8)
            try w.text(id, "messageID")
        case .reportPlayer(let id):
            w.u8(9)
            try w.text(id, "gamePlayerID")
        case .reportRace(let raceID, let seat, let reason):
            w.u8(10)
            try w.text(raceID, "raceID")
            try w.index(seat, "seat")
            w.u8(reason.rawValue)
        }
    }

    init(from r: inout WireReader) throws {
        switch try r.u8() {
        case 0: self = .state
        case 1: self = .history
        case 2: self = .openFeed
        case 3: self = .postText(try r.string(limit: ServiceWireLimit.postText, "text"))
        case 4: self = .postQuickChat(try r.code("quickChat"))
        case 5: self = .block(gamePlayerID: try r.text("gamePlayerID"))
        case 6: self = .unblock(gamePlayerID: try r.text("gamePlayerID"))
        case 7: self = .blockedPlayers
        case 8: self = .reportMessage(messageID: try r.text("messageID"))
        case 9: self = .reportPlayer(gamePlayerID: try r.text("gamePlayerID"))
        case 10: self = .reportRace(raceID: try r.text("raceID"), seat: try r.index(), reason: try r.code("reason"))
        default: throw WireError.invalidValue("lobbyCall")
        }
    }
}

public enum LobbyResult: Equatable, Sendable {
    case state(WireLobbyState)
    case history([WireLobbyMessage])
    /// An item of the feed.
    case event(WireLobbyEvent)
    /// A post as the player sees it.
    case posted(WireLobbyMessage)
    /// A block, unblock or report went through.
    case done
    case blockedPlayers([WireBlockedPlayer])
    case failure(WireLobbyError)

    func encode(to w: inout WireWriter) throws {
        switch self {
        case .state(let state):
            w.u8(0)
            state.encode(to: &w)
        case .history(let messages):
            w.u8(1)
            try w.list(messages, limit: WireLimit.list, "history") { try $1.encode(to: &$0) }
        case .event(.state(let state)):
            w.u8(2)
            state.encode(to: &w)
        case .event(.message(let message)):
            w.u8(3)
            try message.encode(to: &w)
        case .event(.removed(let id)):
            w.u8(4)
            try w.text(id, "messageID")
        case .posted(let message):
            w.u8(5)
            try message.encode(to: &w)
        case .done: w.u8(6)
        case .blockedPlayers(let players):
            w.u8(7)
            try w.list(players, limit: WireLimit.list, "blockedPlayers") { w, player in
                try w.text(player.gamePlayerID, "gamePlayerID")
                try w.text(player.nickname, "nickname")
            }
        case .failure(let error):
            w.u8(8)
            switch error {
            case .closed(let closure):
                w.u8(0)
                w.u8(closure.rawValue)
            case .freeTextLocked: w.u8(1)
            case .empty: w.u8(2)
            case .tooLong(let limit):
                w.u8(3)
                w.int(limit)
            case .rateLimited(let seconds):
                w.u8(4)
                w.int(seconds)
            case .muted(let until):
                w.u8(5)
                w.int64(until)
            case .banned: w.u8(6)
            case .unknownMessage: w.u8(7)
            case .notReportable: w.u8(8)
            case .cannotBlockSelf: w.u8(9)
            }
        }
    }

    init(from r: inout WireReader) throws {
        switch try r.u8() {
        case 0: self = .state(try WireLobbyState(from: &r))
        case 1: self = .history(try r.list(limit: WireLimit.list, "history") { try WireLobbyMessage(from: &$0) })
        case 2: self = .event(.state(try WireLobbyState(from: &r)))
        case 3: self = .event(.message(try WireLobbyMessage(from: &r)))
        case 4: self = .event(.removed(messageID: try r.text("messageID")))
        case 5: self = .posted(try WireLobbyMessage(from: &r))
        case 6: self = .done
        case 7:
            self = .blockedPlayers(try r.list(limit: WireLimit.list, "blockedPlayers") {
                WireBlockedPlayer(gamePlayerID: try $0.text("gamePlayerID"), nickname: try $0.text("nickname"))
            })
        case 8:
            let error: WireLobbyError
            switch try r.u8() {
            case 0: error = .closed(try r.code("closure"))
            case 1: error = .freeTextLocked
            case 2: error = .empty
            case 3: error = .tooLong(limit: try r.int("limit"))
            case 4: error = .rateLimited(retryAfterSeconds: try r.int("retryAfterSeconds"))
            case 5: error = .muted(until: try r.int64("until"))
            case 6: error = .banned
            case 7: error = .unknownMessage
            case 8: error = .notReportable
            case 9: error = .cannotBlockSelf
            default: throw WireError.invalidValue("lobbyError")
            }
            self = .failure(error)
        default: throw WireError.invalidValue("lobbyResult")
        }
    }
}
