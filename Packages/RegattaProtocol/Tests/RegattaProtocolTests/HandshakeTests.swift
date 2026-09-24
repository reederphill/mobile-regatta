import RegattaBots
import RegattaCore
@testable import RegattaProtocol
import Testing

/// Forward compatibility of the handshake (`wireProtocolVersion`): whatever a future version changes,
/// a server can read a `Hello`'s version and every client can read `UpdateRequired`.
@Suite struct HandshakeTests {
    @Test func aHellosVersionIsReadableWithoutItsBody() throws {
        let hello = try Frame(seq: 1, tick: 0, message: .hello(Hello(clientBuild: "1.0 (1)", files: []))).encoded()
        #expect(Frame.helloProtocolVersion(in: hello) == wireProtocolVersion)

        // A future client's Hello: version 7, then a body this build can't decode.
        let future: [UInt8] = [MessageType.hello.rawValue, 1, 0, 0, 0, 0, 0, 0, 0, 7, 0, 0xFF, 0xFF, 0xFF]
        #expect(Frame.helloProtocolVersion(in: future) == 7)
        #expect(throws: WireError.self) { try Frame(decoding: future) }

        #expect(Frame.helloProtocolVersion(in: Array(hello.prefix(Frame.headerSize + 1))) == nil)
        #expect(Frame.helloProtocolVersion(in: try Frame(seq: 1, tick: 0, message: .ping(Ping(clientTime: 0))).encoded()) == nil)
        #expect(Frame.helloProtocolVersion(in: []) == nil)
    }

    /// The frozen layouts, byte for byte: changing any of these breaks every older or newer peer.
    @Test func frozenLayoutsArePinned() throws {
        let hello = try Frame(seq: 0x0102_0304, tick: -2, message: .hello(Hello(protocolVersion: 0x0A0B, clientBuild: "b", simulationVersion: "s", files: []))).encoded()
        #expect(Array(hello.prefix(11)) == [1, 0x04, 0x03, 0x02, 0x01, 0xFE, 0xFF, 0xFF, 0xFF, 0x0B, 0x0A])

        let update = Frame(seq: 5, tick: 300, message: .updateRequired(UpdateRequired(reason: .simulationVersion, simulationVersion: "2/x", protocolVersion: 1)))
        let bytes = try update.encoded()
        #expect(bytes == [17, 5, 0, 0, 0, 0x2C, 0x01, 0, 0, 2, 3, 0x32, 0x2F, 0x78, 1, 0])
        #expect(try Frame(decoding: bytes) == update)
    }

    @Test func unknownReasonCodesAreKeptNotRejected() throws {
        let update = try Frame(decoding: [17, 0, 0, 0, 0, 0, 0, 0, 0, 200, 1, 0x39, 9, 0])
        #expect(update.message == .updateRequired(UpdateRequired(reason: .unknown(200), simulationVersion: "9", protocolVersion: 9)))
        #expect(try update.encoded() == [17, 0, 0, 0, 0, 0, 0, 0, 0, 200, 1, 0x39, 9, 0])

        let cancelled = try Frame(decoding: [MessageType.raceCancelled.rawValue, 0, 0, 0, 0, 0, 0, 0, 0, 77])
        #expect(cancelled.message == .raceCancelled(RaceCancelled(reason: .unknown(77))))
        #expect(try cancelled.encoded().last == 77)

        for reason in UpdateRequired.Reason.known { #expect(UpdateRequired.Reason(code: reason.code) == reason) }
        for reason in RaceCancelled.Reason.known { #expect(RaceCancelled.Reason(code: reason.code) == reason) }
        // `.unknown` of a known code would be a second encoding of it, so it can't be sent.
        #expect(throws: WireError.outOfRange("reason")) {
            try Frame(seq: 0, tick: 0, message: .updateRequired(UpdateRequired(reason: .unknown(2)))).encoded()
        }
        #expect(throws: WireError.outOfRange("reason")) {
            try Frame(seq: 0, tick: 0, message: .raceCancelled(RaceCancelled(reason: .unknown(1)))).encoded()
        }
    }

    /// Message type codes are fixed for good.
    @Test func messageTypeCodesArePinned() {
        let codes: [MessageType: UInt8] = [
            .hello: 1, .joinRace: 2, .inputHeld: 3, .inputTap: 4, .ping: 5, .requestResync: 6,
            .helloAck: 16, .updateRequired: 17, .raceStart: 18, .resync: 19, .snapshot: 20, .event: 21,
            .windKey: 22, .pong: 23, .raceCancelled: 24, .raceClosed: 25,
        ]
        #expect(codes.count == MessageType.allCases.count)
        for type in MessageType.allCases { #expect(codes[type] == type.rawValue) }
    }

    /// Input feedback comes from client stamps: it saturates, and never makes a snapshot unsendable.
    @Test func inputAckMarginSaturates() throws {
        #expect(InputAck(seq: 1, appliedTick: 0, margin: 40_000).margin == 32_767)
        #expect(InputAck(seq: 1, appliedTick: 0, margin: -1_000_000).margin == -32_768)
        #expect(InputAck(seq: 1, appliedTick: 0, margin: -3).margin == -3)
        var gen = Gen(seed: 4)
        let snapshot = Snapshot(seats: gen.wireSeats(2), ack: InputAck(seq: 1, appliedTick: 0, margin: Int.min))
        let frame = Frame(seq: 0, tick: 0, message: .snapshot(snapshot))
        #expect(try Frame(decoding: frame.encoded()) == frame)
    }
}

/// The wind seed never reaches a client (ADR 0001).
@Suite struct WindSeedTests {
    /// Reflects every value a message holds, all the way down.
    static func reflectedTypes(of value: Any, into types: inout [String], isWindSeed: inout Bool) {
        if value is WindSeed { isWindSeed = true }
        types.append(String(describing: type(of: value)))
        for child in Mirror(reflecting: value).children {
            reflectedTypes(of: child.value, into: &types, isWindSeed: &isWindSeed)
        }
    }

    @Test(arguments: MessageType.allCases)
    func noMessageCanHoldAWindSeed(type: MessageType) {
        var gen = Gen(seed: 0x5EED + UInt64(type.rawValue))
        for _ in 0..<100 {
            var types: [String] = []
            var isWindSeed = false
            Self.reflectedTypes(of: gen.frame(type), into: &types, isWindSeed: &isWindSeed)
            #expect(!isWindSeed)
            #expect(types.filter { $0.contains("WindSeed") } == [])
        }
    }

    /// Belt and braces: in a race whose wind seed is known, its bytes appear in none of the frames the
    /// server sends a client.
    @Test func theWindSeedsBytesNeverAppearOnTheWire() throws {
        let windSeed = WindSeed(0xD1CE_5EED_0BAD_F00D)
        let race = botRace(seats: 16, laps: 1, prestartSeconds: 30, seed: 63, windSeed: windSeed)
        let setup = race.setup
        let le = (0..<8).map { UInt8(truncatingIfNeeded: windSeed.value >> (8 * UInt64($0))) }
        let needles = [le, Array(le.reversed())]
        func contains(_ bytes: [UInt8], _ needle: [UInt8]) -> Bool {
            bytes.count >= needle.count && (0...(bytes.count - needle.count)).contains { Array(bytes[$0..<($0 + needle.count)]) == needle }
        }
        func check(_ frame: Frame) throws {
            let bytes = try frame.encoded()
            #expect(needles.allSatisfy { !contains(bytes, $0) }, "wind seed bytes in \(frame.message.type)")
        }
        let names = FleetRoster(setup: setup)
        let roster = (0..<16).map { RosterEntry(name: names[$0].sailingName ?? "Helm \($0 + 1)", colorIndex: $0) }
        try check(Frame(seq: 1, tick: race.tick, message: .raceStart(RaceStart(yourSeat: 0, setup: setup, roster: roster,
                                                                               windKeys: race.wind.keys.keys))))
        var seq: UInt32 = 0
        var keysSent = race.wind.keys.endWindow
        while !race.isOver && race.tick < 6000 {
            for _ in 0..<3 { race.step() }
            seq += 1
            let world = race.exportSnapshot()
            // Every key the race makes goes out as a WindKey frame (on the race's own schedule, not #95's).
            while keysSent < race.wind.keys.endWindow, let key = race.wind.keys[keysSent] {
                try check(Frame(seq: seq, tick: race.tick, message: .windKey(key)))
                keysSent += 1
            }
            try check(Frame(seq: seq, tick: race.tick, message: .snapshot(Snapshot(world: world, ack: InputAck(seq: seq, appliedTick: race.tick, margin: 2)))))
            if seq % 100 == 0 {
                try check(Frame(seq: seq, tick: race.tick, message: .resync(Resync(raceSeed: setup.raceSeed, world: world, nextEventSeq: seq))))
            }
            for event in race.drainEvents() { try check(Frame(seq: seq, event: event)) }
        }
        #expect(seq > 1000)
        #expect(keysSent > 5)
    }

    @Test func windKeysTravelAsTheCoreEncodes() throws {
        let key = Gen(seed: 75).windKeyCopy()
        let frame = Frame(seq: 3, tick: 900, message: .windKey(key))
        let bytes = try frame.encoded()
        #expect(bytes.count == Frame.headerSize + WindKey.byteCount)
        #expect(Array(bytes.dropFirst(Frame.headerSize)) == key.bytes)
        #expect(try Frame(decoding: bytes) == frame)

        let far = WindKey(window: WindKeyWire.maxWindow + 1, shift: key.shift, strength: key.strength, wobble: key.wobble, puffSeed: 1)
        #expect(throws: WireError.outOfRange("windKey.window")) { try Frame(seq: 0, tick: 0, message: .windKey(far)).encoded() }
        let header = Array(bytes.prefix(Frame.headerSize))
        #expect(throws: WireError.invalidValue("windKey.window")) { try Frame(decoding: header + far.bytes) }
        var nan = key.bytes
        for i in 8..<16 { nan[i] = 0xFF } // shift value: a NaN
        #expect(throws: WireError.invalidValue("windKey")) { try Frame(decoding: header + nan) }
        #expect(throws: WireError.truncated) { try Frame(decoding: Array(bytes.dropLast())) }

        // Hostile but finite values: a knot of 1.7e308 turned boats' wind to NaN within 60 ticks.
        let hostile = WindKey(window: 3, shift: WindKnot(value: 1.7e308, slope: 0), strength: key.strength, wobble: key.wobble, puffSeed: 1)
        #expect(throws: WireError.invalidValue("windKey")) { try Frame(decoding: header + hostile.bytes) }
        #expect(throws: WireError.outOfRange("windKey")) { try Frame(seq: 0, tick: 0, message: .windKey(hostile)).encoded() }
        let spoilers: [(inout WindKey) -> Void] = [
            { $0 = WindKey(window: $0.window, shift: WindKnot(value: 3.2, slope: 0), strength: $0.strength, wobble: $0.wobble, puffSeed: 0) },
            { $0 = WindKey(window: $0.window, shift: WindKnot(value: 0, slope: -1.01), strength: $0.strength, wobble: $0.wobble, puffSeed: 0) },
            { $0 = WindKey(window: $0.window, shift: $0.shift, strength: WindKnot(value: -0.01, slope: 0), wobble: $0.wobble, puffSeed: 0) },
            { $0 = WindKey(window: $0.window, shift: $0.shift, strength: WindKnot(value: 10.5, slope: 0), wobble: $0.wobble, puffSeed: 0) },
            { $0 = WindKey(window: $0.window, shift: $0.shift, strength: WindKnot(value: 1, slope: 2), wobble: $0.wobble, puffSeed: 0) },
            { $0 = WindKey(window: $0.window, shift: $0.shift, strength: $0.strength, wobble: WindWobble(hump: 1.5, wiggle: 0), puffSeed: 0) },
            { $0 = WindKey(window: $0.window, shift: $0.shift, strength: $0.strength, wobble: WindWobble(hump: 0, wiggle: -1.5), puffSeed: 0) },
        ]
        for spoil in spoilers {
            var bad = key
            spoil(&bad)
            #expect(!WindKeyWire.isSane(bad))
            #expect(throws: WireError.invalidValue("windKey")) { try Frame(decoding: header + bad.bytes) }
        }
    }

    /// Key lists are in strictly increasing windows, so each message has one encoding and no key twice.
    @Test func keyListsAreStrictlyIncreasing() throws {
        var gen = Gen(seed: 95)
        let a = gen.windKey(window: 5), b = gen.windKey(window: 7), a2 = gen.windKey(window: 5)
        let world = WorldSnapshot(tick: 0, seats: [gen.seat(0), gen.seat(1)])
        func resync(_ keys: [WindKey]) throws -> Frame {
            Frame(seq: 0, tick: 0, message: .resync(try Resync(raceSeed: RaceSeed(1), world: world, windKeys: keys, nextEventSeq: 0)))
        }
        let good = try resync([a, b]).encoded()
        #expect(try Frame(decoding: good) == resync([a, b]))
        for keys in [[b, a], [a, a2]] {
            #expect(throws: WireError.outOfRange("windKeys")) { try resync(keys).encoded() }
        }
        let setup = try RaceSetup(raceSeed: RaceSeed(1), seats: [.human, .bot])
        let roster = [RosterEntry(name: "A", colorIndex: 0), RosterEntry(name: "B", colorIndex: 1)]
        #expect(throws: WireError.outOfRange("windKeys")) {
            try Frame(seq: 0, tick: 0, message: .raceStart(RaceStart(yourSeat: 0, setup: setup, roster: roster, windKeys: [b, a]))).encoded()
        }
        // The same bytes with the two keys swapped, or the first key twice, don't decode.
        let pair = a.bytes + b.bytes
        let at = try #require((0...(good.count - pair.count)).first { Array(good[$0..<($0 + pair.count)]) == pair })
        var swapped = good, doubled = good
        swapped.replaceSubrange(at..<(at + pair.count), with: b.bytes + a.bytes)
        doubled.replaceSubrange(at..<(at + pair.count), with: a.bytes + a2.bytes)
        #expect(throws: WireError.invalidValue("windKeys")) { try Frame(decoding: swapped) }
        #expect(throws: WireError.invalidValue("windKeys")) { try Frame(decoding: doubled) }
    }

    /// The bounds hold every key the generator makes, from every conditions file, far into a race.
    @Test func generatedKeysStayInBounds() throws {
        var largest = (shift: 0.0, shiftSlope: 0.0, strength: 0.0, strengthSlope: 0.0, wobble: 0.0)
        var checked = 0
        for id in ["classic-oscillating", "gusty-offshore", "light-and-patchy", "sea-breeze"] {
            let conditions = try ConditionsFile.bundled(id: id, version: 2)
            for seed in 0..<150 as Range<UInt64> {
                let setup = WindSetup(conditions: conditions, pairing: .stub, raceSeed: RaceSeed(seed &* 0x9E37_79B9 &+ 7))
                var generator = try WindKeyGenerator(windSeed: WindSeed(seed ^ 0xD1CE), setup: setup,
                                                     windows: WindWindows(startSequenceTicks: 1800))
                // 90 windows: 45 minutes, past every trend and build span (960 s).
                for key in generator.keys(through: 89) {
                    #expect(WindKeyWire.isSane(key), "\(id) seed \(seed): \(key)")
                    largest.shift = max(largest.shift, abs(key.shift.value))
                    largest.shiftSlope = max(largest.shiftSlope, abs(key.shift.slope))
                    largest.strength = max(largest.strength, key.strength.value)
                    largest.strengthSlope = max(largest.strengthSlope, abs(key.strength.slope))
                    largest.wobble = max(largest.wobble, abs(key.wobble.hump), abs(key.wobble.wiggle))
                    checked += 1
                }
            }
        }
        print("WINDKEYS largest of \(checked) generated: \(largest)")
        #expect(checked == 4 * 150 * 90)
        // At least 5× headroom on every bound.
        #expect(largest.shift * 5 < WindKeyWire.shiftLimit)
        #expect(largest.shiftSlope * 5 < WindKeyWire.slopeLimit && largest.strengthSlope * 5 < WindKeyWire.slopeLimit)
        #expect(largest.strength * 5 < WindKeyWire.strengthRange.upperBound)
        #expect(largest.wobble * 5 < WindKeyWire.wobbleLimit)
    }

    /// The review's crash over the wire: a Resync whose keys have a gap past the current window is
    /// refused on import, and the race is unchanged, instead of trapping when the clock reaches the gap.
    @Test func aResyncWithAGapInItsKeysIsRefused() throws {
        let server = botRace(prestartSeconds: 60)
        for _ in 0..<1500 { server.step() } // tick −300
        let current = server.wind.windows.window(containing: server.tick)
        let later = botRace(prestartSeconds: 60)
        while later.wind.keys.endWindow <= current + 3 { later.step() }
        let keys = server.wind.keys.keys + [later.wind.keys[current + 3]!]
        let world = server.exportSnapshot()
        let frame = try Frame(decoding: Frame(seq: 0, tick: server.tick, message: .resync(
            Resync(raceSeed: server.setup.raceSeed, world: world, windKeys: keys, nextEventSeq: 1))).encoded())
        guard case .resync(let resync) = frame.message else { Issue.record("not a resync"); return }
        let client = Race(setup: server.setup, windSeed: try #require(server.windSeed))
        let before = client.digest()
        #expect(throws: WorldSnapshotError.missingWindKey(current + 1)) {
            try client.importSnapshot(resync.world(base: client.exportSnapshot(), tick: frame.tick))
        }
        #expect(client.digest() == before)
        // Without the stray key it imports and sails through the gun and past the window it would have missed.
        let clean = try Resync(raceSeed: server.setup.raceSeed, world: world, nextEventSeq: 1)
        try client.importSnapshot(clean.world(base: client.exportSnapshot(), tick: server.tick))
        for _ in 0..<2000 { client.step() }
        #expect(client.tick == server.tick + 2000)
    }
}
