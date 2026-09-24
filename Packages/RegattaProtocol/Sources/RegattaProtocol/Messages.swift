import RegattaCore

/// The wire protocol's version, checked in the handshake alongside the simulation version (#18).
/// Bump it for any change to an existing message's encoding; a new message type or a new code in an
/// enum doesn't need it, since an older peer never receives one it didn't ask for.
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
public struct UpdateRequired: Equatable, Sendable {
    public enum Reason: UInt8, Sendable, CaseIterable {
        case protocolVersion = 1
        case simulationVersion = 2
        case clientBuild = 3
        case dataFiles = 4
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

/// A revealed wind key (ADR 0001), sent reliably about a window ahead (#95).
/// TODO(#75, #95): the key's shape is the keyed wind's (`WindKey`, #75). Until it lands this carries
/// the key as an opaque payload with the window it opens; #95 defines schema 1. Never the wind seed.
public struct WindKeyReveal: Equatable, Sendable {
    public var window: Int
    public var key: VersionedPayload

    public init(window: Int, key: VersionedPayload) {
        self.window = window
        self.key = key
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
    /// Wind keys revealed so far (#95).
    public var windKeys: [WindKeyReveal]

    public init(yourSeat: Int, setup: RaceSetup, roster: [RosterEntry], tide: VersionedPayload = .none, windKeys: [WindKeyReveal] = []) {
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
    /// Every wind key revealed so far (#95).
    public var windKeys: [WindKeyReveal]
    public var eventState: EventState

    public init(raceSeed: RaceSeed, seats: [WireSeat], windKeys: [WindKeyReveal] = [], eventState: EventState) {
        self.raceSeed = raceSeed
        self.seats = seats
        self.windKeys = windKeys
        self.eventState = eventState
    }

    public init(raceSeed: RaceSeed, world: WorldSnapshot, windKeys: [WindKeyReveal] = [], nextEventSeq: UInt32,
                rules: VersionedPayload = .none) throws {
        self.init(raceSeed: raceSeed, seats: try wireSeats(of: world), windKeys: windKeys,
                  eventState: EventState(world: world, nextEventSeq: nextEventSeq, rules: rules))
    }

    /// The world at `tick` (the frame's tick), built on `base`, the receiver's own snapshot (a freshly
    /// built race's, on a rejoin): the wire seats, and finishes and the race's end from the event state.
    /// Contact and foul memory stay as the base has them.
    public func world(base: WorldSnapshot, tick: Int) throws -> WorldSnapshot {
        var world = try merge(seats, into: base, tick: tick)
        for i in world.seats.indices {
            world.seats[i].boat.place = nil
            world.seats[i].boat.finishTime = nil
        }
        for finish in eventState.finishes {
            guard world.seats.indices.contains(finish.seat) else { throw WireError.invalidValue("finishes.seat") }
            world.seats[finish.seat].boat.place = finish.place
            world.seats[finish.seat].boat.finishTime = EventState.time(of: finish.tick)
        }
        world.firstFinishTime = eventState.firstFinishTick.map(EventState.time)
        world.isOver = eventState.isOver
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
    /// applied at the next tick instead. int16 on the wire.
    public var margin: Int

    public init(seq: UInt32, appliedTick: Int, margin: Int) {
        self.seq = seq
        self.appliedTick = appliedTick
        self.margin = margin
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

    /// The receiver's snapshot `base` with this one's seats merged in at `tick` (the frame's tick):
    /// what a predicting client imports (ADR 0005). Fields the wire leaves out (`SnapshotFields.excluded`)
    /// and race-level state keep the base's values.
    public func applied(to base: WorldSnapshot, tick: Int) throws -> WorldSnapshot {
        try merge(seats, into: base, tick: tick)
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
    /// Microseconds since the frame's tick began on the server, for sub-tick clock sync.
    public var sinceTickMicros: UInt16

    public init(clientTime: UInt64, sinceTickMicros: UInt16) {
        self.clientTime = clientTime
        self.sinceTickMicros = sinceTickMicros
    }
}

/// Server → client: the race won't be sailed. Placeholder reasons until the multiplayer flow (#66)
/// adds its own; a new reason is a new code, not a format change.
public struct RaceCancelled: Equatable, Sendable {
    public enum Reason: UInt8, Sendable, CaseIterable {
        case unspecified = 0
        case serverShutdown = 1
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
        w.u8(reason.rawValue)
        try w.string(simulationVersion, limit: WireLimit.string, "simulationVersion")
        w.u16(protocolVersion)
    }

    init(from r: inout WireReader) throws {
        guard let reason = Reason(rawValue: try r.u8()) else { throw WireError.invalidValue("reason") }
        self.reason = reason
        simulationVersion = try r.string(limit: WireLimit.string, "simulationVersion")
        protocolVersion = try r.u16()
    }
}

extension JoinRace {
    func encode(to w: inout WireWriter) throws { try w.blob(token, limit: WireLimit.token, "token") }
    init(from r: inout WireReader) throws { token = try r.blob(limit: WireLimit.token, "token") }
}

extension WindKeyReveal {
    func encode(to w: inout WireWriter) throws {
        try w.i32(window, "window")
        try key.encode(to: &w, "key")
    }

    init(from r: inout WireReader) throws {
        window = try r.i32()
        key = try VersionedPayload(from: &r, "key")
    }
}

func encodeWindKeys(_ keys: [WindKeyReveal], to w: inout WireWriter) throws {
    try w.count(keys.count, limit: WireLimit.list, "windKeys")
    for key in keys { try key.encode(to: &w) }
}

func decodeWindKeys(from r: inout WireReader) throws -> [WindKeyReveal] {
    let n = try r.count(limit: WireLimit.list, "windKeys")
    return try (0..<n).map { _ in try WindKeyReveal(from: &r) }
}

extension RaceStart {
    func encode(to w: inout WireWriter) throws {
        guard setup.seats.count == roster.count else { throw WireError.outOfRange("roster") }
        guard setup.seats.indices.contains(yourSeat) else { throw WireError.outOfRange("yourSeat") }
        try w.index(yourSeat, "yourSeat")
        try w.string(setup.simulationVersion, limit: WireLimit.string, "simulationVersion")
        w.u64(setup.raceSeed.value)
        try w.count(setup.laps, limit: Int(UInt32.max), "laps")
        try w.count(setup.startSequenceTicks, limit: Int(UInt32.max), "startSequenceTicks")
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
        let limit = UInt64(UInt32.max)
        let rawLaps = try r.varint("laps"), rawSequence = try r.varint("startSequenceTicks")
        guard rawLaps <= limit, rawSequence <= limit else { throw WireError.invalidValue("setup") }
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
            guard let margin = Int16(exactly: ack.margin) else { throw WireError.outOfRange("ack.margin") }
            w.i16(margin)
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
