import Foundation
import RegattaCore

/// What your roll tack (#222, #263) shows around your boat: a ring that tells when to tap and how the tap went.
/// Shape carries the meaning, not hue (`CuePalette.cueWhite` only): a thin ring shrinking over the window after
/// the boom crosses, a steady ring once a tap is waiting on the crossing, a solid ring bursting outward on a hit and
/// a broken ring collapsing inward on a miss. Pure: presentation only, nothing here reaches the race (ADR 0002).
nonisolated struct RollRing: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// The boom has crossed and a roll tap still hits: the ring closes over what is left of the window.
        case window
        /// A tap is in, waiting on the crossing to be timed.
        case pending
        /// The tap hit: the ring bursts outward and fades.
        case hit
        /// The tap missed: a broken ring collapses inward and fades.
        case miss
    }

    var kind: Kind
    /// How far through it the ring is, 0 to 1.
    var progress: Double

    /// The ring's radius as a share of `BoatStyle.rollRingHulls` hull lengths.
    var radiusShare: Double {
        switch kind {
        case .window: 1 - 0.55 * progress
        case .pending: 0.55
        case .hit: 0.6 + 0.4 * progress
        case .miss: 0.8 - 0.4 * progress
        }
    }

    /// Its alpha as a share of `BoatStyle.rollRingAlpha`.
    var alphaShare: Double {
        switch kind {
        case .window: 0.7
        case .pending: 0.6
        case .hit, .miss: 1 - progress
        }
    }

    /// Whether it draws the broken ring.
    var isBroken: Bool { kind == .miss }
}

/// Which roll ring `boat` shows at race time `time` (`RollRing`), and the timing of a result's burst: from when it
/// is first drawn, though the race holds the hit or miss until she is close-hauled. Time that runs backwards starts
/// a result over, as `FlogTimer`. Presentation state, one per boat.
nonisolated struct RollRingTimer: Equatable, Sendable {
    private var resultStart: Double?
    private var result: RollRing.Kind?

    /// The ring at `time`, or nil when none shows: `window` is her class's `RollTackTuning.window`, nil for a class
    /// without a roll tack; `seconds` is how long a result shows.
    mutating func ring(for boat: Boat, window: Double?, time: Double, seconds: Double) -> RollRing? {
        guard let window, boat.isTacking else {
            resultStart = nil
            result = nil
            return nil
        }
        switch boat.roll {
        case .pending:
            resultStart = nil
            result = nil
            return RollRing(kind: .pending, progress: 0)
        case .hit, .missed:
            let kind: RollRing.Kind = boat.roll == .hit ? .hit : .miss
            if result != kind || resultStart.map({ time < $0 }) ?? true {
                result = kind
                resultStart = time
            }
            guard let start = resultStart, seconds > 0, time - start < seconds else { return nil }
            return RollRing(kind: kind, progress: (time - start) / seconds)
        case nil:
            resultStart = nil
            result = nil
            guard let crossing = boat.tackCrossingTick, window > 0 else { return nil }
            let elapsed = time - Double(crossing) / Double(Race.tickRate)
            guard elapsed >= 0, elapsed <= window else { return nil }
            return RollRing(kind: .window, progress: elapsed / window)
        }
    }
}
