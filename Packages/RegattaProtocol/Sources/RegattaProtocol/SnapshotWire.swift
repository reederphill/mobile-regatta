import RegattaCore

/// How the wire snapshot quantises each seat (#63). Every step is fine enough that a quantised import
/// predicts like the server's world for far longer than the 100 ms between snapshots (ADR 0005:
/// clients only have to be close), and the record stays small enough for 16 boats in 512 bytes (#18).
///
/// | Field                   | Wire    | Step                      | Range                         |
/// |-------------------------|---------|---------------------------|-------------------------------|
/// | position x, y           | int24   | 1/256 m (3.9 mm)          | ±32 768 m from the course origin |
/// | heading, autopilot      | int16   | 1/65 536 turn (0.0055°)   | a full turn, −π ..< π         |
/// | speed                   | uint16  | 1/1024 m/s                | 0 ..< 64 m/s                  |
/// | rudder (actual)         | int16   | 1/32 767                  | −1 … 1                        |
/// | penalty progress        | int16   | 1/1024 rad                | ±32 rad (5 turns)             |
/// | held rudder             | int8    | exact                     | −127 … 127                    |
/// | status, turns owed, rounding stage | bits | exact            | 3 bits each                   |
/// | ease, autopilot, tacking, boom sides | bits | exact          | 1 bit each                    |
/// | leg index               | uint8   | exact                     | 0 … 255                       |
///
/// Rounding is to nearest, so a field's error is at most half its step. A value outside its range
/// can't be sent: encoding throws `WireError.outOfRange` rather than clamping it.
///
/// None of the ranges can be reached in a valid race: boats can't leave the race area, which a venue
/// keeps well inside ±32 km of the course origin, speeds stay far below 64 m/s, and penalty turns are
/// capped at 4. So an out-of-range throw on the host (#65) is a simulation bug, never a player's
/// doing: the host logs it, skips that snapshot and keeps the race running, and clients keep
/// predicting until the next snapshot that encodes. It never clamps, which would hide the bug.
public enum SnapshotQuantisation {
    public static let positionStep = 1.0 / 256
    public static let headingStep = 2 * Double.pi / 65_536
    public static let speedStep = 1.0 / 1024
    public static let rudderStep = 1.0 / 32_767
    public static let penaltyProgressStep = 1.0 / 1024

    /// Bytes per seat in a wire snapshot.
    public static let bytesPerSeat = 20

    static func quantise(_ value: Double, step: Double, in range: ClosedRange<Int>, _ field: String) throws -> Int {
        guard value.isFinite else { throw WireError.outOfRange(field) }
        let q = (value / step).rounded()
        guard q >= Double(range.lowerBound), q <= Double(range.upperBound) else { throw WireError.outOfRange(field) }
        return Int(q)
    }

    /// An angle as 1/65 536ths of a turn, −32 768 ..< 32 768 (π and −π are the same code).
    static func angle(_ radians: Double, _ field: String) throws -> Int16 {
        let q = try quantise(wrapAngle(radians), step: headingStep, in: -32_768...32_768, field)
        return Int16(truncatingIfNeeded: q) // 32 768, half a turn, wraps to −32 768
    }

    static func radians(_ q: Int16) -> Double { Double(q) * headingStep }
}

/// The tack/gybe autopilot on the wire: its heading in 1/65 536ths of a turn, and its boom side.
public struct WireAutopilot: Hashable, Sendable {
    public var heading: Int16
    public var boomSide: BoomSide

    public init(heading: Int16, boomSide: BoomSide) {
        self.heading = heading
        self.boomSide = boomSide
    }
}

/// One seat of a wire snapshot, in quantised units (`SnapshotQuantisation`). The same for a bot's
/// seat as for a human's: the bot flag is roster metadata in `RaceStart`, never here (#18, #19).
public struct WireSeat: Hashable, Sendable {
    /// Position in 1/256 m, each within int24.
    public var x: Int32
    public var y: Int32
    public var heading: Int16
    public var speed: UInt16
    public var rudder: Int16
    public var autopilot: WireAutopilot?
    public var penaltyProgress: Int16
    public var heldInput: BoatInput
    public var isTacking: Bool
    public var boomSide: BoomSide
    public var status: BoatStatus
    /// 0…7.
    public var penaltyTurnsOwed: UInt8
    /// 0…7.
    public var roundingStage: UInt8
    public var legIndex: UInt8

    public init(
        x: Int32, y: Int32, heading: Int16, speed: UInt16, rudder: Int16, autopilot: WireAutopilot?, penaltyProgress: Int16,
        heldInput: BoatInput, isTacking: Bool, boomSide: BoomSide, status: BoatStatus, penaltyTurnsOwed: UInt8,
        roundingStage: UInt8, legIndex: UInt8
    ) {
        self.x = x
        self.y = y
        self.heading = heading
        self.speed = speed
        self.rudder = rudder
        self.autopilot = autopilot
        self.penaltyProgress = penaltyProgress
        self.heldInput = heldInput
        self.isTacking = isTacking
        self.boomSide = boomSide
        self.status = status
        self.penaltyTurnsOwed = penaltyTurnsOwed
        self.roundingStage = roundingStage
        self.legIndex = legIndex
    }

    /// Quantises a seat of the world. Throws `WireError.outOfRange` for a value the wire can't carry.
    public init(_ seat: WorldSnapshot.Seat) throws {
        typealias Q = SnapshotQuantisation
        let b = seat.boat
        let int24 = -(1 << 23)...((1 << 23) - 1)
        x = Int32(try Q.quantise(b.position.x, step: Q.positionStep, in: int24, "position.x"))
        y = Int32(try Q.quantise(b.position.y, step: Q.positionStep, in: int24, "position.y"))
        heading = try Q.angle(b.heading, "heading")
        speed = UInt16(try Q.quantise(b.speed, step: Q.speedStep, in: 0...65_535, "speed"))
        rudder = Int16(try Q.quantise(b.rudder, step: Q.rudderStep, in: -32_767...32_767, "rudder"))
        autopilot = try b.autopilot.map { WireAutopilot(heading: try Q.angle($0.heading, "autopilot"), boomSide: $0.boomSide) }
        penaltyProgress = Int16(try Q.quantise(b.penaltyProgress, step: Q.penaltyProgressStep, in: -32_768...32_767, "penaltyProgress"))
        heldInput = seat.heldInput
        isTacking = b.isTacking
        boomSide = b.boomSide
        status = b.status
        guard let owed = UInt8(exactly: b.penaltyTurnsOwed), owed <= 7 else { throw WireError.outOfRange("penaltyTurnsOwed") }
        guard let stage = UInt8(exactly: b.roundingStage), stage <= 7 else { throw WireError.outOfRange("roundingStage") }
        guard let leg = UInt8(exactly: b.legIndex) else { throw WireError.outOfRange("legIndex") }
        penaltyTurnsOwed = owed
        roundingStage = stage
        legIndex = leg
    }

    /// Overwrites the fields the wire carries; the rest of `seat` (`SnapshotFields.excluded`) stays.
    public func apply(to seat: inout WorldSnapshot.Seat) {
        typealias Q = SnapshotQuantisation
        seat.boat.position = Vec2(Double(x) * Q.positionStep, Double(y) * Q.positionStep)
        seat.boat.heading = Q.radians(heading)
        seat.boat.speed = Double(speed) * Q.speedStep
        seat.boat.rudder = Double(rudder) * Q.rudderStep
        seat.boat.autopilot = autopilot.map { Autopilot(heading: Q.radians($0.heading), boomSide: $0.boomSide) }
        seat.boat.penaltyProgress = Double(penaltyProgress) * Q.penaltyProgressStep
        seat.boat.isTacking = isTacking
        seat.boat.boomSide = boomSide
        seat.boat.status = status
        seat.boat.penaltyTurnsOwed = Int(penaltyTurnsOwed)
        seat.boat.roundingStage = Int(roundingStage)
        seat.boat.legIndex = Int(legIndex)
        seat.heldInput = heldInput
    }

    // Layout, 20 bytes: x int24, y int24, heading int16, speed uint16, rudder int16, autopilot int16
    // (0 when absent), penalty progress int16, held rudder int8, then two flag bytes and the leg index.
    //   flags:  bit 0 ease, bit 1 has autopilot, bit 2 tacking, bits 3–5 status, bit 6 boom to starboard,
    //           bit 7 the autopilot's boom to starboard (zero without an autopilot)
    //   counts: bits 0–2 penalty turns owed, bits 3–5 rounding stage, bits 6–7 zero

    func encode(to w: inout WireWriter) throws {
        guard penaltyTurnsOwed <= 7 else { throw WireError.outOfRange("penaltyTurnsOwed") }
        guard roundingStage <= 7 else { throw WireError.outOfRange("roundingStage") }
        guard rudder != Int16.min else { throw WireError.outOfRange("rudder") } // −1 is −32 767
        try w.i24(x, "position.x")
        try w.i24(y, "position.y")
        w.i16(heading)
        w.u16(speed)
        w.i16(rudder)
        w.i16(autopilot?.heading ?? 0)
        w.i16(penaltyProgress)
        w.i8(heldInput.rudder)
        var flags: UInt8 = heldInput.ease ? 1 : 0
        if autopilot != nil { flags |= 1 << 1 }
        if isTacking { flags |= 1 << 2 }
        flags |= status.wireCode << 3
        if boomSide == .starboard { flags |= 1 << 6 }
        if autopilot?.boomSide == .starboard { flags |= 1 << 7 }
        w.u8(flags)
        w.u8(penaltyTurnsOwed | roundingStage << 3)
        w.u8(legIndex)
    }

    init(from r: inout WireReader) throws {
        x = try r.i24()
        y = try r.i24()
        heading = try r.i16()
        speed = try r.u16()
        rudder = try r.i16()
        guard rudder != Int16.min else { throw WireError.invalidValue("rudder") }
        let pilot = try r.i16()
        penaltyProgress = try r.i16()
        let held = try r.i8()
        guard held != Int8.min else { throw WireError.invalidValue("heldInput.rudder") }
        let flags = try r.u8()
        let counts = try r.u8()
        legIndex = try r.u8()
        guard counts >> 6 == 0 else { throw WireError.invalidValue("counts") }
        guard let status = BoatStatus(wireCode: flags >> 3 & 0b111) else { throw WireError.invalidValue("status") }
        let hasAutopilot = flags & 1 << 1 != 0
        guard hasAutopilot || (pilot == 0 && flags & 1 << 7 == 0) else { throw WireError.invalidValue("autopilot") }
        heldInput = BoatInput(rudder: held, ease: flags & 1 != 0)
        autopilot = hasAutopilot ? WireAutopilot(heading: pilot, boomSide: flags & 1 << 7 != 0 ? .starboard : .port) : nil
        isTacking = flags & 1 << 2 != 0
        boomSide = flags & 1 << 6 != 0 ? .starboard : .port
        self.status = status
        penaltyTurnsOwed = counts & 0b111
        roundingStage = counts >> 3 & 0b111
    }
}

extension BoatStatus {
    /// Stable wire codes, independent of declaration order.
    var wireCode: UInt8 {
        switch self {
        case .prestart: 0
        case .ocs: 1
        case .racing: 2
        case .finished: 3
        case .dsq: 4
        case .dnf: 5
        }
    }

    init?(wireCode: UInt8) {
        switch wireCode {
        case 0: self = .prestart
        case 1: self = .ocs
        case 2: self = .racing
        case 3: self = .finished
        case 4: self = .dsq
        case 5: self = .dnf
        default: return nil
        }
    }
}

/// Which fields of a seat (`WorldSnapshot.Seat`) the wire snapshot carries, and which it leaves out.
/// `SnapshotCoverageTests` reflects `WorldSnapshot.Seat` and fails when a stored field is in neither
/// list, so a core ticket that adds state to `Boat` or to a seat has to decide here (#70, #71, #79,
/// #85, #86, #89, #96 extend it).
public enum SnapshotFields {
    /// Carried by `WireSeat`, as paths into `WorldSnapshot.Seat`.
    public static let wire: [String] = [
        "boat.position", "boat.heading", "boat.speed", "boat.rudder", "boat.autopilot",
        "boat.status", "boat.legIndex", "boat.roundingStage",
        "boat.penaltyTurnsOwed", "boat.penaltyProgress", "boat.isTacking", "boat.boomSide",
        "heldInput.rudder", "heldInput.ease",
    ]

    /// Left out, with why and where a receiver gets it. A receiver keeps its own value
    /// (`WireSeat.apply(to:)` merges into its snapshot).
    public static let excluded: [String: String] = [
        "boat.id": "the seat index: the seat's position in the snapshot",
        "boat.isPlayer": "the bot flag: roster metadata in RaceStart only, so bots look like humans on the wire (#18, #19)",
        "boat.colorIndex": "roster metadata, sent once in RaceStart's seat table",
        "boat.desiredRudder": "derived: set from the held input or the autopilot every tick before it is read",
        "boat.windDirection": "derived: sampled from the wind at the start of every step",
        "boat.windSpeed": "derived: sampled from the wind at the start of every step",
        "boat.shadow": "derived: recomputed from the fleet at the start of every step",
        "boat.finishTime": "event state (`EventState`, from Resync and the reliable `finished` event), applied with every snapshot",
        "boat.place": "event state (`EventState`, from Resync and the reliable `finished` event), applied with every snapshot",
    ]
}

/// The quantised seats of a world.
func wireSeats(of world: WorldSnapshot) throws -> [WireSeat] {
    guard world.seats.count <= WireLimit.seats else { throw WireError.tooLong("seats") }
    return try world.seats.map(WireSeat.init)
}

/// `base` with `seats` merged in at `tick`. Race-level state stays as the base has it.
func merge(_ seats: [WireSeat], into base: WorldSnapshot, tick: Int) throws -> WorldSnapshot {
    guard seats.count == base.seats.count else {
        throw WorldSnapshotError.seatCount(expected: base.seats.count, found: seats.count)
    }
    var world = base
    world.tick = tick
    for i in seats.indices { seats[i].apply(to: &world.seats[i]) }
    return world
}

func encodeSeats(_ seats: [WireSeat], to w: inout WireWriter) throws {
    try w.count(seats.count, limit: WireLimit.seats, "seats")
    for seat in seats { try seat.encode(to: &w) }
}

func decodeSeats(from r: inout WireReader) throws -> [WireSeat] {
    let n = try r.count(limit: WireLimit.seats, "seats")
    return try (0..<n).map { _ in try WireSeat(from: &r) }
}
