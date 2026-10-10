import Foundation
import RaceHost
import RegattaCore
import RegattaProtocol
@testable import RegattaServerKit
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

            // Through the lifecycle: one line when a race closes after the gun, none when one is cancelled.
            let rig = LifecycleRig(settings: LifecycleRig.quickGrace())
            let lines = await rig.lifecycle.systemLines()
            let cancelled = try await rig.race(["T:0"])
            await rig.lifecycle.cancel(cancelled.id)
            await rig.end(cancelled)
            let closed = try await rig.race(["T:0"])
            let transport = KeptTransport()
            try await closed.join(seat: 0, transport: transport)
            var seq: UInt32 = 0
            await rig.sail(closed, [0], to: 900, seq: &seq)
            await closed.leave(seat: 0, transport: transport)
            await rig.runUntilEnded(closed, limit: 1_200)
            await rig.end(closed)
            // The cancelled race said nothing: the first line is the closed race's.
            let read = await collect(lines, seconds: 30) { _ in true }
            #expect(read.count == 1)
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
