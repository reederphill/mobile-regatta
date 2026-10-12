import Foundation
import NIOHTTP1
import Persistence
import Ratings
import RegattaAdminClient
import RegattaBots
import RegattaCore
@testable import RegattaServerKit
import RegattaServices
import Synchronization
import Testing

/// The server's measures (#157; #28, #24, #31).
@Suite(.timeLimit(.minutes(1))) struct MeasuresTests {
    static let start = Date(timeIntervalSince1970: 1_791_460_800)

    static func event(_ name: AnalyticsEventName, _ player: String?, at time: Date = start, _ properties: [String: StoredAnalyticsValue] = [:])
        -> StoredAnalyticsEvent {
        StoredAnalyticsEvent(source: .server, playerID: player, name: name.rawValue, day: StoredAnalyticsEvent.day(of: time), occurredAt: time,
                             receivedAt: time, properties: properties)
    }

    /// Acceptance: each measure on fixture data.
    @Test func eachMeasureOnFixtureData() throws {
        let endA = Self.start + 3600, endB = Self.start + 7200
        // Race A: wren finishes first, after dropping and coming back; gull's socket closes near the end, and she retires.
        let raceA = try RaceFixture.race(["T:gull", "T:wren", nil], endedAt: endA, seatEvents: [
            SeatEvent(tick: 5_000, seat: 1, kind: .dropped), SeatEvent(tick: 5_100, seat: 1, kind: .rejoined),
            SeatEvent(tick: 8_500, seat: 0, kind: .disconnected),
        ], rows: [.init(seat: 1, place: 1, code: "finished", finishTick: 8_000), .init(seat: 2, place: 2, code: "finished", finishTick: 8_100),
                  .init(seat: 0, place: 3, code: "RET", finishTick: nil)])
        // Race B: two players finish.
        let raceB = try RaceFixture.race(["T:skua", "T:tern"], endedAt: endB)
        let finished = { (end: Date, tick: Int) in end - Double(9_000 - tick) / Double(Race.tickRate) }
        let events = [
            Self.event(.queueWait, "T:a", ["waited_s": .int(30), "outcome": .string("matched"), "humans": .int(2)]),
            Self.event(.queueWait, "T:b", ["waited_s": .double(60), "outcome": .string("matched"), "humans": .int(2)]),
            Self.event(.queueWait, "T:c", ["waited_s": .int(90), "outcome": .string("matched"), "humans": .int(3)]),
            Self.event(.queueWait, "T:d", ["waited_s": .int(20), "outcome": .string("left")]),
            Self.event(.fleetLocked, nil, ["humans": .int(2), "boats": .int(10)]),
            Self.event(.fleetLocked, nil, ["humans": .int(2), "boats": .int(10)]),
            Self.event(.fleetLocked, nil, ["humans": .int(3), "boats": .int(10)]),
            Self.event(.briefingLeave, "T:a", ["cooldown_s": .int(0)]),
            Self.event(.briefingLeave, "T:a", ["cooldown_s": .int(0)]),
            Self.event(.briefingLeave, "T:b", ["cooldown_s": .int(300)]),
            Self.event(.roundTrip, "T:a", ["median_ms": .double(40), "p95_ms": .double(60), "seconds": .double(100), "over_warning_s": .double(0)]),
            Self.event(.roundTrip, "T:b", ["median_ms": .double(120), "p95_ms": .double(300), "seconds": .double(200), "over_warning_s": .double(20)]),
            Self.event(.roundTrip, "T:c", ["median_ms": .double(260), "p95_ms": .double(400), "seconds": .double(100), "over_warning_s": .double(80)]),
            // Race again: wren a minute after her finish, tern two; skua too late; gull retired, so hers doesn't count.
            Self.event(.queueJoined, "T:wren", at: finished(endA, 8_000) + 60),
            Self.event(.queueJoined, "T:tern", at: finished(endB, 8_030) + 120),
            Self.event(.queueJoined, "T:skua", at: finished(endB, 8_000) + 601),
            Self.event(.queueJoined, "T:gull", at: endA + 10),
        ]
        let report = Measures.report(events: events, races: [raceA, raceB], from: Self.start, to: Self.start + 86_400)
        // Queue wait and humans per fleet.
        #expect(report.queueWait.count == 3 && report.queueWait.median == 60 && report.queueWait.mean == 60 && report.queueWait.max == 90)
        #expect(report.queueLeftAfter.count == 1 && report.queueLeftAfter.median == 20)
        #expect(report.fleets == 3)
        #expect(report.humansPerFleet == [.init(value: 2, count: 2), .init(value: 3, count: 1)])
        // Briefing leaves and the cooldowns they cost.
        #expect(report.briefingLeaves == .init(leaves: 3, players: 2, cooldowns: 1, cooldownSeconds: 300))
        // Drops, rejoins, RET.
        #expect(report.seats.humanSeats == 4 && report.seats.drops == 1 && report.seats.disconnects == 1 && report.seats.rejoins == 1)
        #expect(report.seats.retired == 1 && report.seats.dropRate == 0.5 && report.seats.retiredRate == 0.25)
        // Round trips: each seat's median, the time over 250 ms, and the bands.
        #expect(report.roundTrip.seats == 3 && report.roundTrip.medianMs.median == 120 && report.roundTrip.p95Ms.max == 400)
        #expect(report.roundTrip.overWarningSeconds == 100 && report.roundTrip.overWarningShare == 0.25)
        #expect(report.roundTrip.bands.map(\.count) == [1, 0, 1, 0, 1])
        #expect(report.roundTrip.bands.map(\.value) == [0, 50, 100, 150, 250])
        // Race again: two of the three with a result, a minute and two after their finish.
        #expect(report.raceAgain.finishers == 3 && report.raceAgain.requeued == 2)
        #expect(abs((report.raceAgain.rate ?? 0) - 2.0 / 3) < 1e-9)
        #expect(abs((report.raceAgain.secondsToRequeue.min ?? 0) - 60) < 1e-3 && abs((report.raceAgain.secondsToRequeue.max ?? 0) - 120) < 1e-3)
    }

    @Test func nothingMeasuredIsEmptyNotZero() {
        let report = Measures.report(events: [], races: [], from: Self.start, to: Self.start + 60)
        #expect(report.queueWait.count == 0 && report.queueWait.median == nil)
        #expect(report.roundTrip.overWarningShare == nil && report.raceAgain.rate == nil && report.seats.dropRate == nil)
    }

    /// What the queue says is recorded as the server's own events, about the player (#28: keyed to the Game Center player).
    @Test func theQueuesEventsAreRecorded() async throws {
        let store = InMemoryAnalyticsStore()
        let measures = ServerMeasures(analytics: AnalyticsIngest(store: store), archive: InMemoryRaceArchive(), ratings: InMemoryRatingBook())
        await measures.record(.joined("T:a"))
        await measures.record(.left("T:b", waited: 12))
        await measures.record(.matched("T:a", waited: 61.5, humans: 3))
        await measures.record(.fleetLocked(humans: 3, boats: 10))
        await measures.record(.briefingLeave("T:a", cooldown: 300))
        let raw = store.raw()
        #expect(raw.map(\.name) == ["queue_joined", "queue_wait", "queue_wait", "fleet_locked", "briefing_leave"])
        #expect(raw.map(\.playerID) == ["T:a", "T:b", "T:a", nil, "T:a"])
        #expect(raw.allSatisfy { $0.source == .server })
        #expect(raw[1].properties == ["waited_s": .double(12), "outcome": .string("left")])
        #expect(raw[2].properties == ["waited_s": .double(61.5), "outcome": .string("matched"), "humans": .int(3)])
        #expect(raw[3].properties == ["humans": .int(3), "boats": .int(10)])
        #expect(raw[4].properties == ["cooldown_s": .double(300)])
        // Read back for the measures.
        let read = try await store.serverEvents(named: ["queue_wait"], since: .distantPast)
        #expect(read.count == 2)
    }

    /// A seat's round trips are recorded about the player who sat it; nobody's seat records nothing.
    @Test func roundTripsAreRecordedAboutTheSeatsPlayer() async throws {
        let store = InMemoryAnalyticsStore(), archive = InMemoryRaceArchive()
        let race = UUID()
        try await archive.register(race, players: [RaceSeatHolder(playerID: "T:a", seat: 0), RaceSeatHolder(playerID: "deleted:x", seat: 1)])
        let measures = ServerMeasures(analytics: AnalyticsIngest(store: store), archive: archive, ratings: InMemoryRatingBook())
        await measures.roundTrips(race: race, seat: 0, RoundTrips(milliseconds: [40, 50, 60, 300, 45]))
        await measures.roundTrips(race: race, seat: 1, RoundTrips(milliseconds: [40]))
        await measures.roundTrips(race: race, seat: 2, RoundTrips(milliseconds: [40]))
        await measures.roundTrips(race: race, seat: 0, RoundTrips())
        let raw = store.raw()
        #expect(raw.count == 1 && raw.first?.name == "round_trip" && raw.first?.playerID == "T:a")
        #expect(raw.first?.properties == ["median_ms": .double(50), "p95_ms": .double(300), "max_ms": .double(300), "samples": .int(5),
                                          "seconds": .double(10), "over_warning_s": .double(2)])
        var trips = RoundTrips()
        trips.add(sentAt: 1_000_000, now: 41_000_000)
        trips.add(sentAt: 2_000, now: 1_000)
        trips.add(sentAt: 0, now: 61_000_000_000)
        #expect(trips.milliseconds == [40])
    }

    /// The queue tells the measures each join, each wait and how it ended, and each fleet it locks.
    @Test func theQueueTellsTheMeasures() async throws {
        let clock = VirtualClock(), log = LaunchLog(), heard = Mutex<[QueueEvent]>([])
        let queue = QueueMatchmaker(settings: QueueSettings(), registry: RaceRegistry(),
                                    draw: RaceDraw(pairings: OnlinePairing.bundled(), seeds: FixtureWindSeedPools(poolSize: 8)),
                                    tokenKey: QueueMatchmakerTests.key, tokenLifetime: 600, random: SeededRandom(seed: 1), now: { clock.now },
                                    launch: { fleet, closed in try await log.record(fleet, closed) },
                                    events: { event in heard.withLock { $0.append(event) } })
        for index in 0..<3 { try await queue.join(QueueMatchmakerTests.player(index)) }
        clock.advance(10)
        try await queue.leave("T:2")
        clock.advance(50)
        await queue.step()
        let fleet = try #require(await queue.lastFleet)
        #expect(heard.withLock { $0 } == [.joined("T:0"), .joined("T:1"), .joined("T:2"), .left("T:2", waited: 10),
                                          .matched("T:0", waited: 60, humans: 2), .matched("T:1", waited: 60, humans: 2),
                                          .fleetLocked(humans: 2, boats: fleet.setup.fleetSize)])
    }
}

/// The balance queries over race logs (#157, #28, #229).
@Suite(.timeLimit(.minutes(1))) struct BalanceQueryTests {
    static let start = MeasuresTests.start

    static func setup(_ pairing: OnlinePairing, seats: Int, tuned: Bool = false) throws -> RaceSetup {
        let venue = pairing.venue.ref
        return try RaceSetup(raceSeed: RaceSeed(3), seats: [.human, .human] + Array(repeating: .bot, count: seats - 2), laps: 1, startSequenceTicks: 1800,
                             venue: tuned ? FileRef(id: venue.id, version: venue.version, hash: venue.hash, tune: 1) : venue,
                             conditions: pairing.conditions.ref)
    }

    static func bot(_ seat: Int, _ tier: BotTier) -> StoredRaceBot {
        StoredRaceBot(seat: seat, source: .fill, rating: 1500, skill: tier.skill(at: 0.5), handling: 0.5, mapVersion: 1)
    }

    /// Acceptance: tables per rule, per venue × conditions, and per tier, from fixture logs.
    @Test func tablesPerRuleVenueConditionsAndTier() throws {
        let pairings = OnlinePairing.bundled()
        try #require(pairings.count >= 2)
        let (first, second) = (pairings[0], pairings[1])
        // Race 1 at the first pairing: two calls under 10 (one a contact), one under 11; a protest matched to the 11 call,
        // one matched to nothing. A club bot and a national bot.
        var one = try RaceFixture.race(["T:a", "T:b", nil, nil], calls: [.init(offender: 0, victim: 1), .init(offender: 1, victim: 0, contact: false),
                                                                         .init(offender: 2, victim: 3, rule: .windwardLeeward, contact: false)],
                                       protests: [(3, 2), (0, 1)],
                                       rows: [.init(seat: 0, place: 1, code: "finished", finishTick: 8_000),
                                              .init(seat: 2, place: 2, code: "finished", finishTick: 8_100),
                                              .init(seat: 1, place: 3, code: "finished", finishTick: 8_200),
                                              .init(seat: 3, place: 4, code: "DSQ", finishTick: nil)],
                                       setup: try Self.setup(first, seats: 4), bots: [Self.bot(2, .club), Self.bot(3, .national)])
        one.incidents = Self.matching(one.incidents, protest: 0, to: 2)
        // Race 2 at the second pairing: no calls; a regional bot wins.
        let two = try RaceFixture.race(["T:a", "T:b", nil], rows: [.init(seat: 2, place: 1, code: "finished", finishTick: 7_000),
                                                                    .init(seat: 0, place: 2, code: "finished", finishTick: 7_500),
                                                                    .init(seat: 1, place: 3, code: "RET", finishTick: nil)],
                                       setup: try Self.setup(second, seats: 3), bots: [Self.bot(2, .regional)])
        // Splits, as a replay would read them: start and roundings by tick.
        let splits: [UUID: RaceSplits] = [
            one.id: RaceSplits(started: [0: 30, 1: 60, 2: 90, 3: 120], rounded: [0: [3_030], 1: [3_060], 2: [3_090]], finished: [0: 6_030, 1: 6_060, 2: 6_090]),
            two.id: RaceSplits(started: [0: 60, 1: 60, 2: 30], rounded: [0: [2_000, 4_000], 2: [1_500, 3_000]], finished: [0: 6_000, 2: 4_500]),
        ]
        let report = BalanceQueries.report(races: [one, two], splits: splits, ratingChanges: [:], from: Self.start, to: Self.start + 86_400)
        #expect(report.races == 2 && report.tunedExcluded == 0)
        // Per rule: calls, those from contact, and the protests matched to them; a protest matched to nothing is "none".
        #expect(report.rules == [.init(rule: "10", calls: 2, contactCalls: 1, protests: 0), .init(rule: "11", calls: 1, contactCalls: 0, protests: 1),
                                 .init(rule: "none", calls: 0, contactCalls: 0, protests: 1)])
        // Per venue × conditions: starts, legs and finishes in seconds.
        #expect(report.splits.count == 2)
        let atFirst = try #require(report.splits.first { $0.venue == "\(first.venue.id)@\(first.venue.version)" && $0.conditions.hasPrefix(first.conditions.id) })
        #expect(atFirst.races == 1 && atFirst.start.count == 4 && atFirst.start.min == 1 && atFirst.start.max == 4)
        #expect(atFirst.legs.count == 2 && atFirst.legs[0].median == 100 && atFirst.legs[1].median == 100)
        #expect(atFirst.finish.count == 3 && atFirst.finish.min == 201)
        let atSecond = try #require(report.splits.first { $0 != atFirst })
        #expect(atSecond.legs.count == 3 && atSecond.legs.map(\.count) == [2, 2, 2] && atSecond.finish.max == 200)
        // Per tier: humans, then the bots by tier.
        #expect(report.tiers.map(\.tier) == ["human", "club", "regional", "national"])
        let human = report.tiers[0]
        #expect(human.seats == 4 && human.finished == 3 && human.finishShare == 0.75)
        // Places as a share of the fleet: 0, 2/3 in race one; 1/2, 1 in race two.
        #expect(abs((human.meanPlace ?? 0) - (0 + 2.0 / 3 + 0.5 + 1) / 4) < 1e-9)
        #expect(report.tiers[1] == .init(tier: "club", seats: 1, finished: 1, finishShare: 1, meanPlace: 1.0 / 3))
        #expect(report.tiers[2] == .init(tier: "regional", seats: 1, finished: 1, finishShare: 1, meanPlace: 0))
        #expect(report.tiers[3] == .init(tier: "national", seats: 1, finished: 0, finishShare: 0, meanPlace: 1))
    }

    /// Acceptance: a race sailed on a tuned file (#229) is in none of the tables.
    @Test func excludesTunedRaces() throws {
        let pairing = try #require(OnlinePairing.bundled().first)
        let plain = try RaceFixture.race(["T:a", "T:b"], calls: [.init(offender: 0, victim: 1)], setup: try Self.setup(pairing, seats: 2))
        let tuned = try RaceFixture.race(["T:a", "T:b"], calls: [.init(offender: 1, victim: 0, rule: .windwardLeeward)],
                                         setup: try Self.setup(pairing, seats: 2, tuned: true))
        #expect(BalanceQueries.isTuned(tuned) && !BalanceQueries.isTuned(plain))
        let changes = [plain.id: Self.changes([("T:a", 1600, 1), ("T:b", 1500, 2)]), tuned.id: Self.changes([("T:a", 1600, 2), ("T:b", 1500, 1)])]
        let splits = [plain.id: RaceSplits(started: [0: 30], finished: [0: 3_000]), tuned.id: RaceSplits(started: [0: 30, 1: 30], finished: [1: 900])]
        let report = BalanceQueries.report(races: [plain, tuned], splits: splits, ratingChanges: changes, from: Self.start, to: Self.start + 60)
        #expect(report.races == 1 && report.tunedExcluded == 1)
        #expect(report.rules == [.init(rule: "10", calls: 1, contactCalls: 1, protests: 0)])
        #expect(report.splits.map(\.races) == [1] && report.splits.first?.start.count == 1 && report.splits.first?.finish.max == 100)
        #expect(report.tiers.map(\.seats) == [2])
        #expect(report.calibration.map(\.pairs) == [1] && report.calibration.first?.actual == 1)
        let alone = BalanceQueries.report(races: [plain], splits: splits, ratingChanges: changes, from: Self.start, to: Self.start + 60)
        #expect(alone.rules == report.rules && alone.splits == report.splits && alone.tiers == report.tiers && alone.calibration == report.calibration)
    }

    /// Acceptance: Glicko's expected score against the actual results by rating gap, and each player's finish variance
    /// over her last races (fixture logs).
    @Test func ratingCalibrationAndFinishVariance() throws {
        var races: [ArchivedRace] = [], changes: [UUID: [StoredRatingChange]] = [:]
        // Race 1: 1700 beats 1500 beats 1450. Race 2: 1450 beats 1500.
        let first = try RaceFixture.race(["T:hi", "T:mid", "T:lo"], endedAt: Self.start)
        changes[first.id] = Self.changes([("T:hi", 1700, 1), ("T:mid", 1500, 2), ("T:lo", 1450, 3)])
        let second = try RaceFixture.race(["T:mid", "T:lo"], endedAt: Self.start + 60)
        changes[second.id] = Self.changes([("T:mid", 1500, 2), ("T:lo", 1450, 1)])
        races += [first, second]
        let report = BalanceQueries.report(races: races, splits: [:], ratingChanges: changes, from: Self.start, to: Self.start + 3600)
        #expect(report.calibration.map(\.gapFrom) == [0, 200] && report.calibration.map(\.gapTo) == [100, 300])
        #expect(report.calibration.map(\.pairs) == [2, 2])
        // 50 points apart: won once, lost once; 200 and 250 apart: won both.
        #expect(report.calibration[0].actual == 0.5 && report.calibration[1].actual == 1)
        let near = BalanceQueries.expectedScore(Glicko2(rating: 1500, deviation: 50, volatility: 0.06), against: Glicko2(rating: 1450, deviation: 50, volatility: 0.06))
        #expect(abs((report.calibration[0].expected ?? 0) - near) < 1e-12)
        #expect(near > 0.5 && near < 0.6)
        // Glicko-2's E with a small deviation is about the Elo curve: 1 / (1 + 10^(-gap/400)).
        #expect(abs(near - 1 / (1 + pow(10, -50.0 / 400))) < 0.01)
        let far = report.calibration[1].expected ?? 0
        #expect(far > 0.75 && far < 0.85)

        // Finish variance: places as a share of the fleet over her last races, the newest first.
        var settings = MeasuresSettings()
        settings.varianceRaces = 3
        let places = [0, 2, 1, 1]
        let mine = try places.enumerated().map { index, place in
            try RaceFixture.race(["T:me", "T:x", "T:y"], endedAt: Self.start + Double(index) * 60,
                                 rows: [0, 1, 2].map { seat in RaceSummary.Row(seat: seat, place: seat == 0 ? place + 1 : (seat <= place ? seat : seat + 1),
                                                                               code: "finished", finishTick: 8_000) })
        }
        let variance = BalanceQueries.report(races: mine, splits: [:], ratingChanges: [:], from: Self.start, to: Self.start + 3600, settings: settings)
            .finishVariance
        let me = try #require(variance.first { $0.playerID == "T:me" })
        // Her last three: 1, ½, ½ of the fleet.
        #expect(me.races == 3 && abs(me.meanPlace - 2.0 / 3) < 1e-12 && abs(me.variance - 1.0 / 18) < 1e-12)
        // Fewer races than the minimum: none.
        settings.minVarianceRaces = 5
        #expect(BalanceQueries.report(races: mine, splits: [:], ratingChanges: [:], from: Self.start, to: Self.start, settings: settings)
            .finishVariance.isEmpty)
    }

    /// The splits of a race replayed from its log: every seat started, rounded and finished in tick order.
    @Test func splitsAreReadFromAReplay() throws {
        var splits = RaceSplits()
        for event in [RaceEvent(tick: 40, kind: .started(seat: 1)), RaceEvent(tick: 900, kind: .rounded(seat: 1, mark: "W")),
                      RaceEvent(tick: 1_800, kind: .rounded(seat: 1, mark: "L")), RaceEvent(tick: 2_400, kind: .finished(seat: 1, place: 1)),
                      RaceEvent(tick: 50, kind: .started(seat: 0)), RaceEvent(tick: 1_000, kind: .gun)] { splits.add(event) }
        #expect(splits.legs(of: 1) == [860, 900, 600] && splits.legs(of: 0) == nil)
        // A real replay: the start sequence's last second and the gun, nobody over the line yet.
        let short = try RaceFixture.race(["T:a", "T:b"], finalTick: 15, setup: try RaceSetup(raceSeed: RaceSeed(9), seats: [.human, .human], laps: 1,
                                                                                            startSequenceTicks: 30)).log
        #expect(try RaceSplits.replaying(short).finished.isEmpty)
        // A log that doesn't replay (another simulation version) throws.
        var log = try RaceFixture.race(["T:a", "T:b"]).log
        log.header.setup = try RaceSetup(simulationVersion: "0", raceSeed: RaceSeed(1), seats: [.human, .human], laps: 1, startSequenceTicks: 60)
        #expect(throws: (any Error).self) { try RaceSplits.replaying(log) }
    }

    static func changes(_ players: [(String, Double, Int)]) -> [StoredRatingChange] {
        players.map { player, rating, place in
            let before = PlayerRating(glicko: Glicko2(rating: rating, deviation: 50, volatility: 0.06), established: true)
            return StoredRatingChange(playerID: player, before: before, after: before, place: place, opponents: players.count - 1)
        }
    }

    /// `index` with its `protest`th protest matched to incident `incident`.
    static func matching(_ index: IncidentIndex, protest: Int, to incident: Int) -> IncidentIndex {
        var rebuilt = IncidentIndex()
        for each in index.incidents {
            let opened = rebuilt.open(between: each.parties.low, and: each.parties.high, tick: each.tick, leg: each.leg, trigger: each.trigger)
            var updated = opened
            updated.outcome = each.outcome
            rebuilt.update(updated)
        }
        for (i, each) in index.protests.enumerated() {
            rebuilt.recordProtest(Protest(tick: each.tick, leg: each.leg, protester: each.protester, protested: each.protested,
                                          matchedIncidentId: i == protest ? incident : each.matchedIncidentId))
        }
        return rebuilt
    }
}

/// The measures and balance routes (#157 on #154's admin tool).
@Suite(.timeLimit(.minutes(1))) struct MeasuresRouteTests {
    @Test func theAdminToolAnswersTheMeasuresAndTheBalance() async throws {
        let archive = InMemoryRaceArchive(), store = InMemoryAnalyticsStore()
        let measures = ServerMeasures(analytics: AnalyticsIngest(store: store), archive: archive, ratings: archive.ratings)
        await measures.record(.matched("T:a", waited: 42, humans: 2))
        await measures.record(.fleetLocked(humans: 2, boats: 10))
        let race = try RaceFixture.race(["T:a", "T:b"], calls: [.init(offender: 0, victim: 1)], rated: false)
        try await archive.register(race.id, players: race.seating.humans)
        try await archive.close(RaceFixture.record(race))
        let world = AdminWorld(archive: archive)
        let api = AdminAPI(settings: world.api.settings, moderation: world.moderation, archive: archive, measures: measures.queries)
        func get(_ uri: String) async -> (HTTPResponseStatus, [String: Any]) {
            var headers = HTTPHeaders()
            headers.add(name: "Authorization", value: "Bearer \(AdminWorld.token)")
            let (path, query) = RequestHandler.split(uri)
            let reply = await api.respond(method: .GET, path: path, query: query, headers: headers)
            return (reply.status, (try? JSONSerialization.jsonObject(with: Data(reply.body))) as? [String: Any] ?? [:])
        }
        let (status, json) = await get("/admin/measures?days=7")
        #expect(status == .ok)
        #expect((json["queueWait"] as? [String: Any])?["median"] as? Double == 42 && json["fleets"] as? Int == 1)
        #expect((json["seats"] as? [String: Any])?["humanSeats"] as? Int == 2)
        let (balanceStatus, balance) = await get("/admin/balance?days=7&splits=0")
        #expect(balanceStatus == .ok && balance["races"] as? Int == 1 && balance["unreplayed"] as? Int == 0)
        #expect((balance["rules"] as? [[String: Any]])?.first?["rule"] as? String == "10")
        // Without the measures, the routes are absent; without a token, refused.
        #expect(await world.call(.GET, "/admin/measures").status == .notFound)
        #expect(await world.call(.GET, "/admin/balance", token: nil).status == .unauthorized)
        #expect(try AdminCommand.request(["balance", "7", "--no-splits"]).url(on: URL(string: "http://h")!)?.absoluteString
            == "http://h/admin/balance?days=7&splits=0")
        #expect(try AdminCommand.request(["measures"]).path == "/admin/measures")
    }
}
