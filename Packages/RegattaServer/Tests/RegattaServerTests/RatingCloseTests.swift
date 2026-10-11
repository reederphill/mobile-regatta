import Foundation
import Persistence
import Ratings
import RaceHost
import RegattaCore
import RegattaProtocol
@testable import RegattaServerKit
import RegattaServiceClient
import RegattaServices
import Testing

/// What a player's rating stream holds now: read for a moment, so "nothing" is a short wait.
private func pushed(_ lifecycle: RaceLifecycle, _ player: String, expecting count: Int = 1) async -> [RatingChange] {
    let seen = Kept<RatingChange>()
    return await collect(lifecycle.ratingChanges(for: player), seconds: count == 0 ? 0.2 : 5) { change in
        seen.append(change)
        return seen.all.count >= count
    }
}

private func rating(_ value: Int, provisional: Bool = true) -> Rating { Rating(value: value, isProvisional: provisional) }

extension RaceSims {
    /// #151: which races are rated, who in them, and what the close writes. Races are sailed by hand to an all-gone
    /// close (`ret`: RET in reverse leave order), so the humans' places are the order they left in.
    @Suite(.timeLimit(.minutes(2))) struct RatingCloseTests {
        static let closeTime = Date(timeIntervalSince1970: 1_800_000_000)

        static func rig(_ edit: (inout RaceLifecycleSettings) -> Void = { _ in }) -> LifecycleRig {
            var settings = LifecycleRig.quickGrace(.ret)
            settings.closeRetryDelay = .milliseconds(1)
            edit(&settings)
            return LifecycleRig(settings: settings, now: { closeTime })
        }

        /// `players` in seats 0…, all at the gun; then each seat of `leaving` leaves, 3 s apart, first to last, and the
        /// race runs to its all-gone close. Not handed to the lifecycle yet.
        static func sail(_ rig: LifecycleRig, _ players: [String], seats: Int = 4, leaving: [Int],
                         afterGun: (RaceSession, [KeptTransport]) async throws -> Void = { _, _ in }) async throws -> RaceSession {
            let race = try await rig.race(players, seats: seats)
            let transports = players.map { _ in KeptTransport() }
            for seat in players.indices { try await race.join(seat: seat, transport: transports[seat]) }
            var seq: UInt32 = 0, here = Array(players.indices), tick = 30
            await rig.sail(race, here, to: tick, seq: &seq)
            try await afterGun(race, transports)
            for seat in leaving {
                await race.leave(seat: seat, transport: transports[seat])
                here.removeAll { $0 == seat }
                tick += 90
                if !here.isEmpty { await rig.sail(race, here, to: tick, seq: &seq) }
            }
            await rig.runUntilEnded(race, limit: tick + 1_200)
            #expect(await race.host.outcome?.results != nil, "the race didn't close")
            return race
        }

        /// Two humans and two bots: the bots are placed ahead of both, and move nobody. It is a duel between the humans
        /// (one opponent each): the one who left later wins it, 1500 to 1662 and 1338, as two new players' duel does.
        @Test func botsNeverMoveRatings() async throws {
            let rig = Self.rig()
            let race = try await Self.sail(rig, ["T:0", "T:1"], leaving: [1, 0])
            let results = try #require(await race.host.outcome?.results)
            #expect(results.rated)
            #expect(results.rows.prefix(2).map(\.seat).sorted() == [2, 3], "the bots, still racing, are placed ahead")
            #expect(results.rows.suffix(2).map(\.seat) == [0, 1] && results.rows.suffix(2).map(\.place) == [3, 4])
            await rig.end(race)

            let book = rig.archive.ratings
            let changes = book.changes(of: race.id)
            #expect(changes.map(\.playerID) == ["T:0", "T:1"] && changes.map(\.opponents) == [1, 1] && changes.map(\.place) == [3, 4])
            #expect(changes.allSatisfy { $0.before == PlayerRating() && $0.after.lastRatedAt == Self.closeTime && $0.after.ratedRaces == 1 })
            #expect(abs(changes[0].after.glicko.rating - 1662.21) < 0.05 && abs(changes[1].after.glicko.rating - 1337.79) < 0.05)
            #expect(try await book.ratings(of: ["T:0", "T:1"]).mapValues(\.displayed) == ["T:0": 1662, "T:1": 1338])
            // The stored record names the humans alone.
            let record = try #require(try await rig.archive.closedRace(race.id))
            #expect(record.rating?.participants == [.init(playerID: "T:0", place: 3), .init(playerID: "T:1", place: 4)])
            #expect(record.rating?.ratedAt == Self.closeTime && record.bots.map(\.seat) == [2, 3])
            // Retired: not a completed race, not a win.
            #expect(record.stats == [PlayerRaceStat(playerID: "T:0", completed: false, won: false),
                                     PlayerRaceStat(playerID: "T:1", completed: false, won: false)])

            let id = RaceResultsFeed.raceID(race.id)
            #expect(await pushed(rig.lifecycle, "T:0") == [RatingChange(raceID: id, outcome: .rated(before: rating(1500), after: rating(1662)))])
            #expect(await pushed(rig.lifecycle, "T:1") == [RatingChange(raceID: id, outcome: .rated(before: rating(1500), after: rating(1338)))])
            #expect(try await rig.lifecycle.lastRace(of: "T:1")?.rating
                == RatingChange(raceID: id, outcome: .rated(before: rating(1500), after: rating(1338))))
            #expect(rig.ratedPlayers.all == [["T:0", "T:1"]], "the leaderboard mirror hears who was rated, once")
        }

        /// One human and bots: unrated. `.unrated` is pushed, no rating and no history is written; the profile counts are.
        @Test func unratedRaceWritesNoRatingHistory() async throws {
            let rig = Self.rig()
            let race = try await Self.sail(rig, ["T:0"], leaving: [0])
            #expect(try #require(await race.host.outcome?.results).rated == false)
            await rig.end(race)
            let book = rig.archive.ratings, id = RaceResultsFeed.raceID(race.id)
            #expect(book.changes(of: race.id).isEmpty)
            #expect(try await book.ratings(of: ["T:0"]).isEmpty)
            let record = try #require(try await rig.archive.closedRace(race.id))
            #expect(record.rating == nil && record.stats.map(\.playerID) == ["T:0"])
            #expect(await pushed(rig.lifecycle, "T:0") == [RatingChange(raceID: id, outcome: .unrated)])
            #expect(try await rig.lifecycle.lastRace(of: "T:0")?.rating == RatingChange(raceID: id, outcome: .unrated))
            #expect(rig.ratedPlayers.all.isEmpty)
            #expect(try await book.standing(of: "T:0") == PlayerStanding())
        }

        /// A mass drop under `cancel`: no results, no ratings, no counts, no push.
        @Test func cancelledRaceWritesNothing() async throws {
            var settings = RaceLifecycleSettings()
            settings.allGone.simultaneousLossPolicy = .cancel
            let rig = LifecycleRig(settings: settings)
            let race = try await rig.race(["T:0", "T:1"])
            let transports = [KeptTransport(), KeptTransport()]
            for seat in 0..<2 { try await race.join(seat: seat, transport: transports[seat]) }
            var seq: UInt32 = 0
            await rig.sail(race, [0, 1], to: 30, seq: &seq)
            for seat in 0..<2 { await race.leave(seat: seat, transport: transports[seat]) }
            await rig.runUntilEnded(race, limit: 1_200)
            #expect(await race.host.cancelled != nil)
            await rig.end(race)
            #expect(try await rig.archive.state(of: race.id) == .cancelled)
            let book = rig.archive.ratings
            #expect(try await book.ratings(of: ["T:0", "T:1"]).isEmpty && book.changes(of: race.id).isEmpty)
            #expect(try await book.standing(of: "T:0") == PlayerStanding())
            #expect(await pushed(rig.lifecycle, "T:0", expecting: 0).isEmpty)
            #expect(try await rig.lifecycle.lastRace(of: "T:0") == nil)
            #expect(rig.ratedPlayers.all.isEmpty)
        }

        /// Four humans: one gives her seat away before the gun (a bot sails it), one isn't back until after the gun.
        /// The race is rated for the two at the gun alone. The late rejoiner sails, keeps her result and her counts,
        /// and is told `.unrated`; the one who gave her seat away has nothing of this race.
        @Test func leftBeforeGunAndLateRejoinerTakeNoChange() async throws {
            let rig = Self.rig()
            let race = try await rig.race(["T:0", "T:1", "T:2", "T:3"], seats: 5)
            let transports = (0..<4).map { _ in KeptTransport() }
            for seat in 0..<3 { try await race.join(seat: seat, transport: transports[seat]) }
            var seq: UInt32 = 0
            await rig.sail(race, [0, 1, 2], to: -30, seq: &seq)
            #expect(await race.quit(seat: 2, transport: transports[2]))
            await rig.lifecycle.seatReleased("T:2", race: race.id)
            await rig.sail(race, [0, 1], to: 20, seq: &seq)
            try await race.join(seat: 3, transport: transports[3])
            await rig.sail(race, [0, 1, 3], to: 60, seq: &seq)
            for (index, seat) in [3, 1, 0].enumerated() {
                await race.leave(seat: seat, transport: transports[seat])
                let here = Array([3, 1, 0].dropFirst(index + 1))
                if !here.isEmpty { await rig.sail(race, here, to: 150 + index * 90, seq: &seq) }
            }
            await rig.runUntilEnded(race, limit: 1_800)
            let outcome = try #require(await race.host.outcome)
            #expect(outcome.log.humanSeatsAtGun == [0, 1])
            #expect(try #require(outcome.results).rated)
            await rig.end(race)

            let record = try #require(try await rig.archive.closedRace(race.id))
            #expect(record.rating?.participants.map(\.playerID) == ["T:0", "T:1"])
            #expect(record.stats.map(\.playerID) == ["T:0", "T:1", "T:3"], "a seat given away isn't hers to count")
            #expect(record.bots.contains { $0.seat == 2 && $0.source == .takeover })
            let book = rig.archive.ratings, id = RaceResultsFeed.raceID(race.id)
            #expect(book.changes(of: race.id).map(\.playerID) == ["T:0", "T:1"] && book.changes(of: race.id).map(\.opponents) == [1, 1])
            #expect(try await book.ratings(of: ["T:2", "T:3"]).isEmpty)
            #expect(await pushed(rig.lifecycle, "T:3") == [RatingChange(raceID: id, outcome: .unrated)])
            #expect(await pushed(rig.lifecycle, "T:2", expecting: 0).isEmpty)
            #expect(try await rig.lifecycle.lastRace(of: "T:3")?.rating == RatingChange(raceID: id, outcome: .unrated))
            #expect(try await rig.lifecycle.lastRace(of: "T:2") == nil)
            guard case .rated(_, let after)? = await pushed(rig.lifecycle, "T:0").first?.outcome else { Issue.record("T:0 wasn't rated"); return }
            #expect(after.value == 1662)
        }

        /// Decision (#151): a player who leaves for good after the gun was at the gun, so she is rated, as retired:
        /// she loses to everyone still racing. The queue has released her and the race's results no longer reach her,
        /// but her rating change does: it names its race.
        @Test func aPostGunLeaverIsRatedAsRetiredAndToldAfterShesReleased() async throws {
            let rig = Self.rig()
            let race = try await Self.sail(rig, ["T:0", "T:1"], leaving: [0]) { race, transports in
                #expect(await race.quit(seat: 1, transport: transports[1]))
                await rig.lifecycle.seatReleased("T:1", race: race.id)
            }
            #expect(await rig.lifecycle.seat(of: "T:1") == nil)
            await rig.end(race)
            let id = RaceResultsFeed.raceID(race.id)
            #expect(rig.archive.ratings.changes(of: race.id).map(\.place) == [3, 4], "the leaver is last")
            #expect(await collect(rig.lifecycle.results(for: "T:1"), seconds: 0.2) { _ in true }.isEmpty, "no last word of a race she left")
            #expect(await pushed(rig.lifecycle, "T:1") == [RatingChange(raceID: id, outcome: .rated(before: rating(1500), after: rating(1338)))])
            #expect(await pushed(rig.lifecycle, "T:0") == [RatingChange(raceID: id, outcome: .rated(before: rating(1500), after: rating(1662)))])
            #expect(try await rig.lifecycle.lastRace(of: "T:1")?.rating?.outcome == .rated(before: rating(1500), after: rating(1338)))
        }

        /// A participant whose account went during the race (#160): with fewer than 2 left the race is skipped.
        @Test func deletedParticipantIsSkipped() async throws {
            let rig = Self.rig()
            let race = try await Self.sail(rig, ["T:0", "T:1"], leaving: [1, 0])
            rig.archive.ratings.delete("T:1")
            await rig.end(race)
            let book = rig.archive.ratings, id = RaceResultsFeed.raceID(race.id)
            #expect(try await rig.archive.state(of: race.id) == .closed)
            #expect(book.changes(of: race.id).isEmpty)
            #expect(try await book.ratings(of: ["T:0", "T:1"]).isEmpty)
            #expect(await pushed(rig.lifecycle, "T:0") == [RatingChange(raceID: id, outcome: .unrated)])
            #expect(try await rig.lifecycle.lastRace(of: "T:0")?.rating == RatingChange(raceID: id, outcome: .unrated))
            #expect(rig.ratedPlayers.all.isEmpty)
        }

        /// The in-memory archive counts as the Postgres close does (`RatingStoreTests.statsCountCompletedCodesAndWins`):
        /// every closed race, rated or not; a second close of a race is refused and counts nothing.
        @Test func statsCountCompletedCodesAndWins() async throws {
            let archive = InMemoryRaceArchive()
            func close(_ stats: [PlayerRaceStat], rating: RatingInput? = nil) async throws -> Persistence.RatingOutcome {
                let id = UUID()
                try await archive.register(id, players: stats.enumerated().map { RaceSeatHolder(playerID: $1.playerID, seat: $0) })
                let record = ClosedRaceRecord(id: id, log: Data(), digest: 1, simulationVersion: "s", toolchain: "t", results: Data(),
                                              incidents: Data(), rated: rating != nil, rating: rating, stats: stats)
                let outcome = try await archive.close(record)
                await #expect(throws: (any Error).self) { try await archive.close(record) }
                return outcome
            }
            #expect(try await close([PlayerRaceStat(playerID: "T:a", completed: true, won: true)]) == .none)
            #expect(try await close([PlayerRaceStat(playerID: "T:a", completed: false, won: false)]) == .none)
            let rated = try await close(
                [PlayerRaceStat(playerID: "T:a", completed: true, won: false), PlayerRaceStat(playerID: "T:b", completed: true, won: true)],
                rating: RatingInput(participants: [.init(playerID: "T:a", place: 2), .init(playerID: "T:b", place: 1)], ratedAt: Self.closeTime))
            #expect(rated.state == .applied && rated.changes.count == 2)
            let a = try #require(try await archive.ratings.standing(of: "T:a"))
            #expect(a.completedRaces == 2 && a.wins == 1 && a.rating?.displayed == 1338)
            #expect(try await archive.ratings.standing(of: "T:b") == PlayerStanding(rating: rated.changes[1].after, completedRaces: 1, wins: 1))
        }
    }

    /// #151: the rating change reaches the player, and never says something false.
    @Suite(.timeLimit(.minutes(2))) struct RatingPushTests {
        /// Over `/service`: two players queue and race; one leaves after the gun and queues for her next race; the race
        /// she left closes while she waits in the queue, and its rating change arrives on her rating stream.
        @Test func ratedCloseReachesAClientQueuedForTheNextRace() async throws {
            let queue = BriefingLeaveCooldownTests.QueueRig()
            let lifecycle = queue.rig.lifecycle, matchmaker = queue.matchmaker
            let endpoint = ServiceEndpoint(
                config: ServiceEndpointConfig(termsVersion: 1),
                sessions: SessionAuthority(store: InMemoryAccountStore(), verifier: StubVerifier()),
                backends: ServiceBackends(queue: { ServerQueueService(matchmaker: matchmaker, player: $0, lifecycle: lifecycle) },
                                          raceSession: { ServerRaceSessionService(matchmaker: matchmaker, player: $0, lifecycle: lifecycle) }),
                matchmaker: matchmaker, lifecycle: lifecycle)
            var connections: [ServiceConnection] = []
            for name in ["0", "1"] {
                let (_, connection, _) = try await ServiceFixtures.signedIn(endpoint, name)
                _ = try await RemoteTermsService(connection).accept(TermsVersion(1))
                try await RemoteQueueService(connection).join()
                connections.append(connection)
            }
            queue.clock.advance(60)
            await matchmaker.step()
            let race = try #require(await queue.rig.started.sessions.first)
            let transports = [KeptTransport(), KeptTransport()]
            for seat in 0..<2 { try await race.join(seat: seat, transport: transports[seat]) }
            var seq: UInt32 = 0
            await queue.rig.sail(race, [0, 1], to: 30, seq: &seq)

            // She leaves for good after the gun: free at once, and queues for her next race.
            #expect(await race.quit(seat: 1, transport: transports[1]))
            #expect(await eventually { await matchmaker.state(of: "T:1") == .idle })
            let changes = RemoteRaceSessionService(connections[1]).ratingChanges()
            try await RemoteQueueService(connections[1]).join()
            guard case .queued = await matchmaker.state(of: "T:1") else { Issue.record("she isn't queued"); return }

            // The race she left sails on and closes.
            await queue.rig.sail(race, [0], to: 120, seq: &seq)
            await race.leave(seat: 0, transport: transports[0])
            await queue.rig.runUntilEnded(race, limit: 2_400)
            #expect(try #require(await race.host.outcome?.results).rated)
            await queue.rig.started.end(race)

            let id = RaceResultsFeed.raceID(race.id)
            #expect(await collect(changes, seconds: 10) { _ in true }
                == [RatingChange(raceID: id, outcome: .rated(before: rating(1500), after: rating(1338)))])
            guard case .queued = await matchmaker.state(of: "T:1") else { Issue.record("she left the queue"); return }
            // The winner hears hers on a stream opened after the close, and the last race carries it.
            let winner = RemoteRaceSessionService(connections[0])
            #expect(await collect(winner.ratingChanges(), seconds: 10) { _ in true }
                == [RatingChange(raceID: id, outcome: .rated(before: rating(1500), after: rating(1662)))])
            #expect(try await winner.lastRace()?.rating == RatingChange(raceID: id, outcome: .rated(before: rating(1500), after: rating(1662))))
            await matchmaker.stop()
        }

        /// The pushes a player hasn't read are in memory only. After a restart (a new lifecycle over the same store)
        /// nothing is pending, and the last race still carries the change, read from the store.
        @Test func lastRaceCarriesTheRatingAfterRestart() async throws {
            let rig = RatingCloseTests.rig()
            let race = try await RatingCloseTests.sail(rig, ["T:0", "T:1"], leaving: [1, 0])
            await rig.end(race)
            let restarted = RaceLifecycle(archive: rig.archive, tokenKey: LifecycleRig.key, tokenLifetime: 600, toolchain: "test",
                                          start: { _, _ in })
            #expect(await pushed(restarted, "T:0", expecting: 0).isEmpty)
            let last = try #require(try await restarted.lastRace(of: "T:0"))
            #expect(last.rating == RatingChange(raceID: RaceResultsFeed.raceID(race.id), outcome: .rated(before: rating(1500), after: rating(1662))))
            #expect(last.report.isClosed && last.report.results.rated)
        }

        /// The rating step fails: the race still closes (results, last race), the failure is logged, and nobody is
        /// told anything about ratings: no `.rated`, and no false `.unrated`. The same when the store never takes the
        /// close: the race is cancelled, with no rating and no push.
        @Test func closeFailurePushesNoRating() async throws {
            let broken = RatingCloseTests.rig { $0.rating.tau = .nan }
            let race = try await RatingCloseTests.sail(broken, ["T:0", "T:1"], leaving: [1, 0])
            let updates = broken.lifecycle.results(for: "T:0")
            await broken.end(race)
            #expect(try await broken.archive.state(of: race.id) == .closed)
            guard case .report(let report)? = await collect(updates, until: { if case .report(let report) = $0 { report.isClosed } else { true } }).last else {
                Issue.record("no closed report")
                return
            }
            #expect(report.isClosed)
            #expect(await broken.lifecycle.archiveFailures.contains { $0.hasPrefix("rating \(race.id)") })
            #expect(try await broken.archive.ratings.ratings(of: ["T:0", "T:1"]).isEmpty)
            for player in ["T:0", "T:1"] { #expect(await pushed(broken.lifecycle, player, expecting: 0).isEmpty) }
            let last = try #require(try await broken.lifecycle.lastRace(of: "T:0"))
            #expect(last.rating == nil && last.report.isClosed)
            #expect(broken.ratedPlayers.all.isEmpty)

            let refused = RatingCloseTests.rig()
            let lost = try await RatingCloseTests.sail(refused, ["T:0", "T:1"], leaving: [1, 0])
            refused.faults.failCloses(3)
            await refused.end(lost)
            #expect(try await refused.archive.state(of: lost.id) == .cancelled)
            #expect(try await refused.archive.ratings.ratings(of: ["T:0", "T:1"]).isEmpty)
            for player in ["T:0", "T:1"] { #expect(await pushed(refused.lifecycle, player, expecting: 0).isEmpty) }
            #expect(try await refused.lifecycle.lastRace(of: "T:0") == nil)

            // A close that failed twice and then went through is rated once.
            let retried = RatingCloseTests.rig()
            let third = try await RatingCloseTests.sail(retried, ["T:0", "T:1"], leaving: [1, 0])
            retried.faults.failCloses(2)
            await retried.end(third)
            #expect(retried.archive.ratings.changes(of: third.id).count == 2)
            #expect(try await retried.archive.ratings.ratings(of: ["T:0"])["T:0"]?.ratedRaces == 1)
            #expect(await pushed(retried.lifecycle, "T:0").count == 1)
        }
    }
}
