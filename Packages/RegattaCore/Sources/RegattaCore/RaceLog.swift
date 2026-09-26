import Foundation

/// One input exactly as the race applied it (ADR 0002): at the tick it took effect, which is its
/// stamp, or the next unsimulated tick if it came late (#18). Held inputs appear only when they change.
public struct InputRecord: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case held(BoatInput)
        case tap(BoatTap)
    }

    public let tick: Int
    public let seat: Int
    public let kind: Kind

    public init(tick: Int, seat: Int, kind: Kind) {
        self.tick = tick
        self.seat = seat
        self.kind = kind
    }
}

/// Which bot takes over a seat.
public enum TakeoverBot: String, Codable, Hashable, Sendable {
    /// A cautious lowest-tier bot sails a dropped player's boat until they rejoin (#19).
    case cautious
    /// A fleet bot takes a seat given away before the gun, for good (#16, #35).
    case fleet
}

/// A change in who is at a seat. Recorded in the race log so the end of the race (RET, every human
/// gone) and bot takeovers can be replayed (#30, #16, #19). Seat events don't move boats: a seat's
/// boat only ever answers to the inputs in the log.
public struct SeatEvent: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case joined(SeatKind)
        /// The player's socket closed.
        case disconnected
        /// The player's inputs stopped for longer than the 0.5 s input hold (#18).
        case dropped
        case botTookOver(TakeoverBot)
        case rejoined
        /// Left before the gun, giving the seat away (#35).
        case leftBeforeGun
        case left
    }

    public let tick: Int
    public let seat: Int
    public let kind: Kind

    public init(tick: Int, seat: Int, kind: Kind) {
        self.tick = tick
        self.seat = seat
        self.kind = kind
    }
}

/// A race as it's stored: its keys and every input and seat event exactly as applied (ADR 0002).
/// Replaying it with `Replayer` on the same simulation version reproduces the race bit for bit.
public struct RaceLog: Codable, Hashable, Sendable {
    /// Everything a replay needs besides the inputs (ADR 0002).
    public struct Header: Codable, Hashable, Sendable {
        /// Carries the simulation version, the race seed and the id, version and hash of the boat class,
        /// venue, conditions and rules configuration the race was sailed with (ADR 0004).
        public var setup: RaceSetup
        public var windSeed: WindSeed
        /// The tide state at the gun, radians in [0, 2π) (#11), or nil at a venue with no current. Drawn from the
        /// race seed and the venue, and recorded with the race's keys (ADR 0003): a replay checks that it
        /// draws the same.
        public var tideStateAtGun: Double?

        public var simulationVersion: String { setup.simulationVersion }
        public var raceSeed: RaceSeed { setup.raceSeed }

        public init(setup: RaceSetup, windSeed: WindSeed, tideStateAtGun: Double?) {
            self.setup = setup
            self.windSeed = windSeed
            self.tideStateAtGun = tideStateAtGun
        }
    }

    public var header: Header
    /// In the order applied: by tick, and within a tick held inputs by seat, then taps as they came.
    public var inputs: [InputRecord]
    /// By tick, in the order recorded.
    public var seatEvents: [SeatEvent]
    /// The race's tick when the log was taken. A replay steps the race to exactly this tick.
    public var finalTick: Int

    public init(header: Header, inputs: [InputRecord] = [], seatEvents: [SeatEvent] = [], finalTick: Int) {
        self.header = header
        self.inputs = inputs
        self.seatEvents = seatEvents
        self.finalTick = finalTick
    }

    /// Stable JSON: sorted keys, so the same log always encodes to the same bytes.
    public func jsonData(pretty: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted] : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public init(jsonData: Data) throws {
        self = try JSONDecoder().decode(RaceLog.self, from: jsonData)
    }
}

// MARK: - Coding
//
// Records are flat objects so a log stays compact and readable, and the format is spelled out here
// rather than left to synthesis: logs are kept for good, so it must not drift with the Swift compiler.
//
//   {"tick": -1790, "seat": 3, "rudder": -40, "ease": false}
//   {"tick": 12, "seat": 3, "tap": "tackGybe"}
//   {"tick": 12, "seat": 3, "tap": "protest", "target": 5}
//   {"tick": 400, "seat": 3, "event": "joined", "as": "human"}
//   {"tick": 400, "seat": 3, "event": "botTookOver", "bot": "cautious"}

extension InputRecord: Codable {
    private enum CodingKeys: String, CodingKey { case tick, seat, rudder, ease, tap, target }
    private enum TapName: String, Codable { case tackGybe, protest }

    /// Strict: a record is exactly a held input (`rudder`, `ease`) or exactly a tap (`tap`, plus `target`
    /// for a protest). Anything else is malformed and rejected, never read leniently.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tick = try c.decode(Int.self, forKey: .tick)
        seat = try c.decode(Int.self, forKey: .seat)
        func reject(_ key: CodingKeys, _ why: String) -> DecodingError {
            DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: why)
        }
        if let tap = try c.decodeIfPresent(TapName.self, forKey: .tap) {
            for key in [CodingKeys.rudder, .ease] where c.contains(key) {
                throw reject(key, "a tap record has no \(key.stringValue)")
            }
            switch tap {
            case .tackGybe:
                if c.contains(.target) { throw reject(.target, "a tackGybe tap has no target") }
                kind = .tap(.tackGybe)
            case .protest:
                kind = .tap(.protest(target: try c.decode(Int.self, forKey: .target)))
            }
        } else {
            if c.contains(.tap) { throw reject(.tap, "tap is null") }
            if c.contains(.target) { throw reject(.target, "a held input record has no target") }
            let raw = try c.decode(Int.self, forKey: .rudder)
            guard let input = BoatInput(checkedRudder: raw, ease: try c.decode(Bool.self, forKey: .ease)) else {
                throw DecodingError.dataCorruptedError(forKey: .rudder, in: c, debugDescription: "rudder \(raw) is outside −127…127")
            }
            kind = .held(input)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tick, forKey: .tick)
        try c.encode(seat, forKey: .seat)
        switch kind {
        case .held(let input):
            try c.encode(Int(input.rudder), forKey: .rudder)
            try c.encode(input.ease, forKey: .ease)
        case .tap(.tackGybe):
            try c.encode(TapName.tackGybe, forKey: .tap)
        case .tap(.protest(let target)):
            try c.encode(TapName.protest, forKey: .tap)
            try c.encode(target, forKey: .target)
        }
    }
}

extension SeatEvent: Codable {
    private enum CodingKeys: String, CodingKey { case tick, seat, event, `as`, bot }
    private enum EventName: String, Codable {
        case joined, disconnected, dropped, botTookOver, rejoined, leftBeforeGun, left
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tick = try c.decode(Int.self, forKey: .tick)
        seat = try c.decode(Int.self, forKey: .seat)
        switch try c.decode(EventName.self, forKey: .event) {
        case .joined: kind = .joined(try c.decode(SeatKind.self, forKey: .as))
        case .disconnected: kind = .disconnected
        case .dropped: kind = .dropped
        case .botTookOver: kind = .botTookOver(try c.decode(TakeoverBot.self, forKey: .bot))
        case .rejoined: kind = .rejoined
        case .leftBeforeGun: kind = .leftBeforeGun
        case .left: kind = .left
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tick, forKey: .tick)
        try c.encode(seat, forKey: .seat)
        switch kind {
        case .joined(let seatKind):
            try c.encode(EventName.joined, forKey: .event)
            try c.encode(seatKind, forKey: .as)
        case .disconnected: try c.encode(EventName.disconnected, forKey: .event)
        case .dropped: try c.encode(EventName.dropped, forKey: .event)
        case .botTookOver(let bot):
            try c.encode(EventName.botTookOver, forKey: .event)
            try c.encode(bot, forKey: .bot)
        case .rejoined: try c.encode(EventName.rejoined, forKey: .event)
        case .leftBeforeGun: try c.encode(EventName.leftBeforeGun, forKey: .event)
        case .left: try c.encode(EventName.left, forKey: .event)
        }
    }
}
