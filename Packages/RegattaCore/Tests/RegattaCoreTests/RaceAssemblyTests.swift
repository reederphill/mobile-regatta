import Foundation
import Testing
@testable import RegattaCore

/// Race assembly (#81): a race is built from its setup, the data files the setup names and its key chain.
@Suite struct RaceAssemblyTests {
    static let windSeed = WindSeed(0x81)

    static func setup(seats: [SeatKind] = [.human, .bot, .bot, .human], venue: FileRef = RaceFiles.defaults.venue.ref,
                      conditions: FileRef = RaceFiles.defaults.conditions.ref) throws -> RaceSetup {
        try RaceSetup(raceSeed: RaceSeed(81), seats: seats, startSequenceTicks: 900, venue: venue, conditions: conditions)
    }

    /// The test venue (it has a current) with gusty-offshore@2, which it pairs, from a catalog.
    static func tidalRace() throws -> (RaceSetup, RaceFileCatalog) {
        var catalog = RaceFileCatalog()
        let venue = try catalog.venues.add(try VenueFixtures.testFile())
        let conditions = try ConditionsFile.bundled(id: "gusty-offshore", version: 2).ref
        return (try setup(venue: venue, conditions: conditions), catalog)
    }

    /// Steers every seat with the same seeded rudder changes in each race.
    static func sail(_ races: [Race], ticks: Int) {
        var rng = SplitMix64(seed: 81)
        for _ in 0..<ticks {
            let t = races[0].tick + 1
            for seat in races[0].boats.indices where rng.int(in: 0..<45) == 0 {
                let input = BoatInput(rudder: Int8(rng.int(in: -90...90)))
                for race in races { race.apply(input, seat: seat, atTick: t) }
            }
            for race in races { race.step() }
        }
    }

    // MARK: - Resolving files

    @Test func theDefaultSetupResolvesToTheBundledDefaults() throws {
        let files = try RaceFiles(resolving: try Self.setup())
        #expect(files.boatClass.ref == RaceFiles.defaults.boatClass.ref)
        #expect(files.venue.ref.key == DataFileKey(id: "dev-venue", version: 2))
        #expect(files.conditions.ref == RaceFiles.defaults.conditions.ref)
        #expect(files.rulesConfiguration.ref == RaceFiles.defaults.rulesConfiguration.ref)
        #expect(files.pairing == Race.defaultPairing)
    }

    /// A ref whose hash isn't the file's, bundled or in a catalog, is refused before anything is parsed.
    @Test func resolvingAFileWhoseHashDiffersThrows() throws {
        let real = RaceFiles.defaults.rulesConfiguration.ref
        let wrong = FileRef(id: real.id, version: real.version, hash: ContentHash(of: Data("not fleet-rules".utf8)))
        let setup = try RaceSetup(raceSeed: RaceSeed(1), seats: [.human, .bot], rulesConfiguration: wrong)
        #expect(throws: DataFileError.refMismatch(expected: wrong, foundHash: real.hash)) {
            try RaceFiles(resolving: setup)
        }

        // A catalog's fleet-rules@1 with other bytes than the setup's ref.
        var catalog = RaceFileCatalog()
        let retuned = try RulesConfigFile(data: RulesConfigTests.tampered(#""finishWindowSeconds": 120"#, #""finishWindowSeconds": 150"#))
        try catalog.rulesConfigurations.add(retuned)
        #expect(throws: DataFileError.refMismatch(expected: real, foundHash: retuned.ref.hash)) {
            try RaceFiles(resolving: try Self.setup(), from: catalog)
        }

        // A bundled file that isn't one of the defaults is checked against its hash too.
        let v1 = try #require(try ConditionsFile.bundledData(id: "classic-oscillating", version: 1))
        let wrongV1 = FileRef(id: "classic-oscillating", version: 1, hash: real.hash)
        #expect(throws: DataFileError.refMismatch(expected: wrongV1, foundHash: ContentHash(of: v1))) {
            try RaceFiles(resolving: try Self.setup(conditions: wrongV1))
        }
    }

    @Test func aFileNeitherBundledNorInTheCatalogThrows() throws {
        let missing = FileRef(id: "no-such-venue", version: 1, hash: ContentHash(of: Data()))
        #expect(throws: DataFileError.notBundled(kind: Venue.kind, id: "no-such-venue", version: 1)) {
            try RaceFiles(resolving: try Self.setup(venue: missing))
        }
    }

    @Test func aVenueWithoutAPairingForTheConditionsThrows() throws {
        let sea = try ConditionsFile.bundled(id: "sea-breeze", version: 1).ref
        #expect(throws: RaceFilesError.noPairing(venue: RaceFiles.defaults.venue.ref, conditions: sea)) {
            try RaceFiles(resolving: try Self.setup(conditions: sea))
        }
    }

    @Test func aRaceRefusesFilesItsSetupDoesNotName() throws {
        let (tidal, catalog) = try Self.tidalRace()
        #expect(throws: RaceFilesError.notTheSetupFile(expected: tidal.venue, found: RaceFiles.defaults.venue.ref)) {
            try Race(setup: tidal, files: .defaults, mode: .authoritative(windSeed: Self.windSeed))
        }
        _ = try Race(setup: tidal, files: RaceFiles(resolving: tidal, from: catalog), mode: .authoritative(windSeed: Self.windSeed))
    }

    // MARK: - Assembly

    /// Everything is derived from the files and the race seed: the course, its race area in the wind
    /// setup, and the current with its tide state at the gun.
    @Test func theRaceIsDerivedFromItsFiles() throws {
        let (setup, catalog) = try Self.tidalRace()
        let files = try RaceFiles(resolving: setup, from: catalog)
        let race = try Race(setup: setup, files: files, mode: .authoritative(windSeed: Self.windSeed))
        let drawn = WindSetup(conditions: files.conditions, pairing: files.pairing, raceSeed: setup.raceSeed)
        #expect(race.course == CourseLayout.derive(windSetup: drawn, fleetSize: 4, laps: setup.laps,
                                                   boatClass: files.boatClass.content, rules: files.rulesConfiguration.content))
        #expect(race.windSetup == drawn.with(raceArea: race.course.raceArea))
        #expect(race.current == CurrentField(venue: files.venue.content, raceSeed: setup.raceSeed))
        #expect(race.tideStateAtGun == CurrentField.tideStateAtGun(for: files.venue.content, raceSeed: setup.raceSeed))
        #expect(race.tideStateAtGun != nil)
        // The start line is where the pairing puts it, and the boats start below it.
        #expect(race.course.startLine.centre == files.pairing.startLineCentre)
        #expect(race.boats.allSatisfy { race.course.startLine.side($0.position) < 0 })
    }

    @Test func twoRacesFromTheSameSetupChainAndInputsHaveIdenticalDigests() throws {
        let setup = try Self.setup()
        let a = try Race(setup: setup, files: RaceFiles(resolving: setup), mode: .authoritative(windSeed: Self.windSeed))
        let b = try Race(setup: setup, files: RaceFiles(resolving: setup), mode: .authoritative(windSeed: Self.windSeed))
        #expect(a.digest() == b.digest())
        Self.sail([a, b], ticks: 2400)
        #expect(a.digest() == b.digest())
        #expect(a.log == b.log)
        #expect(try Replayer.digest(of: try #require(a.log)) == a.digest())
    }

    // MARK: - Log header

    /// The header records every file by id, version and hash, both seeds and the tide state at the gun,
    /// and survives its JSON.
    @Test func logHeaderRecordsFilesSeedsAndTideStateAndRoundTrips() throws {
        let (setup, catalog) = try Self.tidalRace()
        let race = try Race(setup: setup, files: RaceFiles(resolving: setup, from: catalog),
                            mode: .authoritative(windSeed: Self.windSeed))
        Self.sail([race], ticks: 30)
        let log = try #require(race.log)
        let header = log.header
        #expect([header.setup.boatClass, header.setup.venue, header.setup.conditions, header.setup.rulesConfiguration]
            == [race.files.boatClass.ref, race.files.venue.ref, race.files.conditions.ref, race.files.rulesConfiguration.ref])
        #expect(header.raceSeed == RaceSeed(81) && header.windSeed == Self.windSeed)
        #expect(header.tideStateAtGun == race.tideStateAtGun && header.tideStateAtGun != nil)

        let decoded = try RaceLog(jsonData: log.jsonData())
        #expect(decoded == log)
        #expect(try JSONDecoder().decode(RaceLog.Header.self, from: JSONEncoder().encode(header)) == header)
        #expect(try Replayer.digest(of: decoded, catalog: catalog) == race.digest())

        // A header with no current records no tide state, and says so by leaving it out.
        let plain = try #require(Race(setup: try Self.setup(), windSeed: Self.windSeed).log)
        #expect(plain.header.tideStateAtGun == nil)
        #expect(!String(decoding: try plain.jsonData(), as: UTF8.self).contains("tideStateAtGun"))
    }

    /// A replay draws the tide state again and refuses a log that records another (ADR 0003).
    @Test func replayRefusesAnotherTideStateAtGun() throws {
        let (setup, catalog) = try Self.tidalRace()
        let race = try Race(setup: setup, files: RaceFiles(resolving: setup, from: catalog),
                            mode: .authoritative(windSeed: Self.windSeed))
        var log = try #require(race.log)
        let drawn = log.header.tideStateAtGun
        log.header.tideStateAtGun = 0.5
        #expect(throws: ReplayError.tideStateAtGun(log: 0.5, race: drawn)) { try Replayer.replay(log, catalog: catalog) }
        log.header.tideStateAtGun = nil
        #expect(throws: ReplayError.tideStateAtGun(log: nil, race: drawn)) { try Replayer.replay(log, catalog: catalog) }
    }

    // MARK: - Modes

    /// Two boats in contact: the authoritative race calls it; a prediction on the same keys sails the
    /// same but emits no rule event, and has no umpire.
    @Test func predictionModeNeverEmitsRuleEvents() throws {
        let setup = try Self.setup(seats: [.human, .bot])
        let authoritative = Race(setup: setup, windSeed: Self.windSeed)
        var generator = try WindKeyGenerator(windSeed: Self.windSeed, setup: authoritative.windSetup,
                                             windows: authoritative.wind.windows)
        let prediction = try Race(setup: setup, files: .defaults, mode: .prediction(revealedWindKeys: generator.keys(through: 4)))
        #expect(authoritative.umpire != nil && prediction.umpire == nil)
        #expect(prediction.log == nil && prediction.isKeysOnly)

        // Port meets starboard, bow to bow, below the line: a port-starboard call.
        var snapshot = authoritative.exportSnapshot()
        let centre = authoritative.course.startLine.centre - authoritative.course.upwind * 60
        let wind = authoritative.windSetup.meanDirection
        snapshot.seats[0].boat.position = centre
        snapshot.seats[0].boat.heading = wind + deg2rad(50)
        snapshot.seats[0].boat.boomSide = .leeward(ofRelativeWind: -deg2rad(50))
        snapshot.seats[1].boat.position = centre + Vec2.heading(wind + deg2rad(50)) * 3
        snapshot.seats[1].boat.heading = wind - deg2rad(50)
        snapshot.seats[1].boat.boomSide = .leeward(ofRelativeWind: deg2rad(50))
        try authoritative.importSnapshot(snapshot)
        try prediction.importSnapshot(snapshot)

        var calls: [RaceEvent] = [], predicted: [RaceEvent] = []
        for _ in 0..<60 {
            authoritative.step()
            try prediction.tryStep()
            calls += authoritative.drainEvents()
            predicted += prediction.drainEvents()
        }
        #expect(calls.contains { if case .ruleCall = $0.kind { true } else { false } })
        #expect(!predicted.contains { $0.kind.isRuleEvent })
        // Otherwise it sails exactly the same: the umpire's calls are all it leaves out.
        #expect(predicted == calls.filter { !$0.kind.isRuleEvent })
        #expect(prediction.digest() == authoritative.digest())
    }

    // MARK: - Wind

    /// `WindField.sample` bends and shades the channel wind by the venue's geographic grid (#77).
    @Test func theGeographicGridIsComposedIntoTheWind() throws {
        // The default venue's pairing, with no race area: no puffs.
        let setup = WindSetup(conditions: Race.defaultConditions, pairing: Race.defaultPairing, raceSeed: RaceSeed(1))
        let windows = WindWindows(startSequenceTicks: 900)
        var generator = try WindKeyGenerator(windSeed: Self.windSeed, setup: setup, windows: windows)
        let field = WindField(setup: setup, windows: windows, keys: WindKeyChain(generator.keys(through: 3)))
        let tick = windows.start(of: 2) + 100
        let grid = setup.pairing.geographicGrid
        var shaded = 0
        for x in stride(from: -950.0, through: 950, by: 100) {
            for y in stride(from: -450.0, through: 1000, by: 100) {
                let p = Vec2(x, y)
                let geographic = grid.sample(p)
                let wind = try field.sample(p, tick: tick)
                #expect(wind.speed == (try field.courseAverageSpeed(atTick: tick)) * geographic.speedFactor)
                let expected = wrapAngle(setup.meanDirection + (try field.shift(atTick: tick)) + geographic.directionDelta)
                #expect(abs(wrapAngle(wind.direction - expected)) < 1e-12)
                if geographic != .neutral { shaded += 1 }
            }
        }
        #expect(shaded > 0, "the dev venue's grid is neutral everywhere sampled")
    }
}

