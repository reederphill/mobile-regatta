/// What steers the boat whenever nobody is holding the rudder (ADR 0007, #230): it holds her angle to
/// the true wind at the boat, the sailing wind the polar reads (`Boat.windDirection`, wind less current).
///
/// - It engages on the tick the held rudder centres (`deadBand`), capturing the angle she has then
///   (`engage`). Let go within a snap width of the groove (the class's `upwindSnap`, `downwindSnap`),
///   it takes the groove, which follows the polar's best angle for the wind strength at the boat: the
///   class's running average of it (`Boat.grooveWindSpeed(in:)`, #245), which for a schema-2 class is the wind
///   right now. A puff shorter than the skiff's average leaves bearing away in it the player's call.
///   Let go inside the no-go zone, it bears away to the upwind groove on her boom's side (her tack).
///   The target is an angle to the wind, so a shift never carries it into the no-go zone: she turns
///   with the shift instead.
/// - It steers through the rudder it asks for (`Boat.desiredRudder`) and the class's turn physics:
///   rudder in proportion to the angle's error (the class's `gain`), no dead band, so the angle
///   settles on the target in a steady wind and follows a shift.
/// - Every angle is a sailing angle (`BoomSide.sailingAngle`), read against the boom. So it never
///   tacks or gybes by itself: the boom crosses only when she passes head to wind or the by-the-lee
///   limit, and it never steers her there. It holds an angle by the lee at most the class's
///   `byTheLeeMargin` short of the limit, heading up as the limit shrinks in a building breeze.
/// - Dead run: a groove at 180° is sailed `deadRunMargin` short of dead downwind, with the wind on the
///   quarter away from the boom. The boom side is the hysteresis: whichever quarter a wobble in the wind
///   puts the wind on, the target stays on the boom's side and she never swaps between by the lee and
///   not on the groove. Only a gybe, past the by-the-lee limit, changes the side.
/// - The tack/gybe tap (#13) hands it the groove, upwind for a tack (the wind forward of the beam) or
///   downwind for a gybe, and `isTapping`: full rudder the way that crosses the boom, then, once it
///   has crossed, the groove on the new side (the new tack).
/// - A held rudder off centre disengages it, a tap included (`Race`); the next centring captures again.
public struct Autohelm: Sendable, Equatable {
    /// A held rudder (`BoatInput.rudderValue`) within this of centre is centred: the autohelm steers.
    public static let deadBand = 0.05

    /// The best-VMG angle to the wind: upwind or downwind (CONTEXT.md, "Groove").
    public enum Groove: Sendable, Equatable {
        case upwind
        case downwind
    }

    public enum Target: Sendable, Equatable {
        /// A held sailing angle (`BoomSide.sailingAngle`), radians, −π ..< π: positive with the wind on
        /// the side away from the boom, below −π/2 by the lee.
        case angle(Double)
        /// The groove on the boom's side, at the wind strength its grooves read (`Boat.grooveWindSpeed(in:)`).
        case groove(Groove)

        /// The held angle, or nil for the groove.
        public var angle: Double? {
            if case .angle(let angle) = self { angle } else { nil }
        }

        /// The groove, or nil for a held angle.
        public var groove: Groove? {
            if case .groove(let groove) = self { groove } else { nil }
        }

        /// Whether the target is abaft the beam: where a tap on it gybes rather than tacks.
        public var isDownwind: Bool {
            switch self {
            case .angle(let angle): abs(angle) >= .pi / 2
            case .groove(let groove): groove == .downwind
            }
        }
    }

    public var target: Target
    /// The tack/gybe tap is steering her through head to wind or the gybe; it ends when the boom crosses.
    public var isTapping: Bool

    public init(target: Target, isTapping: Bool = false) {
        self.target = target
        self.isTapping = isTapping
    }

    // MARK: - Engaging

    /// The autohelm of a boat whose rudder has just centred at `sailingAngle`, in `tws` (m/s, the wind
    /// speed her grooves read, `Boat.grooveWindSpeed(in:)`), and whether it snapped to the groove. Inside the
    /// no-go zone it takes the upwind groove without a snap: she bears away to it.
    public static func engage(sailingAngle: Double, tws: Double, boatClass: BoatClass) -> (autohelm: Autohelm, snapped: Bool) {
        let polar = boatClass.polar
        let tuning = boatClass.steering.autohelm
        let angle = wrapAngle(sailingAngle)
        if isInNoGo(angle, polar) { return (Autohelm(target: .groove(.upwind)), false) }
        if abs(wrapAngle(angle - polar.bestUpwind(tws: tws).twa)) <= tuning.upwindSnap {
            return (Autohelm(target: .groove(.upwind)), true)
        }
        // Against the polar's own best angle: at 180° a snap reaches as far by the lee as not.
        if abs(wrapAngle(angle - polar.bestDownwind(tws: tws).twa)) <= tuning.downwindSnap {
            return (Autohelm(target: .groove(.downwind)), true)
        }
        return (Autohelm(target: .angle(angle)), false)
    }

    /// The tap at `sailingAngle`: the groove on the other side, tacking with the wind forward of the
    /// beam and gybing abaft it.
    public static func tackOrGybe(sailingAngle: Double) -> Autohelm {
        Autohelm(target: .groove(abs(wrapAngle(sailingAngle)) < .pi / 2 ? .upwind : .downwind), isTapping: true)
    }

    /// Whether a sailing angle is inside the no-go zone, or past head to wind with the boom not yet across.
    static func isInNoGo(_ sailingAngle: Double, _ polar: PolarTable) -> Bool {
        sailingAngle > -.pi / 2 && sailingAngle < BoatDynamics.noGoAngle(polar)
    }

    // MARK: - Steering

    /// The sailing angle of `groove` in `tws` (m/s): the polar's best angle, a 180° one kept the class's
    /// `deadRunMargin` short of dead downwind (the dead-run rule).
    public static func grooveAngle(_ groove: Groove, tws: Double, boatClass: BoatClass) -> Double {
        switch groove {
        case .upwind: boatClass.polar.bestUpwind(tws: tws).twa
        case .downwind: min(boatClass.polar.bestDownwind(tws: tws).twa, .pi - boatClass.steering.autohelm.deadRunMargin)
        }
    }

    /// The sailing angle it steers for in `tws` (m/s, the wind speed her polar reads): the groove's at
    /// `grooveTWS` (the wind speed her grooves read, `Boat.grooveWindSpeed(in:)`; `tws` if nil), or the held
    /// angle, kept short of the by-the-lee limit in `tws` by the class's `byTheLeeMargin`. An angle inside
    /// the no-go zone, which only an imported snapshot could hold, steers for the upwind groove.
    public func aim(tws: Double, grooveTWS: Double? = nil, boatClass: BoatClass) -> Double {
        let grooveTWS = grooveTWS ?? tws
        switch target {
        case .groove(let groove):
            return Autohelm.grooveAngle(groove, tws: grooveTWS, boatClass: boatClass)
        case .angle(let angle):
            let polar = boatClass.polar
            if Autohelm.isInNoGo(angle, polar) { return Autohelm.grooveAngle(.upwind, tws: grooveTWS, boatClass: boatClass) }
            guard angle < 0 else { return angle }
            // By the lee: how far past dead downwind, at most the limit less the margin.
            let deepest = max(0, polar.byTheLeeLimit(tws: tws) - boatClass.steering.autohelm.byTheLeeMargin)
            return .pi + angle <= deepest ? angle : deepest - .pi
        }
    }

    /// The rudder it asks for, −1 … 1, for a boat at `sailingAngle` with her boom on `boomSide` in `tws`
    /// and `grooveTWS` (m/s, as `aim`). Sailing the tap, full rudder the way that crosses the boom: towards
    /// the wind for a tack, away from it for a gybe. Otherwise in proportion to the error from `aim`.
    public func rudder(sailingAngle: Double, boomSide: BoomSide, tws: Double, grooveTWS: Double? = nil,
                       boatClass: BoatClass) -> Double {
        // Turning to starboard (+) moves the sailing angle by −windSign: towards the wind on starboard tack.
        if isTapping { return target.isDownwind ? -boomSide.windSign : boomSide.windSign }
        let error = wrapAngle(aim(tws: tws, grooveTWS: grooveTWS, boatClass: boatClass) - sailingAngle)
        return (-boomSide.windSign * boatClass.steering.autohelm.gain * error).clamped(to: -1...1)
    }

    // MARK: - Reading

    /// What the autohelm holds, for drawing (#122's vane tick and arc) and feel (#124).
    public struct Reading: Sendable, Equatable {
        public let target: Target
        public let isTapping: Bool
        /// The sailing angle it steers for (`aim`), radians.
        public let aim: Double
        /// The groove `aim` is read against: upwind with it forward of the beam, downwind abaft it.
        public let groove: Groove
        /// That groove's sailing angle at the wind strength its grooves read, radians.
        public let grooveAngle: Double
        /// `aim` less `grooveAngle`, radians: 0 in the groove, positive further off the wind (footing,
        /// sailing deeper), negative closer to it (pinching).
        public let offsetFromGroove: Double
    }

    /// Its reading in `tws` and `grooveTWS` (m/s, as `aim`).
    public func reading(tws: Double, grooveTWS: Double? = nil, boatClass: BoatClass) -> Reading {
        let grooveTWS = grooveTWS ?? tws
        let aim = aim(tws: tws, grooveTWS: grooveTWS, boatClass: boatClass)
        let groove: Groove
        switch target {
        case .groove(let g): groove = g
        case .angle: groove = abs(aim) < .pi / 2 ? .upwind : .downwind
        }
        let grooveAngle = Autohelm.grooveAngle(groove, tws: grooveTWS, boatClass: boatClass)
        return Reading(target: target, isTapping: isTapping, aim: aim, groove: groove, grooveAngle: grooveAngle,
                       offsetFromGroove: wrapAngle(aim - grooveAngle))
    }
}

extension Boat {
    /// Her autohelm's reading in the sailing wind at her, or nil while the rudder is held off centre.
    public func autohelmReading(in boatClass: BoatClass) -> Autohelm.Reading? {
        autohelm?.reading(tws: polarWindSpeed(in: boatClass), grooveTWS: grooveWindSpeed(in: boatClass), boatClass: boatClass)
    }
}
