import RegattaCore

/// The wire protocol's version. The handshake requires an exact match, as it does for the
/// simulation version (#18): a client with any other version gets `UpdateRequired` and nothing else.
///
/// Bump it for any change a peer of this version couldn't decode: a changed encoding of an existing
/// message, and any new code the server may send without being asked, such as a new message type,
/// a new `RaceEvent` kind or a new enum code in a server message. The one exception is the two
/// reason enums, `UpdateRequired.Reason` and `RaceCancelled.Reason`: they decode codes they don't
/// know as `.unknown`, so adding a reason needs no bump, and a newer server's reason still reaches an
/// older client. Only three things are frozen forever, so that any future client and server can still
/// tell each other apart: the frame header (`Frame`), the `protocolVersion` at the start of `Hello`'s
/// body (`Frame.helloProtocolVersion(in:)`), and the whole `UpdateRequired` body.
public let wireProtocolVersion: UInt16 = 1

/// Bytes whose shape is owned by a later ticket, tagged with that shape's schema, so the owner can
/// fill it (and version it) without changing the message around it. Schema 0 is "nothing yet" and
/// carries no bytes.
public struct VersionedPayload: Hashable, Sendable {
    public var schema: UInt16
    public var bytes: [UInt8]

    public static let none = VersionedPayload(schema: 0, bytes: [])

    public init(schema: UInt16, bytes: [UInt8]) {
        self.schema = schema
        self.bytes = bytes
    }

    func encode(to w: inout WireWriter, _ field: String) throws {
        guard schema != 0 || bytes.isEmpty else { throw WireError.outOfRange(field) }
        w.u16(schema)
        try w.blob(bytes, limit: WireLimit.payload, field)
    }

    init(from r: inout WireReader, _ field: String) throws {
        schema = try r.u16()
        bytes = try r.blob(limit: WireLimit.payload, field)
        guard schema != 0 || bytes.isEmpty else { throw WireError.invalidValue(field) }
    }
}

// MARK: - Handshake

/// Client → server, first on a connection: who is asking, and whether they can sail with us (#18, #32).
public struct Hello: Equatable, Sendable {
    /// First in the body, as a uint16, in every version forever (`Frame.helloProtocolVersion(in:)`).
    /// Everything after it belongs to that version.
    public var protocolVersion: UInt16
    /// The app's build, e.g. "1.0 (42)". For support and the update prompt; never trusted.
    public var clientBuild: String
    /// Must equal the server's exactly (ADR 0002), or the server answers `UpdateRequired`.
    public var simulationVersion: String
    /// The data files the client has (ADR 0004), each with its content hash.
    public var files: [FileRef]
    /// The App Attest assertion. Placeholder until #158 defines schema 1: send `.none`.
    public var attestation: VersionedPayload

    public init(protocolVersion: UInt16 = wireProtocolVersion, clientBuild: String, simulationVersion: String = RegattaCore.simulationVersion,
                files: [FileRef], attestation: VersionedPayload = .none) {
        self.protocolVersion = protocolVersion
        self.clientBuild = clientBuild
        self.simulationVersion = simulationVersion
        self.files = files
        self.attestation = attestation
    }
}

/// Server → client: the client can sail here.
public struct HelloAck: Equatable, Sendable {
    public var serverBuild: String

    public init(serverBuild: String) { self.serverBuild = serverBuild }
}

/// Server → client: the client can't sail here until it updates (#18, #16). The connection closes after it.
///
/// Frozen forever (see `wireProtocolVersion`): `reason` uint8 | `simulationVersion` string |
/// `protocolVersion` uint16. A client of any version must be able to read it.
public struct UpdateRequired: Equatable, Sendable {
    public enum Reason: Hashable, Sendable {
        case protocolVersion
        case simulationVersion
        case clientBuild
        case dataFiles
        /// A code this build doesn't know, from a newer server: show a generic update prompt.
        case unknown(UInt8)

        public static let known: [Reason] = [.protocolVersion, .simulationVersion, .clientBuild, .dataFiles]

        public var code: UInt8 {
            switch self {
            case .protocolVersion: 1
            case .simulationVersion: 2
            case .clientBuild: 3
            case .dataFiles: 4
            case .unknown(let code): code
            }
        }

        /// Never fails: a code this build doesn't know is `.unknown`.
        public init(code: UInt8) {
            self = Reason.known.first { $0.code == code } ?? .unknown(code)
        }
    }

    public var reason: Reason
    /// The server's simulation version.
    public var simulationVersion: String
    /// The server's wire protocol version.
    public var protocolVersion: UInt16

    public init(reason: Reason, simulationVersion: String = RegattaCore.simulationVersion, protocolVersion: UInt16 = wireProtocolVersion) {
        self.reason = reason
        self.simulationVersion = simulationVersion
        self.protocolVersion = protocolVersion
    }
}

/// Client → server: take my seat in the race this token names. The token is opaque here; the race
/// session service issues it (#143).
public struct JoinRace: Equatable, Sendable {
    public var token: [UInt8]

    public init(token: [UInt8]) { self.token = token }
}

// MARK: - Race setup and resync

/// One seat's roster metadata: everything about who sails it that isn't the boat. The only place on
/// the wire that says whether a seat is a bot (#18: bots look like humans on the wire; #19: they are
/// labelled everywhere a player looks).
public struct RosterEntry: Equatable, Sendable {
    /// The player's handle or the bot's sailing name.
    public var name: String
    public var colorIndex: Int

    public init(name: String, colorIndex: Int) {
        self.name = name
        self.colorIndex = colorIndex
    }
}

/// Wind keys on the wire are RegattaCore's `WindKey` (#75) in its own fixed 64-byte encoding
/// (`WindKey.bytes`), revealed about a window ahead (ADR 0001; the schedule is #95's). A key is derived
/// one way from the wind seed, which is never on the wire.
public enum WindKeyWire {
    /// The highest window a key on the wire may have: past the longest sequence and
    /// `WorldSnapshot.maxTick`, so a hostile key can't make a receiver's `WindKeyChain` grow without bound.
    public static let maxWindow = (RaceStart.maxStartSequenceTicks + WorldSnapshot.maxTick) / WindWindows.ticksPerWindow + 2

    // Sanity bounds on a key's values, so a hostile key can't drive the wind to infinity or NaN (a knot
    // of 1e308 does, within two seconds). Far outside anything `WindKeyGenerator` makes from the
    // conditions files (the largest in parentheses, from their schema-2 values; `windKeysStayInBounds`
    // samples every file):
    //   shift value: the oscillation amplitude plus the trend (12° + 15° = 0.47 rad); bound π, 6.6×
    //   shift slope: amplitude · 2π / period plus the trend's rate (0.015 + 0.0011 rad/s); bound 1 rad/s, 60×
    //   strength value: 1 + the build, capped at the forecast's top (≤ 1.15); bound 0 … 10, 8.7×
    //   strength slope: the build's rate (0.0006 /s); bound 1 /s, over 1000×
    //   wobble hump and wiggle: ± half the wobble (0.013 rad); bound 1 rad, 76×
    // With every value inside them, a window's Hermite curve stays within tens of radians and a few
    // times the base strength (which `WindField` clamps to the forecast anyway): finite.

    /// |shift value| at a knot, radians.
    public static let shiftLimit = Double.pi
    /// |slope| of either channel at a knot, per second.
    public static let slopeLimit = 1.0
    /// The strength channel's value at a knot, a factor of the base strength.
    public static let strengthRange = 0.0...10.0
    /// |hump| and |wiggle|, radians.
    public static let wobbleLimit = 1.0

    /// Whether `key` is one a receiver can sail with: a window it may hold and values inside the bounds.
    public static func isSane(_ key: WindKey) -> Bool {
        (0...maxWindow).contains(key.window)
            && abs(key.shift.value) <= shiftLimit && abs(key.shift.slope) <= slopeLimit
            && strengthRange.contains(key.strength.value) && abs(key.strength.slope) <= slopeLimit
            && abs(key.wobble.hump) <= wobbleLimit && abs(key.wobble.wiggle) <= wobbleLimit
    }
}

/// Server → client, once per race and again before a `Resync` on rejoin: the race as the client
/// needs it to build its own `Race` (#18, #32). The setup is public; the wind seed is never in it
/// (ADR 0001). Per client: `yourSeat` differs.
public struct RaceStart: Equatable, Sendable {
    public var yourSeat: Int
    /// On the wire its seat kinds travel only as the roster's bot flags.
    public var setup: RaceSetup
    /// By seat, as many as `setup.seats`.
    public var roster: [RosterEntry]
    /// Tide state (#78). Placeholder until #78 defines schema 1: `.none`.
    public var tide: VersionedPayload
    /// Wind keys revealed so far (#95), in increasing windows.
    public var windKeys: [WindKey]

    /// Sane caps on what a race can be, so a decoded setup never builds a huge course or sequence.
    /// Far beyond any real race: two laps by default (#8), a 60 s sequence (#85).
    public static let maxLaps = 50
    public static let maxStartSequenceTicks = 30 * 60 * Race.tickRate

    public init(yourSeat: Int, setup: RaceSetup, roster: [RosterEntry], tide: VersionedPayload = .none, windKeys: [WindKey] = []) {
        self.yourSeat = yourSeat
        self.setup = setup
        self.roster = roster
        self.tide = tide
        self.windKeys = windKeys
    }
}

/// The reliable event stream's state, for a client resynchronising (#18).
public struct EventState: Equatable, Sendable {
    public struct Finish: Equatable, Sendable {
        public var seat: Int
        public var place: Int
        public var tick: Int

        public init(seat: Int, place: Int, tick: Int) {
            self.seat = seat
            self.place = place
            self.tick = tick
        }
    }

    /// The reliable-stream sequence number of the next `Event` or `WindKey` frame this client gets.
    public var nextEventSeq: UInt32
    /// Boats that have finished, by seat.
    public var finishes: [Finish]
    public var firstFinishTick: Int?
    public var isOver: Bool
    /// Client-visible rules and incident state. Placeholder until the rules tickets (#73+, #86, #96)
    /// define schema 1: `.none`. Never umpire memory, which stays on the server (#18, #96).
    public var rules: VersionedPayload

    public init(nextEventSeq: UInt32, finishes: [Finish] = [], firstFinishTick: Int? = nil, isOver: Bool = false,
                rules: VersionedPayload = .none) {
        self.nextEventSeq = nextEventSeq
        self.finishes = finishes
        self.firstFinishTick = firstFinishTick
        self.isOver = isOver
        self.rules = rules
    }

    /// The event state of `world`.
    public init(world: WorldSnapshot, nextEventSeq: UInt32, rules: VersionedPayload = .none) {
        self.nextEventSeq = nextEventSeq
        finishes = world.seats.indices.compactMap { seat in
            let boat = world.seats[seat].boat
            guard let place = boat.place, let time = boat.finishTime else { return nil }
            return Finish(seat: seat, place: place, tick: EventState.tick(of: time))
        }
        firstFinishTick = world.firstFinishTime.map(EventState.tick)
        isOver = world.isOver
        self.rules = rules
    }

    /// Makes `world`'s race-level state the server's: every boat's place and finish time (nil for boats
    /// not in `finishes`), the first finish and whether the race is over. Contact and foul memory are
    /// left alone. Throws for a finish naming a seat `world` doesn't have.
    public func apply(to world: inout WorldSnapshot) throws {
        guard finishes.allSatisfy({ world.seats.indices.contains($0.seat) }) else {
            throw WireError.invalidValue("finishes.seat")
        }
        for i in world.seats.indices {
            world.seats[i].boat.place = nil
            world.seats[i].boat.finishTime = nil
        }
        for finish in finishes {
            world.seats[finish.seat].boat.place = finish.place
            world.seats[finish.seat].boat.finishTime = EventState.time(of: finish.tick)
        }
        world.firstFinishTime = firstFinishTick.map(EventState.time)
        world.isOver = isOver
    }

    /// Brings the state up to date with a reliable event from the server, received in order: how a
    /// client keeps it between `RaceStart` / `Resync` and each `Snapshot` (#64). The reliable stream's
    /// sequence number (`nextEventSeq`) is the caller's to advance.
    public mutating func record(_ event: RaceEvent) {
        switch event.kind {
        case .finished(let seat, let place):
            finishes.removeAll { $0.seat == seat }
            finishes.append(Finish(seat: seat, place: place, tick: event.tick))
            finishes.sort { $0.seat < $1.seat } // by seat, as `init(world:)` lists them
            firstFinishTick = min(firstFinishTick ?? event.tick, event.tick)
        case .disqualified:
            // Today a boat is disqualified only as she crosses the finish line with a penalty unserved,
            // which also starts the finish window (`Race.firstFinishTime`).
            firstFinishTick = min(firstFinishTick ?? event.tick, event.tick)
        case .raceOver:
            isOver = true
        case .gun, .ocs, .cleared, .started, .foul, .markTouch, .penaltyServed, .rounded, .protest:
            break
        }
    }

    /// The race tick of a race time, which is always a whole number of ticks.
    static func tick(of time: Double) -> Int { Int((time * Double(Race.tickRate)).rounded()) }
    /// Exactly `Race.time` at `tick`.
    static func time(of tick: Int) -> Double { Double(tick) / Double(Race.tickRate) }
}

/// Server → client: everything to rebuild the race's state mid-race, for a rejoin or a client that
/// has drifted beyond recovery (#18). The client already has the race's `RaceStart`.
public struct Resync: Equatable, Sendable {
    /// The public race seed (#18 "the seed"): never the wind seed (ADR 0001).
    public var raceSeed: RaceSeed
    /// The world at the frame's tick.
    public var seats: [WireSeat]
    /// Every wind key revealed so far (#95), in increasing windows. A receiver that imports needs them
    /// without a gap from the window before the resync's tick (`WorldSnapshotError.missingWindKey`).
    public var windKeys: [WindKey]
    public var eventState: EventState

    public init(raceSeed: RaceSeed, seats: [WireSeat], windKeys: [WindKey] = [], eventState: EventState) {
        self.raceSeed = raceSeed
        self.seats = seats
        self.windKeys = windKeys
        self.eventState = eventState
    }

    /// `windKeys` defaults to the keys `world` holds, which a race holds only through its current
    /// window; a host that reveals keys ahead (#95) passes every key revealed so far.
    public init(raceSeed: RaceSeed, world: WorldSnapshot, windKeys: [WindKey]? = nil, nextEventSeq: UInt32,
                rules: VersionedPayload = .none) throws {
        self.init(raceSeed: raceSeed, seats: try wireSeats(of: world), windKeys: windKeys ?? world.windKeys.keys,
                  eventState: EventState(world: world, nextEventSeq: nextEventSeq, rules: rules))
    }

    /// The world at `tick` (the frame's tick), built on `base`, the receiver's own snapshot (a freshly
    /// built race's, on a rejoin): the wire seats, finishes and the race's end from the event state, and
    /// the revealed wind keys. Contact and foul memory stay as the base has them.
    public func world(base: WorldSnapshot, tick: Int) throws -> WorldSnapshot {
        var world = try merge(seats, into: base, tick: tick)
        try eventState.apply(to: &world)
        world.windKeys = WindKeyChain(windKeys)
        return world
    }
}

// MARK: - In the race

/// What the server did with a client's inputs: the last it applied, and how early it arrived.
public struct InputAck: Equatable, Sendable {
    /// The input stream sequence number of the client's last input the server applied.
    public var seq: UInt32
    /// The tick it applied at: its stamp, or the next tick if it came late (#18).
    public var appliedTick: Int
    /// Lead feedback for the client's clock (#18, #64): the stamp of the client's latest input minus the
    /// server's next tick when it arrived. ≥ 0: early by that many ticks; < 0: late by that many, and
    /// applied at the next tick instead. It comes from a client's stamp, so it saturates at
    /// ±32 767 ticks rather than ever making a snapshot unsendable.
    public var margin: Int16

    /// Clamps `margin` to the int16 range.
    public init(seq: UInt32, appliedTick: Int, margin: Int) {
        self.seq = seq
        self.appliedTick = appliedTick
        self.margin = Int16(clamping: margin)
    }
}

/// Server → client, every 3rd tick (#18): the whole fleet at the frame's tick, quantised, and this
/// client's input feedback. Full, never a delta. Bots and humans are indistinguishable in it.
public struct Snapshot: Equatable, Sendable {
    /// By seat.
    public var seats: [WireSeat]
    /// Nil until the server has applied an input from this client.
    public var ack: InputAck?

    public init(seats: [WireSeat], ack: InputAck? = nil) {
        self.seats = seats
        self.ack = ack
    }

    /// Quantises `world`'s seats.
    public init(world: WorldSnapshot, ack: InputAck? = nil) throws {
        self.init(seats: try wireSeats(of: world), ack: ack)
    }

    /// What a predicting client imports (ADR 0005): its own snapshot `base` with this one's seats
    /// merged in at `tick` (the frame's tick), and race-level state (finishes, first finish, whether the
    /// race is over) from `events`, the server's event state as the client has it from `RaceStart` /
    /// `Resync` and the reliable events since (`EventState.record`). So a client whose own prediction
    /// ended the race, or finished a boat, takes the server's word at every snapshot. The other fields
    /// the wire leaves out (`SnapshotFields.excluded`) and contact and foul memory keep the base's values.
    public func applied(to base: WorldSnapshot, tick: Int, events: EventState) throws -> WorldSnapshot {
        var world = try merge(seats, into: base, tick: tick)
        try events.apply(to: &world)
        return world
    }
}

/// Client → server: measures the round trip and the server clock (#64).
public struct Ping: Equatable, Sendable {
    /// The client's monotonic clock, in microseconds; the server echoes it.
    public var clientTime: UInt64

    public init(clientTime: UInt64) { self.clientTime = clientTime }
}

/// Server → client: answers a `Ping`. The frame's tick is the server's current tick.
public struct Pong: Equatable, Sendable {
    /// The ping's `clientTime`, echoed.
    public var clientTime: UInt64
    /// Microseconds since the frame's tick began on the server, for sub-tick clock sync. A tick is
    /// 33 334 µs, so it fits; the host clamps (`UInt16(clamping:)`) if its scheduler runs late.
    public var sinceTickMicros: UInt16

    public init(clientTime: UInt64, sinceTickMicros: UInt16) {
        self.clientTime = clientTime
        self.sinceTickMicros = sinceTickMicros
    }
}

/// Server → client: the race won't be sailed. Placeholder reasons until the multiplayer flow (#66)
/// adds its own. A new reason is a new code and needs no `wireProtocolVersion` bump: an older client
/// decodes it as `.unknown` (the exception in `wireProtocolVersion`'s policy).
public struct RaceCancelled: Equatable, Sendable {
    public enum Reason: Hashable, Sendable {
        case unspecified
        case serverShutdown
        /// A code this build doesn't know, from a newer server.
        case unknown(UInt8)

        public static let known: [Reason] = [.unspecified, .serverShutdown]

        public var code: UInt8 {
            switch self {
            case .unspecified: 0
            case .serverShutdown: 1
            case .unknown(let code): code
            }
        }

        /// Never fails: a code this build doesn't know is `.unknown`.
        public init(code: UInt8) {
            self = Reason.known.first { $0.code == code } ?? .unknown(code)
        }
    }

    public var reason: Reason

    public init(reason: Reason) { self.reason = reason }
}

/// Server → client: the race is over and scored.
public struct RaceClosed: Equatable, Sendable {
    /// The results. Placeholder until #86 defines result codes and schema 1: `.none`.
    public var results: VersionedPayload

    public init(results: VersionedPayload) { self.results = results }
}

// MARK: - Codec

extension FileRef {
    func encode(to w: inout WireWriter) throws {
        try w.string(id, limit: WireLimit.string, "file.id")
        guard version >= 0 else { throw WireError.outOfRange("file.version") }
        w.varint(UInt64(version))
        guard hash.bytes.count == 32 else { throw WireError.outOfRange("file.hash") }
        for byte in hash.bytes { w.u8(byte) }
    }

    init(from r: inout WireReader) throws {
        let id = try r.string(limit: WireLimit.string, "file.id")
        guard let version = Int(exactly: try r.varint("file.version")) else { throw WireError.invalidValue("file.version") }
        let digits = Array("0123456789abcdef".utf8)
        var hex: [UInt8] = []
        for _ in 0..<32 {
            let byte = try r.u8()
            hex.append(digits[Int(byte >> 4)])
            hex.append(digits[Int(byte & 0x0F)])
        }
        guard let hash = ContentHash(hex: String(decoding: hex, as: UTF8.self)) else { throw WireError.invalidValue("file.hash") }
        self.init(id: id, version: version, hash: hash)
    }
}

extension Hello {
    func encode(to w: inout WireWriter) throws {
        w.u16(protocolVersion)
        try w.string(clientBuild, limit: WireLimit.string, "clientBuild")
        try w.string(simulationVersion, limit: WireLimit.string, "simulationVersion")
        try w.count(files.count, limit: WireLimit.list, "files")
        for file in files { try file.encode(to: &w) }
        try attestation.encode(to: &w, "attestation")
    }

    init(from r: inout WireReader) throws {
        protocolVersion = try r.u16()
        clientBuild = try r.string(limit: WireLimit.string, "clientBuild")
        simulationVersion = try r.string(limit: WireLimit.string, "simulationVersion")
        let n = try r.count(limit: WireLimit.list, "files")
        files = try (0..<n).map { _ in try FileRef(from: &r) }
        attestation = try VersionedPayload(from: &r, "attestation")
    }
}

extension HelloAck {
    func encode(to w: inout WireWriter) throws { try w.string(serverBuild, limit: WireLimit.string, "serverBuild") }
    init(from r: inout WireReader) throws { serverBuild = try r.string(limit: WireLimit.string, "serverBuild") }
}

extension UpdateRequired {
    func encode(to w: inout WireWriter) throws {
        w.u8(try reason.canonicalCode())
        try w.string(simulationVersion, limit: WireLimit.string, "simulationVersion")
        w.u16(protocolVersion)
    }

    init(from r: inout WireReader) throws {
        reason = Reason(code: try r.u8())
        simulationVersion = try r.string(limit: WireLimit.string, "simulationVersion")
        protocolVersion = try r.u16()
    }
}

extension JoinRace {
    func encode(to w: inout WireWriter) throws { try w.blob(token, limit: WireLimit.token, "token") }
    init(from r: inout WireReader) throws { token = try r.blob(limit: WireLimit.token, "token") }
}

extension WindKey {
    func encode(to w: inout WireWriter) throws {
        guard window <= WindKeyWire.maxWindow else { throw WireError.outOfRange("windKey.window") }
        guard WindKeyWire.isSane(self) else { throw WireError.outOfRange("windKey") }
        w.raw(bytes)
    }

    init(from r: inout WireReader) throws {
        guard let key = WindKey(bytes: try r.raw(WindKey.byteCount)) else { throw WireError.invalidValue("windKey") }
        guard key.window <= WindKeyWire.maxWindow else { throw WireError.invalidValue("windKey.window") }
        guard WindKeyWire.isSane(key) else { throw WireError.invalidValue("windKey") }
        self = key
    }
}

/// A list of keys, in strictly increasing windows: one encoding per message, no key twice.
func encodeWindKeys(_ keys: [WindKey], to w: inout WireWriter) throws {
    guard zip(keys, keys.dropFirst()).allSatisfy({ $0.window < $1.window }) else { throw WireError.outOfRange("windKeys") }
    try w.count(keys.count, limit: WireLimit.list, "windKeys")
    for key in keys { try key.encode(to: &w) }
}

func decodeWindKeys(from r: inout WireReader) throws -> [WindKey] {
    let n = try r.count(limit: WireLimit.list, "windKeys")
    let keys = try (0..<n).map { _ in try WindKey(from: &r) }
    guard zip(keys, keys.dropFirst()).allSatisfy({ $0.window < $1.window }) else { throw WireError.invalidValue("windKeys") }
    return keys
}

extension RaceStart {
    func encode(to w: inout WireWriter) throws {
        guard setup.seats.count == roster.count else { throw WireError.outOfRange("roster") }
        guard setup.seats.indices.contains(yourSeat) else { throw WireError.outOfRange("yourSeat") }
        try w.index(yourSeat, "yourSeat")
        try w.string(setup.simulationVersion, limit: WireLimit.string, "simulationVersion")
        w.u64(setup.raceSeed.value)
        try w.count(setup.laps, limit: RaceStart.maxLaps, "laps")
        try w.count(setup.startSequenceTicks, limit: RaceStart.maxStartSequenceTicks, "startSequenceTicks")
        for file in [setup.boatClass, setup.venue, setup.conditions, setup.rulesConfiguration] {
            w.bool(file != nil)
            try file?.encode(to: &w)
        }
        // The seat table: the bot flag, then the rest of the roster metadata.
        try w.count(roster.count, limit: WireLimit.seats, "roster")
        for (kind, entry) in zip(setup.seats, roster) {
            w.bool(kind == .bot)
            try w.string(entry.name, limit: WireLimit.string, "roster.name")
            try w.index(entry.colorIndex, "roster.colorIndex")
        }
        try tide.encode(to: &w, "tide")
        try encodeWindKeys(windKeys, to: &w)
    }

    init(from r: inout WireReader) throws {
        let yourSeat = try r.index()
        let simulationVersion = try r.string(limit: WireLimit.string, "simulationVersion")
        let raceSeed = RaceSeed(try r.u64())
        let rawLaps = try r.varint("laps"), rawSequence = try r.varint("startSequenceTicks")
        guard rawLaps <= UInt64(RaceStart.maxLaps) else { throw WireError.invalidValue("laps") }
        guard rawSequence <= UInt64(RaceStart.maxStartSequenceTicks) else { throw WireError.invalidValue("startSequenceTicks") }
        let laps = Int(rawLaps), startSequenceTicks = Int(rawSequence)
        var files: [FileRef?] = []
        for _ in 0..<4 { files.append(try r.bool("file") ? try FileRef(from: &r) : nil) }
        let n = try r.count(limit: WireLimit.seats, "roster")
        var kinds: [SeatKind] = []
        var roster: [RosterEntry] = []
        for _ in 0..<n {
            kinds.append(try r.bool("roster.isBot") ? .bot : .human)
            roster.append(RosterEntry(name: try r.string(limit: WireLimit.string, "roster.name"), colorIndex: try r.index()))
        }
        let setup: RaceSetup
        do {
            setup = try RaceSetup(simulationVersion: simulationVersion, raceSeed: raceSeed, seats: kinds, laps: laps,
                                  startSequenceTicks: startSequenceTicks, boatClass: files[0], venue: files[1],
                                  conditions: files[2], rulesConfiguration: files[3])
        } catch {
            throw WireError.invalidValue("setup")
        }
        guard kinds.indices.contains(yourSeat) else { throw WireError.invalidValue("yourSeat") }
        self.init(yourSeat: yourSeat, setup: setup, roster: roster,
                  tide: try VersionedPayload(from: &r, "tide"), windKeys: try decodeWindKeys(from: &r))
    }
}

extension EventState {
    func encode(to w: inout WireWriter) throws {
        w.u32(nextEventSeq)
        try w.count(finishes.count, limit: WireLimit.seats, "finishes")
        for finish in finishes {
            try w.index(finish.seat, "finishes.seat")
            try w.index(finish.place, "finishes.place")
            try w.i32(finish.tick, "finishes.tick")
        }
        w.bool(firstFinishTick != nil)
        if let firstFinishTick { try w.i32(firstFinishTick, "firstFinishTick") }
        w.bool(isOver)
        try rules.encode(to: &w, "rules")
    }

    init(from r: inout WireReader) throws {
        nextEventSeq = try r.u32()
        let n = try r.count(limit: WireLimit.seats, "finishes")
        finishes = try (0..<n).map { _ in Finish(seat: try r.index(), place: try r.index(), tick: try r.i32()) }
        firstFinishTick = try r.bool("firstFinishTick") ? try r.i32() : nil
        isOver = try r.bool("isOver")
        rules = try VersionedPayload(from: &r, "rules")
    }
}

extension Resync {
    func encode(to w: inout WireWriter) throws {
        w.u64(raceSeed.value)
        try encodeSeats(seats, to: &w)
        try encodeWindKeys(windKeys, to: &w)
        try eventState.encode(to: &w)
    }

    init(from r: inout WireReader) throws {
        raceSeed = RaceSeed(try r.u64())
        seats = try decodeSeats(from: &r)
        windKeys = try decodeWindKeys(from: &r)
        eventState = try EventState(from: &r)
    }
}

extension Snapshot {
    func encode(to w: inout WireWriter) throws {
        w.bool(ack != nil)
        if let ack {
            w.u32(ack.seq)
            try w.i32(ack.appliedTick, "ack.appliedTick")
            w.i16(ack.margin)
        }
        try encodeSeats(seats, to: &w)
    }

    init(from r: inout WireReader) throws {
        ack = try r.bool("ack") ? InputAck(seq: try r.u32(), appliedTick: try r.i32(), margin: Int(try r.i16())) : nil
        seats = try decodeSeats(from: &r)
    }
}

extension BoatInput {
    func encode(to w: inout WireWriter) {
        w.i8(rudder)
        w.bool(ease)
    }

    init(from r: inout WireReader) throws {
        let rudder = try r.i8()
        guard rudder != Int8.min else { throw WireError.invalidValue("rudder") }
        self.init(rudder: rudder, ease: try r.bool("ease"))
    }
}

extension BoatTap {
    func encode(to w: inout WireWriter) throws {
        switch self {
        case .tackGybe: w.u8(0)
        case .protest(let target):
            w.u8(1)
            try w.index(target, "target")
        }
    }

    init(from r: inout WireReader) throws {
        switch try r.u8() {
        case 0: self = .tackGybe
        case 1: self = .protest(target: try r.index())
        default: throw WireError.invalidValue("tap")
        }
    }
}

extension UpdateRequired.Reason {
    /// `.unknown` of a known code has another encoding already, so it can't be sent.
    func canonicalCode() throws -> UInt8 {
        guard Self(code: code) == self else { throw WireError.outOfRange("reason") }
        return code
    }
}

extension RaceCancelled.Reason {
    /// `.unknown` of a known code has another encoding already, so it can't be sent.
    func canonicalCode() throws -> UInt8 {
        guard Self(code: code) == self else { throw WireError.outOfRange("reason") }
        return code
    }
}
