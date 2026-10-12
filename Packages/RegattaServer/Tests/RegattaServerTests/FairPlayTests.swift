import Foundation
import NIOHTTP1
import Persistence
import RegattaAdminClient
import RegattaCore
import RegattaProtocol
@testable import RegattaServerKit
import Testing

/// Synthetic closed races for the fair-play scan (#155) and the measures (#157): who sat each seat (nil a bot), and what
/// happened in it.
enum RaceFixture {
    struct Call {
        var offender: Int
        var victim: Int
        var rule: RacingRule = .portStarboard
        var contact = true
    }

    static func race(_ players: [String?], id: UUID = UUID(), endedAt: Date = Date(timeIntervalSince1970: 1_791_460_800), finalTick: Int = 9_000,
                     inputs: [InputRecord] = [], seatEvents: [SeatEvent] = [], calls: [Call] = [], protests: [(protester: Int, protested: Int)] = [],
                     rows: [RaceSummary.Row]? = nil, takenOver: Set<Int> = [], setup: RaceSetup? = nil, bots: [StoredRaceBot] = [],
                     rated: Bool = true) throws -> ArchivedRace {
        let setup = try setup ?? RaceSetup(raceSeed: RaceSeed(7), seats: players.map { $0 == nil ? .bot : .human }, laps: 1, startSequenceTicks: 1800)
        var index = IncidentIndex()
        var tick = 100
        for call in calls {
            let incident = index.open(between: call.offender, and: call.victim, tick: tick, leg: 0, trigger: call.contact ? .contact : .nearMiss)
            var called = incident
            called.outcome = .called(RuleCall(incidentId: incident.id, tick: tick, rule: call.rule, offender: call.offender, victim: call.victim, leg: 0,
                                              turnsOwed: 1, startDeadlineTick: nil, completeDeadlineTick: nil))
            index.update(called)
            tick += 10
        }
        for protest in protests {
            index.recordProtest(Protest(tick: tick, leg: 0, protester: protest.protester, protested: protest.protested, matchedIncidentId: nil))
            tick += 10
        }
        let rows = rows ?? players.indices.map { RaceSummary.Row(seat: $0, place: $0 + 1, code: "finished", finishTick: 8_000 + $0 * 30) }
        var summary = RaceSummary(venue: "Harbour", roster: players.indices.map { RosterEntry(name: "Sailor \($0)", colorIndex: $0, isBot: players[$0] == nil) },
                                  results: .empty, turnsServed: players.map { _ in 0 })
        summary.rows = rows
        summary.rated = rated
        let humans = players.indices.compactMap { seat in players[seat].map { RaceSeatHolder(playerID: $0, seat: seat) } }
        return ArchivedRace(id: id, endedAt: endedAt,
                            log: RaceLog(header: .init(setup: setup, windSeed: WindSeed(7), tideStateAtGun: nil), inputs: inputs,
                                         seatEvents: seatEvents, finalTick: finalTick),
                            summary: summary, incidents: index, bots: bots, seating: RaceSeating(humans: humans, takenOver: takenOver))
    }

    /// `count` taps on `seat`, `spacing` ticks apart from `start`.
    static func taps(seat: Int, count: Int, start: Int = 10, spacing: Int = 7) -> [InputRecord] {
        (0..<count).map { InputRecord(tick: start + $0 * spacing, seat: seat, kind: .tap(.tackGybe)) }
    }

    /// The race as the archive closes it: its log, results and incidents as stored.
    static func record(_ race: ArchivedRace) throws -> ClosedRaceRecord {
        ClosedRaceRecord(id: race.id, log: try race.log.jsonData(pretty: false), digest: 1, simulationVersion: race.log.header.simulationVersion,
                         toolchain: "test", results: try race.summary.encoded(), incidents: try RaceResultsFeed.encode(race.incidents),
                         rated: race.summary.rated, bots: race.bots)
    }
}

@Suite(.timeLimit(.minutes(1))) struct FairPlayTests {
    static let settings = FairPlaySettings()

    static func findings(_ races: [ArchivedRace]) -> [FairPlayFinding] {
        var scan = FairPlayScan(settings: settings)
        for race in races { scan.add(race) }
        return scan.findings()
    }

    /// Acceptance: synthetic logs trip each flag. Rule calls per race, and those from contact above all.
    @Test func ruleCallsTripTheRuleCallFlag() throws {
        // gull: two calls a race in five races, one from a contact: 1 contact call a race, over 0.75.
        let gull = try (0..<5).map { _ in
            try RaceFixture.race(["T:gull", "T:wren", nil], calls: [.init(offender: 0, victim: 1), .init(offender: 0, victim: 2, contact: false)])
        }
        // tern: two near-miss calls a race: 2 a race, over 1.5, and no contact.
        let tern = try (0..<5).map { _ in
            try RaceFixture.race(["T:tern", "T:skua"], calls: [.init(offender: 0, victim: 1, contact: false), .init(offender: 0, victim: 1, contact: false)])
        }
        // auk: as many calls, in four races only: too few to rate.
        let auk = try (0..<4).map { _ in try RaceFixture.race(["T:auk", "T:puffin"], calls: [.init(offender: 0, victim: 1), .init(offender: 0, victim: 1)]) }
        let found = Self.findings(gull + tern + auk)
        let calls = found.filter { $0.kind == .ruleCalls }
        #expect(calls.map(\.playerID) == ["T:gull", "T:tern"])
        #expect(calls[0].value == 1 && calls[0].threshold == 0.75 && calls[0].raceIDs.count == 5)
        #expect(calls[0].detail == "10 rule calls (5 from contact) in 5 races: contact calls per race")
        #expect(calls[1].value == 2 && calls[1].threshold == 1.5)
        // The victims and the bot are never flagged.
        #expect(!found.contains { ["T:wren", "T:skua", "T:puffin"].contains($0.playerID) })
    }

    @Test func protestsFromDifferentPlayersTripTheProtestFlag() throws {
        // Four different players protest gull over three races; a bot and one player twice more don't add.
        let races = try [
            RaceFixture.race(["T:gull", "T:a", "T:b", nil], protests: [(1, 0), (2, 0), (3, 0)]),
            RaceFixture.race(["T:c", "T:gull", "T:a"], protests: [(0, 1), (2, 1)]),
            RaceFixture.race(["T:gull", "T:d"], protests: [(1, 0)]),
            // wren: three players, and one of them three times.
            RaceFixture.race(["T:wren", "T:a", "T:b", "T:c"], protests: [(1, 0), (2, 0), (3, 0), (3, 0), (3, 0)]),
        ]
        let found = Self.findings(races).filter { $0.kind == .protests }
        #expect(found.map(\.playerID) == ["T:gull"])
        #expect(found.first?.value == 4 && found.first?.raceIDs.count == 3)
    }

    @Test func identicalInputsAcrossRacesTripTheInputFlag() throws {
        let scripted = RaceFixture.taps(seat: 0, count: 80)
        let races = try [
            // gull's inputs, tick for tick, in two races; skua sails them in a third, at seat 0 too.
            RaceFixture.race(["T:gull", "T:wren"], inputs: scripted + RaceFixture.taps(seat: 1, count: 80, spacing: 5)),
            RaceFixture.race(["T:gull", "T:wren"], inputs: scripted + RaceFixture.taps(seat: 1, count: 80, spacing: 6)),
            RaceFixture.race(["T:skua", nil], inputs: scripted),
            // tern repeats herself, but under the minimum: a start sat still isn't a script.
            RaceFixture.race(["T:tern", nil], inputs: RaceFixture.taps(seat: 0, count: 20)),
            RaceFixture.race(["T:tern", nil], inputs: RaceFixture.taps(seat: 0, count: 20)),
        ]
        let found = Self.findings(races).filter { $0.kind == .identicalInputs }
        #expect(found.map(\.playerID) == ["T:gull", "T:skua"])
        #expect(found.allSatisfy { $0.value == 3 && $0.raceIDs.count == 3 })
    }

    @Test func dropsJustBeforeTheCloseTripTheLateDropFlag() throws {
        let unfinished = [RaceSummary.Row(seat: 1, place: 1, code: "finished", finishTick: 8_000),
                          RaceSummary.Row(seat: 0, place: 2, code: "RET", finishTick: nil)]
        let late = { (kind: SeatEvent.Kind) in try RaceFixture.race(["T:gull", "T:wren"], seatEvents: [SeatEvent(tick: 8_500, seat: 0, kind: kind)],
                                                                     rows: unfinished) }
        var races = try [late(.disconnected), late(.dropped), late(.left)]
        // Not hers: back again, early, or finished.
        races += try [
            RaceFixture.race(["T:wren", "T:gull"], seatEvents: [SeatEvent(tick: 8_500, seat: 0, kind: .dropped), SeatEvent(tick: 8_600, seat: 0, kind: .rejoined)],
                             rows: unfinished.map { var row = $0; row.seat = 1 - row.seat; return row }),
            RaceFixture.race(["T:wren", "T:gull"], seatEvents: [SeatEvent(tick: 6_000, seat: 0, kind: .dropped)],
                             rows: unfinished.map { var row = $0; row.seat = 1 - row.seat; return row }),
            RaceFixture.race(["T:wren", "T:gull"], seatEvents: [SeatEvent(tick: 8_990, seat: 0, kind: .left)]),
        ]
        let found = Self.findings(races).filter { $0.kind == .lateDrops }
        #expect(found.map(\.playerID) == ["T:gull"])
        #expect(found.first?.value == 3)
    }

    /// A seat a bot took over before the gun, or a deleted player's, is nobody's: no flag.
    @Test func seatsThatArentAPlayersAreNeverFlagged() throws {
        let races = try (0..<5).map { _ in
            try RaceFixture.race(["T:gull", "deleted:1"], calls: [.init(offender: 0, victim: 1), .init(offender: 1, victim: 0), .init(offender: 1, victim: 0)],
                                 takenOver: [0])
        }
        #expect(Self.findings(races).isEmpty)
    }

    /// The nightly job: each finding raised once a window into the admin queue, never a penalty (acceptance: asserted).
    @Test func theJobRaisesFlagsIntoTheQueueAndNeverAPenalty() async throws {
        let archive = InMemoryRaceArchive()
        let world = AdminWorld(archive: archive)
        var races = try (0..<5).map { _ in try RaceFixture.race(["T:gull", "T:wren"], calls: [.init(offender: 0, victim: 1)]) }
        races += try ["T:a", "T:b", "T:c", "T:d"].map { try RaceFixture.race([$0, "T:wren"], protests: [(0, 1)]) }
        for race in races {
            try await archive.register(race.id, players: race.seating.humans)
            try await archive.close(RaceFixture.record(race))
        }
        let job = FairPlayJob(store: world.store, archive: archive)
        let raised = await job.runOnce()
        #expect(raised.map(\.kind) == [.ruleCalls, .protests] && raised.map(\.playerID) == ["T:gull", "T:wren"])
        #expect(raised.allSatisfy { $0.decision == nil && $0.dueAt == $0.createdAt + 24 * 3600 })
        // Raised once a window.
        #expect(await job.runOnce().isEmpty)
        // In the queue with the reports, by due time.
        let report = try await world.file(.message, by: "T:wren", on: "T:gull")
        let queue = await world.call(.GET, "/admin/queue")
        let items = try #require(queue.json["items"] as? [[String: Any]])
        #expect(items.compactMap { $0["type"] as? String }.sorted() == ["flag", "flag", "report"])
        #expect(items.compactMap { ($0["dueAt"] as? Int) } == items.compactMap { ($0["dueAt"] as? Int) }.sorted())
        let detail = await world.call(.GET, "/admin/flags/\(raised[0].id)")
        #expect((detail.json["flag"] as? [String: Any])?["kind"] as? String == "rule_calls")
        // Decided either way: no penalty, no suspension, for anyone.
        #expect(await world.call(.POST, "/admin/flags/\(raised[0].id)/decide?decision=confirm").status == .ok)
        #expect(await world.call(.POST, "/admin/flags/\(raised[1].id)/decide?decision=dismiss").status == .ok)
        #expect(await world.call(.POST, "/admin/flags/\(raised[1].id)/decide?decision=dismiss").status == .conflict)
        #expect(await world.call(.POST, "/admin/flags/\(raised[1].id)/decide?decision=ban").status == .badRequest)
        #expect(await world.call(.GET, "/admin/flags/999").status == .notFound)
        #expect(try await world.store.flag(raised[0].id)?.decision == .upheld)
        #expect(try await world.store.flag(raised[1].id)?.decidedBy == "alice")
        for player in ["T:gull", "T:wren", "T:a", "T:b", "T:c", "T:d"] {
            #expect(try await world.store.penalties(of: player).isEmpty, "\(player)")
            #expect(try await world.restrictions.restrictions(of: player).suspension == nil)
        }
        #expect(try await world.store.report(report.id)?.decision == nil)
        #expect(try await world.store.actions(about: nil, limit: 10).map(\.action) == ["decide_flag", "decide_flag"])
    }

    /// Races outside the window aren't read.
    @Test func theJobReadsTheWindowOnly() async throws {
        let archive = InMemoryRaceArchive(), store = InMemoryModerationStore()
        for _ in 0..<5 {
            let race = try RaceFixture.race(["T:gull", "T:wren"], calls: [.init(offender: 0, victim: 1)])
            try await archive.register(race.id, players: race.seating.humans)
            try await archive.close(RaceFixture.record(race))
        }
        let later = FairPlayJob(store: store, archive: archive, now: { Date() + 31 * 86_400 })
        #expect(await later.runOnce().isEmpty)
        let now = FairPlayJob(store: store, archive: archive, now: { Date() + 1 })
        #expect(await now.runOnce().count == 1)
    }

    @Test func theCommandLineReachesTheFlagRoutes() throws {
        let base = try #require(URL(string: "http://h:1"))
        #expect(try AdminCommand.request(["flag", "3"]).url(on: base)?.absoluteString == "http://h:1/admin/flags/3")
        let decide = try AdminCommand.request(["decide-flag", "3", "confirm"])
        #expect(decide.method == "POST" && decide.url(on: base)?.absoluteString == "http://h:1/admin/flags/3/decide?decision=confirm")
        #expect(AdminRoute(["flags", "3"]) == .flag("3") && AdminRoute(["flags", "3", "decide"])?.method == .POST)
    }
}
