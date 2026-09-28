import Testing
@testable import RegattaCore
@testable import RegattaBots

/// #102, #19 "current sense: Club ignores current, and National plays set and the turn of the tide from the
/// forecast". A bot allows for the current on her way to her mark (`BotBrain.currentAllowance`) by her skill's
/// current sense; what she doesn't allow for sets her off her layline.
@Suite struct BotCurrentSenseTests {
    /// A tidal estuary's current: flooding at `knots` towards `bearing` over the whole race area, past its peak and
    /// easing towards the turn on a tide clock sped up so it turns within a race.
    static func estuary(knots: Double = 2, towards bearing: Double) -> CurrentField {
        let grid = Venue.Grid(origin: Vec2(-5_000, -5_000), cellSize: 10_000, orientation: 0, columns: 2, rows: 2)
        let current = Venue.Current(
            peak: metresPerSecond(knots: knots), isTidal: true, tideClockRate: 12,
            allowedTideStatesAtGun: .init(from: 2.2, to: 2.2), grid: grid, depths: [8, 8, 8, 8],
            floodDirections: [bearing, bearing, bearing, bearing], strengthExponent: 2.0 / 3, shallowsLead: 0,
            eddies: [], maxDepth: 8)
        return CurrentField(current: current, tideStateAtGun: 2.2)
    }

    /// The set she meets sailing from where she is to the windward mark, m/s: the current along her track at the
    /// times she's there, finely sampled.
    static func actualSet(_ view: SeatView, from p: Vec2, to target: Vec2, seconds: Double) -> Vec2 {
        let n = 60
        var sum = Vec2.zero
        for i in 0...n {
            let t = Double(i) / Double(n)
            sum += view.current.sample(p + (target - p) * t, tick: view.tick + RulesConfig.ticks(seconds * t))
        }
        return sum / Double(n + 1)
    }

    /// In the estuary, beating to the windward mark with the tide across the course: a Club bot's layline set error
    /// is the whole set (she allows for none of it), a National bot's a small part of it (she allows for the
    /// forecast's, the turn of the tide included), and a Regional bot's between.
    @Test func laylineSetErrorShrinksWithSkill() throws {
        let setup = try RaceSetup(raceSeed: RaceSeed(8), seats: [.bot, .human], laps: 2, startSequenceTicks: 30 * Race.tickRate)
        let probe = try Race(setup: setup, files: RaceFiles(resolving: setup), mode: .authoritative(windSeed: WindSeed(17)))
        let across = probe.course.axis + .pi / 2
        let race = try Race(setup: setup, files: RaceFiles(resolving: setup), mode: .authoritative(windSeed: WindSeed(17)),
                            current: Self.estuary(towards: across))
        for _ in 0..<(40 * Race.tickRate) { race.step() }
        let view = race.seatView(for: 0)
        let mark = race.course.elements[CourseLayout.windwardIndex].marks[0].position

        func error(_ tier: BotTier) -> (error: Double, set: Double) {
            let style = BotStyle(skill: tier.skill(at: 0.5), startSpot: 0.5, finishSpot: 0.7, timingSlack: 0, penaltyDirection: 1)
            let brain = BotBrain(style: style)
            let seconds = brain.secondsToSail(view.own, to: mark)
            let set = Self.actualSet(view, from: view.own.position, to: mark, seconds: seconds)
            let allowed = brain.currentAllowance(view.own, view, to: mark)
            // Metres she ends up off her layline by: the set she didn't allow for, over her time to the mark.
            return ((set - allowed).length * seconds, set.length * seconds)
        }
        let club = error(.club), regional = error(.regional), national = error(.national)
        print("layline set error, metres: club \(club.error) of \(club.set) set, regional \(regional.error), national \(national.error)")
        #expect(club.set > 50, "a strong enough tide to matter: \(club.set) m")
        #expect(abs(club.error - club.set) < 0.01 * club.set, "Club allows for none of it")
        #expect(national.error < 0.2 * national.set, "National allows for the forecast's: \(national.error) of \(national.set)")
        #expect(national.error < regional.error && regional.error < club.error)

        // The tide turns on her way: the forecast she allows for eases with it, as the current does.
        let atGun = view.current.sample(view.own.position, tick: view.tick)
        let set = Self.actualSet(view, from: view.own.position, to: mark, seconds: BotBrain(style: .init(
            skill: 0.9, startSpot: 0.5, finishSpot: 0.7, timingSlack: 0, penaltyDirection: 1)).secondsToSail(view.own, to: mark))
        #expect(set.length < atGun.length, "the tide eases through the beat")
    }
}
