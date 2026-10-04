import RegattaCore
import SwiftUI

/// The results sheet as a render fixture (#62, #132): `{ "gallery": "results", "results": "live" }` shows a sample
/// race's results while boats still sail, `"closed"` the same race's at its close, both with the Your race card, over
/// the race's dark chrome. Like the race fixture (`RaceView`), it's one `render-fixture` element whose value is the
/// bottom safe-area inset in points. A `"rivalSkill"` gives the sample race practice rivals (#235): "Rival" on
/// their rows.
struct ResultsGalleryView: View {
    let stage: RenderFixture.ResultsStage
    var rivalSkill: Double? = nil

    var body: some View {
        GeometryReader { proxy in
            ResultsView(model: RaceResultViewModel.gallerySample(final: stage == .closed, rivalSkill: rivalSkill),
                        buttons: .practice(home: {}, changeSetup: {}, sailAgain: {}))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ChromePalette.background.ignoresSafeArea())
                .environment(\.colorScheme, .dark)
                .accessibilityElement()
                .accessibilityLabel("Render fixture")
                .accessibilityValue(String(Double(proxy.safeAreaInsets.bottom)))
                .accessibilityIdentifier("render-fixture")
        }
        .persistentSystemOverlays(.hidden)
    }
}

extension RaceResultViewModel {
    /// A sample eight-boat practice race, you in seat 0, on fixed seeds (#132): three finishers (you second, +0:42),
    /// boats still sailing (by distance at the close), a DSQ and an OCS. Its incidents: a rule 10 call against you
    /// (penalty done), a rule 11 call in your favour (the other boat DSQ, so ⚑), a rule 31 mark touch of yours (done)
    /// and your protest. `final` is the race at its close, else a moment before it. `rivalSkill` gives it practice
    /// rivals (#235).
    static func gallerySample(final: Bool, rivalSkill: Double? = nil) -> RaceResultViewModel {
        var config = RaceConfig(opponents: 7, seed: 7, windSeed: RaceConfig.windSeed(pinnedTo: 7))
        config.rivalSkill = rivalSkill
        let setup = config.setup
        let roster = config.roster
        let liveries = FleetLiveries(setup: setup, mySeat: 0)
        let entrants = setup.seats.indices.map { seat in
            Entrant(name: roster.name(of: seat, playerSeat: 0), isBot: roster[seat].isBot, livery: liveries[seat],
                    isRival: roster[seat].isRival)
        }
        let winner = 18_000
        let results = RaceResults(rows: [
            SeatResult(seat: 3, place: 1, code: .finished, finishTick: winner),
            SeatResult(seat: 0, place: 2, code: .finished, finishTick: winner + 42 * Race.tickRate),
            SeatResult(seat: 5, place: 3, code: .finished, finishTick: winner + 75 * Race.tickRate),
            SeatResult(seat: 2, place: 4, code: .byDistance),
            SeatResult(seat: 6, place: 5, code: .byDistance),
            SeatResult(seat: 1, place: 6, code: .byDistance),
            SeatResult(seat: 4, place: 7, code: .dsq),
            SeatResult(seat: 7, place: 8, code: .ocs),
        ], rated: false)
        let live: [LiveStanding] = [
            LiveStanding(seat: 3, status: .finished, place: 1, finishTick: winner),
            LiveStanding(seat: 0, status: .finished, place: 2, finishTick: winner + 42 * Race.tickRate),
            LiveStanding(seat: 5, status: .racing),
            LiveStanding(seat: 2, status: .racing),
            LiveStanding(seat: 6, status: .racing),
            LiveStanding(seat: 1, status: .racing),
            LiveStanding(seat: 4, status: .dsq),
            LiveStanding(seat: 7, status: .ocs),
        ]
        return RaceResultViewModel(results: final ? results : nil, live: live, entrants: entrants, mySeat: 0,
                                   incidents: gallerySampleIncidents(), served: [0: 2])
    }

    /// The sample race's incident index (#94's types): what the card reads.
    static func gallerySampleIncidents() -> IncidentIndex {
        var index = IncidentIndex()
        func call(_ rule: RacingRule, offender: Int, victim: Int, tick: Int, leg: Int) {
            var incident = index.open(between: offender, and: victim, tick: tick, leg: leg)
            incident.outcome = .called(RuleCall(incidentId: incident.id, tick: tick, rule: rule, offender: offender,
                                                victim: victim, leg: leg, turnsOwed: 1, startDeadlineTick: tick + 450,
                                                completeDeadlineTick: tick + 900))
            index.update(incident)
        }
        call(.portStarboard, offender: 0, victim: 2, tick: 4_000, leg: 0)
        call(.windwardLeeward, offender: 4, victim: 0, tick: 9_000, leg: 2)
        index.recordProtest(Protest(tick: 12_000, leg: 3, protester: 0, protested: 6, matchedIncidentId: nil))
        index.recordMarkTouch(MarkTouch(tick: 15_000, leg: 4, seat: 0, mark: "windward mark"))
        return index
    }
}
