import Foundation
import RegattaCore

/// What your roll tack (#222, #263) shows around your boat: a ring that tells when to tap and how the tap went.
/// Shape carries the meaning, not hue (`CuePalette.cueWhite` only). From the moment the tack starts a ring closes on the
/// boat as she comes up to the wind and reaches nothing at the boom crossing: the moment to tap. A dot in it shows a tap
/// is in. Then a hit bursts out as a solid ring ringed with ticks, and a miss collapses as a broken ring with a cross
/// through it. Pure: presentation only, nothing here reaches the race (ADR 0002).
nonisolated struct RollRing: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// The tack has started and the boom has not crossed: the ring closes as she comes up to the wind.
        case approach
        /// The tap hit: the ring bursts outward and fades.
        case hit
        /// The tap missed: a broken ring collapses inward and fades.
        case miss
    }

    var kind: Kind
    /// How far through it the ring is, 0 to 1: how far she has come to head to wind for the approach, how much of the
    /// result's time has passed for a hit or a miss.
    var progress: Double
    /// Whether a tap is in, waiting on the crossing to be timed (approach only).
    var isTapped = false

    /// The ring's radius as a share of `BoatStyle.rollRingHulls` hull lengths.
    var radiusShare: Double {
        switch kind {
        case .approach: 1 - progress
        case .hit: 0.7 + 0.3 * progress
        case .miss: 0.9 - 0.4 * progress
        }
    }

    /// Its alpha as a share of `BoatStyle.rollRingAlpha`: the approach brightens as it closes; a result holds, then fades.
    var alphaShare: Double {
        switch kind {
        case .approach: 0.45 + 0.55 * progress
        case .hit, .miss: min(1, 2 * (1 - progress))
        }
    }

    /// Whether it draws the broken ring with its cross (a miss).
    var isBroken: Bool { kind == .miss }
}

/// Which roll ring `boat` shows at race time `time` (`RollRing`), with the timing of a result's burst: from when it is
/// first drawn, though the race holds the hit or miss until she is close-hauled. Time that runs backwards starts a
/// result over, as `FlogTimer`. The approach reads her wind angle, so it closes however fast she turns, reaching nothing
/// as she comes head to wind (the boom crosses there). Only for a tack: a gybe has no roll yet. Presentation state, one
/// per boat.
nonisolated struct RollRingTimer: Equatable, Sendable {
    private var resultStart: Double?
    private var result: RollRing.Kind?
    /// Her true wind angle when the tack began, radians: what the approach closes from.
    private var tackStartAngle: Double?

    /// The ring at `time`, or nil when none shows: `window` is her class's `RollTackTuning.window`, nil for a class
    /// without a roll tack; `seconds` is how long a result shows.
    mutating func ring(for boat: Boat, window: Double?, time: Double, seconds: Double) -> RollRing? {
        guard window != nil else {
            reset()
            return nil
        }
        // The tack has started (the autohelm is sailing the tap through head to wind) and the boom hasn't crossed.
        if boat.autohelm?.isTapping == true, !boat.isTacking, boat.twa < .pi / 2 {
            resultStart = nil
            result = nil
            let start = max(tackStartAngle ?? 0, boat.twa)
            tackStartAngle = start
            var isTapped = false
            if case .pending = boat.roll { isTapped = true }
            return RollRing(kind: .approach, progress: start > 0 ? (1 - boat.twa / start).clamped(to: 0...1) : 1,
                            isTapped: isTapped)
        }
        tackStartAngle = nil
        guard boat.isTacking else {
            reset()
            return nil
        }
        switch boat.roll {
        case .hit, .missed:
            let kind: RollRing.Kind = boat.roll == .hit ? .hit : .miss
            if result != kind || resultStart.map({ time < $0 }) ?? true {
                result = kind
                resultStart = time
            }
            guard let start = resultStart, seconds > 0, time - start < seconds else { return nil }
            return RollRing(kind: kind, progress: (time - start) / seconds)
        case .pending, nil:
            resultStart = nil
            result = nil
            return nil
        }
    }

    private mutating func reset() {
        resultStart = nil
        result = nil
        tackStartAngle = nil
    }
}
