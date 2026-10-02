import Foundation
import Testing
import RegattaBots
import RegattaCore
@testable import Regatta

/// The results sheet's model (#132, #24, #30): rows from the core's results or the live frame, gaps, ⚑, the Your race
/// card from fixture `IncidentIndex` values, the sheet's 3 s delay, the buttons, and home's Last race.
@MainActor @Suite struct RaceResultViewModelTests {
    private static let livery = FleetLiveries.yours

    /// Eight seats: you in seat 0, bots in 1-7.
    private static let entrants: [RaceResultViewModel.Entrant] = (0..<8).map { seat in
        RaceResultViewModel.Entrant(name: seat == 0 ? "You" : "Bot \(seat)", isBot: seat != 0, livery: livery)
    }

    private static func call(_ index: inout IncidentIndex, _ rule: RacingRule, offender: Int, victim: Int, tick: Int,
                             leg: Int, turns: Int = 1) {
        var incident = index.open(between: offender, and: victim, tick: tick, leg: leg)
        incident.outcome = .called(RuleCall(incidentId: incident.id, tick: tick, rule: rule, offender: offender,
                                            victim: victim, leg: leg, turnsOwed: turns, startDeadlineTick: nil,
                                            completeDeadlineTick: nil))
        index.update(incident)
    }

    /// Finishers by finish, then by distance, DSQ, OCS, RET (#30), whatever order the rows come in; shared places
    /// kept; each code in the result column.
    @Test func ordersFinishersByDistanceDSQOCSRET() {
        let results = RaceResults(rows: [
            SeatResult(seat: 6, place: 7, code: .ret),
            SeatResult(seat: 4, place: 5, code: .dsq),
            SeatResult(seat: 2, place: 2, code: .finished, finishTick: 9_030),
            SeatResult(seat: 5, place: 6, code: .ocs),
            SeatResult(seat: 3, place: 4, code: .byDistance),
            SeatResult(seat: 1, place: 1, code: .finished, finishTick: 9_000),
            SeatResult(seat: 0, place: 3, code: .byDistance),
            SeatResult(seat: 7, place: 5, code: .dsq),
        ], rated: false)
        let model = RaceResultViewModel(results: results, live: [], entrants: Self.entrants, mySeat: 0, incidents: nil)
        #expect(model.isFinal)
        #expect(model.rows.map(\.seat) == [1, 2, 0, 3, 4, 7, 5, 6])
        #expect(model.rows.map(\.place) == [1, 2, 3, 4, 5, 5, 6, 7])
        #expect(model.rows.map(\.result.text) == ["5:00", "+0:01", "By distance", "By distance", "DSQ", "DSQ", "OCS", "RET"])
        #expect(model.myRow?.seat == 0 && model.rows.filter(\.isPlayer).count == 1)
        #expect(model.rows[1].isBot && !model.rows[2].isBot)
        #expect(model.summary == "3 of 8")
        #expect(model.card == nil, "no incident index, no card")
    }

    /// The gap to the winner is "+m:ss", whole seconds rounded up, so no finisher behind the winner reads "+0:00"; the
    /// winner shows her race time (ruling 1).
    @Test func gapFormatting() {
        let rate = Race.tickRate
        #expect(RaceResultViewModel.gapText(ticks: 1) == "+0:01")
        #expect(RaceResultViewModel.gapText(ticks: rate) == "+0:01")
        #expect(RaceResultViewModel.gapText(ticks: rate + 1) == "+0:02")
        #expect(RaceResultViewModel.gapText(ticks: 42 * rate) == "+0:42")
        #expect(RaceResultViewModel.gapText(ticks: 75 * rate) == "+1:15")
        #expect(RaceResultViewModel.gapText(ticks: 600 * rate) == "+10:00")
        #expect(RaceResultViewModel.gapText(ticks: 0) == "+0:00")
        #expect(RaceResultViewModel.Result.raceTime(ticks: 581 * rate).text == "9:41")
        let results = RaceResults(rows: [
            SeatResult(seat: 3, place: 1, code: .finished, finishTick: 581 * rate),
            SeatResult(seat: 0, place: 2, code: .finished, finishTick: 623 * rate),
        ], rated: false)
        let model = RaceResultViewModel(results: results, live: [], entrants: Self.entrants, mySeat: 0, incidents: nil)
        #expect(model.rows.map(\.result) == [.raceTime(ticks: 581 * rate), .gap(ticks: 42 * rate)])
        #expect(model.rows.map(\.result.text) == ["9:41", "+0:42"])
    }

    /// Before the close (no results, or online's empty close) the rows are the live standings: finishers with their
    /// gaps, the rest "Sailing", DSQ, not started; and leaving then keeps a snapshot with the sailing boats by
    /// distance (ruling 4).
    @Test func liveRowsBeforeTheCloseAndTheSnapshotOnLeaving() {
        typealias Live = RaceResultViewModel.LiveStanding
        let live = [
            Live(seat: 2, status: .finished, place: 1, finishTick: 9_000),
            Live(seat: 0, status: .finished, place: 2, finishTick: 9_300),
            Live(seat: 1, status: .racing),
            Live(seat: 3, status: .dsq),
            Live(seat: 4, status: .ocs),
        ]
        for results in [nil, RaceResults.empty] {
            let model = RaceResultViewModel(results: results, live: live, entrants: Self.entrants, mySeat: 0, incidents: nil)
            #expect(!model.isFinal)
            #expect(model.rows.map(\.seat) == [2, 0, 1, 3, 4])
            #expect(model.rows.map(\.place) == [1, 2, 3, 4, 5])
            #expect(model.rows.map(\.result.text) == ["5:00", "+0:10", "Sailing", "DSQ", "Not started"])
            let kept = model.leftBeforeClose()
            #expect(kept.isFinal)
            #expect(kept.rows.map(\.result.text) == ["5:00", "+0:10", "By distance", "DSQ", "By distance"])
        }
    }

    /// ⚑ marks every boat with a rule call against her, not the victim, and not a mark touch alone (ruling 5).
    @Test func flagsEveryBoatWithACallAgainstIt() {
        var index = IncidentIndex()
        Self.call(&index, .portStarboard, offender: 2, victim: 0, tick: 100, leg: 0)
        Self.call(&index, .windwardLeeward, offender: 5, victim: 3, tick: 200, leg: 1)
        index.open(between: 1, and: 4, tick: 300, leg: 1)
        index.recordMarkTouch(MarkTouch(tick: 400, leg: 2, seat: 6, mark: "windward mark"))
        let results = RaceResults(rows: (0..<8).map { SeatResult(seat: $0, place: $0 + 1, code: .byDistance) }, rated: false)
        let model = RaceResultViewModel(results: results, live: [], entrants: Self.entrants, mySeat: 0, incidents: index)
        #expect(Set(model.rows.filter(\.flagged).map(\.seat)) == [2, 5])
    }

    /// The card lists only incidents involving you: calls against you with the rule number and plain words, the other
    /// boat, the leg and the outcome; calls in your favour alike; your mark touches as rule 31; your protests, recorded
    /// and never changing a result. Others' calls and protests aren't listed.
    @Test func yourRaceCardListsCallsAgainstInFavourAndProtests() throws {
        var index = IncidentIndex()
        Self.call(&index, .portStarboard, offender: 0, victim: 2, tick: 1_000, leg: 0)
        Self.call(&index, .windwardLeeward, offender: 4, victim: 0, tick: 2_000, leg: 1)
        Self.call(&index, .clearAstern, offender: 5, victim: 6, tick: 2_500, leg: 1)
        index.recordProtest(Protest(tick: 3_000, leg: 2, protester: 0, protested: 3, matchedIncidentId: nil))
        index.recordProtest(Protest(tick: 3_100, leg: 2, protester: 6, protested: 0, matchedIncidentId: nil))
        index.recordMarkTouch(MarkTouch(tick: 4_000, leg: 3, seat: 0, mark: "windward mark"))
        Self.call(&index, .whileTacking, offender: 0, victim: 1, tick: 5_000, leg: 4)
        let results = RaceResults(rows: [
            SeatResult(seat: 0, place: 1, code: .finished, finishTick: 9_000),
        ] + [1, 2, 3, 5, 6, 7].enumerated().map { SeatResult(seat: $1, place: $0 + 2, code: .byDistance) }
          + [SeatResult(seat: 4, place: 8, code: .dsq)], rated: false)
        // You served two turns: the rule 10 call's and the mark touch's; the rule 13 one is not done at the close.
        let model = RaceResultViewModel(results: results, live: [], entrants: Self.entrants, mySeat: 0, incidents: index,
                                        served: [0: 2])
        let card = try #require(model.card)
        #expect(card.against.map(\.rule) == ["10", "31", "13"])
        #expect(card.against[0].title == "Rule 10: \(RuleWords.plain(.portStarboard))")
        #expect(card.against[0].other == "\(BotGlyph.text) Bot 2")
        #expect(card.against[0].legText == "Leg 1")
        #expect(card.against.map(\.outcome) == [.penaltyDone, .penaltyDone, .notDone])
        #expect(card.against[1].other == nil && card.against[1].title == "Rule 31: touched the windward mark")
        #expect(card.inFavour.count == 1)
        #expect(card.inFavour[0].rule == "11" && card.inFavour[0].other == "\(BotGlyph.text) Bot 4")
        #expect(card.inFavour[0].legText == "Leg 2" && card.inFavour[0].outcome == .dsq)
        #expect(card.protests.map(\.protested) == ["\(BotGlyph.text) Bot 3"])
        #expect(card.protests[0].legText == "Leg 3")
        #expect(YourRaceCard.ProtestEntry.note == "Recorded, doesn't change results")
        #expect(model.rows.first { $0.seat == 0 }?.flagged == true)
    }

    /// While the race runs a turn not yet done is owed; a call that adds no turn (44.1(a)) owes none.
    @Test func yourRaceCardOutcomesWhileRacing() throws {
        var index = IncidentIndex()
        Self.call(&index, .portStarboard, offender: 0, victim: 2, tick: 1_000, leg: 0, turns: 0)
        Self.call(&index, .windwardLeeward, offender: 0, victim: 3, tick: 2_000, leg: 1)
        let live = (0..<8).map { RaceResultViewModel.LiveStanding(seat: $0, status: .racing) }
        let model = RaceResultViewModel(results: nil, live: live, entrants: Self.entrants, mySeat: 0, incidents: index)
        let card = try #require(model.card)
        #expect(card.against.map(\.outcome) == [.noTurn, .owed])
        #expect(model.leftBeforeClose().card?.against.map(\.outcome) == [.noTurn, .notDone])
        let quiet = RaceResultViewModel(results: nil, live: live, entrants: Self.entrants, mySeat: 7,
                                        incidents: IncidentIndex())
        #expect(quiet.card?.isEmpty == true)
    }

    /// Practice results offer Home, Change setup and Sail again; the first race Race online and Help (#24).
    @Test func firstRaceButtons() {
        #expect(GameSession.resultsButtons(isFirstRace: false) == .practice)
        #expect(GameSession.resultsButtons(isFirstRace: true) == .firstRace)
        let session = GameSession(config: PracticeSetup().config(seed: 1, windSeed: 1))
        #expect(session.resultsButtons == .practice)
        session.isFirstRace = true
        #expect(session.resultsButtons == .firstRace)
    }

    /// Your finish horn: the results build at once and slide up `resultsDelay` (3 s) of wall-clock time later, the race
    /// running on behind them.
    @Test func sheetShowsThreeSecondsAfterYourFinish() throws {
        let session = GameSession(config: PracticeSetup().config(seed: 1, windSeed: 1))
        var clock = Date(timeIntervalSinceReferenceDate: 0)
        session.now = { clock }
        let me = session.driver.myBoatIndex
        session.consume([RaceEvent(tick: 100, kind: .finished(seat: me, place: 1))])
        #expect(session.playerDone && session.results != nil && !session.showsResults)
        clock += GameSession.resultsDelay - 0.5
        session.refreshHUD()
        #expect(!session.showsResults)
        clock += 0.5
        session.refreshHUD()
        #expect(session.showsResults)
    }

    /// Your DSQ, or the race closing with you still racing, shows the results at once.
    @Test func sheetShowsAtOnceOnYourDSQOrTheClose() {
        let dsq = GameSession(config: PracticeSetup().config(seed: 1, windSeed: 1))
        dsq.consume([RaceEvent(tick: 100, kind: .disqualified(seat: dsq.driver.myBoatIndex, reason: "penalty"))])
        #expect(dsq.showsResults)
        let closed = GameSession(config: PracticeSetup().config(seed: 1, windSeed: 1))
        closed.consume([RaceEvent(tick: 100, kind: .raceClosed(results: .empty))])
        #expect(closed.showsResults && closed.results?.isFinal == false)
    }

    /// The last race round-trips through its store, as the next launch reads it (ruling 6).
    @Test func lastRaceStoreRoundTrip() throws {
        let name = "RaceResultViewModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = LastRaceStore(defaults: defaults)
        #expect(store.load() == nil)
        for final in [false, true] {
            let sample = RaceResultViewModel.gallerySample(final: final)
            store.save(sample)
            #expect(store.load() == sample)
        }
        let model = AppModel(launchOptions: LaunchOptions(arguments: ["/path/to/Regatta"]), defaults: defaults)
        #expect(model.lastRace == RaceResultViewModel.gallerySample(final: true))
    }

    /// Home's Last race is kept as you leave a race you were done in, and stays when you leave the next one mid-race:
    /// it lasts until the next race ends (#24, #25).
    @Test func lastRaceIsKeptUntilTheNextRaceEnds() throws {
        let model = AppModel(launchOptions: LaunchOptions(arguments: ["/path/to/Regatta", "-uitesting", "-seed", "1"]))
        #expect(model.lastRace == nil)
        model.beginPractice()
        model.finishBriefing()
        let first = try #require(model.session)
        first.playerDone = true
        model.leaveRace()
        let kept = try #require(model.lastRace)
        #expect(kept.isFinal && kept.rows.count == model.practiceSetup.fleetSize)
        #expect(!kept.rows.contains { $0.result == .sailing })

        model.beginPractice()
        model.finishBriefing()
        model.leaveRace()
        #expect(model.lastRace == kept, "a race left mid-race doesn't replace it")

        model.beginPractice()
        model.finishBriefing()
        let session = try #require(model.session)
        let results = RaceResults(rows: (0..<model.practiceSetup.fleetSize).map {
            SeatResult(seat: $0, place: $0 + 1, code: .byDistance)
        }, rated: false)
        session.consume([RaceEvent(tick: 10, kind: .raceClosed(results: results))])
        #expect(model.lastRace != kept && model.lastRace?.isFinal == true, "the next race's close replaces it")
        let replaced = try #require(model.lastRace)
        #expect(replaced.rows.filter { $0.result != .byDistance }.isEmpty)
    }

    /// The results galleries are render fixtures (`ResultsGalleryView`).
    @Test func theResultsFixturesAreGalleries() throws {
        #expect(try RenderFixture.gallery(named: "results-live", in: RenderFixtureTests.fixtures) == .results(.live))
        #expect(try RenderFixture.gallery(named: "results-closed", in: RenderFixtureTests.fixtures) == .results(.closed))
        let closed = RaceResultViewModel.gallerySample(final: true)
        #expect(closed.rows.map(\.result.text).contains("+0:42"))
        let card = try #require(closed.card)
        #expect(!card.against.isEmpty && !card.inFavour.isEmpty && !card.protests.isEmpty)
        let flagged = closed.rows.filter { $0.flagged }
        #expect(!flagged.isEmpty)
    }
}
