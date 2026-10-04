import Foundation
import Testing
import RegattaBots
import RegattaCore
@testable import Regatta

/// The practice history the rivals' skill is set from (#235): kept on the device, the newest `Rivals.kept` finishes;
/// a finish counts if you finished or were placed by distance in a fleet of four or more, once per race; the next
/// practice race's rivals sail at the skill it gives, and the briefing and results name them.
@MainActor @Suite struct PracticeHistoryTests {
    /// A private defaults domain, removed after `body`.
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "PracticeHistoryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    private static let livery = FleetLiveries.yours

    private static func entrants(_ count: Int) -> [RaceResultViewModel.Entrant] {
        (0..<count).map { RaceResultViewModel.Entrant(name: $0 == 0 ? "You" : "Bot \($0)", isBot: $0 != 0, livery: livery) }
    }

    /// Closed results of `count` boats with you (seat 0) `place`d with `code`, the rest finishers.
    private static func results(count: Int, place: Int, code: ResultCode) -> RaceResultViewModel {
        var others = Array(1..<count)
        let rows = (1...count).map { rank -> SeatResult in
            if rank == place {
                return SeatResult(seat: 0, place: rank, code: code, finishTick: code == .finished ? 9_000 + rank : nil)
            }
            return SeatResult(seat: others.removeFirst(), place: rank, code: .finished, finishTick: 9_000 + rank)
        }
        return RaceResultViewModel(results: RaceResults(rows: rows, rated: false), live: [], entrants: entrants(count),
                                   mySeat: 0, incidents: nil)
    }

    @Test func storeRoundTripsAndKeepsTheNewest() throws {
        try withDefaults { defaults in
            let store = PracticeHistoryStore(defaults: defaults)
            #expect(store.load().isEmpty)
            var history: [PracticeFinish] = []
            for place in 1...(Rivals.kept + 2) {
                history = Rivals.recording(PracticeFinish(place: place, fleetSize: 16, tier: .regional), in: history)
                store.save(history)
            }
            #expect(store.load() == history)
            #expect(store.load().count == Rivals.kept)
            #expect(store.load().first?.place == 3)
        }
    }

    /// A finish or a by-distance place counts, at the race's tier; DSQ, OCS and RET don't (not pace), nor results that
    /// aren't final, nor a fleet under four.
    @Test func recordingRules() {
        #expect(Self.results(count: 8, place: 3, code: .finished).practiceFinish(tier: .club)
                == PracticeFinish(place: 3, fleetSize: 8, tier: .club))
        #expect(Self.results(count: 8, place: 1, code: .finished).practiceFinish(tier: nil)
                == PracticeFinish(place: 1, fleetSize: 8, tier: nil))
        #expect(Self.results(count: 8, place: 6, code: .byDistance).practiceFinish(tier: nil)
                == PracticeFinish(place: 6, fleetSize: 8, tier: nil))
        for code in [ResultCode.dsq, .ocs, .ret] {
            #expect(Self.results(count: 8, place: 8, code: code).practiceFinish(tier: nil) == nil)
        }
        #expect(Self.results(count: 3, place: 1, code: .finished).practiceFinish(tier: nil) == nil)
        let live = RaceResultViewModel(results: nil, live: [
            .init(seat: 0, status: .finished, place: 1, finishTick: 9_000),
            .init(seat: 1, status: .racing), .init(seat: 2, status: .racing), .init(seat: 3, status: .racing),
        ], entrants: Self.entrants(4), mySeat: 0, incidents: nil)
        #expect(live.practiceFinish(tier: nil) == nil, "not final")
        #expect(live.leftBeforeClose().practiceFinish(tier: nil) == PracticeFinish(place: 1, fleetSize: 4, tier: nil),
                "a finisher's place is final as you leave before the close")
    }

    /// A fresh history: no rivals. A race's close records your finish once (leaving it after doesn't record it again);
    /// the next practice race then has two rivals at the skill the history gives, named in the briefing and results.
    @Test func aFinishedRaceGivesTheNextRaceRivals() throws {
        try withDefaults { defaults in
            let model = AppModel(launchOptions: LaunchOptions(arguments: ["/path/to/Regatta", "-seed", "3"]),
                                 defaults: defaults)
            model.beginPractice()
            #expect(model.practiceConfig?.rivalSkill == nil)
            #expect(try #require(model.briefing).fleet.allSatisfy { !$0.isRival })
            model.finishBriefing()
            let first = try #require(model.session)
            #expect(first.roster.rivals.isEmpty)
            let fleet = model.practiceSetup.fleetSize
            let me = first.driver.myBoatIndex
            var others = Array((0..<fleet).filter { $0 != me })
            let rows = (1...fleet).map { place -> SeatResult in
                SeatResult(seat: place == 2 ? me : others.removeFirst(), place: place, code: .finished,
                           finishTick: 9_000 + place)
            }
            first.consume([RaceEvent(tick: 10, kind: .raceClosed(results: RaceResults(rows: rows, rated: false)))])
            model.leaveRace()
            let history = PracticeHistoryStore(defaults: defaults).load()
            #expect(history == [PracticeFinish(place: 2, fleetSize: fleet, tier: model.practiceSetup.botTier)])

            model.beginPractice()
            let skill = try #require(model.practiceConfig?.rivalSkill)
            #expect(skill == model.practiceSetup.rivalSkill(history: history))
            let briefing = try #require(model.briefing)
            let rivals = Set(briefing.fleet.filter(\.isRival).map(\.seat))
            #expect(rivals.count == 2)
            #expect(briefing.fleet.filter(\.isRival).allSatisfy { $0.isBot && !$0.isMe })
            model.finishBriefing()
            let second = try #require(model.session)
            #expect(second.roster.rivals == rivals)
            second.playerDone = true
            let kept = try #require(second.resultsToKeep())
            #expect(Set(kept.rows.filter(\.isRival).map(\.seat)) == rivals)
            model.leaveRace()
            #expect(PracticeHistoryStore(defaults: defaults).load().count == 2, "left after finishing: it counts")
        }
    }
}
