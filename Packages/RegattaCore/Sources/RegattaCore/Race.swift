import Foundation

/// The authoritative race simulation. Advance it with `step()`, one fixed tick of `Race.dt` at a time.
///
/// Determinism (ADR 0002): the step path draws randomness only from the race's `SplitMix64`,
/// never reads the wall clock, and never iterates a `Set` or `Dictionary` — their order depends on
/// a per-process hash seed. Look them up by key; iterate arrays. `DeterminismTests` scans for all three.
public final class Race {
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
    /// Each leg's target (`CourseLayout.targetPosition(for:)`), by leg index: what `distanceToFinish(of:)`
    /// measures to on a rounding leg.
    private let legTargets: [Vec2]
    /// For each rounding leg, by leg index, the metres from its target on through every later leg's target to
    /// the nearest point of the finish line (`distanceToFinish(of:)`); 0 for the finish leg.
    private let remainingAfterTarget: [Double]
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
    /// course, the start row, a rule call's penalty deadlines and the close (the finish window and the time
    /// limit, `closeTick`) read it; the rest wait for the tickets that use them.
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
    /// A test's wind over the ground by tick, in place of the keyed wind's (`init(setup:files:mode:current:wind:)`).
    private let scriptedWind: ((_ tick: Int) -> GroundWind)?
    /// One boat per seat: `boats[seat]`.
    public private(set) var boats: [Boat]
    /// Each seat's held input, in force until the seat sends a different one.
    public private(set) var heldInputs: [BoatInput]
    /// Race clock in ticks; negative during the start sequence, 0 at the gun.
    public private(set) var tick: Int
    /// Race clock in seconds, derived from `tick` so it never accumulates rounding.
    public var time: Double { Double(tick) / Double(Race.tickRate) }
    /// Whether the race has closed (`closeTick`, `closeAllGone`). A closed race never steps again and takes
    /// no more input or seat events.
    public private(set) var isOver = false
    /// When the first boat finished, race seconds: it opens the finish window (#8). A DSQ at the line doesn't.
    public private(set) var firstFinishTime: Double?
    /// The results, fixed as the race closes; nil until then (#86).
    public private(set) var results: RaceResults?
    /// The all-gone close, for the log (`RaceLog.allGoneClose`).
    private var allGoneClose: RaceLog.AllGoneClose?

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
    /// at the gun), and in `wind` instead of its keyed wind's over the ground, the same everywhere on the
    /// water at each tick: for tests. The keys are made and held as ever.
    init(setup: RaceSetup, files: RaceFiles, mode: Mode, current: CurrentField?,
         wind scriptedWind: ((_ tick: Int) -> GroundWind)? = nil) throws {
        try files.check(against: setup)
        self.setup = setup
        self.files = files
        self.scriptedWind = scriptedWind
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
        let drawn = WindSetup(conditions: files.conditions, pairing: files.pairing, raceSeed: setup.raceSeed)
        let course = CourseLayout.derive(windSetup: drawn, land: files.venue.content.land, fleetSize: setup.fleetSize,
                                         laps: setup.laps, boatClass: files.boatClass.content,
                                         rules: files.rulesConfiguration.content)
        self.course = course
        let targets = course.legs.map(course.targetPosition(for:))
        legTargets = targets
        remainingAfterTarget = Race.remainingAfterTargets(targets, legs: course.legs, finish: course.finishLine.segment)
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

        // The start row (#35): every boat in her slot (squeezed only where the race area needs it, #82), on
        // starboard, reaching towards the pin at the row's true wind angle and fraction of polar speed in the
        // race's base strength. The public wind setup, not the wind at her: a prediction may not hold the
        // first window's key yet (ADR 0001). Boom to port: starboard tack. Her rudder is centred, so her
        // autohelm engages on the first step at the wind angle she has then, and holds the reach until
        // she steers (#219, ADR 0007).
        let boatClass = files.boatClass.content
        let row = course.startRow(fleetSize: setup.fleetSize, raceSeed: setup.raceSeed, hullLength: boatClass.hull.length)
        let rowHeading = course.startRowHeading
        let rowSpeed = course.placement.polarSpeedFraction
            * boatClass.polar.speed(twa: course.placement.trueWindAngle, tws: windSetup.baseStrength)
        let fleet = setup.seats.indices.map { seat in
            Boat(id: seat, isPlayer: setup.seats[seat] == .human, colorIndex: seat, position: row[seat],
                 heading: rowHeading, speed: rowSpeed, boomSide: .port)
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

    /// Records a change in who is at `seat`, stamped with the current tick. Returns nil for an unknown seat
    /// or a closed race: the results are fixed and the log ends at the close, so a replay reads every seat
    /// event before it closes, as the race did.
    @discardableResult
    public func record(_ kind: SeatEvent.Kind, seat: Int) -> SeatEvent? {
        guard boats.indices.contains(seat), !isOver else { return nil }
        let event = SeatEvent(tick: tick, seat: seat, kind: kind)
        seatEvents.append(event)
        return event
    }

    /// The race so far as a log: its keys, and every input and seat event exactly as applied. Nil for a
    /// keys-only race: it is a prediction, never the record (ADR 0005), and has no wind seed to log.
    public var log: RaceLog? {
        guard let windSeed else { return nil }
        return RaceLog(header: .init(setup: setup, windSeed: windSeed, tideStateAtGun: tideStateAtGun), inputs: appliedInputs,
                seatEvents: seatEvents, finalTick: tick, allGoneClose: allGoneClose)
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

        // A held rudder off centre steers, and lets go of the autohelm and any tap it is sailing (#13). A
        // centred one leaves her to the autohelm, which captures her wind angle on the tick it centres (ADR 0007).
        for i in boats.indices {
            let rudder = heldInputs[i].rudderValue
            if abs(rudder) > Autohelm.deadBand {
                boats[i].autohelm = nil
                boats[i].desiredRudder = rudder
            } else if boats[i].autohelm == nil {
                engageAutohelm(i)
            }
        }

        for record in taps {
            appliedInputs.append(record)
            guard case .tap(let tap) = record.kind else { continue }
            let i = record.seat
            switch tap {
            case .tackGybe:
                // The autohelm sails her through head to wind or the gybe to the groove on the new tack.
                let b = boats[i]
                if !b.isGhost { boats[i].autohelm = .tackOrGybe(sailingAngle: b.sailingAngle) }
            case .protest(let target):
                emit(.protestRecorded(seat: i, target: target))
            }
        }
    }

    /// Engages seat `i`'s autohelm on the angle she sails now, against the grooves in the wind they read
    /// this tick (`Boat.grooveWindSpeed`), and announces a snap to the groove (#124).
    private func engageAutohelm(_ i: Int) {
        let b = boats[i]
        let engaged = Autohelm.engage(sailingAngle: b.sailingAngle, tws: b.grooveWindSpeed, boatClass: boatClass)
        boats[i].autohelm = engaged.autohelm
        if engaged.snapped { emit(.grooveSnap(seat: i)) }
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
        averageGrooveWinds()

        applyInputs()

        let previous = boats
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
        if let scriptedWind { return scriptedWind(tick) }
        do {
            return try wind.sample(p, tick: tick)
        } catch {
            preconditionFailure("race at tick \(tick) is missing wind: \(error)")
        }
    }

    /// The ground wind at `p` now, as `groundWind(at:)`, or nil where a keys-only race doesn't hold the key
    /// for now yet: for a reader outside the step (`SeatView`), which must not trap.
    func heldGroundWind(at p: Vec2) -> GroundWind? {
        if let scriptedWind { return scriptedWind(tick) }
        return try? wind.sample(p, tick: tick)
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
    /// takes none and casts none (#30).
    private func applyWindShadows() {
        let cones = boats.indices.map(shadowCone(ofSeat:))
        for i in boats.indices {
            guard !boats[i].isGhost else {
                boats[i].shadow = 1
                continue
            }
            let others = cones.indices.compactMap { $0 == i ? nil : cones[$0] }
            boats[i].shadow = ShadowCone.factor(at: boats[i].position, of: others, floor: boatClass.windShadow.stackingFloor)
        }
    }

    /// Moves every boat's average of the wind speed her polar reads a tick on (`Boat.averagedWindSpeed`):
    /// what her autohelm's grooves follow (#245), once the wind and shadows are sampled this tick.
    private func averageGrooveWinds() {
        let timeConstant = boatClass.steering.autohelm.grooveWindAverage
        for i in boats.indices { boats[i].averageWind(dt: Race.dt, timeConstant: timeConstant) }
    }

    /// The wind shadow and backwind `seat`'s boat casts now, along her apparent wind (#10), or nil for a
    /// ghost, which casts none, or an unknown seat.
    public func shadowCone(ofSeat seat: Int) -> ShadowCone? {
        guard boats.indices.contains(seat), !boats[seat].isGhost else { return nil }
        return ShadowCone(caster: boats[seat], shadow: boatClass.windShadow)
    }

    private func integrate(_ i: Int, _ dt: Double) {
        var b = boats[i]
        // The polar reads the sailing wind (#14); shadow slows it and never turns it (#10). The current
        // carries every boat, ghosts too (#11). The autohelm's grooves read the class's average of it (#245).
        let tws = b.polarWindSpeed

        if let helm = b.autohelm {
            b.desiredRudder = helm.rudder(sailingAngle: b.sailingAngle, boomSide: b.boomSide, tws: tws,
                                          grooveTWS: b.grooveWindSpeed, boatClass: boatClass)
        }

        let before = b.heading
        let moved = BoatDynamics.advance(
            BoatDynamics.State(position: b.position, heading: b.heading, speed: b.speed, rudder: b.rudder, boomSide: b.boomSide,
                               isPlaning: b.isPlaning, spinnaker: b.spinnaker),
            control: BoatDynamics.Control(rudder: b.desiredRudder, ease: heldInputs[i].ease, sailing: !b.isGhost),
            env: BoatDynamics.Environment(windDirection: b.sailingWind.direction, windSpeed: tws, current: b.current),
            boatClass: boatClass, dt: dt)
        b.position = moved.position
        b.heading = moved.heading
        b.speed = moved.speed
        b.rudder = moved.rudder
        b.isPlaning = moved.isPlaning
        b.spinnaker = moved.spinnaker
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
            // The tap has crossed the boom: the autohelm holds the groove on the new tack.
            b.autohelm?.isTapping = false
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

    /// `rightOfWay(seat, other)` for every seat in order, nil at `seat` itself: one seat's relation to the
    /// whole fleet, as `SeatView` shows it, in one pass.
    func rightsOfWay(of seat: Int) -> [RightOfWay?] {
        let hull = boatClass.hull
        let boat = boats[seat]
        return boats.indices.map { other in
            other == seat ? nil : Rules.rightOfWay(boat, boats[other], overlapped: overlaps.isOverlapped(seat, other), hull: hull)
        }
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
        for i in boats.indices where !boats[i].isGhost {
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
    /// on the tick a touch begins only the course's `edgeSpeedRetention` of that (`RaceEdges.speed`); land
    /// and boundary touched in one tick are one edge, facing the way her hull is pushed, so she loses her
    /// speed to them once. Her heading and rudder are her own, so she can steer away. A touch lasts until
    /// she is more than `RaceEdges.touchMargin` clear of that edge. A touch is no foul: it costs no
    /// penalty, and when it begins it is announced and recorded (`IncidentIndex.obstructionContacts`).
    /// Only Section A of the rules applies near land (#12), so no rule 19. A ghost sails through.
    private func resolveEdgeContacts() {
        var touching = Set<WorldSnapshot.EdgeContact>()
        let outline = boatClass.hull.outline
        for i in boats.indices where !boats[i].isGhost {
            let resolution = course.resolveEdges(hull: boats[i].hull(outline: outline))
            let beginning = resolution.touches.filter { !edgeContacts.contains(.init(seat: i, kind: $0)) }
            if !resolution.touches.isEmpty {
                boats[i].position += resolution.push
                boats[i].speed = RaceEdges.speed(boats[i].speed, forward: boats[i].forward, normal: resolution.normal,
                                                 begins: !beginning.isEmpty, retention: course.edgeSpeedRetention)
            }
            for kind in resolution.touches { touching.insert(WorldSnapshot.EdgeContact(seat: i, kind: kind)) }
            for kind in beginning {
                incidents.recordObstructionContact(ObstructionContact(tick: tick, leg: boats[i].legIndex, seat: i, kind: kind))
                emit(.obstructionContact(seat: i, kind: kind))
            }
            for kind in ObstructionKind.allCases where !resolution.touches.contains(kind) {
                let contact = WorldSnapshot.EdgeContact(seat: i, kind: kind)
                if edgeContacts.contains(contact),
                   course.isNear(kind, hull: boats[i].hull(outline: outline), within: RaceEdges.touchMargin) {
                    touching.insert(contact)
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

    /// OCS (#9, rule 29.1): any point of her hull on the course side of the line or its extensions at the gun.
    private func fireGun() {
        for i in boats.indices where boats[i].status == .prestart && isOverStartLine(boats[i]) {
            boats[i].status = .ocs
            emit(.ocsNotice(recipient: i))
        }
        emit(.gun)
    }

    /// Whether any point of `boat`'s hull is on the course side of the start line or its extensions.
    private func isOverStartLine(_ boat: Boat) -> Bool {
        boat.hull(outline: boatClass.hull.outline).contains { course.startLine.side($0) > 0 }
    }

    /// Whether any point of the hull crossed the start line itself, not an extension, from the pre-start
    /// side, on the move from `before` to `after`.
    private func crossesStartLine(from before: Boat, to after: Boat) -> Bool {
        let outline = boatClass.hull.outline
        return zip(before.hull(outline: outline), after.hull(outline: outline)).contains {
            crossing(from: $0, to: $1, over: course.startLine.segment) == 1
        }
    }

    /// Advances seat `i`'s start and rounding progress over this tick's move from `before`.
    private func updateProgress(_ i: Int, from before: Boat) {
        switch boats[i].status {
        case .prestart:
            if time >= 0 && crossesStartLine(from: before, to: boats[i]) {
                boats[i].status = .racing
                boats[i].legIndex = 0
                boats[i].roundingStage = 0
                emit(.started(seat: i))
            }
        case .ocs:
            // Cleared once her whole hull is back on the pre-start side of the line or its extensions.
            if !isOverStartLine(boats[i]) {
                boats[i].status = .prestart
                emit(.cleared(seat: i))
            }
        case .racing:
            let leg = course.legs[boats[i].legIndex]
            var progress = CourseLayout.Progress(legIndex: boats[i].legIndex, stage: boats[i].roundingStage)
            course.advance(&progress, from: before.position, to: boats[i].position)
            if progress.finished {
                finish(i)
            } else {
                if progress.legIndex > boats[i].legIndex { emit(.rounded(seat: i, mark: course.name(of: leg))) }
                boats[i].legIndex = progress.legIndex
                boats[i].roundingStage = progress.stage
            }
        case .finished, .dsq:
            break
        }
    }

    /// Seat `i` crossed the finish line: she finishes, or with a penalty unserved she is disqualified. Either
    /// way she is a ghost from this tick (#30). The first finish opens the finish window (#8).
    private func finish(_ i: Int) {
        if boats[i].penaltyTurnsOwed > 0 {
            disqualify(i, reason: "finished without taking a penalty")
            return
        }
        finishers += 1
        boats[i].status = .finished
        boats[i].place = finishers
        boats[i].finishTime = time
        emit(.finished(seat: i, place: finishers))
        if firstFinishTime == nil {
            firstFinishTime = time
            emit(.firstFinish(closeTick: closeTick))
        }
        emit(.becameGhost(seat: i))
    }

    /// Disqualifies seat `i` now: DSQ, and a ghost from the call (#30). Today only as she finishes with a
    /// penalty unserved; #89 calls it at a missed penalty deadline. A DSQ doesn't open the finish window:
    /// only a finisher does (#8).
    private func disqualify(_ i: Int, reason: String) {
        boats[i].status = .dsq
        emit(.disqualified(seat: i, reason: reason))
        emit(.becameGhost(seat: i))
    }

    // MARK: - Close

    /// The race tick of a race time, which is always a whole number of ticks.
    static func tick(of time: Double) -> Int { Int((time * Double(tickRate)).rounded()) }

    /// The tick the first boat finished on, or nil while nobody has.
    public var firstFinishTick: Int? { firstFinishTime.map(Race.tick(of:)) }

    /// The time limit in ticks after the gun (the race format's `timeLimit`: 960 s).
    private var timeLimitTicks: Int { RulesConfig.ticks(rules.raceFormat.timeLimit) }
    /// The finish window in ticks after the first finish (the race format's `finishWindow`: 120 s).
    private var finishWindowTicks: Int { RulesConfig.ticks(rules.raceFormat.finishWindow) }

    /// The tick the race closes on (#8): `min(firstFinish + finishWindow, timeLimit)` after the first finish,
    /// the time limit while nobody has finished. Both come from the race format in the rules configuration
    /// (#73: 120 s and 960 s in fleet-rules@1 and @2). A boat crossing the line on this tick still finishes.
    /// It closes sooner once no boat is still racing or able to (every one finished or DSQ), or when every
    /// human has gone (`closeAllGone`). The yellow countdown reads it (#114).
    public var closeTick: Int {
        let limit = timeLimitTicks
        return firstFinishTick.map { min($0 + finishWindowTicks, limit) } ?? limit
    }

    /// When the race is expected to close, for the matchmaker (#16, #147). Pure and deterministic, from the
    /// race as it stands:
    /// - closed: the tick it closed on (`tick`);
    /// - after the first finish: `closeTick`;
    /// - before it: `min(timeLimit, projectedFirstFinish + finishWindow)`, with
    ///   `projectedFirstFinish = max(tick, 0) + ticks(leaderRemaining / designPace)`, where `leaderRemaining`
    ///   is the least `distanceToFinish(of:)` of a boat racing, or `courseLength` while none is, and
    ///   `designPace = courseLength / beatSizing.leaderSeconds`: the pace the course is sized for
    ///   (`CourseLayout.beat`).
    ///
    /// The pace is the course's own length over the leader's design time, so it cancels the calibration
    /// factor and the beat's cap: before anyone has started the estimate is always the gun plus
    /// `leaderSeconds` (480 s) plus the finish window, even where the cap (`beatSizing.maxMetres`) makes the
    /// course quicker to sail than that.
    public var expectedCloseTick: Int {
        if isOver { return tick }
        if firstFinishTime != nil { return closeTick }
        let whole = courseLength
        let leaderRemaining = boats.filter { $0.status == .racing }.map(distanceToFinish(of:)).min() ?? whole
        let designPace = whole / rules.raceFormat.beatSizing.leaderSeconds
        let projected = max(tick, 0) + RulesConfig.ticks(leaderRemaining / designPace)
        return min(timeLimitTicks, projected + finishWindowTicks)
    }

    /// Whether `seat`'s boat is a ghost now, as a display shows it (#30, #86): `Boat.isGhost` (finished or
    /// DSQ), and once the race has closed also a boat still OCS or never started, which could have returned
    /// and started until then. It reads only each seat's status and `isOver`, which every client holds
    /// (ADR 0005), so nothing is stored or sent for it. The step's checks read `Boat.isGhost`: nothing
    /// steps after the close.
    public func isGhost(seat: Int) -> Bool {
        let boat = boats[seat]
        return boat.isGhost || (isOver && (boat.status == .ocs || boat.status == .prestart))
    }

    /// Closes the race at once because every human has gone (#30, G3), at `atTick`, which must be now: the
    /// host decides when (#66's trigger; #148 wires it), after this tick's step and seat events.
    /// `leaveOrder` is the human seats in the order they went, first gone first (`AllGone.leaveOrder`).
    ///
    /// Scored as a normal close but for the RETs: each seat in `leaveOrder` that hasn't finished or been
    /// disqualified is RET, placed one by one in reverse leave order, the latest gone highest (G3: by when
    /// each went, not by `atTick`); any other human gone at the close is RET too, tied behind them. A seat
    /// given away before the gun (`SeatEvent.Kind.leftBeforeGun`) is a fleet bot's (#16) and scored as one.
    /// Bots still racing are placed by distance, and a human who finished keeps the finish.
    ///
    /// Returns false, changing nothing, if the race is over, `atTick` isn't `tick`, or `leaveOrder` names a
    /// seat that isn't one of the race's human seats, or names one twice. The log records the close
    /// (`RaceLog.allGoneClose`), and a replay closes the same way.
    @discardableResult
    public func closeAllGone(atTick: Int, leaveOrder: [Int]) -> Bool {
        guard !isOver, atTick == tick else { return false }
        var listed = Array(repeating: false, count: boats.count)
        for seat in leaveOrder {
            guard boats.indices.contains(seat), setup.seats[seat] == .human, !listed[seat] else { return false }
            listed[seat] = true
        }
        allGoneClose = RaceLog.AllGoneClose(tick: atTick, leaveOrder: leaveOrder)
        close(allGoneOrder: leaveOrder)
        return true
    }

    /// Closes the race at `closeTick`, after this tick's finishes, or as soon as no boat is still racing or
    /// able to (every one finished or DSQ).
    private func checkForEnd() {
        guard tick >= closeTick || boats.allSatisfy(\.isGhost) else { return }
        close(allGoneOrder: nil)
    }

    /// Scores the race and closes it: the results, then `becameGhost` for every boat still OCS or never
    /// started (a ghost from the close, `isGhost(seat:)`), then `raceClosed` with the results.
    private func close(allGoneOrder: [Int]?) {
        let scored = score(allGoneOrder: allGoneOrder)
        let ghostsAtClose = boats.indices.filter { boats[$0].status == .ocs || boats[$0].status == .prestart }
        results = scored
        isOver = true
        for seat in ghostsAtClose { emit(.becameGhost(seat: seat)) }
        emit(.raceClosed(results: scored))
    }

    /// Who is at a seat, from the seat events (#16, #30, G3).
    private struct Presence {
        /// A human seat nobody gave away before the gun (a fleet bot takes a seat left then, #16).
        var isHuman: Bool
        /// Whether its last joining, rejoining, drop or leaving at or before the gun was a joining or a
        /// rejoining: the human was there at the gun.
        var wasAtGun = false
        /// Whether its last joining, rejoining, drop or leaving was a drop or a leaving. A disconnection
        /// doesn't count until the input hold runs out and the seat drops (G3). A seat nobody ever
        /// attached to drops too (#195).
        var isGone = false
    }

    private func presence() -> [Presence] {
        var seats = setup.seats.map { Presence(isHuman: $0 == .human) }
        for event in seatEvents {
            switch event.kind {
            case .leftBeforeGun:
                seats[event.seat].isHuman = false
            case .joined, .rejoined:
                seats[event.seat].isGone = false
                if event.tick <= 0 { seats[event.seat].wasAtGun = true }
            case .dropped, .left:
                seats[event.seat].isGone = true
                if event.tick <= 0 { seats[event.seat].wasAtGun = false }
            case .disconnected, .botTookOver:
                break
            }
        }
        return seats
    }

    /// The results as the race stands (`RaceResults`): finishers by finish, boats racing by distance to
    /// finish, then DSQ, OCS (never started included) and RET. A human seat gone at the close whose boat
    /// hasn't finished or been disqualified is RET (#16), and so is each such seat in an all-gone close's
    /// `allGoneOrder` (`closeAllGone`). Rated if at least 2 humans were at the gun (#30).
    private func score(allGoneOrder: [Int]?) -> RaceResults {
        let presence = presence()
        var isRET = boats.indices.map { presence[$0].isHuman && presence[$0].isGone && !boats[$0].isGhost }
        var placedRETs: [Int] = []
        for seat in (allGoneOrder ?? []).reversed() where presence[seat].isHuman && !boats[seat].isGhost {
            isRET[seat] = true
            placedRETs.append(seat)
        }

        var rows: [SeatResult] = []
        rows.reserveCapacity(boats.count)
        /// Each seat its own place, in order.
        func placeEach(_ seats: [Int], _ code: ResultCode) {
            for seat in seats {
                let finishTick = code == .finished ? boats[seat].finishTime.map(Race.tick(of:)) : nil
                rows.append(SeatResult(seat: seat, place: rows.count + 1, code: code, finishTick: finishTick))
            }
        }
        /// The seats tied on one place, in seat order.
        func tie(_ seats: [Int], _ code: ResultCode) {
            let place = rows.count + 1
            for seat in seats { rows.append(SeatResult(seat: seat, place: place, code: code)) }
        }

        let finishers = boats.indices.filter { boats[$0].status == .finished }.sorted {
            let a = boats[$0], b = boats[$1]
            return (a.finishTime ?? 0, a.place ?? 0, $0) < (b.finishTime ?? 0, b.place ?? 0, $1)
        }
        placeEach(finishers, .finished)
        let racing = boats.indices.filter { boats[$0].status == .racing && !isRET[$0] }
        let distances = racing.map { distanceToFinish(of: boats[$0]) }
        placeEach(racing.indices.sorted { (distances[$0], racing[$0]) < (distances[$1], racing[$1]) }.map { racing[$0] },
                  .byDistance)
        tie(boats.indices.filter { boats[$0].status == .dsq }, .dsq)
        tie(boats.indices.filter { (boats[$0].status == .ocs || boats[$0].status == .prestart) && !isRET[$0] }, .ocs)
        placeEach(placedRETs, .ret)
        tie(boats.indices.filter { isRET[$0] && !placedRETs.contains($0) }, .ret)

        let atGun = presence.filter { $0.isHuman && $0.wasAtGun }.count
        return RaceResults(rows: rows, rated: atGun >= 2)
    }

    // MARK: - Standings

    /// Metres `boat` still has to sail to finish, round her remaining marks (#8): what places a boat still
    /// racing when the race closes, and ranks the boats racing until then.
    ///
    /// Racing on a rounding leg, it is the straight line to the leg's target (`CourseLayout.targetPosition`:
    /// the mark, or a gate's midpoint), then on through every later leg's target to the nearest point of the
    /// finish line; on the finish leg, the straight line to the nearest point of the finish line. A pure
    /// distance, with no allowance for the rounding stages she has crossed: two boats rounding the same mark
    /// rank by how far each is from its target, a wobble of metres close to the mark. Not yet started (in
    /// the sequence, late or OCS) she has `courseLength` still to sail from the start line's centre, plus her
    /// distance to it. A boat that has finished or been disqualified has 0.
    public func distanceToFinish(of boat: Boat) -> Double {
        switch boat.status {
        case .racing:
            guard course.legs.indices.contains(boat.legIndex) else { return .infinity }
            guard case .round = course.legs[boat.legIndex] else {
                return (boat.position - Collision.closestPoint(on: course.finishLine.segment, to: boat.position)).length
            }
            return (boat.position - legTargets[boat.legIndex]).length + remainingAfterTarget[boat.legIndex]
        case .prestart, .ocs:
            return (boat.position - course.startLine.centre).length + courseLength
        case .finished, .dsq:
            return 0
        }
    }

    /// The whole course, metres, as `distanceToFinish(of:)` measures it: from the start line's centre to the
    /// first leg's target, and on round the rest to the finish line.
    public var courseLength: Double {
        guard case .round = course.legs[0] else {
            return (course.startLine.centre - Collision.closestPoint(on: course.finishLine.segment, to: course.startLine.centre)).length
        }
        return (legTargets[0] - course.startLine.centre).length + remainingAfterTarget[0]
    }

    /// `remainingAfterTarget` for a course's `legs` and their `targets`: each rounding leg's target on through
    /// every later rounding leg's target to the nearest point of `finish`, summed back from the last.
    private static func remainingAfterTargets(_ targets: [Vec2], legs: [CourseLayout.Leg], finish: Segment) -> [Double] {
        var remaining = Array(repeating: 0.0, count: legs.count)
        for k in legs.indices.reversed() {
            guard case .round = legs[k] else { continue }
            let next = k + 1
            if next < legs.count, case .round = legs[next] {
                remaining[k] = (targets[k] - targets[next]).length + remaining[next]
            } else {
                remaining[k] = (targets[k] - Collision.closestPoint(on: finish, to: targets[k])).length
            }
        }
        return remaining
    }

    /// Seats from first to last. Once the race has closed, the results' display order (`results`). Until
    /// then as the results would rank the fleet now, leaving out who has gone (RET): finishers by finish,
    /// boats racing by distance to finish, DSQ, then boats not yet started by their distance to the start
    /// line's centre.
    public func standings() -> [Int] {
        if let results { return results.order }
        return boats.indices.sorted { rankKey($0) < rankKey($1) }
    }

    /// Where `seat` stands, from 1: its place in `standings()`, found without sorting the fleet. Unique: the
    /// scored places, ties and all, are the results' (`SeatResult.place`).
    public func place(of seat: Int) -> Int {
        if let results, let index = results.rows.firstIndex(where: { $0.seat == seat }) { return index + 1 }
        let key = rankKey(seat)
        var place = 1
        for i in boats.indices where i != seat && rankKey(i) < key { place += 1 }
        return place
    }

    /// Unique for each seat: its group, its measure within it, and the finish place or the seat to break ties.
    private func rankKey(_ i: Int) -> (Int, Double, Int) {
        let b = boats[i]
        switch b.status {
        case .finished: return (0, b.finishTime ?? 0, b.place ?? i)
        case .racing: return (1, distanceToFinish(of: b), i)
        case .dsq: return (2, 0, i)
        case .prestart, .ocs: return (3, (b.position - course.startLine.centre).length, i)
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
            firstFinishTime: firstFinishTime, isOver: isOver, results: results, windKeys: wind.keys,
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
    /// obstruction contact, results for a race not over or not one row for each seat, or a missing key from the first window the wind at the snapshot's tick needs
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
        if let results = snapshot.results {
            var rowCount = Array(repeating: 0, count: boats.count)
            for row in results.rows where seatRange.contains(row.seat) { rowCount[row.seat] += 1 }
            guard snapshot.isOver, results.rows.count == boats.count, rowCount.allSatisfy({ $0 == 1 }) else {
                throw WorldSnapshotError.invalidResults
            }
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
        results = snapshot.results
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
            ("autohelm", boat.autohelm?.target.angle), ("penaltyProgress", boat.penaltyProgress),
            ("windOverGround.direction", boat.windOverGround.direction), ("windOverGround.speed", boat.windOverGround.speed),
            ("sailingWind.direction", boat.sailingWind.direction), ("sailingWind.speed", boat.sailingWind.speed),
            ("apparentWind.direction", boat.apparentWind.direction), ("apparentWind.speed", boat.apparentWind.speed),
            ("current.x", boat.current.x), ("current.y", boat.current.y), ("shadow", boat.shadow),
            ("finishTime", boat.finishTime), ("averagedWindSpeed", boat.averagedWindSpeed),
            ("spinnaker", boat.spinnaker.remaining),
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
