import Foundation
import RegattaBots
import RegattaCore

/// The oracle (#583): the fastest lap a beam search finds for one boat on a seed's course, knowing the whole seeded
/// wind, pressure and current (an offline tool may read the whole key chain; ADR 0001's limit is on live bots). It never
/// ships: it lives here, not in RegattaBots.
///
/// The world it searches is the seed's race for one boat (`TimeTrialCourse`): no fleet, so no rules but the marks' and
/// the edges'. Each node is that race's world (`WorldSnapshot`) at a checkpoint and who is steering; a node's children
/// sail each action from it to the next checkpoint on a copy of the race, through the race's own step
/// (`BoatDynamics.advance` for the boat, the race for the wind, the current and the course), so what the search finds is
/// a lap the race sails, bit for bit, when her inputs are sent again (`TimeTrialCourse.replay`).
///
/// - Checkpoints every `checkpointSeconds`, and sooner on an event: she reaches a mark's zone or a rounding stage, crosses
///   a layline, or the wind at her turns by `shiftCut` or changes speed by `puffCut` since the last checkpoint (a shift
///   knot or a puff's edge reaching her).
/// - Actions (`Action`), human-sendable: a held rudder every `BotDriver.decisionInterval` ticks from a helm that steers an
///   angle to the wind or a waypoint (`Helm`), or the inputs the executor or the tactician would send from here, her own
///   driver carried on from the node (`BotDriver`; a fresh one taking over the boat after the helm has had her). Nothing
///   a player couldn't send.
/// - Score: each child is sailed on `horizonSeconds` more as the executor would sail her, and scored there by its
///   estimated finish (`estimatedFinish`): the time, plus the time the polar's best needs from there to the leg's target
///   in the wind on the water and on round the course's later legs in the mean wind, plus the time her speed below her
///   target costs to make up.
/// - The beam keeps the `beamWidth` best children, every tack kept and one a place (`select`), and always the executor's
///   and the tactician's own laps, unbroken from the gun: so the lap it finds is never slower than either's.
public struct Oracle {
    public struct Options: Hashable, Sendable {
        public var checkpointSeconds: Double
        public var horizonSeconds: Double
        public var beamWidth: Int
        /// Checkpoints on events, as well as on the clock.
        public var eventCheckpoints: Bool

        public init(checkpointSeconds: Double = 2, horizonSeconds: Double = 20, beamWidth: Int = 16,
                    eventCheckpoints: Bool = true) {
            self.checkpointSeconds = checkpointSeconds
            self.horizonSeconds = horizonSeconds
            self.beamWidth = beamWidth
            self.eventCheckpoints = eventCheckpoints
        }
    }

    /// What she does at a checkpoint, until the next.
    public enum Action: CaseIterable, Hashable, Sendable {
        /// Hold the course her helm is steering.
        case hold
        /// The groove on this tack: the polar's best VMG angle upwind or downwind, whichever the leg's target needs, or
        /// the angle that fetches it on a reach.
        case groove
        /// Head up, and bear away, by `angleStep`.
        case pinch
        case foot
        /// Head up to plane: `planingStep` hotter on a run.
        case headUp
        /// Tack or gybe: the groove on the other tack.
        case turn
        /// Steer for the leg's waypoint (`Helm.waypoint`), or the groove where it can't be sailed straight.
        case waypoint
        /// The same at a gate, by its other mark.
        case otherGateMark
        /// Send what the bot of this profile would: `executor` or `tactician`.
        case sail(BotProfile)

        public static let allCases: [Action] = [.hold, .groove, .pinch, .foot, .headUp, .turn, .waypoint, .otherGateMark]
            + Oracle.profiles.map(Action.sail)
    }

    /// The bots whose decisions are actions, and whose own laps the beam always keeps.
    public static let profiles: [BotProfile] = [.executor, .tactician]
    /// The bot the horizon sails as.
    public static let rolloutProfile = BotProfile.executor

    /// What her helm steers.
    public enum Course: Hashable, Sendable {
        /// This true wind angle on the side her boom gives for `boomSide`: radians, 0…π.
        case angle(boomSide: BoomSide, twa: Double)
        /// The rounding waypoint of the leg she is on; at a gate, by mark `gateMark` (0 the left, 1 the right).
        case waypoint(gateMark: Int)
        /// A fixed point, steered for as a waypoint is: the start oracle's spot on the line (#584).
        case point(Vec2)
    }

    /// One input she sends: a held input or a tap, for the tick it applies at.
    public struct Input: Hashable, Sendable {
        public var tick: Int
        public var held: BoatInput?
        public var tap: BoatTap?
    }

    /// What a horizon that fouls a mark adds to its child's score: about a penalty turn.
    public static let horizonFoulSeconds = 30.0
    public static let angleStep = deg2rad(4)
    public static let planingStep = deg2rad(15)
    public static let shiftCut = deg2rad(4)
    public static let puffCut = 0.1
    /// The least a checkpoint is apart, an event or not.
    public static let minimumSegmentSeconds = 0.5

    public let course: TimeTrialCourse
    public let options: Options

    public init(course: TimeTrialCourse, options: Options = Options()) {
        self.course = course
        self.options = options
        laterLegs = Self.laterLegSeconds(course)
    }

    /// The lap it found: the inputs she sends, and its finish by the plan.
    public struct Plan: Sendable {
        public var inputs: [Input]
        /// Seconds after the gun she finishes; nil if no node finished by the close.
        public var finishSeconds: Double?
        /// Nodes sailed (children and their horizons), the search's cost.
        public var nodes: Int
        /// Ticks the race stepped in the search.
        public var ticks: Int
    }

    /// A node's sent inputs, as a chain back to the start: a child shares her parent's.
    final class Trail: @unchecked Sendable {
        let parent: Trail?
        let inputs: [Input]

        init(parent: Trail?, inputs: [Input]) {
            self.parent = parent
            self.inputs = inputs
        }

        var all: [Input] {
            var segments: [[Input]] = []
            var node: Trail? = self
            while let trail = node {
                segments.append(trail.inputs)
                node = trail.parent
            }
            return segments.reversed().flatMap { $0 }
        }
    }

    /// Who steers a segment: her helm, or a bot (her driver and its profile).
    enum Pilot {
        case helm(Helm)
        case bot(BotDriver, BotProfile)
    }

    struct Node {
        var world: WorldSnapshot
        var helm: Helm
        /// The bot that sailed the last segment, carried on by a child that sails as the same profile.
        var bot: (driver: BotDriver, profile: BotProfile)?
        /// The profile whose own lap this is, every segment sailed as her from the gun; nil for any other.
        var pure: BotProfile?
        var trail: Trail?
        var score: Double
        var finish: Double?
    }

    /// Seconds the polar's best needs, in the mean wind, from leg k's target on round the rest of the course.
    private let laterLegs: [Double]

    /// A bot of `profile` taking the boat over where she is.
    private func takeOver(_ profile: BotProfile) -> BotDriver {
        guard let driver = TimeTrialSailor.profile(profile).driver(raceSeed: course.setup.raceSeed) else {
            preconditionFailure("a profile always has a driver")
        }
        return driver.takingOver()
    }

    /// Searches the seed's course from the start to the finish.
    public func search() throws -> Plan {
        var race = try course.race()
        var nodes = 0
        var ticks = 0
        let up = course.steady(tws: race.boats[0].polarWindSpeed(in: course.boatClass)).up.twa
        let root = Node(world: course.gun, helm: Helm(course: .angle(boomSide: .port, twa: up)), bot: nil, pure: nil,
                        trail: nil, score: 0, finish: nil)
        var beam = [root]
        var best: Node?
        var levels = 0
        while !beam.isEmpty {
            levels += 1
            // A fresh copy of the race now and then: the race logs every input it applies.
            if levels.isMultiple(of: 64) { race = try course.race() }
            var children: [Node] = []
            for node in beam {
                for action in Action.allCases {
                    var child: Node
                    switch action {
                    case .sail(let profile):
                        let driver = node.bot.flatMap { $0.profile == profile ? $0.driver : nil } ?? takeOver(profile)
                        child = try sail(from: node, pilot: .bot(driver, profile), race: race, ticks: &ticks)
                        child.pure = node.pure == profile || node.world.tick == course.gun.tick ? profile : nil
                    default:
                        guard let helm = node.helm.after(action, world: node.world, oracle: self) else { continue }
                        child = try sail(from: node, pilot: .helm(helm), race: race, ticks: &ticks)
                    }
                    nodes += 1
                    if let finish = child.finish {
                        if best.map({ finish < $0.finish! }) ?? true { best = child }
                        continue
                    }
                    // A bot's own lap goes on whatever it scores: one that fouls a mark serves her turn and finishes.
                    guard child.score.isFinite || child.pure != nil else { continue }
                    if options.horizonSeconds > 0, child.score.isFinite {
                        child.score = try horizonScore(child, race: race, ticks: &ticks)
                        nodes += 1
                    }
                    guard child.score.isFinite || child.pure != nil else { continue }
                    children.append(child)
                }
            }
            beam = select(children)
            // Done once nothing in the beam can still beat the best finish found.
            if let best, let finish = best.finish, beam.allSatisfy({ $0.score >= finish && $0.pure == nil }) { break }
            if beam.allSatisfy({ $0.world.tick >= TimeTrialCourse.capTicks }) { break }
        }
        return Plan(inputs: best?.trail?.all ?? [], finishSeconds: best?.finish, nodes: nodes, ticks: ticks)
    }

    /// The best `beamWidth` of `children` by score: first each bot's own lap (`Node.pure`), then the best child on each
    /// leg, rounding stage and tack, then the rest by score, a child within `spacing` hull lengths of a kept one on the same
    /// leg, stage and tack dropped. So a lull that catches the leaders on one tack never empties the beam of the other, and
    /// the bots' laps always finish. Ties go to the earlier child, so the beam is the same every run.
    private func select(_ children: [Node]) -> [Node] {
        let order = children.indices.sorted { a, b in
            children[a].score != children[b].score ? children[a].score < children[b].score : a < b
        }
        func bucket(_ node: Node) -> [Int] {
            let boat = node.world.seats[0].boat
            return [boat.legIndex, boat.roundingStage, boat.boomSide == .port ? 0 : 1]
        }
        var kept = order.filter { children[$0].pure != nil }
        var buckets: [[Int]] = []
        for index in order where kept.count < options.beamWidth && !buckets.contains(bucket(children[index])) {
            buckets.append(bucket(children[index]))
            if !kept.contains(index) { kept.append(index) }
        }
        let near = Self.spacing * course.boatClass.hull.length
        for index in order where kept.count < options.beamWidth && !kept.contains(index) {
            let boat = children[index].world.seats[0].boat
            let crowded = kept.contains { other in
                let o = children[other].world.seats[0].boat
                return bucket(children[other]) == bucket(children[index]) && (o.position - boat.position).length < near
            }
            if !crowded { kept.append(index) }
        }
        return kept.sorted { children[$0].score != children[$1].score ? children[$0].score < children[$1].score : $0 < $1 }
            .map { children[$0] }
    }

    /// Hull lengths apart two kept children on one leg, stage and tack are at least.
    static let spacing = 2.0

    /// `node`'s child sailed by `pilot` to the next checkpoint, and scored there.
    private func sail(from node: Node, pilot: Pilot, race: Race, ticks: inout Int) throws -> Node {
        try race.importSnapshot(node.world)
        let startTick = race.tick
        let start = race.boats[0]
        let endTick = startTick + Int(options.checkpointSeconds * Double(Race.tickRate))
        let minimumTick = startTick + Int(Self.minimumSegmentSeconds * Double(Race.tickRate))
        var pilot = pilot
        var sent: [Input] = []
        var last = node.world.seats[0].heldInput
        let wasOverstood = isOverstood(start)
        let wasInZone = course.distanceToMark(ofLeg: start.legIndex, from: start.position) < course.roundingRadius
        while race.tick < endTick && !race.isOver {
            steer(&pilot, race: race, last: &last, sent: &sent)
            race.step()
            ticks += 1
            _ = race.drainEvents()
            let boat = race.boats[0]
            if boat.status == .finished || boat.status == .dsq { break }
            // Her helm fouls a mark: that child is done. A bot serves the turn, as she would racing.
            if boat.penaltyTurnsOwed > 0, case .helm = pilot { break }
            guard options.eventCheckpoints, race.tick >= minimumTick else { continue }
            if boat.legIndex != start.legIndex || boat.roundingStage != start.roundingStage { break }
            if !wasInZone && course.distanceToMark(ofLeg: boat.legIndex, from: boat.position) < course.roundingRadius { break }
            if isOverstood(boat) != wasOverstood { break }
            if abs(wrapAngle(boat.sailingWind.direction - start.sailingWind.direction)) > Self.shiftCut { break }
            if abs(boat.sailingWind.speed - start.sailingWind.speed) > Self.puffCut * max(start.sailingWind.speed, 0.5) { break }
        }
        let boat = race.boats[0]
        let trail = sent.isEmpty ? node.trail : Trail(parent: node.trail, inputs: sent)
        let finish = boat.status == .finished ? boat.finishTime : nil
        // Out, closed without finishing, or her helm owing a turn: she can't finish the lap the search wants.
        var fouled = boat.penaltyTurnsOwed > 0
        if case .bot = pilot { fouled = false }
        let lost = fouled || boat.status == .dsq || (race.isOver && finish == nil)
        let score = lost ? Double.infinity : estimatedFinish(race)
        var child = Node(world: race.exportSnapshot(), helm: node.helm, bot: nil, pure: nil, trail: trail, score: score,
                         finish: finish)
        switch pilot {
        case .helm(let helm): child.helm = helm
        case .bot(let driver, let profile):
            child.bot = (driver, profile)
            // Her helm picks up the course she is sailing now, should the next segment be the helm's.
            child.helm = Helm(course: .angle(boomSide: boat.boomSide, twa: boat.twa))
        }
        return child
    }

    /// One tick's steering by `pilot`: on a decision tick her helm's held input, or her bot's decision, sent for the next
    /// tick; what changes is recorded in `sent`.
    private func steer(_ pilot: inout Pilot, race: Race, last: inout BoatInput, sent: inout [Input]) {
        let next = race.tick + 1
        switch pilot {
        case .helm(let helm):
            guard race.tick.isMultiple(of: BotDriver.decisionInterval) else { return }
            let input = helm.input(race: race, oracle: self)
            if input != last {
                race.apply(input, seat: 0, atTick: next)
                sent.append(Input(tick: next, held: input))
                last = input
            }
        case .bot(var driver, let profile):
            if let decision = driver.drive(race) {
                if decision.input != last {
                    sent.append(Input(tick: next, held: decision.input))
                    last = decision.input
                }
                if let tap = decision.tap { sent.append(Input(tick: next, tap: tap)) }
            }
            pilot = .bot(driver, profile)
        }
    }

    /// `node` sailed on `horizonSeconds` as the executor would sail her (her own driver if she is the executor's), and
    /// scored there: its finish if it finishes. So a tack is scored with the leg it sets up, sailed well.
    private func horizonScore(_ node: Node, race: Race, ticks: inout Int) throws -> Double {
        try race.importSnapshot(node.world)
        let profile = Self.rolloutProfile
        var pilot = Pilot.bot(node.bot.flatMap { $0.profile == profile ? $0.driver : nil } ?? takeOver(profile), profile)
        let endTick = race.tick + Int(options.horizonSeconds * Double(Race.tickRate))
        var last = node.world.seats[0].heldInput
        var sent: [Input] = []
        while race.tick < endTick && !race.isOver {
            steer(&pilot, race: race, last: &last, sent: &sent)
            race.step()
            ticks += 1
            _ = race.drainEvents()
            let boat = race.boats[0]
            if boat.status == .finished { return boat.finishTime ?? .infinity }
            // Sailing on fouls a mark: the child itself is clean, and another course from it may not, so it pays the
            // turn's cost rather than dropping out.
            if boat.penaltyTurnsOwed > 0 || boat.status == .dsq { return estimatedFinish(race) + Self.horizonFoulSeconds }
        }
        return estimatedFinish(race)
    }

    func isOverstood(_ boat: Boat) -> Bool {
        course.isOverstood(legIndex: boat.legIndex, position: boat.position, boomSide: boat.boomSide,
                           windDirection: boat.sailingWind.direction, windSpeed: boat.polarWindSpeed(in: course.boatClass))
    }

    // MARK: - The estimate

    /// When she would finish from here (#583's terminal estimate): the race's time, plus the polar's best she can hold
    /// (`SteadyPolar`) in the wind on the water through what is left of her rounding to the leg's target (`roundingPath`,
    /// `pathSeconds`; two tacks or gybes where a piece can't be fetched, round a mark in the way), at the better gate mark,
    /// plus the later legs at it in the mean wind, plus what her speed below her target costs to make up
    /// (`momentum.speedingUp` of it).
    func estimatedFinish(_ race: Race) -> Double {
        let boat = race.boats[0]
        guard boat.status == .racing else {
            if boat.status == .finished { return boat.finishTime ?? race.time }
            let toLine = (course.course.startLine.centre - boat.position).length / max(boat.speed, 1)
            return race.time + toLine + laterLegs[0]
                + Self.legSeconds(polar: course.steady(tws: course.baseWindStrength), from: course.course.startLine.centre,
                                  to: course.legTarget(0), windDirection: course.course.axis)
        }
        let tws = boat.polarWindSpeed(in: course.boatClass)
        let steady = course.steady(tws: tws)
        let toTarget = (0..<max(course.marks(ofLeg: boat.legIndex).count, 1)).map { gateMark in
            var from = boat.position
            var seconds = 0.0
            let marks = course.marks(ofLeg: boat.legIndex).map(\.position)
            for point in roundingPath(boat, gateMark: gateMark) {
                for stop in clearing(marks, from: from, to: point) + [point] {
                    seconds += pathSeconds(race, from: from, to: stop)
                    from = stop
                }
            }
            return seconds
        }.min() ?? 0
        let target = steady.speed(twa: boat.twa)
        let deficit = target > 0.1 ? max(0, target - boat.speed) / target * course.boatClass.momentum.speedingUp : 0
        return race.time + toTarget + laterLegs[min(boat.legIndex, laterLegs.count - 1)] + deficit
    }

    /// Seconds the polar's best needs from `from` to `to` in the wind on the water now (`legSeconds`), piece by piece of at
    /// most `pathPiece` metres, each in the ground wind at its middle: the oracle knows the whole field, so a hole or a
    /// puff between her and the mark counts.
    func pathSeconds(_ race: Race, from: Vec2, to: Vec2) -> Double {
        let run = to - from
        let pieces = max(1, min(Self.pathPieces, Int((run.length / Self.pathPiece).rounded(.up))))
        var seconds = 0.0
        for k in 0..<pieces {
            let a = from + run * (Double(k) / Double(pieces))
            let b = from + run * (Double(k + 1) / Double(pieces))
            let wind = race.groundWind(at: (a + b) / 2)
            seconds += Self.legSeconds(polar: course.steady(tws: wind.speed), from: a, to: b, windDirection: wind.direction)
        }
        return seconds
    }

    /// The detour a straight run from `from` to `to` takes round the first of `marks` it would pass within half a
    /// rounding's clearance of: a point that clearance off the mark, on the side the run passes it. Empty for a clear run.
    func clearing(_ marks: [Vec2], from: Vec2, to: Vec2) -> [Vec2] {
        let off = course.boatClass.hull.length + CourseLayout.markRadius
        let run = to - from
        guard run.lengthSquared > 1e-9 else { return [] }
        for mark in marks {
            let along = ((mark - from).dot(run) / run.lengthSquared).clamped(to: 0...1)
            guard along > 0, along < 1 else { continue }
            let nearest = from + run * along
            let away = nearest - mark
            guard away.length < off / 2 else { continue }
            let side = away.length > 1e-6 ? away.normalized : run.normalized.rightPerp
            return [mark + side * off]
        }
        return []
    }

    static let pathPiece = 50.0
    static let pathPieces = 8

    /// Where she still has to go on her leg, in order: back round behind the mark if she is past it on the wrong side, the
    /// waypoints of the rounding stages she hasn't crossed (`Helm.waypoint`), by `gateMark` at a gate, then the leg's
    /// target; on the finish leg, the nearest point of the line (`Helm.finishPoint`).
    func roundingPath(_ boat: Boat, gateMark: Int) -> [Vec2] {
        let layout = course.course
        guard layout.legs.indices.contains(boat.legIndex), case .round = layout.legs[boat.legIndex] else {
            return [Helm.finishPoint(from: boat.position, oracle: self)]
        }
        let stages = layout.roundingStages(of: layout.legs[boat.legIndex]).count
        var path: [Vec2] = []
        // Past the mark on the wrong side, before the first stage: she goes back round behind it.
        if boat.roundingStage == 0, let frame = Helm.frame(legIndex: boat.legIndex, gateMark: gateMark, oracle: self) {
            let off = course.boatClass.hull.length + CourseLayout.markRadius
            let relative = boat.position - frame.mark
            if relative.dot(frame.approach) > 0 && relative.dot(frame.outside) < 0 {
                path.append(frame.mark - frame.approach * off + frame.outside * off * 0.5)
            }
        }
        var stage = boat
        for next in boat.roundingStage..<stages {
            stage.roundingStage = next
            path.append(Helm.waypoint(boat: stage, gateMark: gateMark, oracle: self))
        }
        return path + [course.legTarget(boat.legIndex)]
    }

    /// Seconds `polar`'s best needs from `from` to `to` in a wind from `windDirection`: straight where the bearing can be
    /// sailed between the best upwind and downwind angles, else two legs at the best angle; never slower than `slowest`.
    static func legSeconds(polar: SteadyPolar, from: Vec2, to: Vec2, windDirection: Double) -> Double {
        let run = to - from
        let distance = run.length
        guard distance > 1e-6 else { return 0 }
        let off = abs(wrapAngle(windDirection - run.bearing))
        func twoLegs(_ optimum: (twa: Double, speed: Double)) -> Double {
            // Two legs at ±(the optimum's angle off the wind's axis): their lengths sum to distance·cos(δ)/cos(α).
            let axis = optimum.twa < .pi / 2 ? 0.0 : Double.pi
            let alpha = abs(optimum.twa - axis)
            let delta = abs(off - axis)
            return distance * cos(delta) / cos(alpha) / max(optimum.speed, Self.slowest)
        }
        if off < polar.up.twa { return twoLegs(polar.up) }
        if off > polar.down.twa { return twoLegs(polar.down) }
        return distance / max(polar.speed(twa: off), Self.slowest)
    }

    /// The least speed the estimate reckons with, m/s: a calm is slow going, not a wall.
    static let slowest = 0.1

    /// `laterLegs`: for each leg, the polar's best in the race's mean wind from its target on round the rest.
    private static func laterLegSeconds(_ trial: TimeTrialCourse) -> [Double] {
        let legs = trial.course.legs
        var after = Array(repeating: 0.0, count: legs.count)
        guard legs.count > 1 else { return after }
        for k in stride(from: legs.count - 2, through: 0, by: -1) {
            after[k] = legSeconds(polar: trial.steady(tws: trial.baseWindStrength), from: trial.legTarget(k),
                                  to: trial.legTarget(k + 1), windDirection: trial.course.axis) + after[k + 1]
        }
        return after
    }
}

extension Oracle {
    /// Her helm (#583): steers `course` with the rudder, deciding every `BotDriver.decisionInterval` ticks as a bot does.
    /// A proportional law on the heading error at the class's autohelm gain, capped at `turnRudder` through a tack and at
    /// `bearAwayRudder` otherwise: one held input a decision, never a tap.
    struct Helm: Hashable, Sendable {
        var course: Course

        static let turnRudder = 0.7
        static let bearAwayRudder = 0.35
        /// Within this of the heading she steers for, she has settled on it and may choose again.
        static let settled = deg2rad(15)
        /// Slower than this she is stopped: inside the no-go she lets the rudder go so the class falls her off (#458).
        static let ironsSpeed = 0.5
        /// Stopped outside the no-go she bears away this far below close-hauled to build way.
        static let buildWay = deg2rad(10)

        init(course: Course) {
            self.course = course
        }

        /// The helm after `action` at a node whose world is `world`; nil where the action is the same as another
        /// (pinching at the no-go's edge, a gate's other mark off a gate, a hold that is its groove).
        func after(_ action: Action, world: WorldSnapshot, oracle: Oracle, seat: Int = 0) -> Helm? {
            let boat = world.seats[seat].boat
            let steady = oracle.course.steady(tws: boat.polarWindSpeed(in: oracle.course.boatClass))
            let up = steady.up.twa
            let down = steady.down.twa
            let minimum = max(up - deg2rad(8), BoatDynamics.noGoAngle(oracle.course.boatClass.polar) + deg2rad(5))
            let maximum = deg2rad(178)
            let current: (side: BoomSide, twa: Double) = {
                if case .angle(let side, let twa) = course { return (side, twa) }
                return (boat.boomSide, boat.twa)
            }()
            func angle(_ side: BoomSide, _ twa: Double) -> Helm? {
                let clamped = min(max(twa, minimum), maximum)
                let next = Helm(course: .angle(boomSide: side, twa: clamped))
                return next == self && action != .hold ? nil : next
            }
            // Through a turn, or any big change of course, she holds it: a helm that changes its mind head to wind
            // stops there.
            guard action == .hold || abs(wrapAngle(heading(boat: boat, oracle: oracle) - boat.heading)) < Self.settled else {
                return nil
            }
            switch action {
            case .hold:
                return self
            case .groove:
                return angle(boat.boomSide, groove(boat: boat, up: up, down: down, oracle: oracle))
            case .pinch:
                return angle(current.side, current.twa - Oracle.angleStep)
            case .foot:
                return angle(current.side, current.twa + Oracle.angleStep)
            case .headUp:
                guard current.twa > .pi / 2 else { return nil }
                return angle(current.side, current.twa - Oracle.planingStep)
            case .turn:
                let twa = boat.twa < .pi / 2 ? up : down
                return angle(boat.boomSide.opposite, twa)
            case .waypoint:
                let next = Helm(course: .waypoint(gateMark: 0))
                return next == self ? nil : next
            case .otherGateMark:
                guard oracle.course.marks(ofLeg: boat.legIndex).count == 2 else { return nil }
                let next = Helm(course: .waypoint(gateMark: 1))
                return next == self ? nil : next
            case .sail:
                return nil
            }
        }

        /// The groove's angle on her tack: the polar's best upwind or downwind, whichever the leg's target needs, or the
        /// angle that fetches the target where her tack can sail straight at it.
        private func groove(boat: Boat, up: Double, down: Double, oracle: Oracle) -> Double {
            let target = oracle.course.legTarget(boat.legIndex)
            let angle = boat.boomSide.sailingAngle(relativeWind: wrapAngle(boat.sailingWind.direction - (target - boat.position).bearing))
            if angle > up && angle < down { return angle }
            return angle <= up ? up : down
        }

        /// The held input for now: seat `seat`'s, her seat in a time trial's race.
        func input(race: Race, oracle: Oracle, seat: Int = 0) -> BoatInput {
            let boat = race.boats[seat]
            var desired = heading(boat: boat, oracle: oracle)
            if boat.speed < Self.ironsSpeed {
                // Stopped: let go in the no-go so the class falls her off (#458); outside it, bear away to build way.
                if boat.twa < BoatDynamics.noGoAngle(oracle.course.boatClass.polar) { return BoatInput(rudder: 0.0) }
                let build = oracle.course.steady(tws: boat.polarWindSpeed(in: oracle.course.boatClass)).up.twa + Self.buildWay
                if boat.twa < build {
                    let wind = boat.sailingWind.direction
                    desired = boat.boomSide == .port ? wrapAngle(wind - build) : wrapAngle(wind + build)
                }
            }
            let error = wrapAngle(desired - boat.heading)
            let gain = oracle.course.boatClass.steering.autohelm.gain
            // A tack swings hard through head to wind; every other turn (a gybe, a bear-away) gently, to keep the plane.
            var cap = Self.bearAwayRudder
            let side = BoomSide.leeward(ofRelativeWind: wrapAngle(boat.sailingWind.direction - desired))
            if side != boat.boomSide, boat.twa < .pi / 2 { cap = Self.turnRudder }
            let rudder = (error * gain).clamped(to: -cap...cap)
            return BoatInput(rudder: rudder)
        }

        /// The heading she steers for.
        func heading(boat: Boat, oracle: Oracle) -> Double {
            let wind = boat.sailingWind.direction
            switch course {
            case .angle(let side, let twa):
                return side == .port ? wrapAngle(wind - twa) : wrapAngle(wind + twa)
            case .waypoint, .point:
                let point: Vec2
                switch course {
                case .point(let fixed): point = fixed
                case .waypoint(let gateMark): point = Self.waypoint(boat: boat, gateMark: gateMark, oracle: oracle)
                case .angle: preconditionFailure("an angle is steered above")
                }
                let bearing = (point - boat.position).bearing
                let relative = wrapAngle(wind - bearing)
                let up = oracle.course.steady(tws: boat.polarWindSpeed(in: oracle.course.boatClass)).up.twa
                let side: BoomSide = BoomSide.leeward(ofRelativeWind: relative)
                // A waypoint inside the no-go: the groove on the tack she is on.
                if abs(relative) < up {
                    return boat.boomSide == .port ? wrapAngle(wind - up) : wrapAngle(wind + up)
                }
                // Straight downwind is as deep as she sails: she gybes for it rather than by the lee.
                let deepest = deg2rad(178)
                if abs(relative) > deepest {
                    return side == .port ? wrapAngle(wind - deepest) : wrapAngle(wind + deepest)
                }
                return bearing
            }
        }

        /// The nearest point of the finish line to `position`, kept a tenth of the line in from either end, clear of
        /// the pin and the committee boat.
        static func finishPoint(from position: Vec2, oracle: Oracle) -> Vec2 {
            let line = oracle.course.course.finishLine.segment
            let along = line.b - line.a
            let share = ((position - line.a).dot(along) / along.lengthSquared).clamped(to: 0.1...0.9)
            return line.a + along * share
        }

        /// Where she steers for at a rounding (#583): a mark's first stage beside it on the side she leaves it, a hull
        /// length and its radius off, a stage on; its second stage past the mark the same way round; a gate's by
        /// `gateMark`. The finish leg's is the line (`finishPoint`).
        static func waypoint(boat: Boat, gateMark: Int, oracle: Oracle) -> Vec2 {
            guard let frame = frame(legIndex: boat.legIndex, gateMark: gateMark, oracle: oracle) else {
                return finishPoint(from: boat.position, oracle: oracle)
            }
            let off = oracle.course.boatClass.hull.length + CourseLayout.markRadius
            if boat.roundingStage == 0 { return frame.mark + frame.outside * off + frame.approach * off * 0.5 }
            return frame.mark + frame.approach * off - frame.outside * off
        }

        /// A rounding's frame: the mark she rounds (a gate's by `gateMark`), the way she comes at it, and the side she
        /// passes it on: a mark's outside, rounding it to its side; a gate mark's inside, between the two. Nil on the
        /// finish leg.
        static func frame(legIndex: Int, gateMark: Int, oracle: Oracle) -> (mark: Vec2, approach: Vec2, outside: Vec2)? {
            let layout = oracle.course.course
            guard layout.legs.indices.contains(legIndex), case .round(let index) = layout.legs[legIndex] else { return nil }
            switch layout.elements[index] {
            case .mark(let mark, let side):
                let approach = index == CourseLayout.windwardIndex
                    ? layout.upwind : (mark.position - layout.elements[CourseLayout.windwardIndex].marks[0].position).normalized
                return (mark.position, approach, side == .port ? approach.rightPerp : -approach.rightPerp)
            case .gate(let left, let right):
                let mark = gateMark == 0 ? left : right
                let other = gateMark == 0 ? right : left
                return (mark.position, -layout.upwind, (other.position - mark.position).normalized)
            }
        }
    }
}
