import Foundation
import RegattaBots
import RegattaCore

// `regatta-timetrial` (#583, stage 1): the oracle time trial. One boat, no fleet, from a fixed start at the gun, sails
// a race's course: the oracle (`Oracle`, a search over the whole seeded wind) and every tier and profile on the same
// seeds, each alone. The ledger (`LapLedger`) splits each lap into legs and causes, so a bot's time behind the oracle
// says where it went. Measurement only: nothing here is read by a live bot or the race.

/// One seed of the time trial's pool: a race's seeds and files, sailed by one boat.
public struct TimeTrialSeed: Codable, Hashable, Sendable {
    /// "R3" for reference race 3, "H3" for hold-out seed 3.
    public var name: String
    public var raceSeed: UInt64
    public var windSeed: UInt64
    /// Each file as `id@version`, bundled.
    public var venue: String
    public var conditions: String
    public var boatClass: String
    public var rules: String
    public var laps: Int

    public init(name: String, raceSeed: UInt64, windSeed: UInt64, venue: String, conditions: String, boatClass: String,
                rules: String, laps: Int) {
        self.name = name
        self.raceSeed = raceSeed
        self.windSeed = windSeed
        self.venue = venue
        self.conditions = conditions
        self.boatClass = boatClass
        self.rules = rules
        self.laps = laps
    }

    /// The reference regatta's races (#367, `ReferenceRegatta.bundled`), in its order: their seeds, files and laps.
    public static var reference: [TimeTrialSeed] {
        ReferenceRegatta.bundled.races.map { race in
            let entry = race.entry
            return TimeTrialSeed(name: "R\(race.number)", raceSeed: entry.raceSeed.value, windSeed: race.windSeed.value,
                                 venue: entry.venue, conditions: entry.conditions, boatClass: entry.boatClass,
                                 rules: entry.rulesConfiguration, laps: entry.laps)
        }
    }

    /// Hold-out seeds (#583): reference race n's files and laps on new race and wind seeds, for checking that what is
    /// tuned on the reference regatta holds elsewhere. Seeds are literals of a fixed rule, never drawn at run time.
    public static var holdOut: [TimeTrialSeed] { renamed("H", base: 0x0583_0000_0000_0000) }

    /// Validation seeds (#583 stage 3): as the hold-out seeds, on other seeds again, for checking a set tuned on the
    /// reference and hold-out seeds together.
    public static var validation: [TimeTrialSeed] { renamed("V", base: 0x0583_1000_0000_0000) }

    private static func renamed(_ prefix: String, base: UInt64) -> [TimeTrialSeed] {
        reference.enumerated().map { index, seed in
            var held = seed
            held.name = "\(prefix)\(index + 1)"
            held.raceSeed = base &+ UInt64(index + 1) &* 0x9E37_79B9
            held.windSeed = BotRaceHarness.windSeed(for: held.raceSeed).value
            return held
        }
    }

    /// The pools of seeds the time trial sails.
    public enum Pool: String, CaseIterable, Sendable {
        case reference, holdout, validation

        public var seeds: [TimeTrialSeed] {
            switch self {
            case .reference: TimeTrialSeed.reference
            case .holdout: TimeTrialSeed.holdOut
            case .validation: TimeTrialSeed.validation
            }
        }
    }
}

/// Who sails a time trial (#583).
public enum TimeTrialSailor: Hashable, Sendable, CustomStringConvertible {
    /// The search (`Oracle`).
    case oracle
    /// A live bot of the tier: her skill and handling drawn in its bands from her seed, as the fleet's are.
    case tier(BotTier)
    /// A suite profile at skill 1 (`BotProfile`): the executor, perfect handling with the baseline's groove-only tactics,
    /// or the tactician.
    case profile(BotProfile)

    public var description: String {
        switch self {
        case .oracle: "oracle"
        case .tier(let tier): tier.rawValue
        case .profile(let profile): profile.rawValue
        }
    }

    /// `name` as `description` gives it.
    public init?(_ name: String) {
        if name == "oracle" {
            self = .oracle
        } else if let tier = BotTier(rawValue: name) {
            self = .tier(tier)
        } else if let profile = BotProfile(rawValue: name) {
            self = .profile(profile)
        } else {
            return nil
        }
    }

    /// The bots the owner reads the table for (#583): Club, Regional, National, the executor and the tactician.
    public static let standard: [TimeTrialSailor] = [.tier(.club), .tier(.regional), .tier(.national),
                                                     .profile(.executor), .profile(.tactician)]

    /// Her driver for the time trial's one seat, `seat` of its race.
    func driver(raceSeed: RaceSeed, seat: Int = 0) -> BotDriver? {
        switch self {
        case .oracle: nil
        case .tier(let tier): BotDriver(seat: seat, raceSeed: raceSeed, tier: tier)
        case .profile(let profile): BotDriver(seat: seat, raceSeed: raceSeed, skill: 1, profile: profile)
        }
    }
}

/// A seed's course for one boat (#583): the race of the seed, and the world at the gun with her at the fixed start.
/// Every sailor of a seed starts from that one state: half a hull length below the middle of the line, close-hauled on
/// starboard in the wind there, at her polar speed, the rudder centred. A race seats two at least (`RaceSetup.fleetSizes`),
/// so the second seat is a ghost from the gun, disqualified at the committee end: a ghost casts no shadow, touches
/// nothing and never opens the finish window, and the race closes once she finishes.
///
/// A start trial's course (#584, `init(_:start:)`) begins at the start of the sequence instead: the race seats the
/// trial's whole fleet, so the line and the opening are that fleet's, and she is in seat `start.seat`'s place of the
/// opening (or the start row), as she would be racing; every other seat is a ghost from the first tick.
public final class TimeTrialCourse {
    public let seed: TimeTrialSeed
    public let setup: RaceSetup
    public let files: RaceFiles
    public let windSeed: WindSeed
    /// The world her trial begins in: the gun, tick 0, with her at the start; a start trial's, the start of the sequence.
    public let origin: WorldSnapshot
    /// The lap trial's origin: the world at the gun.
    public var gun: WorldSnapshot { origin }
    /// A start trial's fleet and her seat in it (#584); nil for a lap trial.
    public let start: (fleetSize: Int, seat: Int)?
    /// A hold-one-out's fleet (#584 stage 2, `init(holdOut:seat:seed:)`): every other seat's inputs as logged, by the
    /// tick they apply at; nil for a time trial alone.
    public let fleet: [Int: [InputRecord]]?
    /// Her seat in the race: the held-out seat, else 0 (a trial alone is seat 0, its other seats ghosts).
    public let her: Int
    /// The race's course, as every race on the setup derives it.
    public let course: CourseLayout
    public let boatClass: BoatClass
    /// The race's base wind strength (`WindSetup.baseStrength`), m/s.
    public let baseWindStrength: Double

    /// The lap trial's course: her at the fixed start at the gun.
    public convenience init(_ seed: TimeTrialSeed) throws {
        try self.init(seed, start: nil)
    }

    /// With `start`, a start trial's (#584): her in seat `start.seat`'s place of a `start.fleetSize` fleet at the start of
    /// the sequence.
    public init(_ seed: TimeTrialSeed, start: (fleetSize: Int, seat: Int)?) throws {
        self.seed = seed
        self.start = start
        fleet = nil
        her = 0
        let classFile = try BotRaceHarness.bundledClass(seed.boatClass)
        let venue = try dataFileKey(seed.venue)
        let conditions = try dataFileKey(seed.conditions)
        let seats = Array(repeating: SeatKind.bot, count: start?.fleetSize ?? 2)
        setup = try RaceSetup(raceSeed: RaceSeed(seed.raceSeed), seats: seats, laps: seed.laps, boatClass: classFile.ref,
                              venue: VenueFile.bundled(id: venue.id, version: venue.version).ref,
                              conditions: ConditionsFile.bundled(id: conditions.id, version: conditions.version).ref,
                              rulesConfiguration: BotRaceHarness.bundledRules(seed.rules).ref)
        files = try RaceFiles(resolving: setup)
        windSeed = WindSeed(seed.windSeed)
        let race = try Race(setup: setup, files: files, mode: .authoritative(windSeed: windSeed))
        course = race.course
        boatClass = race.boatClass
        baseWindStrength = race.windSetup.baseStrength
        if let start {
            origin = try Self.startOrigin(race, seat: start.seat)
            return
        }
        while race.tick < 0 { race.step() }
        var snapshot = race.exportSnapshot()
        let upwind = course.upwind
        let position = course.startLine.centre - upwind * (0.5 * boatClass.hull.length + 0.5 * boatClass.hull.length)
        let wind = race.groundWind(at: position)
        let twa = boatClass.polar.bestUpwind(tws: wind.speed).twa
        var boat = snapshot.seats[0].boat
        boat.position = position
        boat.heading = wrapAngle(wind.direction - twa)
        boat.speed = BoatDynamics.polarTarget(relativeWind: twa, boomSide: .port, tws: wind.speed, isPlaning: false,
                                              spinnaker: .down, boatClass: boatClass)
        boat.boomSide = .port
        boat.rudder = 0
        boat.desiredRudder = 0
        boat.autohelm = nil
        boat.status = .prestart
        boat.legIndex = 0
        boat.roundingStage = 0
        boat.isTacking = false
        boat.tackCrossingTick = nil
        boat.isPlaning = false
        boat.spinnaker = .down
        boat.averagedWindSpeed = wind.speed
        snapshot.seats[0].boat = boat
        snapshot.seats[0].heldInput = .neutral
        var ghost = snapshot.seats[1].boat
        ghost.position = course.startLine.committee.position
            + (course.startLine.committee.position - course.startLine.pin.position).normalized * 50 - upwind * 50
        ghost.speed = 0
        ghost.rudder = 0
        ghost.desiredRudder = 0
        ghost.autohelm = nil
        ghost.status = .dsq
        snapshot.seats[1].boat = ghost
        snapshot.seats[1].heldInput = .neutral
        snapshot.ribbonPoints = []
        snapshot.emissionLevels = []
        snapshot.headers = []
        snapshot.backwind = BackwindSails()
        snapshot.touchingBoats = []
        snapshot.touchingObstacles = []
        snapshot.touchingEdges = []
        try race.importSnapshot(snapshot)
        origin = race.exportSnapshot()
    }

    /// A hold-one-out's course (#584 stage 2): `log`'s race from the start of the sequence, its whole fleet on the water,
    /// she in `seat` and every other seat sailing its logged inputs again (ADR 0002: a replay runs no brain), so they
    /// sail as they did and don't answer her. `seed` names it.
    public init(holdOut log: RaceLog, seat: Int, seed: TimeTrialSeed) throws {
        self.seed = seed
        setup = log.header.setup
        start = (fleetSize: setup.fleetSize, seat: seat)
        her = seat
        fleet = Dictionary(grouping: log.inputs.filter { $0.seat != seat }, by: \.tick)
        files = try RaceFiles(resolving: setup)
        windSeed = log.header.windSeed
        let race = try Race(setup: setup, files: files, mode: .authoritative(windSeed: windSeed))
        course = race.course
        boatClass = race.boatClass
        baseWindStrength = race.windSetup.baseStrength
        origin = race.exportSnapshot()
    }

    /// Applies the fleet's logged inputs for the tick `race` steps to next, in the log's order (a hold-one-out's; nothing
    /// for a trial alone). Call it before each step, as `Replayer.replay` applies a log's.
    func applyFleet(_ race: Race) {
        guard let records = fleet?[race.tick + 1] else { return }
        for record in records {
            switch record.kind {
            case .held(let input): race.apply(input, seat: record.seat, atTick: record.tick)
            case .tap(let tap): race.tap(tap, seat: record.seat, atTick: record.tick)
            }
        }
    }

    /// A start trial's origin (#584): `race` at the start of the sequence with her, seat 0, in `seat`'s place and trim,
    /// every other seat a ghost, disqualified and out of the way beyond the committee end.
    private static func startOrigin(_ race: Race, seat: Int) throws -> WorldSnapshot {
        var snapshot = race.exportSnapshot()
        let place = snapshot.seats[seat]
        snapshot.seats[0].boat.position = place.boat.position
        snapshot.seats[0].boat.heading = place.boat.heading
        snapshot.seats[0].boat.speed = place.boat.speed
        snapshot.seats[0].boat.boomSide = place.boat.boomSide
        snapshot.seats[0].heldInput = place.heldInput
        let line = race.course.startLine
        let away = line.committee.position + (line.committee.position - line.pin.position).normalized * 50
            - race.course.upwind * 50
        for ghost in snapshot.seats.indices.dropFirst() {
            var boat = snapshot.seats[ghost].boat
            boat.position = away
            boat.speed = 0
            boat.rudder = 0
            boat.desiredRudder = 0
            boat.autohelm = nil
            boat.status = .dsq
            snapshot.seats[ghost].boat = boat
            snapshot.seats[ghost].heldInput = .neutral
        }
        try race.importSnapshot(snapshot)
        return race.exportSnapshot()
    }

    /// A race where her trial begins (`origin`): a new race on the setup, that world imported.
    public func race() throws -> Race {
        let race = try Race(setup: setup, files: files, mode: .authoritative(windSeed: windSeed))
        try race.importSnapshot(origin)
        _ = race.drainEvents()
        return race
    }

    /// The last tick she may sail to: the race's own time limit closes it first.
    public static let capTicks = BotMatrix.defaultCapSecondsAfterGun * Race.tickRate

    /// Sails `sailor`, a bot, from the start to the close, the ledger watching every tick: reading `tunables` in place
    /// of the bundled file's if given (#583 stage 2).
    public func sail(_ sailor: TimeTrialSailor, tunables: BotTunables? = nil) throws -> TimeTrialRun {
        guard let bot = sailor.driver(raceSeed: setup.raceSeed) else {
            preconditionFailure("the oracle sails through `Oracle`, not a driver")
        }
        var driver = (tunables.map(bot.tuned) ?? bot).takingOver()
        let race = try race()
        var ledger = LapLedger(course: self)
        while !race.isOver && race.tick < Self.capTicks {
            let before = race.boats[0]
            driver.drive(race)
            race.step()
            _ = race.drainEvents()
            ledger.record(race, before: before)
        }
        return TimeTrialRun(sailor: sailor, race: race, ledger: ledger)
    }

    /// Re-sails `inputs` from the start to the close, the ledger watching: the oracle's lap.
    public func replay(_ inputs: [Oracle.Input]) throws -> TimeTrialRun {
        let race = try race()
        var ledger = LapLedger(course: self)
        var next = 0
        while !race.isOver && race.tick < Self.capTicks {
            while next < inputs.count && inputs[next].tick <= race.tick + 1 {
                if let held = inputs[next].held { race.apply(held, seat: 0, atTick: inputs[next].tick) }
                if let tap = inputs[next].tap { race.tap(tap, seat: 0, atTick: inputs[next].tick) }
                next += 1
            }
            let before = race.boats[0]
            race.step()
            _ = race.drainEvents()
            ledger.record(race, before: before)
        }
        return TimeTrialRun(sailor: .oracle, race: race, ledger: ledger)
    }

    // MARK: - Geometry the oracle and the ledger share

    /// The speeds she can hold at each true wind angle in `tws` (`SteadyPolar`), worked out once a wind strength.
    func steady(tws: Double) -> SteadyPolar {
        let key = Int((tws * 20).rounded())
        if let known = steadyPolars[key] { return known }
        let polar = SteadyPolar(boatClass: boatClass, tws: Double(key) / 20)
        steadyPolars[key] = polar
        return polar
    }

    private var steadyPolars: [Int: SteadyPolar] = [:]

    /// The leg's direction of progress at `position` (#267's ladder): up or down the course axis on a beat or a run, the
    /// straight line to the target on a reach and on the finish leg's reach, if any.
    func progressDirection(legIndex: Int, at position: Vec2) -> Vec2 {
        let target = legTarget(legIndex)
        if isReach[legIndex] { return (target - position).normalized }
        return (target - position).dot(course.upwind) >= 0 ? course.upwind : -course.upwind
    }

    /// Where leg `index` goes: its mark, its gate's midpoint, or the middle of the finish line.
    func legTarget(_ index: Int) -> Vec2 {
        let leg = course.legs[min(index, course.legs.count - 1)]
        guard case .round = leg else { return course.finishLine.centre }
        return course.targetPosition(for: leg)
    }

    /// Each leg a reach by the ladder's rule (`Race.ladderLegs`): more across the axis than along it.
    lazy var isReach: [Bool] = {
        var from = course.startLine.centre
        return course.legs.indices.map { k in
            let to = legTarget(k)
            let run = to - from
            from = to
            return abs(run.dot(course.upwind.rightPerp)) > abs(run.dot(course.upwind))
        }
    }()

    /// The marks of leg `index` (none for the finish).
    func marks(ofLeg index: Int) -> [CourseLayout.Mark] {
        guard course.legs.indices.contains(index), case .round = course.legs[index] else { return [] }
        return course.marksOfLeg(course.legs[index])
    }

    /// Metres from `position` to the nearest mark of leg `index`; infinite for the finish.
    func distanceToMark(ofLeg index: Int, from position: Vec2) -> Double {
        marks(ofLeg: index).map { ($0.position - position).length }.min() ?? .infinity
    }

    /// The best speed made good along `direction` the polar gives in `wind` (any heading), plus the current's share of
    /// it: the rate the ledger measures her progress against, metres a second.
    func bestProgressRate(along direction: Vec2, windDirection: Double, windSpeed: Double, current: Vec2) -> Double {
        let polar = steady(tws: windSpeed)
        var best = 0.0
        for degree in stride(from: 0, to: 360, by: 1) {
            let heading = deg2rad(Double(degree))
            let rate = polar.speed(twa: abs(wrapAngle(windDirection - heading))) * Vec2.heading(heading).dot(direction)
            best = max(best, rate)
        }
        return best + current.dot(direction)
    }

    /// Whether a boat at `position` heading for leg `index`'s target on the side `boomSide` gives is past its layline
    /// (#583): on a beat the target lies further off the wind than her close-hauled course, on a run hotter than her
    /// downwind groove, by more than `overstandMargin`. Never on a reach.
    func isOverstood(legIndex: Int, position: Vec2, boomSide: BoomSide, windDirection: Double, windSpeed: Double) -> Bool {
        guard course.legs.indices.contains(legIndex), !isReach[legIndex] else { return false }
        let toTarget = legTarget(legIndex) - position
        guard toTarget.length > 2 * boatClass.hull.length else { return false }
        let angle = boomSide.sailingAngle(relativeWind: wrapAngle(windDirection - toTarget.bearing))
        guard angle > 0 else { return false }
        let polar = steady(tws: windSpeed)
        if toTarget.dot(course.upwind) >= 0 { return angle > polar.up.twa + Self.overstandMargin }
        return angle < polar.down.twa - Self.overstandMargin
    }

    /// How far past the groove the target must lie for her to have overstood it.
    static let overstandMargin = deg2rad(3)

    /// Within this of a leg's mark, centre to centre, she is rounding it: the course's rule 18 zone.
    var roundingRadius: Double { course.zoneRadius }
}

/// One sailor's lap on a seed (#583): her finish, and her ledger.
public struct TimeTrialRun {
    public let sailor: TimeTrialSailor
    /// Seconds from the gun to her finish; nil if she didn't finish by the close.
    public let finishSeconds: Double?
    /// Seconds she sailed: to her finish, or to the close.
    public let sailedSeconds: Double
    public let ledger: LapLedger
    /// The race at the close, for its digest.
    public let digest: UInt64

    init(sailor: TimeTrialSailor, race: Race, ledger: LapLedger) {
        self.sailor = sailor
        finishSeconds = race.boats[0].finishTime
        sailedSeconds = ledger.totalSeconds
        self.ledger = ledger
        digest = race.digest()
    }
}

/// Where a lap's time goes (#583), tick by tick, as `RaceObserver` watches a race (#471). Every tick she sails is in
/// exactly one segment (the start, a leg's sailing, a mark's rounding) and its seconds split into what she would have
/// needed at the polar's best progress in the wind she had (`ideal`) and the rest, put down to one cause. So the
/// segments, and the causes with `ideal`, each sum to her time, and two boats' columns differ by their time's gap.
public struct LapLedger {
    /// What a tick's seconds are put down to.
    public enum Cause: String, CaseIterable, Codable, Sendable {
        /// From the gun until she crosses the line: all of it.
        case start
        /// Inside a mark's rounding window: all of it.
        case rounding
        /// Inside a tack or a gybe, from the turn's start until she is back to speed: what she lost on the polar's best.
        case manoeuvre
        /// Sailing past the layline: what she lost on the polar's best.
        case overstood
        /// Anything else she lost on the polar's best: off the groove's angle, below its speed, off the plane.
        case offPolar
        /// The seconds the polar's best progress in her own wind needed: what her wind cost or gave against another's
        /// (lulls, puffs and shifts she sailed into or missed).
        case wind
        /// Metres only (#584 stage 2, `metresByCause`): the polar's best progress another boat's shadow and backwind took
        /// off hers, ...
        case air
        /// ... and what she lost in a tack or gybe or off the polar with another boat within `forcedLengths`: the moves
        /// the fleet made her make (a duck, a tack to clear).
        case forced

        /// The causes a lap's seconds are put down to: all but the fleet's, which a time trial, alone, never has.
        public static let lap: [Cause] = [.start, .rounding, .manoeuvre, .overstood, .offPolar, .wind]
    }

    /// Where on the course a tick is.
    public enum Segment: Hashable, Codable, Sendable {
        case start
        /// Sailing leg n (0-based), outside its rounding window.
        case leg(Int)
        /// Rounding leg n's mark.
        case rounding(Int)
    }

    private struct Tick {
        var segment: Segment
        var cause: Cause
        /// Seconds lost against the polar's best; the whole tick for the start and a rounding.
        var lost: Double
        /// Seconds the polar's best progress needed.
        var ideal: Double
        /// Heading change this tick, radians a second.
        var turnRate: Double
        /// With `measuresMetres`: metres up the course axis the polar's best progress in clean air made this tick, what
        /// another boat's shadow took off it, and what she fell short of the rest (negative where she made more); the
        /// first less the others is her progress.
        var idealMetres = 0.0
        var airMetres = 0.0
        var lostMetres = 0.0
        /// Another boat (racing, or not yet started) within `forcedLengths` of her this tick.
        var crowded = false
    }

    private let course: TimeTrialCourse
    private var ticks: [Tick] = []
    /// Whether it also measures each tick in metres up the course axis (#584, the start trial's first minute): the
    /// first beat's ladder, what `StartGeometry.made` counts.
    private let measuresMetres: Bool
    /// Her seat in the race.
    private let seat: Int
    /// The leg whose rounding window she is in.
    private var roundingLeg: Int?
    /// After a boom crossing, the manoeuvre lasts until she is back to speed or this tick.
    private var manoeuvreUntil: Int?
    private var crossingTick = 0

    /// A turn starts on the first of the ticks before its boom crossing that turn faster than this.
    static let turningRate = deg2rad(4)
    /// The longest a turn reaches back before its crossing, and on after it, seconds.
    static let turnReach = 8.0
    static let recoveryCap = 15.0
    /// Back to speed: this share of her target at the angle she sails, turning slower than `turningRate`.
    static let recoveredShare = 0.95

    /// Hull lengths, centre to centre, inside which another boat makes a tack, a gybe or a loss off the polar a forced
    /// move (`Cause.forced`): the suite's crossing distance (`RaceTally.crossingLengths`).
    static let forcedLengths = RaceTally.crossingLengths

    init(course: TimeTrialCourse, measuresMetres: Bool = false, seat: Int = 0) {
        self.course = course
        self.measuresMetres = measuresMetres
        self.seat = seat
    }

    /// `tick` with its metres (`measuresMetres`): the polar's best progress up the axis this tick in the wind and current
    /// she had, clean of other boats' shadow, the shadow's share of it, and her own progress.
    private func metred(_ tick: Tick, race: Race, before: Boat) -> Tick {
        guard measuresMetres else { return tick }
        let boat = race.boats[seat]
        let dt = 1 / Double(Race.tickRate)
        let upwind = course.course.upwind
        let flow = boat.current.dot(upwind)
        let clean = course.bestProgressRate(along: upwind, windDirection: boat.sailingWind.direction,
                                            windSpeed: boat.sailingWind.speed, current: boat.current)
        // In her shadow: the wind's speed for a class whose shadow slows the wind, her own for one whose shadow slows her.
        let shaded = course.boatClass.windShadow.isSpeedLoss
            ? (clean - flow) * boat.shadow + flow
            : course.bestProgressRate(along: upwind, windDirection: boat.sailingWind.direction,
                                      windSpeed: boat.polarWindSpeed(in: course.boatClass), current: boat.current)
        var tick = tick
        tick.idealMetres = max(0, clean) * dt
        tick.airMetres = tick.idealMetres - max(0, shaded) * dt
        tick.lostMetres = max(0, shaded) * dt - (boat.position - before.position).dot(upwind)
        let near = Self.forcedLengths * course.boatClass.hull.length
        tick.crowded = race.boats.indices.contains { other in
            other != seat && [.racing, .prestart, .ocs].contains(race.boats[other].status)
                && (race.boats[other].position - boat.position).length < near
        }
        return tick
    }

    /// Records the tick the race just stepped: `before` is her boat before it.
    mutating func record(_ race: Race, before: Boat) {
        let boat = race.boats[seat]
        let dt = 1 / Double(Race.tickRate)
        guard before.status != .finished else { return }
        let turnRate = wrapAngle(boat.heading - before.heading) / dt
        if before.status == .prestart || before.status == .ocs {
            ticks.append(metred(Tick(segment: .start, cause: .start, lost: dt, ideal: 0, turnRate: turnRate), race: race,
                                before: before))
            return
        }
        let leg = boat.status == .finished ? before.legIndex : boat.legIndex
        if let rounding = roundingLeg, leg > rounding,
           course.distanceToMark(ofLeg: rounding, from: boat.position) >= course.roundingRadius {
            roundingLeg = nil
        }
        if roundingLeg == nil, course.distanceToMark(ofLeg: leg, from: boat.position) < course.roundingRadius {
            roundingLeg = leg
        }
        if let rounding = roundingLeg {
            ticks.append(metred(Tick(segment: .rounding(rounding), cause: .rounding, lost: dt, ideal: 0, turnRate: turnRate),
                                race: race, before: before))
            return
        }
        let progress = race.ladderDistanceToFinish(of: before) - race.ladderDistanceToFinish(of: boat)
        let wind = boat.sailingWind
        let rate = course.bestProgressRate(along: course.progressDirection(legIndex: before.legIndex, at: before.position),
                                           windDirection: wind.direction, windSpeed: boat.polarWindSpeed(in: course.boatClass),
                                           current: boat.current)
        let ideal = rate > 0.05 ? max(0, progress) / rate : dt
        var cause = Cause.offPolar
        if before.boomSide != boat.boomSide {
            crossingTick = race.tick
            manoeuvreUntil = race.tick + Int(Self.recoveryCap * Double(Race.tickRate))
            // The turn began on the first of the ticks before the crossing that were turning.
            var k = ticks.count - 1
            let reach = Int(Self.turnReach * Double(Race.tickRate))
            while k >= 0, ticks.count - k <= reach, abs(ticks[k].turnRate) > Self.turningRate, case .leg = ticks[k].segment,
                  ticks[k].cause != .manoeuvre {
                ticks[k].cause = .manoeuvre
                k -= 1
            }
        }
        if let until = manoeuvreUntil {
            let target = BoatDynamics.polarTarget(relativeWind: boat.relativeWind, boomSide: boat.boomSide,
                                                  tws: boat.polarWindSpeed(in: course.boatClass), isPlaning: boat.isPlaning,
                                                  spinnaker: boat.spinnaker, boatClass: course.boatClass)
            let recovered = boat.speed >= Self.recoveredShare * target && abs(turnRate) < Self.turningRate
                && race.tick > crossingTick
            if race.tick > until || recovered {
                manoeuvreUntil = nil
            } else {
                cause = .manoeuvre
            }
        }
        if cause == .offPolar,
           course.isOverstood(legIndex: before.legIndex, position: boat.position, boomSide: boat.boomSide,
                              windDirection: wind.direction, windSpeed: boat.polarWindSpeed(in: course.boatClass)) {
            cause = .overstood
        }
        ticks.append(metred(Tick(segment: .leg(leg), cause: cause, lost: dt - ideal, ideal: ideal, turnRate: turnRate),
                            race: race, before: before))
    }

    /// Seconds recorded: to her finish, or to the close.
    public var totalSeconds: Double { Double(ticks.count) / Double(Race.tickRate) }

    /// Seconds by cause; `.wind` is the ideal seconds. They sum to `totalSeconds`.
    public var byCause: [Cause: Double] {
        var sums = Dictionary(uniqueKeysWithValues: Cause.allCases.map { ($0, 0.0) })
        for tick in ticks {
            sums[tick.cause, default: 0] += tick.lost
            sums[.wind, default: 0] += tick.ideal
        }
        return sums
    }

    /// With `measuresMetres`: metres short of the polar's best progress up the axis by cause, `.wind` the best progress
    /// in clean air itself, `.air` what other boats' shadow took off it; a loss in a tack or gybe or off the polar with
    /// another boat close is `.forced`. The best less the rest is her progress up the axis, to rounding.
    public var metresByCause: [Cause: Double] {
        var sums = Dictionary(uniqueKeysWithValues: Cause.allCases.map { ($0, 0.0) })
        for tick in ticks {
            let cause: Cause = tick.crowded && (tick.cause == .manoeuvre || tick.cause == .offPolar) ? .forced : tick.cause
            sums[cause, default: 0] += tick.lostMetres
            sums[.air, default: 0] += tick.airMetres
            sums[.wind, default: 0] += tick.idealMetres
        }
        return sums
    }

    /// Seconds by segment. They sum to `totalSeconds`.
    public var bySegment: [Segment: Double] {
        var sums: [Segment: Double] = [:]
        for tick in ticks { sums[tick.segment, default: 0] += tick.lost + tick.ideal }
        return sums
    }

    /// Seconds in tacks and gybes' windows, and how many.
    public var manoeuvres: Int {
        var count = 0
        var inside = false
        for tick in ticks {
            if tick.cause == .manoeuvre && !inside { count += 1 }
            inside = tick.cause == .manoeuvre
        }
        return count
    }
}
