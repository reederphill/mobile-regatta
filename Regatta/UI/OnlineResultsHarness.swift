import RegattaCore
import RegattaProtocol
import RegattaServices
import SwiftUI

/// `-onlineResults` with `-fakeServices online-results` (#133): the online results sheet over the race's dark chrome,
/// fed by the scenario's paced results stream, so a UI test sees rows fill in live and the rating go from pending to
/// pushed without sailing a race. The integration with a sailed race (`GameSession` and the stream) is unit-tested in
/// `RegattaTests`; the end-to-end through a real server is #163's.
struct OnlineResultsHarness: View {
    let results: OnlineResults
    let entrants: [RaceResultViewModel.Entrant]
    let livery: Livery
    let raceAgain: () -> Void
    let home: () -> Void
    let tryIt: (DesignID) -> Void

    var body: some View {
        ZStack {
            ChromePalette.background.ignoresSafeArea()
            if let model = results.model(entrants: entrants, livery: livery) {
                ResultsView(model: model, buttons: .online(raceAgain: raceAgain, home: home, tryIt: tryIt))
            }
        }
        .environment(\.colorScheme, .dark)
        .onAppear { results.start() }
    }
}

extension RaceResultViewModel {
    /// The fake online race's entrants (`FakeServiceScenario.onlineRace`): names from its roster, "You" in seat 0,
    /// the scenario's bot seats, and a practice fleet's liveries on fixed seeds.
    static func onlineSampleEntrants(roster: [RosterEntry], botSeats: [Int]) -> [Entrant] {
        // Before the first report there's no roster, and no fleet to dress.
        guard !roster.isEmpty else { return [] }
        let config = RaceConfig(opponents: roster.count - 1, seed: 7, windSeed: RaceConfig.windSeed(pinnedTo: 7))
        let liveries = FleetLiveries(setup: config.setup, mySeat: 0)
        return roster.indices.map { seat in
            Entrant(name: seat == 0 ? "You" : roster[seat].name, isBot: botSeats.contains(seat), livery: liveries[seat])
        }
    }

    /// The fake online race's results at one moment (#133's render fixtures): mid-race with you finished and three
    /// boats sailing, rating pending; closed and rated, the change pushed (provisional); or closed and unrated.
    static func onlineSample(_ stage: RenderFixture.ResultsStage) -> RaceResultViewModel {
        let scenario: FakeServiceScenario = stage == .onlineUnrated ? .onlineResultsUnrated : .onlineResults
        let race = FakeServiceScenario.onlineRace(rated: scenario == .onlineResults, pacing: nil)
        let reports = race.results.compactMap { update -> RaceReport? in
            if case .report(let report) = update { report } else { nil }
        }
        let report = stage == .onlineLive ? reports[2] : reports[reports.count - 1]
        let rating: RatingCell = stage == .onlineLive ? .pending : race.ratingChanges.first.map { RatingCell($0.outcome) } ?? .pending
        let entrants = onlineSampleEntrants(roster: report.roster, botSeats: scenario.raceBotSeats)
        return RaceResultViewModel(report: report, entrants: entrants, rating: rating, earned: nil)
    }
}
