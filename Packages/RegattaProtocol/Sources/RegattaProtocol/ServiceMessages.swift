// The client's online services on the wire (#143): identity and terms, the queue and the race session (#109), the
// lobby, the profile, analytics and data deletion (#241), in frames like the race's (#63, #18), with codes from 64.
// Each service has a request type (client → server) and a reply type (server → client). A request's body starts
// with its id, a varint the client picks, unique among its requests in flight; the reply to it starts with the
// same id, so replies can come in any order. A reply to an id the client isn't waiting for is a protocol error.
//
// Streams (identity, queue, results, rating changes, the lobby feed) are opened by a call (`openStateUpdates`, say)
// that has no reply: the stream's id is that request's id. The client then asks for each item with `StreamNext`, one
// at a time, and the server answers it, when it has an item, with the service's reply carrying the item, or with
// `StreamEnd` once the stream is over. So a stream never runs ahead of its reader: a scripted fake plays one step
// per read, and a server holds a change until it is asked. `StreamClose` drops a stream the client no longer reads.
//
// The frame's `seq` counts the sender's service messages (`MessageType.Stream.other`); its `tick` is 0: services
// have no race clock. Values are the service's own, in protocol types (`Wire…`): the adapters in RegattaServices
// map them to and from the service types. Integers are zigzag varints unless they are seats (a byte) or ticks
// (int32); enum codes are fixed for good, and a decoder rejects codes it doesn't know.

/// The largest service frame either way, the transport's cap (#145): over the largest real message (a race report
/// with mark touches, about 16 MB; the lobby history, about 9.5 MB). An analytics batch over it is refused: the
/// client splits it.
public let serviceFrameLimit = 32 << 20

/// A call to a service: the id its reply echoes, and what is asked.
public struct ServiceRequest<Call: Equatable & Sendable>: Equatable, Sendable {
    public var id: UInt32
    public var call: Call

    public init(id: UInt32, call: Call) {
        self.id = id
        self.call = call
    }
}

/// A service's answer to the request with `id`, or an item of the stream a `StreamNext` with `id` asked for.
public struct ServiceReply<Result: Equatable & Sendable>: Equatable, Sendable {
    public var id: UInt32
    public var result: Result

    public init(id: UInt32, result: Result) {
        self.id = id
        self.result = result
    }
}

/// Client → server: send the next item of `stream` (the id of the request that opened it), answered under `id`.
public struct StreamNext: Equatable, Sendable {
    public var id: UInt32
    public var stream: UInt32

    public init(id: UInt32, stream: UInt32) {
        self.id = id
        self.stream = stream
    }
}

/// Client → server: the client no longer reads `stream`. No reply; a `StreamNext` waiting on it is answered `StreamEnd`.
public struct StreamClose: Equatable, Sendable {
    public var stream: UInt32

    public init(stream: UInt32) { self.stream = stream }
}

/// Server → client: the stream the `StreamNext` with `id` asked has no more items.
public struct StreamEnd: Equatable, Sendable {
    public var id: UInt32

    public init(id: UInt32) { self.id = id }
}

extension Message {
    /// The request id a server → client service message answers, nil for any other message.
    public var replyID: UInt32? {
        switch self {
        case .identityReply(let m): m.id
        case .termsReply(let m): m.id
        case .queueReply(let m): m.id
        case .raceSessionReply(let m): m.id
        case .lobbyReply(let m): m.id
        case .profileReply(let m): m.id
        case .analyticsReply(let m): m.id
        case .deletionReply(let m): m.id
        case .streamEnd(let m): m.id
        case .sessionReply(let m): m.id
        default: nil
        }
    }

    /// The body of a service message (`MessageType` 64 and up).
    func encodeService(to w: inout WireWriter) throws {
        switch self {
        case .identityRequest(let m): try w.request(m) { try $1.encode(to: &$0) }
        case .termsRequest(let m): try w.request(m) { try $1.encode(to: &$0) }
        case .queueRequest(let m): w.request(m) { $1.encode(to: &$0) }
        case .raceSessionRequest(let m): w.request(m) { $1.encode(to: &$0) }
        case .lobbyRequest(let m): try w.request(m) { try $1.encode(to: &$0) }
        case .profileRequest(let m): try w.request(m) { try $1.encode(to: &$0) }
        case .analyticsRequest(let m): try w.request(m) { try $1.encode(to: &$0) }
        case .deletionRequest(let m): try w.request(m) { try $1.encode(to: &$0) }
        case .streamNext(let m):
            w.requestID(m.id)
            w.requestID(m.stream)
        case .streamClose(let m): w.requestID(m.stream)
        case .identityReply(let m): try w.reply(m) { try $1.encode(to: &$0) }
        case .termsReply(let m): try w.reply(m) { try $1.encode(to: &$0) }
        case .queueReply(let m): try w.reply(m) { try $1.encode(to: &$0) }
        case .raceSessionReply(let m): try w.reply(m) { try $1.encode(to: &$0) }
        case .lobbyReply(let m): try w.reply(m) { try $1.encode(to: &$0) }
        case .profileReply(let m): try w.reply(m) { try $1.encode(to: &$0) }
        case .analyticsReply(let m): try w.reply(m) { try $1.encode(to: &$0) }
        case .deletionReply(let m): try w.reply(m) { try $1.encode(to: &$0) }
        case .streamEnd(let m): w.requestID(m.id)
        case .sessionRequest(let m): try w.request(m) { try $1.encode(to: &$0) }
        case .sessionReply(let m): try w.reply(m) { try $1.encode(to: &$0) }
        default: throw WireError.outOfRange("service")
        }
    }

    /// Decodes the body of a service message of `type`.
    init(service type: MessageType, from r: inout WireReader) throws {
        switch type {
        case .identityRequest: self = .identityRequest(ServiceRequest(id: try r.requestID(), call: try IdentityCall(from: &r)))
        case .termsRequest: self = .termsRequest(ServiceRequest(id: try r.requestID(), call: try TermsCall(from: &r)))
        case .queueRequest: self = .queueRequest(ServiceRequest(id: try r.requestID(), call: try QueueCall(from: &r)))
        case .raceSessionRequest:
            self = .raceSessionRequest(ServiceRequest(id: try r.requestID(), call: try RaceSessionCall(from: &r)))
        case .lobbyRequest: self = .lobbyRequest(ServiceRequest(id: try r.requestID(), call: try LobbyCall(from: &r)))
        case .profileRequest: self = .profileRequest(ServiceRequest(id: try r.requestID(), call: try ProfileCall(from: &r)))
        case .analyticsRequest:
            self = .analyticsRequest(ServiceRequest(id: try r.requestID(), call: try WireAnalyticsBatch(from: &r)))
        case .deletionRequest: self = .deletionRequest(ServiceRequest(id: try r.requestID(), call: try DeletionCall(from: &r)))
        case .streamNext: self = .streamNext(StreamNext(id: try r.requestID(), stream: try r.requestID()))
        case .streamClose: self = .streamClose(StreamClose(stream: try r.requestID()))
        case .identityReply: self = .identityReply(ServiceReply(id: try r.requestID(), result: try IdentityResult(from: &r)))
        case .termsReply: self = .termsReply(ServiceReply(id: try r.requestID(), result: try TermsResult(from: &r)))
        case .queueReply: self = .queueReply(ServiceReply(id: try r.requestID(), result: try QueueResult(from: &r)))
        case .raceSessionReply:
            self = .raceSessionReply(ServiceReply(id: try r.requestID(), result: try RaceSessionResult(from: &r)))
        case .lobbyReply: self = .lobbyReply(ServiceReply(id: try r.requestID(), result: try LobbyResult(from: &r)))
        case .profileReply: self = .profileReply(ServiceReply(id: try r.requestID(), result: try ProfileResult(from: &r)))
        case .analyticsReply: self = .analyticsReply(ServiceReply(id: try r.requestID(), result: try AnalyticsResult(from: &r)))
        case .deletionReply: self = .deletionReply(ServiceReply(id: try r.requestID(), result: try DeletionResult(from: &r)))
        case .streamEnd: self = .streamEnd(StreamEnd(id: try r.requestID()))
        case .sessionRequest: self = .sessionRequest(ServiceRequest(id: try r.requestID(), call: try SessionCall(from: &r)))
        case .sessionReply: self = .sessionReply(ServiceReply(id: try r.requestID(), result: try SessionResult(from: &r)))
        default: throw WireError.unknownMessageType(type.rawValue)
        }
    }
}

// MARK: - Values every service uses

/// A rating on the ladder, with its provisional badge (#16).
public struct WireRating: Equatable, Sendable {
    public var value: Int
    public var isProvisional: Bool

    public init(value: Int, isProvisional: Bool) {
        self.value = value
        self.isProvisional = isProvisional
    }

    func encode(to w: inout WireWriter) {
        w.int(value)
        w.bool(isProvisional)
    }

    init(from r: inout WireReader) throws {
        self.init(value: try r.int("rating"), isProvisional: try r.bool("isProvisional"))
    }
}

/// Service field limits, beside `WireLimit`.
enum ServiceWireLimit {
    /// A lobby line's text in bytes: well over `LobbyLimits.maxCharacters` characters of any script, so the server,
    /// not the codec, refuses an over-long post.
    static let postText = 8192
    /// A livery's colour slots.
    static let colours = 16
    /// One analytics event's properties.
    static let properties = 64
}

extension WireWriter {
    mutating func requestID(_ id: UInt32) { varint(UInt64(id)) }

    /// Any `Int`, as a zigzag varint: small magnitudes of either sign are short.
    mutating func int(_ v: Int) { int64(Int64(v)) }

    mutating func int64(_ v: Int64) { varint(UInt64(bitPattern: (v << 1) ^ (v >> 63))) }

    /// A presence flag, then the value when there is one.
    mutating func optional<T>(_ value: T?, _ body: (inout WireWriter, T) throws -> Void) rethrows {
        bool(value != nil)
        if let value { try body(&self, value) }
    }

    mutating func text(_ s: String, _ field: String) throws { try string(s, limit: WireLimit.string, field) }

    /// Seats, each a byte, `limit` at most.
    mutating func seats(_ seats: [Int], _ field: String) throws {
        try count(seats.count, limit: WireLimit.seats, field)
        for seat in seats { try index(seat, field) }
    }

    mutating func list<T>(_ items: [T], limit: Int, _ field: String, _ body: (inout WireWriter, T) throws -> Void) throws {
        try count(items.count, limit: limit, field)
        for item in items { try body(&self, item) }
    }

    mutating func request<Call>(_ m: ServiceRequest<Call>, _ body: (inout WireWriter, Call) throws -> Void) rethrows {
        requestID(m.id)
        try body(&self, m.call)
    }

    mutating func reply<Result>(_ m: ServiceReply<Result>, _ body: (inout WireWriter, Result) throws -> Void) rethrows {
        requestID(m.id)
        try body(&self, m.result)
    }
}

extension WireReader {
    mutating func requestID() throws -> UInt32 {
        let v = try varint("id")
        guard let id = UInt32(exactly: v) else { throw WireError.invalidValue("id") }
        return id
    }

    mutating func int(_ field: String) throws -> Int {
        guard let v = Int(exactly: try int64(field)) else { throw WireError.invalidValue(field) }
        return v
    }

    mutating func int64(_ field: String) throws -> Int64 {
        let u = try varint(field)
        return Int64(bitPattern: u >> 1) ^ -Int64(bitPattern: u & 1)
    }

    mutating func optional<T>(_ field: String, _ body: (inout WireReader) throws -> T) throws -> T? {
        try bool(field) ? try body(&self) : nil
    }

    mutating func text(_ field: String) throws -> String { try string(limit: WireLimit.string, field) }

    mutating func seats(_ field: String) throws -> [Int] {
        let n = try count(limit: WireLimit.seats, field)
        return try (0..<n).map { _ in try index() }
    }

    mutating func list<T>(limit: Int, _ field: String, _ body: (inout WireReader) throws -> T) throws -> [T] {
        let n = try count(limit: limit, field)
        return try (0..<n).map { _ in try body(&self) }
    }

    /// A one-byte code for an enum that rejects codes it doesn't know.
    mutating func code<T: RawRepresentable<UInt8>>(_ field: String) throws -> T {
        guard let value = T(rawValue: try u8()) else { throw WireError.invalidValue(field) }
        return value
    }
}
