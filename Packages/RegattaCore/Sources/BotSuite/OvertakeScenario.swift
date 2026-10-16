import Foundation
import RegattaBots
import RegattaCore

// `regatta-botsuite --scenario overtake` (#530): a scripted boat sails the player's part, slow on the first beat or
// holding below the line before the gun, and live bots are placed astern of her on her tack. The report says how the
// bots get past her: contacts, the rule calls between them, how close they came, how far back they chose to pass and
// how long they took to clear ahead.
//
// The scenario is a harness, as the pack (`PackScenario`, #526) is. It changes no rule and no bot, and adds nothing to
// the core: the boats are put in place with `Race.exportSnapshot()` and `importSnapshot(_:)`, and the scripted boat is
// sailed through the race's input API (`Race.apply`), as a player's device sends hers. Only she is fixed; the bots
// react. A run without `--scenario overtake` never reaches this file.

/// Before the gun or on the first beat.
public enum OvertakePhase: String, CaseIterable, Codable, Hashable, Sendable {
    /// Placed `OvertakeScenario.prestartLead` before the gun just below the line's middle, eased, holding there.
    case prestart
    /// Placed a second after the gun about a third up the beat.
    case beat
}

/// The scripted boat's tack.
public enum OvertakeTack: String, CaseIterable, Codable, Hashable, Sendable {
    case port, starboard

    var tack: Tack { self == .port ? .port : .starboard }
}

/// One layout of the scenario: what a group of races of the report shares.
public struct OvertakeLayout: Codable, Hashable, Sendable {
    public var phase: OvertakePhase
    public var tack: OvertakeTack
    /// Sailed in a venue with a current (`saltings-reach@1`), or without (`dev-venue@7`).
    public var current: Bool
    /// The first bot's distance astern of her, centre to centre along her heading, hull lengths. Each further bot is
    /// `OvertakeScenario.slotSpacing` lengths further back.
    public var astern: Double
    /// The bots' offset across her heading, hull lengths: positive to windward.
    public var across: Double
    /// The race's fleet: her and `fleetSize − 1` bots.
    public var fleetSize: Int
    /// The control (`--overtake-control`): she is placed `OvertakeScenario.controlAbeam` lengths across the course from
    /// where she would be (`OvertakeScenario.controlOffset`), so the bots have nobody ahead, and the measures but
    /// contacts and calls are read against a phantom of her sailing where she would have been. What fires here is false:
    /// a wander, a tactical tack.
    public var control: Bool

    public init(phase: OvertakePhase, tack: OvertakeTack, current: Bool, astern: Double, across: Double, fleetSize: Int = 2,
                control: Bool = false) {
        self.phase = phase
        self.tack = tack
        self.current = current
        self.astern = astern
        self.across = across
        self.fleetSize = fleetSize
        self.control = control
    }

    public var venue: String { current ? PackScenario.currentVenue : PackScenario.calmVenue }
}

/// One race of the scenario: a layout, a seed, a tier mix.
public struct OvertakeCell: Hashable, Sendable {
    public var seed: UInt64
    public var layout: OvertakeLayout
    public var tierMix: TierMix
    public var autohelmOff: Bool?
    public var boatClass: String?

    public init(seed: UInt64, layout: OvertakeLayout, tierMix: TierMix, autohelmOff: Bool? = nil, boatClass: String? = nil) {
        self.seed = seed
        self.layout = layout
        self.tierMix = tierMix
        self.autohelmOff = autohelmOff
        self.boatClass = boatClass
    }

    /// The race the cell sails: one lap, the beat its first leg.
    var raceCell: BotRaceCell {
        BotRaceCell(seed: seed, venue: layout.venue, conditions: PackScenario.conditions, tideStateDegrees: 0,
                    fleetSize: layout.fleetSize, tierMix: tierMix, profileMix: .live, laps: 1,
                    capSecondsAfterGun: BotMatrix.defaultCapSecondsAfterGun, autohelmOff: autohelmOff, boatClass: boatClass)
    }
}

/// How a bot's encounter with her ended.
public enum OvertakeOutcome: String, CaseIterable, Codable, Hashable, Sendable {
    /// Clear ahead of her, on her windward side at that tick.
    case passedWindward
    /// Clear ahead of her, on her leeward side.
    case passedLeeward
    /// Tacked before she was clear ahead: never a pass (the course's tactics may have called it, not her).
    case tackedAway
    /// Neither, when the run ended.
    case stillAstern
}

/// Where a bot chose to pass: the side of her she turned to, or a tack.
public enum OvertakeSide: String, CaseIterable, Codable, Hashable, Sendable {
    case windward, leeward, tack
}

/// What the scenario saw of one bot against the scripted boat.
public struct OvertakeBotResult: Codable, Hashable, Sendable {
    public var seat: Int
    public var tier: String
    /// Her contacts with the scripted boat.
    public var contacts: Int
    /// Of `contacts`, those made while their incident was still open (the pair touched again before separating): the
    /// umpire judges an incident once, so these are never called. A stalled boat is often bumped twice.
    public var repeatContacts: Int = 0
    /// Rule calls on the bot with the scripted boat the victim, by rule (`RacingRule.rawValue`).
    public var callsByRule: [String: Int]
    /// Rule calls on the scripted boat with this bot the victim.
    public var callsOnHer: Int
    /// The closest she came to the scripted boat, centre to centre, hull lengths.
    public var closestApproach: Double
    /// The first tick of a sustained offset off her course (`OvertakeProbe`), as hull lengths astern of her along her
    /// heading, and its side; nil if none.
    public var passChosenLengths: Double?
    public var passChosenSide: OvertakeSide?
    /// Seconds from the placement to the first tick the scripted boat was clear astern of her; nil if never.
    public var clearAheadSeconds: Double?
    public var outcome: OvertakeOutcome
    /// Seconds with her wind under 0.85 of the free wind (`PackScenario.dirtyAir`).
    public var dirtySeconds: Double

    public var calls: Int { callsByRule.values.reduce(0, +) }
}

/// One race of the scenario, reduced.
public struct OvertakeRaceResult: Codable, Hashable, Sendable {
    public var seed: UInt64
    public var layout: OvertakeLayout
    public var tierMix: TierMix
    public var tideStateAtGun: Double?
    /// Ticks sailed after the placement.
    public var ticks: Int
    public var bots: [OvertakeBotResult]
    /// Contacts and rule calls between two bots: never in the pair measures.
    public var botBotContacts: Int
    public var botBotCalls: Int
    /// The scripted boat's speed share (`OvertakeProbe.Share`) after the settle, and the share of those ticks eased.
    public var herShareMean: Double?
    public var herShareMin: Double?
    public var herShareMax: Double?
    public var herInBandShare: Double?
    public var herEasedShare: Double?
    /// She was over the line at the gun (prestart phase only).
    public var herOCS: Bool
    /// Penalty turns called on her that the harness waived (`OvertakeScenario.waivePenalty`): she never sails one, and
    /// is never disqualified for it, so she stays a racing boat with her rights. The calls themselves are counted in
    /// each bot's `callsOnHer`.
    public var herPenaltiesWaived: Int = 0
    /// She was disqualified (should never be: her penalties are waived).
    public var herDSQ: Bool = false
}

/// A prestart race whose boats don't all start inside the race area: left out of the report's rows.
struct OvertakeUnplaced: Error {}

/// A race left out (`OvertakeUnplaced`): its cell.
public struct OvertakeUnplacedRace: Codable, Hashable, Sendable {
    public var seed: UInt64
    public var layout: OvertakeLayout
    public var tierMix: TierMix
}

/// The scenario: placement, the scripted helm, the sail.
public enum OvertakeScenario {
    public static let defaultAstern = [2.0, 4.0, 6.0]
    public static let defaultAcross = [-1.0, 0.0, 1.0]
    public static let defaultFleetSize = 2
    public static let defaultSeeds = 16
    /// Each bot after the first is this many hull lengths further astern than the one before.
    public static let slotSpacing = 2.0
    /// The control's scripted boat, this many hull lengths across the course from her place. Owner Q6 proposed 40
    /// abeam to leeward; that is below the line on a 360 m beat, and 40 straight across leaves the race area.
    public static let controlAbeam = 30.0
    /// The scripted boat's target speed share of the polar on the beat, and the ease's hysteresis about it: eased above
    /// `easeAbove`, sheeted in below `sheetBelow` (owner Q2, proposed).
    public static let targetShare = 0.65
    public static let easeAbove = 0.70
    public static let sheetBelow = 0.60
    /// Seconds after which her share is judged, from the placement on the beat, from the gun before it.
    public static let settleSeconds = 5
    /// On the beat she is placed this share of the way up it: low, so a bot that has passed her is not yet at the
    /// windward mark when the run ends (the brief's third up the beat is too high on a 360 m beat).
    public static let beatStart = 1.0 / 6
    /// The prestart phase places the boats this long before the gun.
    public static let prestartLead = 30
    /// The beat phase runs this long after the placement; the prestart phase to this long after the gun.
    public static let beatSeconds = 90
    public static let afterGunSeconds = 60
    /// Before the gun she holds, stalled, with her centre about this many hull lengths below the line's middle along
    /// the course's axis (placed up-current of it), and sails up if set more than `holdLengths` below the line, bow to
    /// line. Owner Q1 proposed she creep up eased from where 30 s of the creep starts, but a fleet of two has a 42 m line
    /// and the race area ends one line length below it: a bot 6 lengths astern of her would start outside it.
    public static let prestartDepth = 1.5
    public static let holdLengths = 2.0
    /// The sailing angle she luffs to while she holds, degrees: inside the no-go zone.
    public static let luffDegrees = 15.0
    /// A sustained offset: the bot's heading this far off hers for this long, while clear astern (owner Q3, proposed).
    public static let offsetDegrees = 10.0
    public static let offsetSeconds = 2.0
    /// A penalty called on her is waived once every other boat's centre is this many hull lengths from hers (clear of
    /// the umpire's separation, so no incident with her is still open), or, at the latest, this many ticks before her
    /// first deadline.
    public static let waiveClearLengths = 4.0
    public static let waiveMarginTicks = 2
    /// No boat's straight track comes nearer the race area's edge than this, metres (`BotRaceHarness.edgeMargin`).
    public static let edgeMargin = BotRaceHarness.edgeMargin

    // MARK: Cells

    /// The layouts a run sails, the control's after the scenario's when asked.
    public static func layouts(_ options: BotSuiteOptions) -> [OvertakeLayout] {
        let phases = options.overtakePhases.isEmpty ? OvertakePhase.allCases : options.overtakePhases
        let tacks = options.overtakeTacks.isEmpty ? OvertakeTack.allCases : options.overtakeTacks
        let currents: [Bool] = switch options.overtakeCurrent ?? .both {
        case .with: [true]
        case .without: [false]
        case .both: [true, false]
        }
        let asterns = options.overtakeAstern.isEmpty ? defaultAstern : options.overtakeAstern
        let sizes = options.fleetSizes.isEmpty ? [defaultFleetSize] : options.fleetSizes
        let controls = options.overtakeControl ? [false, true] : [false]
        return controls.flatMap { control in
            phases.flatMap { phase in
                tacks.flatMap { tack in
                    currents.flatMap { current in
                        sizes.flatMap { size in
                            asterns.flatMap { astern in
                                defaultAcross.map {
                                    OvertakeLayout(phase: phase, tack: tack, current: current, astern: astern, across: $0,
                                                   fleetSize: size, control: control)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// The races a run sails: every layout × tier mix × seed, seeds outermost.
    public static func cells(_ options: BotSuiteOptions) throws -> [OvertakeCell] {
        let tiers = options.tierMixes.isEmpty ? [TierMix.national] : options.tierMixes
        let seeds = (1...(options.seedCount ?? defaultSeeds)).map(UInt64.init)
        if let boatClass = options.boatClass { _ = try BotRaceHarness.bundledClass(boatClass) }
        let layouts = layouts(options)
        return seeds.flatMap { seed in
            tiers.flatMap { tier in
                layouts.map {
                    OvertakeCell(seed: seed, layout: $0, tierMix: tier, autohelmOff: options.autohelmOff == true ? true : nil,
                                 boatClass: options.boatClass)
                }
            }
        }
    }

    public static func run(_ options: BotSuiteOptions) throws -> OvertakeReport {
        let cells = try cells(options)
        let sailed = try BotSuite.inParallel(cells, jobs: options.jobs ?? BotSuite.defaultJobs) { cell -> OvertakeRaceResult? in
            do {
                return try sail(cell)
            } catch is OvertakeUnplaced {
                return nil
            }
        }
        let unplaced = zip(cells, sailed).filter { $0.1 == nil }.map {
            OvertakeUnplacedRace(seed: $0.0.seed, layout: $0.0.layout, tierMix: $0.0.tierMix)
        }
        return OvertakeReport(races: sailed.compactMap { $0 }, unplaced: unplaced)
    }

    // MARK: Placement

    /// One boat's place.
    struct Pose: Hashable {
        var seat: Int
        var position: Vec2
        var heading: Double
        var speed: Double
        /// Close-hauled: the polar's best upwind angle at the placement's wind.
        var twa: Double
    }

    /// Her heading's frame at the placement: forward, and the unit to windward across it.
    struct Frame {
        var forward: Vec2
        var windward: Vec2
    }

    /// The poses for `cell` in `race`, which has been stepped to the placement's tick and not placed: hers (seat 0)
    /// first, then the bots'.
    static func poses(_ cell: OvertakeCell, in race: Race) throws -> [Pose] {
        let layout = cell.layout
        let course = race.course
        let length = race.boatClass.hull.length
        let line = course.startLine
        let wind = race.groundWind(at: line.centre + course.upwind * (layout.phase == .beat ? course.beat * beatStart : 0))
        let up = race.boatClass.polar.bestUpwind(tws: wind.speed)
        // Starboard tack: the wind over her starboard side, the boom to port, heading left of the wind.
        let heading = layout.tack == .starboard ? wind.direction - up.twa : wind.direction + up.twa
        let frame = frame(heading: heading, tack: layout.tack.tack)
        let herSpeed: Double
        var her: Vec2
        let botSpeed: Double
        switch layout.phase {
        case .beat:
            herSpeed = targetShare * up.speed
            botSpeed = up.speed
            // `beatStart` of the way up the beat, across the course on the side she sails away from: her track
            // crosses the axis half way along it.
            let track = herSpeed * Double(beatSeconds)
            let anchor = line.centre + course.upwind * (course.beat * beatStart)
            her = anchor - course.right * (frame.forward.dot(course.right) * track / 2)
        case .prestart:
            // Her spot (`prestartSpot`), less what the current there sets her in the lead: she stalls (the helm), so
            // the current carries her onto it by the gun. Without that a current takes her past the line's end, and
            // she never starts. The bots creep at the ease's share of the polar.
            herSpeed = 0
            botSpeed = race.boatClass.ease.speedFraction * up.speed
            let spot = prestartSpot(course: course, forward: frame.forward, length: length)
            her = spot - race.current.sample(spot, tick: race.tick) * Double(prestartLead)
        }
        // The bots astern of where she is, in successive slots; in the control she is then moved across the course.
        let reference = her
        if layout.control {
            let offset = controlOffset(frame: frame, course: course, length: length)
            switch layout.phase {
            case .beat: her = her + offset
            case .prestart:
                // Her spot moved, less the current's set there.
                let spot = prestartSpot(course: course, forward: frame.forward, length: length) + offset
                her = spot - race.current.sample(spot, tick: race.tick) * Double(prestartLead)
            }
        }
        var poses = [Pose(seat: 0, position: her, heading: heading, speed: herSpeed, twa: up.twa)]
        for seat in 1..<layout.fleetSize {
            let astern = layout.astern + slotSpacing * Double(seat - 1)
            let position = reference - frame.forward * (astern * length) + frame.windward * (layout.across * length)
            poses.append(Pose(seat: seat, position: position, heading: heading, speed: botSpeed, twa: up.twa))
        }
        // Every boat starts at least a hull length inside the race area. On the beat her straight track over the run, at
        // her share, and the bots', at the polar's upwind speed, ends `edgeMargin` inside it too. (Before the gun the
        // bots start below the line's middle and sail a start: where they go after it is theirs.)
        for pose in poses {
            let speed = pose.seat == 0 ? targetShare * up.speed : up.speed
            let end = pose.position + frame.forward * (speed * Double(beatSeconds))
            let points = layout.phase == .beat ? [(pose.position, length), (end, edgeMargin)] : [(pose.position, length)]
            for (point, margin) in points
            where course.raceArea.inset(point) < margin || !course.isInRaceArea(point) {
                // Before the gun the race area ends a line length below the line, and a current setting her up to
                // it puts her start further down: such a race is left out, and counted (`OvertakeReport.unplaced`).
                if layout.phase == .prestart { throw OvertakeUnplaced() }
                throw PackScenarioError.setup("overtake: seat \(pose.seat)'s track leaves the race area at "
                    + "\(fixed(course.raceArea.inset(point), 0)) m in (seed \(cell.seed), \(layout.venue), "
                    + "\(layout.phase.rawValue) \(layout.tack.rawValue), beat \(fixed(course.beat, 0)) m)")
            }
            // Her track ends short of the windward mark's zone. (A bot at full speed reaches it in about 90 s from
            // anywhere low on a short beat; by then she is past her.)
            if layout.phase == .beat, pose.seat == 0, (end - line.centre).dot(course.upwind) > course.beat - course.zoneRadius {
                throw PackScenarioError.setup("overtake: seat \(pose.seat)'s track reaches the windward mark's zone "
                    + "(\(fixed((end - line.centre).dot(course.upwind), 0)) m up a \(fixed(course.beat, 0)) m beat; seed "
                    + "\(cell.seed), \(layout.venue), \(layout.phase.rawValue))")
            }
        }
        return poses
    }

    /// Where she holds before the gun: `prestartDepth` hull lengths below the line, a quarter of its length from its
    /// middle towards the end she sails away from, so she has room to sail up to it on her tack against a current.
    static func prestartSpot(course: CourseLayout, forward: Vec2, length: Double) -> Vec2 {
        let line = course.startLine
        let away = forward.dot(course.right) < 0 ? 1.0 : -1.0
        return line.centre - course.upwind * (prestartDepth * length) + course.right * (away * line.length / 4)
    }

    /// Where the control moves her: `controlAbeam` hull lengths straight across the course, to the side the bots sail
    /// away from, so she stays above the line and inside the race area and is never ahead of them.
    static func controlOffset(frame: Frame, course: CourseLayout, length: Double) -> Vec2 {
        course.right * ((frame.forward.dot(course.right) < 0 ? 1 : -1) * controlAbeam * length)
    }

    static func frame(heading: Double, tack: Tack) -> Frame {
        let forward = Vec2.heading(heading)
        // The wind over her starboard side on starboard tack: windward is to her right.
        return Frame(forward: forward, windward: tack == .starboard ? forward.rightPerp : -forward.rightPerp)
    }

    /// Puts `poses` into `race`: close-hauled on the layout's tack, racing the first leg after the gun or in the
    /// sequence before it, clean air.
    static func place(_ poses: [Pose], phase: OvertakePhase, tack: OvertakeTack, in race: Race) throws {
        var snapshot = race.exportSnapshot()
        for pose in poses {
            snapshot.seats[pose.seat].boat.position = pose.position
            snapshot.seats[pose.seat].boat.heading = pose.heading
            snapshot.seats[pose.seat].boat.speed = pose.speed
            snapshot.seats[pose.seat].boat.boomSide = tack == .starboard ? .port : .starboard
            snapshot.seats[pose.seat].boat.status = phase == .beat ? .racing : .prestart
            snapshot.seats[pose.seat].boat.legIndex = 0
            snapshot.seats[pose.seat].boat.roundingStage = 0
            snapshot.seats[pose.seat].boat.autohelm = Autohelm(target: .angle(pose.twa))
            snapshot.seats[pose.seat].boat.rudder = 0
            snapshot.seats[pose.seat].boat.isTacking = false
            snapshot.seats[pose.seat].heldInput = .neutral
            // Nothing from before the placement: the boats sail the sequence (and on the beat past the gun) unsteered
            // from their default spots, and touch in most races; a penalty owed then would have a bot turning circles
            // and her disqualified, a ghost, in the run (#530 fix round 1).
            snapshot.seats[pose.seat].boat.penaltyTurnsOwed = 0
            snapshot.seats[pose.seat].boat.penaltyProgress = 0
            snapshot.seats[pose.seat].boat.penaltyClockTick = nil
            snapshot.seats[pose.seat].boat.queuedPenaltyCallTicks = []
        }
        // The umpire's memory of those touches goes too: no incident is open, and no pair touches or overlaps until the
        // race says so from the placed boats.
        snapshot.incidents = IncidentIndex()
        snapshot.touchingBoats = []
        snapshot.touchingObstacles = []
        snapshot.touchingEdges = []
        snapshot.overlaps = []
        snapshot.ribbonPoints = []
        snapshot.emissionLevels = []
        snapshot.headers = []
        snapshot.backwind = BackwindSails()
        try race.importSnapshot(snapshot)
        _ = race.drainEvents()
    }

    /// The race of `cell`, stepped to the placement (a second past the gun for the beat, `prestartLead` before it for
    /// the prestart) and placed.
    static func placedRace(_ cell: OvertakeCell) throws -> (race: Race, setup: RaceSetup, poses: [Pose]) {
        let raceCell = cell.raceCell
        let setup = try BotRaceHarness.raceSetup(for: raceCell)
        let race = try Race(setup: setup, files: BotRaceHarness.raceFiles(for: raceCell, setup: setup),
                            mode: .authoritative(windSeed: BotRaceHarness.windSeed(for: cell.seed)))
        let ticks = cell.layout.phase == .beat
            ? setup.startSequenceTicks + Race.tickRate
            : setup.startSequenceTicks - prestartLead * Race.tickRate
        for _ in 0..<ticks { race.step() }
        let poses = try poses(cell, in: race)
        try place(poses, phase: cell.layout.phase, tack: cell.layout.tack, in: race)
        return (race, setup, poses)
    }

    // MARK: Sailing

    /// Sails `cell`: the scripted boat by `ScriptedHelm`, the bots live, for `beatSeconds` after the placement on the
    /// beat, to `afterGunSeconds` after the gun before it.
    /// `observe`, for a diagnosis, sees the race after each step with that step's drained events.
    public static func sail(_ cell: OvertakeCell) throws -> OvertakeRaceResult { try sail(cell, observe: nil) }

    static func sail(_ cell: OvertakeCell, observe: ((Race, [RaceEvent]) -> Void)?) throws -> OvertakeRaceResult {
        let (race, setup, poses) = try placedRace(cell)
        // The control's measures are read against where she would have been: her own boat moved back by the
        // control's offset, a phantom the bots can't see. Contacts and calls stay the race's, with the real her.
        var plain = cell
        plain.layout.control = false
        let phantomOffset = cell.layout.control ? poses[0].position - (try Self.poses(plain, in: race))[0].position : .zero
        let tiers = setup.seats.indices.map { cell.tierMix.tier(ofSeat: $0, raceSeed: setup.raceSeed) }
        var controllers = SeatControllers([.human] + (1..<setup.seats.count).map {
            .bot(cell.tierMix.driver(seat: $0, raceSeed: setup.raceSeed).takingOver())
        })
        var helm = ScriptedHelm(angle: poses[0].twa, eased: cell.layout.phase == .prestart, line: race.course.startLine,
                                hullLength: race.boatClass.hull.length)
        let first = race.tick
        var probe = OvertakeProbe(seats: setup.seats.count, hull: race.boatClass.hull, startTick: first)
        let gunTick = first + (cell.layout.phase == .beat ? -Race.tickRate : prestartLead * Race.tickRate)
        let settleTick = (cell.layout.phase == .beat ? first : gunTick) + settleSeconds * Race.tickRate
        let endTick = cell.layout.phase == .beat ? first + beatSeconds * Race.tickRate : gunTick + afterGunSeconds * Race.tickRate
        var herOCS = false
        var waived = 0
        var herDSQ = false
        while !race.isOver && race.tick < endTick {
            let input = helm.input(for: race.boats[0], boatClass: race.boatClass, secondsToGun: Double(gunTick - race.tick) / Double(Race.tickRate))
            _ = race.apply(input, seat: 0, atTick: race.tick + 1)
            controllers.drive(race)
            race.step()
            let events = race.drainEvents()
            let repeats = Self.repeatContacts(in: race, tick: race.tick)
            if try waivePenalty(in: race) { waived += 1 }
            observe?(race, events)
            if race.boats[0].status == .ocs { herOCS = true }
            if race.boats[0].status == .dsq { herDSQ = true }
            let her = race.boats[0]
            let sample = race.tick >= settleTick && her.status == .racing
                ? OvertakeProbe.Share(share: ScriptedHelm.share(her, polar: race.boatClass.polar), eased: helm.eased) : nil
            // Before the gun she is luffed, stalled: the bots' offsets are read off the course she will sail.
            let course = race.tick < gunTick
                ? her.windDirection - (her.tack == .starboard ? 1 : -1) * helm.angle : nil
            var boats = race.boats
            boats[0].position -= phantomOffset
            probe.record(boats: boats, events: events, tick: race.tick, herShare: sample, herCourse: course,
                         repeatContacts: repeats)
        }
        let bots = (1..<setup.seats.count).map { probe.result(seat: $0, tier: tiers[$0].rawValue) }
        let shares = probe.shares.map(\.share)
        return OvertakeRaceResult(
            seed: cell.seed, layout: cell.layout, tierMix: cell.tierMix, tideStateAtGun: race.tideStateAtGun,
            ticks: race.tick - first, bots: bots, botBotContacts: probe.botBotContacts, botBotCalls: probe.botBotCalls,
            herShareMean: shares.isEmpty ? nil : shares.reduce(0, +) / Double(shares.count),
            herShareMin: shares.min(), herShareMax: shares.max(),
            herInBandShare: shares.isEmpty ? nil : share(shares.filter { (sheetBelow...easeAbove).contains($0) }.count, of: shares.count),
            herEasedShare: shares.isEmpty ? nil : share(probe.shares.filter(\.eased).count, of: shares.count),
            herOCS: herOCS, herPenaltiesWaived: waived, herDSQ: herDSQ)
    }

    /// The contacts of this tick (`race.incidents.contacts`) whose incident opened on an earlier tick: the pair touched
    /// again before separating.
    static func repeatContacts(in race: Race, tick: Int) -> [SeatPair] {
        race.incidents.contacts.reversed().prefix { $0.tick == tick }.compactMap { contact in
            guard let id = contact.incidentId, race.incidents.incidents[id].tick < contact.tick else { return nil }
            return contact.parties
        }
    }

    /// Owner (#530 c): the scripted boat is exempt from disqualification. A penalty called on her stands as a call (the
    /// probe counts it), but she never sails it, so the harness takes the owed turns off her before a deadline would
    /// disqualify her, through the race's own snapshot. Nothing else about her changes: she keeps her status, tack and
    /// rights, and the bots' views of her are as for any boat (an owed penalty is not on them; only a turn under way is,
    /// rule 21.2). An import forgets the umpire's escape tracks and rule 17 records, so it waits until no boat is near her
    /// (`waiveClearLengths`) and so no incident with her is open, or at the latest `waiveMarginTicks` before the first
    /// deadline. True when it waived one this tick.
    static func waivePenalty(in race: Race) throws -> Bool {
        let her = race.boats[0]
        guard her.penaltyTurnsOwed > 0, !race.isGhost(seat: 0) else { return false }
        let length = race.boatClass.hull.length
        let clear = race.boats.indices.dropFirst().allSatisfy {
            race.isGhost(seat: $0) || (race.boats[$0].position - her.position).length > waiveClearLengths * length
        }
        let penalty = race.rules.raceFormat.penalty
        let first = her.penaltyClockTick.map {
            $0 + RulesConfig.ticks(penalty.turn == .tackAndGybe ? penalty.complete : min(penalty.start, penalty.complete))
        }
        let queued = her.queuedPenaltyCallTicks.first.map { $0 + RulesConfig.ticks(penalty.start) }
        let deadline = [first, queued].compactMap { $0 }.min()
        guard clear || deadline.map({ race.tick >= $0 - waiveMarginTicks }) == true else { return false }
        var snapshot = race.exportSnapshot()
        snapshot.seats[0].boat.penaltyTurnsOwed = 0
        snapshot.seats[0].boat.penaltyProgress = 0
        snapshot.seats[0].boat.penaltyClockTick = nil
        snapshot.seats[0].boat.queuedPenaltyCallTicks = []
        try race.importSnapshot(snapshot)
        return true
    }
}

/// The scripted boat's helm: the player's part. She holds her close-hauled angle by hand (or, on a class whose autohelm
/// holds a centred rudder, lets it), and on the beat eases above `easeAbove` of the polar and sheets in below
/// `sheetBelow`, so she sails at about `targetShare` of it. Before the gun she holds below the line: she luffs into the
/// no-go zone and stalls, eased, and if she is set more than `holdLengths` below the line she sheets in and sails up.
struct ScriptedHelm {
    /// The sailing angle she holds, radians.
    var angle: Double
    private(set) var eased: Bool
    let line: CourseLayout.Line
    let hullLength: Double

    init(angle: Double, eased: Bool, line: CourseLayout.Line, hullLength: Double) {
        self.angle = angle
        self.eased = eased
        self.line = line
        self.hullLength = hullLength
    }

    /// Her speed over the clean-wind polar's at her wind angle (owner Q2).
    static func share(_ boat: Boat, polar: PolarTable) -> Double {
        let polarSpeed = polar.speed(twa: boat.twa, tws: boat.windSpeed)
        return polarSpeed > 0 ? boat.speed / polarSpeed : 0
    }

    /// The input for her next tick.
    /// `secondsToGun` positive before the gun.
    mutating func input(for boat: Boat, boatClass: BoatClass, secondsToGun: Double) -> BoatInput {
        let beforeGun = secondsToGun > 0
        if !beforeGun {
            let share = Self.share(boat, polar: boatClass.polar)
            if eased, share < OvertakeScenario.sheetBelow { eased = false }
            if !eased, share > OvertakeScenario.easeAbove { eased = true }
        }
        let bow = boat.position + boat.forward * (hullLength / 2)
        // Where the current carries her, stalled, by the gun: more than `holdLengths` below the line, she sheets in and
        // sails up; otherwise she luffs.
        let low = line.side(bow + boat.current * max(secondsToGun, 0)) < -OvertakeScenario.holdLengths * hullLength
        if beforeGun { eased = !low }
        if beforeGun, !low {
            // Luff into the no-go zone and stall, steering as the autohelm steers (its `rudder`), which won't aim there.
            let windSign = boat.boomSide == .port ? 1.0 : -1.0
            let error = wrapAngle(deg2rad(OvertakeScenario.luffDegrees) - boat.sailingAngle)
            return BoatInput(rudder: -windSign * boatClass.steering.autohelm.gain * error, ease: eased)
        }
        guard !boatClass.steering.autohelm.holdsWhenCentred else { return BoatInput(rudder: 0.0, ease: eased) }
        let rudder = Autohelm(target: .angle(angle)).rudder(
            sailingAngle: boat.sailingAngle, boomSide: boat.boomSide, tws: boat.polarWindSpeed(in: boatClass),
            grooveTWS: boat.grooveWindSpeed(in: boatClass), boatClass: boatClass)
        return BoatInput(rudder: rudder, ease: eased)
    }
}

/// What the scenario reads of the race each tick: each bot against the scripted boat (seat 0), and the bots against
/// each other apart. Pure: fed boats, the tick's drained events and the tick, so a test can drive it by hand.
struct OvertakeProbe {
    struct Share: Hashable {
        var share: Double
        var eased: Bool
    }

    /// One bot's running record.
    struct Record {
        var contacts = 0
        var repeatContacts = 0
        var callsByRule: [String: Int] = [:]
        var callsOnHer = 0
        var closest = Double.infinity
        /// The current run of offset ticks while clear astern: its first tick, distance and side.
        var run: (tick: Int, lengths: Double, side: OvertakeSide)?
        var passChosen: (lengths: Double, side: OvertakeSide)?
        var clearAheadTick: Int?
        var clearAheadSide: OvertakeSide?
        var tacked = false
        var dirtyTicks = 0
    }

    let hull: BoatClass.Hull
    let startTick: Int
    private(set) var records: [Record]
    private(set) var botBotContacts = 0
    private(set) var botBotCalls = 0
    private(set) var shares: [Share] = []

    init(seats: Int, hull: BoatClass.Hull, startTick: Int) {
        self.hull = hull
        self.startTick = startTick
        records = Array(repeating: Record(), count: seats)
    }

    /// Call after each `race.step()` with its drained events. `herCourse`, the heading the bots' offsets are read
    /// against, is her heading unless given.
    /// `repeatContacts`, this tick's contacts made while their incident was already open.
    mutating func record(boats: [Boat], events: [RaceEvent], tick: Int, herShare: Share? = nil, herCourse: Double? = nil,
                         repeatContacts: [SeatPair] = []) {
        if let herShare { shares.append(herShare) }
        for pair in repeatContacts where pair.contains(0) { records[pair.high].repeatContacts += 1 }
        for event in events {
            switch event.kind {
            case .contact(let pair):
                if pair.contains(0) { records[pair.high].contacts += 1 } else { botBotContacts += 1 }
            case .ruleCall(let call):
                if call.victim == 0, call.offender != 0 {
                    records[call.offender].callsByRule[call.rule.rawValue, default: 0] += 1
                } else if call.offender == 0, call.victim != 0 {
                    records[call.victim].callsOnHer += 1
                } else if call.offender != 0, call.victim != 0 {
                    botBotCalls += 1
                }
            default: break
            }
        }
        let her = boats[0]
        let length = hull.length
        let windSign = her.tack == .starboard ? 1.0 : -1.0
        let windward = her.forward.rightPerp * windSign
        let ticksNeeded = Int((OvertakeScenario.offsetSeconds * Double(Race.tickRate)).rounded())
        for seat in boats.indices.dropFirst() {
            let bot = boats[seat]
            var record = records[seat]
            let offset = bot.position - her.position
            record.closest = min(record.closest, offset.length / length)
            if bot.shadow < PackScenario.dirtyAir { record.dirtyTicks += 1 }
            if record.clearAheadTick == nil {
                // A tack ends the encounter as tacked away: on the other tack she can be abaft the bot's beam
                // without the bot having passed her.
                if bot.tack != her.tack || bot.isTacking { record.tacked = true }
                if !record.tacked, Rules.isClearAstern(her, of: bot, hull: hull) {
                    record.clearAheadTick = tick
                    record.clearAheadSide = offset.dot(windward) >= 0 ? .windward : .leeward
                }
            }
            // A sustained offset off her course, while she is still clear astern of her.
            if record.passChosen == nil {
                let astern = Rules.isClearAstern(bot, of: her, hull: hull)
                let turn = wrapAngle(bot.heading - (herCourse ?? her.heading))
                let side: OvertakeSide? = !astern ? nil
                    : bot.tack != her.tack || bot.isTacking ? .tack
                    : abs(turn) >= deg2rad(OvertakeScenario.offsetDegrees) ? (turn * windSign > 0 ? .windward : .leeward)
                    : nil
                if let side {
                    if record.run == nil || record.run?.side != side {
                        record.run = (tick, -offset.dot(her.forward) / length, side)
                    }
                    if let run = record.run, side == .tack || tick - run.tick + 1 >= ticksNeeded {
                        record.passChosen = (run.lengths, run.side)
                    }
                } else {
                    record.run = nil
                }
            }
            records[seat] = record
        }
    }

    /// The bot in `seat`'s result.
    func result(seat: Int, tier: String) -> OvertakeBotResult {
        let record = records[seat]
        let outcome: OvertakeOutcome = switch (record.clearAheadSide, record.tacked) {
        case (.windward?, _): .passedWindward
        case (.leeward?, _): .passedLeeward
        case (_, true): .tackedAway
        default: .stillAstern
        }
        return OvertakeBotResult(
            seat: seat, tier: tier, contacts: record.contacts, repeatContacts: record.repeatContacts, callsByRule: record.callsByRule, callsOnHer: record.callsOnHer,
            closestApproach: record.closest, passChosenLengths: record.passChosen?.lengths,
            passChosenSide: record.passChosen?.side,
            clearAheadSeconds: record.clearAheadTick.map { Double($0 - startTick) / Double(Race.tickRate) },
            outcome: outcome, dirtySeconds: Double(record.dirtyTicks) / Double(Race.tickRate))
    }
}

// MARK: Report

/// One row of the report: the bots of one group of races, pooled.
public struct OvertakeGroupRow: Codable, Hashable, Sendable {
    public var group: String
    public var races: Int
    public var bots: Int
    /// Per 100 bots: contacts with her, rule 12 and rule 11 calls on the bots (her the victim), the other calls on
    /// them, and calls on her (a bot the victim).
    public var contactsPer100: Double
    /// Of the contacts, per 100 bots, those made while their incident was still open: never judged again.
    public var repeatContactsPer100: Double = 0
    public var r12Per100: Double
    public var r11Per100: Double
    public var otherCallsPer100: Double
    public var callsOnHerPer100: Double
    /// Between bots, per 100 bots: apart from the pair measures.
    public var botBotContactsPer100: Double
    public var botBotCallsPer100: Double
    /// Closest approach, hull lengths: the least, the 10th percentile, and the bots under 1.0 and 1.3 lengths.
    public var closestMin: Double?
    public var closestP10: Double?
    public var closestUnder1: Int
    public var closestUnder13: Int
    /// The share of bots that chose a pass; how far back, hull lengths (median, 10th percentile); by side.
    public var passChosenShare: Double
    public var passChosenMedian: Double?
    public var passChosenP10: Double?
    public var passChosenBySide: [String: Int]
    /// The share of bots clear ahead of her by the run's end, and the seconds it took them (median, 90th, max).
    public var clearedShare: Double
    public var clearAheadMedian: Double?
    public var clearAheadP90: Double?
    public var clearAheadMax: Double?
    /// The outcomes, as shares of the bots.
    public var outcomeShares: [String: Double]
    public var dirtySecondsPerBot: Double?
    /// The scripted boat's speed share over the races (sanity): the mean of the races' means, the least and most, the
    /// mean share of ticks eased.
    public var herShareMean: Double?
    public var herShareMin: Double?
    public var herShareMax: Double?
    public var herEasedShare: Double?

    init(group: String, races: [OvertakeRaceResult], keep: (OvertakeBotResult) -> Bool = { _ in true }) {
        self.group = group
        self.races = races.count
        let bots = races.flatMap { $0.bots.filter(keep) }
        self.bots = bots.count
        let per100 = 100 / Double(max(bots.count, 1))
        func count(_ value: (OvertakeBotResult) -> Int) -> Double { Double(bots.reduce(0) { $0 + value($1) }) * per100 }
        contactsPer100 = count(\.contacts)
        repeatContactsPer100 = count(\.repeatContacts)
        r12Per100 = count { $0.callsByRule[RacingRule.clearAstern.rawValue] ?? 0 }
        r11Per100 = count { $0.callsByRule[RacingRule.windwardLeeward.rawValue] ?? 0 }
        otherCallsPer100 = count {
            $0.calls - ($0.callsByRule[RacingRule.clearAstern.rawValue] ?? 0) - ($0.callsByRule[RacingRule.windwardLeeward.rawValue] ?? 0)
        }
        callsOnHerPer100 = count(\.callsOnHer)
        botBotContactsPer100 = Double(races.reduce(0) { $0 + $1.botBotContacts }) * per100
        botBotCallsPer100 = Double(races.reduce(0) { $0 + $1.botBotCalls }) * per100
        let closest = bots.map(\.closestApproach).sorted()
        closestMin = closest.first
        closestP10 = closest.isEmpty ? nil : TickTimings.percentile(10, ofSorted: closest)
        closestUnder1 = closest.filter { $0 < 1.0 }.count
        closestUnder13 = closest.filter { $0 < 1.3 }.count
        let chosen = bots.compactMap(\.passChosenLengths).sorted()
        passChosenShare = share(chosen.count, of: bots.count)
        passChosenMedian = chosen.isEmpty ? nil : median(chosen)
        passChosenP10 = chosen.isEmpty ? nil : TickTimings.percentile(10, ofSorted: chosen)
        passChosenBySide = Dictionary(bots.compactMap(\.passChosenSide).map { ($0.rawValue, 1) }, uniquingKeysWith: +)
        let cleared = bots.compactMap(\.clearAheadSeconds).sorted()
        clearedShare = share(cleared.count, of: bots.count)
        clearAheadMedian = cleared.isEmpty ? nil : median(cleared)
        clearAheadP90 = cleared.isEmpty ? nil : TickTimings.percentile(90, ofSorted: cleared)
        clearAheadMax = cleared.last
        outcomeShares = Dictionary(uniqueKeysWithValues: OvertakeOutcome.allCases.map { outcome in
            (outcome.rawValue, share(bots.filter { $0.outcome == outcome }.count, of: bots.count))
        })
        dirtySecondsPerBot = bots.isEmpty ? nil : bots.map(\.dirtySeconds).reduce(0, +) / Double(bots.count)
        let means = races.compactMap(\.herShareMean)
        herShareMean = means.isEmpty ? nil : means.reduce(0, +) / Double(means.count)
        herShareMin = races.compactMap(\.herShareMin).min()
        herShareMax = races.compactMap(\.herShareMax).max()
        let eased = races.compactMap(\.herEasedShare)
        herEasedShare = eased.isEmpty ? nil : eased.reduce(0, +) / Double(eased.count)
    }

    /// The columns' titles, in the order `cells` gives them.
    static let titles = ["group", "races", "bots", "contacts/100", "repeat/100", "r12/100", "r11/100", "other/100", "on her/100",
                         "bot-bot contacts/100", "bot-bot calls/100", "closest min", "closest p10", "<1.0 L", "<1.3 L",
                         "pass chosen", "chosen L median", "chosen L p10", "chosen sides", "cleared", "clear s median",
                         "clear s p90", "clear s max", "windward", "leeward", "tacked away", "still astern", "dirty s/bot",
                         "her share mean", "her min", "her max", "her eased"]

    var cells: [String] {
        func number(_ value: Double?, _ places: Int = 1) -> String { value.map { fixed($0, places) } ?? "-" }
        let sides = OvertakeSide.allCases.compactMap { side in passChosenBySide[side.rawValue].map { "\(side.rawValue):\($0)" } }
        return [group, "\(races)", "\(bots)", fixed(contactsPer100, 1), fixed(repeatContactsPer100, 1), fixed(r12Per100, 1), fixed(r11Per100, 1),
                fixed(otherCallsPer100, 1), fixed(callsOnHerPer100, 1), fixed(botBotContactsPer100, 1), fixed(botBotCallsPer100, 1),
                number(closestMin, 2), number(closestP10, 2), "\(closestUnder1)", "\(closestUnder13)", fixed(passChosenShare),
                number(passChosenMedian), number(passChosenP10), sides.isEmpty ? "-" : sides.joined(separator: " "),
                fixed(clearedShare), number(clearAheadMedian), number(clearAheadP90), number(clearAheadMax),
                fixed(outcomeShares[OvertakeOutcome.passedWindward.rawValue] ?? 0),
                fixed(outcomeShares[OvertakeOutcome.passedLeeward.rawValue] ?? 0),
                fixed(outcomeShares[OvertakeOutcome.tackedAway.rawValue] ?? 0),
                fixed(outcomeShares[OvertakeOutcome.stillAstern.rawValue] ?? 0), number(dirtySecondsPerBot),
                number(herShareMean, 3), number(herShareMin, 3), number(herShareMax, 3), number(herEasedShare)]
    }
}

/// `regatta-botsuite --scenario overtake`'s report: one row of columns for all the races and for each group of them.
public struct OvertakeReport: Codable, Hashable, Sendable {
    public var scenario = "overtake"
    public var races: [OvertakeRaceResult]
    /// The prestart races that couldn't be placed inside the race area (`OvertakeUnplaced`), left out of the rows.
    public var unplaced: [OvertakeUnplacedRace]
    /// Owner (#530 b): the share of the cells left out, of all and of the prestart ones (all of them prestart races
    /// with a current up the course), so the scenario is not read as a full sweep of the venues.
    public var unplacedShare: Double
    public var unplacedPrestartShare: Double
    /// The scenario's races (all, by phase, tack, current, astern, across, fleet size, tier, beat × astern, beat ×
    /// tier), then the control's under `control …` when it was sailed.
    public var rows: [OvertakeGroupRow]

    init(races: [OvertakeRaceResult], unplaced: [OvertakeUnplacedRace] = []) {
        self.races = races
        self.unplaced = unplaced
        unplacedShare = share(unplaced.count, of: races.count + unplaced.count)
        let prestart = races.filter { $0.layout.phase == .prestart }.count
        unplacedPrestartShare = share(unplaced.filter { $0.layout.phase == .prestart }.count, of: prestart + unplaced.count)
        var rows = Self.rows(races.filter { !$0.layout.control }, prefix: "")
        let control = races.filter(\.layout.control)
        if !control.isEmpty { rows += Self.rows(control, prefix: "control ") }
        self.rows = rows
    }

    private static func rows(_ races: [OvertakeRaceResult], prefix: String) -> [OvertakeGroupRow] {
        guard !races.isEmpty else { return [] }
        func row(_ group: String, _ keep: (OvertakeRaceResult) -> Bool) -> [OvertakeGroupRow] {
            let kept = races.filter(keep)
            return kept.isEmpty ? [] : [OvertakeGroupRow(group: prefix + group, races: kept)]
        }
        var rows = [OvertakeGroupRow(group: prefix + "all", races: races)]
        for phase in OvertakePhase.allCases { rows += row("phase \(phase.rawValue)") { $0.layout.phase == phase } }
        for tack in OvertakeTack.allCases { rows += row("tack \(tack.rawValue)") { $0.layout.tack == tack } }
        // Before the gun her tack decides who holds right of way once the bots tack for their start: on port she keeps
        // clear of a starboard bot (rule 10).
        for tack in OvertakeTack.allCases {
            rows += row("prestart tack \(tack.rawValue)") { $0.layout.phase == .prestart && $0.layout.tack == tack }
        }
        rows += row("current with") { $0.layout.current } + row("current without") { !$0.layout.current }
        for astern in Set(races.map(\.layout.astern)).sorted() { rows += row("astern \(text(astern))") { $0.layout.astern == astern } }
        for across in Set(races.map(\.layout.across)).sorted() { rows += row("across \(text(across))") { $0.layout.across == across } }
        let sizes = Set(races.map(\.layout.fleetSize)).sorted()
        if sizes.count > 1 { for size in sizes { rows += row("fleet \(size)") { $0.layout.fleetSize == size } } }
        for tier in BotTier.allCases { rows += tierRow(races, tier: tier, group: prefix + "tier \(tier.rawValue)") }
        // The beat's rows #531 targets: by astern and by tier.
        let beat = races.filter { $0.layout.phase == .beat }
        for astern in Set(beat.map(\.layout.astern)).sorted() {
            rows += row("beat astern \(text(astern))") { $0.layout.phase == .beat && $0.layout.astern == astern }
        }
        for tier in BotTier.allCases { rows += tierRow(beat, tier: tier, group: prefix + "beat tier \(tier.rawValue)") }
        return rows
    }

    private static func tierRow(_ races: [OvertakeRaceResult], tier: BotTier, group: String) -> [OvertakeGroupRow] {
        let kept = races.filter { $0.bots.contains { $0.tier == tier.rawValue } }
        return kept.isEmpty ? [] : [OvertakeGroupRow(group: group, races: kept, keep: { $0.tier == tier.rawValue })]
    }

    private static func text(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : fixed(value, 1)
    }

    private func percent(_ value: Double) -> String { fixed(value * 100, 1) + " %" }

    /// Sorted keys, so two runs of the same options give the same bytes.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(self)
    }

    /// A summary line, then the table: a header line and a row for each group.
    public var lines: [String] {
        let bots = races.reduce(0) { $0 + $1.bots.count }
        let waived = races.reduce(0) { $0 + $1.herPenaltiesWaived }
        var lines = ["overtake scenario: \(races.count) races, \(bots) bots, \(races.filter(\.herOCS).count) with her OCS, "
            + "\(waived) penalties on her waived, \(races.filter(\.herDSQ).count) with her DSQ, "
            + "\(unplaced.count) not placed (\(percent(unplacedShare)) of all, \(percent(unplacedPrestartShare)) of prestart: a "
            + "current up the course sets her start below the race area, which ends a line length below the line)"]
        let table = [OvertakeGroupRow.titles] + rows.map(\.cells)
        let widths = OvertakeGroupRow.titles.indices.map { column in table.map { $0[column].count }.max() ?? 0 }
        for row in table {
            lines.append(row.indices.map { column in
                let padding = String(repeating: " ", count: widths[column] - row[column].count)
                return column == 0 ? row[column] + padding : padding + row[column]
            }.joined(separator: "  "))
        }
        return lines
    }
}
