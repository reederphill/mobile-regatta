import RegattaCore

/// Every message on the race connection. Its type code is fixed for good; a new message takes the
/// next free code. Codes 0–31 are the race protocol; service messages (#143) start at 64.
public enum MessageType: UInt8, Sendable, CaseIterable {
    // Client → server.
    case hello = 1
    case joinRace = 2
    case inputHeld = 3
    case inputTap = 4
    case ping = 5
    case requestResync = 6
    // Server → client.
    case helloAck = 16
    case updateRequired = 17
    case raceStart = 18
    case resync = 19
    case snapshot = 20
    case event = 21
    case windKey = 22
    case pong = 23
    case raceCancelled = 24
    case raceClosed = 25

    public enum Direction: Sendable { case clientToServer, serverToClient }

    public var direction: Direction {
        switch self {
        case .hello, .joinRace, .inputHeld, .inputTap, .ping, .requestResync: .clientToServer
        case .helloAck, .updateRequired, .raceStart, .resync, .snapshot, .event, .windKey, .pong, .raceCancelled,
             .raceClosed: .serverToClient
        }
    }

    /// What a frame's `seq` counts for this type.
    public enum Stream: Sendable {
        /// The client's inputs, held and taps together, from 1; `InputAck.seq` refers to it.
        case input
        /// The server's reliable stream to one client, `Event` and `WindKey` together, contiguous
        /// from 1, so a gap means a lost frame; `EventState.nextEventSeq` resumes it after a `Resync`.
        case reliable
        /// The sender's count of its other messages; informational only.
        case other
    }

    public var stream: Stream {
        switch self {
        case .inputHeld, .inputTap: .input
        case .event, .windKey: .reliable
        default: .other
        }
    }
}

/// A message's content. Its sequence number and tick are the frame's.
public enum Message: Equatable, Sendable {
    case hello(Hello)
    case joinRace(JoinRace)
    /// A seat's held input (#18), in force from the frame's tick until the seat sends another.
    case inputHeld(BoatInput)
    /// A tap (#18), applied once at the frame's tick.
    case inputTap(BoatTap)
    case ping(Ping)
    /// Client → server: send me a `Resync`, e.g. a wind key I need is missing (#64). Empty.
    case requestResync
    case helloAck(HelloAck)
    case updateRequired(UpdateRequired)
    case raceStart(RaceStart)
    case resync(Resync)
    case snapshot(Snapshot)
    /// A race event (#18 reliable events); the frame's tick is the event's.
    case event(RaceEvent.Kind)
    case windKey(WindKeyReveal)
    case pong(Pong)
    case raceCancelled(RaceCancelled)
    case raceClosed(RaceClosed)

    public var type: MessageType {
        switch self {
        case .hello: .hello
        case .joinRace: .joinRace
        case .inputHeld: .inputHeld
        case .inputTap: .inputTap
        case .ping: .ping
        case .requestResync: .requestResync
        case .helloAck: .helloAck
        case .updateRequired: .updateRequired
        case .raceStart: .raceStart
        case .resync: .resync
        case .snapshot: .snapshot
        case .event: .event
        case .windKey: .windKey
        case .pong: .pong
        case .raceCancelled: .raceCancelled
        case .raceClosed: .raceClosed
        }
    }
}

/// One message as it goes on the wire: type, sequence number and tick, then the body (#18: tick and
/// sequence numbers everywhere, framing that doesn't depend on the transport).
///
///     type uint8 | seq uint32 | tick int32 | body
///
/// Little-endian. The frame is exactly one transport message: the transport delimits it, so there is
/// no length field. `seq` counts within the type's `MessageType.Stream`. `tick` is the tick the
/// message is about: an input's stamp, an event's tick, the snapshot's or resync's tick; otherwise the
/// sender's race clock when it sent it (the client's predicted tick, the server's tick).
///
/// The header layout is frozen forever, as are the codes of `hello` (1) and `updateRequired` (17):
/// every version of the protocol has to be able to read a `Hello`'s version and answer it
/// (`wireProtocolVersion`).
public struct Frame: Equatable, Sendable {
    /// Bytes before the body.
    public static let headerSize = 9

    /// The `protocolVersion` of a `Hello` frame, read without decoding the rest of its body, which a
    /// future version may lay out differently. Nil for anything that isn't a `Hello` long enough to
    /// have one. The server reads it first and answers any version but its own with `UpdateRequired`.
    public static func helloProtocolVersion(in bytes: [UInt8]) -> UInt16? {
        guard bytes.count >= headerSize + 2, bytes[0] == MessageType.hello.rawValue else { return nil }
        return UInt16(bytes[headerSize]) | UInt16(bytes[headerSize + 1]) << 8
    }

    public var seq: UInt32
    public var tick: Int
    public var message: Message

    public init(seq: UInt32, tick: Int, message: Message) {
        self.seq = seq
        self.tick = tick
        self.message = message
    }

    /// An `Event` frame for `event`, at its tick.
    public init(seq: UInt32, event: RaceEvent) {
        self.init(seq: seq, tick: event.tick, message: .event(event.kind))
    }

    /// The race event an `Event` frame carries, with the frame's tick.
    public var raceEvent: RaceEvent? {
        guard case .event(let kind) = message else { return nil }
        return RaceEvent(tick: tick, kind: kind)
    }

    public func encoded() throws -> [UInt8] {
        var w = WireWriter()
        w.u8(message.type.rawValue)
        w.u32(seq)
        try w.i32(tick, "tick")
        switch message {
        case .hello(let m): try m.encode(to: &w)
        case .joinRace(let m): try m.encode(to: &w)
        case .inputHeld(let input): input.encode(to: &w)
        case .inputTap(let tap): try tap.encode(to: &w)
        case .ping(let m): w.u64(m.clientTime)
        case .requestResync: break
        case .helloAck(let m): try m.encode(to: &w)
        case .updateRequired(let m): try m.encode(to: &w)
        case .raceStart(let m): try m.encode(to: &w)
        case .resync(let m): try m.encode(to: &w)
        case .snapshot(let m): try m.encode(to: &w)
        case .event(let kind): try kind.encode(to: &w)
        case .windKey(let m): try m.encode(to: &w)
        case .pong(let m):
            w.u64(m.clientTime)
            w.u16(m.sinceTickMicros)
        case .raceCancelled(let m): w.u8(try m.reason.canonicalCode())
        case .raceClosed(let m): try m.results.encode(to: &w, "results")
        }
        return w.bytes
    }

    /// Decodes exactly one frame: throws on anything the encoder wouldn't produce.
    public init(decoding bytes: [UInt8]) throws {
        var r = WireReader(bytes)
        let code = try r.u8()
        guard let type = MessageType(rawValue: code) else { throw WireError.unknownMessageType(code) }
        seq = try r.u32()
        tick = try r.i32()
        switch type {
        case .hello: message = .hello(try Hello(from: &r))
        case .joinRace: message = .joinRace(try JoinRace(from: &r))
        case .inputHeld: message = .inputHeld(try BoatInput(from: &r))
        case .inputTap: message = .inputTap(try BoatTap(from: &r))
        case .ping: message = .ping(Ping(clientTime: try r.u64()))
        case .requestResync: message = .requestResync
        case .helloAck: message = .helloAck(try HelloAck(from: &r))
        case .updateRequired: message = .updateRequired(try UpdateRequired(from: &r))
        case .raceStart: message = .raceStart(try RaceStart(from: &r))
        case .resync: message = .resync(try Resync(from: &r))
        case .snapshot: message = .snapshot(try Snapshot(from: &r))
        case .event: message = .event(try RaceEvent.Kind(from: &r))
        case .windKey: message = .windKey(try WindKeyReveal(from: &r))
        case .pong: message = .pong(Pong(clientTime: try r.u64(), sinceTickMicros: try r.u16()))
        case .raceCancelled:
            message = .raceCancelled(RaceCancelled(reason: RaceCancelled.Reason(code: try r.u8())))
        case .raceClosed: message = .raceClosed(RaceClosed(results: try VersionedPayload(from: &r, "results")))
        }
        try r.finish()
    }
}
