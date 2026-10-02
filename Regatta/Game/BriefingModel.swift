import Foundation
import RegattaBots
import RegattaCore

/// The briefing (#130, #15, #16): what the player sees between choosing a race and its start sequence. The venue and
/// conditions, the wind forecast, the tide forecast (only at a venue with current, ADR 0003), the course and the fleet.
/// Pure: no SwiftUI, and it never builds a `Race`.
///
/// Everything comes from the public race setup and its files (`WindSetup`, `CourseLayout`, `CurrentField`,
/// `TideForecast`), never from the wind seed: the keyed wind stays secret (ADR 0001), and nothing of the trend's size
/// or timing, the pressure side or the lanes is shown (#10, ADR 0008).
///
/// A practice briefing waits for Ready; an online one counts down 15 s and advances itself, with no callouts (#23).
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

    /// The tide forecast as the briefing draws it (ADR 0003): the channel current over the race window at the deepest
    /// water, with its slacks and peaks, where the tide turns first, and how strong it gets.
    struct TideSummary: Equatable {
        /// One point of the graph: race tick, and the channel current at the deepest water in knots, flood positive
        /// and ebb negative.
        struct Sample: Equatable {
            var tick: Int
            var knots: Double
        }

        /// Race ticks the graph covers: the start sequence through the time limit.
        var window: ClosedRange<Int>
        var samples: [Sample]
        /// The deepest water's slacks and peaks within the window.
        var events: [TideForecast.Event]
        /// Peak channel current anywhere, knots.
        var peakKnots: Double
        /// Compass bearing the flood flows towards at the start line, degrees; nil where the line is off the grid.
        var floodBearingDegrees: Double?
        /// The first slack at the start line and at the windward mark, if one falls in the window.
        var startLineSlack: Int?
        var windwardSlack: Int?
        /// Where the tide turns first (`TideForecast.turnsFirst`) and when.
        var turnsFirst: Vec2?
        var turnsFirstTick: Int?
    }

    let mode: Mode
    let setup: RaceSetup
    let mySeat: Int
    let venueName: String
    let conditionsName: String
    let forecast: WindForecast
    let course: CourseLayout
    /// Nil at a venue without current: the briefing shows no tide section there.
    let tide: TideSummary?
    let fleet: [FleetRow]
    let boatClass: String
    /// Whether this briefing shows the one-off tide callouts (#23): practice, not the first race, a venue with
    /// current, hints on, and this device hasn't seen them. Marked seen when the briefing begins.
    let showsTideCallouts: Bool

    private let seen: RuleSeenStore
    private let menuMusic: any MenuMusic
    private let now: () -> Date
    private(set) var countdown: BriefingCountdown?
    private(set) var hasBegun = false
    private(set) var hasAdvanced = false

    /// `files` are the files `setup` names; `ratings` gives a seat's rating text (nil until the services carry them).
    init(setup: RaceSetup, files: RaceFiles, mySeat: Int, mode: Mode, liveries: FleetLiveries, isFirstRace: Bool = false,
         seen: RuleSeenStore, hintsOn: Bool, menuMusic: any MenuMusic, ratings: (Int) -> String? = { _ in nil },
         now: @escaping () -> Date = Date.init) {
        self.mode = mode
        self.setup = setup
        self.mySeat = mySeat
        self.seen = seen
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
            tide = Self.tideSummary(field: CurrentField(venue: venue, raceSeed: setup.raceSeed), window: window,
                                    course: course)
        } else {
            tide = nil
        }
        let roster = FleetRoster(setup: setup)
        fleet = setup.seats.indices.map { seat in
            let isBot = roster[seat].isBot && seat != mySeat
            return FleetRow(seat: seat, name: roster.name(of: seat, playerSeat: mySeat), isMe: seat == mySeat,
                            isBot: isBot, livery: liveries[seat], rating: isBot ? nil : ratings(seat))
        }
        showsTideCallouts = mode == .practice && !isFirstRace && venue.hasCurrent && hintsOn
            && !seen.hasSeen(.tideCallouts)
    }

    var laps: Int { setup.laps }

    /// The briefing is on screen: fades the menu music out, marks the tide callouts seen if they show, and starts an
    /// online briefing's countdown. Only the first call does anything.
    func begin() {
        guard !hasBegun else { return }
        hasBegun = true
        menuMusic.fadeOut()
        if showsTideCallouts { seen.markSeen(.tideCallouts) }
        if case .online(let seconds) = mode { countdown = BriefingCountdown(duration: seconds, start: now()) }
    }

    /// Seconds left of an online briefing's countdown; nil in practice or before it begins.
    var secondsLeft: Double? { countdown?.remaining(at: now()) }
    /// The whole seconds the countdown shows (`BriefingCountdown.displayed(at:)`); nil in practice or before it begins.
    var displayedSeconds: Int? { countdown?.displayed(at: now()) }

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

    // MARK: Wind text

    /// The wind forecast's lines, in order: strength, direction, trend (only if there is one), shifts, puffs.
    var windLines: [String] { Self.windLines(forecast) }

    // TODO-COPY (#171): every line and label here is placeholder wording; the owner judges words against numbers.
    static func windLines(_ forecast: WindForecast) -> [String] {
        var lines = [strengthLine(forecast), directionLine(forecast)]
        if let trend = trendLine(forecast) { lines.append(trend) }
        lines.append(shiftLine(forecast))
        lines.append(puffLine(forecast))
        return lines
    }

    static func strengthLine(_ forecast: WindForecast) -> String {
        let range = forecast.strengthRangeKnots
        return "\(whole(range.lowerBound))–\(whole(range.upperBound)) kn, about \(whole(forecast.baseStrengthKnots)) kn today"
    }

    static func directionLine(_ forecast: WindForecast) -> String {
        let degrees = whole(forecast.meanDirectionDegrees) % 360
        return "From \(String(format: "%03d", degrees))° (\(compassPoint(forecast.meanDirectionDegrees)))"
    }

    /// Only the trend's direction, never its size or timing (#10).
    static func trendLine(_ forecast: WindForecast) -> String? {
        switch forecast.trend {
        case .right?: "Veering through the race"
        case .left?: "Backing through the race"
        case nil: nil
        }
    }

    static func shiftLine(_ forecast: WindForecast) -> String {
        let amplitude = forecast.shiftAmplitudeDegrees
        let period = forecast.shiftPeriodSeconds
        let label = amplitude < 7 ? "small" : amplitude < 11 ? "moderate" : "big"
        return "Shifts ±\(whole(amplitude))° every \(whole(period.lowerBound))–\(whole(period.upperBound)) s (\(label))"
    }

    static func puffLine(_ forecast: WindForecast) -> String {
        let puffs = forecast.puffs
        let label = puffs.gain.upperBound <= 0.25 ? "mild" : puffs.gain.upperBound <= 0.32 ? "moderate" : "strong"
        return "Puffs +\(percent(puffs.gain.lowerBound))–\(percent(puffs.gain.upperBound))%, lulls "
            + "−\(percent(puffs.lullLoss.lowerBound))–\(percent(puffs.lullLoss.upperBound))%, "
            + "\(percent(puffs.coverage))% of the water (\(label))"
    }

    /// The 16-point compass name of `degrees`.
    static func compassPoint(_ degrees: Double) -> String {
        let points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        let index = Int((degrees / 22.5).rounded()) % 16
        return points[(index + 16) % 16]
    }

    private static func whole(_ value: Double) -> Int { Int(value.rounded()) }
    private static func percent(_ fraction: Double) -> Int { Int((fraction * 100).rounded()) }

    // MARK: Tide text

    // TODO-COPY (#171)
    var tideLines: [String] {
        guard let tide else { return [] }
        var lines = ["Peak \(String(format: "%.1f", tide.peakKnots)) kn in the channel"]
        if let bearing = tide.floodBearingDegrees {
            lines[0] += ", flooding towards \(String(format: "%03d", Int(bearing.rounded()) % 360))°"
        }
        if let tick = tide.startLineSlack { lines.append("Slack at the start line \(Self.raceTime(tick))") }
        if let tick = tide.windwardSlack { lines.append("Slack at the windward mark \(Self.raceTime(tick))") }
        if let tick = tide.turnsFirstTick { lines.append("Turns first at the dot on the course, \(Self.raceTime(tick))") }
        return lines
    }

    /// The one-off tide callouts (#23), shown on the graph when `showsTideCallouts`. TODO-COPY (#171).
    static let tideCallouts = [
        "The line is the tide over the race: above the middle it floods, below it ebbs.",
        "Slack is where it crosses the middle: the tide turns there.",
        "Shallow water turns first: the dot on the course shows where.",
    ]

    /// A race tick as the briefing says it: "at the gun", "2:30 before the gun" or "12:05 after the gun".
    static func raceTime(_ tick: Int) -> String {
        let seconds = Int((Double(abs(tick)) / Double(Race.tickRate)).rounded())
        if seconds == 0 { return "at the gun" }
        let clock = "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
        return tick < 0 ? "\(clock) before the gun" : "\(clock) after the gun"
    }

    /// Samples in the graph.
    static let tideSamples = 120

    private static func tideSummary(field: CurrentField, window: ClosedRange<Int>, course: CourseLayout) -> TideSummary? {
        guard field.current != nil else { return nil }
        let windward = course.elements[CourseLayout.windwardIndex].marks[0].position
        let forecast = TideForecast(field: field, window: window, points: [course.startLine.centre, windward])
        let peakKnots = knots(metresPerSecond: forecast.peak)
        let span = window.upperBound - window.lowerBound
        let samples = (0...tideSamples).map { i -> TideSummary.Sample in
            let tick = window.lowerBound + span * i / tideSamples
            return TideSummary.Sample(tick: tick, knots: peakKnots * sin(field.tideState(atTick: tick)))
        }
        // The deepest water's events: its phase is `tideState`, so they're the curve's own crossings and peaks.
        let deepest = forecast.locations.dropFirst(2).max { $0.peak < $1.peak }
        let line = forecast.locations[0], mark = forecast.locations[1]
        let first = forecast.turnsFirst
        return TideSummary(
            window: window, samples: samples, events: deepest?.events ?? [], peakKnots: peakKnots,
            floodBearingDegrees: (line.floodDirection ?? deepest?.floodDirection).map(Self.compassDegrees),
            startLineSlack: line.slacks.first, windwardSlack: mark.slacks.first,
            turnsFirst: first?.position, turnsFirstTick: first?.slacks.first)
    }

    private static func compassDegrees(_ radians: Double) -> Double {
        let degrees = rad2deg(radians).truncatingRemainder(dividingBy: 360)
        return degrees < 0 ? degrees + 360 : degrees
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
