import Foundation

/// The tide forecast for a race (#78, ADR 0003): when the channel current turns and peaks at each
/// location over a window of race ticks, where it turns first, and how strong it gets. Worked out
/// analytically from `CurrentField`'s local tide phase, so it is exact to the tick; everything in it is
/// public and known before the gun. Shown in the briefing (#15); no UI here.
public struct TideForecast: Sendable, Equatable {
    /// A moment in the tide: slack (the channel current is zero and reverses) or peak (strongest).
    public enum Turn: Sendable, Equatable, CaseIterable {
        /// Local phase 0: the ebb ends and the flood begins.
        case slackBeforeFlood
        /// Local phase π/2.
        case peakFlood
        /// Local phase π: the flood ends and the ebb begins.
        case slackBeforeEbb
        /// Local phase 3π/2.
        case peakEbb

        public var isSlack: Bool { self == .slackBeforeFlood || self == .slackBeforeEbb }
    }

    public struct Event: Sendable, Equatable {
        /// Race tick, rounded to the nearest one.
        public let tick: Int
        public let turn: Turn
    }

    /// One place's forecast.
    public struct Location: Sendable, Equatable {
        /// Metres.
        public let position: Vec2
        /// Depth here, metres.
        public let depth: Double
        /// Compass bearing the flood flows towards here, radians; the ebb flows the other way. Nil
        /// beyond the current grid.
        public let floodDirection: Double?
        /// Strength of the channel current here at peak tide, m/s: the venue's peak scaled by depth.
        /// Zero on dry water and beyond the grid.
        public let peak: Double
        /// Slacks and peaks within the window, in tick order. Empty where there is no current (`peak` 0).
        public let events: [Event]

        /// Ticks of the slacks within the window.
        public var slacks: [Int] { events.filter { $0.turn.isSlack }.map(\.tick) }
        /// Ticks of the peaks within the window.
        public var peaks: [Int] { events.filter { !$0.turn.isSlack }.map(\.tick) }
    }

    /// Race ticks covered, inclusive.
    public let window: ClosedRange<Int>
    /// Strongest channel current anywhere, at the deepest water, m/s; 0 without current.
    public let peak: Double
    /// The requested points first, in the order given, then every wet node of the current grid,
    /// row-major. Empty for a venue without current.
    public let locations: [Location]

    /// Forecast over race ticks `window` for the requested `points` and every wet node.
    public init(field: CurrentField, window: ClosedRange<Int>, points: [Vec2] = []) {
        self.window = window
        guard let current = field.current else {
            peak = 0
            locations = []
            return
        }
        peak = current.peak
        var positions = points
        for row in 0..<current.grid.rows {
            for column in 0..<current.grid.columns where current.depth(column: column, row: row) > 0 {
                positions.append(current.grid.position(column: column, row: row))
            }
        }
        locations = positions.map { Self.location(at: $0, field: field, current: current, window: window) }
    }

    /// Where the tide turns first: the location with the earliest slack in the window (the first such
    /// location on a tie), or nil if no location has a slack in it.
    public var turnsFirst: Location? {
        locations.compactMap { location in location.slacks.first.map { (location, $0) } }
            .min { $0.1 < $1.1 }?.0
    }

    private static func location(at p: Vec2, field: CurrentField, current: Venue.Current,
                                 window: ClosedRange<Int>) -> Location {
        let depth = field.depth(at: p)
        let flood = field.floodDirection(at: p)
        let strength = flood == nil ? 0 : current.peak * current.relativeStrength(depth: depth)
        var events: [Event] = []
        let rate = field.phaseRate
        if strength > 0, rate > 0 {
            // Local phase φ_p(t) = φ_p(0) + rate × t; turn m (m × π/2) comes at t = (m π/2 − φ_p(0)) / rate.
            // Search half a tick either side of the window so rounding can't drop an event at an end.
            let quarter = Double.pi / 2
            let start = field.localPhase(at: p, tick: 0)
            let lower = start + rate * (CurrentField.seconds(window.lowerBound) - 0.5 / Double(Race.tickRate))
            let upper = start + rate * (CurrentField.seconds(window.upperBound) + 0.5 / Double(Race.tickRate))
            var m = (lower / quarter).rounded(.up)
            while m * quarter <= upper {
                let seconds = (m * quarter - start) / rate
                let tick = Int((seconds * Double(Race.tickRate)).rounded())
                if window.contains(tick) {
                    let index = Int(m.truncatingRemainder(dividingBy: 4) + 4) % 4
                    events.append(Event(tick: tick, turn: Turn.allCases[index]))
                }
                m += 1
            }
        }
        return Location(position: p, depth: depth, floodDirection: flood?.bearing, peak: strength, events: events)
    }
}
