import Foundation
@testable import RegattaCore

/// #458: a hand-steered tack measured from `BoatDynamics` directly, as #456 measured its findings (#465's sweep): a
/// boat close-hauled on port boom at `entry` of her groove target, a helm profile on the rudder and a twin that sails on
/// in her groove. The loss is how far the twin has made good upwind beyond her, in hull lengths. #456's figures are
/// means over seven winds of the same strength: steady, and the gusty-offshore wind at the boat in six races (`WindBook`),
/// its strength scaled to the cell's. The helm profiles are a small set of the sweep's (`Helm`).
enum HandTack {
    static let dt = Race.dt

    /// How the helm steers the tack.
    enum Helm: CaseIterable {
        /// Full rudder until a fifth of a second's turn short of the new groove, then the hold law.
        case slam
        /// The same at 75 % and 50 % rudder.
        case rudder75, rudder50
        /// Full rudder, easing to a quarter over the last 20° (35°) before the groove, then the hold law.
        case smooth20, smooth35
        /// Bear off 10° or 15° first and hold it 3 s or 5 s, then a full-rudder tack.
        case bear10x3, bear10x5, bear15x3, bear15x5
        /// Full rudder for 25 % (60 %) of the turn, then the rudder centred for good: she is left in irons.
        case release25, release60
        /// #456's release helms as the sweep sailed them: full rudder whenever she is short of 25 % (60 %) of the turn,
        /// centred past it. Falling back off the wind takes her short of it again, so the helm takes full rudder again
        /// and holds her at the edge of the no-go: a held rudder, not a centred one.
        case release25Probe, release60Probe

        /// The profiles a best tack is taken over: full, 75 %, 50 % and smoothed.
        static let best: [Helm] = [.slam, .rudder75, .rudder50, .smooth20, .smooth35]
        static let bear: [Helm] = [.bear10x3, .bear10x5, .bear15x3, .bear15x5]

        var seconds: Double {
            switch self {
            case .release25, .release60, .release25Probe, .release60Probe: 45
            default: 25
            }
        }
    }

    /// The wind a run sails in: `knots`, steady (`seed` nil) or gusty-offshore's shape from `WindBook`.
    struct Cell: Hashable {
        var knots: Double
        var entry: Double
        var seed: Int?

        /// #456's cells for one strength and entry: steady and the six gusty winds.
        static func all(knots: Double, entry: Double = 1) -> [Cell] {
            ([nil] + (1...6).map(Optional.some)).map { Cell(knots: knots, entry: entry, seed: $0) }
        }
    }

    struct Metrics {
        /// Loss against the twin at 20 s and 25 s, hull lengths.
        var loss20 = 0.0
        var loss25 = 0.0
        /// Seconds she spent under 30 % of her new groove's target speed inside the no-go (#456's "stuck").
        var stuck = 0.0
    }

    /// One tack by `helm` in `cell`'s wind.
    static func run(_ helm: Helm, _ cell: Cell, boatClass boat: BoatClass) -> Metrics {
        let ticks = Int((helm.seconds / dt).rounded())
        let wind0 = WindBook.shared.sample(knots: cell.knots, seed: cell.seed, tick: 0)
        let angle0 = Autohelm.grooveAngle(.upwind, tws: wind0.speed, boatClass: boat)
        let boom = BoomSide.port
        let heading0 = compass(wind: wind0.direction, sailingAngle: angle0, boom: boom)
        let target = BoatDynamics.polarTarget(relativeWind: angle0, boomSide: boom, tws: wind0.speed, isPlaning: false,
                                              spinnaker: .down, boatClass: boat)
        var helmState = BoatDynamics.State(heading: heading0, speed: cell.entry * target, boomSide: boom)
        var twinState = helmState
        let signed = Autohelm.tackOrGybe(sailingAngle: angle0).rudder(sailingAngle: angle0, boomSide: boom, tws: wind0.speed,
                                                                      boatClass: boat)
        let turnSign = signed >= 0 ? 1.0 : -1.0
        let newBoom = boom.opposite
        let along = Vec2.heading(wind0.direction)
        let noGo = BoatDynamics.noGoAngle(boat.polar)
        var pilot = Pilot(helm: helm, boat: boat, turnSign: turnSign, startBoom: boom)
        var metrics = Metrics()
        for tick in 0..<ticks {
            let (dir, tws) = WindBook.shared.sample(knots: cell.knots, seed: cell.seed, tick: tick)
            let env = BoatDynamics.Environment.constant(windDirection: dir, windSpeed: tws)
            let angle = Autohelm.grooveAngle(.upwind, tws: tws, boatClass: boat)
            let command = pilot.command(t: Double(tick) * dt, heading: helmState.heading, speed: helmState.speed,
                                        wind: dir, angle: angle)
            let origin = compass(wind: dir, sailingAngle: angle, boom: boom)
            helmState = BoatDynamics.advance(helmState, control: .init(rudder: command), env: env, boatClass: boat, dt: dt)
            twinState = BoatDynamics.advance(twinState, control: .init(rudder: holdLaw(heading: twinState.heading, aim: origin)),
                                             env: env, boatClass: boat, dt: dt)
            let now = Double(tick + 1) * dt
            let loss = (twinState.position.dot(along) - helmState.position.dot(along)) / boat.hull.length
            if abs(now - 20) < dt / 2 { metrics.loss20 = loss }
            if abs(now - 25) < dt / 2 { metrics.loss25 = loss }
            let grooveTarget = BoatDynamics.polarTarget(relativeWind: newBoom == .port ? angle : -angle, boomSide: newBoom,
                                                        tws: tws, isPlaning: false, spinnaker: .down, boatClass: boat)
            if helmState.speed < 0.3 * max(grooveTarget, 1e-6), abs(wrapAngle(dir - helmState.heading)) < noGo {
                metrics.stuck += dt
            }
        }
        return metrics
    }

    /// #459: a tack (from the upwind groove) or a gybe (from the downwind groove, after `warmUp` seconds sailing it) as
    /// a bot's hand turns it (`BotBrain.handTurning`): `fraction` of full rudder, eased to a quarter of it over the last
    /// `ease` degrees (0: held to the end), to `over` degrees past the new groove, then the hold law. The loss against
    /// the twin, hull lengths made good to windward (to leeward for a gybe), `seconds` after the rudder goes over, and
    /// the seconds stuck (`Metrics.stuck`).
    static func turn(gybe: Bool, fraction: Double, ease: Double = 0, over: Double = 0, cell: Cell,
                     boatClass boat: BoatClass, seconds: Double? = nil, warmUp: Double = 15) -> (loss: Double, stuck: Double) {
        let groove: Autohelm.Groove = gybe ? .downwind : .upwind
        let warm = gybe ? Int((warmUp / dt).rounded()) : 0
        let ticks = warm + Int(((seconds ?? (gybe ? 30 : 25)) / dt).rounded())
        let wind0 = WindBook.shared.sample(knots: cell.knots, seed: cell.seed, tick: 0)
        let angle0 = Autohelm.grooveAngle(groove, tws: wind0.speed, boatClass: boat)
        let boom = BoomSide.port
        let target = BoatDynamics.polarTarget(relativeWind: angle0, boomSide: boom, tws: wind0.speed, isPlaning: false,
                                              spinnaker: .down, boatClass: boat)
        var helmState = BoatDynamics.State(heading: compass(wind: wind0.direction, sailingAngle: angle0, boom: boom),
                                           speed: cell.entry * target, boomSide: boom)
        var twinState = helmState
        // Turning to starboard (+) luffs her with the boom to port.
        let turnSign: Double = gybe ? -1 : 1
        let along = Vec2.heading(wind0.direction) * (gybe ? -1 : 1)
        let noGo = BoatDynamics.noGoAngle(boat.polar)
        var done = false
        var stuck = 0.0
        for tick in 0..<ticks {
            let (dir, tws) = WindBook.shared.sample(knots: cell.knots, seed: cell.seed, tick: tick)
            let env = BoatDynamics.Environment.constant(windDirection: dir, windSpeed: tws)
            let angle = Autohelm.grooveAngle(groove, tws: tws, boatClass: boat)
            let origin = compass(wind: dir, sailingAngle: angle, boom: boom)
            let aim = compass(wind: dir, sailingAngle: angle, boom: boom.opposite)
            var command = holdLaw(heading: helmState.heading, aim: tick < warm ? origin : aim)
            if tick >= warm, !done {
                var remaining = headingRemaining(from: helmState.heading, to: aim + turnSign * deg2rad(over), turnSign: turnSign)
                if helmState.boomSide == boom, remaining < 0 { remaining += 2 * .pi }
                var rudder = fraction
                var end = fraction * boat.steering.turnRate(speed: helmState.speed) * 0.2
                if ease > 5 {
                    end = max(end * 0.25, deg2rad(5))
                    if remaining < deg2rad(ease) {
                        rudder *= 1 + (0.25 - 1) * ((deg2rad(ease) - remaining) / (deg2rad(ease) - deg2rad(5))).clamped(to: 0...1)
                    }
                }
                if remaining > end { command = quantise(turnSign * rudder) } else { done = true }
            }
            helmState = BoatDynamics.advance(helmState, control: .init(rudder: command), env: env, boatClass: boat, dt: dt)
            twinState = BoatDynamics.advance(twinState, control: .init(rudder: holdLaw(heading: twinState.heading, aim: origin)),
                                             env: env, boatClass: boat, dt: dt)
            guard tick >= warm, !gybe else { continue }
            let grooveTarget = BoatDynamics.polarTarget(relativeWind: -angle, boomSide: boom.opposite, tws: tws,
                                                        isPlaning: false, spinnaker: .down, boatClass: boat)
            if helmState.speed < 0.3 * max(grooveTarget, 1e-6), abs(wrapAngle(dir - helmState.heading)) < noGo { stuck += dt }
        }
        return ((twinState.position.dot(along) - helmState.position.dot(along)) / boat.hull.length, stuck)
    }

    static func mean(_ cells: [Cell], _ value: (Cell) -> Double) -> Double {
        cells.map(value).reduce(0, +) / Double(cells.count)
    }

    /// #456's best tack: in each cell (10 kn, entry 1) the least 25 s loss of `Helm.best`, averaged.
    static func best(boatClass: BoatClass) -> Double {
        mean(Cell.all(knots: 10)) { cell in Helm.best.map { run($0, cell, boatClass: boatClass).loss25 }.min()! }
    }

    /// The mean 25 s loss of `helm` at 10 kn, entry 1.
    static func loss(_ helm: Helm, boatClass: BoatClass) -> Double {
        mean(Cell.all(knots: 10)) { run(helm, $0, boatClass: boatClass).loss25 }
    }

    /// #456's gentle gap: in each cell (10 kn, entry 1) how much the worse of 50 % rudder and `smooth20` loses beyond
    /// the best, averaged.
    static func gentleGap(boatClass: BoatClass) -> Double {
        mean(Cell.all(knots: 10)) { cell in
            let best = Helm.best.map { run($0, cell, boatClass: boatClass).loss25 }.min()!
            return max(run(.rudder50, cell, boatClass: boatClass).loss25, run(.smooth20, cell, boatClass: boatClass).loss25) - best
        }
    }

    /// At entry 0.7: how much a slam loses beyond the best bear-off-first tack at 20 s, averaged over the cells. #456's
    /// light-air gap is this at 6 kn; its strong-air gap is minus this at 14 kn.
    static func bearOffGap(knots: Double, boatClass: BoatClass) -> Double {
        mean(Cell.all(knots: knots, entry: 0.7)) { cell in
            let slam = run(.slam, cell, boatClass: boatClass).loss20
            let bear = Helm.bear.map { run($0, cell, boatClass: boatClass).loss20 }.min()!
            return slam - bear
        }
    }

    /// #456's stuck figure: the mean of the two release helms over the cells at 10 kn, entry 1.
    static func stuck(_ helms: [Helm] = [.release25, .release60], boatClass: BoatClass) -> Double {
        mean(Cell.all(knots: 10)) { cell in
            helms.map { run($0, cell, boatClass: boatClass).stuck }.reduce(0, +) / Double(helms.count)
        }
    }

    // MARK: - The helm

    struct Pilot {
        let helm: Helm
        let boat: BoatClass
        let turnSign: Double
        let startBoom: BoomSide
        var phase = 0
        var mark = 0.0
        var initialRemaining: Double?
        var released = false

        init(helm: Helm, boat: BoatClass, turnSign: Double, startBoom: BoomSide) {
            self.helm = helm
            self.boat = boat
            self.turnSign = turnSign
            self.startBoom = startBoom
        }

        /// The rudder for a boat on `heading` at `speed` in wind from `wind`, whose upwind groove is `angle` off it.
        mutating func command(t: Double, heading: Double, speed: Double, wind: Double, angle: Double) -> Double {
            let aim = compass(wind: wind, sailingAngle: angle, boom: startBoom.opposite)
            let remaining = headingRemaining(from: heading, to: aim, turnSign: turnSign)
            if initialRemaining == nil { initialRemaining = max(remaining, 1e-6) }
            switch helm {
            case .slam: return held(heading: heading, speed: speed, aim: aim, magnitude: 1)
            case .rudder75: return held(heading: heading, speed: speed, aim: aim, magnitude: 0.75)
            case .rudder50: return held(heading: heading, speed: speed, aim: aim, magnitude: 0.5)
            case .smooth20: return smooth(heading: heading, aim: aim, ease: 20)
            case .smooth35: return smooth(heading: heading, aim: aim, ease: 35)
            case .bear10x3: return bear(t: t, heading: heading, speed: speed, wind: wind, angle: angle, aim: aim, degrees: 10, hold: 3)
            case .bear10x5: return bear(t: t, heading: heading, speed: speed, wind: wind, angle: angle, aim: aim, degrees: 10, hold: 5)
            case .bear15x3: return bear(t: t, heading: heading, speed: speed, wind: wind, angle: angle, aim: aim, degrees: 15, hold: 3)
            case .bear15x5: return bear(t: t, heading: heading, speed: speed, wind: wind, angle: angle, aim: aim, degrees: 15, hold: 5)
            case .release25, .release60, .release25Probe, .release60Probe:
                let fraction = helm == .release25 || helm == .release25Probe ? 0.25 : 0.6
                let initial = initialRemaining ?? 1e-6
                if (initial - remaining) / initial >= fraction { released = true }
                let latched = helm == .release25 || helm == .release60
                return released && (latched || (initial - remaining) / initial >= fraction) ? 0 : quantise(turnSign)
            }
        }

        func held(heading: Double, speed: Double, aim: Double, magnitude: Double) -> Double {
            let remaining = headingRemaining(from: heading, to: aim, turnSign: turnSign)
            let lead = magnitude * boat.steering.turnRate(speed: speed) * 0.2
            if remaining < lead { return holdLaw(heading: heading, aim: aim) }
            return quantise(turnSign * magnitude)
        }

        func smooth(heading: Double, aim: Double, ease: Double) -> Double {
            let remaining = headingRemaining(from: heading, to: aim, turnSign: turnSign)
            let start = deg2rad(ease), five = deg2rad(5)
            if remaining > start { return quantise(turnSign) }
            if remaining > five {
                let t = (start - remaining) / (start - five)
                return quantise(turnSign * (1 + (0.25 - 1) * t))
            }
            return holdLaw(heading: heading, aim: aim)
        }

        mutating func bear(t: Double, heading: Double, speed: Double, wind: Double, angle: Double, aim: Double,
                           degrees: Double, hold: Double) -> Double {
            let away = -turnSign
            let bearAim = compass(wind: wind, sailingAngle: angle + deg2rad(degrees), boom: startBoom)
            if phase == 0 {
                let remaining = headingRemaining(from: heading, to: bearAim, turnSign: away)
                if remaining < boat.steering.turnRate(speed: speed) * 0.2 { phase = 1; mark = t + hold }
                return quantise(away)
            }
            if phase == 1 {
                if t >= mark { phase = 2 }
                return holdLaw(heading: heading, aim: bearAim)
            }
            return held(heading: heading, speed: speed, aim: aim, magnitude: 1)
        }
    }

    static func compass(wind: Double, sailingAngle: Double, boom: BoomSide) -> Double {
        wrapAngle(wind - (boom == .port ? sailingAngle : -sailingAngle))
    }

    static func headingRemaining(from heading: Double, to aim: Double, turnSign: Double) -> Double {
        let delta = wrapAngle(aim - heading)
        return turnSign >= 0 ? delta : -delta
    }

    /// The rudder as a held input carries it, centred inside the autohelm's dead band.
    static func quantise(_ raw: Double) -> Double {
        let held = BoatInput(rudder: raw).rudderValue
        return abs(held) <= Autohelm.deadBand ? 0 : held
    }

    /// Steers for `aim`: a tenth of full rudder per degree off it.
    static func holdLaw(heading: Double, aim: Double) -> Double {
        quantise((0.1 * rad2deg(wrapAngle(aim - heading))).clamped(to: -1...1))
    }
}

/// #456's gusty winds: gusty-offshore@7's wind at one point of the default venue over 150 s of six races (race seeds
/// 1–6), its direction about its mean and its strength as a share of its mean, each read from its own offset. Steady
/// (seed nil) is the cell's strength from 0.
final class WindBook: @unchecked Sendable {
    static let shared = WindBook()

    struct Series {
        var direction: [Double]
        var scale: [Double]
        var offset: Int
    }

    private let series: [Int: Series]

    private init() {
        var series: [Int: Series] = [:]
        for seed in 1...6 { series[seed] = try! Self.record(seed) }
        self.series = series
    }

    func sample(knots: Double, seed: Int?, tick: Int) -> (direction: Double, speed: Double) {
        let speed = metresPerSecond(knots: knots)
        guard let seed, let s = series[seed] else { return (0, speed) }
        let i = (s.offset + tick) % s.scale.count
        return (s.direction[i], s.scale[i] * speed)
    }

    static func record(_ seed: Int) throws -> Series {
        let conditions = try ConditionsFile.bundled(id: "gusty-offshore", version: 7)
        let venue = try VenueFile.bundled(id: "dev-venue", version: 7)
        let setup = try RaceSetup(raceSeed: RaceSeed(UInt64(seed)), seats: [.human, .human], laps: 1,
                                  startSequenceTicks: 1, venue: venue.ref, conditions: conditions.ref)
        let race = try Race(setup: setup, files: try RaceFiles(resolving: setup),
                            mode: .authoritative(windSeed: WindSeed(UInt64(seed) &* 0x9E37_79B9_7F4A_7C15 &+ 1)))
        race.step()
        let point = race.boats[0].position
        var snap = race.exportSnapshot()
        for i in snap.seats.indices {
            snap.seats[i].boat.speed = 0
            snap.seats[i].boat.rudder = 0
            snap.seats[i].boat.desiredRudder = 0
            snap.seats[i].heldInput = .neutral
        }
        try race.importSnapshot(snap)
        let n = 150 * Race.tickRate
        var direction: [Double] = [], speed: [Double] = []
        for _ in 0..<n {
            race.step()
            let wind = race.groundWind(at: point)
            direction.append(wind.direction)
            speed.append(wind.speed)
        }
        let meanSpeed = speed.reduce(0, +) / Double(n)
        var east = 0.0, north = 0.0
        for angle in direction {
            east += Foundation.sin(angle)
            north += Foundation.cos(angle)
        }
        let mean = atan2(east / Double(n), north / Double(n))
        var mix = UInt64(seed) &* 0x9E37_79B9_7F4A_7C15 &+ 1
        mix = mix &* 6364136223846793005 &+ 1
        let room = max((150 - 60) * Race.tickRate, 1)
        return Series(direction: direction.map { wrapAngle($0 - mean) },
                      scale: speed.map { meanSpeed > 1e-6 ? $0 / meanSpeed : 1 }, offset: Int(mix % UInt64(room)))
    }
}
