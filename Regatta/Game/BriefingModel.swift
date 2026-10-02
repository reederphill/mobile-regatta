import Foundation
import RegattaBots
import RegattaCore

/// The briefing (#130, #15, #16): what the player sees between choosing a race and its start sequence. The venue and
/// conditions, a short wind and current description (current only at a venue with it, ADR 0003) and the fleet.
/// Pure: no SwiftUI, and it never builds a `Race`.
///
/// Everything comes from the public race setup and its files (`WindSetup`, `CourseLayout`, `CurrentField`,
/// `TideForecast`), never from the wind seed: the keyed wind stays secret (ADR 0001), and nothing of the trend's size
/// or timing, the pressure side or the lanes is shown (#10, ADR 0008). It says it in a few words, never in numbers:
/// no knots, degrees, seconds, percentages or times (owner review of #130).
///
/// A practice briefing waits for Ready; an online one counts down 15 s and advances itself (#23).
final class BriefingModel {
    enum Mode: Equatable {
        /// Waits for the Ready tap.
        case practice
        /// Counts down `seconds` and advances itself.
        case online(seconds: Double)

        /// The online briefing's length (#16).
        static let onlineSeconds = 15.0
    }

    /// A boat in the fleet list (#21, #19).
    struct FleetRow: Equatable, Identifiable {
        var seat: Int
        /// "You", a bot's sailing name or a player's.
        var name: String
        var isMe: Bool
        /// Bots are always marked as bots (#19), with `BotGlyph`.
        var isBot: Bool
        var livery: Livery
        /// The player's rating, once the services carry one; nil for now, and always for a bot.
        var rating: String?

        var id: Int { seat }
    }

    /// The current as the briefing describes it (ADR 0003): how strong it gets, whether it turns during the race,
    /// and whether it turns earlier in the shallows. Words only, never its times, speed or direction.
    struct CurrentSummary: Equatable {
        enum Strength: Equatable {
            case light, moderate, strong
        }

        var strength: Strength
        /// Whether the deepest water has a slack between the start sequence and the time limit.
        var turnsDuringRace: Bool
        /// Whether shallower water turns before the deepest (`TideForecast.turnsFirst`).
        var turnsEarlierInShallows: Bool
    }

    let mode: Mode
    let setup: RaceSetup
    let mySeat: Int
    let venueName: String
    let conditionsName: String
    let forecast: WindForecast
    let course: CourseLayout
    /// Nil at a venue without current: the briefing says nothing of current there.
    let current: CurrentSummary?
    let fleet: [FleetRow]
    let boatClass: String

    private let menuMusic: any MenuMusic
    private let now: () -> Date
    private(set) var countdown: BriefingCountdown?
    private(set) var hasBegun = false
    private(set) var hasAdvanced = false

    /// `files` are the files `setup` names; `ratings` gives a seat's rating text (nil until the services carry them).
    init(setup: RaceSetup, files: RaceFiles, mySeat: Int, mode: Mode, liveries: FleetLiveries,
         menuMusic: any MenuMusic, ratings: (Int) -> String? = { _ in nil }, now: @escaping () -> Date = Date.init) {
        self.mode = mode
        self.setup = setup
        self.mySeat = mySeat
        self.menuMusic = menuMusic
        self.now = now
        venueName = files.venue.content.displayName
        let windSetup = WindSetup(conditions: files.conditions, pairing: files.pairing, raceSeed: setup.raceSeed)
        forecast = windSetup.forecast
        conditionsName = forecast.conditionsName
        boatClass = files.boatClass.ref.id
        let course = CourseLayout.derive(windSetup: windSetup, land: files.venue.content.land, fleetSize: setup.fleetSize,
                                         laps: setup.laps, boatClass: files.boatClass.content,
                                         rules: files.rulesConfiguration.content)
        self.course = course
        let venue = files.venue.content
        if venue.hasCurrent {
            let window = -setup.startSequenceTicks ... RulesConfig.ticks(files.rulesConfiguration.content.raceFormat.timeLimit)
            current = Self.currentSummary(field: CurrentField(venue: venue, raceSeed: setup.raceSeed), window: window)
        } else {
            current = nil
        }
        let roster = FleetRoster(setup: setup)
        fleet = setup.seats.indices.map { seat in
            let isBot = roster[seat].isBot && seat != mySeat
            return FleetRow(seat: seat, name: roster.name(of: seat, playerSeat: mySeat), isMe: seat == mySeat,
                            isBot: isBot, livery: liveries[seat], rating: isBot ? nil : ratings(seat))
        }
    }

    var laps: Int { setup.laps }

    /// The briefing is on screen: fades the menu music out and starts an online briefing's countdown. Only the first
    /// call does anything.
    func begin() {
        guard !hasBegun else { return }
        hasBegun = true
        menuMusic.fadeOut()
        if case .online(let seconds) = mode { countdown = BriefingCountdown(duration: seconds, start: now()) }
    }

    /// Seconds left of an online briefing's countdown; nil in practice or before it begins.
    var secondsLeft: Double? { countdown?.remaining(at: now()) }
    /// The whole seconds the countdown shows (`BriefingCountdown.displayed(at:)`): the full length until it begins, so
    /// its first frame reads 15, not 0; nil in practice.
    var displayedSeconds: Int? {
        guard case .online(let seconds) = mode else { return nil }
        return countdown?.displayed(at: now()) ?? Int(seconds.rounded(.up))
    }

    /// Whether the briefing should advance now: true once, when an online countdown has run out. Practice advances on
    /// Ready instead (`ready()`).
    func advanceIfDue() -> Bool {
        guard !hasAdvanced, let countdown, countdown.isDone(at: now()) else { return false }
        hasAdvanced = true
        return true
    }

    /// Ready, in practice: true once.
    func ready() -> Bool {
        guard mode == .practice, !hasAdvanced else { return false }
        hasAdvanced = true
        return true
    }

    // MARK: Words

    // TODO-COPY (#171): every phrase here is placeholder wording.

    /// The wind in a phrase or two: strength and direction, then the shifts and puffs (and a trend's direction, if
    /// there is one).
    var windLines: [String] { Self.windLines(forecast) }

    static func windLines(_ forecast: WindForecast) -> [String] {
        let first = "\(strengthWord(knots: forecast.baseStrengthKnots)) breeze from the "
            + compassWord(forecast.meanDirectionDegrees)
        var second = "\(shiftWord(degrees: forecast.shiftAmplitudeDegrees)) shifts, "
            + "\(puffWord(gain: forecast.puffs.gain.upperBound)) puffs"
        if let trend = trendWords(forecast.trend) { second += ", \(trend)" }
        return [first, second]
    }

    /// This race's base strength in a word.
    static func strengthWord(knots: Double) -> String {
        knots < 8 ? "Light" : knots < 13 ? "Moderate" : knots < 17 ? "Fresh" : "Strong"
    }

    /// The oscillating shift's swing in a word.
    static func shiftWord(degrees: Double) -> String {
        degrees < 7 ? "Small" : degrees < 11 ? "Moderate" : "Big"
    }

    /// A puff's peak gain in a word.
    static func puffWord(gain: Double) -> String {
        gain <= 0.25 ? "mild" : gain <= 0.32 ? "moderate" : "strong"
    }

    /// Only the trend's direction, never its size or timing (#10).
    static func trendWords(_ trend: WindSetup.TrendDirection?) -> String? {
        switch trend {
        case .right?: "veering through the race"
        case .left?: "backing through the race"
        case nil: nil
        }
    }

    /// The 8-point compass name of the direction `degrees`, in words: "north", "south-west".
    static func compassWord(_ degrees: Double) -> String {
        let points = ["north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west"]
        let index = Int((degrees / 45).rounded()) % 8
        return points[(index + 8) % 8]
    }

    /// The current in a line, e.g. "Current: strong, turns during the race, earlier in the shallows"; nil at a venue
    /// without current.
    var currentLine: String? { current.map(Self.currentLine) }

    static func currentLine(_ current: CurrentSummary) -> String {
        let strength = switch current.strength {
        case .light: "light"
        case .moderate: "moderate"
        case .strong: "strong"
        }
        var parts = ["Current: \(strength)"]
        if current.turnsDuringRace {
            parts.append("turns during the race")
            if current.turnsEarlierInShallows { parts.append("earlier in the shallows") }
        } else {
            parts.append("steady through the race")
        }
        return parts.joined(separator: ", ")
    }

    /// The course in a line: "Course: windward–leeward, 3 laps".
    var courseLine: String { "Course: windward–leeward, \(laps) \(laps == 1 ? "lap" : "laps")" }

    /// The channel current's peak in a word, knots.
    static func currentStrength(knots: Double) -> CurrentSummary.Strength {
        knots < 0.8 ? .light : knots < 1.6 ? .moderate : .strong
    }

    private static func currentSummary(field: CurrentField, window: ClosedRange<Int>) -> CurrentSummary? {
        guard field.current != nil else { return nil }
        let forecast = TideForecast(field: field, window: window, points: [])
        let deepest = forecast.locations.max { $0.peak < $1.peak }
        let deepestSlack = deepest?.slacks.first
        let earlier: Bool
        if let first = forecast.turnsFirst, let firstSlack = first.slacks.first, let deepest {
            earlier = first.depth < deepest.depth && firstSlack < (deepestSlack ?? Int.max)
        } else {
            earlier = false
        }
        return CurrentSummary(strength: currentStrength(knots: knots(metresPerSecond: forecast.peak)),
                              turnsDuringRace: deepestSlack != nil, turnsEarlierInShallows: earlier)
    }
}

/// An online briefing's countdown (#16): `duration` seconds from `start`, on whatever clock the caller reads (the app
/// scales it by `-timescale`).
struct BriefingCountdown: Equatable {
    var duration: Double
    var start: Date

    /// Seconds left at `date`, never below zero.
    func remaining(at date: Date) -> Double {
        max(0, duration - date.timeIntervalSince(start))
    }

    func isDone(at date: Date) -> Bool { remaining(at: date) <= 0 }

    /// What the countdown shows at `date`: whole seconds, rounded up, so it reads 15 at the start and 1 in the last.
    func displayed(at date: Date) -> Int { Int(remaining(at: date).rounded(.up)) }
}
