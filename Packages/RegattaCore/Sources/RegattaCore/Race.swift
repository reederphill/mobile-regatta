import Foundation

/// The authoritative race simulation. Advance it with `step()`, one fixed tick of `Race.dt` at a time.
///
/// Determinism (ADR 0002): the step path draws randomness only from the race's `SplitMix64`,
/// never reads the wall clock, and never iterates a `Set` or `Dictionary` — their order depends on
/// a per-process hash seed. Look them up by key; iterate arrays. `DeterminismTests` scans for all three.
public final class Race {
    public struct Config: Sendable {
        public var opponents: Int
        public var laps: Int
        public var prestartSeconds: Double
        public var seed: UInt64
        public var playerName: String
        /// A bot sails the player's boat too (demo mode, headless tests).
        public var autopilotPlayer: Bool

        public init(
            opponents: Int = 7,
            laps: Int = 2,
            prestartSeconds: Double = 60,
            seed: UInt64,
            playerName: String = "You",
            autopilotPlayer: Bool = false
        ) {
            self.opponents = opponents
            self.laps = laps
            self.prestartSeconds = prestartSeconds
            self.seed = seed
            self.playerName = playerName
            self.autopilotPlayer = autopilotPlayer
        }
    }

    /// Length of the disturbed-air cone behind a boat.
    public static let shadowLength = Boat.length * 8
    /// Half-width of the shadow cone at `distance` downwind of the boat.
    public static func shadowHalfWidth(at distance: Double) -> Double { 2 + distance * 0.18 }
    public static let timeLimitAfterFirstFinish = 180.0

    /// Simulation ticks per second. A server that falls behind catches up with several ticks, never a longer one.
    public static let tickRate = 30
    /// Seconds per tick.
    public static let dt = 1.0 / Double(tickRate)

    static let botNames = [
        "Gannet", "Petrel", "Skua", "Fulmar", "Tern", "Osprey", "Curlew", "Kittiwake",
        "Shearwater", "Puffin", "Cormorant", "Albatross", "Plover", "Heron", "Merlin", "Dunlin",
    ]

    public let config: Config
    public let course: Course
    public let polar = Polar.dinghy
    public let playerIndex = 0

    public private(set) var wind: WindField
    public private(set) var boats: [Boat]
    /// Race clock in ticks; negative during the start sequence, 0 at the gun.
    public private(set) var tick: Int
    /// Race clock in seconds, derived from `tick` so it never accumulates rounding.
    public var time: Double { Double(tick) / Double(Race.tickRate) }
    public private(set) var isOver = false
    public private(set) var firstFinishTime: Double?

    /// Wraps the bot-brain phase of `step()` so a profiler can time it; the app emits an `os_signpost` interval.
    /// It must call `body` exactly once and must not touch the race, so it never changes simulation output.
    public var botBrainsInterval: ((_ body: () -> Void) -> Void)?

    private struct Pair: Hashable {
        let a: Int
        let b: Int
    }

    private var brains: [Int: BotBrain] = [:]
    private var boatContacts = Set<Pair>()
    private var obstacleContacts = Set<Pair>()
    private var lastFoul: [Pair: Double] = [:]
    private var events: [RaceEvent] = []
    private var finishers = 0

    public init(config: Config) {
        self.config = config
        var rng = SplitMix64(seed: config.seed)
        let course = Course.standard(laps: config.laps)
        self.course = course
        wind = WindField(
            seed: rng.next(),
            baseDirection: course.axis,
            areaMin: Vec2(-450, -250),
            areaMax: Vec2(450, course.marks[0].position.y + 200)
        )
        tick = -Int((config.prestartSeconds * Double(Race.tickRate)).rounded())

        var fleet = [
            Boat(id: 0, name: config.playerName, isPlayer: true, colorIndex: 0,
                 position: Vec2(0, -55), heading: .pi / 2, speed: 2),
        ]
        for k in 0..<max(0, config.opponents) {
            var position = Vec2.zero
            for _ in 0..<50 {
                position = Vec2(rng.range(-130, 130), rng.range(-100, -35))
                if fleet.allSatisfy({ ($0.position - position).length > 10 }) { break }
            }
            let heading = rng.bool() ? Double.pi / 2 : -Double.pi / 2
            fleet.append(Boat(id: k + 1, name: Race.botNames[k % Race.botNames.count], isPlayer: false,
                              colorIndex: k + 1, position: position, heading: heading, speed: 2))
        }
        boats = fleet

        for i in boats.indices where i != playerIndex || config.autopilotPlayer {
            brains[i] = BotBrain(rng: &rng)
        }
        refreshWind()
    }

    public var player: Boat { boats[playerIndex] }

    // MARK: - Player input

    /// Rudder from the touch controls, -1…1. Any real input cancels an auto-tack.
    public func setPlayerRudder(_ value: Double) {
        guard brains[playerIndex] == nil else { return }
        if abs(value) > 0.05 { boats[playerIndex].autopilot = nil }
        if boats[playerIndex].autopilot == nil {
            boats[playerIndex].desiredRudder = value.clamped(to: -1...1)
        }
    }

    /// Mirror the heading across the wind: a tack when upwind, a gybe when downwind.
    public func playerTackOrGybe() {
        let b = boats[playerIndex]
        guard b.isOnCourse else { return }
        boats[playerIndex].autopilot = wrapAngle(b.windDirection + b.relativeWind)
    }

    // MARK: - Simulation

    public func drainEvents() -> [RaceEvent] {
        defer { events.removeAll() }
        return events
    }

    /// Advances the race by one tick.
    public func step() {
        guard !isOver else { return }
        tick += 1
        wind.step()
        if tick == 0 { fireGun() }

        refreshWind()
        applyWindShadows()

        if let botBrainsInterval { botBrainsInterval(runBotBrains) } else { runBotBrains() }

        let previous = boats.map(\.position)
        for i in boats.indices { integrate(i, Race.dt) }
        resolveBoatContacts()
        resolveObstacleContacts()
        for i in boats.indices { updateProgress(i, from: previous[i]) }
        checkForEnd()
    }

    private func runBotBrains() {
        for i in boats.indices where boats[i].isOnCourse {
            guard var brain = brains[i] else { continue }
            let rudder = brain.rudder(for: i, in: self)
            brains[i] = brain
            boats[i].desiredRudder = rudder
        }
    }

    private func refreshWind() {
        for i in boats.indices {
            boats[i].windDirection = wind.direction(at: boats[i].position)
            boats[i].windSpeed = wind.speed(at: boats[i].position)
        }
    }

    private func applyWindShadows() {
        for i in boats.indices {
            guard boats[i].isOnCourse else {
                boats[i].shadow = 1
                continue
            }
            var factor = 1.0
            for j in boats.indices where j != i && boats[j].isOnCourse {
                let offset = boats[i].position - boats[j].position
                let downwind = -Vec2.heading(boats[j].windDirection)
                let along = offset.dot(downwind)
                guard along > 0, along < Race.shadowLength else { continue }
                let width = Race.shadowHalfWidth(at: along)
                let lateral = abs(offset.cross(downwind))
                guard lateral < width else { continue }
                factor *= 1 - 0.22 * (1 - along / Race.shadowLength) * (1 - lateral / width)
            }
            boats[i].shadow = max(factor, 0.6)
        }
    }

    private func integrate(_ i: Int, _ dt: Double) {
        var b = boats[i]

        if let target = b.autopilot {
            let error = wrapAngle(target - b.heading)
            b.desiredRudder = (error / deg2rad(20)).clamped(to: -1...1)
            if abs(error) < deg2rad(3) {
                b.autopilot = nil
                b.desiredRudder = 0
            }
        }
        let rudderRate = 5 * dt
        b.rudder += (b.desiredRudder - b.rudder).clamped(to: -rudderRate...rudderRate)

        // Steering: more authority with more flow over the rudder.
        let steerage = (0.45 + b.speed / 3).clamped(to: 0.45...1)
        let turn = b.rudder * deg2rad(85) * steerage * dt
        let wasStarboard = b.relativeWind >= 0
        b.heading = wrapAngle(b.heading + turn)

        if b.penaltyTurnsOwed > 0 {
            b.penaltyProgress += turn
            if abs(b.penaltyProgress) >= 2 * .pi * Double(b.penaltyTurnsOwed) {
                b.penaltyTurnsOwed = 0
                b.penaltyProgress = 0
                events.append(.penaltyServed(boat: i))
            }
        }

        // Rule 13: from passing head to wind until close-hauled on the new tack.
        if (b.relativeWind >= 0) != wasStarboard {
            b.isTacking = b.twa < .pi / 2
        }
        if b.isTacking && b.twa >= polar.upwindTWA - deg2rad(5) {
            b.isTacking = false
        }

        let target = b.isOnCourse ? polar.targetSpeed(twa: b.twa, windSpeed: b.windSpeed * b.shadow) : 0
        let timeConstant = target > b.speed ? 2.5 : 5.0
        b.speed += (target - b.speed) * min(1, dt / timeConstant)
        b.speed -= b.speed * abs(b.rudder) * 0.3 * dt
        b.speed = max(0, b.speed)
        b.position += b.forward * b.speed * dt

        boats[i] = b
    }

    // MARK: - Contact and rules

    private func resolveBoatContacts() {
        var touching = Set<Pair>()
        let hulls = boats.map { $0.hull() }
        for i in boats.indices where boats[i].isOnCourse {
            for j in (i + 1)..<boats.count where boats[j].isOnCourse {
                guard (boats[i].position - boats[j].position).length < Boat.length * 1.3,
                      let push = Collision.penetration(hulls[i], hulls[j])
                else { continue }

                let pair = Pair(a: i, b: j)
                touching.insert(pair)
                if !boatContacts.contains(pair) {
                    boats[i].speed *= 0.6
                    boats[j].speed *= 0.6
                    if (lastFoul[pair] ?? -.infinity) + 5 < time {
                        lastFoul[pair] = time
                        let call = Rules.judge(boats[i], boats[j], course: course)
                        penalize(call.offender, turns: 2)
                        events.append(.foul(call))
                    }
                }
                boats[i].position += push * 0.5
                boats[j].position -= push * 0.5
            }
        }
        boatContacts = touching
    }

    private func resolveObstacleContacts() {
        var touching = Set<Pair>()
        let obstacles = course.obstacles
        for i in boats.indices where boats[i].isOnCourse {
            for (k, obstacle) in obstacles.enumerated() {
                guard (boats[i].position - obstacle.position).length < Boat.length + obstacle.radius,
                      let push = Collision.penetration(polygon: boats[i].hull(), circle: obstacle.position, radius: obstacle.radius)
                else { continue }
                let pair = Pair(a: i, b: k)
                touching.insert(pair)
                if !obstacleContacts.contains(pair) {
                    boats[i].speed *= 0.5
                    penalize(i, turns: 1)
                    events.append(.markTouch(boat: i, mark: obstacle.name))
                }
                boats[i].position += push
            }
        }
        obstacleContacts = touching
    }

    private func penalize(_ i: Int, turns: Int) {
        if boats[i].penaltyTurnsOwed == 0 { boats[i].penaltyProgress = 0 }
        boats[i].penaltyTurnsOwed = min(boats[i].penaltyTurnsOwed + turns, 4)
    }

    // MARK: - Start, roundings, finish

    private func fireGun() {
        for i in boats.indices where boats[i].status == .prestart && course.lineSide(boats[i].position) > 0 {
            boats[i].status = .ocs
            events.append(.ocs(boat: i))
        }
        events.append(.gun)
    }

    private func updateProgress(_ i: Int, from p0: Vec2) {
        let p1 = boats[i].position
        let lineCrossing = crossing(from: p0, to: p1, over: course.startLine)

        switch boats[i].status {
        case .prestart:
            if time >= 0 && lineCrossing == 1 {
                boats[i].status = .racing
                boats[i].legIndex = 0
                boats[i].roundingStage = 0
                events.append(.started(boat: i))
            }
        case .ocs:
            if course.lineSide(p1) < 0 {
                boats[i].status = .prestart
                events.append(.cleared(boat: i))
            }
        case .racing:
            switch course.legs[boats[i].legIndex] {
            case .round(let m):
                let gates = course.gates(forMark: m)
                let stage = boats[i].roundingStage
                if crossing(from: p0, to: p1, over: gates[stage]) == 1 {
                    boats[i].roundingStage += 1
                    if boats[i].roundingStage == gates.count {
                        boats[i].legIndex += 1
                        boats[i].roundingStage = 0
                        events.append(.rounded(boat: i, mark: course.marks[m].name))
                    }
                } else if stage > 0 && crossing(from: p0, to: p1, over: gates[stage - 1]) == -1 {
                    boats[i].roundingStage -= 1
                }
            case .finish:
                if lineCrossing == -1 { finish(i) }
            }
        case .finished, .dsq, .dnf:
            break
        }
    }

    private func finish(_ i: Int) {
        firstFinishTime = firstFinishTime ?? time
        if boats[i].penaltyTurnsOwed > 0 {
            boats[i].status = .dsq
            events.append(.disqualified(boat: i, reason: "finished without taking a penalty"))
            return
        }
        finishers += 1
        boats[i].status = .finished
        boats[i].place = finishers
        boats[i].finishTime = time
        events.append(.finished(boat: i, place: finishers))
    }

    private func checkForEnd() {
        let timedOut = firstFinishTime.map { time > $0 + Race.timeLimitAfterFirstFinish } ?? false
        guard timedOut || !boats.contains(where: \.isOnCourse) else { return }
        for i in boats.indices where boats[i].isOnCourse { boats[i].status = .dnf }
        isOver = true
        events.append(.raceOver)
    }

    // MARK: - Standings

    /// Distance-based progress score used to rank boats still racing.
    public func progress(of b: Boat) -> Double {
        guard b.legIndex < course.legs.count else { return .infinity }
        let target = course.targetPosition(for: course.legs[b.legIndex])
        return Double(b.legIndex) * 10_000 + Double(b.roundingStage) * 100 - (b.position - target).length
    }

    /// Boat indices from first to last.
    public func standings() -> [Int] {
        boats.indices.sorted { rankKey($0) < rankKey($1) }
    }

    private func rankKey(_ i: Int) -> (Int, Double) {
        let b = boats[i]
        switch b.status {
        case .finished: return (0, b.finishTime ?? 0)
        case .racing: return (1, -progress(of: b))
        case .prestart, .ocs: return (2, (b.position - course.lineCenter).length)
        case .dsq, .dnf: return (3, Double(i))
        }
    }
}
