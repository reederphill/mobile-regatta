import RegattaCore
import RegattaDevAPI
import RegattaLoadClient
import RegattaProtocol
import Testing

/// The load client's wind audit (#95) on hand-built frames: no server needed.
struct WindAuditTests {
    // A 10 s sequence: windows start at −1800, −900, 0, 900; key k is revealed at its start − 30.
    let setup = try! RaceSetup(raceSeed: RaceSeed(95), seats: [.human, .bot], laps: 1, startSequenceTicks: 300)

    private func keys(through window: Int) throws -> [WindKey] {
        let race = Race(setup: setup, windSeed: WindSeed(0x95))
        var generator = try WindKeyGenerator(windSeed: WindSeed(0x95), setup: race.windSetup, windows: race.wind.windows)
        return generator.keys(through: window)
    }

    private func raceStart(_ keys: [WindKey], tick: Int) throws -> [UInt8] {
        let roster = (0..<2).map { RosterEntry(name: "Seat \($0 + 1)", colorIndex: $0) }
        return try Frame(seq: 1, tick: tick, message: .raceStart(RaceStart(yourSeat: 0, setup: setup, roster: roster, windKeys: keys)))
            .encoded()
    }

    private func audit(_ frames: [[UInt8]], windSeed: UInt64? = nil) -> [String] {
        var audit = WindAudit(windows: WindWindows(startSequenceTicks: setup.startSequenceTicks), windSeed: windSeed)
        for frame in frames { audit.check(frame) }
        return audit.violations
    }

    @Test func aCleanSequencePasses() throws {
        let all = try keys(through: 3)
        let race = Race(setup: setup, windSeed: WindSeed(0x95))
        let resync = try Resync(raceSeed: setup.raceSeed, world: race.exportSnapshot(), windKeys: Array(all[0...3]), nextEventSeq: 2)
        let frames = [
            try raceStart(Array(all[0...1]), tick: -300),
            try Frame(seq: 1, tick: -30, message: .windKey(all[2])).encoded(),
            try Frame(seq: 2, tick: 870, message: .windKey(all[3])).encoded(),
            try Frame(seq: 3, tick: 899, message: .resync(resync)).encoded(),
        ]
        #expect(audit(frames, windSeed: 0x95).isEmpty)
    }

    @Test func aKeyBeforeItsRevealTickIsAViolation() throws {
        let all = try keys(through: 3)
        let early = try Frame(seq: 1, tick: -31, message: .windKey(all[2])).encoded()
        #expect(audit([early]).count == 1)
        // A join holding a key not yet revealed, or missing one that is.
        #expect(audit([try raceStart(Array(all[0...2]), tick: -300)]).count == 2)
        #expect(audit([try raceStart(Array(all[0...0]), tick: -300)]).count == 1)
    }

    @Test func theWindSeedsBytesAreAViolationInEitherByteOrder() throws {
        let frame = try raceStart(try keys(through: 1), tick: -300)
        // A "seed" that is eight bytes of the frame, read either way round.
        let run = Array(frame[20..<28])
        let littleEndian = run.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
        let bigEndian = run.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        #expect(audit([frame], windSeed: littleEndian) == ["wind seed bytes in raceStart"])
        #expect(audit([frame], windSeed: bigEndian) == ["wind seed bytes in raceStart"])
        #expect(audit([frame], windSeed: 0x0102_0304_0506_0708).isEmpty)
    }

    @Test func theDevInstantRaceSeedIsTheOneTheServerUses() {
        #expect(InstantRaceRequest.windSeed(forRaceSeed: 3) == 3 ^ 0x5EED_5EED_5EED_5EED)
    }
}
