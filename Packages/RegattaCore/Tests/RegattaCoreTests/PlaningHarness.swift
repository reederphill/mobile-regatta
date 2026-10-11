import Foundation
@testable import RegattaCore

/// #462: a boat on the plane with the spinnaker up, measured from `BoatDynamics` directly as `HandTack` measures a
/// tack: `warm` seconds on the downwind groove on port boom, then a helm (`GybeHelm`, `RunHelm`) on the rudder, and a
/// twin that sails on in the groove. Loss and distance are to leeward of the mean wind, in hull lengths. The winds are
/// `HandTack`'s seven (steady and the six gusty ones of `WindBook`), with an optional scripted lull.
enum PlaningHarness {
    static let dt = HandTack.dt
    static let knot = metresPerSecond(knots: 1)
    static let port = BoomSide.port

    struct Wind: Sendable {
        var knots: Double
        /// A gusty wind of `WindBook`, or nil: steady.
        var seed: Int?
        /// A scripted lull: the strength falls by this share over 3 s from `lullAt` seconds after the warm-up, holds
        /// `lullHold` seconds and comes back over 3 s.
        var lullDepth = 0.0
        var lullAt = 5.0
        var lullHold = 10.0

        func sample(tick: Int, warmTicks: Int) -> (direction: Double, speed: Double) {
            let (direction, speed) = WindBook.shared.sample(knots: knots, seed: seed, tick: tick)
            guard lullDepth > 0 else { return (direction, speed) }
            let t = Double(tick - warmTicks) * PlaningHarness.dt - lullAt
            let ramp = 3.0
            var depth = 0.0
            if t <= 0 { depth = 0 } else if t < ramp { depth = t / ramp } else if t < ramp + lullHold { depth = 1 }
            else if t < 2 * ramp + lullHold { depth = 1 - (t - ramp - lullHold) / ramp }
            return (direction, speed * (1 - lullDepth * depth))
        }

        /// Steady and the six gusty winds.
        static func all(_ knots: Double) -> [Wind] { [Wind(knots: knots)] + gusty(knots) }
        static func gusty(_ knots: Double) -> [Wind] { (1...6).map { Wind(knots: knots, seed: $0) } }
    }

    /// What a helm steers by, each tick.
    struct Context {
        /// Seconds since the warm-up.
        var t: Double
        var state: BoatDynamics.State
        var windDirection: Double
        var tws: Double
        /// The downwind groove's sailing angle in this tick's wind.
        var groove: Double
        var boat: BoatClass
    }

    protocol Helm {
        /// When she arrived on her new course, seconds since the warm-up; nil for a helm that turns nowhere.
        var arrived: Double? { get }
        mutating func rudder(_ context: Context) -> Double
    }

    struct Result {
        /// Loss against the twin 30 s and 45 s after the warm-up, hull lengths.
        var loss30 = Double.nan
        var loss45 = Double.nan
        /// Her speed as the helm took over, and the least since, m/s.
        var entry = 0.0
        var minSpeed = Double.infinity
        /// The least apparent wind speed, m/s.
        var minApparent = Double.infinity
        /// Seconds off the plane, and how often she got on or off it.
        var offSeconds = 0.0
        var transitions = 0
        var firstOff: Double?
        var lastOff: Double?
        var onAtEnd = false
        var arrived: Double?
        /// At the end: speed (kn), true and apparent wind angle (degrees), apparent wind speed (kn).
        var endSpeed = 0.0
        var endTWA = 0.0
        var endAWA = 0.0
        var endApparent = 0.0
        /// Knots made good to leeward over the last 30 s.
        var vmg30 = 0.0
        /// Hull lengths made good to leeward since the warm-up.
        var leeward = 0.0
        var end = BoatDynamics.State(heading: 0, speed: 0)

        /// Off the plane 2 s after she arrived on her new course (at any time, for a helm that turns nowhere).
        var fell: Bool {
            guard let lastOff else { return false }
            guard let arrived else { return true }
            return lastOff >= arrived + 2
        }

        /// Off the plane only during the turn.
        var flickered: Bool { offSeconds > 0 && !fell }

        /// Seconds from first off the plane to on it for good; nil if she never left it or is off it at the end.
        var replane: Double? {
            guard let firstOff, let lastOff, onAtEnd else { return nil }
            return lastOff - firstOff + PlaningHarness.dt
        }
    }

    enum Start { case planing, offPlane }

    static func compass(_ wind: Double, _ angle: Double, _ boom: BoomSide) -> Double {
        HandTack.compass(wind: wind, sailingAngle: angle, boom: boom)
    }

    static func grooveAngle(_ tws: Double, _ boat: BoatClass) -> Double {
        Autohelm.grooveAngle(.downwind, tws: tws, boatClass: boat)
    }

    static func apparentSpeed(_ twa: Double, _ speed: Double, _ tws: Double) -> Double {
        BoatClass.PlaningTuning.apparentWindSpeed(twa: twa, speed: speed, tws: tws)
    }

    /// The apparent wind angle, degrees.
    static func apparentAngle(_ twa: Double, _ speed: Double, _ tws: Double) -> Double {
        rad2deg(Foundation.acos(BoatClass.PlaningTuning.apparentWindCosine(twa: twa, speed: speed, tws: tws).clamped(to: -1...1)))
    }

    /// `helm` sails `seconds` after `warm` seconds on the downwind groove, on port boom with the spinnaker up, from
    /// the plane at her polar speed or off it at her off-plane speed; the twin always starts planing.
    static func sail<H: Helm>(_ boat: BoatClass, _ wind: Wind, seconds: Double, warm: Double = 10, start: Start = .planing,
                              helm: inout H) -> Result {
        let warmTicks = Int((warm / dt).rounded()), ticks = Int((seconds / dt).rounded())
        let wind0 = wind.sample(tick: 0, warmTicks: warmTicks)
        let angle0 = grooveAngle(wind0.speed, boat)
        let heading0 = compass(wind0.direction, angle0, port)
        let on = boat.polar.speed(twa: angle0, tws: wind0.speed)
        let off = boat.planing!.offPlaneSpeed(twa: angle0, tws: wind0.speed, polar: boat.polar)
        var state = BoatDynamics.State(heading: heading0, speed: start == .planing ? on : off, boomSide: port,
                                       isPlaning: start == .planing, spinnaker: .up)
        var twin = BoatDynamics.State(heading: heading0, speed: on, boomSide: port, isPlaning: true, spinnaker: .up)
        let leewardAxis = Vec2.heading(0) * -1
        var result = Result()
        var leeward0 = 0.0, leewardMid = 0.0
        for tick in 0..<(warmTicks + ticks) {
            let (direction, tws) = wind.sample(tick: tick, warmTicks: warmTicks)
            let env = BoatDynamics.Environment.constant(windDirection: direction, windSpeed: tws)
            let groove = grooveAngle(tws, boat)
            let origin = compass(direction, groove, port)
            let command: Double
            if tick < warmTicks {
                command = HandTack.holdLaw(heading: state.heading, aim: origin)
            } else {
                if tick == warmTicks {
                    result.entry = state.speed
                    leeward0 = state.position.dot(leewardAxis)
                }
                command = helm.rudder(Context(t: Double(tick - warmTicks) * dt, state: state, windDirection: direction, tws: tws,
                                              groove: groove, boat: boat))
            }
            let was = state.isPlaning
            state = BoatDynamics.advance(state, control: .init(rudder: command), env: env, boatClass: boat, dt: dt)
            twin = BoatDynamics.advance(twin, control: .init(rudder: HandTack.holdLaw(heading: twin.heading, aim: origin)),
                                        env: env, boatClass: boat, dt: dt)
            guard tick >= warmTicks else { continue }
            let now = Double(tick - warmTicks + 1) * dt
            let twa = abs(wrapAngle(direction - state.heading))
            if state.isPlaning != was { result.transitions += 1 }
            if !state.isPlaning {
                result.offSeconds += dt
                if result.firstOff == nil { result.firstOff = now }
                result.lastOff = now
            }
            result.minSpeed = min(result.minSpeed, state.speed)
            result.minApparent = min(result.minApparent, apparentSpeed(twa, state.speed, tws))
            let loss = (twin.position.dot(leewardAxis) - state.position.dot(leewardAxis)) / boat.hull.length
            if abs(now - 30) < dt / 2 { result.loss30 = loss }
            if abs(now - 45) < dt / 2 { result.loss45 = loss }
            if abs(now - (seconds - 30)) < dt / 2 { leewardMid = state.position.dot(leewardAxis) }
            if tick == warmTicks + ticks - 1 {
                result.endSpeed = state.speed / knot
                result.endTWA = rad2deg(twa)
                result.endAWA = apparentAngle(twa, state.speed, tws)
                result.endApparent = apparentSpeed(twa, state.speed, tws) / knot
                result.vmg30 = (state.position.dot(leewardAxis) - leewardMid) / 30 / knot
                result.leeward = (state.position.dot(leewardAxis) - leeward0) / boat.hull.length
            }
        }
        result.onAtEnd = state.isPlaning
        result.arrived = helm.arrived
        result.end = state
        return result
    }

    /// The deepest sailing angle, no deeper than the groove, at which she gets on the plane in `tws` with most of her
    /// steady off-plane speed there, or with what she still carries (`speedNow`); in marginal wind, the fastest angle
    /// that gets her on at all. Nil: none does.
    static func planingAngle(tws: Double, _ boat: BoatClass, speedNow: Double = 0) -> Double? {
        let planing = boat.planing!
        func offSpeed(_ angle: Double) -> Double {
            var speed = planing.offPlaneSpeed(twa: angle, tws: tws, polar: boat.polar)
            if let kite = boat.spinnaker, angle < kite.dropBelowTWA { speed *= kite.twoSailFactor(twa: angle) }
            return speed
        }
        func getsOn(_ angle: Double, _ speed: Double) -> Bool {
            planing.isPlaning(was: false, twa: angle, speed: speed, tws: tws, rudder: 0, polar: boat.polar)
        }
        for margin in [0.92, 0.96] {
            var angle = grooveAngle(tws, boat)
            while angle >= planing.fromTWA {
                if getsOn(angle, max(margin * offSpeed(angle), 0.95 * speedNow)) { return angle }
                angle -= deg2rad(1)
            }
        }
        var best: Double?, bestSpeed = 0.0
        var angle = grooveAngle(tws, boat)
        while angle >= planing.fromTWA {
            let speed = offSpeed(angle)
            if getsOn(angle, speed), speed > bestSpeed {
                best = angle
                bestSpeed = speed
            }
            angle -= deg2rad(1)
        }
        return best
    }

    /// "Head up to plane": off the plane she steers for the planing angle, and bears away again once she planes at
    /// 85 % of the groove's speed.
    struct Recovery {
        var heating = false

        mutating func aim(_ context: Context, boom: BoomSide) -> Double? {
            if !context.state.isPlaning {
                heating = true
            } else if heating, context.state.speed >= 0.85 * context.boat.polar.speed(twa: context.groove, tws: context.tws) {
                heating = false
            }
            guard heating, let angle = PlaningHarness.planingAngle(tws: context.tws, context.boat, speedNow: context.state.speed)
            else { return nil }
            return PlaningHarness.compass(context.windDirection, angle, boom)
        }
    }

    /// A gybe from port boom: `fraction` of full rudder to `over` degrees past the new groove, never let go before the
    /// boom is across, then the hold law for the groove. `linger`: on the way she first holds dead downwind that many
    /// seconds. `headsUp`: off the plane afterwards she heads up to plane (at most half rudder); otherwise she sits
    /// on the groove.
    struct GybeHelm: Helm {
        var fraction: Double
        var over = 0.0
        var linger = 0.0
        var headsUp = false
        var phase = 0
        var mark = 0.0
        var arrived: Double?
        var recovery = Recovery()

        mutating func rudder(_ context: Context) -> Double {
            let turnSign = -1.0
            let port = PlaningHarness.port
            let state = context.state
            let aim = PlaningHarness.compass(context.windDirection, context.groove, port.opposite)
            let end = fraction * context.boat.steering.turnRate(speed: state.speed) * 0.2
            let deadDownwind = wrapAngle(context.windDirection - .pi)
            if phase == 0 {
                if linger > 0 {
                    if HandTack.headingRemaining(from: state.heading, to: deadDownwind, turnSign: turnSign) > end {
                        return HandTack.quantise(turnSign * fraction)
                    }
                    phase = 1
                    mark = context.t + linger
                } else {
                    phase = 2
                }
            }
            if phase == 1 {
                if context.t < mark { return HandTack.holdLaw(heading: state.heading, aim: deadDownwind) }
                phase = 2
            }
            if phase == 2 {
                var remaining = HandTack.headingRemaining(from: state.heading, to: aim + turnSign * deg2rad(over), turnSign: turnSign)
                if state.boomSide == port, remaining < 0 { remaining += 2 * .pi }
                if remaining > end || state.boomSide == port { return HandTack.quantise(turnSign * fraction) }
                phase = 3
                arrived = context.t
            }
            if headsUp, let heat = recovery.aim(context, boom: port.opposite) {
                return HandTack.holdLaw(heading: state.heading, aim: heat).clamped(to: -0.5...0.5)
            }
            return HandTack.holdLaw(heading: state.heading, aim: aim)
        }
    }

    /// A run on port boom at the groove plus `delta` degrees.
    struct RunHelm: Helm {
        enum Mode {
            /// Follows the groove angle of the wind she has, as the bots do.
            case track
            /// Holds the compass course of the mean wind's groove (plus `delta`): a centred rudder.
            case compass
        }

        var delta = 0.0
        var mode = Mode.track
        /// The wind's mean strength, m/s: the compass course's groove.
        var meanTWS: Double
        var headsUp = false
        var recovery = Recovery()
        var arrived: Double? { nil }

        mutating func rudder(_ context: Context) -> Double {
            let port = PlaningHarness.port
            if headsUp, let heat = recovery.aim(context, boom: port) {
                return HandTack.holdLaw(heading: context.state.heading, aim: heat).clamped(to: -0.5...0.5)
            }
            let deepest = deg2rad(178)
            switch mode {
            case .track:
                let angle = min(context.groove + deg2rad(delta), deepest)
                return HandTack.holdLaw(heading: context.state.heading, aim: PlaningHarness.compass(context.windDirection, angle, port))
            case .compass:
                let angle = min(PlaningHarness.grooveAngle(meanTWS, context.boat) + deg2rad(delta), deepest)
                return HandTack.holdLaw(heading: context.state.heading, aim: PlaningHarness.compass(0, angle, port))
            }
        }
    }

    /// A gybe by `fraction` of full rudder (`GybeHelm`), 45 s from the rudder going over.
    static func gybe(_ fraction: Double, over: Double = 0, linger: Double = 0, headsUp: Bool = false, _ boat: BoatClass,
                     _ wind: Wind, seconds: Double = 45) -> Result {
        var helm = GybeHelm(fraction: fraction, over: over, linger: linger, headsUp: headsUp)
        return sail(boat, wind, seconds: seconds, helm: &helm)
    }

    /// A run at the groove plus `delta` degrees (`RunHelm`), 50 s after the warm-up.
    static func run(_ boat: BoatClass, _ wind: Wind, delta: Double = 0, mode: RunHelm.Mode = .track, headsUp: Bool = false,
                    seconds: Double = 50, start: Start = .planing) -> Result {
        var helm = RunHelm(delta: delta, mode: mode, meanTWS: wind.knots * knot, headsUp: headsUp)
        return sail(boat, wind, seconds: seconds, start: start, helm: &helm)
    }
}
