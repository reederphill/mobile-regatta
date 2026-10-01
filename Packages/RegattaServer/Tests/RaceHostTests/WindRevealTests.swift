import RaceHost
import RegattaCore
import RegattaProtocol
import Testing

/// The host's wind key reveal (#95, ADR 0001): key k goes out at server tick `windowStart(k) − 30`
/// (`WindKeyWire.revealTick`), from the window origin on, and the wind seed never does.
struct WindRevealTests {
    /// What one seat's client holds, read off the frames the host sent it, in order.
    private struct Client {
        let transport: RecordingTransport
        let windows: WindWindows
        private(set) var keys: [WindKey] = []
        private(set) var start: RaceStart?
        private(set) var resyncs: [(tick: Int, resync: Resync)] = []
        /// Each `WindKey` frame: its tick and key.
        private(set) var keyFrames: [(tick: Int, key: WindKey)] = []
        private var read = 0

        init(_ transport: RecordingTransport, setup: RaceSetup) {
            self.transport = transport
            windows = WindWindows(startSequenceTicks: setup.startSequenceTicks)
        }

        /// Reads the frames sent since the last call.
        mutating func catchUp() throws {
            let sent = transport.sentBytes
            for bytes in sent[read...] {
                let frame = try Frame(decoding: bytes)
                switch frame.message {
                case .raceStart(let raceStart):
                    start = raceStart
                    keys = raceStart.windKeys
                case .resync(let resync):
                    resyncs.append((frame.tick, resync))
                    keys = resync.windKeys
                case .windKey(let key):
                    keyFrames.append((frame.tick, key))
                    keys.append(key)
                default:
                    break
                }
            }
            read = sent.count
        }

        var highestWindow: Int? { keys.last?.window }

        /// The keys-only race a client builds from what it holds.
        func race(setup: RaceSetup) -> Race { Race(setup: setup, revealedWindKeys: keys) }
    }

    /// The chain the host's keys must be: an independent generator from the same seed.
    private func chain(_ rig: Rig, through window: Int) throws -> [WindKey] {
        let race = Race(setup: rig.setup, windSeed: rig.windSeed)
        var generator = try WindKeyGenerator(windSeed: rig.windSeed, setup: race.windSetup, windows: race.wind.windows)
        return generator.keys(through: window)
    }

    // MARK: Schedule

    @Test func aClientHoldsOnlyKeysWhoseWindowStartsWithinThirtyTicksOfTheServerTick() async throws {
        // The default 60 s sequence: origin −2700, window k starts at −2700 + 900k; the host starts at −1800.
        let rig = try await Rig(startSequenceTicks: RaceSetup.defaultStartSequenceTicks)
        var client = Client(rig.seat0, setup: rig.setup)
        let windows = client.windows
        #expect(windows.origin == -2700)
        let first = await rig.host.tick
        let last = windows.start(of: 5)
        for tick in first...last {
            if tick > first { await rig.run(to: tick) }
            #expect(await rig.host.tick == tick)
            try client.catchUp()
            let lastRevealed = WindKeyWire.lastRevealedWindow(atTick: tick, windows: windows)
            // Every key k held has windowStart(k) ≤ t + 30, and every such key is held.
            #expect(client.keys.allSatisfy { windows.start(of: $0.window) <= tick + WindKeyWire.revealLeadTicks })
            #expect(client.highestWindow == lastRevealed, "tick \(tick)")
            #expect(client.keys.map(\.window) == Array(0...lastRevealed))
            // At the start of window k the client holds key k, never k + 1.
            let window = windows.window(containing: tick)
            if windows.start(of: window) == tick { #expect(client.highestWindow == window, "start of window \(window)") }
        }
        // Keys 2…5 went out on the reliable stream, each at its reveal tick, a second before its window.
        #expect(client.keyFrames.map(\.key.window) == [2, 3, 4, 5])
        for (tick, key) in client.keyFrames {
            #expect(tick == WindKeyWire.revealTick(of: key.window, windows: windows))
            #expect(tick == windows.start(of: key.window) - 30)
        }
        #expect(await rig.host.revealedWindKeys == client.keys)
        #expect(client.keys == (try chain(rig, through: 5)))
    }

    @Test func keysDueBeforeTheFirstTickAreInTheFirstRaceStart() async throws {
        // Attached before the host's first step: key 0 was due at −2730 and key 1 at −1830, both before
        // the host's first tick (−1800); key 2 is due at −930.
        let rig = try await Rig(startSequenceTicks: RaceSetup.defaultStartSequenceTicks)
        #expect(await rig.host.tick == -1800)
        guard case .raceStart(let start) = rig.seat0.frames.first?.message else {
            Issue.record("no RaceStart")
            return
        }
        #expect(start.windKeys.map(\.window) == [0, 1])
        let expected = try chain(rig, through: 1)
        #expect(start.windKeys == expected)
        #expect(start.windKeys.flatMap(\.bytes) == expected.flatMap(\.bytes))
        // So a keys-only race can sail from the first tick, without asking for a resync.
        let race = Race(setup: start.setup, revealedWindKeys: start.windKeys)
        try race.wind.requireKeys(atTick: race.tick + 1)
        try race.tryStep()
    }

    // MARK: Client wind equals server wind

    @Test func clientAndServerWindSamplesAreEqualAtTheSameTickAndPosition() async throws {
        let rig = try await Rig()
        var client = Client(rig.seat0, setup: rig.setup)
        let windows = client.windows
        // Server ticks to look from: spread through the race, and around each window start and its key's reveal.
        var ticks = Set(stride(from: await rig.host.tick, through: 2400, by: 97))
        for k in 2...5 {
            let start = windows.start(of: k)
            ticks.formUnion([start - 31, start - 30, start - 1, start])
        }
        // At each, what the client samples now and a second ahead (its most-ahead lead), where the boats
        // are and around them.
        var expected: [Int: (points: [Vec2], wind: [GroundWind])] = [:]
        for tick in ticks.sorted() {
            await rig.run(to: tick)
            try client.catchUp()
            let keysOnly = client.race(setup: rig.setup)
            var points: [Vec2] = []
            for seat in 0..<rig.setup.seats.count { points.append(await rig.host.boat(seat: seat).position) }
            for dx in [-1500.0, 0, 1500] { for dy in [-1500.0, 0, 1500] { points.append(points[0] + Vec2(dx, dy)) } }
            for at in [tick, tick + WindKeyWire.revealLeadTicks] {
                expected[at] = (points, try points.map { try keysOnly.wind.sample($0, tick: at) })
            }
            // One tick further, at a window's start, the client hasn't the key: it never extrapolates.
            let beyond = tick + WindKeyWire.revealLeadTicks + 1
            let window = windows.window(containing: beyond)
            if windows.start(of: window) == beyond {
                #expect(throws: WindFieldError.missingKey(window)) { try keysOnly.wind.sample(points[0], tick: beyond) }
            }
        }
        #expect(expected.keys.contains(windows.start(of: 3)))

        // The server's wind: a seeded race, stepped to each tick the client sampled.
        let server = Race(setup: rig.setup, windSeed: rig.windSeed)
        for at in expected.keys.sorted() {
            while server.tick < at { server.step() }
            guard let (points, wind) = expected[at] else { continue }
            #expect(try points.map { try server.wind.sample($0, tick: at) } == wind, "tick \(at)")
        }
    }

    // MARK: Resync

    @Test func resyncMidRaceRestoresAllRevealedKeys() async throws {
        let rig = try await Rig()
        let windows = WindWindows(startSequenceTicks: rig.setup.startSequenceTicks)
        await rig.run(to: 1000)
        await rig.host.disconnect(seat: 0)
        await rig.run(to: 1010)
        let again = RecordingTransport()
        #expect(await rig.host.attach(seat: 0, transport: again))
        var client = Client(again, setup: rig.setup)
        try client.catchUp()

        let lastRevealed = WindKeyWire.lastRevealedWindow(atTick: 1010, windows: windows)
        #expect(lastRevealed == 3)
        let revealed = await rig.host.revealedWindKeys
        #expect(client.start?.windKeys == revealed)
        guard let (tick, resync) = client.resyncs.first else {
            Issue.record("no Resync on the rejoin")
            return
        }
        #expect(tick == 1010)
        #expect(resync.windKeys == revealed)
        #expect(resync.windKeys == (try chain(rig, through: lastRevealed)))
        try expectRestores(resync, tick: tick, setup: rig.setup)

        // A RequestResync gets every key revealed by then: one more since (key 4, at 1770).
        await rig.run(to: 1800)
        await rig.send(.requestResync, seq: 1, stamp: 1801)
        try client.catchUp()
        #expect(client.resyncs.count == 2)
        guard let (later, requested) = client.resyncs.last else { return }
        #expect(requested.windKeys == (try chain(rig, through: 4)))
        #expect(requested.windKeys == (await rig.host.revealedWindKeys))
        try expectRestores(requested, tick: later, setup: rig.setup)
    }

    /// A fresh keys-only race that imports `resync` holds every key it carries, and sails on from `tick`
    /// as far as a client may lead without asking for another.
    private func expectRestores(_ resync: Resync, tick: Int, setup: RaceSetup) throws {
        let race = Race(setup: setup, revealedWindKeys: [])
        try race.importSnapshot(resync.world(base: race.exportSnapshot(), tick: tick))
        #expect(race.tick == tick)
        #expect(race.wind.keys.keys == resync.windKeys)
        for _ in 0..<WindKeyWire.revealLeadTicks { try race.tryStep() }
        #expect(race.tick == tick + WindKeyWire.revealLeadTicks)
    }

    // MARK: Wire capture

    @Test func aWireCaptureOverAFullRaceHoldsNoWindSeedBytes() async throws {
        // A seed with no byte twice, so a match can only be the seed.
        let windSeed = WindSeed(0x1F2E_3D4C_5B6A_7988)
        let rig = try await Rig(humans: 1, seats: 3, firstInputHold: true, windSeed: windSeed)
        let rejoined = RecordingTransport()
        while await rig.host.outcome == nil {
            let tick = await rig.host.tick
            // A one-lap race closes well inside this; a hang fails the test instead of the job's time limit.
            guard tick < 40_000 else { Issue.record("the race never closed (tick \(tick))"); break }
            if tick < 1200 && tick + 300 >= 1200 {
                await rig.run(to: 1200)
                // A mid-race rejoin: a RaceStart and a Resync, each with every key revealed so far.
                await rig.host.disconnect(seat: 0)
                #expect(await rig.host.attach(seat: 0, transport: rejoined))
            } else {
                await rig.run(to: tick + 300)
            }
        }
        let captured = rig.seat0.sentBytes + rejoined.sentBytes
        let le = (0..<8).map { UInt8(truncatingIfNeeded: windSeed.value >> (8 * UInt64($0))) }
        #expect(Set(le).count == 8)
        let needles = [le, Array(le.reversed())]
        for bytes in captured where needles.contains(where: { contains(bytes, $0) }) {
            Issue.record("wind seed bytes in \(try Frame(decoding: bytes).message.type)")
        }
        // The capture is a whole race: keys revealed on the stream, the rejoin's resync, the close.
        let frames = try captured.map { try Frame(decoding: $0) }
        #expect(frames.contains { if case .windKey = $0.message { true } else { false } })
        #expect(frames.contains { if case .resync = $0.message { true } else { false } })
        #expect(rejoined.frames.last?.message.type == .raceClosed)
        #expect(await rig.host.revealedWindKeys.count > 3)
    }

    private func contains(_ bytes: [UInt8], _ needle: [UInt8]) -> Bool {
        bytes.count >= needle.count
            && (0...(bytes.count - needle.count)).contains { Array(bytes[$0..<($0 + needle.count)]) == needle }
    }
}
