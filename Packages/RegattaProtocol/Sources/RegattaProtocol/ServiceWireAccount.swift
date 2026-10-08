import RegattaCore

// Identity and terms, the queue (#109), the profile, analytics and data deletion (#241) on the wire. Each call and
// result starts with a one-byte code, in the order the cases are declared: fixed for good, a new case takes the
// next code.

// MARK: - Identity

/// A signed-in Game Center player and the restrictions Game Center reports (#16, #34).
public struct WirePlayer: Equatable, Sendable {
    public var gamePlayerID: String
    public var alias: String
    public var isUnderage: Bool
    public var isPersonalizedCommunicationRestricted: Bool
    public var isMultiplayerGamingRestricted: Bool

    public init(gamePlayerID: String, alias: String, isUnderage: Bool, isPersonalizedCommunicationRestricted: Bool,
                isMultiplayerGamingRestricted: Bool) {
        self.gamePlayerID = gamePlayerID
        self.alias = alias
        self.isUnderage = isUnderage
        self.isPersonalizedCommunicationRestricted = isPersonalizedCommunicationRestricted
        self.isMultiplayerGamingRestricted = isMultiplayerGamingRestricted
    }

    // The restrictions are one byte of flags: bit 0 underage, 1 communication, 2 multiplayer; the rest are 0.
    func encode(to w: inout WireWriter) throws {
        try w.text(gamePlayerID, "gamePlayerID")
        try w.text(alias, "alias")
        w.u8((isUnderage ? 1 : 0) | (isPersonalizedCommunicationRestricted ? 2 : 0) | (isMultiplayerGamingRestricted ? 4 : 0))
    }

    init(from r: inout WireReader) throws {
        let id = try r.text("gamePlayerID"), alias = try r.text("alias")
        let flags = try r.u8()
        guard flags & ~0b111 == 0 else { throw WireError.invalidValue("restrictions") }
        self.init(gamePlayerID: id, alias: alias, isUnderage: flags & 1 != 0,
                  isPersonalizedCommunicationRestricted: flags & 2 != 0, isMultiplayerGamingRestricted: flags & 4 != 0)
    }
}

/// What Game Center signed for the server to check the player's id (#16, #145): the signature covers the
/// `teamPlayerID` (with the bundle id, the timestamp and the salt); the `gamePlayerID` rides along unsigned.
public struct WireIdentitySignature: Equatable, Sendable {
    public var gamePlayerID: String
    public var teamPlayerID: String
    public var publicKeyURL: String
    public var signature: [UInt8]
    public var salt: [UInt8]
    public var timestamp: UInt64

    public init(gamePlayerID: String, teamPlayerID: String, publicKeyURL: String, signature: [UInt8], salt: [UInt8], timestamp: UInt64) {
        self.gamePlayerID = gamePlayerID
        self.teamPlayerID = teamPlayerID
        self.publicKeyURL = publicKeyURL
        self.signature = signature
        self.salt = salt
        self.timestamp = timestamp
    }

    func encode(to w: inout WireWriter) throws {
        try w.text(gamePlayerID, "gamePlayerID")
        try w.text(teamPlayerID, "teamPlayerID")
        try w.string(publicKeyURL, limit: WireLimit.token, "publicKeyURL")
        try w.blob(signature, limit: WireLimit.token, "signature")
        try w.blob(salt, limit: WireLimit.token, "salt")
        w.u64(timestamp)
    }

    init(from r: inout WireReader) throws {
        self.init(gamePlayerID: try r.text("gamePlayerID"), teamPlayerID: try r.text("teamPlayerID"), publicKeyURL: try r.string(limit: WireLimit.token, "publicKeyURL"),
                  signature: try r.blob(limit: WireLimit.token, "signature"), salt: try r.blob(limit: WireLimit.token, "salt"),
                  timestamp: try r.u64())
    }
}

public enum IdentityCall: UInt8, Equatable, Sendable, CaseIterable {
    case state
    /// Opens the stream of Game Center's state (#314): no reply; `StreamNext` reads it.
    case openStateUpdates
    case gamePlayerID
    case identitySignature
    case signIn

    func encode(to w: inout WireWriter) throws { w.u8(rawValue) }
    init(from r: inout WireReader) throws { self = try r.code("identityCall") }
}

public enum IdentityResult: Equatable, Sendable {
    /// Game Center's state, nil signed out: for `state`, `signIn` and each item of the state stream.
    case state(WirePlayer?)
    case gamePlayerID(String?)
    case signature(WireIdentitySignature)
    case notSignedIn

    func encode(to w: inout WireWriter) throws {
        switch self {
        case .state(let player):
            w.u8(0)
            try w.optional(player) { try $1.encode(to: &$0) }
        case .gamePlayerID(let id):
            w.u8(1)
            try w.optional(id) { try $0.text($1, "gamePlayerID") }
        case .signature(let signature):
            w.u8(2)
            try signature.encode(to: &w)
        case .notSignedIn: w.u8(3)
        }
    }

    init(from r: inout WireReader) throws {
        switch try r.u8() {
        case 0: self = .state(try r.optional("player") { try WirePlayer(from: &$0) })
        case 1: self = .gamePlayerID(try r.optional("gamePlayerID") { try $0.text("gamePlayerID") })
        case 2: self = .signature(try WireIdentitySignature(from: &r))
        case 3: self = .notSignedIn
        default: throw WireError.invalidValue("identityResult")
        }
    }
}

// MARK: - Session

/// Opening the connection's signed-in session (#145). A connection starts signed out; until a session is open the
/// server answers identity as signed out and refuses every other service.
public enum SessionCall: Equatable, Sendable {
    /// Signs in with what Game Center signed, and the alias and restrictions Game Center reports now (taken from the
    /// client until #158's App Attest assertion covers the request). The player's `gamePlayerID` is the signature's.
    case signIn(signature: WireIdentitySignature, player: WirePlayer)
    /// Resumes the session `token` names, with the alias and restrictions Game Center reports now.
    case resume(token: [UInt8], player: WirePlayer)
    /// Ends the connection's session: its token stops working.
    case signOut

    func encode(to w: inout WireWriter) throws {
        switch self {
        case .signIn(let signature, let player):
            w.u8(0)
            try signature.encode(to: &w)
            try player.encode(to: &w)
        case .resume(let token, let player):
            w.u8(1)
            try w.blob(token, limit: WireLimit.token, "token")
            try player.encode(to: &w)
        case .signOut: w.u8(2)
        }
    }

    init(from r: inout WireReader) throws {
        switch try r.u8() {
        case 0: self = .signIn(signature: try WireIdentitySignature(from: &r), player: try WirePlayer(from: &r))
        case 1: self = .resume(token: try r.blob(limit: WireLimit.token, "token"), player: try WirePlayer(from: &r))
        case 2: self = .signOut
        default: throw WireError.invalidValue("sessionCall")
        }
    }
}

/// Why the server didn't open a session.
public enum WireSessionRefusal: UInt8, Equatable, Sendable, CaseIterable {
    /// The signature doesn't verify: a bad or untrusted certificate, the wrong bundle, a tampered field.
    case invalidSignature
    /// The signature's timestamp is outside the server's window: sign again.
    case staleSignature
    /// Another player is bound to this gamePlayerID, or this player to another one.
    case gamePlayerIDConflict
    /// The token names no live session (expired, signed out, or never issued): sign in.
    case sessionExpired
    /// The server can't open sessions now: try later.
    case unavailable
}

public enum SessionResult: Equatable, Sendable {
    /// The session is open: `token` resumes it on a later connection.
    case signedIn(token: [UInt8], player: WirePlayer)
    case refused(WireSessionRefusal)
    /// `signOut` went through.
    case signedOut

    func encode(to w: inout WireWriter) throws {
        switch self {
        case .signedIn(let token, let player):
            w.u8(0)
            try w.blob(token, limit: WireLimit.token, "token")
            try player.encode(to: &w)
        case .refused(let refusal):
            w.u8(1)
            w.u8(refusal.rawValue)
        case .signedOut: w.u8(2)
        }
    }

    init(from r: inout WireReader) throws {
        switch try r.u8() {
        case 0: self = .signedIn(token: try r.blob(limit: WireLimit.token, "token"), player: try WirePlayer(from: &r))
        case 1: self = .refused(try r.code("sessionRefusal"))
        case 2: self = .signedOut
        default: throw WireError.invalidValue("sessionResult")
        }
    }
}

// MARK: - Terms

public enum WireTermsStatus: Equatable, Sendable {
    case accepted(version: Int)
    case needsAcceptance(current: Int, lastAccepted: Int?)

    func encode(to w: inout WireWriter) {
        switch self {
        case .accepted(let version):
            w.u8(0)
            w.int(version)
        case .needsAcceptance(let current, let lastAccepted):
            w.u8(1)
            w.int(current)
            w.optional(lastAccepted) { $0.int($1) }
        }
    }

    init(from r: inout WireReader) throws {
        switch try r.u8() {
        case 0: self = .accepted(version: try r.int("version"))
        case 1: self = .needsAcceptance(current: try r.int("current"), lastAccepted: try r.optional("lastAccepted") { try $0.int("lastAccepted") })
        default: throw WireError.invalidValue("termsStatus")
        }
    }
}

public enum TermsCall: Equatable, Sendable {
    case status
    case accept(version: Int)

    func encode(to w: inout WireWriter) throws {
        switch self {
        case .status: w.u8(0)
        case .accept(let version):
            w.u8(1)
            w.int(version)
        }
    }

    init(from r: inout WireReader) throws {
        switch try r.u8() {
        case 0: self = .status
        case 1: self = .accept(version: try r.int("version"))
        default: throw WireError.invalidValue("termsCall")
        }
    }
}

public enum TermsResult: Equatable, Sendable {
    case status(WireTermsStatus)
    case staleVersion(current: Int)

    func encode(to w: inout WireWriter) throws {
        switch self {
        case .status(let status):
            w.u8(0)
            status.encode(to: &w)
        case .staleVersion(let current):
            w.u8(1)
            w.int(current)
        }
    }

    init(from r: inout WireReader) throws {
        switch try r.u8() {
        case 0: self = .status(try WireTermsStatus(from: &r))
        case 1: self = .staleVersion(current: try r.int("current"))
        default: throw WireError.invalidValue("termsResult")
        }
    }
}

// MARK: - Queue

/// Why the player can't queue now (#16, #26, #34).
public enum WireQueueRefusal: Equatable, Sendable {
    case notSignedIn
    case termsNotAccepted
    case multiplayerRestricted
    case cooldown(secondsRemaining: Int)
    /// Seconds since the epoch; nil for a permanent ban.
    case suspended(until: Int64?)
    case attestationFailed
    case updateRequired

    func encode(to w: inout WireWriter) {
        switch self {
        case .notSignedIn: w.u8(0)
        case .termsNotAccepted: w.u8(1)
        case .multiplayerRestricted: w.u8(2)
        case .cooldown(let seconds):
            w.u8(3)
            w.int(seconds)
        case .suspended(let until):
            w.u8(4)
            w.optional(until) { $0.int64($1) }
        case .attestationFailed: w.u8(5)
        case .updateRequired: w.u8(6)
        }
    }

    init(from r: inout WireReader) throws {
        switch try r.u8() {
        case 0: self = .notSignedIn
        case 1: self = .termsNotAccepted
        case 2: self = .multiplayerRestricted
        case 3: self = .cooldown(secondsRemaining: try r.int("secondsRemaining"))
        case 4: self = .suspended(until: try r.optional("until") { try $0.int64("until") })
        case 5: self = .attestationFailed
        case 6: self = .updateRequired
        default: throw WireError.invalidValue("refusal")
        }
    }
}

public enum WireQueueState: Equatable, Sendable {
    case idle
    case unavailable(WireQueueRefusal)
    case queued(queuedPlayers: Int, secondsToLock: Int)
    case fleetLocked

    func encode(to w: inout WireWriter) {
        switch self {
        case .idle: w.u8(0)
        case .unavailable(let refusal):
            w.u8(1)
            refusal.encode(to: &w)
        case .queued(let players, let seconds):
            w.u8(2)
            w.int(players)
            w.int(seconds)
        case .fleetLocked: w.u8(3)
        }
    }

    init(from r: inout WireReader) throws {
        switch try r.u8() {
        case 0: self = .idle
        case 1: self = .unavailable(try WireQueueRefusal(from: &r))
        case 2: self = .queued(queuedPlayers: try r.int("queuedPlayers"), secondsToLock: try r.int("secondsToLock"))
        case 3: self = .fleetLocked
        default: throw WireError.invalidValue("queueState")
        }
    }
}

public enum QueueCall: UInt8, Equatable, Sendable, CaseIterable {
    /// Opens the stream of the queue's state: no reply; `StreamNext` reads it.
    case openStateUpdates
    case join
    case leave

    func encode(to w: inout WireWriter) { w.u8(rawValue) }
    init(from r: inout WireReader) throws { self = try r.code("queueCall") }
}

public enum QueueResult: Equatable, Sendable {
    /// An item of the state stream.
    case state(WireQueueState)
    /// `join` or `leave` went through.
    case done
    case refused(WireQueueRefusal)
    case alreadyQueued
    case notQueued

    func encode(to w: inout WireWriter) throws {
        switch self {
        case .state(let state):
            w.u8(0)
            state.encode(to: &w)
        case .done: w.u8(1)
        case .refused(let refusal):
            w.u8(2)
            refusal.encode(to: &w)
        case .alreadyQueued: w.u8(3)
        case .notQueued: w.u8(4)
        }
    }

    init(from r: inout WireReader) throws {
        switch try r.u8() {
        case 0: self = .state(try WireQueueState(from: &r))
        case 1: self = .done
        case 2: self = .refused(try WireQueueRefusal(from: &r))
        case 3: self = .alreadyQueued
        case 4: self = .notQueued
        default: throw WireError.invalidValue("queueResult")
        }
    }
}

// MARK: - Profile

/// A design earned at a number of completed races (#21).
public struct WireMilestone: Equatable, Sendable {
    public var design: String
    public var completedRaces: Int

    public init(design: String, completedRaces: Int) {
        self.design = design
        self.completedRaces = completedRaces
    }
}

/// The player's online profile (#25, #21, #26).
public struct WireProfile: Equatable, Sendable {
    /// A racing suspension (#26).
    public enum Suspension: Equatable, Sendable {
        case until(Int64)
        case permanent
    }

    public var gamePlayerID: String
    public var nickname: String
    public var rating: WireRating
    public var completedRaces: Int
    public var wins: Int
    public var suspension: Suspension?
    /// Design ids, in milestone order.
    public var earned: [String]
    public var next: WireMilestone?
    public var livery: Livery

    public init(gamePlayerID: String, nickname: String, rating: WireRating, completedRaces: Int, wins: Int,
                suspension: Suspension?, earned: [String], next: WireMilestone?, livery: Livery) {
        self.gamePlayerID = gamePlayerID
        self.nickname = nickname
        self.rating = rating
        self.completedRaces = completedRaces
        self.wins = wins
        self.suspension = suspension
        self.earned = earned
        self.next = next
        self.livery = livery
    }

    func encode(to w: inout WireWriter) throws {
        try w.text(gamePlayerID, "gamePlayerID")
        try w.text(nickname, "nickname")
        rating.encode(to: &w)
        w.int(completedRaces)
        w.int(wins)
        switch suspension {
        case nil: w.u8(0)
        case .permanent: w.u8(1)
        case .until(let until):
            w.u8(2)
            w.int64(until)
        }
        try w.list(earned, limit: WireLimit.list, "earned") { try $0.text($1, "earned") }
        try w.optional(next) { w, next in
            try w.text(next.design, "next.design")
            w.int(next.completedRaces)
        }
        try livery.encode(to: &w)
    }

    init(from r: inout WireReader) throws {
        let id = try r.text("gamePlayerID"), nickname = try r.text("nickname")
        let rating = try WireRating(from: &r)
        let races = try r.int("completedRaces"), wins = try r.int("wins")
        let suspension: Suspension?
        switch try r.u8() {
        case 0: suspension = nil
        case 1: suspension = .permanent
        case 2: suspension = .until(try r.int64("until"))
        default: throw WireError.invalidValue("suspension")
        }
        let earned = try r.list(limit: WireLimit.list, "earned") { try $0.text("earned") }
        let next = try r.optional("next") { WireMilestone(design: try $0.text("next.design"), completedRaces: try $0.int("next.completedRaces")) }
        self.init(gamePlayerID: id, nickname: nickname, rating: rating, completedRaces: races, wins: wins, suspension: suspension,
                  earned: earned, next: next, livery: try Livery(from: &r))
    }
}

extension Livery {
    func encode(to w: inout WireWriter) throws {
        try w.text(design.rawValue, "design")
        try w.list(colours, limit: ServiceWireLimit.colours, "colours") { try $0.text($1.rawValue, "colour") }
        w.int(sailNumber)
    }

    init(from r: inout WireReader) throws {
        self.init(design: DesignID(try r.text("design")),
                  colours: try r.list(limit: ServiceWireLimit.colours, "colours") { SwatchID(try $0.text("colour")) },
                  sailNumber: try r.int("sailNumber"))
    }
}

/// What's wrong with a livery the player tried to store (#21).
public enum WireLiveryProblem: UInt8, Equatable, Sendable, CaseIterable {
    case sailNumber
    case slotCount
    case colour
    case unknownDesign
    case notOwned
}

public enum ProfileCall: Equatable, Sendable {
    case profile
    case saveLivery(Livery)

    func encode(to w: inout WireWriter) throws {
        switch self {
        case .profile: w.u8(0)
        case .saveLivery(let livery):
            w.u8(1)
            try livery.encode(to: &w)
        }
    }

    init(from r: inout WireReader) throws {
        switch try r.u8() {
        case 0: self = .profile
        case 1: self = .saveLivery(try Livery(from: &r))
        default: throw WireError.invalidValue("profileCall")
        }
    }
}

public enum ProfileResult: Equatable, Sendable {
    case profile(WireProfile)
    /// The livery as stored.
    case livery(Livery)
    case notSignedIn
    case invalidLivery(WireLiveryProblem)
    case liveryLocked

    func encode(to w: inout WireWriter) throws {
        switch self {
        case .profile(let profile):
            w.u8(0)
            try profile.encode(to: &w)
        case .livery(let livery):
            w.u8(1)
            try livery.encode(to: &w)
        case .notSignedIn: w.u8(2)
        case .invalidLivery(let problem):
            w.u8(3)
            w.u8(problem.rawValue)
        case .liveryLocked: w.u8(4)
        }
    }

    init(from r: inout WireReader) throws {
        switch try r.u8() {
        case 0: self = .profile(try WireProfile(from: &r))
        case 1: self = .livery(try Livery(from: &r))
        case 2: self = .notSignedIn
        case 3: self = .invalidLivery(try r.code("liveryProblem"))
        case 4: self = .liveryLocked
        default: throw WireError.invalidValue("profileResult")
        }
    }
}

// MARK: - Analytics

public enum WireAnalyticsValue: Equatable, Sendable {
    case int(Int64)
    /// Finite only.
    case double(Double)
    case string(String)
    case bool(Bool)
}

public struct WireAnalyticsProperty: Equatable, Sendable {
    public var key: String
    public var value: WireAnalyticsValue

    public init(key: String, value: WireAnalyticsValue) {
        self.key = key
        self.value = value
    }
}

public struct WireAnalyticsEvent: Equatable, Sendable {
    public var sequence: Int
    public var name: String
    /// Seconds since the epoch, by the device's clock.
    public var time: Int64
    /// In ascending order of their keys' UTF-8 bytes, each key once, so an event has one encoding.
    public var properties: [WireAnalyticsProperty]

    public init(sequence: Int, name: String, time: Int64, properties: [WireAnalyticsProperty]) {
        self.sequence = sequence
        self.name = name
        self.time = time
        self.properties = properties
    }

    /// Whether `a` sorts before `b` as `properties` keys do.
    public static func keyPrecedes(_ a: String, _ b: String) -> Bool { a.utf8.lexicographicallyPrecedes(b.utf8) }

    func encode(to w: inout WireWriter) throws {
        w.int(sequence)
        try w.text(name, "name")
        w.int64(time)
        guard zip(properties, properties.dropFirst()).allSatisfy({ Self.keyPrecedes($0.key, $1.key) }) else {
            throw WireError.outOfRange("properties")
        }
        try w.list(properties, limit: ServiceWireLimit.properties, "properties") { w, property in
            try w.text(property.key, "key")
            switch property.value {
            case .int(let v):
                w.u8(0)
                w.int64(v)
            case .double(let v):
                guard v.isFinite else { throw WireError.outOfRange("double") }
                w.u8(1)
                w.u64(v.bitPattern)
            case .string(let v):
                w.u8(2)
                try w.text(v, "string")
            case .bool(let v):
                w.u8(3)
                w.bool(v)
            }
        }
    }

    init(from r: inout WireReader) throws {
        let sequence = try r.int("sequence"), name = try r.text("name"), time = try r.int64("time")
        let properties = try r.list(limit: ServiceWireLimit.properties, "properties") { r in
            let key = try r.text("key")
            let value: WireAnalyticsValue
            switch try r.u8() {
            case 0: value = .int(try r.int64("int"))
            case 1:
                let v = Double(bitPattern: try r.u64())
                guard v.isFinite else { throw WireError.invalidValue("double") }
                value = .double(v)
            case 2: value = .string(try r.text("string"))
            case 3: value = .bool(try r.bool("bool"))
            default: throw WireError.invalidValue("analyticsValue")
            }
            return WireAnalyticsProperty(key: key, value: value)
        }
        guard zip(properties, properties.dropFirst()).allSatisfy({ Self.keyPrecedes($0.key, $1.key) }) else {
            throw WireError.invalidValue("properties")
        }
        self.init(sequence: sequence, name: name, time: time, properties: properties)
    }
}

/// The analytics request's body: one batch (#28). The service, not the codec, holds a batch to its size: the
/// codec carries up to `WireLimit.list` events, so an over-size batch reaches the server to be refused.
public struct WireAnalyticsBatch: Equatable, Sendable {
    public var installID: String
    public var events: [WireAnalyticsEvent]

    public init(installID: String, events: [WireAnalyticsEvent]) {
        self.installID = installID
        self.events = events
    }

    func encode(to w: inout WireWriter) throws {
        try w.text(installID, "installID")
        try w.list(events, limit: WireLimit.list, "events") { try $1.encode(to: &$0) }
    }

    init(from r: inout WireReader) throws {
        self.init(installID: try r.text("installID"), events: try r.list(limit: WireLimit.list, "events") { try WireAnalyticsEvent(from: &$0) })
    }
}

public enum AnalyticsResult: Equatable, Sendable {
    case receipt(accepted: Int, duplicates: Int)
    case batchTooLarge(max: Int)
    case unavailable

    func encode(to w: inout WireWriter) throws {
        switch self {
        case .receipt(let accepted, let duplicates):
            w.u8(0)
            w.int(accepted)
            w.int(duplicates)
        case .batchTooLarge(let max):
            w.u8(1)
            w.int(max)
        case .unavailable: w.u8(2)
        }
    }

    init(from r: inout WireReader) throws {
        switch try r.u8() {
        case 0: self = .receipt(accepted: try r.int("accepted"), duplicates: try r.int("duplicates"))
        case 1: self = .batchTooLarge(max: try r.int("max"))
        case 2: self = .unavailable
        default: throw WireError.invalidValue("analyticsResult")
        }
    }
}

// MARK: - Data deletion

/// What the server holds for a player online (#28).
public enum WireOnlineData: UInt8, Equatable, Sendable, CaseIterable {
    case profile
    case rating
    case livery
    case chatHistory
    case reportsFiled
    case leaderboardEntry
    case termsAcceptance
}

public struct WireDeletionPlan: Equatable, Sendable {
    /// Ascending by code, each once.
    public var deletes: [WireOnlineData]
    public var anonymisesRaceLogs: Bool
    public var confirmation: String

    public init(deletes: [WireOnlineData], anonymisesRaceLogs: Bool, confirmation: String) {
        self.deletes = deletes
        self.anonymisesRaceLogs = anonymisesRaceLogs
        self.confirmation = confirmation
    }

    // `deletes` is one byte, bit n for code n; bit 7 is 0.
    func encode(to w: inout WireWriter) throws {
        guard zip(deletes, deletes.dropFirst()).allSatisfy({ $0.rawValue < $1.rawValue }) else { throw WireError.outOfRange("deletes") }
        w.u8(deletes.reduce(0) { $0 | 1 << $1.rawValue })
        w.bool(anonymisesRaceLogs)
        try w.text(confirmation, "confirmation")
    }

    init(from r: inout WireReader) throws {
        let bits = try r.u8()
        guard bits & 0x80 == 0 else { throw WireError.invalidValue("deletes") }
        self.init(deletes: WireOnlineData.allCases.filter { bits & 1 << $0.rawValue != 0 },
                  anonymisesRaceLogs: try r.bool("anonymisesRaceLogs"), confirmation: try r.text("confirmation"))
    }
}

public enum DeletionCall: Equatable, Sendable {
    case plan
    case delete(confirmation: String)

    func encode(to w: inout WireWriter) throws {
        switch self {
        case .plan: w.u8(0)
        case .delete(let confirmation):
            w.u8(1)
            try w.text(confirmation, "confirmation")
        }
    }

    init(from r: inout WireReader) throws {
        switch try r.u8() {
        case 0: self = .plan
        case 1: self = .delete(confirmation: try r.text("confirmation"))
        default: throw WireError.invalidValue("deletionCall")
        }
    }
}

public enum DeletionResult: Equatable, Sendable {
    case plan(WireDeletionPlan)
    case deleted
    case notSignedIn
    case nothingToDelete
    case invalidConfirmation

    func encode(to w: inout WireWriter) throws {
        switch self {
        case .plan(let plan):
            w.u8(0)
            try plan.encode(to: &w)
        case .deleted: w.u8(1)
        case .notSignedIn: w.u8(2)
        case .nothingToDelete: w.u8(3)
        case .invalidConfirmation: w.u8(4)
        }
    }

    init(from r: inout WireReader) throws {
        switch try r.u8() {
        case 0: self = .plan(try WireDeletionPlan(from: &r))
        case 1: self = .deleted
        case 2: self = .notSignedIn
        case 3: self = .nothingToDelete
        case 4: self = .invalidConfirmation
        default: throw WireError.invalidValue("deletionResult")
        }
    }
}
