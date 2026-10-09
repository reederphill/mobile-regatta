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
        /// event (`RaceEvent.Kind.isRuleEvent`): rule calls come only from the server. It judges nothing,
        /// owes, serves and enforces no penalty turn and disqualifies nobody (#96): the server's events
        /// (`apply(authoritative:)`) and snapshots bring those, and its right-of-way relations are the server
        /// umpire's (`umpireRelations`).
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
    /// Each leg's target (`CourseLayout.targetPosition(for:)`), by leg index: what `distanceToFinish(of:)` and
    /// `ladderDistanceToFinish(of:)` measure to on a rounding leg.
    private let legTargets: [Vec2]
    /// For each rounding leg, by leg index, the metres from its target on through every later leg's target to
    /// the nearest point of the finish line (`distanceToFinish(of:)`); 0 for the finish leg.
    private let remainingAfterTarget: [Double]
    /// The course axis (`CourseLayout.upwind`), cached: the ladder lines are drawn across it (#267), and the
    /// rank key reads it inside every sort comparison.
    private let ladderAxis: Vec2
    /// By leg index, whether the course axis can't measure the leg and ladder distance runs along it instead
    /// (#267, the owner's ruling): a leg that runs more across the axis than along it, the W → O reach.
    private let isReachLeg: [Bool]
    /// For each leg, by leg index, the ladder metres of every later leg (`ladderDistanceToFinish(of:)`): each
    /// beat or run up or down the axis between its targets, each reach straight along it, the finish leg to
    /// the nearest point of the finish line. 0 for the finish leg.
    private let ladderAfterTarget: [Double]
    /// The class every boat sails: hull, polar and handling (ADR 0004).
    public var boatClass: BoatClass { files.boatClass.content }
    /// Prototype (proto-tiller, never merged): whether a human seat's autohelm engages when the rudder centres. Off,
    /// a centred rudder sails straight on. Set by the app's tuning panel (Steering → Auto tiller); not logged.
    public var humanAutohelm = false
    /// The water's own motion (#78, ADR 0003), which carries every boat (#79): the venue's current at the
    /// tide state at the gun the race seed draws.
    public let current: CurrentField
    /// The tide state at the gun the log records (ADR 0003), or nil at a venue with no current.
    public let tideStateAtGun: Double?
    /// The umpire's memory: the authoritative race's alone, nil for a prediction. Never in a snapshot:
    /// a test that compares a race with one importing its world hands this on too (`WorldSnapshotTests`).
    public internal(set) var umpire: UmpireState?
    /// The pressure map the seat views last drew (`SeatView.PressureMap`, #290), kept for their views until its next
    /// refresh tick. A function of its tick and the keys it read, which never change once held; not race state, and
    /// nothing a step reads.
    var pressureMapDrawn: SeatView.PressureMap?

    /// The bundled defaults (`RaceFiles.defaults`), for code that needs one of them without a race.
    public static var defaultBoatClass: BoatClass { RaceFiles.defaults.boatClass.content }
    public static var defaultConditions: ConditionsFile { RaceFiles.defaults.conditions }
    public static var defaultVenue: VenueFile { RaceFiles.defaults.venue }
    /// `defaultVenue`'s pairing for `defaultConditions`.
    public static var defaultPairing: Venue.Pairing { RaceFiles.defaults.pairing }
    public static var defaultRulesConfiguration: RulesConfigFile { RaceFiles.defaults.rulesConfiguration }

    /// The rules and race-format values this race uses (#73). So far rule 18 (the zone, the mark-room-given
    /// and on-a-beat tests, #91), the incidents, the start sequence, the course, the start row, the penalty
    /// turns' deadlines and their stacking (#89) and the close (the finish window and the time limit,
    /// `closeTick`) read it; the rest wait for the tickets that use them.
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
    /// Every pair's overlap as of the last point of certainty (#87), updated once a tick.
    public private(set) var overlaps: OverlapTracker
    private var events: [RaceEvent] = []
    private var finishers = 0
    /// Inputs stamped for ticks not yet simulated, in the order they arrived.
    private var pending: [InputRecord] = []
    private var appliedInputs: [InputRecord] = []
    private var seatEvents: [SeatEvent] = []

    /// The wind shadow (#377): every boat's ribbon wake, stepped each tick from the boats' states
    /// (`TurbulenceRibbons`, the class's `ribbons`). Race state, carried whole in a snapshot.
    public private(set) var wake: TurbulenceRibbons
    /// Each seat's backwind header now, radians, the lag's state (`applyBackwindHeaders`): empty until the first step,
    /// and always for a class without a header. Race state, in a snapshot.
    private var headerState: [Double] = []
    /// Each seat's backwind level and side (`BackwindSails`), for a class with a header: empty until the first step,
    /// and always for a class without one. Race state, in a snapshot.
    private var backwindSails = BackwindSails()
    /// Each seat's sailing wind direction this tick before any backwind header turned it (`applyBackwindHeaders`), what
    /// her autohelm steers a groove by (`helmSailingAngle`). Not state: set again every step before anything reads it.
    private var unheadedWindDirections: [Double] = []

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
        let ladder = Race.ladderLegs(targets, course: course)
        ladderAxis = course.upwind
        isReachLeg = ladder.isReach
        ladderAfterTarget = ladder.after
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
        wake = TurbulenceRibbons(shadow: boatClass.windShadow)
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
                seatEvents: seatEvents, finalTick: tick, allGoneClose: allGoneClose, incidentIndex: incidents)
    }

    private func acceptsInput(from seat: Int) -> Bool {
        boats.indices.contains(seat) && !isOver
    }

    /// Applies the inputs stamped for this tick and logs them: held inputs first, the last one per
    /// seat winning and logged only if it changed, then taps in the order they came. So a seat's
    /// held input and tap in the same tick act the same whichever arrived first. Returns the tick's protests,
    /// in the order they came, for `step` to record after the tick's calls (`recordProtest`).
    private func applyInputs() -> [ProtestTap] {
        var protests: [ProtestTap] = []
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
            // Prototype (proto-tiller): a human's tack/gybe tap hands back a centred rudder once it has crossed the
            // boom and settled her within 3° of the new groove.
            if boats[i].isPlayer, !humanAutohelm, let helm = boats[i].autohelm, !helm.isTapping {
                let aim = helm.aim(tws: boats[i].polarWindSpeed(in: boatClass),
                                   grooveTWS: boats[i].grooveWindSpeed(in: boatClass), boatClass: boatClass)
                if abs(wrapAngle(aim - boats[i].sailingAngle)) < deg2rad(3) {
                    boats[i].autohelm = nil
                    boats[i].desiredRudder = 0
                }
            }
            let rudder = heldInputs[i].rudderValue
            if abs(rudder) > Autohelm.deadBand {
                boats[i].autohelm = nil
                boats[i].desiredRudder = rudder
            } else if boats[i].autohelm == nil {
                if boats[i].isPlayer && !humanAutohelm {
                    // Prototype (proto-tiller, never merged): no autohelm for a human. A centred rudder is a
                    // centred rudder: she sails straight on, and the wind's shifts and puffs are hers to steer.
                    boats[i].desiredRudder = 0
                } else {
                    engageAutohelm(i)
                }
            }
        }

        for record in taps {
            appliedInputs.append(record)
            guard case .tap(let tap) = record.kind else { continue }
            let i = record.seat
            switch tap {
            case .tackGybe:
                let b = boats[i]
                guard !b.isGhost else { break }
                if boatClass.rollTack != nil, isInTack(b) {
                    // A second tap during a tack is the roll (#222, #263): one a tack, any after it ignored.
                    if b.roll == nil { boats[i].roll = .pending(tapTick: tick) } // timed in `sailRoll`
                } else {
                    // The autohelm sails her through head to wind or the gybe to the groove on the new tack.
                    boats[i].autohelm = .tackOrGybe(sailingAngle: b.sailingAngle)
                }
            case .protest(let target):
                protests.append(ProtestTap(protester: i, protested: target))
            }
        }
        return protests
    }

    /// A protest tap applied this tick (#94), recorded after the tick's calls.
    private struct ProtestTap {
        let protester: Int
        let protested: Int
    }

    /// Records seat `i`'s protest of `target` (#94, #9): any boat may protest any other, a ghost or a bot
    /// included, and a protest never changes a result. The umpire links it to the pair's incident of the
    /// protest window before it (`UmpireState.matchProtest`), and only the protester is told. Applied with the
    /// tick's inputs, recorded after the tick's calls (`step`). The authoritative race's alone: a prediction
    /// records no protest and emits no rule event.
    private func recordProtest(by i: Int, of target: Int) {
        guard let umpire else { return }
        let matched = umpire.matchProtest(by: i, of: target, atTick: tick,
                                          window: RulesConfig.ticks(rules.raceFormat.protestWindow), in: incidents)
        incidents.recordProtest(Protest(tick: tick, leg: boats[i].legIndex, protester: i, protested: target,
                                        matchedIncidentId: matched))
        emit(.protestRecorded(seat: i, target: target, matchedIncidentId: matched))
    }

    /// Whether `b` is in a tack a roll tap can roll (#263): her autohelm sailing a tack's tap towards head to
    /// wind, or past it (`isTacking`) until close-hauled.
    private func isInTack(_ b: Boat) -> Bool {
        if b.isTacking { return true }
        guard let helm = b.autohelm, helm.isTapping else { return false }
        return !helm.target.isDownwind
    }

    /// Engages seat `i`'s autohelm on the angle she sails now, against the grooves in the wind they read
    /// this tick (`Boat.grooveWindSpeed(in:)`), and announces a snap to the groove (#124).
    private func engageAutohelm(_ i: Int) {
        let b = boats[i]
        let engaged = Autohelm.engage(sailingAngle: b.sailingAngle, tws: b.grooveWindSpeed(in: boatClass),
                                      boatClass: boatClass)
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
        // The order is fixed (#377): every caster's backwind zone from the tick-start states and the backwind levels as
        // of the last tick, before any header turns a boat's wind (so a caster's own header never feeds her zone); the
        // headers from those zones; then the ribbons and the backwind levels step from the headed winds; then each
        // boat's shadow from the ribbons now and the zones.
        let backwinds = boats.indices.map(shadowCone(ofSeat:))
        let header = boatClass.windShadow.header
        if let header { applyBackwindHeaders(backwinds, header: header) }
        // Every boat's working scale, from the headed winds: the same for the wake and the backwind levels.
        let scales = sailScales()
        stepWake(scales: scales)
        if header != nil { stepBackwindSails(scales: scales) }
        applyWindShadows(backwinds)
        averageGrooveWinds()

        let protests = applyInputs()

        let previous = boats
        for i in boats.indices { integrate(i, Race.dt) }
        enforcePenaltyDeadlines()
        // Where the boats sailed to, before contacts push them apart: a call at a contact this tick
        // reads this tick's certain overlap. Rule 18's zones first: the overlap terms apply on opposite
        // tacks between boats rule 18 applies between (#91), and its records read the updated overlaps.
        let hulls = boats.map { $0.hull(outline: boatClass.hull.outline) }
        let zones = boats.indices.map { course.markZone(of: boats[$0], hull: hulls[$0]) }
        let markRoomApplies = markRoomAppliesByPair(zones)
        overlaps.update(boats, hull: boatClass.hull, margin: lastPointOfCertaintyTicks, markRoomApplies: markRoomApplies)
        updateMarkRoom(previous: previous, hulls: hulls, zones: zones, markRoomApplies: markRoomApplies)
        // The umpire records the boats as the calls below judge them (#92), and its rule 17 records read that (#345).
        recordTrack()
        updateProperCourse(hulls: hulls, markRoomApplies: markRoomApplies)
        forgetSeparatedMarkTouches()
        resolveBoatContacts()
        callNearMisses()
        // After the tick's calls, so a protest on the tick an incident opens is about it (#94).
        for protest in protests { recordProtest(by: protest.protester, of: protest.protested) }
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
    /// takes none and casts none (#30). The shadow is every other caster's ribbons (`wake`, #377), times each one's
    /// backwind loss (`ShadowCone.factor(at:)`: #298's or #79's, or the header's lull, none by default), floored at the
    /// class's stacking floor. `zones` are every seat's backwind (`shadowCone(ofSeat:)`) this tick.
    private func applyWindShadows(_ zones: [ShadowCone?]) {
        let shadow = boatClass.windShadow
        let floor = shadow.stackingFloor
        let backwindIsPureShift = shadow.backwindInnerLength != nil && shadow.header.map { $0.lull == 0 } ?? false
        let wake = wake.frame(tick: tick)
        for i in boats.indices {
            guard !boats[i].isGhost else {
                boats[i].shadow = 1
                continue
            }
            let p = boats[i].position
            var f = wake.unflooredFactor(at: p, receiver: i)
            // A header's backwind at lull 0 (the default) leaves every factor exactly 1: nothing to multiply.
            if !backwindIsPureShift {
                for (c, zone) in zones.enumerated() where c != i {
                    if let zone { f *= zone.factor(at: p) }
                }
            }
            boats[i].shadow = max(f, floor)
        }
    }

    /// Steps the ribbon wake (#377): every boat's emission level target is how hard her sail is working, with her held
    /// ease (`SailTrim.workingScale`), from this tick's (headed) winds.
    private func stepWake(scales: [Double]) {
        wake.step(boats: boats, tick: tick, scales: scales)
    }

    /// Steps each seat's backwind level and side (`backwindSails`), for a class with a header (#377): built over the
    /// ribbons' `buildSeconds`, faded over the class's `backwindFadeSeconds`.
    private func stepBackwindSails(scales: [Double]) {
        let shadow = boatClass.windShadow
        backwindSails.step(boats: boats, scales: scales, buildSeconds: shadow.ribbons.buildSeconds,
                           fadeSeconds: shadow.backwindFadeSeconds)
    }

    /// Every boat's working scale now: her sail's angle to her apparent wind with her held ease (`SailTrim`).
    private func sailScales() -> [Double] {
        let boatClass = boatClass
        return boats.indices.map { SailTrim.standard.workingScale(of: boats[$0], ease: heldInputs[$0].ease, boatClass: boatClass) }
    }

    /// How much `seat`'s backwind is cast, 0...1, for a class with a header (#377): her backwind level (`BackwindSails`)
    /// as of the last tick stepped; before the first, her working scale now. 1 for a class without a header (#298's
    /// loss ignores her sail) or an unknown seat.
    public func backwindSail(ofSeat seat: Int) -> Double {
        guard boatClass.windShadow.header != nil, boats.indices.contains(seat) else { return 1 }
        if backwindSails.levels.indices.contains(seat) { return backwindSails.levels[seat] }
        return SailTrim.standard.workingScale(of: boats[seat], ease: heldInputs[seat].ease, boatClass: boatClass)
    }

    /// The side `seat`'s backwind is cast on, for a class with a header (#377, `BackwindSails.sides`): her windward side,
    /// held while a zone fades out past her boom crossing; nil (her side now) before the first tick stepped, for a class
    /// without a header, or for an unknown seat.
    public func backwindSide(ofSeat seat: Int) -> Tack? {
        guard boatClass.windShadow.header != nil, backwindSails.sides.indices.contains(seat) else { return nil }
        return backwindSails.sides[seat]
    }

    /// The backwind as a header (#377): each boat's wind over the ground is turned towards her bow by the header's angle
    /// × the envelope of every other boat's backwind she sits in (`ShadowCone.backwindEnvelope(at:)`, from `zones`, this
    /// tick's from the tick-start states), summed and capped, through a first-order lag of `lagSeconds`
    /// (`headerState`); never past her bow line. Her three winds are then resolved again from it, so her polar,
    /// apparent wind, drawing and everything after see the headed wind; nobody else's changes. Her autohelm (ADR 0007)
    /// holds her heading through it (`helmSailingAngle`).
    /// The backwind is the one thing that turns a boat's wind: #10 had shadows never turn it.
    private func applyBackwindHeaders(_ zones: [ShadowCone?], header: BoatClass.WindShadow.Header) {
        if headerState.count != boats.count { headerState = Array(repeating: 0, count: boats.count) }
        if unheadedWindDirections.count != boats.count { unheadedWindDirections = Array(repeating: 0, count: boats.count) }
        let follow = header.lagSeconds > 0 ? min(1, Race.dt / header.lagSeconds) : 1
        for i in boats.indices {
            unheadedWindDirections[i] = boats[i].sailingWind.direction
            guard !boats[i].isGhost else {
                headerState[i] = 0
                continue
            }
            let target = Self.headerTarget(at: boats[i].position, receiver: i, zones: zones, header: header)
            headerState[i] += (target - headerState[i]) * follow
            guard headerState[i] > 0 else { continue }
            let headed = Self.headed(boats[i].windOverGround, heading: boats[i].heading, by: headerState[i])
            let winds = BoatWinds.resolve(ground: headed, current: boats[i].current, velocityThroughWater: boats[i].velocity)
            boats[i].windOverGround = winds.overGround
            boats[i].sailingWind = winds.sailing
            boats[i].apparentWind = winds.apparent
        }
    }

    /// The header every caster but `receiver` puts on a boat at `p`, radians: the header's angle × each one's backwind
    /// envelope there, summed, capped at the header's cap.
    static func headerTarget(at p: Vec2, receiver: Int, zones: [ShadowCone?], header: BoatClass.WindShadow.Header) -> Double {
        var sum = 0.0
        for (c, zone) in zones.enumerated() where c != receiver {
            if let zone { sum += header.angle * zone.backwindEnvelope(at: p) }
        }
        return min(header.cap, sum)
    }

    /// `ground` turned `header` radians towards `heading` (a header for a boat sailing it), never past it.
    static func headed(_ ground: Wind, heading: Double, by header: Double) -> Wind {
        let off = wrapAngle(heading - ground.direction)
        let turn = (off < 0 ? -1.0 : 1.0) * min(header, abs(off))
        return Wind(direction: wrapAngle(ground.direction + turn), speed: ground.speed)
    }

    /// The sailing angle seat `i`'s autohelm steers a groove by: against her wind before this tick's backwind header
    /// (#377). A backwind header comes off a boat on her lee bow, so following it down would bear her away onto that
    /// boat's stern (rule 11 against her): like a sailor with a boat on her lee bow she holds her heading and pinches
    /// instead, and tacking away is hers to choose. Never into the no-go zone: she holds only as much of the header as
    /// keeps her headed angle out of it, so a slow or luffed boat headed hard isn't pinned in irons. Unheaded, her plain
    /// sailing angle. Only a groove holds through it: an angle the autohelm holds (`Autohelm.Target.angle`), and its
    /// engaging, read her headed angle, the one the player's screen and a bot's view (`SeatView`) show, so an angle a
    /// bot asked for is the angle she sails (held against the unheaded wind, a bot steering by its view fought the
    /// autohelm through every header).
    private func helmSailingAngle(_ b: Boat, seat i: Int) -> Double {
        guard header(ofSeat: i) > 0, unheadedWindDirections.indices.contains(i) else { return b.sailingAngle }
        let unheaded = b.boomSide.sailingAngle(relativeWind: wrapAngle(unheadedWindDirections[i] - b.heading))
        // Never pinched into the no-go zone: she holds only as much as keeps her headed angle out of it.
        let room = max(0, abs(b.sailingAngle) - BoatDynamics.noGoAngle(boatClass.polar))
        let turn = wrapAngle(unheaded - b.sailingAngle)
        return b.sailingAngle + (turn < 0 ? -1 : 1) * min(abs(turn), room)
    }

    /// Each seat's backwind header now, radians (`applyBackwindHeaders`): 0 for every seat of a class without a header.
    public func header(ofSeat seat: Int) -> Double { headerState.indices.contains(seat) ? headerState[seat] : 0 }

    /// Moves every boat's average of the wind speed her polar reads a tick on (`Boat.averagedWindSpeed`):
    /// what her autohelm's grooves follow (#245), once the wind and shadows are sampled this tick.
    private func averageGrooveWinds() {
        for i in boats.indices { boats[i].averageWind(dt: Race.dt, in: boatClass) }
    }

    /// The wind shadow and backwind `seat`'s boat casts now, along her apparent wind (#10), or nil for a
    /// ghost, which casts none, or an unknown seat.
    public func shadowCone(ofSeat seat: Int) -> ShadowCone? {
        guard boats.indices.contains(seat), !boats[seat].isGhost else { return nil }
        var zone = ShadowCone(caster: boats[seat], shadow: boatClass.windShadow)
        // The backwind is upwash off a working sail (#377): for a class with a header only.
        if boatClass.windShadow.header != nil {
            zone.backwindSail = backwindSail(ofSeat: seat)
            zone.backwindSide = backwindSide(ofSeat: seat)
        }
        return zone
    }

    private func integrate(_ i: Int, _ dt: Double) {
        var b = boats[i]
        // The polar reads the sailing wind (#14); shadow slows it and never turns it (#10), or, for a class whose
        // shadow is a speed loss, slows her target speed instead (#220, #263). The current carries every boat,
        // ghosts too (#11). The autohelm's grooves read the class's average of it (#245).
        let tws = b.polarWindSpeed(in: boatClass)
        let grooveTWS = b.grooveWindSpeed(in: boatClass)
        // The player steers this tick with the rudder held off centre, or through the tap the autohelm is
        // sailing for her (#219): what a penalty turn reads (`turnPenalty`).
        let playerDriven = b.autohelm?.isTapping ?? true

        if let helm = b.autohelm {
            // A groove holds her heading through a backwind header (`helmSailingAngle`); a held angle is her headed one.
            let sailingAngle = helm.target.groove != nil ? helmSailingAngle(b, seat: i) : b.sailingAngle
            b.desiredRudder = helm.rudder(sailingAngle: sailingAngle, boomSide: b.boomSide, tws: tws,
                                          grooveTWS: grooveTWS, boatClass: boatClass)
        }

        let before = b.heading
        let speedBefore = b.speed
        let moved = BoatDynamics.advance(
            BoatDynamics.State(position: b.position, heading: b.heading, speed: b.speed, rudder: b.rudder, boomSide: b.boomSide,
                               isPlaning: b.isPlaning, spinnaker: b.spinnaker),
            control: BoatDynamics.Control(rudder: b.desiredRudder, ease: heldInputs[i].ease, sailing: !b.isGhost),
            env: BoatDynamics.Environment(windDirection: b.sailingWind.direction, windSpeed: tws, current: b.current,
                                          shadow: b.speedShadow(in: boatClass)),
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

        if b.penaltyTurnsOwed > 0 { turnPenalty(&b, seat: i, turn: turn, playerDriven: playerDriven) }

        // Rule 13: from the boom crossing head to wind until close-hauled on the new tack.
        if crossing {
            // The tap has crossed the boom: the autohelm holds the groove on the new tack.
            b.autohelm?.isTapping = false
            b.isTacking = b.twa < .pi / 2
            b.tackCrossingTick = b.isTacking ? tick : nil
            emit(b.isTacking ? .tacked(seat: i) : .gybed(seat: i))
        }
        if let roll = boatClass.rollTack { sailRoll(&b, seat: i, roll, speedBefore: speedBefore) }
        if b.isTacking && b.twa >= boatClass.polar.bestUpwind(tws: tws).twa - deg2rad(5) {
            b.isTacking = false
            b.tackCrossingTick = nil
            b.roll = nil
        }

        boats[i] = b
    }

    /// A roll tack this tick (#263), once the dynamics have moved her from `speedBefore`: a pending tap hits when the
    /// boom crosses within the class's window of it (either side), and misses once the window has passed without a
    /// crossing, or at once for a tap after the window; a miss takes the class's factor off her speed, once. A hit keeps
    /// back the class's share of each tick's speed loss (never a gain: no floor and no jump). Out of her tack, a
    /// decided roll is done.
    private func sailRoll(_ b: inout Boat, seat: Int, _ roll: BoatClass.RollTackTuning, speedBefore: Double) {
        if case .pending(let tapTick) = b.roll {
            if let crossing = b.tackCrossingTick, abs(tapTick - crossing) <= roll.windowTicks {
                b.roll = .hit
                emit(.rollHit(seat: seat))
            } else if b.tackCrossingTick != nil || tick - tapTick > roll.windowTicks {
                b.speed *= roll.missSpeedFactor
                b.roll = .missed
                emit(.rollMissed(seat: seat))
            }
        }
        if b.roll == .hit, b.speed < speedBefore {
            b.speed = speedBefore - roll.hitLossFraction * (speedBefore - b.speed)
        }
        if b.roll == .hit || b.roll == .missed, !isInTack(b) { b.roll = nil }
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

    /// Who must keep clear between `seat` and every other seat, in seat order, nil at `seat` itself and for
    /// any pair with a ghost: `Rules.obligation` (rule 21 over rules 10–13), so a returning or penalised boat
    /// keeps clear. Where the umpire holds a mark-room record for the pair (#91) and neither boat is under rule 21,
    /// the boat owing mark-room is the one that keeps clear: the glow is the only mark-room cue the player gets, so
    /// it shows who owes room as well as who keeps clear (owner, 2026-10-03, #386). Rule 18 is not right of way
    /// (Case 25): this is what the glyphs show (#123), never what the umpire calls. Read-only.
    /// A prediction never works it out from its own world (#96, ADR 0005): it returns the server umpire's
    /// (`umpireRelations`) for the seat they are for, and none for any other seat or before they come.
    public func keepClearRelations(of seat: Int) -> [RightOfWay?] {
        guard boats.indices.contains(seat) else { return [] }
        if umpire == nil {
            guard let relations = umpireRelations, relations.seat == seat else {
                return Array(repeating: nil, count: boats.count)
            }
            return relations.keepClear
        }
        return boats.indices.map { keepClearRelation(of: seat, to: $0) }
    }

    /// `keepClearRelations(of: seat)[other]`, for the one pair: the server works out only the pairs in range of
    /// a seat (#96). Nil for a seat out of the fleet.
    public func keepClearRelation(of seat: Int, to other: Int) -> RightOfWay? {
        guard boats.indices.contains(seat), boats.indices.contains(other), other != seat else { return nil }
        if umpire == nil {
            guard let relations = umpireRelations, relations.seat == seat else { return nil }
            return relations.keepClear[other]
        }
        guard let verdict = Rules.obligation(boats[seat], boats[other], overlapped: overlaps.isOverlapped(seat, other),
                                             course: course, hull: boatClass.hull) else { return nil }
        // Rule 21 stands over mark-room: a boat owed room that is taking a penalty or returning gets none and keeps
        // clear, as the umpire holds her to (`EscapeSimulation.markRoomVerdict`); with both under it, Section A decides.
        let underRule21 = [seat, other].contains { boats[$0].isTakingPenalty || course.isReturning(boats[$0]) }
        if !underRule21, let record = umpire?.markRoom(SeatPair(seat, other)) {
            return RightOfWay(keepClear: record.owing, rule: record.rule)
        }
        return RightOfWay(keepClear: verdict.offender, rule: verdict.rule)
    }

    /// Boats touching: a contact costs both boats speed and is announced (`RaceEvent.Kind.contact`) on the
    /// tick it begins, and opens an incident unless the pair has one open (`call`), its offender exonerated when
    /// another boat's breach compelled her (`exoneratingCompelled`, 43.1(a)): every pair judged first, then called
    /// (`callCompelledLast`). The pushes part them.
    /// A pair not touching whose open incident the umpire holds closes it once their hulls are more than
    /// the rules configuration's `incidents.separation` apart. A ghost can't be touched.
    private func resolveBoatContacts() {
        var touching = Set<Pair>()
        // Contacts begun this tick, and the calls they make: called once every pair is judged (`callCompelledLast`).
        var begun: [(Int, Int)] = []
        var verdicts: [Verdict] = []
        let hull = boatClass.hull
        let hulls = boats.map { $0.hull(outline: hull.outline) }
        let separation = rules.incidents.separation.metres(hullLength: hull.length)
        for i in boats.indices where !boats[i].isGhost {
            for j in (i + 1)..<boats.count where !boats[j].isGhost {
                let apart = (boats[i].position - boats[j].position).length
                guard apart < hull.length * 1.3, let push = Collision.penetration(hulls[i], hulls[j]) else {
                    // The hulls are no further apart than the centres, so only a pair whose centres are past
                    // the separation can have separated.
                    if apart > separation, isIncidentOpen(i, j),
                       Collision.distance(convex: hulls[i], simplePolygon: hulls[j]) > separation {
                        umpire?.close(SeatPair(i, j))
                    }
                    continue
                }

                let pair = Pair(a: i, b: j)
                touching.insert(pair)
                if !boatContacts.contains(pair) {
                    boats[i].speed = BoatDynamics.speed(after: .boat, speed: boats[i].speed, boatClass: boatClass)
                    boats[j].speed = BoatDynamics.speed(after: .boat, speed: boats[j].speed, boatClass: boatClass)
                    emit(.contact(SeatPair(i, j)))
                    // Only the umpire judges (#96): a prediction's contact costs speed and pushes, never a call.
                    if umpire != nil, !isIncidentOpen(i, j),
                       let verdict = Rules.judge(boats[i], boats[j], overlapped: overlaps.isOverlapped(i, j),
                                                 course: course, hull: hull, escape: escapeSimulation(i, j)) {
                        verdicts.append(verdict)
                    }
                    begun.append((i, j))
                }
                boats[i].position += push * 0.5
                boats[j].position -= push * 0.5
            }
        }
        boatContacts = touching
        callCompelledLast(verdicts, trigger: .contact)
        for (i, j) in begun { recordBoatContact(i, j) }
    }

    /// Calls this tick's `verdicts` (`call`), each offender exonerated when another boat's breach compelled her
    /// (`exoneratingCompelled`, 43.1(a)), whatever the seats' order: first those whose offender is the victim of none
    /// of the others, then the rest, all judged before any of them is called. So a boat's 43.1(a) never turns on
    /// whether the pair that compelled her comes before hers in seat order; each phase keeps seat order.
    private func callCompelledLast(_ verdicts: [Verdict], trigger: Incident.Trigger) {
        let victims = Set(verdicts.map(\.victim))
        for verdict in verdicts where !victims.contains(verdict.offender) {
            call(exoneratingCompelled(verdict), trigger: trigger)
        }
        let compelled = verdicts.filter { victims.contains($0.offender) }.map(exoneratingCompelled)
        for verdict in compelled { call(verdict, trigger: trigger) }
    }

    /// Records seats `i` and `j`'s contact, begun this tick, in the incident index (#94) with the incident it is
    /// part of: the one the umpire holds open between them, which it may just have opened. The authoritative
    /// race's alone, as the umpire's incident memory is.
    private func recordBoatContact(_ i: Int, _ j: Int) {
        guard let umpire else { return }
        let pair = SeatPair(i, j)
        incidents.recordBoatContact(BoatContact(tick: tick, leg: max(boats[i].legIndex, boats[j].legIndex), parties: pair,
                                                incidentId: umpire.openIncident(pair)))
    }

    /// Near misses (#9): an overlapped pair not touching and with no incident open, where the right-of-way
    /// boat's sweep would hit the boat that must keep clear (`RulesConfig.NearMissSweep.hits`), opens an
    /// incident just as a contact does (`call`), with no `contact` event, and is judged as `Rules.judge`
    /// judges one: the obligation the sweep read, then the escape simulation over it (#92). The
    /// authoritative race's alone: a client never shows a call the server hasn't made (ADR 0005), so a
    /// prediction needn't spend the sweep on one.
    private func callNearMisses() {
        guard umpire != nil else { return }
        let hull = boatClass.hull
        let sweep = rules.incidents.nearMissSweep
        var verdicts: [Verdict] = []
        for i in boats.indices where !boats[i].isGhost {
            for j in (i + 1)..<boats.count where !boats[j].isGhost && overlaps.isOverlapped(i, j) {
                guard sweep.canReach(boats[i], boats[j], hull: hull), !boatContacts.contains(Pair(a: i, b: j)),
                      !isIncidentOpen(i, j),
                      let obligation = Rules.obligation(boats[i], boats[j], overlapped: true, course: course, hull: hull),
                      sweep.hits(boats[obligation.victim], boats[obligation.offender], hull: hull)
                else { continue }
                verdicts.append(escapeSimulation(i, j)?.verdict(obligation, course: course) ?? obligation)
            }
        }
        callCompelledLast(verdicts, trigger: .nearMiss)
    }

    /// The umpire's recorded track (#92): every boat and every pair's certain overlap this tick, for the escape
    /// simulation. The authoritative race's alone, under a rules configuration that has one (schema 4): a
    /// prediction never judges room (ADR 0005), so it needn't spend the memory.
    private func recordTrack() {
        guard umpire != nil else { return }
        let escape = rules.incidents.escape
        guard escape.changesCourse != nil else { return }
        umpire?.record(tick: tick, boats: boats, inputs: heldInputs, overlaps: overlaps.certainOverlaps,
                        keeping: escape.recordedTicks)
    }

    /// The escape simulation for seats `a` and `b` on the umpire's recorded track, with the pair's rule 17 record
    /// (#345) and rule 18 record (#93), or nil in a prediction or under a rules configuration without one.
    private func escapeSimulation(_ a: Int, _ b: Int) -> EscapeSimulation? {
        guard let umpire, let track = umpire.track(a, b) else { return nil }
        return EscapeSimulation(track: track, rules: rules, boatClass: boatClass,
                                properCourse: umpire.properCourse(SeatPair(a, b)), markRoom: umpire.markRoom(SeatPair(a, b)))
    }

    /// Rule 43.1(a) (#93): `verdict` with its offender exonerated too when another boat's breach compelled her
    /// into the victim (`compellingIncident`, the victim a third boat on her recorded track). `call` then makes no
    /// call on the incident. Unchanged when she is already exonerated, in a prediction, or under a rules
    /// configuration without an escape simulation.
    private func exoneratingCompelled(_ verdict: Verdict) -> Verdict {
        let (offender, victim) = (verdict.offender, verdict.victim)
        guard !verdict.exonerated.contains(offender), let track = umpire?.track(offender, victim),
              compellingIncident(of: offender, into: .boat(seat: victim, track: track.recorded(victim))) != nil
        else { return verdict }
        return Verdict(rule: verdict.rule, offender: offender, victim: victim, exonerated: verdict.exonerated + [offender])
    }

    /// Rule 43.1(a) (#93): the incident whose breach compelled seat `seat` into `hazard`, if any: one the umpire
    /// holds open between her and another boat (not the hazard), called against that boat with `seat` the victim,
    /// its call within the recorded track, after which the escape simulation finds she had no way clear of both
    /// that boat and the hazard, but would have had one clear of the hazard alone (`EscapeSimulation.isCompelled`).
    /// One hop: a boat compelled by a boat that was herself compelled isn't followed further. Looked up in seat
    /// order. Nil in a prediction, which holds no umpire.
    private func compellingIncident(of seat: Int, into hazard: EscapeSimulation.Hazard) -> Int? {
        guard let umpire else { return nil }
        var excluded = seat
        if case .boat(let third, _) = hazard { excluded = third }
        for other in boats.indices where other != seat && other != excluded {
            guard let id = umpire.openIncident(SeatPair(seat, other)), case .called(let call)? = incidents[id]?.outcome,
                  call.offender == other, call.victim == seat, let escape = escapeSimulation(seat, other)
            else { continue }
            let breach = escape.track.count - 1 - (tick - call.tick)
            if breach >= 0, escape.isCompelled(seat, by: other, breach: breach, into: hazard) { return id }
        }
        return nil
    }

    /// Rule 17 (#345): the umpire's records of leeward boats that came up from clear astern
    /// (`UmpireState.updateProperCourse`). The authoritative race's alone, under a rules configuration with rule 17's
    /// limits (schema 5).
    private func updateProperCourse(hulls: [[Vec2]], markRoomApplies: [Bool]) {
        guard umpire != nil, rules.incidents.properCourse != nil else { return }
        umpire?.updateProperCourse(ProperCourseTick(
            tick: tick, boats: boats, hulls: hulls, markRoomApplies: markRoomApplies, overlaps: overlaps, rules: rules,
            boatClass: boatClass))
    }

    /// The windward boats seat `seat` is held to her proper course against now (rule 17, #345: the umpire's records
    /// naming her the leeward boat), in seat order. A prediction holds no umpire (ADR 0005): it returns the server
    /// umpire's word (`umpireRelations`, #96) for the seat it is for, and none for any other.
    public func properCourseRestrictions(of seat: Int) -> [Int] {
        guard let umpire else {
            guard let relations = umpireRelations, relations.seat == seat else { return [] }
            return relations.restrictedBy
        }
        return boats.indices.filter { other in
            other != seat && umpire.properCourse(SeatPair(seat, other))?.leeward == seat
        }
    }

    /// Whether `properCourseRestrictions(of: seat)` holds `other`, for the one pair: the server works out only the
    /// pairs in range of a seat (#96).
    public func isHeldToProperCourse(_ seat: Int, against other: Int) -> Bool {
        guard boats.indices.contains(seat), boats.indices.contains(other), other != seat else { return false }
        guard let umpire else {
            guard let relations = umpireRelations, relations.seat == seat else { return false }
            return relations.restrictedBy.contains(other)
        }
        return umpire.properCourse(SeatPair(seat, other))?.leeward == seat
    }

    /// Whether rule 18 applies between each pair now (`Rules.markRoomApplies`), by `OverlapTracker.index`,
    /// from each seat's `MarkZone`: world state alone, so a prediction's overlaps are the server's.
    private func markRoomAppliesByPair(_ zones: [MarkZone?]) -> [Bool] {
        let n = boats.count
        var applies = [Bool](repeating: false, count: OverlapTracker.pairCount(seats: n))
        for a in 0..<n where zones[a] != nil {
            for b in (a + 1)..<n where zones[b] != nil {
                applies[OverlapTracker.index(a, b, seats: n)] = Rules.markRoomApplies(
                    boats[a], boats[b], zones: zones[a], zones[b], course: course, onABeat: rules.onABeat)
            }
        }
        return applies
    }

    /// Rule 18 (#91): the umpire's records of who is entitled to mark-room from whom
    /// (`UmpireState.updateMarkRoom`), announced by no event: mark-room is the right-of-way glow
    /// (`keepClearRelations(of:)`, #386), and `markRoomNotice` is no longer emitted (#403). The authoritative
    /// race's alone (ADR 0005). Mark-room
    /// is not right of way: an incident's call reads the record only through the escape simulation
    /// (`EscapeSimulation.verdict`: 18.2, 18.2(d) and 43.1(b), #93).
    private func updateMarkRoom(previous: [Boat], hulls: [[Vec2]], zones: [MarkZone?], markRoomApplies: [Bool]) {
        guard umpire != nil else { return }
        umpire?.updateMarkRoom(MarkRoomTick(
            tick: tick, boats: boats, previous: previous, hulls: hulls, zones: zones, markRoomApplies: markRoomApplies,
            overlaps: overlaps, course: course, rules: rules, boatClass: boatClass))
    }

    /// Whether the umpire holds an incident open between seats `a` and `b`. Never, in a prediction.
    private func isIncidentOpen(_ a: Int, _ b: Int) -> Bool { umpire?.openIncident(SeatPair(a, b)) != nil }

    /// Marks (#90): a boat touching a mark loses speed by the class's mark factor on the tick the touch begins,
    /// and is pushed off it. Touching a mark of her leg (rule 31, `CourseLayout.isRule31Mark`) costs her one
    /// penalty turn (`penalize`) and is announced (`markTouch`), unless the turn is already owed for the same
    /// incident or she is exonerated (`markTouchVerdict`). Any other touch is an obstruction contact of kind `.mark`: no penalty,
    /// announced and recorded (`IncidentIndex.obstructionContacts`), as an edge's is. A ghost sails through.
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
                    touchMark(i, obstacle)
                }
                boats[i].position += push
            }
        }
        obstacleContacts = touching
    }

    /// What seat `i`'s touch of `obstacle`, begun this tick, costs her (rule 31, #90).
    /// A prediction never penalises a touch of a mark of her leg (#96, ADR 0005): the server's `markTouch` owes
    /// the turn (`apply(authoritative:)`).
    private func touchMark(_ i: Int, _ obstacle: Obstacle) {
        if course.isRule31Mark(obstacle.name, status: boats[i].status, legIndex: boats[i].legIndex) {
            guard umpire != nil else { return }
            switch markTouchVerdict(i, obstacle) {
            case .turn:
                penalize(i)
                if umpire != nil {
                    // The index's record of it (#94); the authoritative race's alone.
                    incidents.recordMarkTouch(MarkTouch(tick: tick, leg: boats[i].legIndex, seat: i, mark: obstacle.name))
                }
                emit(.markTouch(seat: i, mark: obstacle.name))
                rememberMarkTouch(i)
                return
            case .sameIncident:
                break
            case .exonerated(let id):
                // Recorded on the incident she was compelled in (43.1, #93): no call or event of its own.
                if var incident = incidents[id] {
                    incident.exonerate(i)
                    incidents.update(incident)
                }
            }
        }
        incidents.recordObstructionContact(ObstructionContact(tick: tick, leg: boats[i].legIndex, seat: i, kind: .mark))
        emit(.obstructionContact(seat: i, kind: .mark))
    }

    /// What touching a mark of her leg costs a boat (#90).
    private enum MarkTouchVerdict {
        /// One penalty turn (rule 31).
        case turn
        /// Nothing more (44.1(a)): she has an open incident whose call already carries her turn.
        case sameIncident
        /// Nothing (43.1, #93): another boat's breach in the open incident `incidentId` put her on the mark.
        case exonerated(incidentId: Int)
    }

    /// Rule 44.1(a): whether seat `i`'s touch of a mark of her leg is in the same incident as a foul she is
    /// already called for: one the umpire holds open (the pair hasn't separated), whose call she is the
    /// offender of. One turn for the incident, the call's. Otherwise rule 43.1 (#93), in an incident the umpire
    /// holds open whose call names her the victim: 43.1(b) when the call is the other boat failing to give her
    /// mark-room (18.2 or 18.3) at `obstacle`, the mark of the pair's rule 18 record, which still has her entitled,
    /// and she touches it on the call's tick or after (Case 95: forced onto the mark she was owed room at), and
    /// 43.1(a) when that boat's breach compelled her onto `obstacle` (`compellingIncident`). Then she is exonerated, with no turn. The
    /// authoritative race's alone (`touchMark`): a prediction penalises no touch (#96).
    private func markTouchVerdict(_ i: Int, _ obstacle: Obstacle) -> MarkTouchVerdict {
        guard let umpire else { return .turn }
        for other in boats.indices where other != i {
            if let id = umpire.openIncident(SeatPair(i, other)), case .called(let call)? = incidents[id]?.outcome,
               call.offender == i {
                return .sameIncident
            }
        }
        for other in boats.indices where other != i {
            if let id = umpire.openIncident(SeatPair(i, other)), case .called(let call)? = incidents[id]?.outcome,
               call.offender == other, call.victim == i, call.rule == .givingMarkRoom || call.rule == .tackingInTheZone,
               call.tick <= tick, let record = umpire.markRoom(SeatPair(i, other)), record.entitled == i,
               record.owing == other, record.mark == obstacle.name {
                return .exonerated(incidentId: id)
            }
        }
        if let id = compellingIncident(of: i, into: .mark(centre: obstacle.position, radius: obstacle.radius)) {
            return .exonerated(incidentId: id)
        }
        return .turn
    }

    /// Remembers, for 44.1(a), the boats seat `i`'s penalised mark touch shares an incident with: every boat
    /// within the incident separation of her now (`UmpireState.markTouchNeighbours(of:)`). A foul she commits
    /// against one before they separate costs no second turn (`call`). The authoritative race's alone.
    private func rememberMarkTouch(_ i: Int) {
        guard umpire != nil else { return }
        let near = boats.indices.filter { $0 != i && !boats[$0].isGhost && !isSeparated(i, $0) }
        umpire?.setMarkTouchNeighbours(near, of: i)
    }

    /// Forgets, before the tick's calls, every remembered mark touch's neighbour that has separated from her
    /// (`rememberMarkTouch`) or stopped racing. Looked up by seat, in seat order.
    private func forgetSeparatedMarkTouches() {
        guard umpire != nil else { return }
        for i in boats.indices {
            let neighbours = umpire?.markTouchNeighbours(of: i) ?? []
            guard !neighbours.isEmpty else { continue }
            let kept = boats[i].isGhost ? [] : neighbours.filter { !boats[$0].isGhost && !isSeparated(i, $0) }
            if kept != neighbours { umpire?.setMarkTouchNeighbours(kept, of: i) }
        }
    }

    /// Whether seats `a` and `b`'s hulls are more than the rules configuration's `incidents.separation` apart:
    /// as `resolveBoatContacts` closes an incident.
    private func isSeparated(_ a: Int, _ b: Int) -> Bool {
        let hull = boatClass.hull
        let separation = rules.incidents.separation.metres(hullLength: hull.length)
        guard (boats[a].position - boats[b].position).length > separation else { return false }
        return Collision.distance(convex: boats[a].hull(outline: hull.outline),
                                  simplePolygon: boats[b].hull(outline: hull.outline)) > separation
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
            for kind in ObstructionKind.edges where !resolution.touches.contains(kind) {
                let contact = WorldSnapshot.EdgeContact(seat: i, kind: kind)
                if edgeContacts.contains(contact),
                   course.isNear(kind, hull: boats[i].hull(outline: outline), within: RaceEdges.touchMargin) {
                    touching.insert(contact)
                }
            }
        }
        edgeContacts = touching
    }

    /// Opens an incident for `verdict`, records whom it exonerates (rule 43.1: the incident's `exonerated`,
    /// never a call or an event of their own, #92), and, when that is its offender (compelled, 43.1(a), #93),
    /// decides it `.noCall`: no penalty, no event. Otherwise it decides it with a rule call, penalises the offender one
    /// turn (`penalize`; none, `turnsOwed` 0, when her penalised mark touch was in this incident, 44.1(a), #90)
    /// and announces the call, with the turn's deadlines when its clock is fixed at the call.
    /// The umpire holds the incident open until the pair separates (`resolveBoatContacts`): one incident
    /// per pair (#9). The authoritative race's alone: a prediction judges nothing (#96, ADR 0005).
    private func call(_ verdict: Verdict, trigger: Incident.Trigger) {
        let leg = boats[verdict.offender].legIndex
        var incident = incidents.open(between: verdict.offender, and: verdict.victim, tick: tick, leg: leg, trigger: trigger)
        for seat in verdict.exonerated { incident.exonerate(seat) }
        if verdict.exonerated.contains(verdict.offender) {
            incident.outcome = .noCall
            incidents.update(incident)
            umpire?.open(incident.id, for: incident.parties)
            return
        }
        let penalty = rules.raceFormat.penalty
        // 44.1(a) (#90): a foul in the same incident as her penalised mark touch costs no second turn.
        let touchNeighbours = umpire?.markTouchNeighbours(of: verdict.offender) ?? []
        let sameIncidentAsTouch = touchNeighbours.contains(verdict.victim)
        if sameIncidentAsTouch {
            umpire?.setMarkTouchNeighbours(touchNeighbours.filter { $0 != verdict.victim }, of: verdict.offender)
        }
        let clock = sameIncidentAsTouch ? nil : penalize(verdict.offender)
        let call = RuleCall(
            incidentId: incident.id, tick: tick, rule: verdict.rule, offender: verdict.offender, victim: verdict.victim,
            leg: leg, turnsOwed: sameIncidentAsTouch ? 0 : 1,
            startDeadlineTick: clock.map { $0 + RulesConfig.ticks(penalty.start) },
            completeDeadlineTick: clock.map { $0 + RulesConfig.ticks(penalty.complete) })
        incident.outcome = .called(call)
        incidents.update(incident)
        umpire?.open(incident.id, for: incident.parties)
        emit(.ruleCall(call))
    }

    // MARK: - Penalty turns

    /// The most of a full turn the autohelm can leave on a penalty turn's progress (#219): just short of it,
    /// so only a tick the player drives completes the turn.
    static let heldPenaltyProgress = (2 * Double.pi).nextDown

    /// Seat `i` owes one more penalty turn, called now (#9, #89): a foul's (`call`) or a mark touch's (rule 31,
    /// `resolveObstacleContacts`).
    /// Owed turns add up with no cap and are served in order. With none owed it is the current turn at once,
    /// and its clock starts now; otherwise it queues behind the turns she owes, and its clock starts when it
    /// becomes current (`startNextPenaltyClock`). Returns the turn's clock tick when it is fixed now, for the
    /// rule call's deadlines: always under `fromCall` stacking, and under `sequential` only when she owed none.
    /// Internal for tests, which call it as a call on the current tick would. A prediction owes the turn the
    /// server called at `callTick`, the event's (`apply(authoritative:)`, #96).
    @discardableResult
    func penalize(_ i: Int, calledAt callTick: Int? = nil) -> Int? {
        let tick = callTick ?? self.tick
        if boats[i].penaltyTurnsOwed == 0 {
            boats[i].penaltyTurnsOwed = 1
            boats[i].penaltyProgress = 0
            boats[i].penaltyClockTick = tick
            return tick
        }
        boats[i].penaltyTurnsOwed += 1
        boats[i].queuedPenaltyCallTicks.append(tick)
        switch rules.raceFormat.penalty.stackedPenaltyDeadlines {
        case .sequential: return nil
        case .fromCall: return tick
        }
    }

    /// Moves seat `i`'s current penalty turn on by this tick's heading change `turn`, radians (#9, #89). A turn
    /// is 360° one way, so it includes a tack and a gybe. Its direction is set by the first turning the player
    /// drives after it becomes current; a tick the player drives against it gives the turn up, its progress
    /// back to 0 (`penaltyReset`); a full turn serves it (`penaltyServed`), what she turned past it carrying
    /// into the next owed turn, whose clock then starts. Crossing the rules' `startedTurn` (30°) is announced
    /// (`penaltyStarted`).
    ///
    /// The player drives a tick with the rudder held off centre, or through the tack/gybe tap the autohelm is
    /// sailing for her (`playerDriven`). Letting go mid-turn hands her to the autohelm (#219), which never
    /// tacks or gybes by itself. The 360° is counted from her heading whoever steers, but a tick of the
    /// autohelm holding her (its bear-away to the groove after a let-go head to wind included) can neither
    /// undo the turn nor complete it: it moves the progress in the turn's direction, never back past its start,
    /// nor back under `startedTurn` once she has turned that far (started stays started until she gives the
    /// turn up or serves it, so the start deadline reads it off the progress), and never onto the full turn
    /// (`heldPenaltyProgress`), so the next tick the player drives turning on completes it. Before the player
    /// has set a direction the autohelm's turning counts for nothing.
    ///
    /// A prediction (#96) turns as the player drives it but never completes a turn: its progress runs on past a
    /// full turn, up to the turns she owes, and the server's `penaltyServed` (`apply(authoritative:)`) takes each
    /// full turn off as the server served it, carrying the rest into the next. So a turn is never served twice, and
    /// the arc (`OwedPenalty.progress`) waits just short of a full turn until the server's word comes. The turns
    /// past the full ones (the server served them, its word is on the way) count as the autohelm's start.
    private func turnPenalty(_ b: inout Boat, seat i: Int, turn: Double, playerDriven: Bool) {
        let before = b.penaltyProgress
        let direction: Double = before > 0 ? 1 : before < 0 ? -1 : 0
        let startedTurn = rules.raceFormat.penalty.startedTurn
        // A prediction's full turns the server has served and not yet said so (always 0 in the authoritative race).
        let served = umpire == nil
            ? min((abs(before) / (2 * .pi)).rounded(.down), Double(max(b.penaltyTurnsOwed - 1, 0))) * 2 * .pi : 0
        var progress: Double
        if playerDriven {
            if direction * turn < 0 {
                b.penaltyProgress = 0
                emit(.penaltyReset(seat: i))
                return
            }
            progress = before + turn
        } else {
            guard direction != 0 else { return }
            let floor = served + (abs(before) - served >= startedTurn ? startedTurn : 0)
            progress = direction * min(max(direction * (before + turn), floor), served + Race.heldPenaltyProgress)
        }
        if abs(before) < startedTurn && abs(progress) >= startedTurn { emit(.penaltyStarted(seat: i)) }
        if umpire == nil {
            let owed = Double(b.penaltyTurnsOwed) * 2 * .pi
            b.penaltyProgress = min(max(progress, -owed), owed)
            return
        }
        if abs(progress) >= 2 * .pi {
            progress -= (progress < 0 ? -2 : 2) * .pi
            b.penaltyTurnsOwed -= 1
            emit(.penaltyServed(seat: i))
            if b.penaltyTurnsOwed == 0 {
                progress = 0
                b.penaltyClockTick = nil
                b.queuedPenaltyCallTicks = []
            } else {
                startNextPenaltyClock(&b, now: tick)
            }
        }
        b.penaltyProgress = progress
    }

    /// Starts the clock of the owed turn that has just become current, now, as the rules' stacking says (G4):
    /// under `sequential` at the later of its call and now, the previous turn's completion; under `fromCall`
    /// at its call. A queued turn whose call the boat doesn't hold (`Boat.queuedPenaltyCallTicks`) starts now.
    private func startNextPenaltyClock(_ b: inout Boat, now tick: Int) {
        let call = b.queuedPenaltyCallTicks.isEmpty ? nil : b.queuedPenaltyCallTicks.removeFirst()
        switch rules.raceFormat.penalty.stackedPenaltyDeadlines {
        case .sequential: b.penaltyClockTick = max(call ?? tick, tick)
        case .fromCall: b.penaltyClockTick = call ?? tick
        }
    }

    /// Disqualifies every boat that misses a penalty deadline on this tick (#9, #89), a ghost from this tick
    /// (#30): her current turn not started (turned the rules' `startedTurn`) at its start deadline
    /// (`missedStart`), or not completed by its complete deadline (`missedComplete`); under `fromCall` stacking
    /// also a turn still queued at its own start deadline (`missedStart`). The turning this tick counts first.
    /// The authoritative race's alone: a disqualification is a rule event (ADR 0005), so a client shows it when
    /// the server sends it.
    private func enforcePenaltyDeadlines() {
        guard umpire != nil else { return }
        let penalty = rules.raceFormat.penalty
        let start = RulesConfig.ticks(penalty.start), complete = RulesConfig.ticks(penalty.complete)
        for i in boats.indices where !boats[i].isGhost && boats[i].penaltyTurnsOwed > 0 {
            let boat = boats[i]
            guard let clock = boat.penaltyClockTick else { continue }
            if tick >= clock + complete {
                disqualify(i, reason: Race.missedComplete)
            } else if tick == clock + start && abs(boat.penaltyProgress) < penalty.startedTurn {
                disqualify(i, reason: Race.missedStart)
            } else if penalty.stackedPenaltyDeadlines == .fromCall, let queued = boat.queuedPenaltyCallTicks.first,
                      tick >= queued + start {
                disqualify(i, reason: Race.missedStart)
            }
        }
    }

    /// `RaceEvent.Kind.disqualified`'s reason for a penalty turn not started by its start deadline (#89).
    public static let missedStart = "missedStart"
    /// `RaceEvent.Kind.disqualified`'s reason for a penalty turn not completed by its complete deadline (#89).
    public static let missedComplete = "missedComplete"

    // MARK: - The server's word, in a prediction (#96)

    /// Whether `apply(authoritative:)` can change a prediction for `event`: a rule call with a turn, a mark touch,
    /// a penalty reset or served, a disqualification, an OCS notice or clearing, a finish (#96). A client re-sails
    /// for these alone (`PredictedRace`).
    public static func isRuling(_ event: RaceEvent) -> Bool {
        switch event.kind {
        case .ruleCall(let call): call.turnsOwed > 0
        case .markTouch, .penaltyReset, .penaltyServed, .disqualified, .ocsNotice, .cleared, .finished: true
        default: false
        }
    }

    /// Applies one of the server's authoritative events to a prediction (#96, ADR 0005), as the authoritative race
    /// changed its state when it emitted it, with the event's tick as the call's: a rule call with a turn and a mark
    /// touch owe a turn (`penalize`), `penaltyReset` gives the current turn up, `penaltyServed` serves it (the turning
    /// past the full turn carried into the next owed turn, whose clock starts at the event's tick), `disqualified`
    /// makes her DSQ and a ghost, owing nothing, `ocsNotice` makes her OCS, `cleared` puts her back in the
    /// pre-start, and `finished` finishes her if the prediction hasn't. Every other event, `markRoomNotice`
    /// included (reserved, no longer emitted, #403), changes nothing (`isRuling`). The caller applies each event once, in the server's order, at the
    /// end of its tick (`PredictedRace`); a prediction makes none of these changes itself. A prediction's alone:
    /// the authoritative race is the server.
    public func apply(authoritative event: RaceEvent) {
        precondition(umpire == nil, "only a prediction applies the server's events")
        func has(_ seat: Int) -> Bool { boats.indices.contains(seat) }
        switch event.kind {
        case .ruleCall(let call) where call.turnsOwed > 0 && has(call.offender):
            for _ in 0..<call.turnsOwed { penalize(call.offender, calledAt: event.tick) }
        case .markTouch(let seat, _) where has(seat):
            penalize(seat, calledAt: event.tick)
        case .penaltyReset(let seat) where has(seat):
            boats[seat].penaltyProgress = 0
        case .penaltyServed(let seat) where has(seat) && boats[seat].penaltyTurnsOwed > 0:
            var b = boats[seat]
            b.penaltyTurnsOwed -= 1
            if b.penaltyTurnsOwed == 0 {
                b.penaltyProgress = 0
                b.penaltyClockTick = nil
                b.queuedPenaltyCallTicks = []
            } else {
                // The turning past the full turn carries into the next, as `turnPenalty` serves it.
                let progress = b.penaltyProgress
                let direction: Double = progress < 0 ? -1 : 1
                b.penaltyProgress = abs(progress) >= 2 * .pi ? progress - direction * 2 * .pi : 0
                startNextPenaltyClock(&b, now: event.tick)
            }
            boats[seat] = b
        case .disqualified(let seat, _) where has(seat):
            boats[seat].status = .dsq
            boats[seat].penaltyTurnsOwed = 0
            boats[seat].penaltyProgress = 0
            boats[seat].penaltyClockTick = nil
            boats[seat].queuedPenaltyCallTicks = []
        case .ocsNotice(let seat) where has(seat) && boats[seat].status == .prestart:
            boats[seat].status = .ocs
        case .cleared(let seat) where has(seat) && boats[seat].status == .ocs:
            boats[seat].status = .prestart
        case .finished(let seat, let place) where has(seat) && boats[seat].status != .finished:
            let time = Double(event.tick) / Double(Race.tickRate)
            boats[seat].status = .finished
            boats[seat].place = place
            boats[seat].finishTime = time
            finishers = max(finishers, place)
            if firstFinishTime.map({ time < $0 }) ?? true { firstFinishTime = time }
        default:
            break
        }
    }

    /// The server umpire's word on one seat's pairs, as a prediction holds it from the last snapshot (#96): who
    /// keeps clear (`keepClearRelations(of:)`) and the windward boats she is held to her proper course against
    /// (`properCourseRestrictions(of:)`), for the pairs the server sent (those in range of her). Never the
    /// prediction's own world: the umpire is the server's (ADR 0005).
    public struct UmpireRelations: Equatable, Sendable {
        /// The seat the relations are for: the client's own.
        public var seat: Int
        /// Who keeps clear between `seat` and each seat, by seat; nil at `seat`, out of range, or with no relation.
        public var keepClear: [RightOfWay?]
        /// The windward boats `seat` is held to her proper course against (rule 17), in seat order.
        public var restrictedBy: [Int]

        public init(seat: Int, keepClear: [RightOfWay?], restrictedBy: [Int]) {
            self.seat = seat
            self.keepClear = keepClear
            self.restrictedBy = restrictedBy
        }
    }

    /// The server umpire's relations a prediction last took (`setUmpireRelations`), nil before the first or
    /// after a resync. Always nil in the authoritative race, which has the umpire itself.
    public private(set) var umpireRelations: UmpireRelations?

    /// Takes the server umpire's `relations` (#96), or forgets them with nil. A prediction's alone. Relations
    /// for a fleet of another size are dropped.
    public func setUmpireRelations(_ relations: UmpireRelations?) {
        precondition(umpire == nil, "only a prediction takes the server umpire's relations")
        guard let relations, relations.keepClear.count == boats.count, boats.indices.contains(relations.seat) else {
            umpireRelations = nil
            return
        }
        umpireRelations = relations
    }

    /// Seat `seat`'s owed penalty turns as the HUD shows them (G4, #114), or nil while she owes none.
    public func owedPenalty(ofSeat seat: Int) -> OwedPenalty? {
        guard boats.indices.contains(seat) else { return nil }
        return OwedPenalty(boats[seat], penalty: rules.raceFormat.penalty)
    }

    // MARK: - Start, roundings, finish

    /// OCS (#9, rule 29.1): any point of her hull on the course side of the line or its extensions at the gun.
    /// A prediction (#96) judges no OCS: its boats are OCS by the server's `ocsNotice` or snapshot.
    private func fireGun() {
        for i in boats.indices where umpire != nil && boats[i].status == .prestart && isOverStartLine(boats[i]) {
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
                // Owing a penalty turn she doesn't finish (#89): she takes it on the course side and crosses
                // again. Nothing moves on, so that crossing is checked the same way.
                if boats[i].penaltyTurnsOwed == 0 { finish(i) }
            } else {
                if progress.legIndex > boats[i].legIndex { emit(.rounded(seat: i, mark: course.name(of: leg))) }
                boats[i].legIndex = progress.legIndex
                boats[i].roundingStage = progress.stage
            }
        case .finished, .dsq:
            break
        }
    }

    /// Seat `i` crossed the finish line owing no penalty turn: she finishes, a ghost from this tick (#30). The
    /// first finish opens the finish window (#8).
    private func finish(_ i: Int) {
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

    /// Disqualifies seat `i` now: DSQ, and a ghost from the call (#30), owing no more penalty turns. Called at
    /// a missed penalty deadline (`enforcePenaltyDeadlines`, #89). A DSQ doesn't open the finish window: only a
    /// finisher does (#8).
    private func disqualify(_ i: Int, reason: String) {
        boats[i].status = .dsq
        boats[i].penaltyTurnsOwed = 0
        boats[i].penaltyProgress = 0
        boats[i].penaltyClockTick = nil
        boats[i].queuedPenaltyCallTicks = []
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
    ///
    /// It keeps the path length (`distanceToFinish`), not the ladder distance that ranks the fleet (#267): a
    /// time estimate wants the metres still to sail, and a pace is metres of path per second.
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
    /// Bots still racing are placed by ladder distance, and a human who finished keeps the finish.
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

    /// The results as the race stands (`RaceResults`): finishers by finish, boats racing by ladder distance
    /// (`ladderDistanceToFinish(of:)`, #267), then DSQ, OCS (never started included) and RET. A human seat gone at the close whose boat
    /// hasn't finished or been disqualified is RET (#16), and so is each such seat in an all-gone close's
    /// `allGoneOrder` (`closeAllGone`). Rated if at least 2 humans were at the gun (#30).
    private func score(allGoneOrder: [Int]?) -> RaceResults {
        let presence = presence()
        var isRET = boats.indices.map { isGone($0, presence) }
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
        let distances = racing.map { ladderRank(boats[$0]) }
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

    /// Metres `boat` still has to sail to finish, round her remaining marks (#8): the path length, which times
    /// the close (`expectedCloseTick`). It no longer ranks anything: standings, places and by-distance results
    /// go by `ladderDistanceToFinish(of:)` (#267).
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

    /// Metres `boat` still has to go to finish by the ladder (#267): what ranks the boats racing, places those
    /// unfinished at the close, and gives the gap to the leader (`gapToLeader(of:)`).
    ///
    /// Racing on a beat or a run, it is her distance to the leg's target measured along the course axis
    /// (`CourseLayout.upwind`, fixed for the race, never the live wind), so across the ladder lines: boats on
    /// one ladder line are level however far apart across the course. On a reach (a leg the axis can't
    /// measure, W → O) it is the straight line to the target, so the order moves along it. Then every later
    /// leg the same way (`ladderAfterTarget`). On the finish leg, her distance to the nearest point of the
    /// finish line along the axis. At a target the leg's and the next leg's totals are equal, so a rounding
    /// makes no jump. Not racing, it is `distanceToFinish(of:)`.
    public func ladderDistanceToFinish(of boat: Boat) -> Double {
        guard boat.status == .racing else { return distanceToFinish(of: boat) }
        let leg = boat.legIndex
        guard course.legs.indices.contains(leg) else { return .infinity }
        guard case .round = course.legs[leg] else {
            let line = Collision.closestPoint(on: course.finishLine.segment, to: boat.position)
            return abs((line - boat.position).dot(ladderAxis))
        }
        let toTarget = legTargets[leg] - boat.position
        let here = isReachLeg[leg] ? toTarget.length : abs(toTarget.dot(ladderAxis))
        return here + ladderAfterTarget[leg]
    }

    /// Metres by the ladder `seat` is behind the leader (#267): her `ladderDistanceToFinish(of:)` less the least
    /// of any boat racing, or 0 while a boat has finished. A finished boat's own gap is 0. Nil for a boat not
    /// yet started (prestart or OCS), disqualified, or whose player has gone and who hasn't finished (#30). A
    /// gone boat can still be the leader. `gapsToLeader()[seat]`: for the whole fleet, call that once.
    public func gapToLeader(of seat: Int) -> Double? {
        gapsToLeader()[seat]
    }

    /// `gapToLeader(of:)` for every seat, by seat (#268): the seats' presence, each racing boat's ladder
    /// distance and the leader's are worked out once, so a client can read the whole fleet every tick.
    public func gapsToLeader() -> [Double?] {
        let presence = presence()
        let anyFinished = boats.contains { $0.status == .finished }
        let ladder = boats.map { $0.status == .racing ? ladderDistanceToFinish(of: $0) : .infinity }
        let leader = ladder.filter(\.isFinite).min()
        return boats.indices.map { seat -> Double? in
            let boat = boats[seat]
            switch boat.status {
            case .prestart, .ocs, .dsq: return nil
            case .finished, .racing: break
            }
            if isGone(seat, presence) { return nil }
            if boat.status == .finished { return 0 }
            let mine = ladder[seat]
            guard mine.isFinite else { return nil }
            if anyFinished { return mine }
            return mine - (leader ?? mine)
        }
    }

    /// Whether `seat`'s player has gone and her boat is neither finished nor disqualified: RET at a close.
    private func isGone(_ seat: Int, _ presence: [Presence]) -> Bool {
        presence[seat].isHuman && presence[seat].isGone && !boats[seat].isGhost
    }

    /// `ladderDistanceToFinish(of:)` to whole millimetres, for ranking: two boats on one ladder line differ
    /// only by rounding noise, and the seat must break their tie.
    private func ladderRank(_ boat: Boat) -> Double {
        (ladderDistanceToFinish(of: boat) * 1000).rounded()
    }

    /// `isReachLeg` and `ladderAfterTarget` for a course and its legs' `targets`. Each leg runs from the last
    /// leg's target (the first from the start line's centre) to its own, the finish leg to the nearest point of
    /// the finish line.
    static func ladderLegs(_ targets: [Vec2], course: CourseLayout) -> (isReach: [Bool], after: [Double]) {
        let axis = course.upwind
        let legs = course.legs
        var isReach = Array(repeating: false, count: legs.count)
        var length = Array(repeating: 0.0, count: legs.count)
        var from = course.startLine.centre
        for k in legs.indices {
            let to: Vec2
            if case .round = legs[k] {
                to = targets[k]
            } else {
                to = Collision.closestPoint(on: course.finishLine.segment, to: from)
            }
            let run = to - from
            let along = abs(run.dot(axis))
            isReach[k] = abs(run.dot(axis.rightPerp)) > along
            length[k] = isReach[k] ? run.length : along
            from = to
        }
        var after = Array(repeating: 0.0, count: legs.count)
        for k in legs.indices.reversed() where k + 1 < legs.count {
            after[k] = length[k + 1] + after[k + 1]
        }
        return (isReach, after)
    }

    /// Seats from first to last. Once the race has closed, the results' display order (`results`). Until
    /// then: finishers by finish, boats racing by ladder distance (`ladderDistanceToFinish(of:)`, #267), DSQ,
    /// then boats not yet started by their distance to the start line's centre. A boat whose player has gone
    /// keeps her place among them until the close makes her RET.
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
        case .racing: return (1, ladderRank(b), i)
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
        for a in boats.indices {
            for b in boats.indices where b > a && boatContacts.contains(Pair(a: a, b: b)) {
                boatPairs.append(.init(a, b))
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
            ObstructionKind.edges.map { WorldSnapshot.EdgeContact(seat: seat, kind: $0) }.filter(edgeContacts.contains)
        }
        return WorldSnapshot(
            tick: tick,
            seats: boats.indices.map { WorldSnapshot.Seat(boat: boats[$0], heldInput: heldInputs[$0]) },
            touchingBoats: boatPairs, touchingObstacles: obstacles, touchingEdges: edges,
            incidents: incidents,
            firstFinishTime: firstFinishTime, isOver: isOver, results: results, windKeys: wind.keys,
            overlaps: overlaps.memory, ribbonPoints: wake.points, emissionLevels: wake.levels, headers: headerState,
            backwind: backwindSails
        )
    }

    /// Replaces the world with `snapshot`, so stepping on continues from its tick (ADR 0005). The race
    /// keeps what isn't world state: its setup, course and wind seed, and its umpire's memory (#88), less
    /// any open incident the snapshot's incidents don't end on for its pair. So a race that imports another
    /// race's snapshot holds no incident open, and can call a pair the other wouldn't until they separate.
    /// Its rule 18 records (#91) carry on, tested against the new world from the next step.
    /// Bots run outside the race (#60), and their memory isn't in a snapshot, so bots driving a restored
    /// race won't make the same decisions.
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
    /// rounding stage the course doesn't have, a negative penalty count or penalty clocks that don't match it
    /// (`Boat.penaltyClockTick`, `queuedPenaltyCallTicks`), a bad contact, overlap, incident or
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
            if let field = invalidField(of: entry.boat, tick: snapshot.tick) {
                throw WorldSnapshotError.invalidBoat(seat: seat, field: field)
            }
        }
        guard snapshot.firstFinishTime?.isFinite ?? true else { throw WorldSnapshotError.invalidTime }
        let seatRange = boats.indices
        let validPair = { (p: WorldSnapshot.SeatPair) in seatRange.contains(p.a) && seatRange.contains(p.b) && p.a < p.b }
        guard snapshot.touchingBoats.allSatisfy(validPair),
              snapshot.touchingObstacles.allSatisfy({ seatRange.contains($0.seat) && course.obstacles.indices.contains($0.obstacle) })
        else { throw WorldSnapshotError.invalidContact }
        let kinds = ObstructionKind.edges
        let edgeOrder = { (e: WorldSnapshot.EdgeContact) in e.seat * kinds.count + kinds.firstIndex(of: e.kind)! }
        guard snapshot.touchingEdges.allSatisfy({ seatRange.contains($0.seat) && kinds.contains($0.kind) }),
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
        let incidentCount = snapshot.incidents.count
        if let bad = snapshot.incidents.contacts.firstIndex(where: {
            !seatRange.contains($0.parties.low) || !seatRange.contains($0.parties.high)
                || !course.legs.indices.contains($0.leg) || $0.tick > snapshot.tick
                || ($0.incidentId.map { !(0..<incidentCount).contains($0) } ?? false)
        }) {
            throw WorldSnapshotError.invalidBoatContact(index: bad)
        }
        if let bad = snapshot.incidents.markTouches.firstIndex(where: {
            !seatRange.contains($0.seat) || !course.legs.indices.contains($0.leg) || $0.tick > snapshot.tick
        }) {
            throw WorldSnapshotError.invalidMarkTouch(index: bad)
        }
        if let bad = snapshot.incidents.protests.firstIndex(where: {
            !seatRange.contains($0.protester) || !seatRange.contains($0.protested)
                || !course.legs.indices.contains($0.leg) || $0.tick > snapshot.tick
        }) {
            throw WorldSnapshotError.invalidProtest(index: bad)
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

        try validateShadowState(of: snapshot)

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
        pressureMapDrawn = nil

        tick = snapshot.tick
        boats = snapshot.seats.map(\.boat)
        heldInputs = snapshot.seats.map(\.heldInput)
        boatContacts = Set(snapshot.touchingBoats.map { Pair(a: $0.a, b: $0.b) })
        obstacleContacts = Set(snapshot.touchingObstacles.map { Pair(a: $0.seat, b: $0.obstacle) })
        edgeContacts = Set(snapshot.touchingEdges)
        overlaps = OverlapTracker(seats: boats.count, memory: snapshot.overlaps)
        incidents = snapshot.incidents
        umpire?.keepOpenIncidents(in: incidents)
        umpire?.forgetTrack()
        firstFinishTime = snapshot.firstFinishTime
        isOver = snapshot.isOver
        results = snapshot.results
        // Places count up from the boats already finished.
        finishers = boats.filter { $0.status == .finished }.count
        pending.removeAll()
        events.removeAll()
        wake = TurbulenceRibbons(shadow: boatClass.windShadow, points: snapshot.ribbonPoints, levels: snapshot.emissionLevels)
        headerState = snapshot.headers
        backwindSails = snapshot.backwind
    }

    /// Throws `invalidShadowState` unless the snapshot's ribbons, headers and backwind (#377) are each empty or one
    /// per seat, with values the race can step from.
    private func validateShadowState(of snapshot: WorldSnapshot) throws {
        let n = boats.count
        let sizeOK = { (count: Int) in count == 0 || count == n }
        let level = { (x: Double) in x >= 0 && x <= 1 }
        let pointOK = { (p: TurbulenceRibbons.Point) in
            [p.position.x, p.position.y, p.drift.x, p.drift.y, p.peak, p.scale, p.growth].allSatisfy(\.isFinite)
                && p.life.isFinite && p.life > 0 && p.born <= snapshot.tick
        }
        guard sizeOK(snapshot.ribbonPoints.count), sizeOK(snapshot.emissionLevels.count), sizeOK(snapshot.headers.count),
              sizeOK(snapshot.backwind.levels.count),
              snapshot.ribbonPoints.allSatisfy({ $0.allSatisfy(pointOK) }),
              snapshot.emissionLevels.allSatisfy(level), snapshot.backwind.levels.allSatisfy(level),
              snapshot.headers.allSatisfy({ $0.isFinite && $0 >= 0 })
        else { throw WorldSnapshotError.invalidShadowState }
    }

    /// The first field of `boat` the race couldn't step from at `tick`, or nil.
    private func invalidField(of boat: Boat, tick: Int) -> String? {
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
        // A clock and queued calls exactly while she owes a turn, none after the tick, the queue in call order.
        let ticks = -setup.startSequenceTicks...tick
        if boat.penaltyTurnsOwed == 0 {
            guard boat.penaltyClockTick == nil else { return "penaltyClockTick" }
        } else {
            guard let clock = boat.penaltyClockTick, ticks.contains(clock) else { return "penaltyClockTick" }
        }
        let queue = boat.queuedPenaltyCallTicks
        guard queue.count < max(boat.penaltyTurnsOwed, 1), queue.allSatisfy(ticks.contains),
              zip(queue, queue.dropFirst()).allSatisfy({ $0 <= $1 })
        else { return "queuedPenaltyCallTicks" }
        return nil
    }
}
