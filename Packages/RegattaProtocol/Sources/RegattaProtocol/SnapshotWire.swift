import RegattaCore

/// How the wire snapshot quantises each seat (#63). Every step is fine enough that a quantised import
/// predicts like the server's world for far longer than the 100 ms between snapshots (ADR 0005:
/// clients only have to be close), and the record stays small enough for 16 boats in 512 bytes (#18).
///
/// | Field                   | Wire    | Step                      | Range                         |
/// |-------------------------|---------|---------------------------|-------------------------------|
/// | position x, y           | int24   | 1/256 m (3.9 mm)          | ±32 768 m from the course origin |
/// | heading, autohelm angle  | int16   | 1/65 536 turn (0.0055°)   | a full turn, −π ..< π         |
/// | speed, averaged wind    | uint16  | 1/1024 m/s                | 0 ..< 64 m/s                  |
/// | spinnaker hoist or drop left | uint8 | a tick (1/30 s)        | 0 … 8.5 s                     |
/// | rudder (actual)         | int16   | 1/32 767                  | −1 … 1                        |
/// | penalty progress        | int16   | 1/1024 rad                | ±32 rad (5 turns)             |
/// | held rudder             | int8    | exact                     | −127 … 127                    |
/// | status, turns owed, rounding stage | bits | exact            | 3 bits each                   |
/// | ease, autohelm, its groove and tap, tacking, boom side, planing, averaged wind | bits | exact | 1 bit each |
/// | spinnaker               | bits    | exact                     | 2 bits                        |
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
    /// A hoist or drop's time left, seconds: a tick.
    public static let spinnakerStep = Race.dt

    /// Bytes per seat in a wire snapshot.
    public static let bytesPerSeat = 24

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

/// The autohelm on the wire (ADR 0007, #230): the sailing angle it holds in 1/65 536ths of a turn, or
/// the groove it holds, and whether it is sailing the tack/gybe tap.
public struct WireAutohelm: Hashable, Sendable {
    public enum Target: Hashable, Sendable {
        case angle(Int16)
        case groove(Autohelm.Groove)
    }

    public var target: Target
    public var isTapping: Bool

    public init(target: Target, isTapping: Bool) {
        self.target = target
        self.isTapping = isTapping
    }

    /// Quantises `autohelm`. Throws `WireError.outOfRange` for an angle that isn't finite.
    public init(_ autohelm: Autohelm) throws {
        switch autohelm.target {
        case .angle(let angle): target = .angle(try SnapshotQuantisation.angle(angle, "autohelm"))
        case .groove(let groove): target = .groove(groove)
        }
        isTapping = autohelm.isTapping
    }

    /// The autohelm this stands for.
    public var autohelm: Autohelm {
        switch target {
        case .angle(let q): Autohelm(target: .angle(SnapshotQuantisation.radians(q)), isTapping: isTapping)
        case .groove(let groove): Autohelm(target: .groove(groove), isTapping: isTapping)
        }
    }
}

/// The spinnaker on the wire (#248): its state, and a hoist or drop's time left in ticks (`SnapshotQuantisation.spinnakerStep`).
public enum WireSpinnaker: Hashable, Sendable {
    case down
    case hoisting(UInt8)
    case up
    case dropping(UInt8)

    /// Quantises `spinnaker`. Throws `WireError.outOfRange` for a time left the wire can't carry.
    public init(_ spinnaker: Spinnaker) throws {
        func ticks(_ remaining: Double) throws -> UInt8 {
            UInt8(try SnapshotQuantisation.quantise(remaining, step: SnapshotQuantisation.spinnakerStep, in: 0...255, "spinnaker"))
        }
        switch spinnaker {
        case .down: self = .down
        case .hoisting(let remaining): self = .hoisting(try ticks(remaining))
        case .up: self = .up
        case .dropping(let remaining): self = .dropping(try ticks(remaining))
        }
    }

    /// The spinnaker this stands for.
    public var spinnaker: Spinnaker {
        switch self {
        case .down: .down
        case .hoisting(let q): .hoisting(remaining: Double(q) * SnapshotQuantisation.spinnakerStep)
        case .up: .up
        case .dropping(let q): .dropping(remaining: Double(q) * SnapshotQuantisation.spinnakerStep)
        }
    }

    var code: UInt8 {
        switch self {
        case .down: 0
        case .hoisting: 1
        case .up: 2
        case .dropping: 3
        }
    }

    var ticksLeft: UInt8 {
        switch self {
        case .hoisting(let q), .dropping(let q): q
        case .down, .up: 0
        }
    }

    /// From its 2-bit code and the time-left byte, which must be 0 when it is up or down.
    init?(code: UInt8, ticksLeft: UInt8) {
        switch code {
        case 0 where ticksLeft == 0: self = .down
        case 1: self = .hoisting(ticksLeft)
        case 2 where ticksLeft == 0: self = .up
        case 3: self = .dropping(ticksLeft)
        default: return nil
        }
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
    public var autohelm: WireAutohelm?
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
    /// #248: on the plane, the spinnaker, and the average of the wind speed her grooves follow in
    /// 1/1024 m/s (nil before the race first samples her wind). The client predicts all three (ADR 0007).
    public var isPlaning: Bool
    public var spinnaker: WireSpinnaker
    public var averagedWindSpeed: UInt16?

    public init(
        x: Int32, y: Int32, heading: Int16, speed: UInt16, rudder: Int16, autohelm: WireAutohelm?, penaltyProgress: Int16,
        heldInput: BoatInput, isTacking: Bool, boomSide: BoomSide, status: BoatStatus, penaltyTurnsOwed: UInt8,
        roundingStage: UInt8, legIndex: UInt8, isPlaning: Bool = false, spinnaker: WireSpinnaker = .down,
        averagedWindSpeed: UInt16? = nil
    ) {
        self.x = x
        self.y = y
        self.heading = heading
        self.speed = speed
        self.rudder = rudder
        self.autohelm = autohelm
        self.penaltyProgress = penaltyProgress
        self.heldInput = heldInput
        self.isTacking = isTacking
        self.boomSide = boomSide
        self.status = status
        self.penaltyTurnsOwed = penaltyTurnsOwed
        self.roundingStage = roundingStage
        self.legIndex = legIndex
        self.isPlaning = isPlaning
        self.spinnaker = spinnaker
        self.averagedWindSpeed = averagedWindSpeed
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
        autohelm = try b.autohelm.map(WireAutohelm.init)
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
        isPlaning = b.isPlaning
        spinnaker = try WireSpinnaker(b.spinnaker)
        averagedWindSpeed = try b.averagedWindSpeed.map {
            UInt16(try Q.quantise($0, step: Q.speedStep, in: 0...65_535, "averagedWindSpeed"))
        }
    }

    /// Overwrites the fields the wire carries; the rest of `seat` (`SnapshotFields.excluded`) stays.
    public func apply(to seat: inout WorldSnapshot.Seat) {
        typealias Q = SnapshotQuantisation
        seat.boat.position = Vec2(Double(x) * Q.positionStep, Double(y) * Q.positionStep)
        seat.boat.heading = Q.radians(heading)
        seat.boat.speed = Double(speed) * Q.speedStep
        seat.boat.rudder = Double(rudder) * Q.rudderStep
        seat.boat.autohelm = autohelm?.autohelm
        seat.boat.penaltyProgress = Double(penaltyProgress) * Q.penaltyProgressStep
        seat.boat.isTacking = isTacking
        seat.boat.boomSide = boomSide
        seat.boat.status = status
        seat.boat.penaltyTurnsOwed = Int(penaltyTurnsOwed)
        seat.boat.roundingStage = Int(roundingStage)
        seat.boat.legIndex = Int(legIndex)
        seat.boat.isPlaning = isPlaning
        seat.boat.spinnaker = spinnaker.spinnaker
        seat.boat.averagedWindSpeed = averagedWindSpeed.map { Double($0) * Q.speedStep }
        seat.heldInput = heldInput
    }

    // Layout, 24 bytes: x int24, y int24, heading int16, speed uint16, rudder int16, autohelm angle int16
    // (0 for the groove or without an autohelm), penalty progress int16, held rudder int8, then two flag
    // bytes and the leg index; then (#248) a sails byte, the spinnaker's ticks left uint8 (0 unless it is
    // going up or coming down) and the averaged wind uint16 (0 without one).
    //   flags:  bit 0 ease, bit 1 has autohelm, bit 2 tacking, bits 3–5 status, bit 6 boom to starboard,
    //           bit 7 the autohelm is sailing the tap
    //   counts: bits 0–2 penalty turns owed, bits 3–5 rounding stage, bit 6 the autohelm holds the groove,
    //           bit 7 that groove is the downwind one
    //   sails:  bits 0–1 spinnaker (down, going up, up, coming down), bit 2 planing, bit 3 has an averaged
    //           wind; bits 4–7 zero
    // Every autohelm bit is zero without an autohelm, and the downwind bit without the groove.

    func encode(to w: inout WireWriter) throws {
        guard penaltyTurnsOwed <= 7 else { throw WireError.outOfRange("penaltyTurnsOwed") }
        guard roundingStage <= 7 else { throw WireError.outOfRange("roundingStage") }
        guard rudder != Int16.min else { throw WireError.outOfRange("rudder") } // −1 is −32 767
        try w.i24(x, "position.x")
        try w.i24(y, "position.y")
        w.i16(heading)
        w.u16(speed)
        w.i16(rudder)
        if case .angle(let angle) = autohelm?.target { w.i16(angle) } else { w.i16(0) }
        w.i16(penaltyProgress)
        w.i8(heldInput.rudder)
        var flags: UInt8 = heldInput.ease ? 1 : 0
        if autohelm != nil { flags |= 1 << 1 }
        if isTacking { flags |= 1 << 2 }
        flags |= status.wireCode << 3
        if boomSide == .starboard { flags |= 1 << 6 }
        if autohelm?.isTapping == true { flags |= 1 << 7 }
        w.u8(flags)
        var counts = penaltyTurnsOwed | roundingStage << 3
        if case .groove(let groove) = autohelm?.target {
            counts |= 1 << 6
            if groove == .downwind { counts |= 1 << 7 }
        }
        w.u8(counts)
        w.u8(legIndex)
        var sails = spinnaker.code
        if isPlaning { sails |= 1 << 2 }
        if averagedWindSpeed != nil { sails |= 1 << 3 }
        w.u8(sails)
        w.u8(spinnaker.ticksLeft)
        w.u16(averagedWindSpeed ?? 0)
    }

    init(from r: inout WireReader) throws {
        x = try r.i24()
        y = try r.i24()
        heading = try r.i16()
        speed = try r.u16()
        rudder = try r.i16()
        guard rudder != Int16.min else { throw WireError.invalidValue("rudder") }
        let angle = try r.i16()
        penaltyProgress = try r.i16()
        let held = try r.i8()
        guard held != Int8.min else { throw WireError.invalidValue("heldInput.rudder") }
        let flags = try r.u8()
        let counts = try r.u8()
        legIndex = try r.u8()
        let sails = try r.u8()
        let ticksLeft = try r.u8()
        let averaged = try r.u16()
        guard sails >> 4 == 0, let kite = WireSpinnaker(code: sails & 0b11, ticksLeft: ticksLeft) else {
            throw WireError.invalidValue("spinnaker")
        }
        let hasAverage = sails & 1 << 3 != 0
        guard hasAverage || averaged == 0 else { throw WireError.invalidValue("averagedWindSpeed") }
        spinnaker = kite
        isPlaning = sails & 1 << 2 != 0
        averagedWindSpeed = hasAverage ? averaged : nil
        guard let status = BoatStatus(wireCode: flags >> 3 & 0b111) else { throw WireError.invalidValue("status") }
        let hasAutohelm = flags & 1 << 1 != 0, isTapping = flags & 1 << 7 != 0
        let isGroove = counts & 1 << 6 != 0, isDownwind = counts & 1 << 7 != 0
        guard hasAutohelm || (angle == 0 && !isTapping && !isGroove), isGroove ? angle == 0 : !isDownwind else {
            throw WireError.invalidValue("autohelm")
        }
        heldInput = BoatInput(rudder: held, ease: flags & 1 != 0)
        autohelm = hasAutohelm
            ? WireAutohelm(target: isGroove ? .groove(isDownwind ? .downwind : .upwind) : .angle(angle), isTapping: isTapping)
            : nil
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
        "boat.position", "boat.heading", "boat.speed", "boat.rudder", "boat.autohelm",
        "boat.status", "boat.legIndex", "boat.roundingStage",
        "boat.penaltyTurnsOwed", "boat.penaltyProgress", "boat.isTacking", "boat.boomSide",
        "boat.isPlaning", "boat.spinnaker", "boat.averagedWindSpeed",
        "heldInput.rudder", "heldInput.ease",
    ]

    /// Left out, with why and where a receiver gets it. A receiver keeps its own value
    /// (`WireSeat.apply(to:)` merges into its snapshot).
    public static let excluded: [String: String] = [
        "boat.id": "the seat index: the seat's position in the snapshot",
        "boat.isPlayer": "the bot flag: roster metadata in RaceStart only, so bots look like humans on the wire (#18, #19)",
        "boat.colorIndex": "roster metadata, sent once in RaceStart's seat table",
        "boat.desiredRudder": "derived: set from the held input or the autohelm every tick before it is read",
        "boat.windOverGround": "derived: sampled from the wind at the start of every step",
        "boat.sailingWind": "derived: resolved from the wind and the current at the start of every step",
        "boat.apparentWind": "derived: resolved from the sailing wind and the boat's velocity at the start of every step",
        "boat.current": "derived: sampled from the current at the start of every step",
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

/// `base` with `seats` merged in at `tick`. Race-level state stays as the base has it, but for the
/// obstruction contacts it began after `tick` (#82): the receiver's own prediction ahead of the server,
/// which it sails again from here (and a snapshot can't hold contacts from after its tick).
func merge(_ seats: [WireSeat], into base: WorldSnapshot, tick: Int) throws -> WorldSnapshot {
    guard seats.count == base.seats.count else {
        throw WorldSnapshotError.seatCount(expected: base.seats.count, found: seats.count)
    }
    var world = base
    world.tick = tick
    world.incidents.forgetObstructionContacts(after: tick)
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
