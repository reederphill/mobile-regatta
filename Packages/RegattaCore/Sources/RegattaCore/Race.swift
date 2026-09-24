import Foundation

/// The authoritative race simulation. Advance it with `step()`, one fixed tick of `Race.dt` at a time.
///
/// Determinism (ADR 0002): the step path draws randomness only from the race's `SplitMix64`,
/// never reads the wall clock, and never iterates a `Set` or `Dictionary` — their order depends on
/// a per-process hash seed. Look them up by key; iterate arrays. `DeterminismTests` scans for all three.
public final class Race {
    /// Length of the disturbed-air cone behind a boat.
    public static let shadowLength = Boat.length * 8
    /// Half-width of the shadow cone at `distance` downwind of the boat.
    public static func shadowHalfWidth(at distance: Double) -> Double { 2 + distance * 0.18 }
    public static let timeLimitAfterFirstFinish = 180.0
    /// An eased boat's target speed as a fraction of the polar's: the prototype's 15 % (#13).
    /// A placeholder until the boat class's ease amount and rate are wired in (#58, #81).
    public static let easedSpeedFactor = 0.15

    /// Simulation ticks per second. A server that falls behind catches up with several ticks, never a longer one.
    public static let tickRate = 30
    /// Seconds per tick.
    public static let dt = 1.0 / Double(tickRate)

    static let botNames = [
        "Gannet", "Petrel", "Skua", "Fulmar", "Tern", "Osprey", "Curlew", "Kittiwake",
        "Shearwater", "Puffin", "Cormorant", "Albatross", "Plover", "Heron", "Merlin", "Dunlin",
    ]

    public let setup: RaceSetup
    public let windSeed: WindSeed
    public let course: Course
    public let polar = Polar.dinghy

    /// The conditions every race sails until race assembly reads `RaceSetup.conditions` (#81).
    /// Schema 2: the keyed wind needs its wobble and ramp tuning (#75).
    public static let defaultConditions: ConditionsFile = {
        do {
            return try ConditionsFile.bundled(id: "classic-oscillating", version: 2)
        } catch {
            preconditionFailure("bundled conditions classic-oscillating@2 failed to load: \(error)")
        }
    }()

    /// The public wind setup, drawn from the race seed: mean direction, base strength, trend direction.
    public let windSetup: WindSetup
    /// The keyed wind (ADR 0001), holding the keys through the current window and no further.
    public private(set) var wind: WindField
    /// Makes this race's keys from its wind seed, one window at a time as the clock enters it. A race
    /// always holds its wind seed (practice on the device, the server, a replay), so it is never
    /// missing a key; an online client that holds only revealed keys needs its own source (#95).
    private var windKeys: WindKeyGenerator
    /// One boat per seat: `boats[seat]`.
    public private(set) var boats: [Boat]
    /// Each seat's held input, in force until the seat sends a different one.
    public private(set) var heldInputs: [BoatInput]
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
    /// Inputs stamped for ticks not yet simulated, in the order they arrived.
    private var pending: [InputRecord] = []
    private var appliedInputs: [InputRecord] = []
    private var seatEvents: [SeatEvent] = []

    /// Builds the race at the start of its sequence, tick −`setup.startSequenceTicks`.
    ///
    /// The public wind setup (mean direction, base strength, trend direction) is drawn from the race
    /// seed in `defaultConditions` with the stub venue pairing, and the course is laid square to its
    /// mean direction (#10). Everything that changes during the race comes from the key chain of
    /// `windSeed` alone, never from the race seed (ADR 0001).
    /// `botBrainSeats` are sailed by the built-in `BotBrain`, which feeds them through the same
    /// held-input path as any seat, so the log still holds every input applied (ADR 0002). A replay
    /// passes none: replays never run bots. Temporary until bots become seat controllers (#60).
    public init(setup: RaceSetup, windSeed: WindSeed, botBrainSeats: [Int] = []) {
        self.setup = setup
        self.windSeed = windSeed
        var rng = SplitMix64(seed: setup.raceSeed.value)
        let windSetup = WindSetup(conditions: Race.defaultConditions, pairing: .stub, raceSeed: setup.raceSeed)
        self.windSetup = windSetup
        let course = Course.standard(laps: setup.laps, axis: windSetup.meanDirection)
        self.course = course
        let windows = WindWindows(startSequenceTicks: setup.startSequenceTicks)
        wind = WindField(setup: windSetup, windows: windows)
        do {
            windKeys = try WindKeyGenerator(windSeed: windSeed, setup: windSetup, windows: windows)
        } catch {
            preconditionFailure("default conditions can't be keyed: \(error)")
        }
        tick = -setup.startSequenceTicks

        // Prototype placement until the start row (#35): seat 0 mid-line, the rest scattered by the race seed.
        var fleet: [Boat] = []
        var botsNamed = 0
        for seat in setup.seats.indices {
            let kind = setup.seats[seat]
            let name: String
            if kind == .bot {
                name = Race.botNames[botsNamed % Race.botNames.count]
                botsNamed += 1
            } else {
                name = "Helm \(seat + 1)"
            }
            var position = Vec2(0, -55)
            var heading = Double.pi / 2
            if seat > 0 {
                for _ in 0..<50 {
                    position = Vec2(rng.range(-130, 130), rng.range(-100, -35))
                    if fleet.allSatisfy({ ($0.position - position).length > 10 }) { break }
                }
                heading = rng.bool() ? Double.pi / 2 : -Double.pi / 2
            }
            fleet.append(Boat(id: seat, name: name, isPlayer: kind == .human, colorIndex: seat,
                              position: position, heading: heading, speed: 2))
        }
        boats = fleet
        heldInputs = Array(repeating: .neutral, count: fleet.count)

        // Every seat draws a style, so a seat's style doesn't depend on which seats have brains.
        for seat in boats.indices {
            let brain = BotBrain(rng: &rng)
            if botBrainSeats.contains(seat) { brains[seat] = brain }
        }
        makeWindKeys()
        refreshWind()
    }

    // MARK: - Input

    /// Holds `input` for `seat` from tick `stamp` until the seat sends another. A stamp the race has
    /// already simulated applies at the next tick instead, and is logged there (#18).
    /// Returns the tick it applies at, or nil if rejected: an unknown seat, a seat sailed by a
    /// built-in brain, or a race that is over.
    @discardableResult
    public func apply(_ input: BoatInput, seat: Int, atTick stamp: Int) -> Int? {
        guard acceptsInput(from: seat) else { return nil }
        let at = max(stamp, tick + 1)
        pending.append(InputRecord(tick: at, seat: seat, kind: .held(input)))
        return at
    }

    /// Applies `tap` for `seat` once, at tick `stamp` (or the next unsimulated tick if that has passed).
    /// Returns the tick it applies at, or nil if rejected, as for `apply`, or for a protest of an
    /// unknown seat or of the protesting seat itself.
    @discardableResult
    public func tap(_ tap: BoatTap, seat: Int, atTick stamp: Int) -> Int? {
        guard acceptsInput(from: seat) else { return nil }
        if case .protest(let target) = tap {
            guard boats.indices.contains(target), target != seat else { return nil }
        }
        let at = max(stamp, tick + 1)
        pending.append(InputRecord(tick: at, seat: seat, kind: .tap(tap)))
        return at
    }

    /// Records a change in who is at `seat`, stamped with the current tick. Returns nil for an unknown seat.
    @discardableResult
    public func record(_ kind: SeatEvent.Kind, seat: Int) -> SeatEvent? {
        guard boats.indices.contains(seat) else { return nil }
        let event = SeatEvent(tick: tick, seat: seat, kind: kind)
        seatEvents.append(event)
        return event
    }

    /// The race so far as a log: its keys, and every input and seat event exactly as applied.
    public var log: RaceLog {
        RaceLog(header: .init(setup: setup, windSeed: windSeed), inputs: appliedInputs,
                seatEvents: seatEvents, finalTick: tick)
    }

    private func acceptsInput(from seat: Int) -> Bool {
        boats.indices.contains(seat) && brains[seat] == nil && !isOver
    }

    /// Queues this tick's input from each built-in brain whose boat is on the course.
    private func runBotBrains() {
        for i in boats.indices where boats[i].isOnCourse {
            guard var brain = brains[i] else { continue }
            let rudder = brain.rudder(for: i, in: self)
            brains[i] = brain
            pending.append(InputRecord(tick: tick, seat: i, kind: .held(BoatInput(rudder: rudder))))
        }
    }

    /// Applies the inputs stamped for this tick and logs them: held inputs first, the last one per
    /// seat winning and logged only if it changed, then taps in the order they came. So a seat's
    /// held input and tap in the same tick act the same whichever arrived first.
    private func applyInputs() {
        var held = heldInputs
        var taps: [InputRecord] = []
        if !pending.isEmpty {
            var later: [InputRecord] = []
            for record in pending {
                guard record.tick == tick else {
                    later.append(record)
                    continue
                }
                switch record.kind {
                case .held(let input): held[record.seat] = input
                case .tap: taps.append(record)
                }
            }
            pending = later
        }
        for seat in boats.indices where held[seat] != heldInputs[seat] {
            heldInputs[seat] = held[seat]
            appliedInputs.append(InputRecord(tick: tick, seat: seat, kind: .held(held[seat])))
        }

        // Any real rudder input cancels an auto-tack (#13).
        for i in boats.indices {
            let rudder = heldInputs[i].rudderValue
            if abs(rudder) > 0.05 { boats[i].autopilot = nil }
            if boats[i].autopilot == nil { boats[i].desiredRudder = rudder }
        }

        for record in taps {
            appliedInputs.append(record)
            guard case .tap(let tap) = record.kind else { continue }
            let i = record.seat
            switch tap {
            case .tackGybe:
                // Mirror the heading across the wind: a tack when upwind, a gybe when downwind.
                let b = boats[i]
                if b.isOnCourse { boats[i].autopilot = wrapAngle(b.windDirection + b.relativeWind) }
            case .protest(let target):
                emit(.protest(seat: i, target: target))
            }
        }
    }

    // MARK: - Simulation

    public func drainEvents() -> [RaceEvent] {
        defer { events.removeAll() }
        return events
    }

    private func emit(_ kind: RaceEvent.Kind) {
        events.append(RaceEvent(tick: tick, kind: kind))
    }

    /// Advances the race by one tick.
    public func step() {
        guard !isOver else { return }
        tick += 1
        makeWindKeys()
        if tick == 0 { fireGun() }

        refreshWind()
        applyWindShadows()

        if let botBrainsInterval { botBrainsInterval(runBotBrains) } else { runBotBrains() }
        applyInputs()

        let previous = boats.map(\.position)
        for i in boats.indices { integrate(i, Race.dt) }
        resolveBoatContacts()
        resolveObstacleContacts()
        for i in boats.indices { updateProgress(i, from: previous[i]) }
        checkForEnd()
    }

    /// The ground wind at `p` now. The race holds every key through the current window, so this never
    /// fails; if it ever did, it traps rather than extrapolate (ADR 0001).
    public func groundWind(at p: Vec2) -> GroundWind {
        do {
            return try wind.sample(p, tick: tick)
        } catch {
            preconditionFailure("race at tick \(tick) is missing wind: \(error)")
        }
    }

    /// Adds the keys through the window holding the current tick, one window at a time: the race never
    /// holds a key before its window starts.
    private func makeWindKeys() {
        let current = wind.windows.window(containing: tick)
        while windKeys.nextWindow <= current { wind.add(windKeys.next()) }
    }

    private func refreshWind() {
        for i in boats.indices {
            let ground = groundWind(at: boats[i].position)
            boats[i].windDirection = ground.direction
            boats[i].windSpeed = ground.speed
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
                emit(.penaltyServed(seat: i))
            }
        }

        // Rule 13: from passing head to wind until close-hauled on the new tack.
        if (b.relativeWind >= 0) != wasStarboard {
            b.isTacking = b.twa < .pi / 2
        }
        if b.isTacking && b.twa >= polar.upwindTWA - deg2rad(5) {
            b.isTacking = false
        }

        var target = b.isOnCourse ? polar.targetSpeed(twa: b.twa, windSpeed: b.windSpeed * b.shadow) : 0
        if heldInputs[i].ease { target *= Race.easedSpeedFactor }
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
                        emit(.foul(call))
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
                    emit(.markTouch(seat: i, mark: obstacle.name))
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
            emit(.ocs(seat: i))
        }
        emit(.gun)
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
                emit(.started(seat: i))
            }
        case .ocs:
            if course.lineSide(p1) < 0 {
                boats[i].status = .prestart
                emit(.cleared(seat: i))
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
                        emit(.rounded(seat: i, mark: course.marks[m].name))
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
            emit(.disqualified(seat: i, reason: "finished without taking a penalty"))
            return
        }
        finishers += 1
        boats[i].status = .finished
        boats[i].place = finishers
        boats[i].finishTime = time
        emit(.finished(seat: i, place: finishers))
    }

    private func checkForEnd() {
        let timedOut = firstFinishTime.map { time > $0 + Race.timeLimitAfterFirstFinish } ?? false
        guard timedOut || !boats.contains(where: \.isOnCourse) else { return }
        for i in boats.indices where boats[i].isOnCourse { boats[i].status = .dnf }
        isOver = true
        emit(.raceOver)
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

// MARK: - World snapshot (ADR 0005)

extension Race {
    /// The whole predictable world at this tick. Lossless: `importSnapshot` of it continues exactly
    /// like this race. Pairs are listed by seat and obstacle index, never by iterating a set.
    public func exportSnapshot() -> WorldSnapshot {
        var boatPairs: [WorldSnapshot.SeatPair] = []
        var fouls: [WorldSnapshot.FoulMemory] = []
        for a in boats.indices {
            for b in boats.indices where b > a {
                let pair = Pair(a: a, b: b)
                if boatContacts.contains(pair) { boatPairs.append(.init(a, b)) }
                if let time = lastFoul[pair] { fouls.append(.init(pair: .init(a, b), time: time)) }
            }
        }
        var obstacles: [WorldSnapshot.ObstacleContact] = []
        let obstacleCount = course.obstacles.count
        for seat in boats.indices {
            for k in 0..<obstacleCount where obstacleContacts.contains(Pair(a: seat, b: k)) {
                obstacles.append(.init(seat: seat, obstacle: k))
            }
        }
        return WorldSnapshot(
            tick: tick,
            seats: boats.indices.map { WorldSnapshot.Seat(boat: boats[$0], heldInput: heldInputs[$0]) },
            touchingBoats: boatPairs, touchingObstacles: obstacles, foulMemory: fouls,
            firstFinishTime: firstFinishTime, isOver: isOver
        )
    }

    /// Replaces the world with `snapshot`, so stepping on continues from its tick (ADR 0005). The race
    /// keeps what isn't world state: its setup, course and wind seed, and its bot brains, whose own
    /// memory isn't in a snapshot, so a race restored with brains won't make the same bot decisions.
    /// Inputs queued but not yet applied and undrained events are dropped. `log` is left as it was and
    /// no longer describes the race: a race that imports is a prediction, never the record. The
    /// authoritative host never imports a snapshot a client could have supplied (ADR 0005).
    ///
    /// The wind is brought to the snapshot's tick; until the keyed wind (#75) makes it a function of
    /// the tick, going back rebuilds it from the start of the sequence.
    ///
    /// Throws, leaving the race unchanged, for a snapshot it couldn't sail on from: another fleet
    /// size, a tick outside the sequence start … `WorldSnapshot.maxTick`, a non-finite value, a leg or
    /// rounding stage the course doesn't have, a negative penalty count, or a bad contact.
    public func importSnapshot(_ snapshot: WorldSnapshot) throws {
        guard snapshot.seats.count == boats.count else {
            throw WorldSnapshotError.seatCount(expected: boats.count, found: snapshot.seats.count)
        }
        for (seat, entry) in snapshot.seats.enumerated() where entry.boat.id != seat {
            throw WorldSnapshotError.boatID(seat: seat, found: entry.boat.id)
        }
        guard snapshot.tick >= -setup.startSequenceTicks else { throw WorldSnapshotError.tickBeforeStart(snapshot.tick) }
        guard snapshot.tick <= WorldSnapshot.maxTick else { throw WorldSnapshotError.tickTooLate(snapshot.tick) }
        for (seat, entry) in snapshot.seats.enumerated() {
            if let field = invalidField(of: entry.boat) { throw WorldSnapshotError.invalidBoat(seat: seat, field: field) }
        }
        guard snapshot.firstFinishTime?.isFinite ?? true, snapshot.foulMemory.allSatisfy({ $0.time.isFinite }) else {
            throw WorldSnapshotError.invalidTime
        }
        let seatRange = boats.indices
        let validPair = { (p: WorldSnapshot.SeatPair) in seatRange.contains(p.a) && seatRange.contains(p.b) && p.a < p.b }
        guard snapshot.touchingBoats.allSatisfy(validPair),
              snapshot.foulMemory.allSatisfy({ validPair($0.pair) }),
              snapshot.touchingObstacles.allSatisfy({ seatRange.contains($0.seat) && course.obstacles.indices.contains($0.obstacle) })
        else { throw WorldSnapshotError.invalidContact }

        let windTick = snapshot.tick + setup.startSequenceTicks
        if wind.tick > windTick { wind = Race(setup: setup, windSeed: windSeed).wind }
        while wind.tick < windTick { wind.step() }

        tick = snapshot.tick
        boats = snapshot.seats.map(\.boat)
        heldInputs = snapshot.seats.map(\.heldInput)
        boatContacts = Set(snapshot.touchingBoats.map { Pair(a: $0.a, b: $0.b) })
        obstacleContacts = Set(snapshot.touchingObstacles.map { Pair(a: $0.seat, b: $0.obstacle) })
        var foulTimes: [Pair: Double] = [:]
        for memory in snapshot.foulMemory { foulTimes[Pair(a: memory.pair.a, b: memory.pair.b)] = memory.time }
        lastFoul = foulTimes
        firstFinishTime = snapshot.firstFinishTime
        isOver = snapshot.isOver
        // Places count up from the boats already finished.
        finishers = boats.filter { $0.status == .finished }.count
        pending.removeAll()
        events.removeAll()
    }

    /// The first field of `boat` the race couldn't step from, or nil.
    private func invalidField(of boat: Boat) -> String? {
        let doubles: [(String, Double?)] = [
            ("position.x", boat.position.x), ("position.y", boat.position.y), ("heading", boat.heading),
            ("speed", boat.speed), ("rudder", boat.rudder), ("desiredRudder", boat.desiredRudder),
            ("autopilot", boat.autopilot), ("penaltyProgress", boat.penaltyProgress),
            ("windDirection", boat.windDirection), ("windSpeed", boat.windSpeed), ("shadow", boat.shadow),
            ("finishTime", boat.finishTime),
        ]
        if let bad = doubles.first(where: { !($0.1?.isFinite ?? true) }) { return bad.0 }
        guard course.legs.indices.contains(boat.legIndex) else { return "legIndex" }
        let stages: Int
        switch course.legs[boat.legIndex] {
        case .round(let mark): stages = course.gates(forMark: mark).count
        case .finish: stages = 1 // a finishing boat has no rounding stages: always 0
        }
        guard (0..<stages).contains(boat.roundingStage) else { return "roundingStage" }
        guard boat.penaltyTurnsOwed >= 0 else { return "penaltyTurnsOwed" }
        return nil
    }
}
