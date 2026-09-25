import RegattaCore
@testable import RegattaProtocol
import Testing

/// Property tests: every message round-trips exactly through the codec, and the decoder accepts only
/// what the encoder produces.
@Suite struct RoundTripTests {
    static let casesPerType = 400

    @Test(arguments: MessageType.allCases)
    func everyMessageRoundTrips(type: MessageType) throws {
        var gen = Gen(seed: 0x63_0000 + UInt64(type.rawValue))
        for _ in 0..<Self.casesPerType {
            let frame = gen.frame(type)
            let bytes = try frame.encoded()
            #expect(bytes.first == type.rawValue)
            let decoded = try Frame(decoding: bytes)
            #expect(decoded == frame)
            #expect(try decoded.encoded() == bytes)
        }
    }

    /// The codec covers every `RaceEvent` case (`eventKindIndex` is exhaustive, so a new case fails to
    /// compile until the generator and the codec have it).
    @Test func everyRaceEventKindRoundTrips() throws {
        var gen = Gen(seed: 0xE7E7)
        var seen = Set<Int>()
        for index in 0..<eventKindCount {
            for _ in 0..<100 {
                let event = RaceEvent(tick: gen.tick(), kind: gen.eventKind(index))
                seen.insert(eventKindIndex(event.kind))
                let frame = Frame(seq: gen.u32(), event: event)
                let decoded = try Frame(decoding: frame.encoded())
                #expect(decoded.raceEvent == event)
            }
        }
        #expect(seen == Set(0..<eventKindCount))
    }

    /// Quantised fields come back within their step: world → wire → frame → world.
    @Test func quantisedSeatsRoundTripWithinTheirSteps() throws {
        var gen = Gen(seed: 0x5EA7)
        for _ in 0..<2000 {
            let world = gen.world(seats: gen.int(2...16))
            let frame = Frame(seq: 1, tick: world.tick, message: .snapshot(try Snapshot(world: world)))
            let decoded = try Frame(decoding: frame.encoded())
            guard case .snapshot(let snapshot) = decoded.message else { Issue.record("not a snapshot"); return }
            let back = try snapshot.applied(to: world, tick: decoded.tick, events: EventState(world: world, nextEventSeq: 0))
            #expect(back.tick == world.tick)
            for (a, b) in zip(world.seats, back.seats) { expectWithinSteps(a, b) }
            // Quantising again gives the same wire values.
            #expect(try Snapshot(world: back).seats == snapshot.seats)
        }
    }

    @Test func everyPrefixOfAFrameIsRejected() throws {
        var gen = Gen(seed: 0x7121)
        for type in MessageType.allCases {
            let bytes = try gen.frame(type).encoded()
            for length in 0..<bytes.count {
                #expect(throws: WireError.self) { try Frame(decoding: Array(bytes[..<length])) }
            }
            #expect(throws: WireError.trailingBytes(1)) { try Frame(decoding: bytes + [0]) }
        }
    }

    @Test func unknownTypesAndCodesAreRejected() throws {
        let known = Set(MessageType.allCases.map(\.rawValue))
        for code in 0...255 where !known.contains(UInt8(code)) {
            #expect(throws: WireError.unknownMessageType(UInt8(code))) { try Frame(decoding: [UInt8(code)] + Array(repeating: 0, count: 8)) }
        }
        let header: (MessageType) -> [UInt8] = { [$0.rawValue, 0, 0, 0, 0, 0, 0, 0, 0] }
        #expect(throws: WireError.invalidValue("event")) { try Frame(decoding: header(.event) + [22]) }
        // Code 4 was the pre-#73 `foul`: retired, never reused.
        #expect(throws: WireError.invalidValue("event")) { try Frame(decoding: header(.event) + [4, 14, 0, 1]) }
        #expect(throws: WireError.invalidValue("tap")) { try Frame(decoding: header(.inputTap) + [2]) }
        #expect(throws: WireError.invalidValue("ease")) { try Frame(decoding: header(.inputHeld) + [0, 2]) }
        #expect(throws: WireError.invalidValue("rudder")) { try Frame(decoding: header(.inputHeld) + [0x80, 0]) }
        // A rule call: incident id (u16), tick (i32), then the rule's code; there are 16 rules.
        #expect(throws: WireError.invalidValue("rule")) { try Frame(decoding: header(.event) + [12, 0, 0, 0, 0, 0, 0, 16]) }
        #expect(throws: WireError.invalidValue("obstruction")) { try Frame(decoding: header(.event) + [13, 0, 2]) }
        #expect(throws: WireError.invalidValue("contact")) { try Frame(decoding: header(.event) + [14, 3, 3]) }
        #expect(throws: WireError.invalidValue("contact")) { try Frame(decoding: header(.event) + [14, 3, 1]) }
        // Reasons are the exception: unknown codes decode as `.unknown` (HandshakeTests).
        // Schema 0 carries no bytes.
        #expect(throws: WireError.invalidValue("results")) { try Frame(decoding: header(.raceClosed) + [0, 0, 1, 7]) }
    }

    @Test func seatReservedBitsAndNonCanonicalValuesAreRejected() throws {
        var gen = Gen(seed: 0xB175)
        var seats = gen.wireSeats(2)
        seats[0].autopilot = nil
        let good = try Frame(seq: 0, tick: 0, message: .snapshot(Snapshot(seats: seats))).encoded()
        _ = try Frame(decoding: good)
        let seat0 = Frame.headerSize + 1 + 1 // header, no-ack flag, seat count
        func mutated(_ offset: Int, _ change: (inout UInt8) -> Void) -> [UInt8] {
            var bytes = good
            change(&bytes[seat0 + offset])
            return bytes
        }
        #expect(throws: WireError.invalidValue("status")) { try Frame(decoding: mutated(17) { $0 = $0 & 0b1100_0111 | 6 << 3 }) }
        #expect(throws: WireError.invalidValue("counts")) { try Frame(decoding: mutated(18) { $0 |= 0x80 }) }
        #expect(throws: WireError.invalidValue("autopilot")) { try Frame(decoding: mutated(12) { $0 = 1 }) } // value without the flag
        #expect(throws: WireError.invalidValue("autopilot")) { try Frame(decoding: mutated(17) { $0 |= 0x80 }) } // boom side without it
        #expect(throws: WireError.invalidValue("heldInput.rudder")) { try Frame(decoding: mutated(16) { $0 = 0x80 }) }
    }

    @Test func varintsMustBeShortestAndStringsValidUTF8() throws {
        let header: [UInt8] = [MessageType.helloAck.rawValue, 0, 0, 0, 0, 0, 0, 0, 0]
        #expect(try Frame(decoding: header + [1, 0x41]).message == .helloAck(HelloAck(serverBuild: "A")))
        #expect(throws: WireError.invalidValue("serverBuild")) { try Frame(decoding: header + [0x81, 0x00, 0x41]) }
        #expect(throws: WireError.invalidValue("serverBuild")) { try Frame(decoding: header + [2, 0xC3, 0x28]) }
        #expect(throws: WireError.tooLong("serverBuild")) { try Frame(decoding: header + [0x81, 0x02] + Array(repeating: 0x41, count: 257)) }
        // A length past the end is truncation, not a huge allocation.
        #expect(throws: WireError.truncated) { try Frame(decoding: header + [0xFF, 0x01]) }
        var r = WireReader(Array(repeating: 0xFF, count: 10) + [0x01])
        #expect(throws: WireError.invalidValue("v")) { try r.varint("v") }
        var max = WireWriter()
        max.varint(.max)
        var back = WireReader(max.bytes)
        #expect(try back.varint("v") == .max)
    }

    @Test func valuesTheWireCantCarryThrowOnEncode() throws {
        var gen = Gen(seed: 0x0E0E)
        func encode(_ message: Message, tick: Int = 0) throws { _ = try Frame(seq: 0, tick: tick, message: message).encoded() }
        #expect(throws: WireError.outOfRange("tick")) { try encode(.requestResync, tick: Int(Int32.max) + 1) }
        #expect(throws: WireError.outOfRange("target")) { try encode(.inputTap(.protest(target: 256))) }
        #expect(throws: WireError.outOfRange("seat")) { try encode(.event(.started(seat: -1))) }
        #expect(throws: WireError.outOfRange("results")) { try encode(.raceClosed(RaceClosed(results: VersionedPayload(schema: 0, bytes: [1])))) }
        var seats = gen.wireSeats(2)
        seats[1].x = 1 << 23
        #expect(throws: WireError.outOfRange("position.x")) { try encode(.snapshot(Snapshot(seats: seats))) }

        var world = gen.world(seats: 2)
        world.seats[1].boat.position.y = 40_000
        #expect(throws: WireError.outOfRange("position.y")) { try Snapshot(world: world) }
        world = gen.world(seats: 2)
        world.seats[0].boat.speed = 64
        #expect(throws: WireError.outOfRange("speed")) { try Snapshot(world: world) }
        world.seats[0].boat.speed = .nan
        #expect(throws: WireError.outOfRange("speed")) { try Snapshot(world: world) }
        world = gen.world(seats: 2)
        world.seats[0].boat.penaltyTurnsOwed = 8
        #expect(throws: WireError.outOfRange("penaltyTurnsOwed")) { try Snapshot(world: world) }
        world = gen.world(seats: 2)
        world.seats[0].boat.legIndex = 256
        #expect(throws: WireError.outOfRange("legIndex")) { try Snapshot(world: world) }
    }

    /// Bots look like humans on the wire (#18): who sails a seat changes nothing in a snapshot.
    @Test func aSeatsSnapshotBytesDontDependOnWhoSailsIt() throws {
        var gen = Gen(seed: 0xB07)
        for _ in 0..<200 {
            let world = gen.world(seats: 16)
            var relabelled = world
            for i in relabelled.seats.indices {
                relabelled.seats[i].boat = relabel(relabelled.seats[i].boat, isPlayer: !world.seats[i].boat.isPlayer)
            }
            let a = try Frame(seq: 1, tick: 1, message: .snapshot(Snapshot(world: world))).encoded()
            let b = try Frame(seq: 1, tick: 1, message: .snapshot(Snapshot(world: relabelled))).encoded()
            #expect(a == b)
        }
    }

    /// The bot flag is on the wire once, in the roster, and nowhere else in `RaceStart`.
    @Test func raceStartCarriesTheBotFlagOnlyInTheSeatTable() throws {
        let setup = try RaceSetup(raceSeed: RaceSeed(7), seats: [.human, .bot, .bot])
        let roster = ["Ann", "Gannet", "Petrel"].enumerated().map { RosterEntry(name: $0.element, colorIndex: $0.offset) }
        let start = RaceStart(yourSeat: 0, setup: setup, roster: roster)
        let decoded = try Frame(decoding: Frame(seq: 1, tick: -1800, message: .raceStart(start)).encoded())
        #expect(decoded.message == .raceStart(start))
        guard case .raceStart(let back) = decoded.message else { return }
        #expect(back.setup.seats == [.human, .bot, .bot])
        #expect(back.setup == setup)

        #expect(throws: WireError.outOfRange("roster")) {
            try Frame(seq: 1, tick: 0, message: .raceStart(RaceStart(yourSeat: 0, setup: setup, roster: Array(roster.prefix(2))))).encoded()
        }
        #expect(throws: WireError.outOfRange("yourSeat")) {
            try Frame(seq: 1, tick: 0, message: .raceStart(RaceStart(yourSeat: 3, setup: setup, roster: roster))).encoded()
        }
    }

    @Test func messageDirectionsAndStreams() {
        for type in MessageType.allCases {
            let clientSends: Set<MessageType> = [.hello, .joinRace, .inputHeld, .inputTap, .ping, .requestResync]
            #expect((type.direction == .clientToServer) == clientSends.contains(type))
        }
        #expect(MessageType.inputHeld.stream == .input && MessageType.inputTap.stream == .input)
        #expect(MessageType.event.stream == .reliable && MessageType.windKey.stream == .reliable)
        #expect(MessageType.snapshot.stream == .other)
    }

    @Test func eventAudiences() {
        var gen = Gen(seed: 0xA0D)
        for index in 0..<eventKindCount {
            let kind = gen.eventKind(index)
            let audience = EventAudience(kind)
            switch kind {
            case .protestRecorded(let seat, let target):
                #expect(audience == .seats([seat, target]))
                #expect(!EventAudience.seats([seat, target]).includes(seat: 16))
            case .ocsNotice(let recipient):
                #expect(audience == .seats([recipient]))
            case .markRoomNotice(let recipients):
                #expect(audience == .seats(recipients))
            default:
                #expect(audience == .everyone)
            }
            #expect((0..<16).allSatisfy { audience == .everyone ? audience.includes(seat: $0) : true })
        }
        let targeted = EventAudience.seats([4])
        #expect(targeted.includes(seat: 4))
        #expect((0..<16).filter { targeted.includes(seat: $0) } == [4])
    }
}

/// A copy of `boat` whose roster metadata (and so its bot flag) is changed.
func relabel(_ boat: Boat, isPlayer: Bool) -> Boat {
    var copy = Boat(id: boat.id, isPlayer: isPlayer, colorIndex: (boat.colorIndex + 5) % 16,
                    position: boat.position, heading: boat.heading, speed: boat.speed)
    copy.rudder = boat.rudder
    copy.desiredRudder = boat.desiredRudder
    copy.autopilot = boat.autopilot
    copy.status = boat.status
    copy.legIndex = boat.legIndex
    copy.roundingStage = boat.roundingStage
    copy.penaltyTurnsOwed = boat.penaltyTurnsOwed
    copy.penaltyProgress = boat.penaltyProgress
    copy.isTacking = boat.isTacking
    copy.boomSide = boat.boomSide
    copy.windDirection = boat.windDirection
    copy.windSpeed = boat.windSpeed
    copy.shadow = boat.shadow
    copy.finishTime = boat.finishTime
    copy.place = boat.place
    return copy
}
