import Foundation
import RegattaCore

/// Your boat's instruments (#457, #454): her speed through the water and the apparent wind, raw at one tick. The race
/// HUD's bottom row shows them (`HUDModel`); tack and gybe quality is read from them alone (no target, no band).
///
/// The apparent wind is the sim's `Boat.apparentWind`: the wind over the ground at her (before anyone's shadow, but
/// turned by another boat's backwind header, #377), with the current and her own motion through the water in it. A
/// shadow's speed loss is not in it (the shadow is a factor on her sailing wind or target speed, `Boat.shadow`); it
/// shows only as the speed she loses.
struct InstrumentReading: Equatable {
    /// Speed through the water, knots.
    var speedKnots = 0.0
    /// The apparent wind's angle off the bow, radians, −π...π: positive over the starboard side, negative over port.
    var apparentAngle = 0.0
    /// The apparent wind's speed, knots.
    var apparentKnots = 0.0

    init(speedKnots: Double = 0, apparentAngle: Double = 0, apparentKnots: Double = 0) {
        self.speedKnots = speedKnots
        self.apparentAngle = apparentAngle
        self.apparentKnots = apparentKnots
    }

    init(boat: Boat) {
        speedKnots = knots(metresPerSecond: boat.speed)
        apparentAngle = wrapAngle(boat.apparentWind.direction - boat.heading)
        apparentKnots = knots(metresPerSecond: boat.apparentWind.speed)
    }
}

/// The instruments' display smoothing (#457): a first-order low pass in race time, so the tenths don't flicker at the
/// HUD's 15 Hz but a tack's dip (a second or two) still reads. The angle is smoothed the short way round, so it
/// crosses head to wind and dead downwind without swinging through the beam. Nothing moves while race time doesn't
/// (paused, a frozen fixture); the first reading, or one after a jump in race time (a restart), is shown as it is.
struct InstrumentSmoother {
    /// Seconds of race time.
    static let timeConstant = 0.3
    /// A step longer than this (or backwards) is a jump: the reading is shown raw.
    static let jumpSeconds = 1.0

    private(set) var shown: InstrumentReading?
    private var time: Double?

    /// The reading to show at race time `time`, given the latest raw one.
    mutating func step(_ raw: InstrumentReading, at time: Double) -> InstrumentReading {
        defer { self.time = time }
        guard var shown, let last = self.time, time >= last, time - last <= Self.jumpSeconds else {
            shown = raw
            return raw
        }
        guard time > last else { return shown }
        let k = 1 - exp(-(time - last) / Self.timeConstant)
        shown.speedKnots += (raw.speedKnots - shown.speedKnots) * k
        shown.apparentKnots += (raw.apparentKnots - shown.apparentKnots) * k
        shown.apparentAngle = wrapAngle(shown.apparentAngle + wrapAngle(raw.apparentAngle - shown.apparentAngle) * k)
        self.shown = shown
        return shown
    }
}
