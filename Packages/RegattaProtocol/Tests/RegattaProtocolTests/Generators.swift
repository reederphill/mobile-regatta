import RegattaBots
import RegattaCore
@testable import RegattaProtocol

/// Seeded generators for property tests: SplitMix64 only, never the standard library's randomness,
/// so every run checks the same cases (ADR 0002's rule, kept here too).
struct Gen {
    var rng: SplitMix64

    init(seed: UInt64) { rng = SplitMix64(seed: seed) }

    mutating func int(_ range: ClosedRange<Int>) -> Int { rng.int(in: range) }
    mutating func bool() -> Bool { rng.bool() }
    mutating func double(_ a: Double, _ b: Double) -> Double { rng.range(a, b) }
    mutating func u16() -> UInt16 { UInt16(truncatingIfNeeded: rng.next()) }
    mutating func u32() -> UInt32 { UInt32(truncatingIfNeeded: rng.next()) }
    mutating func u64() -> UInt64 { rng.next() }
    mutating func tick() -> Int { int(-100_000...100_000) }
    mutating func bytes(_ count: ClosedRange<Int>) -> [UInt8] { (0..<int(count)).map { _ in UInt8(truncatingIfNeeded: rng.next()) } }

    /// ASCII, accented Latin, CJK and emoji, so multi-byte UTF-8 is covered.
    mutating func string(_ length: ClosedRange<Int> = 0...24) -> String {
        let pieces = ["a", "Z", "7", " ", "-", "é", "ß", "漢", "字", "⛵", "🙂", "\u{301}"]
        return (0..<int(length)).map { _ in pieces[int(0...(pieces.count - 1))] }.joined()
    }

    mutating func payload() -> VersionedPayload {
        bool() ? .none : VersionedPayload(schema: UInt16(int(1...65_535)), bytes: bytes(0...64))
    }

    mutating func fileRef() -> FileRef {
        let hex = bytes(32...32).map { byte in
            let s = String(byte, radix: 16)
            return s.count == 1 ? "0" + s : s
        }.joined()
        let letters = Array("abcdefghijklmnopqrstuvwxyz0123456789-")
        let id = String((0..<int(1...20)).map { _ in letters[int(0...(letters.count - 1))] })
        return FileRef(id: id, version: int(1...1000), hash: ContentHash(hex: hex)!)
    }

    mutating func input() -> BoatInput { BoatInput(rudder: Int8(int(-127...127)), ease: bool()) }

    mutating func tap(seats: Int = 16) -> BoatTap { bool() ? .tackGybe : .protest(target: int(0...(seats - 1))) }

    mutating func status() -> BoatStatus { [.prestart, .ocs, .racing, .finished, .dsq, .dnf][int(0...5)] }

    /// A seat with every field anywhere in its wire range.
    mutating func seat(_ id: Int) -> WorldSnapshot.Seat {
        _ = string() // was the boat's name (#60 moved names to the roster); kept so the cases don't move
        var boat = Boat(id: id, isPlayer: bool(), colorIndex: int(0...15),
                        position: Vec2(double(-32_000, 32_000), double(-32_000, 32_000)),
                        heading: double(-.pi, .pi), speed: double(0, 63.99))
        boat.rudder = double(-1, 1)
        boat.desiredRudder = double(-1, 1)
        boat.autopilot = bool() ? double(-.pi, .pi) : nil
        boat.status = status()
        boat.legIndex = int(0...255)
        boat.roundingStage = int(0...7)
        boat.penaltyTurnsOwed = int(0...7)
        boat.penaltyProgress = double(-31.9, 31.9)
        boat.isTacking = bool()
        boat.windDirection = double(-.pi, .pi)
        boat.windSpeed = double(0, 15)
        boat.shadow = double(0.6, 1)
        if bool() {
            boat.finishTime = Double(int(0...30_000)) / 30
            boat.place = int(1...16)
        }
        return WorldSnapshot.Seat(boat: boat, heldInput: input())
    }

    mutating func world(seats: Int) -> WorldSnapshot {
        WorldSnapshot(tick: tick(), seats: (0..<seats).map { seat($0) })
    }

    mutating func wireSeats(_ n: Int) -> [WireSeat] {
        (0..<n).map { _ in
            WireSeat(
                x: Int32(int(-(1 << 23)...((1 << 23) - 1))), y: Int32(int(-(1 << 23)...((1 << 23) - 1))),
                heading: Int16(truncatingIfNeeded: u16()), speed: u16(), rudder: Int16(int(-32_767...32_767)),
                autopilot: bool() ? Int16(truncatingIfNeeded: u16()) : nil, penaltyProgress: Int16(truncatingIfNeeded: u16()),
                heldInput: input(), isTacking: bool(), status: status(), penaltyTurnsOwed: UInt8(int(0...7)),
                roundingStage: UInt8(int(0...7)), legIndex: UInt8(int(0...255))
            )
        }
    }

    mutating func setup() -> RaceSetup {
        let seats: [SeatKind] = (0..<int(2...16)).map { _ in bool() ? .bot : .human }
        func file(_ g: inout Gen) -> FileRef? { g.bool() ? g.fileRef() : nil }
        return try! RaceSetup(
            simulationVersion: string(1...40), raceSeed: RaceSeed(u64()), seats: seats, laps: int(1...RaceStart.maxLaps),
            startSequenceTicks: int(1...RaceStart.maxStartSequenceTicks), boatClass: file(&self), venue: file(&self),
            conditions: file(&self), rulesConfiguration: file(&self)
        )
    }

    /// A value anywhere in `limit`: often exactly at an end, sometimes a subnormal.
    mutating func within(_ limit: ClosedRange<Double>) -> Double {
        switch int(0...5) {
        case 0: return limit.lowerBound
        case 1: return limit.upperBound
        case 2:
            let tiny = Double(bitPattern: u64() & 0x000F_FFFF_FFFF_FFFF)
            return limit.lowerBound < 0 && bool() ? -tiny : tiny
        default: return double(limit.lowerBound, limit.upperBound)
        }
    }

    /// A key with every field anywhere in the wire's bounds (`WindKeyWire`), in any window it allows.
    mutating func windKey(window: Int? = nil) -> WindKey {
        typealias B = WindKeyWire
        let shift = -B.shiftLimit...B.shiftLimit, slope = -B.slopeLimit...B.slopeLimit, wobble = -B.wobbleLimit...B.wobbleLimit
        return WindKey(window: window ?? int(0...B.maxWindow),
                       shift: WindKnot(value: within(shift), slope: within(slope)),
                       strength: WindKnot(value: within(B.strengthRange), slope: within(slope)),
                       wobble: WindWobble(hump: within(wobble), wiggle: within(wobble)), puffSeed: u64())
    }

    /// `windKey()` on a copy, for a single key from a fixed seed.
    func windKeyCopy() -> WindKey {
        var copy = self
        return copy.windKey()
    }

    /// Keys in strictly increasing windows, as the wire requires.
    mutating func windKeys() -> [WindKey] {
        var window = int(0...20)
        return (0..<int(0...6)).map { _ in
            defer { window += int(1...3) }
            return windKey(window: window)
        }
    }

    /// Every `RaceEvent.Kind`, by `index` (see `eventKindIndex`).
    mutating func eventKind(_ index: Int) -> RaceEvent.Kind {
        let seat = int(0...15)
        switch index {
        case 0: return .gun
        case 1: return .ocs(seat: seat)
        case 2: return .cleared(seat: seat)
        case 3: return .started(seat: seat)
        case 4:
            let rule = RacingRule.allCases[int(0...(RacingRule.allCases.count - 1))]
            return .foul(RuleCall(rule: rule, offender: seat, victim: int(0...15)))
        case 5: return .markTouch(seat: seat, mark: string())
        case 6: return .penaltyServed(seat: seat)
        case 7: return .rounded(seat: seat, mark: string())
        case 8: return .finished(seat: seat, place: int(1...16))
        case 9: return .disqualified(seat: seat, reason: string())
        case 10: return .protest(seat: seat, target: int(0...15))
        default: return .raceOver
        }
    }

    /// A random frame of `type`, with every field drawn from its whole range.
    mutating func frame(_ type: MessageType) -> Frame {
        let message: Message
        switch type {
        case .hello:
            message = .hello(Hello(protocolVersion: u16(), clientBuild: string(), simulationVersion: string(),
                                   files: (0..<int(0...5)).map { _ in fileRef() }, attestation: payload()))
        case .joinRace: message = .joinRace(JoinRace(token: bytes(0...200)))
        case .inputHeld: message = .inputHeld(input())
        case .inputTap: message = .inputTap(tap())
        case .ping: message = .ping(Ping(clientTime: u64()))
        case .requestResync: message = .requestResync
        case .helloAck: message = .helloAck(HelloAck(serverBuild: string()))
        case .updateRequired:
            // Any code: the known ones and codes from a newer server.
            message = .updateRequired(UpdateRequired(reason: UpdateRequired.Reason(code: UInt8(int(0...255))),
                                                     simulationVersion: string(), protocolVersion: u16()))
        case .raceStart:
            let setup = setup()
            message = .raceStart(RaceStart(
                yourSeat: int(0...(setup.fleetSize - 1)), setup: setup,
                roster: (0..<setup.fleetSize).map { _ in RosterEntry(name: string(), colorIndex: int(0...255)) },
                tide: payload(), windKeys: windKeys()))
        case .resync:
            let n = int(2...16)
            let finishes = (0..<int(0...n)).map { _ in EventState.Finish(seat: int(0...(n - 1)), place: int(1...n), tick: tick()) }
            message = .resync(Resync(
                raceSeed: RaceSeed(u64()), seats: wireSeats(n), windKeys: windKeys(),
                eventState: EventState(nextEventSeq: u32(), finishes: finishes, firstFinishTick: bool() ? tick() : nil,
                                       isOver: bool(), rules: payload())))
        case .snapshot:
            let ack = bool() ? InputAck(seq: u32(), appliedTick: tick(), margin: int(-32_768...32_767)) : nil
            message = .snapshot(Snapshot(seats: wireSeats(int(2...16)), ack: ack))
        case .event: message = .event(eventKind(int(0...11)))
        case .windKey: message = .windKey(windKey())
        case .pong: message = .pong(Pong(clientTime: u64(), sinceTickMicros: u16()))
        case .raceCancelled:
            message = .raceCancelled(RaceCancelled(reason: RaceCancelled.Reason(code: UInt8(int(0...255)))))
        case .raceClosed: message = .raceClosed(RaceClosed(results: payload()))
        }
        return Frame(seq: u32(), tick: int(Int(Int32.min)...Int(Int32.max)), message: message)
    }
}

/// The index of each `RaceEvent.Kind` case. Exhaustive, so a new case doesn't compile until the
/// generator and the codec cover it.
func eventKindIndex(_ kind: RaceEvent.Kind) -> Int {
    switch kind {
    case .gun: 0
    case .ocs: 1
    case .cleared: 2
    case .started: 3
    case .foul: 4
    case .markTouch: 5
    case .penaltyServed: 6
    case .rounded: 7
    case .finished: 8
    case .disqualified: 9
    case .protest: 10
    case .raceOver: 11
    }
}

let eventKindCount = 12

/// A fleet race with a bot sailing every seat, for real snapshots: starts, OCS, contacts, roundings, finishes.
func botRace(seats: Int = 16, laps: Int = 1, prestartSeconds: Int = 30, seed: UInt64 = 63,
             windSeed: WindSeed? = nil) -> BotSailedRace {
    let kinds: [SeatKind] = (0..<seats).map { $0 % 4 == 0 ? .human : .bot }
    let setup = try! RaceSetup(raceSeed: RaceSeed(seed), seats: kinds, laps: laps,
                               startSequenceTicks: prestartSeconds * Race.tickRate)
    return BotSailedRace(Race(setup: setup, windSeed: windSeed ?? WindSeed(seed &* 0x9E37_79B9_7F4A_7C15 &+ 1)))
}

/// A race whose seats are all sailed by RegattaBots' seat controllers through the input API (#60), as a
/// race host sails its bots: `step()` lets the bots decide, then steps the race. Reads the race's
/// properties through to it.
@dynamicMemberLookup
final class BotSailedRace {
    let race: Race
    private var seats: SeatControllers

    init(_ race: Race) {
        self.race = race
        seats = SeatControllers(race.boats.indices.map { .bot(BotDriver(seat: $0, raceSeed: race.setup.raceSeed)) })
    }

    subscript<T>(dynamicMember keyPath: KeyPath<Race, T>) -> T { race[keyPath: keyPath] }

    func step() {
        seats.drive(race)
        race.step()
    }

    func exportSnapshot() -> WorldSnapshot { race.exportSnapshot() }
    func drainEvents() -> [RaceEvent] { race.drainEvents() }
}
