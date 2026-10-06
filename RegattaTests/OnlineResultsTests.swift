import Foundation
import Testing
import RegattaCore
import RegattaProtocol
import RegattaServices
@testable import Regatta

/// The online results (#133, #24): rows from the server's results stream, your rating cell, the earned-design line, and
/// who can be reported. The race is the fake `online-results` scenario's (`FakeServiceScenario.onlineRace`).
@MainActor @Suite struct OnlineResultsTests {
    /// The scenario's reports, unpaced: four boats finishing one by one, then the close.
    private static func reports(rated: Bool = true) -> [RaceReport] {
        FakeServiceScenario.onlineRace(rated: rated, pacing: nil).results.compactMap { update in
            if case .report(let report) = update { report } else { nil }
        }
    }

    private static func entrants(rated: Bool = true) -> [RaceResultViewModel.Entrant] {
        let scenario: FakeServiceScenario = rated ? .onlineResults : .onlineResultsUnrated
        return RaceResultViewModel.onlineSampleEntrants(roster: reports(rated: rated)[0].roster, botSeats: scenario.raceBotSeats)
    }

    private static func model(_ report: RaceReport, rating: RaceResultViewModel.RatingCell = .pending) -> RaceResultViewModel {
        RaceResultViewModel(report: report, entrants: entrants(rated: report.results.rated), rating: rating, earned: nil)
    }

    /// The unrated reasons' words (#24), and the rating cell's: pending, "+12 → 1532" with a true minus for a loss.
    @Test func unratedReasonText() {
        typealias Cell = RaceResultViewModel.RatingCell
        #expect(RaceResultViewModel.UnratedReason.practice.text == "Practice, unrated")
        #expect(RaceResultViewModel.UnratedReason.noOtherHumans.text == "No other humans at the gun, unrated")
        #expect(Cell(.unrated) == .unrated(.noOtherHumans))
        #expect(Cell(.unrated).text == "No other humans at the gun, unrated")
        #expect(Cell.pending.text == "Rating pending")
        let won = Cell(.rated(before: Rating(value: 1520, isProvisional: false), after: Rating(value: 1532, isProvisional: false)))
        #expect(won.text == "+12 → 1532" && !won.isProvisional)
        let lost = Cell(.rated(before: Rating(value: 1500, isProvisional: true), after: Rating(value: 1493, isProvisional: true)))
        #expect(lost.text == "\u{2212}7 → 1493" && lost.isProvisional)
        #expect(Cell.rated(change: 0, after: 1500, isProvisional: false).text == "+0 → 1500")
    }

    /// Report is offered on another human's row only (#26, #24): never a bot's, never yours, never practice.
    @Test func reportUnavailableOnBotRows() throws {
        let online = Self.model(Self.reports()[4])
        for row in online.rows {
            #expect(online.canReport(row) == (!row.isBot && !row.isPlayer), "seat \(row.seat)")
        }
        #expect(online.rows.filter(\.isBot).map(\.seat).sorted() == [3, 4, 5])
        #expect(online.rows.filter { online.canReport($0) }.map(\.seat).sorted() == [1, 2])
        let practice = RaceResultViewModel.gallerySample(final: true)
        #expect(practice.rows.allSatisfy { !practice.canReport($0) }, "practice offers Report")
    }

    /// Boats still racing read "Sailing" with no place, after the boats scored so far, and fill in as they finish; at the
    /// close every boat has its result and the rows are final (#24).
    @Test func onlineRowsFillInLive() {
        let reports = Self.reports()
        let first = Self.model(reports[0])
        #expect(first.rows.map(\.seat) == [3, 0, 1, 2, 4, 5])
        #expect(first.rows.dropFirst().allSatisfy { $0.result == .sailing && $0.place == 0 })
        #expect(!first.isFinal)
        let mid = Self.model(reports[2])
        #expect(mid.rows.map(\.place) == [1, 2, 3, 0, 0, 0])
        #expect(mid.myRow?.result == .gap(ticks: 420) && mid.myRow?.name == "You")
        let closed = Self.model(reports[4])
        #expect(closed.isFinal && closed.rows.map(\.place) == [1, 2, 3, 4, 5, 6])
        #expect(!closed.rows.contains { $0.result == .sailing })
        #expect(closed.online?.raceID == "fake-race")
    }

    /// The Your race card and ⚑ come from the stream's per-player incidents and flagged seats (#133): the call against
    /// you, its turn done, and the call's victim named.
    @Test func onlineCardFromTheStreamsIncidents() throws {
        var report = Self.reports()[4]
        report.incidents[0].markTouches = [MarkTouch(tick: 3000, leg: 1, seat: 0, mark: "windward mark")]
        report.incidents[0].protests = [Protest(tick: 2410, leg: 0, protester: 0, protested: 1, matchedIncidentId: 0)]
        report.flaggedSeats = [0, 4]
        let model = Self.model(report)
        let card = try #require(model.card)
        // One turn served: the rule 10 call's (oldest first); the later touch's turn wasn't done.
        #expect(card.against.map(\.phrase) == ["Rule 10 against you, penalty done", "Touched the windward mark, penalty not done"])
        #expect(card.protests.map(\.phrase) == ["You protested Wren"])
        #expect(model.rows.filter(\.flagged).map(\.seat).sorted() == [0, 4])
    }

    /// The rating stays pending through the close of a rated race until the server pushes this race's change; an
    /// unrated close says why at once; another race's change is ignored (#24).
    @Test func ratingPendingUntilPushed() {
        let results = OnlineResults(service: ScriptedRaceSessionService(RaceSessionScenario()))
        for report in Self.reports() { results.consume(.report(report)) }
        #expect(results.ratingCell == .pending)
        results.consume(RatingChange(raceID: RaceID("other"), outcome: .unrated))
        #expect(results.ratingCell == .pending, "another race's change moved the cell")
        results.consume(RatingChange(raceID: RaceID("fake-race"), outcome: .rated(
            before: Rating(value: 1500, isProvisional: true), after: Rating(value: 1512, isProvisional: true))))
        #expect(results.ratingCell == .rated(change: 12, after: 1512, isProvisional: true))

        let unrated = OnlineResults(service: ScriptedRaceSessionService(RaceSessionScenario()))
        let reports = Self.reports(rated: false)
        unrated.consume(.report(reports[0]))
        #expect(unrated.ratingCell == .pending, "an open report's rated flag isn't final")
        unrated.consume(.report(reports[4]))
        #expect(unrated.ratingCell == .unrated(.noOtherHumans))
    }

    /// Read from the scripted service: the final report and the pushed change, as the sheet shows them.
    @Test func streamsReadToTheRatedClose() async {
        let results = OnlineResults(service: ScriptedRaceSessionService(FakeServiceScenario.onlineRace(rated: true, pacing: nil)))
        await results.run()
        let model = results.model(entrants: Self.entrants(), livery: FleetLiveries.yours)
        #expect(model?.isFinal == true)
        #expect(model?.online?.rating.text == "+12 → 1512")
    }

    /// A close you didn't retire from counts once (G6), however often it's read; a RET or a cancelled race never does.
    @Test func aCountedCloseCountsOnce() throws {
        let name = "OnlineResultsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = CompletedRacesStore(defaults: defaults)
        var told: [RaceID] = []
        let results = OnlineResults(service: ScriptedRaceSessionService(RaceSessionScenario()), completedBefore: 9)
        results.onCompleted = { race in
            told.append(race)
            store.countCompletion(of: race.rawValue)
        }
        let reports = Self.reports()
        for report in reports { results.consume(.report(report)) }
        results.consume(.report(reports[4]))
        #expect(told == [RaceID("fake-race")])
        #expect(store.count == 1)
        #expect(!store.countCompletion(of: "fake-race"), "the same race counted twice")
        #expect(store.count == 1)

        var retired = reports[4]
        retired.results.rows = retired.results.rows.map { row in
            var row = row
            if row.seat == 0 { row.code = .ret; row.finishTick = nil }
            return row
        }
        let ret = OnlineResults(service: ScriptedRaceSessionService(RaceSessionScenario()))
        ret.onCompleted = { _ in Issue.record("a RET counted") }
        ret.consume(.report(retired))

        let cancelled = OnlineResults(service: ScriptedRaceSessionService(RaceSessionScenario()))
        cancelled.onCompleted = { _ in Issue.record("a cancelled race counted") }
        cancelled.consume(.report(reports[0]))
        cancelled.consume(.cancelled(.serverShutdown))
        cancelled.consume(.report(reports[4]))
        #expect(cancelled.isCancelled && cancelled.model(entrants: Self.entrants(), livery: FleetLiveries.yours) == nil)
    }

    /// The earned line appears only when this race reaches an earned design's milestone, and stays hidden while that
    /// design has no art (owner 2026-10-05: until #169 draws it). Never a paid design.
    @Test func earnedLineHiddenWhileTheDesignHasNoArt() throws {
        let livery = FleetLiveries.yours
        let design = try #require(EarnedUnlock.design(completedBefore: 9, resultCode: .finished, catalogue: .bundled,
                                                      boatClass: "skiff"))
        #expect(design.id == DesignID("skiff-earned-10"))
        #expect(!MyBoatModel.hasArt(design), "#169 has drawn it: the line now shows")
        #expect(EarnedUnlock.line(completedBefore: 9, resultCode: .finished, livery: livery, boatClass: "skiff") == nil)

        let drawn = EarnedUnlock.line(completedBefore: 49, resultCode: .dsq, livery: livery, boatClass: "skiff",
                                      isDrawn: { _ in true })
        #expect(drawn?.design == DesignID("skiff-earned-50"))
        #expect(drawn?.livery.design == DesignID("skiff-earned-50") && drawn?.livery.sailNumber == livery.sailNumber)
        #expect(EarnedUnlock.line(completedBefore: 9, resultCode: .ret, livery: livery, boatClass: "skiff",
                                  isDrawn: { _ in true }) == nil, "a RET unlocked a design")
        #expect(EarnedUnlock.line(completedBefore: 10, resultCode: .finished, livery: livery, boatClass: "skiff",
                                  isDrawn: { _ in true }) == nil, "no milestone at 11")
    }

    /// A session with the server's results shows them, with Race again and Home; a cancellation takes the sheet away.
    @Test func sessionShowsTheStreamsResults() {
        let session = GameSession(config: PracticeSetup().config(seed: 1, windSeed: 1))
        #expect(session.resultsButtons == .practice)
        let results = OnlineResults(service: ScriptedRaceSessionService(RaceSessionScenario()))
        session.onlineResults = results
        #expect(session.resultsButtons == .online)
        session.consume([RaceEvent(tick: 100, kind: .raceClosed(results: .empty))])
        #expect(session.showsResults && session.results?.online == nil, "the live frame before the first report")
        results.consume(.report(Self.reports()[2]))
        #expect(session.results?.online?.rating == .pending)
        #expect(session.results?.rows.count == 6)
        results.consume(.cancelled(.serverShutdown))
        #expect(!session.showsResults && session.results == nil)
    }

    /// The online render fixtures are results galleries at their stages.
    @Test func theOnlineResultsFixturesAreGalleries() throws {
        #expect(try RenderFixture.gallery(named: "results-online-live", in: RenderFixtureTests.fixtures) == .results(.onlineLive))
        #expect(try RenderFixture.gallery(named: "results-online-rated", in: RenderFixtureTests.fixtures) == .results(.onlineRated))
        #expect(try RenderFixture.gallery(named: "results-online-unrated", in: RenderFixtureTests.fixtures) == .results(.onlineUnrated))
        #expect(RaceResultViewModel.onlineSample(.onlineLive).myRow?.place == 3)
        #expect(RaceResultViewModel.onlineSample(.onlineUnrated).online?.rating == .unrated(.noOtherHumans))
    }

    /// An online Last race round-trips through its store, and one kept before the online payload still loads.
    @Test func onlineResultsRoundTripTheLastRaceStore() throws {
        var model = Self.model(Self.reports()[4], rating: .rated(change: 12, after: 1512, isProvisional: true))
        model.online?.earned = RaceResultViewModel.EarnedLine(design: DesignID("skiff-earned-10"), name: "Chevron bow",
                                                              livery: FleetLiveries.yours)
        let data = try JSONEncoder().encode(model)
        #expect(try JSONDecoder().decode(RaceResultViewModel.self, from: data) == model)
    }
}
