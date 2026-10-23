import RegattaCore

/// The National helm's planner (#583 stage 3): instead of weighing the shift, the puffs and the pressure as degrees of
/// header against a threshold (`BotBrain.upwindTack`, `downwindGybe`), she sails "hold this tack" and "tack (or gybe)
/// now" forward on the boat's own dynamics (`BoatDynamics.advance`) for her horizon, in the wind she can see, and
/// turns when turning gets her to her mark sooner by more than her margin (`BotTunables.plannerMargin`). The oracle
/// time trial (`regatta-timetrial`, stage 1) measured the heuristics a long way off the fastest lap; this is the
/// oracle's search, shallow, on a player's information.
///
/// **Information, not foresight** (ADR 0001): the planner's world is built from her `SeatView` and nothing else, by
/// construction (`PerceivedWind`): the wind at her boat, the puffs and lulls drawn on the water within her perception
/// (`Tactics.puffRange`) drifting as they are drawn to, and the pressure map as the water shows it (`SeatView.pressure`,
/// at most `PressureMap.refreshTicks` old). No key is read: her shift off the course's axis (the public mean wind)
/// fades back to it over `BotTunables.plannerShiftReversion` seconds, as a player expects an oscillating breeze to swing
/// back, and the rest of the leg past her horizon is reckoned in the mean wind.
///
/// Rules and the fleet stay the heuristics' (`upwindTack`'s tack interval, fleet tactics, cover, laylines and corridor,
/// and everything off the open beat and run): the planner is asked only where they would weigh the shift.
///
/// Skill is depth (`Depth`): a live bot plans from `BotTunables.plannerStart` through the Regional band (the bundled file:
/// its top, so every National bot and no Regional one), her horizon growing to the top of the National band
/// (`depth(skill:tunables:)`); below it, and for the suite's profiles, she keeps the heuristics.
struct BotPlanner: Sendable, Equatable {
    /// How far ahead she plans.
    struct Depth: Sendable, Equatable {
        /// Seconds each option is sailed forward.
        var horizon: Double
    }

    /// The forward sail's step, seconds: coarser than the race's tick, as cheap as it can be and still turn her.
    static let step = 0.1
    /// Planning is costly: she plans again only this often, seconds, and holds the answer between.
    static let replanSeconds = 1.0

    /// Her depth at `skill`, a live bot's, by `tunables` (`plannerStart` through the Regional band, her horizon growing
    /// from `plannerStartHorizon` there to `plannerHorizon` at the top of the National band); nil below the start, or
    /// when `plannerHorizon` is 0: no bot plans.
    static func depth(skill: Double, tunables: BotTunables) -> Depth? {
        guard tunables.plannerHorizon > 0 else { return nil }
        let regional = BotTier.regional.skillBand
        let national = BotTier.national.skillBand
        let start = regional.lowerBound + tunables.plannerStart * (regional.upperBound - regional.lowerBound)
        guard skill >= start else { return nil }
        let w = BotWeaknesses.ramp(skill, from: start, to: national.upperBound)
        let horizon = tunables.plannerStartHorizon + (tunables.plannerHorizon - tunables.plannerStartHorizon) * w
        return horizon >= step ? Depth(horizon: horizon) : nil
    }

    /// Advance calls one plan sails: two options, each `horizon / step` steps. What the budget test holds (#583).
    static func steps(_ depth: Depth) -> Int { 2 * Int((depth.horizon / step).rounded(.up)) }

    /// The wind she can see (#583: information, not foresight), built from her seat's view alone.
    struct PerceivedWind {
        /// The wind at her boat now: direction, and its speed less the puffs on her.
        let direction: Double
        /// The course's axis (`CourseLayout.axis`, the public mean wind), and how fast her shift off it fades, seconds
        /// (an e-folding time); 0, it never does.
        let mean: Double
        let reversion: Double
        let baseSpeed: Double
        let here: Pressure?
        let pressure: SeatView.PressureMap?
        let puffs: [SeatView.DrawnPuff]

        /// From `view`, seeing puffs and pressure out to `range` metres (`Tactics.puffRange`); none when 0.
        init(_ view: SeatView, range: Double, reversion: Double = 0) {
            let b = view.own
            direction = b.windDirection
            mean = view.course.axis
            self.reversion = reversion
            pressure = range > 0 ? view.pressure : nil
            here = pressure?.sample(at: b.position)
            puffs = range > 0 ? view.puffs.filter { ($0.center - b.position).length - $0.radius <= range } : []
            baseSpeed = b.polarWindSpeed / Self.puffFactor(puffs, at: b.position, after: 0)
        }

        /// e^−x for x ≥ 0, from the stdlib-free series RegattaBots keeps to (a few terms of `(1 + x/n)^−n` are close
        /// enough for a forecast): 1 at 0, falling to 0.
        static func fade(_ x: Double) -> Double {
            guard x > 0 else { return 1 }
            guard x < 40 else { return 0 }
            var y = 1 + x / 64
            for _ in 0..<6 { y *= y }
            return 1 / y
        }

        /// A puff's or lull's change on the wind, as the race's `(1 − d²)²` falloff: its tone at its centre.
        static func puffFactor(_ puffs: [SeatView.DrawnPuff], at p: Vec2, after seconds: Double) -> Double {
            var factor = 1.0
            for puff in puffs {
                let offset = p - (puff.center + puff.drift * seconds)
                let d2 = offset.lengthSquared / (puff.radius * puff.radius)
                guard d2 < 1 else { continue }
                factor += puff.tone * (1 - d2) * (1 - d2)
            }
            return max(factor, 0.05)
        }

        /// The wind at `p`, `seconds` from now: hers, scaled and turned by the pressure there against hers, and the
        /// puffs drifted there.
        func at(_ p: Vec2, after seconds: Double) -> (direction: Double, speed: Double) {
            var direction = self.direction
            if reversion > 0 { direction = mean + wrapAngle(self.direction - mean) * Self.fade(seconds / reversion) }
            var speed = baseSpeed
            if let here, let there = pressure?.sample(at: p), here.factor > 0 {
                speed *= there.factor / here.factor
                direction += wrapAngle(there.turn - here.turn)
            }
            return (wrapAngle(direction), speed * Self.puffFactor(puffs, at: p, after: seconds))
        }
    }

    /// The boat as the forward sail moves her.
    struct Sailed {
        var state: BoatDynamics.State
        var seconds: Double
    }

    /// `start` sailed for `seconds` steering `twa` with her boom on `side` (`BoomSide`): a proportional helm at the
    /// class's autohelm gain, through a tack hard (0.7), every other turn gently (0.35), letting go stopped in the no-go.
    static func sail(_ start: BoatDynamics.State, side: BoomSide, twa: Double, for seconds: Double, wind: PerceivedWind,
                     boatClass: BoatClass) -> Sailed {
        var state = start
        var t = 0.0
        let gain = boatClass.steering.autohelm.gain
        let noGo = BoatDynamics.noGoAngle(boatClass.polar)
        while t < seconds - 1e-9 {
            let w = wind.at(state.position, after: t)
            let relative = wrapAngle(w.direction - state.heading)
            let desired = side == .port ? wrapAngle(w.direction - twa) : wrapAngle(w.direction + twa)
            var rudder = 0.0
            if !(state.speed < 0.5 && abs(relative) < noGo) {
                let tacking = BoomSide.leeward(ofRelativeWind: wrapAngle(w.direction - desired)) != state.boomSide
                    && abs(relative) < .pi / 2
                let cap = tacking ? 0.7 : 0.35
                rudder = (wrapAngle(desired - state.heading) * gain).clamped(to: -cap...cap)
            }
            state = BoatDynamics.advance(state, control: BoatDynamics.Control(rudder: rudder),
                                         env: BoatDynamics.Environment(windDirection: w.direction, windSpeed: w.speed),
                                         boatClass: boatClass, dt: step)
            t += step
        }
        return Sailed(state: state, seconds: t)
    }

    /// Seconds from `sailed` to `target`: what it took, plus the polar's best she can hold (`SteadyPolars`) from where it
    /// left her in the wind she sees there (two tacks or gybes where it can't be fetched), plus what her speed below
    /// her target there costs to make up.
    static func seconds(_ sailed: Sailed, to target: Vec2, wind: PerceivedWind, boatClass: BoatClass,
                        polars: inout SteadyPolars) -> Double {
        // The rest of the leg in the wind she expects for it: the mean's, where her shift fades.
        let w = wind.at(sailed.state.position, after: wind.reversion > 0 ? 1e9 : sailed.seconds)
        let polar = polars.polar(tws: w.speed, boatClass: boatClass)
        let run = target - sailed.state.position
        let distance = run.length
        let off = abs(wrapAngle(w.direction - run.bearing))
        func twoLegs(_ optimum: (twa: Double, speed: Double)) -> Double {
            let axis = optimum.twa < .pi / 2 ? 0.0 : Double.pi
            let alongAxis = Vec2.heading(off - axis).y
            return distance * alongAxis / Vec2.heading(optimum.twa - axis).y / max(optimum.speed, 0.1)
        }
        let rest: Double
        if off < polar.up.twa {
            rest = twoLegs(polar.up)
        } else if off > polar.down.twa {
            rest = twoLegs(polar.down)
        } else {
            rest = distance / max(polar.speed(twa: off), 0.1)
        }
        let relative = abs(wrapAngle(w.direction - sailed.state.heading))
        let target = polar.speed(twa: relative)
        let deficit = target > 0.1 ? max(0, target - sailed.state.speed) / target * boatClass.momentum.speedingUp : 0
        return sailed.seconds + rest + deficit
    }

    /// One plan (#583 stage 3): her view now, the groove's angle `twa` she sails on either side, whether she planes, where
    /// she sails for, her depth, how far she sees (`Tactics.puffRange`) and how fast she expects her shift to fade, and
    /// the steady polars she has worked out so far. Kept as her last plan (`BotBrain.lastPlanRequest`), so the budget test
    /// (`PlannerTests.plannerStaysWithinTheTickBudget`) can time it again, outside the bot, which reads no clock.
    struct Request: Sendable {
        let view: SeatView
        let twa: Double
        let isPlaning: Bool
        let target: Vec2
        let depth: Depth
        let range: Double
        let reversion: Double
        let polars: SteadyPolars

        /// The seconds turning now gains on holding on, to `target`: positive, the turn gets her there sooner.
        func gain() -> Double { run().gain }

        /// `gain()`, and the steady polars with any it worked out added, for her next plan.
        func run() -> (gain: Double, polars: SteadyPolars) {
            BotPlanner.gain(self)
        }
    }

    private static func gain(_ request: Request) -> (gain: Double, polars: SteadyPolars) {
        let (view, twa, isPlaning, target, depth) = (request.view, request.twa, request.isPlaning, request.target, request.depth)
        let (range, reversion) = (request.range, request.reversion)
        var polars = request.polars
        let b = view.own
        let wind = PerceivedWind(view, range: range, reversion: reversion)
        let kite: Spinnaker = view.boatClass.spinnaker.map { b.twa >= $0.hoistAboveTWA ? .up : .down } ?? .down
        let start = BoatDynamics.State(position: b.position, heading: b.heading, speed: b.speed, rudder: b.rudder,
                                       boomSide: b.boomSide, isPlaning: isPlaning, spinnaker: kite)
        let hold = sail(start, side: b.boomSide, twa: twa, for: depth.horizon, wind: wind, boatClass: view.boatClass)
        let turn = sail(start, side: b.boomSide.opposite, twa: twa, for: depth.horizon, wind: wind, boatClass: view.boatClass)
        let gain = seconds(hold, to: target, wind: wind, boatClass: view.boatClass, polars: &polars)
            - seconds(turn, to: target, wind: wind, boatClass: view.boatClass, polars: &polars)
        return (gain, polars)
    }
}
