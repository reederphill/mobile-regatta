import Foundation
import Testing
import RegattaBots
import RegattaCore
@testable import Regatta

/// The briefing's model (#130): the words it says about the wind, current and course, its countdown and its start.
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
                                          mode: .practice).config()
    }

    private static func model(venue: String = "saltings-reach@1", conditions: String = "gusty-offshore@7", seed: UInt64 = 7,
                              mode: BriefingModel.Mode = .practice, music: any MenuMusic = SilentMenuMusic(),
                              clock: FakeClock = FakeClock()) throws -> BriefingModel {
        let config = try config(venue: venue, conditions: conditions, seed: seed)
        let setup = config.setup
        return BriefingModel(setup: setup, files: try RaceFiles(resolving: setup), mySeat: 0, mode: mode,
                             liveries: FleetLiveries(setup: setup, mySeat: 0), menuMusic: music, now: { clock.date })
    }

    private static let online = BriefingModel.Mode.online(seconds: BriefingModel.Mode.onlineSeconds)

    /// #15, #10, owner review: each conditions file's wind is a phrase or two in words, never numbers: the conditions'
    /// strength and the seeded direction, then the shift and puff character, and a trend only by its direction.
    @Test func forecastTextForEachConditions() throws {
        // The breeze word is the conditions' own (its strength range), never this race's draw: light-and-patchy
        // reads light in every race (owner, 2026-10-02: a ~8 kn Fellmere race read "Moderate").
        let cases: [(venue: String, conditions: String, name: String, strength: String, character: String)] = [
            ("fellmere@1", "light-and-patchy@7", "Light and patchy", "Light", "Moderate shifts, strong puffs"),
            ("hollin-bay@1", "classic-oscillating@7", "Classic oscillating", "Moderate", "Moderate shifts, moderate puffs"),
            ("hollin-bay@1", "sea-breeze@7", "Sea breeze", "Fresh", "Small shifts, mild puffs, "),
            ("fellmere@1", "gusty-offshore@7", "Gusty offshore", "Strong", "Big shifts, strong puffs"),
        ]
        for item in cases {
            for seed: UInt64 in [7, 31, 1, 2, 3, 4, 5] {
                let model = try Self.model(venue: item.venue, conditions: item.conditions, seed: seed)
                let lines = model.windLines
                #expect(model.conditionsName == item.name)
                #expect(lines.count == 2, "\(item.conditions): \(lines)")
                let direction = BriefingModel.compassWord(model.forecast.meanDirectionDegrees)
                #expect(lines[0] == "\(item.strength) breeze from the \(direction)",
                        "\(item.conditions) seed \(seed), \(model.forecast.baseStrengthKnots) kn: \(lines[0])")
                #expect(lines[1].hasPrefix(item.character), "\(item.conditions): \(lines[1])")
                // Only the sea breeze has a trend: its direction alone, never its size or timing (#10).
                let trend = lines[1].contains("veering") || lines[1].contains("backing")
                #expect(trend == (item.conditions == "sea-breeze@7"), "\(item.conditions): \(lines)")
                #expect(!lines.joined().contains { $0.isNumber }, "no numbers: \(lines)")
            }
        }
    }

    @Test func wordsForStrengthShiftsAndPuffs() {
        // From the conditions' range (its middle), so the word never contradicts the conditions' name.
        #expect(BriefingModel.strengthWord(range: 6...9) == "Light")
        #expect(BriefingModel.strengthWord(range: 9...14) == "Moderate")
        #expect(BriefingModel.strengthWord(range: 11...16) == "Fresh")
        #expect(BriefingModel.strengthWord(range: 14...20) == "Strong")
        #expect(BriefingModel.shiftWord(degrees: 5) == "Small")
        #expect(BriefingModel.shiftWord(degrees: 12) == "Big")
        #expect(BriefingModel.puffWord(gain: 0.24) == "mild")
        #expect(BriefingModel.puffWord(gain: 0.35) == "strong")
    }

    @Test func compassWords() {
        #expect(BriefingModel.compassWord(0) == "north")
        #expect(BriefingModel.compassWord(359) == "north")
        #expect(BriefingModel.compassWord(225) == "south-west")
        #expect(BriefingModel.compassWord(315) == "north-west")
        #expect(BriefingModel.compassWord(100) == "east")
    }

    /// ADR 0003, owner review: current is described only at a venue with it, in a line of words: how strong, whether
    /// it turns during the race and whether it turns earlier in the shallows. Never "tide", never a number.
    @Test func currentOnlyAtAVenueWithCurrent() throws {
        #expect(try Self.model(venue: "fellmere@1").current == nil)
        #expect(try Self.model(venue: "fellmere@1").currentLine == nil)
        let model = try Self.model()
        let current = try #require(model.current)
        #expect(current.strength == .strong, "Saltings Reach peaks at 2 kn")
        let line = try #require(model.currentLine)
        #expect(line.hasPrefix("Current: strong, "))
        #expect(!line.contains { $0.isNumber }, "\(line)")
        #expect(!line.lowercased().contains("tide"), "\(line)")
    }

    @Test func currentLineWords() {
        typealias Summary = BriefingModel.CurrentSummary
        #expect(BriefingModel.currentLine(Summary(strength: .strong, turnsDuringRace: true, turnsEarlierInShallows: true))
            == "Current: strong, turns during the race, earlier in the shallows")
        #expect(BriefingModel.currentLine(Summary(strength: .light, turnsDuringRace: true, turnsEarlierInShallows: false))
            == "Current: light, turns during the race")
        #expect(BriefingModel.currentLine(Summary(strength: .moderate, turnsDuringRace: false, turnsEarlierInShallows: false))
            == "Current: moderate, steady through the race")
        #expect(BriefingModel.currentStrength(knots: 0.5) == .light)
        #expect(BriefingModel.currentStrength(knots: 1.2) == .moderate)
        #expect(BriefingModel.currentStrength(knots: 2) == .strong)
    }

    /// The current fixture's seed turns during the race, earlier in the shallows: the longest current line; the
    /// steady fixture has none.
    @Test func currentFixtureTurnsDuringTheRace() throws {
        guard case .briefing(let fixture)? = try RenderFixture.gallery(named: "briefing-current", in: RenderFixtureTests.fixtures) else {
            Issue.record("briefing-current isn't a briefing gallery")
            return
        }
        let model = try fixture.model()
        #expect(model.current == BriefingModel.CurrentSummary(strength: .strong, turnsDuringRace: true,
                                                               turnsEarlierInShallows: true))
        #expect(model.fleet.count == fixture.opponents + 1)

        guard case .briefing(let steady)? = try RenderFixture.gallery(named: "briefing-steady", in: RenderFixtureTests.fixtures) else {
            Issue.record("briefing-steady isn't a briefing gallery")
            return
        }
        #expect(try steady.model().current == nil)
    }

    /// #16: the online countdown advances at 15 s, once, on the injected clock; practice never counts down.
    @Test func onlineCountdownAdvancesAtFifteenSeconds() throws {
        let clock = FakeClock()
        let model = try Self.model(mode: Self.online, clock: clock)
        #expect(model.secondsLeft == nil)
        #expect(model.displayedSeconds == 15, "the first frame, before it begins, reads 15, not 0")
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
        #expect(practice.displayedSeconds == nil)
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
        #expect(model.courseLine == "Course: windward–leeward, \(setup.laps) \(setup.laps == 1 ? "lap" : "laps")")
    }
}
