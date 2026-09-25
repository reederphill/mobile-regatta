/// How one boat moves through one tick, from her boat class alone (ADR 0004): momentum, steering,
/// rudder drag, head-to-wind fall-off, the ease, and the boom crossing on a tack or gybe. Pure: no events, no other boats, no rules.
/// `Race` calls it for every boat every tick; tests call it with a constant `Environment`.
public enum BoatDynamics {
    /// The part of a boat the dynamics move.
    public struct State: Sendable, Equatable {
        public var position: Vec2
        /// Compass heading, radians.
        public var heading: Double
        /// Speed through the water, m/s.
        public var speed: Double
        /// Actual rudder, −1 … 1.
        public var rudder: Double
        /// Which side the boom is on.
        public var boomSide: BoomSide

        public init(position: Vec2 = .zero, heading: Double, speed: Double, rudder: Double = 0, boomSide: BoomSide = .port) {
            self.position = position
            self.heading = heading
            self.speed = speed
            self.rudder = rudder
            self.boomSide = boomSide
        }
    }

    /// What the helm asks for this tick.
    public struct Control: Sendable, Equatable {
        /// Rudder asked for, −1 … 1; the rudder moves towards it at the class's slew rate.
        public var rudder: Double
        /// Sheets let out (`BoatInput.ease`).
        public var ease: Bool
        /// False once the boat has left the course (finished, retired): the sail stops drawing.
        public var sailing: Bool

        public init(rudder: Double, ease: Bool = false, sailing: Bool = true) {
            self.rudder = rudder
            self.ease = ease
            self.sailing = sailing
        }
    }

    /// The water and wind the boat sails in this tick.
    public struct Environment: Sendable, Equatable {
        /// Where the true wind blows from, radians.
        public var windDirection: Double
        /// True wind speed the sail sees (after any wind shadow), m/s.
        public var windSpeed: Double
        /// Current, m/s: moves the boat over the ground without changing her speed through the water.
        public var current: Vec2

        public init(windDirection: Double, windSpeed: Double, current: Vec2 = .zero) {
            self.windDirection = windDirection
            self.windSpeed = windSpeed
            self.current = current
        }

        /// A test environment: the same wind everywhere, no current.
        public static func constant(windDirection: Double, windSpeed: Double) -> Environment {
            Environment(windDirection: windDirection, windSpeed: windSpeed)
        }
    }

    /// `state` after `dt` seconds under `control` in `env`, sailing as `boatClass`.
    ///
    /// - The rudder moves towards the helm's at `steering.rudderSlew`.
    /// - Full rudder turns at `steering.turnRate(speed:)`: from `minTurnRate` stopped up to `topTurnRate`.
    /// - Inside close-hauled (below the polar's best upwind angle) a boat without steerage falls off
    ///   towards close-hauled at `headToWindFallOffRate`, scaled by how little of her top turn rate the
    ///   speed gives her (the class's turn-rate curve): at full way she carries on straight.
    /// - Speed approaches the polar target with the class's time constants: `speedingUp` when below it,
    ///   `slowingDown` above it, `noGo` inside the no-go zone (below the polar's first sailing row, where
    ///   the sail can't draw and the target is 0), and `ease.timeConstant` towards the eased target
    ///   (`ease.speedFraction` of the polar's).
    /// - Rudder drag takes `rudderDrag` of the speed per second at full rudder.
    /// - The boom crosses (`boomCrosses`) on the tick the bow passes head to wind (a tack), or when she
    ///   bears away by the lee past the polar's `byTheLeeLimit` (a gybe). By the lee the speed target is
    ///   the polar mirrored past dead downwind, less `byTheLeePenalty`.
    public static func advance(_ state: State, control: Control, env: Environment, boatClass: BoatClass, dt: Double) -> State {
        let steering = boatClass.steering
        let polar = boatClass.polar
        var s = state

        let slew = steering.rudderSlew * dt
        s.rudder += (control.rudder - s.rudder).clamped(to: -slew...slew)

        var turn = s.rudder * steering.turnRate(speed: s.speed) * dt
        let relative = wrapAngle(env.windDirection - (s.heading + turn))
        let closeHauled = polar.bestUpwind(tws: env.windSpeed).twa
        if abs(relative) < closeHauled {
            // Falls off away from the wind; exactly head to wind she falls onto starboard tack.
            let steerage = steering.turnRate(speed: s.speed) / steering.topTurnRate
            let fallOff = steering.headToWindFallOffRate * max(0, 1 - steerage) * dt
            turn += relative >= 0 ? -min(fallOff, closeHauled - relative) : min(fallOff, closeHauled + relative)
        }
        s.heading = wrapAngle(s.heading + turn)

        let relativeWind = wrapAngle(env.windDirection - s.heading)
        if boomCrosses(sailingAngle: s.boomSide.sailingAngle(relativeWind: relativeWind), tws: env.windSpeed, polar: polar) != nil {
            s.boomSide = s.boomSide.opposite
        }

        let twa = abs(relativeWind)
        let inNoGo = twa < noGoAngle(polar)
        var target = control.sailing && !inNoGo ? polar.speed(twa: twa, tws: env.windSpeed) : 0
        if BoomSide.isByTheLee(s.boomSide.sailingAngle(relativeWind: relativeWind)) {
            target *= 1 - polar.byTheLeePenalty
        }
        let timeConstant: Double
        if control.ease && control.sailing {
            target *= boatClass.ease.speedFraction
            timeConstant = target > s.speed ? boatClass.momentum.speedingUp : boatClass.ease.timeConstant
        } else if target > s.speed {
            timeConstant = boatClass.momentum.speedingUp
        } else {
            timeConstant = inNoGo ? boatClass.momentum.noGo : boatClass.momentum.slowingDown
        }
        s.speed += (target - s.speed) * min(1, dt / timeConstant)
        s.speed -= s.speed * abs(s.rudder) * steering.rudderDrag * dt
        s.speed = max(0, s.speed)
        s.position += Vec2.heading(s.heading) * s.speed * dt + env.current * dt
        return s
    }

    /// How the boom crosses.
    public enum Crossing: Sendable, Equatable {
        /// The bow passed head to wind.
        case tack
        /// She bore away by the lee past the class's limit.
        case gybe
    }

    /// Whether the boom crosses at `sailingAngle` (`BoomSide.sailingAngle(relativeWind:)`), in `tws` (m/s).
    /// With the wind on the boom's side forward of the beam she has passed head to wind: a tack. Aft
    /// of the beam she is by the lee, and gybes once that's more than `byTheLeeLimit(tws:)`.
    public static func boomCrosses(sailingAngle: Double, tws: Double, polar: PolarTable) -> Crossing? {
        guard sailingAngle < 0 else { return nil }
        if -sailingAngle < .pi / 2 { return .tack }
        return .pi + sailingAngle > polar.byTheLeeLimit(tws: tws) ? .gybe : nil
    }

    /// The no-go zone's edge: the polar's first row above head to wind. Inside it the sail can't draw.
    public static func noGoAngle(_ polar: PolarTable) -> Double { polar.twaAxis[1] }

    /// What a boat hits.
    public enum Contact: Sendable {
        case boat
        case mark
    }

    /// Speed right after a contact begins: the class's contact factor of the speed before.
    public static func speed(after contact: Contact, speed: Double, boatClass: BoatClass) -> Double {
        switch contact {
        case .boat: speed * boatClass.contact.boat
        case .mark: speed * boatClass.contact.mark
        }
    }
}
