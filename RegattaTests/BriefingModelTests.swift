import Foundation
import Testing
import RegattaBots
import RegattaCore
@testable import Regatta

/// The briefing's model (#130): the forecasts it shows, its one-off tide callouts, its countdown and its start.
@MainActor @Suite struct BriefingModelTests {
    /// Counts `fadeOut` calls.
    final class CountingMusic: MenuMusic {
        var fadeOuts = 0
        func fadeOut() { fadeOuts += 1 }
    }

    /// A settable clock.
    final class FakeClock {
        var date = Date(timeIntervalSinceReferenceDate: 1_000)
        func advance(_ seconds: Double) { date.addTimeInterval(seconds) }
    }

    private static func config(venue: String, conditions: String, seed: UInt64 = 7, opponents: Int = 5) throws -> RaceConfig {
        try RenderFixture.BriefingFixture(raceSeed: seed, venue: venue, conditions: conditions, opponents: opponents,
                                          mode: .practice, callouts: true).config()
    }

    private static func model(venue: String = "saltings-reach@1", conditions: String = "gusty-offshore@7", seed: UInt64 = 7,
                              mode: BriefingModel.Mode = .practice, isFirstRace: Bool = false, seen: RuleSeenStore = RuleSeenStore(),
                              hintsOn: Bool = true, music: any MenuMusic = SilentMenuMusic(),
                              clock: FakeClock = FakeClock()) throws -> BriefingModel {
        let config = try config(venue: venue, conditions: conditions, seed: seed)
        let setup = config.setup
        return BriefingModel(setup: setup, files: try RaceFiles(resolving: setup), mySeat: 0, mode: mode,
                             liveries: FleetLiveries(setup: setup, mySeat: 0), isFirstRace: isFirstRace, seen: seen,
                             hintsOn: hintsOn, menuMusic: music, now: { clock.date })
    }

    private static let online = BriefingModel.Mode.online(seconds: BriefingModel.Mode.onlineSeconds)

    /// #23: the callouts show the first time a practice briefing shows a venue with current, and never again on this
    /// device; never in the first race, online, at a venue without current or with hints off, and those don't use
    /// them up. They're used up when the briefing begins, not when it's made.
    @Test func tideCalloutShownOnceNeverInFirstRaceOrOnline() throws {
        let seen = RuleSeenStore()
        #expect(try !Self.model(isFirstRace: true, seen: seen).showsTideCallouts)
        #expect(try !Self.model(mode: Self.online, seen: seen).showsTideCallouts)
        #expect(try !Self.model(seen: seen, hintsOn: false).showsTideCallouts)
        #expect(try !Self.model(venue: "fellmere@1", seen: seen).showsTideCallouts)
        #expect(!seen.hasSeen(.tideCallouts))

        let unbegun = try Self.model(seen: seen)
        #expect(unbegun.showsTideCallouts)
        #expect(!seen.hasSeen(.tideCallouts), "made but never shown")

        let first = try Self.model(seen: seen)
        #expect(first.showsTideCallouts)
        first.begin()
        #expect(seen.hasSeen(.tideCallouts))
        #expect(first.showsTideCallouts, "the briefing that shows them keeps them")

        #expect(try !Self.model(seen: seen).showsTideCallouts)
        #expect(try !Self.model(conditions: "classic-oscillating@7", seed: 99, seen: seen).showsTideCallouts)
    }

    /// The callouts' flag is a hint's: Settings' Reset hints shows them again.
    @Test func resetHintsShowsTheCalloutsAgain() throws {
        let defaults = try #require(UserDefaults(suiteName: "BriefingModelTests.resetHints"))
        defaults.removePersistentDomain(forName: "BriefingModelTests.resetHints")
        let seen = RuleSeenStore(defaults: defaults)
        try Self.model(seen: seen).begin()
        #expect(try !Self.model(seen: seen).showsTideCallouts)
        DeviceSettings.resetHints(in: defaults)
        #expect(try Self.model(seen: seen).showsTideCallouts)
        defaults.removePersistentDomain(forName: "BriefingModelTests.resetHints")
    }

    /// #15, #10: each conditions file's forecast says its strength range in knots and this race's base strength, the
    /// seeded mean direction, the shift character and the puff character; a trend only by its direction.
    @Test func forecastTextForEachConditions() throws {
        let cases: [(venue: String, conditions: String, name: String, range: String, shift: String, puffs: String)] = [
            ("fellmere@1", "light-and-patchy@7", "Light and patchy", "6–9 kn", "±10° every 90–110 s", "Puffs +30–35%"),
            ("hollin-bay@1", "classic-oscillating@7", "Classic oscillating", "9–14 kn", "±8° every 70–90 s", "Puffs +22–30%"),
            ("hollin-bay@1", "sea-breeze@7", "Sea breeze", "11–16 kn", "±5° every 60–65 s", "Puffs +20–24%"),
            ("fellmere@1", "gusty-offshore@7", "Gusty offshore", "14–20 kn", "±12° every 60–70 s", "Puffs +28–35%"),
        ]
        for item in cases {
            let model = try Self.model(venue: item.venue, conditions: item.conditions)
            let lines = model.windLines
            #expect(model.conditionsName == item.name)
            #expect(lines[0].hasPrefix(item.range), "\(item.conditions): \(lines[0])")
            let base = Int(model.forecast.baseStrengthKnots.rounded())
            #expect(lines[0].contains("about \(base) kn"), "\(item.conditions): \(lines[0])")
            let direction = Int(model.forecast.meanDirectionDegrees.rounded()) % 360
            #expect(lines[1] == "From \(String(format: "%03d", direction))° (\(BriefingModel.compassPoint(model.forecast.meanDirectionDegrees)))")
            #expect(lines.contains { $0.hasPrefix("Shifts \(item.shift)") }, "\(item.conditions): \(lines)")
            #expect(lines.contains { $0.hasPrefix(item.puffs) }, "\(item.conditions): \(lines)")
            // Only the sea breeze has a trend: its direction alone, never its size or timing (#10).
            let trend = lines.filter { $0.contains("Veering") || $0.contains("Backing") }
            #expect(trend.count == (item.conditions == "sea-breeze@7" ? 1 : 0), "\(item.conditions): \(lines)")
            #expect(!lines.joined().contains("min"), "no trend timing")
            #expect(lines.count == (item.conditions == "sea-breeze@7" ? 5 : 4))
        }
    }

    @Test func compassPoints() {
        #expect(BriefingModel.compassPoint(0) == "N")
        #expect(BriefingModel.compassPoint(359) == "N")
        #expect(BriefingModel.compassPoint(225) == "SW")
        #expect(BriefingModel.compassPoint(315) == "NW")
        #expect(BriefingModel.compassPoint(100) == "E")
    }

    /// ADR 0003: the tide shows only at a venue with current, with its peak and the slacks over the race.
    @Test func tideOnlyAtAVenueWithCurrent() throws {
        #expect(try Self.model(venue: "fellmere@1").tide == nil)
        #expect(try Self.model(venue: "fellmere@1").tideLines.isEmpty)
        let tide = try #require(try Self.model().tide)
        #expect(abs(tide.peakKnots - 2) < 0.01)
        #expect(tide.samples.count == BriefingModel.tideSamples + 1)
        #expect(tide.samples.first?.tick == tide.window.lowerBound && tide.samples.last?.tick == tide.window.upperBound)
        #expect(tide.samples.allSatisfy { abs($0.knots) <= tide.peakKnots + 1e-9 })
        #expect(tide.window.lowerBound == -RaceConfig(seed: 1, windSeed: 1).setup.startSequenceTicks)
    }

    /// The tidal briefing fixture's seed shows every marker: a slack and a peak at the deepest water, and where the
    /// tide turns first.
    @Test func tidalFixtureShowsSlackPeakAndTurnsFirst() throws {
        let gallery = try RenderFixture.gallery(named: "briefing-tidal", in: RenderFixtureTests.fixtures)
        guard case .briefing(let fixture)? = gallery else {
            Issue.record("briefing-tidal isn't a briefing gallery")
            return
        }
        let model = try fixture.model()
        let tide = try #require(model.tide)
        #expect(tide.events.contains { $0.turn.isSlack })
        #expect(tide.events.contains { !$0.turn.isSlack })
        #expect(tide.turnsFirst != nil)
        #expect(model.showsTideCallouts)
        #expect(model.fleet.count == fixture.opponents + 1)

        guard case .briefing(let steady)? = try RenderFixture.gallery(named: "briefing-steady", in: RenderFixtureTests.fixtures) else {
            Issue.record("briefing-steady isn't a briefing gallery")
            return
        }
        #expect(try steady.model().tide == nil)
    }

    /// #16: the online countdown advances at 15 s, once, on the injected clock; practice never counts down.
    @Test func onlineCountdownAdvancesAtFifteenSeconds() throws {
        let clock = FakeClock()
        let model = try Self.model(mode: Self.online, clock: clock)
        #expect(model.secondsLeft == nil)
        #expect(!model.advanceIfDue())
        model.begin()
        #expect(model.displayedSeconds == 15)
        clock.advance(14.9)
        #expect(!model.advanceIfDue())
        #expect(model.displayedSeconds == 1)
        clock.advance(0.1)
        #expect(model.secondsLeft == 0)
        #expect(model.advanceIfDue())
        #expect(!model.advanceIfDue(), "advances once")
        #expect(!model.ready(), "online has no Ready")

        let practice = try Self.model(clock: clock)
        practice.begin()
        clock.advance(60)
        #expect(practice.secondsLeft == nil)
        #expect(!practice.advanceIfDue())
        #expect(practice.ready())
        #expect(!practice.ready(), "Ready advances once")
    }

    @Test func countdownBoundary() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let countdown = BriefingCountdown(duration: 15, start: start)
        #expect(!countdown.isDone(at: start.addingTimeInterval(14.999)))
        #expect(countdown.isDone(at: start.addingTimeInterval(15)))
        #expect(countdown.displayed(at: start) == 15)
        #expect(countdown.displayed(at: start.addingTimeInterval(30)) == 0)
    }

    /// The briefing fades the menu music as it starts, once (#126).
    @Test func beginFadesTheMenuMusicOnce() throws {
        let music = CountingMusic()
        let model = try Self.model(music: music)
        #expect(music.fadeOuts == 0)
        model.begin()
        model.begin()
        #expect(music.fadeOuts == 1)
    }

    /// #19, #21: the fleet list has every seat, you first as "You", each bot marked, each with its livery; no ratings
    /// yet.
    @Test func fleetListsEverySeatWithBotsMarked() throws {
        let model = try Self.model()
        #expect(model.fleet.count == 6)
        #expect(model.fleet[0].isMe && model.fleet[0].name == "You" && !model.fleet[0].isBot)
        #expect(model.fleet.dropFirst().allSatisfy { $0.isBot && !$0.isMe })
        #expect(model.fleet.allSatisfy { $0.rating == nil })
        let liveries = FleetLiveries(setup: model.setup, mySeat: 0)
        #expect(model.fleet.map(\.livery) == liveries.liveries)
        #expect(Set(model.fleet.map(\.livery.sailNumber)).count == model.fleet.count)
    }

    /// The course is the race's own: the same layout `Race` derives from the setup.
    @Test func courseIsTheRacesOwn() throws {
        let config = try Self.config(venue: "saltings-reach@1", conditions: "gusty-offshore@7")
        let setup = config.setup
        let race = try Race(setup: setup, files: RaceFiles(resolving: setup), mode: .authoritative(windSeed: WindSeed(config.windSeed)))
        let model = try Self.model()
        #expect(model.course == race.course)
        #expect(model.venueName == "Saltings Reach")
        #expect(model.laps == setup.laps)
    }

    @Test func raceTimes() {
        #expect(BriefingModel.raceTime(0) == "at the gun")
        #expect(BriefingModel.raceTime(-45 * Race.tickRate) == "0:45 before the gun")
        #expect(BriefingModel.raceTime(725 * Race.tickRate) == "12:05 after the gun")
    }
}
