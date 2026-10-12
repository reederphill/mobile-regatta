import Foundation
import RaceHost
import RegattaBots
import RegattaCore
import RegattaProtocol
@testable import RegattaServerKit
import RegattaServiceClient
import RegattaServices
import Testing

extension RaceSims {
    /// #148: the reports a player's results stream carries, and the last race.
    @Suite(.timeLimit(.minutes(2))) struct RaceResultsFeedTests {
        private static let roster = (0..<4).map { RosterEntry(name: "Boat \($0)", colorIndex: $0) }

        /// An index with a call against seat 1 (on seat 0), a contact between 2 and 3, a mark touch and a protest by 0.
        private static func incidents() -> IncidentIndex {
            var index = IncidentIndex()
            var call = index.open(between: 0, and: 1, tick: 40, leg: 0)
            call.outcome = .called(RuleCall(incidentId: call.id, tick: 41, rule: .portStarboard, offender: 1, victim: 0, leg: 0, turnsOwed: 1,
                                            startDeadlineTick: nil, completeDeadlineTick: nil))
            index.update(call)
            index.open(between: 2, and: 3, tick: 50, leg: 0)
            index.recordMarkTouch(MarkTouch(tick: 60, leg: 1, seat: 0, mark: "Windward"))
            index.recordMarkTouch(MarkTouch(tick: 70, leg: 1, seat: 2, mark: "Windward"))
            index.recordProtest(Protest(tick: 80, leg: 1, protester: 0, protested: 1, matchedIncidentId: 0))
            return index
        }

        private static func live(tick: Int, finishers: [SeatResult], sailing: [Int], results: RaceResults? = nil) -> LiveResults {
            LiveResults(tick: tick, expectedCloseTick: 9_000, finishers: finishers, sailing: sailing, incidents: incidents(),
                        turnsServed: [1, 0, 0, 0], results: results)
        }

        /// Acceptance: the report fills in as boats finish and ends closed, every seat placed; she sees only her own
        /// incidents, touches and protests; every called boat is flagged.
        @Test func reportsFillInAndEndClosedWithOwnIncidentsOnly() throws {
            let race = UUID()
            let start = RaceResultsFeed.live(race, seat: 0, roster: Self.roster, results: Self.live(tick: 100, finishers: [], sailing: [0, 1, 2, 3]))
            let first = SeatResult(seat: 2, place: 1, code: .finished, finishTick: 900)
            let filling = RaceResultsFeed.live(race, seat: 0, roster: Self.roster, results: Self.live(tick: 950, finishers: [first], sailing: [0, 1, 3]))
            let final = RaceResults(rows: [first, SeatResult(seat: 0, place: 2, code: .finished, finishTick: 1_000),
                                           SeatResult(seat: 3, place: 3, code: .byDistance), SeatResult(seat: 1, place: 4, code: .ret)], rated: true)
            let summary = RaceSummary(venue: "Bay", roster: Self.roster, results: final, turnsServed: [1, 0, 0, 0])
            let closed = RaceResultsFeed.closed(race, seat: 0, summary: try RaceSummary(decoding: try summary.encoded()),
                                                incidents: try RaceResultsFeed.decodeIncidents(try RaceResultsFeed.encode(Self.incidents())))

            #expect(start.results.rows.isEmpty && start.sailing == [0, 1, 2, 3] && !start.isClosed)
            #expect(filling.results.order == [2] && filling.sailing == [0, 1, 3] && !filling.isClosed)
            #expect(closed.results == final && closed.sailing.isEmpty && closed.isClosed)
            for report in [start, filling, closed] {
                #expect(report.raceID == RaceID(race.uuidString.lowercased()))
                #expect(report.incidents.map(\.seat) == [0])
                let own = try #require(report.incidents.first)
                #expect(own.incidents.map(\.id) == [0])
                #expect(own.markTouches.map(\.seat) == [0])
                #expect(own.protests.map(\.protester) == [0])
                #expect(own.turnsServed == 1)
                #expect(report.flaggedSeats == [1])
            }
        }

        /// The lobby gets one "X won" line at the close: the first row's sailor; none when nobody sailed it to the end.
        @Test func winnerSystemLineAtClose() async throws {
            let won = RaceSummary(venue: "Bay", roster: Self.roster,
                                  results: RaceResults(rows: [SeatResult(seat: 2, place: 1, code: .finished, finishTick: 900),
                                                              SeatResult(seat: 0, place: 2, code: .ret)], rated: false),
                                  turnsServed: [0, 0, 0, 0])
            #expect(won.winnerLine == .winner(venue: "Bay", nickname: "Boat 2"))
            for code in [ResultCode.ocs, .ret] {
                let nobody = RaceSummary(venue: "Bay", roster: Self.roster, results: RaceResults(rows: [SeatResult(seat: 0, place: 1, code: code)], rated: false),
                                         turnsServed: [0, 0, 0, 0])
                #expect(nobody.winnerLine == nil)
            }

            // A bot that wins says nothing (#149): the line names a human winner only.
            var crewed = Self.roster
            crewed[2].isBot = true
            let bot = RaceSummary(venue: "Bay", roster: crewed, results: won.results, turnsServed: [0, 0, 0, 0])
            #expect(bot.winnerLine == nil)

            // Through the lifecycle: one line when a race closes after the gun, none when one is cancelled.
            let rig = LifecycleRig(settings: LifecycleRig.quickGrace())
            let cancelled = try await rig.race(["T:0"])
            await rig.lifecycle.cancel(cancelled.id)
            await rig.end(cancelled)
            /// A race `player` sails alone against the bots and closes having won, as a queue race or a dev-arranged one.
            func sailHome(_ player: String, announces: Bool) async throws {
                let closed = try await rig.race([player], announces: announces)
                let transport = KeptTransport()
                try await closed.join(seat: 0, transport: transport)
                var seq: UInt32 = 0
                await rig.sail(closed, [0], to: 900, seq: &seq)
                await closed.leave(seat: 0, transport: transport)
                await rig.runUntilEnded(closed, limit: 1_200)
                // Her boat sailed it home ahead of the bots: the race as its host closed it, with her seat's row first.
                var outcome = await closed.host.close()
                let rows = try #require(outcome.results).rows
                outcome.results = RaceResults(rows: [SeatResult(seat: 0, place: 1, code: .finished, finishTick: 900)]
                                                  + rows.filter { $0.seat != 0 }.enumerated().map {
                                                      SeatResult(seat: $1.seat, place: $0 + 2, code: $1.code, finishTick: $1.finishTick)
                                                  }, rated: false)
                await rig.lifecycle.ended(closed.id, .closed(outcome))
            }
            try await sailHome("T:0", announces: true)
            // The cancelled race said nothing: the first line is the closed race's.
            #expect(rig.lobby.lines == [.winner(venue: "Test Bay", nickname: "NT:0")])
            // The line's player is stored with it, so her deletion takes it (#152).
            #expect(rig.lobby.events.all.last == .winner(venue: "Test Bay", nickname: "NT:0", playerID: "T:0"))

            // A race the bots won: no line.
            let bots = try await rig.race(["T:1"])
            await rig.runUntilEnded(bots, limit: 300)
            #expect(await bots.host.outcome?.results?.rows.first?.seat != 0)
            await rig.end(bots)
            #expect(rig.lobby.lines.count == 1)

            // A dev-arranged race (#152): the same win is no line, and the lobby hears nothing of its finishers.
            let before = rig.lobby.events.all
            try await sailHome("T:2", announces: false)
            #expect(rig.lobby.events.all == before)
        }

        /// #149: a report's roster, live and closed, and the last race's mark each bot: the ones that filled the fleet
        /// and the one sailing a seat its player gave up before the gun, under her sailing name. Rows stored before the
        /// flag read as no bots.
        @Test func resultsAndLastRaceMarkBots() async throws {
            var roster = Self.roster
            roster[2].isBot = true
            roster[3] = RosterEntry(name: "Skua", colorIndex: 3, isBot: true)
            let results = RaceResults(rows: [SeatResult(seat: 0, place: 1, code: .finished, finishTick: 900)], rated: false)
            let summary = RaceSummary(venue: "Bay", roster: roster, results: results, turnsServed: [0, 0, 0, 0])
            let stored = try RaceSummary(decoding: try summary.encoded())
            #expect(stored == summary && stored.rosterEntries == roster)
            #expect(RaceResultsFeed.closed(UUID(), seat: 0, summary: stored, incidents: IncidentIndex()).roster.map(\.isBot) == [false, false, true, true])
            #expect(RaceResultsFeed.live(UUID(), seat: 0, roster: roster, results: Self.live(tick: 1, finishers: [], sailing: [0])).roster == roster)
            let old = Data(#"{"rated":false,"roster":[{"colorIndex":0,"name":"Ann"},{"colorIndex":1,"name":"Seat 2"}],"rows":[],"turnsServed":[0,0],"venue":"Bay"}"#.utf8)
            #expect(try RaceSummary(decoding: old).rosterEntries == [RosterEntry(name: "Ann", colorIndex: 0), RosterEntry(name: "Seat 2", colorIndex: 1)])

            // Through the lifecycle: T:1 gives her seat up before the gun, T:0 sails on and then drops.
            let rig = LifecycleRig(settings: LifecycleRig.quickGrace())
            let race = try await rig.race(["T:0", "T:1"], seats: 4)
            let transports = [KeptTransport(), KeptTransport()]
            for seat in 0..<2 { try await race.join(seat: seat, transport: transports[seat]) }
            let updates = rig.lifecycle.results(for: "T:0")
            await rig.run(race, to: -20)
            #expect(await race.quit(seat: 1, transport: transports[1]))
            var seq: UInt32 = 0
            await rig.sail(race, [0], to: 30, seq: &seq)
            await race.leave(seat: 0, transport: transports[0])
            await rig.runUntilEnded(race, limit: 600)
            await rig.end(race)
            let reports = await collect(updates) { if case .report(let report) = $0 { report.isClosed } else { true } }
            guard case .report(let final)? = reports.last else { Issue.record("no closed report: \(reports)"); return }
            #expect(final.isClosed && final.roster.map(\.isBot) == [false, true, true, true])
            #expect(final.roster[0].name == "NT:0")
            #expect(final.roster.dropFirst().allSatisfy { FleetRoster.sailingNames.contains($0.name) })
            #expect(Set(final.roster.map(\.name)).count == 4)
            let last = try #require(try await rig.lifecycle.lastRace(of: "T:0"))
            #expect(last.report == final)
            // Over the service wire and back, flags and all.
            let frame = try Frame(seq: 1, tick: 0, message: .raceSessionReply(ServiceReply(id: 1, result: .update(.report(final.wire))))).encoded()
            guard case .raceSessionReply(let reply) = try Frame(decoding: frame).message, case .update(.report(let wire)) = reply.result else {
                Issue.record("not a report")
                return
            }
            #expect(wire.roster == final.roster)
        }

        /// #469: results and rating streams dropped as soon as they are opened leave no watcher: the rating change that
        /// comes next isn't sent to a stream nobody holds, but kept for the one she opens.
        @Test func streamsDroppedAtOnceLeaveNoWatcherToSwallowARatingChange() async throws {
            let rig = LifecycleRig(settings: LifecycleRig.quickGrace())
            let race = try await rig.race(["T:0"])
            for _ in 0..<50 {
                _ = rig.lifecycle.results(for: "T:0")
                _ = rig.lifecycle.ratingChanges(for: "T:0")
            }
            #expect(!rig.lifecycle.resultWatchers.isWatched("T:0"))
            #expect(!rig.lifecycle.ratingWatchers.isWatched("T:0"))
            await rig.runUntilEnded(race, limit: 300)
            await rig.end(race)
            #expect(rig.lifecycle.resultWatchers.keys.isEmpty && rig.lifecycle.ratingWatchers.keys.isEmpty)
            let change = await collect(rig.lifecycle.ratingChanges(for: "T:0")) { _ in true }
            #expect(change == [RatingChange(raceID: RaceResultsFeed.raceID(race.id), outcome: .unrated)])
        }

        /// Acceptance: the last race is the one she last finished in, until her next race ends; a cancelled race doesn't
        /// replace it; an unrated close pushes `.unrated`; the stream's closed report is the last race's.
        @Test func lastRaceUntilNextRaceEnds() async throws {
            let rig = LifecycleRig(settings: LifecycleRig.quickGrace())
            #expect(try await rig.lifecycle.lastRace(of: "T:0") == nil)

            let first = try await rig.race(["T:0"], seed: 1)
            let updates = rig.lifecycle.results(for: "T:0")
            await rig.runUntilEnded(first, limit: 300)
            await rig.end(first)
            let reports = await collect(updates) { if case .report(let report) = $0 { report.isClosed } else { true } }
            guard case .report(let final)? = reports.last else { Issue.record("no closed report: \(reports)"); return }
            #expect(final.isClosed && final.results.rows.count == 4)
            #expect(try await rig.lifecycle.lastRace(of: "T:0")?.report == final)
            let change = await collect(rig.lifecycle.ratingChanges(for: "T:0")) { _ in true }
            #expect(change == [RatingChange(raceID: RaceResultsFeed.raceID(first.id), outcome: .unrated)])

            let second = try await rig.race(["T:0"], seed: 2)
            #expect(try await rig.lifecycle.lastRace(of: "T:0")?.report.raceID == RaceResultsFeed.raceID(first.id))
            await rig.lifecycle.cancel(second.id)
            await rig.end(second)
            #expect(try await rig.lifecycle.lastRace(of: "T:0")?.report.raceID == RaceResultsFeed.raceID(first.id))

            let third = try await rig.race(["T:0"], seed: 3)
            await rig.runUntilEnded(third, limit: 300)
            #expect(try await rig.lifecycle.lastRace(of: "T:0")?.report.raceID == RaceResultsFeed.raceID(first.id))
            await rig.end(third)
            #expect(try await rig.lifecycle.lastRace(of: "T:0")?.report.raceID == RaceResultsFeed.raceID(third.id))
        }
    }
}
