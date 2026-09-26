import Foundation

/// The authoritative race simulation. Advance it with `step()`, one fixed tick of `Race.dt` at a time.
///
/// Determinism (ADR 0002): the step path draws randomness only from the race's `SplitMix64`,
/// never reads the wall clock, and never iterates a `Set` or `Dictionary` — their order depends on
/// a per-process hash seed. Look them up by key; iterate arrays. `DeterminismTests` scans for all three.
public final class Race {
    public static let timeLimitAfterFirstFinish = 180.0

    /// Simulation ticks per second. A server that falls behind catches up with several ticks, never a longer one.
    public static let tickRate = 30
    /// Seconds per tick.
    public static let dt = 1.0 / Double(tickRate)

    /// How a race is keyed, and whether it is the record.
    public enum Mode: Sendable {
        /// The race of record: the server's, a practice race on the device, a replay. It holds the secret
        /// wind seed (ADR 0001) and makes every key from it, keeps a `log`, and umpires (`UmpireState`).
        case authoritative(windSeed: WindSeed)
        /// How an online client predicts (#64, ADR 0005): no wind seed, only the revealed keys, which later
        /// keys join through `addRevealedWindKey(_:)`. It has no `log` and no umpire, and never emits a rule
        /// event (`RaceEvent.Kind.isRuleEvent`): rule calls come only from the server.
        case prediction(revealedWindKeys: [WindKey])
    }

    public let setup: RaceSetup
    /// The data files the race is sailed with, exactly those `setup` names (ADR 0004).
    public let files: RaceFiles
    /// The secret wind seed (ADR 0001), or nil for a prediction (`Mode.prediction`), which is how an
    /// online client predicts: it never holds the seed.
    public let windSeed: WindSeed?
    /// The course, derived from the files, the race seed's wind setup and the fleet size (#12, #80).
    public let course: CourseLayout
    /// The class every boat sails: hull, polar and handling (ADR 0004).
    public var boatClass: BoatClass { files.boatClass.content }
    /// The water's own motion (#78, ADR 0003), which carries every boat (#79): the venue's current at the
    /// tide state at the gun the race seed draws.
    public let current: CurrentField
    /// The tide state at the gun the log records (ADR 0003), or nil at a venue with no current.
    public let tideStateAtGun: Double?
    /// The umpire's memory: the authoritative race's alone, nil for a prediction.
    public let umpire: UmpireState?

    /// The bundled defaults (`RaceFiles.defaults`), for code that needs one of them without a race.
    public static var defaultBoatClass: BoatClass { RaceFiles.defaults.boatClass.content }
    public static var defaultConditions: ConditionsFile { RaceFiles.defaults.conditions }
    public static var defaultVenue: VenueFile { RaceFiles.defaults.venue }
    /// `defaultVenue`'s pairing for `defaultConditions`.
    public static var defaultPairing: Venue.Pairing { RaceFiles.defaults.pairing }
    public static var defaultRulesConfiguration: RulesConfigFile { RaceFiles.defaults.rulesConfiguration }

    /// The rules and race-format values this race uses (#73). So far the zone, the start sequence, the
    /// course and a rule call's penalty deadlines read it; the rest wait for the tickets that use them.
    public var rules: RulesConfig { files.rulesConfiguration.content }
    /// Every incident so far, by id and by pair of boats.
    public private(set) var incidents = IncidentIndex()

    /// The public wind setup, drawn from the race seed around the venue's pairing for the conditions:
    /// mean direction, base strength, trend direction; with the course's race area, where puffs spawn.
    public let windSetup: WindSetup
    /// The keyed wind (ADR 0001), holding the keys through the current window and no further.
    public private(set) var wind: WindField
    /// Makes this race's keys from its wind seed, one window at a time as the clock enters it. A seeded
    /// race (practice on the device, the server, a replay) is never missing a key. Nil for a keys-only
    /// race, which holds only the keys it is given (`addRevealedWindKey(_:)`) and never makes or guesses
    /// one: it steps with `tryStep()`, which refuses to enter a window it holds no key for.
    private var windKeys: WindKeyGenerator?
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

    private struct Pair: Hashable {
        let a: Int
        let b: Int
    }

    private var boatContacts = Set<Pair>()
    private var obstacleContacts = Set<Pair>()
    /// Seats touching an edge of the race area, by kind.
    private var edgeContacts = Set<WorldSnapshot.EdgeContact>()
    private var lastFoul: [Pair: Double] = [:]
    /// Every pair's overlap as of the last point of certainty (#87), updated once a tick.
    public private(set) var overlaps: OverlapTracker
    private var events: [RaceEvent] = []
    private var finishers = 0
    /// Inputs stamped for ticks not yet simulated, in the order they arrived.
    private var pending: [InputRecord] = []
    private var appliedInputs: [InputRecord] = []
    private var seatEvents: [SeatEvent] = []

    /// Builds the race at the start of its sequence, tick −`setup.startSequenceTicks`, from `files`, which
    /// must be exactly the ones `setup` names (`RaceFiles(resolving:)`); throws `RaceFilesError` if not.
    ///
    /// The public wind setup (mean direction, base strength, trend direction) is drawn from the race seed
    /// in the conditions with the venue's pairing for them; the course is derived from it, the fleet size,
    /// the laps, the class and the rules configuration (#12, #80), and its race area is where puffs spawn.
    /// The current's tide state at the gun comes from the race seed and the venue (#78). Everything that
    /// changes during the race comes from the key chain alone: the wind seed's, or the revealed keys for a
    /// prediction, never from the race seed (ADR 0001).
    ///
    /// The race runs no bots: every seat, bot or human, is sailed from outside through `apply` and
    /// `tap` (RegattaBots' seat controllers for bots, #60), so the log holds every input applied and
    /// a replay needs nothing but the log (ADR 0002). Names and the rest of the roster live outside too.
    ///
    /// A prediction steps with `tryStep()`, which throws `WindFieldError.missingKey` instead of entering a
    /// tick whose wind needs a key it doesn't hold; plain `step()` and `groundWind(at:)` trap there, as they
    /// would for a seeded race with a bug. If its keys don't cover the first tick, the boats' wind stays
    /// unset until the race imports a snapshot or steps.
    public convenience init(setup: RaceSetup, files: RaceFiles, mode: Mode) throws {
        try self.init(setup: setup, files: files, mode: mode, current: nil)
    }

    /// A race sailing in `current` instead of its venue's (the log still records the venue's tide state
    /// at the gun): for tests.
    init(setup: RaceSetup, files: RaceFiles, mode: Mode, current: CurrentField?) throws {
        try files.check(against: setup)
        self.setup = setup
        self.files = files
        let revealedWindKeys: [WindKey]
        switch mode {
        case .authoritative(let seed):
            windSeed = seed
            revealedWindKeys = []
            umpire = UmpireState()
        case .prediction(let keys):
            windSeed = nil
            revealedWindKeys = keys
            umpire = nil
        }
        var rng = SplitMix64(seed: setup.raceSeed.value)
        let drawn = WindSetup(conditions: files.conditions, pairing: files.pairing, raceSeed: setup.raceSeed)
        let course = CourseLayout.derive(windSetup: drawn, land: files.venue.content.land, fleetSize: setup.fleetSize,
                                         laps: setup.laps, boatClass: files.boatClass.content,
                                         rules: files.rulesConfiguration.content)
        self.course = course
        let windSetup = drawn.with(raceArea: course.raceArea)
        self.windSetup = windSetup
        self.current = current ?? CurrentField(venue: files.venue.content, raceSeed: setup.raceSeed)
        tideStateAtGun = CurrentField.tideStateAtGun(for: files.venue.content, raceSeed: setup.raceSeed)
        let windows = WindWindows(startSequenceTicks: setup.startSequenceTicks)
        wind = WindField(setup: windSetup, windows: windows, keys: WindKeyChain(revealedWindKeys))
        if let windSeed {
            do {
                windKeys = try WindKeyGenerator(windSeed: windSeed, setup: windSetup, windows: windows)
            } catch {
                preconditionFailure("\(files.conditions.ref) can't be keyed: \(error)")
            }
        }
        tick = -setup.startSequenceTicks

        // Prototype placement until the start row (#35), square to the line: seat 0 mid-line, the rest
        // scattered below it by the race seed, reaching along it. The draws are squeezed towards the line
        // to keep every boat at least a hull length inside the race area (#82), which reaches only a line
        // length below it.
        let centre = course.startLine.centre, up = course.upwind, right = course.right
        let hullLength = files.boatClass.content.hull.length
        let area = course.raceArea
        let below = area.halfLength + (centre - area.centre).dot(up)
        let across = area.halfWidth - abs((centre - area.centre).dot(right))
        let squeeze = Vec2(min(1, (across - hullLength) / 130), min(1, (below - hullLength) / 100))
        func onWater(_ offset: Vec2) -> Vec2 { centre + right * (offset.x * squeeze.x) + up * (offset.y * squeeze.y) }
        var fleet: [Boat] = []
        for seat in setup.seats.indices {
            let kind = setup.seats[seat]
            var offset = Vec2(0, -55)
            var heading = course.axis + Double.pi / 2
            if seat > 0 {
                for _ in 0..<50 {
                    offset = Vec2(rng.range(-130, 130), rng.range(-100, -35))
                    if fleet.allSatisfy({ ($0.position - onWater(offset)).length > 10 }) { break }
                }
                heading = course.axis + (rng.bool() ? Double.pi / 2 : -Double.pi / 2)
            }
            // The boom starts to leeward of the mean wind: the sampled wind may not be known yet (keys-only).
            fleet.append(Boat(id: seat, isPlayer: kind == .human, colorIndex: seat,
                              position: onWater(offset), heading: heading, speed: 2,
                              boomSide: .leeward(ofRelativeWind: wrapAngle(windSetup.meanDirection - heading))))
        }
        boats = fleet
        overlaps = OverlapTracker(seats: fleet.count)
        heldInputs = Array(repeating: .neutral, count: fleet.count)
        makeWindKeys()
        if windKeys != nil || (try? wind.requireKeys(atTick: tick)) != nil { refreshWind() }
    }

    /// An authoritative race on the files `setup` names (`RaceFiles(resolving:)`). Traps if this build
    /// can't resolve them: use `init(setup:files:mode:)` for a setup from outside.
    public convenience init(setup: RaceSetup, windSeed: WindSeed) {
        self.init(setup: setup, mode: .authoritative(windSeed: windSeed))
    }

    /// A prediction (`Mode.prediction`) on the files `setup` names, holding only the revealed `keys`.
    /// Traps if this build can't resolve the files: use `init(setup:files:mode:)` for a setup from outside.
    public convenience init(setup: RaceSetup, revealedWindKeys keys: [WindKey]) {
        self.init(setup: setup, mode: .prediction(revealedWindKeys: keys))
    }

    private convenience init(setup: RaceSetup, mode: Mode) {
        do {
            try self.init(setup: setup, files: RaceFiles(resolving: setup), mode: mode)
        } catch {
            preconditionFailure("the race files \(setup) names failed to resolve: \(error)")
        }
    }

    // MARK: - Input

    /// Holds `input` for `seat` from tick `stamp` until the seat sends another. A stamp the race has
    /// already simulated applies at the next tick instead, and is logged there (#18).
    /// Returns the tick it applies at, or nil if rejected: an unknown seat or a race that is over.
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

    /// The race so far as a log: its keys, and every input and seat event exactly as applied. Nil for a
    /// keys-only race: it is a prediction, never the record (ADR 0005), and has no wind seed to log.
    public var log: RaceLog? {
        guard let windSeed else { return nil }
        return RaceLog(header: .init(setup: setup, windSeed: windSeed, tideStateAtGun: tideStateAtGun), inputs: appliedInputs,
                seatEvents: seatEvents, finalTick: tick)
    }

    private func acceptsInput(from seat: Int) -> Bool {
        boats.indices.contains(seat) && !isOver
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
                // The same wind angle with the boom on the other side: a tack upwind, a gybe downwind.
                let b = boats[i]
                if b.isOnCourse {
                    boats[i].autopilot = .tackOrGybe(heading: b.heading, boomSide: b.boomSide, windDirection: b.windDirection)
                }
            case .protest(let target):
                emit(.protestRecorded(seat: i, target: target))
            }
        }
    }

    // MARK: - Simulation

    public func drainEvents() -> [RaceEvent] {
        defer { events.removeAll() }
        return events
    }

    private func emit(_ kind: RaceEvent.Kind) {
        // A prediction has no umpire: its rule events would be guesses, and the server's are the calls.
        if umpire == nil && kind.isRuleEvent { return }
        events.append(RaceEvent(tick: tick, kind: kind))
    }

    /// Advances the race by one tick, like `step()`, unless the race is keys-only and the next tick's
    /// wind needs a key it doesn't hold: then it throws `missingKey` and leaves the race unchanged, so a
    /// client can fetch the key (#64: request a `Resync`) instead of guessing the wind (ADR 0001). A
    /// seeded race makes its own keys, so for it this is exactly `step()` and never throws.
    ///
    /// It samples the wind first exactly where the step will: at every boat's position at the next tick
    /// (`refreshWind`), which needs every key back to `WindField.firstWindowNeeded(atTick:)` for the
    /// puffs (#76) that may still be alive. A new read of the wind inside `step()`, such as the
    /// geographic grid (#77) sampled anywhere else, must be checked here too, or a keys-only race could
    /// trap where it should throw.
    public func tryStep() throws(WindFieldError) {
        if windKeys == nil && !isOver {
            for boat in boats { _ = try wind.sample(boat.position, tick: tick + 1) }
        }
        step()
    }

    /// Adds a key the server revealed (ADR 0001, #95) to a keys-only race, replacing any key held for its
    /// window. Returns false, adding nothing, for a seeded race: it makes its own keys.
    @discardableResult
    public func addRevealedWindKey(_ key: WindKey) -> Bool {
        guard windKeys == nil else { return false }
        wind.add(key)
        return true
    }

    /// Whether the race holds only revealed keys and no wind seed.
    public var isKeysOnly: Bool { windKeys == nil }

    /// Advances the race by one tick.
    public func step() {
        guard !isOver else { return }
        tick += 1
        makeWindKeys()
        if tick == 0 { fireGun() }

        refreshWind()
        applyWindShadows()

        applyInputs()

        let previous = boats.map(\.position)
        for i in boats.indices { integrate(i, Race.dt) }
        // Where the boats sailed to, before contacts push them apart: a call at a contact this tick
        // reads this tick's certain overlap.
        overlaps.update(boats, hull: boatClass.hull, margin: lastPointOfCertaintyTicks)
        resolveBoatContacts()
        resolveObstacleContacts()
        resolveEdgeContacts()
        for i in boats.indices { updateProgress(i, from: previous[i]) }
        checkForEnd()
    }

    /// The ground wind at `p` now. A seeded race holds every key through the current window, and a
    /// keys-only one does once it has stepped or imported a snapshot, so this never fails; if it ever
    /// did, it traps rather than extrapolate (ADR 0001).
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
        guard windKeys != nil else { return }
        let current = wind.windows.window(containing: tick)
        while windKeys!.nextWindow <= current { wind.add(windKeys!.next()) }
    }

    /// Samples every boat's wind over the ground and current at her position, and resolves her three
    /// winds (`BoatWinds`) from them and her velocity through the water.
    private func refreshWind() {
        for i in boats.indices {
            let flow = current.sample(boats[i].position, tick: tick)
            let winds = BoatWinds.resolve(ground: Wind(groundWind(at: boats[i].position)), current: flow,
                                          velocityThroughWater: boats[i].velocity)
            boats[i].current = flow
            boats[i].windOverGround = winds.overGround
            boats[i].sailingWind = winds.sailing
            boats[i].apparentWind = winds.apparent
        }
    }

    /// Every boat on the course takes the shadow and backwind of every other one on it (#10); a ghost
    /// takes none and casts none.
    private func applyWindShadows() {
        let cones = boats.indices.map(shadowCone(ofSeat:))
        for i in boats.indices {
            guard boats[i].isOnCourse else {
                boats[i].shadow = 1
                continue
            }
            let others = cones.indices.compactMap { $0 == i ? nil : cones[$0] }
            boats[i].shadow = ShadowCone.factor(at: boats[i].position, of: others, floor: boatClass.windShadow.stackingFloor)
        }
    }

    /// The wind shadow and backwind `seat`'s boat casts now, along her apparent wind (#10), or nil for a
    /// ghost, which casts none, or an unknown seat.
    public func shadowCone(ofSeat seat: Int) -> ShadowCone? {
        guard boats.indices.contains(seat), boats[seat].isOnCourse else { return nil }
        return ShadowCone(caster: boats[seat], shadow: boatClass.windShadow)
    }

    private func integrate(_ i: Int, _ dt: Double) {
        var b = boats[i]

        if let pilot = b.autopilot {
            if let rudder = pilot.rudder(heading: b.heading, boomSide: b.boomSide, windDirection: b.windDirection) {
                b.desiredRudder = rudder
            } else {
                b.autopilot = nil
                b.desiredRudder = 0
            }
        }

        let before = b.heading
        // The polar reads the sailing wind (#14); shadow slows it and never turns it (#10). The current
        // carries every boat, ghosts too (#11).
        let tws = b.sailingWind.speed * b.shadow
        let moved = BoatDynamics.advance(
            BoatDynamics.State(position: b.position, heading: b.heading, speed: b.speed, rudder: b.rudder, boomSide: b.boomSide),
            control: BoatDynamics.Control(rudder: b.desiredRudder, ease: heldInputs[i].ease, sailing: b.isOnCourse),
            env: BoatDynamics.Environment(windDirection: b.sailingWind.direction, windSpeed: tws, current: b.current),
            boatClass: boatClass, dt: dt)
        b.position = moved.position
        b.heading = moved.heading
        b.speed = moved.speed
        b.rudder = moved.rudder
        let crossing = moved.boomSide != b.boomSide
        b.boomSide = moved.boomSide
        let turn = wrapAngle(b.heading - before)

        if b.penaltyTurnsOwed > 0 {
            b.penaltyProgress += turn
            if abs(b.penaltyProgress) >= 2 * .pi * Double(b.penaltyTurnsOwed) {
                b.penaltyTurnsOwed = 0
                b.penaltyProgress = 0
                emit(.penaltyServed(seat: i))
            }
        }

        // Rule 13: from the boom crossing head to wind until close-hauled on the new tack.
        if crossing {
            b.isTacking = b.twa < .pi / 2
            emit(b.isTacking ? .tacked(seat: i) : .gybed(seat: i))
        }
        if b.isTacking && b.twa >= boatClass.polar.bestUpwind(tws: tws).twa - deg2rad(5) {
            b.isTacking = false
        }

        boats[i] = b
    }

    // MARK: - Contact and rules

    /// The last point of certainty in ticks (15 in fleet-rules@1).
    private var lastPointOfCertaintyTicks: Int { RulesConfig.ticks(rules.incidents.lastPointOfCertainty) }

    /// Whether seats `a` and `b` are overlapped as of their last point of certainty.
    public func isOverlapped(_ a: Int, _ b: Int) -> Bool { overlaps.isOverlapped(a, b) }

    /// Which of seats `a` and `b` must keep clear under rules 10–13 now (`Rules.rightOfWay`), with their
    /// overlap as of the last point of certainty. Nil if either is a ghost. For glyphs and bots.
    public func rightOfWay(_ a: Int, _ b: Int) -> RightOfWay? {
        Rules.rightOfWay(boats[a], boats[b], overlapped: overlaps.isOverlapped(a, b), hull: boatClass.hull)
    }

    private func resolveBoatContacts() {
        var touching = Set<Pair>()
        let outline = boatClass.hull.outline
        let hulls = boats.map { $0.hull(outline: outline) }
        // A ghost can't be touched.
        for i in boats.indices where !boats[i].isGhost {
            for j in (i + 1)..<boats.count where !boats[j].isGhost {
                guard (boats[i].position - boats[j].position).length < boatClass.hull.length * 1.3,
                      let push = Collision.penetration(hulls[i], hulls[j])
                else { continue }

                let pair = Pair(a: i, b: j)
                touching.insert(pair)
                if !boatContacts.contains(pair) {
                    boats[i].speed = BoatDynamics.speed(after: .boat, speed: boats[i].speed, boatClass: boatClass)
                    boats[j].speed = BoatDynamics.speed(after: .boat, speed: boats[j].speed, boatClass: boatClass)
                    if (lastFoul[pair] ?? -.infinity) + 5 < time,
                       let verdict = Rules.judge(boats[i], boats[j], overlapped: overlaps.isOverlapped(i, j),
                                                 course: course, hull: boatClass.hull) {
                        lastFoul[pair] = time
                        call(verdict)
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
                guard (boats[i].position - obstacle.position).length < boatClass.hull.length + obstacle.radius,
                      let push = Collision.penetration(polygon: boats[i].hull(outline: boatClass.hull.outline), circle: obstacle.position, radius: obstacle.radius)
                else { continue }
                let pair = Pair(a: i, b: k)
                touching.insert(pair)
                if !obstacleContacts.contains(pair) {
                    boats[i].speed = BoatDynamics.speed(after: .mark, speed: boats[i].speed, boatClass: boatClass)
                    penalize(i, turns: 1)
                    emit(.markTouch(seat: i, mark: obstacle.name))
                }
                boats[i].position += push
            }
        }
        obstacleContacts = touching
    }

    /// Keeps every boat on the course in the race area (#12, #82): out of the land and inside the
    /// boundary (`CourseLayout.resolveEdges`). Heading into an edge she keeps only her speed along it, and
    /// on the tick a touch begins only the course's `edgeSpeedRetention` of that (`RaceEdges.speed`); her
    /// heading and rudder are her own, so she can steer away. A touch is no foul: it costs no penalty,
    /// and when it begins it is announced and recorded (`IncidentIndex.obstructionContacts`). Only Section
    /// A of the rules applies near land (#12), so no rule 19. A ghost sails through.
    private func resolveEdgeContacts() {
        var touching = Set<WorldSnapshot.EdgeContact>()
        let outline = boatClass.hull.outline
        for i in boats.indices where boats[i].isOnCourse {
            let resolution = course.resolveEdges(hull: boats[i].hull(outline: outline))
            guard !resolution.touches.isEmpty else { continue }
            boats[i].position += resolution.push
            for touch in resolution.touches {
                let contact = WorldSnapshot.EdgeContact(seat: i, kind: touch.kind)
                touching.insert(contact)
                let begins = !edgeContacts.contains(contact)
                boats[i].speed = RaceEdges.speed(boats[i].speed, forward: boats[i].forward, normal: touch.normal,
                                                 begins: begins, retention: course.edgeSpeedRetention)
                if begins {
                    incidents.recordObstructionContact(
                        ObstructionContact(tick: tick, leg: boats[i].legIndex, seat: i, kind: touch.kind))
                    emit(.obstructionContact(seat: i, kind: touch.kind))
                }
            }
        }
        edgeContacts = touching
    }

    /// Turns a foul costs today, until the penalty rules move to the single penalty turn.
    private static let foulTurns = 2

    /// Opens an incident for `verdict`, decides it with a rule call, penalises the offender and
    /// announces the call. The deadlines come from the rules configuration; nothing enforces them yet.
    private func call(_ verdict: Verdict) {
        let leg = boats[verdict.offender].legIndex
        var incident = incidents.open(between: verdict.offender, and: verdict.victim, tick: tick, leg: leg)
        let penalty = rules.raceFormat.penalty
        let call = RuleCall(
            incidentId: incident.id, tick: tick, rule: verdict.rule, offender: verdict.offender, victim: verdict.victim,
            leg: leg, turnsOwed: Race.foulTurns,
            startDeadlineTick: tick + RulesConfig.ticks(penalty.start),
            completeDeadlineTick: tick + RulesConfig.ticks(penalty.complete))
        incident.outcome = .called(call)
        incidents.update(incident)
        penalize(verdict.offender, turns: Race.foulTurns)
        emit(.ruleCall(call))
    }

    private func penalize(_ i: Int, turns: Int) {
        if boats[i].penaltyTurnsOwed == 0 { boats[i].penaltyProgress = 0 }
        boats[i].penaltyTurnsOwed = min(boats[i].penaltyTurnsOwed + turns, 4)
    }

    // MARK: - Start, roundings, finish

    private func fireGun() {
        for i in boats.indices where boats[i].status == .prestart && course.startLine.side(boats[i].position) > 0 {
            boats[i].status = .ocs
            emit(.ocsNotice(recipient: i))
        }
        emit(.gun)
    }

    private func updateProgress(_ i: Int, from p0: Vec2) {
        let p1 = boats[i].position
        let lineCrossing = crossing(from: p0, to: p1, over: course.startLine.segment)

        switch boats[i].status {
        case .prestart:
            if time >= 0 && lineCrossing == 1 {
                boats[i].status = .racing
                boats[i].legIndex = 0
                boats[i].roundingStage = 0
                emit(.started(seat: i))
            }
        case .ocs:
            if course.startLine.side(p1) < 0 {
                boats[i].status = .prestart
                emit(.cleared(seat: i))
            }
        case .racing:
            let leg = course.legs[boats[i].legIndex]
            var progress = CourseLayout.Progress(legIndex: boats[i].legIndex, stage: boats[i].roundingStage)
            course.advance(&progress, from: p0, to: p1)
            if progress.finished {
                finish(i)
            } else {
                if progress.legIndex > boats[i].legIndex { emit(.rounded(seat: i, mark: course.name(of: leg))) }
                boats[i].legIndex = progress.legIndex
                boats[i].roundingStage = progress.stage
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
        emit(.raceClosed)
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
        case .prestart, .ocs: return (2, (b.position - course.startLine.centre).length)
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
        let edges = boats.indices.flatMap { seat in
            ObstructionKind.allCases.map { WorldSnapshot.EdgeContact(seat: seat, kind: $0) }.filter(edgeContacts.contains)
        }
        return WorldSnapshot(
            tick: tick,
            seats: boats.indices.map { WorldSnapshot.Seat(boat: boats[$0], heldInput: heldInputs[$0]) },
            touchingBoats: boatPairs, touchingObstacles: obstacles, touchingEdges: edges, foulMemory: fouls,
            incidents: incidents,
            firstFinishTime: firstFinishTime, isOver: isOver, windKeys: wind.keys,
            overlaps: overlaps.memory
        )
    }

    /// Replaces the world with `snapshot`, so stepping on continues from its tick (ADR 0005). The race
    /// keeps what isn't world state: its setup, course and wind seed. Bots run outside the race (#60),
    /// and their memory isn't in a snapshot, so bots driving a restored race won't make the same decisions.
    /// Inputs queued but not yet applied and undrained events are dropped. `log` is left as it was and
    /// no longer describes the race: a race that imports is a prediction, never the record. The
    /// authoritative host never imports a snapshot a client could have supplied (ADR 0005).
    ///
    /// The wind is a function of the tick and the keys (ADR 0001), so the race takes the snapshot's
    /// keys, which must be this race's, and moves its own key generator (which holds the wind seed, never
    /// in a snapshot) to just after them, so the keys it makes as the clock runs on are the ones the
    /// exporting race would have made. The generator is rebuilt from the wind seed when the snapshot
    /// holds fewer keys than it has made: at most one HMAC per window.
    /// A keys-only race has no generator: it takes the snapshot's keys, and adds revealed keys after them.
    ///
    /// Throws, leaving the race unchanged, for a snapshot it couldn't sail on from: another fleet
    /// size, a tick outside the sequence start … `WorldSnapshot.maxTick`, a non-finite value, a leg or
    /// rounding stage the course doesn't have, a negative penalty count, a bad contact, overlap, incident or
    /// obstruction contact, or a missing key from the first window the wind at the snapshot's tick needs
    /// (`WindField.firstWindowNeeded`: the window before the snapshot's, or further back for puffs that
    /// may still be alive) through the last key it holds.
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
        let kinds = ObstructionKind.allCases
        let edgeOrder = { (e: WorldSnapshot.EdgeContact) in e.seat * kinds.count + kinds.firstIndex(of: e.kind)! }
        guard snapshot.touchingEdges.allSatisfy({ seatRange.contains($0.seat) }),
              zip(snapshot.touchingEdges, snapshot.touchingEdges.dropFirst()).allSatisfy({ edgeOrder($0) < edgeOrder($1) })
        else { throw WorldSnapshotError.invalidContact }
        if let bad = snapshot.incidents.incidents.first(where: {
            !seatRange.contains($0.parties.low) || !seatRange.contains($0.parties.high)
                || !course.legs.indices.contains($0.leg) || $0.tick > snapshot.tick
        }) {
            throw WorldSnapshotError.invalidIncident(id: bad.id)
        }
        if let bad = snapshot.incidents.obstructionContacts.firstIndex(where: {
            !seatRange.contains($0.seat) || !course.legs.indices.contains($0.leg) || $0.tick > snapshot.tick
        }) {
            throw WorldSnapshotError.invalidObstructionContact(index: bad)
        }
        let margin = lastPointOfCertaintyTicks
        for (k, entry) in snapshot.overlaps.enumerated() {
            let ascending = k == 0 || snapshot.overlaps[k - 1].pair.a < entry.pair.a
                || (snapshot.overlaps[k - 1].pair.a == entry.pair.a && snapshot.overlaps[k - 1].pair.b < entry.pair.b)
            guard validPair(entry.pair), ascending, (0..<max(margin, 1)).contains(entry.changeTicks) else {
                throw WorldSnapshotError.invalidOverlap
            }
        }

        let snapshotWind = WindField(setup: windSetup, windows: wind.windows, keys: snapshot.windKeys)
        do {
            try snapshotWind.requireKeys(atTick: snapshot.tick)
        } catch {
            switch error {
            case .missingKey(let window): throw WorldSnapshotError.missingWindKey(window)
            case .beforeOrigin: throw WorldSnapshotError.tickBeforeStart(snapshot.tick)
            }
        }
        // From the first window the wind at the snapshot's tick needs on, the keys must run without a
        // gap: the generator resumes after the last one, so a missing key in between would never be
        // made, and the wind would trap when the clock reached it.
        let firstNeeded = snapshotWind.firstWindowNeeded(atTick: snapshot.tick)
        if let gap = (firstNeeded..<max(firstNeeded, snapshot.windKeys.endWindow)).first(where: { snapshot.windKeys[$0] == nil }) {
            throw WorldSnapshotError.missingWindKey(gap)
        }
        // A keys-only race has no generator: it keeps the snapshot's keys and adds revealed ones.
        var generator = windKeys
        if let windSeed, var seeded = generator {
            if seeded.nextWindow > snapshot.windKeys.endWindow {
                do {
                    seeded = try WindKeyGenerator(windSeed: windSeed, setup: windSetup, windows: wind.windows)
                } catch {
                    preconditionFailure("the race's own conditions can't be keyed: \(error)")
                }
            }
            _ = seeded.keys(through: snapshot.windKeys.endWindow - 1)
            generator = seeded
        }

        wind = snapshotWind
        windKeys = generator

        tick = snapshot.tick
        boats = snapshot.seats.map(\.boat)
        heldInputs = snapshot.seats.map(\.heldInput)
        boatContacts = Set(snapshot.touchingBoats.map { Pair(a: $0.a, b: $0.b) })
        obstacleContacts = Set(snapshot.touchingObstacles.map { Pair(a: $0.seat, b: $0.obstacle) })
        edgeContacts = Set(snapshot.touchingEdges)
        var foulTimes: [Pair: Double] = [:]
        for memory in snapshot.foulMemory { foulTimes[Pair(a: memory.pair.a, b: memory.pair.b)] = memory.time }
        lastFoul = foulTimes
        overlaps = OverlapTracker(seats: boats.count, memory: snapshot.overlaps)
        incidents = snapshot.incidents
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
            ("autopilot", boat.autopilot?.heading), ("penaltyProgress", boat.penaltyProgress),
            ("windOverGround.direction", boat.windOverGround.direction), ("windOverGround.speed", boat.windOverGround.speed),
            ("sailingWind.direction", boat.sailingWind.direction), ("sailingWind.speed", boat.sailingWind.speed),
            ("apparentWind.direction", boat.apparentWind.direction), ("apparentWind.speed", boat.apparentWind.speed),
            ("current.x", boat.current.x), ("current.y", boat.current.y), ("shadow", boat.shadow),
            ("finishTime", boat.finishTime),
        ]
        if let bad = doubles.first(where: { !($0.1?.isFinite ?? true) }) { return bad.0 }
        guard course.legs.indices.contains(boat.legIndex) else { return "legIndex" }
        let stages: Int
        switch course.legs[boat.legIndex] {
        case .round: stages = course.roundingStages(of: course.legs[boat.legIndex]).count
        case .finish: stages = 1 // a finishing boat has no rounding stages: always 0
        }
        guard (0..<stages).contains(boat.roundingStage) else { return "roundingStage" }
        guard boat.penaltyTurnsOwed >= 0 else { return "penaltyTurnsOwed" }
        return nil
    }
}
