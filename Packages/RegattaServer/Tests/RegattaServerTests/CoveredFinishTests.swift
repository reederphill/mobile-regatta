import Foundation
import Persistence
import RaceHost
import RegattaCore
import RegattaProtocol
@testable import RegattaServerKit
import RegattaServices
import Testing

/// #150 (owner 2026-10-11): what a finish the cautious bot sailed for a dropped player is worth to her. Pure: the
/// results row and the log's seat events, in race ticks.
struct CoveredFinishTests {
    static let finish = 9_000
    static let second = Race.tickRate

    private func row(_ code: ResultCode = .finished, seat: Int = 1, place: Int = 2) -> SeatResult {
        SeatResult(seat: seat, place: place, code: code, finishTick: code == .finished ? Self.finish : nil)
    }

    private func events(_ kinds: (Int, SeatEvent.Kind)..., seat: Int = 1) -> [SeatEvent] {
        [SeatEvent(tick: -1800, seat: seat, kind: .joined(.human))] + kinds.map { SeatEvent(tick: $0.0, seat: seat, kind: $0.1) }
    }

    private func dropped(_ tick: Int) -> [SeatEvent] { events((tick, .disconnected), (tick, .dropped), (tick, .botTookOver(.cautious))) }

    /// The minute, measured from the recorded drop to the finish tick: less than 60 s counts, 60 s doesn't.
    @Test func aDropLessThanAMinuteBeforeTheFinishCountsForTheRating() {
        let f = Self.finish, s = Self.second
        #expect(CoveredFinish.defaultGraceTicks == 60 * s)
        #expect(CoveredFinish.standing(of: row(), events: dropped(f - 59 * s)) == .covered)
        #expect(CoveredFinish.standing(of: row(), events: dropped(f - 60 * s + 1)) == .covered, "one tick inside the minute")
        #expect(CoveredFinish.standing(of: row(), events: dropped(f - 60 * s)) == .coveredTooLate, "the minute itself is too long")
        #expect(CoveredFinish.standing(of: row(), events: dropped(f - 61 * s)) == .coveredTooLate)
        #expect(CoveredFinish.standing(of: row(), events: dropped(f - 1)) == .covered)
        // The minute is a setting.
        #expect(CoveredFinish.standing(of: row(), events: dropped(f - 61 * s), graceTicks: 62 * s) == .covered)
        #expect(CoveredFinish.standing(of: row(), events: dropped(f - 1), graceTicks: 0) == .coveredTooLate)
        #expect(CoveredFinish.standing(of: row(), events: dropped(f - 1), graceTicks: 1) == .coveredTooLate)
        #expect(CoveredFinish.standing(of: row(), events: dropped(f - 1), graceTicks: 2) == .covered)
    }

    /// A finish she sailed herself is hers in full: she never dropped, she dropped after it, or she was back before it.
    @Test func aFinishSheSailedHerselfIsHers() {
        let f = Self.finish
        #expect(CoveredFinish.standing(of: row(), events: events()) == .own)
        // Back before the finish, however long she was away.
        #expect(CoveredFinish.standing(of: row(), events: events((3_000, .dropped), (3_000, .botTookOver(.cautious)), (5_000, .rejoined))) == .own)
        #expect(CoveredFinish.standing(of: row(), events: events((3_000, .dropped), (f - 1, .rejoined))) == .own)
        // A drop recorded at the finish tick came after the step she finished in, on her own inputs.
        #expect(CoveredFinish.standing(of: row(), events: dropped(f)) == .own)
        #expect(CoveredFinish.standing(of: row(), events: dropped(f + 300)) == .own)
        // Her socket closing isn't a drop until the hold runs out.
        #expect(CoveredFinish.standing(of: row(), events: events((f - 10, .disconnected))) == .own)
        // Another seat's drop is not hers.
        #expect(CoveredFinish.standing(of: row(), events: events() + dropped(100).map { SeatEvent(tick: $0.tick, seat: 0, kind: $0.kind) }) == .own)
        // A row that is no finish has nothing to decide: `Race.score` made her RET already if she was gone.
        for code in [ResultCode.byDistance, .dsq, .ocs, .ret] {
            #expect(CoveredFinish.standing(of: row(code), events: dropped(100)) == .own)
        }
    }

    /// Never back, back too late, never there at all, and a leave: the time she went is the start of her last absence.
    @Test func goneSinceIsTheStartOfHerLastAbsenceBeforeTheFinish() {
        let f = Self.finish
        #expect(CoveredFinish.goneSince(seat: 1, finishTick: f, events: dropped(100)) == 100)
        #expect(CoveredFinish.standing(of: row(), events: dropped(100)) == .coveredTooLate, "never back")
        // A rejoin recorded at the finish tick came after the bot's finish.
        #expect(CoveredFinish.goneSince(seat: 1, finishTick: f, events: events((f - 30, .dropped), (f, .rejoined))) == f - 30)
        #expect(CoveredFinish.standing(of: row(), events: events((100, .dropped), (f, .rejoined))) == .coveredTooLate)
        // Away twice: only the last absence counts.
        #expect(CoveredFinish.goneSince(seat: 1, finishTick: f, events: events((100, .dropped), (900, .rejoined), (f - 90, .dropped))) == f - 90)
        // A dropped seat that then leaves went when she dropped.
        #expect(CoveredFinish.goneSince(seat: 1, finishTick: f, events: events((100, .dropped), (f - 10, .left))) == 100)
        // A Leave after the gun: gone from the leave.
        #expect(CoveredFinish.goneSince(seat: 1, finishTick: f, events: events((f - 30, .left), (f - 15, .botTookOver(.cautious)))) == f - 30)
        // A seat nobody ever attached to.
        let never = [SeatEvent(tick: -1770, seat: 1, kind: .dropped), SeatEvent(tick: -1770, seat: 1, kind: .botTookOver(.cautious))]
        #expect(CoveredFinish.standing(of: row(), events: never) == .coveredTooLate)
    }

    private func log(_ seats: [SeatKind], _ events: [SeatEvent], leaveOrder: [Int]? = nil) throws -> RaceLog {
        let setup = try RaceSetup(raceSeed: RaceSeed(150), seats: seats, laps: 1, startSequenceTicks: 1800)
        return RaceLog(header: .init(setup: setup, windSeed: WindSeed(150), tideStateAtGun: nil), seatEvents: events, finalTick: 9_600,
                       allGoneClose: leaveOrder.map { RaceLog.AllGoneClose(tick: 9_600, leaveOrder: $0) })
    }

    /// Per race: only human seats, only covered finishes; and the place a finish that doesn't count is rated at.
    @Test func standingsAndTheRetiredPlace() throws {
        let f = Self.finish
        let gone = { (seat: Int, tick: Int) in SeatEvent(tick: tick, seat: seat, kind: .dropped) }
        let finished = { (seat: Int, place: Int) in SeatResult(seat: seat, place: place, code: .finished, finishTick: f) }
        // Seats 0…3 human, 4 a bot. 0 sailed home; 1's cover got home a minute and more after she went; 2's within it;
        // 3 is gone and unfinished (RET); the bot finished.
        let results = RaceResults(rows: [finished(4, 1), finished(1, 2), finished(2, 3), finished(0, 4), SeatResult(seat: 3, place: 5, code: .ret)],
                                  rated: true)
        let normal = try log([.human, .human, .human, .human, .bot], [gone(1, 100), gone(2, f - 600), gone(3, 4_000), gone(4, 50)])
        #expect(CoveredFinish.standings(results: results, log: normal) == [1: .coveredTooLate, 2: .covered])
        #expect(CoveredFinish.standings(results: results, log: normal, graceTicks: 300) == [1: .coveredTooLate, 2: .coveredTooLate])
        // A normal close ties its RETs behind everyone: she shares their place.
        #expect(CoveredFinish.retiredPlace(of: 1, results: results, log: normal) == 5)
        // Nobody retired: one place behind the last row.
        let all = RaceResults(rows: [finished(4, 1), finished(1, 2), finished(0, 3), SeatResult(seat: 2, place: 4, code: .ocs),
                                     SeatResult(seat: 3, place: 4, code: .ocs)], rated: true)
        #expect(CoveredFinish.retiredPlace(of: 1, results: all, log: normal) == 5)

        // An all-gone close ranks its RETs by leave order, the later leaver ahead (0 went last: place 3, then 3, then 2).
        // Seat 1 went first of all, her boat finished: she draws with the RET who went next after her, the worst placed.
        let allGone = RaceResults(rows: [finished(4, 1), finished(1, 2), SeatResult(seat: 0, place: 3, code: .ret),
                                         SeatResult(seat: 3, place: 4, code: .ret), SeatResult(seat: 2, place: 5, code: .ret)], rated: true)
        #expect(CoveredFinish.retiredPlace(of: 1, results: allGone, log: try log([.human, .human, .human, .human, .bot], [], leaveOrder: [1, 2, 3, 0])) == 5)
        // Gone between 2 and 3: she draws with 3, behind 0, ahead of 2.
        #expect(CoveredFinish.retiredPlace(of: 1, results: allGone, log: try log([.human, .human, .human, .human, .bot], [], leaveOrder: [2, 1, 3, 0])) == 4)
        // The last to go: nobody retired after her, so the best RET's place.
        #expect(CoveredFinish.retiredPlace(of: 1, results: allGone, log: try log([.human, .human, .human, .human, .bot], [], leaveOrder: [2, 3, 0, 1])) == 3)
    }

    @Test func theServerConfigReadsTheGrace() throws {
        var env = ["ENV": "dev", "TERMS_VERSION": "1"]
        #expect(try ServerConfig.load(from: env).lifecycle.coveredFinishGraceTicks == 60 * Race.tickRate)
        #expect(RaceLifecycleSettings().coveredFinishGraceTicks == 1800)
        env["COVERED_FINISH_GRACE_SECONDS"] = "45"
        #expect(try ServerConfig.load(from: env).lifecycle.coveredFinishGraceTicks == 45 * Race.tickRate)
        for bad in ["-1", "3601", "a minute", "1.5"] {
            env["COVERED_FINISH_GRACE_SECONDS"] = bad
            #expect(throws: (any Error).self) { try ServerConfig.load(from: env) }
        }
    }
}

extension RaceSims.RaceResultsFeedTests {
    /// A finish the cautious bot sailed while its player was gone is nobody's win: no "X won" line (#150).
    @Test func noWinnerLineForAFinishSailedWhileGone() {
        let roster = (0..<4).map { RosterEntry(name: "Boat \($0)", colorIndex: $0) }
        let won = RaceSummary(venue: "Bay", roster: roster,
                              results: RaceResults(rows: [SeatResult(seat: 2, place: 1, code: .finished, finishTick: 900),
                                                          SeatResult(seat: 0, place: 2, code: .finished, finishTick: 960)], rated: true),
                              turnsServed: [0, 0, 0, 0])
        #expect(won.winnerLine(sailedWhileGone: []) == .winner(venue: "Bay", nickname: "Boat 2"))
        #expect(won.winnerLine(sailedWhileGone: [2]) == nil)
        // Only the first row's: the second boat's cover is no reason to keep the winner quiet, and the line never
        // passes to the next boat.
        #expect(won.winnerLine(sailedWhileGone: [0]) == .winner(venue: "Bay", nickname: "Boat 2"))
        // A summary never carries the disconnected mark.
        var marked = roster
        marked[2].isDisconnected = true
        #expect(RaceSummary(venue: "Bay", roster: marked, results: won.results, turnsServed: [0, 0, 0, 0]).rosterEntries == roster)
    }
}

extension RaceSims.RaceLifecycleTests {
    /// Two players and no bots, so the covered boat is first home. T:0 holds a straight helm to the close; T:1 drops
    /// just after the gun and the cautious bot sails her boat. `backAt`: she rejoins at that tick and holds a straight
    /// helm too. Run to the race's own close; not handed to the lifecycle yet.
    private static func sailCovered(_ rig: LifecycleRig, seed: UInt64, backAt: Int? = nil) async throws -> RaceSession {
        let race = try await rig.race(["T:0", "T:1"], seats: 2, seed: seed)
        let transports = [KeptTransport(), KeptTransport()]
        for seat in 0..<2 { try await race.join(seat: seat, transport: transports[seat]) }
        var seq: UInt32 = 0, here = [0], tick = 30
        await rig.sail(race, [0, 1], to: tick, seq: &seq)
        await race.leave(seat: 1, transport: transports[1])
        while await !race.host.isEnded, tick < 27_000 {
            if let backAt, here == [0], tick + 60 >= backAt {
                await rig.sail(race, here, to: backAt, seq: &seq)
                try await race.join(seat: 1, transport: KeptTransport())
                here = [0, 1]
                tick = backAt
            } else {
                tick += 60
                await rig.sail(race, here, to: tick, seq: &seq)
            }
        }
        return race
    }

    private static func coverRig(graceTicks: Int? = nil) -> LifecycleRig {
        var settings = RaceLifecycleSettings()
        settings.closeRetryDelay = .milliseconds(1)
        if let graceTicks { settings.coveredFinishGraceTicks = graceTicks }
        return LifecycleRig(settings: settings, now: { Date(timeIntervalSince1970: 1_800_000_000) })
    }

    /// #150, owner 2026-10-11. The cautious bot sails a dropped player's boat home first. Dropped less than the grace
    /// before the finish, the place counts for her rating; the grace or longer, she is rated as retired and loses to
    /// the player still racing. Either way: no completed race, no win, no winner's line; and the results, the log and
    /// the digest are the race's own. Back before the line, the finish is hers in full.
    ///
    /// The race is the first seed of 12 whose covered boat finishes; the grace is set either side of how long she had
    /// been gone at the line, and the rejoin six ticks before it.
    @Test func aFinishSailedWhileGoneIsRatedButNotCompletedOrWon() async throws {
        var probe: (seed: UInt64, finish: Int, dropped: Int, results: RaceResults, digest: UInt64)?
        for seed in UInt64(150)..<162 where probe == nil {
            let race = try await Self.sailCovered(Self.coverRig(), seed: seed)
            guard let outcome = await race.host.outcome, let results = outcome.results, let row = results.row(of: 1), row.code == .finished,
                  let finish = row.finishTick, let dropped = outcome.log.seatEvents.last(where: { $0.seat == 1 && $0.kind == .dropped }) else { continue }
            probe = (seed, finish, dropped.tick, results, outcome.digest)
        }
        let sailed = try #require(probe, "the covered boat finished in none of 12 seeds")
        let gone = sailed.finish - sailed.dropped
        #expect(sailed.results.row(of: 1)?.place == 1 && sailed.results.rated)
        #expect(gone > CoveredFinish.defaultGraceTicks, "she dropped at the gun: a minute and more before the line")
        let other = try #require(sailed.results.row(of: 0))
        #expect(other.place == 2 && other.code != .ret)
        let id = { (race: RaceSession) in RaceResultsFeed.raceID(race.id) }

        // Inside the grace (set one tick past her absence), beyond it (the absence itself), and the default minute.
        for (grace, counts) in [(gone + 1, true), (gone, false), (nil, false)] as [(Int?, Bool)] {
            let rig = Self.coverRig(graceTicks: grace)
            let race = try await Self.sailCovered(rig, seed: sailed.seed)
            await rig.end(race)
            // The race is what it was: same results, same digest, her row a finish in first place.
            let stored = try #require(try await rig.archive.closedRace(race.id))
            #expect(stored.digest == sailed.digest)
            #expect(try Replayer.digest(of: RaceLog(jsonData: stored.log)) == sailed.digest)
            let summary = try RaceSummary(decoding: stored.results)
            #expect(summary.results == sailed.results)
            #expect(summary.rosterEntries.allSatisfy { !$0.isDisconnected })
            // Her rating: the place sailed, or a retirement's (behind the last row: nobody else retired).
            let changes = rig.archive.ratings.changes(of: race.id)
            let hers = try #require(changes.first { $0.playerID == "T:1" }), theirs = try #require(changes.first { $0.playerID == "T:0" })
            #expect(hers.place == (counts ? 1 : 3) && theirs.place == 2, "grace \(grace.map(String.init) ?? "default")")
            #expect(hers.after.displayed == (counts ? 1662 : 1338) && theirs.after.displayed == (counts ? 1338 : 1662))
            // Never a completed race or a win of hers; the player who stayed has her race.
            let standing = try #require(try await rig.archive.ratings.standing(of: "T:1"))
            #expect(standing.completedRaces == 0 && standing.wins == 0)
            let stayed = try #require(try await rig.archive.ratings.standing(of: "T:0"))
            #expect(stayed.completedRaces == (RaceLifecycleSettings().earnedProgressResultCodes.contains(other.code) ? 1 : 0) && stayed.wins == 0)
            // And nobody "won".
            #expect(rig.lobby.lines.isEmpty)
            #expect(try await rig.lifecycle.lastRace(of: "T:1")?.report.results == sailed.results)
            _ = id
        }

        // Back six ticks before the bot would have finished, she sails the boat over the line herself: hers in full.
        let rig = Self.coverRig()
        let race = try await Self.sailCovered(rig, seed: sailed.seed, backAt: sailed.finish - 6)
        let outcome = try #require(await race.host.outcome)
        let row = try #require(outcome.results?.row(of: 1))
        try #require(row.code == .finished && row.place == 1, "she didn't carry her way over the line")
        #expect(try #require(row.finishTick) > sailed.finish - 6)
        #expect(CoveredFinish.standings(results: try #require(outcome.results), log: outcome.log).isEmpty)
        await rig.end(race)
        let changes = rig.archive.ratings.changes(of: race.id)
        #expect(changes.first { $0.playerID == "T:1" }?.place == 1)
        #expect(changes.first { $0.playerID == "T:1" }?.after.displayed == 1662)
        #expect(try await rig.archive.ratings.standing(of: "T:1").map { [$0.completedRaces, $0.wins] } == [1, 1])
        #expect(rig.lobby.lines == [.winner(venue: "Test Bay", nickname: "NT:1")])
    }
}
