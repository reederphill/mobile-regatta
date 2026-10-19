import Foundation
import RegattaBots
import RegattaCore

// `regatta-botsuite --scenario pack` (#525, step 0): a bunch of 4 to 6 boats placed above the leeward gate, sailed to
// the gate by the live bots, and measured. The matrix's gate roundings hold a pack (three boats within 20 m at the
// pick) in 1 to 4 percent of them, so a run of the matrix can't see the packs a player meets. Here every race is one.
//
// The scenario is a harness. It changes no rule and no bot, and it adds nothing to the core: the boats are put in
// place with `Race.exportSnapshot()` and `importSnapshot(_:)`, as the bot tests place theirs
// (`BotConductTests.place`), after the gun, on the gate's leg. It is separate from `BotSuiteReport`: a run without
// `--scenario` never reaches this file.

/// The scenario's own failures, which the command reports as a setup error (exit 2).
public enum PackScenarioError: Error, CustomStringConvertible, Equatable {
    case setup(String)

    public var description: String {
        switch self {
        case .setup(let message): "pack scenario: \(message)"
        }
    }
}

/// Which of the pack scenario's venues it sails: `saltings-reach` has a current, `dev-venue` has none.
public enum PackCurrent: String, CaseIterable, Codable, Hashable, Sendable {
    case with, without, both
}

/// Whether the boats of a pack are on one gybe or on both.
public enum PackGybes: String, CaseIterable, Codable, Hashable, Sendable {
    /// Every boat on the gybe of the first one drawn.
    case same
    /// The boats alternate gybes by slot, so one of every two boats meeting owes the other room (rule 10).
    case mixed
}

/// One layout of the pack: what a group of races of the report shares.
public struct PackLayout: Codable, Hashable, Sendable {
    /// Sailed in a venue with a current (`saltings-reach@1`), or without (`dev-venue@7`).
    public var current: Bool
    /// The boats in the pack, which is the race's fleet.
    public var size: Int
    /// Where the bunch's centre lies across the course, hull lengths from the middle of the gate. The gate is 10 hull
    /// lengths wide: -6 is over one end, 0 the middle, +6 over the other. Positive is to the course's right looking up
    /// the wind (`CourseLayout.right`), which is the end the course calls the gate's left mark.
    public var offset: Double
    public var gybes: PackGybes

    public init(current: Bool, size: Int, offset: Double, gybes: PackGybes) {
        self.current = current
        self.size = size
        self.offset = offset
        self.gybes = gybes
    }

    public var venue: String { current ? PackScenario.currentVenue : PackScenario.calmVenue }
}

/// One race of the scenario: a layout, a seed, a tier mix.
public struct PackCell: Hashable, Sendable {
    public var seed: UInt64
    public var layout: PackLayout
    public var tierMix: TierMix
    /// Metres above the middle of the gate's line, along the course, the bunch's centre.
    public var above: Double
    public var autohelmOff: Bool?
    public var boatClass: String?
    /// The bundled rules it sails, `id@version` (#477, `--rules`); nil for the default rules.
    public var rules: String?

    public init(seed: UInt64, layout: PackLayout, tierMix: TierMix, above: Double = PackScenario.defaultAbove,
                autohelmOff: Bool? = nil, boatClass: String? = nil,
                rules: String? = nil) {
        self.seed = seed
        self.layout = layout
        self.tierMix = tierMix
        self.above = above
        self.autohelmOff = autohelmOff
        self.boatClass = boatClass
        self.rules = rules
    }

    /// The race the cell sails: its fleet is the pack, two laps so the gate is the third leg.
    var raceCell: BotRaceCell {
        BotRaceCell(seed: seed, venue: layout.venue, conditions: PackScenario.conditions, tideStateDegrees: 0,
                    fleetSize: layout.size, tierMix: tierMix, profileMix: .live, laps: PackScenario.laps,
                    capSecondsAfterGun: BotMatrix.defaultCapSecondsAfterGun, autohelmOff: autohelmOff, boatClass: boatClass,
                    rules: rules)
    }
}

/// What the scenario saw of one boat.
public struct PackBoatResult: Codable, Hashable, Sendable {
    public var seat: Int
    public var tier: String
    /// She was in a pack at her entry: at least two other boats racing the gate leg, not yet round the mark, within
    /// 20 m of her on that tick. False too for a boat that never entered.
    public var inPack: Bool
    /// The boats within 20 m at her entry; nil if she never entered.
    public var neighbours: Int?
    /// The gate mark she rounded, read on her first tick on the next leg: 0 the left one, 1 the right one; nil if she
    /// never got onto the next leg.
    public var markUsed: Int?
    /// Her gate rounding, entry to the end of the leg (`RoundingObservation.EntryToEnd`), against the ideal; nil if she
    /// never completed it.
    public var extraMetres: Double?
    public var extraSeconds: Double?
    /// Seconds below the gate's line, and the most metres below it (`RoundingObservation.BelowTheLine`).
    public var belowSeconds: Double?
    public var deepest: Double?
    /// At least 3 s below the line before she crossed it (`RoundingObservation.overshoots`).
    public var overshoot: Bool?
    /// Still below the line when her rounding's exit ended.
    public var stillBelow: Bool?
    /// Seconds on the gate leg within 80 m of the gate's centre with her wind under 0.85 of the free wind: in someone's
    /// shadow, backwind or ribbon (`Boat.shadow`).
    public var dirtySeconds: Double
    public var boatContacts: Int
    public var markTouches: Int
    /// Her rule calls as the offender, in all and by rule.
    public var calls: Int
    public var callsByRule: [String: Int]

    /// She rounded the gate and has its measures.
    public var completed: Bool { extraMetres != nil }
}

/// One race of the scenario, reduced.
public struct PackRaceResult: Codable, Hashable, Sendable {
    public var seed: UInt64
    public var layout: PackLayout
    public var tierMix: TierMix
    /// The tide state at the gun (`Race.tideStateAtGun`), as the seed draws it; nil in a venue without a current.
    public var tideStateAtGun: Double?
    /// Ticks sailed after the boats were placed, and whether the cap ended the race with a boat still short of the end
    /// rule (`PackScenario.capSeconds`).
    public var ticks: Int
    public var capped: Bool
    /// The fastest current any boat felt, metres per second, over the ticks sailed.
    public var maxCurrent: Double
    public var boats: [PackBoatResult]

    /// At least one boat was in a pack at her entry.
    public var holdsPack: Bool { boats.contains(where: \.inPack) }
    /// Boats on each gate mark (the left one first).
    var markCounts: [Int] {
        [0, 1].map { mark in boats.filter { $0.markUsed == mark }.count }
    }
    public var bothMarksUsed: Bool { markCounts.allSatisfy { $0 > 0 } }
    /// The boats on the mark fewer of them rounded; 0 when they all rounded one.
    public var lessUsedMark: Int { markCounts.min() ?? 0 }
    public var boatContacts: Int { boats.reduce(0) { $0 + $1.boatContacts } / 2 }
    public var markTouches: Int { boats.reduce(0) { $0 + $1.markTouches } }
    public var calls: Int { boats.reduce(0) { $0 + $1.calls } }
    /// The extra metres of the boats that were in a pack, summed.
    public var packExtraMetres: Double { boats.filter(\.inPack).compactMap(\.extraMetres).reduce(0, +) }
}

/// The scenario: placement, the sail and the measures.
public enum PackScenario {
    public static let currentVenue = "saltings-reach@1"
    public static let calmVenue = "dev-venue@7"
    public static let conditions = "classic-oscillating@7"
    /// Two laps, so the gate is the third leg (`gateLeg`).
    public static let laps = 2
    public static let gateLeg = 2
    public static let defaultAbove = 100.0
    public static let defaultOffsets = [-6.0, 0.0, 6.0]
    public static let defaultSizes = [4, 5, 6]
    public static let defaultSeeds = 16
    /// The bunch is drawn in a disc of this radius around its centre, hull lengths.
    public static let discLengths = 3.5
    /// No two hulls closer than this at placement, centre to centre, hull lengths.
    public static let spacingLengths = 1.5
    /// A boat is in a pack with this many others within `packRange`.
    public static let packNeighbours = 2
    public static let packRange = 20.0
    /// Draws of the whole bunch before the placement gives up.
    public static let maxDraws = 50
    /// A shadowed boat's wind is under this share of the free wind (`RaceTally.shadowFactor`).
    public static let dirtyAir = 0.85
    /// The race ends this long after the boats are placed, seconds, whoever has not got round by then.
    public static let capSeconds = 240

    // MARK: Cells

    /// The races a run sails: every layout × tier mix × seed, seeds outermost.
    public static func cells(_ options: BotSuiteOptions) throws -> [PackCell] {
        let sizes = options.fleetSizes.isEmpty ? defaultSizes : options.fleetSizes
        let offsets = options.packOffsets.isEmpty ? defaultOffsets : options.packOffsets
        let tiers = options.tierMixes.isEmpty ? [TierMix.national] : options.tierMixes
        let currents: [Bool] = switch options.packCurrent ?? .both {
        case .with: [true]
        case .without: [false]
        case .both: [true, false]
        }
        let seeds = (1...(options.seedCount ?? defaultSeeds)).map(UInt64.init)
        if let boatClass = options.boatClass { _ = try BotRaceHarness.bundledClass(boatClass) }
        if let rules = options.rules { _ = try BotRaceHarness.bundledRules(rules) }
        let layouts = currents.flatMap { current in
            sizes.flatMap { size in
                offsets.flatMap { offset in
                    PackGybes.allCases.map { PackLayout(current: current, size: size, offset: offset, gybes: $0) }
                }
            }
        }
        return seeds.flatMap { seed in
            tiers.flatMap { tier in
                layouts.map {
                    PackCell(seed: seed, layout: $0, tierMix: tier, above: options.packAbove ?? defaultAbove,
                             autohelmOff: options.autohelmOff == true ? true : nil, boatClass: options.boatClass,
                                 rules: options.rules)
                }
            }
        }
    }

    public static func run(_ options: BotSuiteOptions) throws -> PackReport {
        let cells = try cells(options)
        let races = try BotSuite.inParallel(cells, jobs: options.jobs ?? BotSuite.defaultJobs, sail)
        return PackReport(races: races, above: options.packAbove ?? defaultAbove)
    }

    // MARK: Placement

    /// The course's geometry the placement and the probe both read.
    struct Geometry {
        /// The middle of the gate's line.
        var gate: Vec2
        var up: Vec2
        var right: Vec2
        /// Along the gate's line from its left mark to its right one, as the roundings read it.
        var along: Vec2
        var hullLength: Double

        init(_ race: Race) throws {
            let course = race.course
            guard course.legs.indices.contains(PackScenario.gateLeg),
                  course.legs[PackScenario.gateLeg] == .round(CourseLayout.gateIndex),
                  case .gate(let left, let right) = course.elements[CourseLayout.gateIndex] else {
                throw PackScenarioError.setup("leg \(PackScenario.gateLeg) is not the leeward gate")
            }
            gate = course.targetPosition(for: course.legs[PackScenario.gateLeg])
            up = course.upwind
            self.right = course.right
            along = (right.position - left.position).normalized
            hullLength = race.boatClass.hull.length
        }
    }

    /// One boat's place in the bunch.
    struct Pose: Hashable {
        var seat: Int
        var position: Vec2
        var heading: Double
        var speed: Double
        /// Her true wind angle, and whether she sails the gybe with the boom to port (the wind over her starboard quarter).
        var twa: Double
        var onStarboardGybe: Bool
    }

    /// The stream the bunch is drawn from: the seed and the layout but for its current, so a race with a current and
    /// one without draw the same bunch and differ in the water and the wind.
    static func stream(_ cell: PackCell) -> SplitMix64 {
        var key = cell.seed &* 0x9E37_79B9_7F4A_7C15
        for part in [UInt64(cell.layout.size), cell.layout.offset.bitPattern, cell.above.bitPattern,
                     cell.layout.gybes == .same ? 0 : 1] {
            var mixer = SplitMix64(seed: key ^ part)
            key = mixer.next()
        }
        return SplitMix64(seed: key)
    }

    /// The bunch for `cell` in `race`, which is past the gun and has not been placed: a pose for each seat.
    static func poses(_ cell: PackCell, in race: Race) throws -> [Pose] {
        let geometry = try Geometry(race)
        let length = geometry.hullLength
        let centre = geometry.gate + geometry.up * cell.above + geometry.right * (cell.layout.offset * length)
        let wind = race.groundWind(at: centre)
        let down = race.boatClass.polar.bestDownwind(tws: wind.speed)
        let size = cell.layout.size
        var rng = stream(cell)
        let area = race.course.raceArea
        for _ in 0..<maxDraws {
            // The bunch in a disc, no two hulls closer than the spacing.
            var points: [Vec2] = []
            var failed = false
            for _ in 0..<size {
                var placed = false
                for _ in 0..<100 {
                    let radius = discLengths * length * rng.unit().squareRoot()
                    let angle = rng.range(0, 2 * .pi)
                    let point = centre + geometry.right * (radius * cos(angle)) + geometry.up * (radius * sin(angle))
                    if points.allSatisfy({ ($0 - point).length >= spacingLengths * length }) {
                        points.append(point)
                        placed = true
                        break
                    }
                }
                if !placed {
                    failed = true
                    break
                }
            }
            // The first slot's coin and the seats' order are drawn whether or not the bunch is kept, so the stream
            // stays the same however many draws it took.
            let firstGybe = rng.bool()
            var seats = Array(0..<size)
            for i in stride(from: size - 1, to: 0, by: -1) { seats.swapAt(i, rng.int(in: 0...i)) }
            guard !failed,
                  points.allSatisfy({ area.inset($0) > 0 }),
                  points.indices.allSatisfy({ i in
                      points.indices.filter { $0 != i && (points[$0] - points[i]).length <= packRange }.count >= packNeighbours
                  }) else { continue }
            return points.indices.map { slot in
                let starboard = cell.layout.gybes == .same ? firstGybe : (slot.isMultiple(of: 2) == firstGybe)
                return Pose(seat: seats[slot], position: points[slot],
                            heading: starboard ? wind.direction - down.twa : wind.direction + down.twa,
                            speed: down.speed, twa: down.twa, onStarboardGybe: starboard)
            }.sorted { $0.seat < $1.seat }
        }
        throw PackScenarioError.setup("no pack of \(size) at offset \(cell.layout.offset) in \(maxDraws) draws "
            + "(seed \(cell.seed), \(cell.layout.venue))")
    }

    /// Puts `poses` into `race` as the bot tests put their boats: racing the gate leg, nothing round it yet, the
    /// autohelm holding the wind angle, clean air.
    static func place(_ poses: [Pose], in race: Race) throws {
        var snapshot = race.exportSnapshot()
        for pose in poses {
            // The wind minus her heading: her wind angle, positive with the wind over her starboard quarter.
            let relative = pose.onStarboardGybe ? pose.twa : -pose.twa
            snapshot.seats[pose.seat].boat.position = pose.position
            snapshot.seats[pose.seat].boat.heading = pose.heading
            snapshot.seats[pose.seat].boat.speed = pose.speed
            snapshot.seats[pose.seat].boat.boomSide = relative >= 0 ? .port : .starboard
            snapshot.seats[pose.seat].boat.status = .racing
            snapshot.seats[pose.seat].boat.legIndex = gateLeg
            snapshot.seats[pose.seat].boat.roundingStage = 0
            snapshot.seats[pose.seat].boat.autohelm = Autohelm(target: .angle(abs(relative)))
            snapshot.seats[pose.seat].boat.rudder = 0
            snapshot.seats[pose.seat].boat.isTacking = false
            snapshot.seats[pose.seat].heldInput = .neutral
        }
        // Placed boats start in clean air: no ribbons, headers or backwind from where they were.
        snapshot.ribbonPoints = []
        snapshot.emissionLevels = []
        snapshot.headers = []
        snapshot.backwind = BackwindSails()
        try race.importSnapshot(snapshot)
        _ = race.drainEvents()
    }

    /// The race of `cell`, one second past the gun (so the wind has its keys), its boats placed in the bunch.
    static func placedRace(_ cell: PackCell) throws -> (race: Race, setup: RaceSetup, poses: [Pose]) {
        let raceCell = cell.raceCell
        let setup = try BotRaceHarness.raceSetup(for: raceCell)
        let race = try Race(setup: setup, files: BotRaceHarness.raceFiles(for: raceCell, setup: setup),
                            mode: .authoritative(windSeed: BotRaceHarness.windSeed(for: cell.seed)))
        for _ in 0..<(setup.startSequenceTicks + Race.tickRate) { race.step() }
        let poses = try poses(cell, in: race)
        try place(poses, in: race)
        return (race, setup, poses)
    }

    // MARK: Sailing

    /// Sails `cell`: the live bots from the placement until each has been on the leg after the gate for the rounding's
    /// exit (`RoundingObservation.exitSeconds`), or until `capSeconds`.
    public static func sail(_ cell: PackCell) throws -> PackRaceResult {
        let (race, setup, _) = try placedRace(cell)
        let geometry = try Geometry(race)
        let tiers = setup.seats.indices.map { cell.tierMix.tier(ofSeat: $0, raceSeed: setup.raceSeed) }
        // The bots take their seats over mid-race, as a bot takes over any seat (`BotDriver.takingOver()`).
        var controllers = SeatControllers(tiers.indices.map {
            .bot(cell.tierMix.driver(seat: $0, raceSeed: setup.raceSeed).takingOver())
        })
        var tally = RaceTally(race: race)
        var probe = PackProbe(race: race, geometry: geometry)
        var scorers = Array(repeating: RoundingScorer(course: race.course, polar: race.boatClass.polar), count: setup.seats.count)
        let first = race.tick
        let exitTicks = RoundingObservation.exitSeconds * Race.tickRate
        var pastTicks = Array(repeating: 0, count: setup.seats.count)
        var capped = true
        while !race.isOver && race.tick - first < capSeconds * Race.tickRate {
            controllers.drive(race)
            race.step()
            let drained = race.drainEvents()
            tally.record(race, events: drained)
            probe.record(race)
            for (seat, boat) in race.boats.enumerated() {
                guard boat.status == .racing else {
                    pastTicks[seat] = exitTicks
                    continue
                }
                scorers[seat].record(RoundingSample(tick: race.tick, position: boat.position, windDirection: boat.windDirection,
                                                    tws: boat.polarWindSpeed(in: race.boatClass), leg: boat.legIndex,
                                                    stage: boat.roundingStage))
                if boat.legIndex > gateLeg { pastTicks[seat] += 1 }
            }
            if pastTicks.allSatisfy({ $0 >= exitTicks }) {
                capped = false
                break
            }
        }
        let boats = race.boats.indices.map { seat -> PackBoatResult in
            let metrics = tally.metrics(seat: seat, of: race, tier: tiers[seat], profile: nil,
                                        style: controllers[seat].driver?.style)
            let rounding = scorers[seat].observations().first { $0.mark == .gate && $0.entryToEnd != nil }
            return PackBoatResult(
                seat: seat, tier: tiers[seat].rawValue, inPack: probe.inPack[seat], neighbours: probe.neighbours[seat],
                markUsed: probe.markUsed[seat], extraMetres: rounding?.entryToEnd?.extraMetres,
                extraSeconds: rounding?.entryToEnd?.extraSeconds, belowSeconds: rounding?.belowTheLine?.seconds,
                deepest: rounding?.belowTheLine?.deepest, overshoot: rounding.map(\.overshoots),
                stillBelow: rounding?.belowTheLine?.stillBelow,
                dirtySeconds: Double(probe.dirtyTicks[seat]) / Double(Race.tickRate),
                boatContacts: metrics.boatContacts, markTouches: metrics.markContacts, calls: metrics.foulsAsOffender,
                callsByRule: metrics.callsByRule)
        }
        return PackRaceResult(seed: cell.seed, layout: cell.layout, tierMix: cell.tierMix, tideStateAtGun: race.tideStateAtGun,
                              ticks: race.tick - first, capped: capped, maxCurrent: probe.maxCurrent, boats: boats)
    }
}

/// What the scenario reads of the race each tick, apart from the roundings (`RoundingScorer`): who was in a pack at her
/// entry, which mark she rounded, her time in dirty air, the current.
struct PackProbe {
    private let geometry: PackScenario.Geometry
    private let gateLeg = PackScenario.gateLeg
    private(set) var inPack: [Bool]
    private(set) var neighbours: [Int?]
    private(set) var markUsed: [Int?]
    private(set) var dirtyTicks: [Int]
    private(set) var maxCurrent = 0.0

    init(race: Race, geometry: PackScenario.Geometry) {
        self.geometry = geometry
        inPack = Array(repeating: false, count: race.boats.count)
        neighbours = Array(repeating: nil, count: race.boats.count)
        markUsed = Array(repeating: nil, count: race.boats.count)
        dirtyTicks = Array(repeating: 0, count: race.boats.count)
    }

    /// Call after each `race.step()`.
    mutating func record(_ race: Race) {
        let boats = race.boats
        // On the gate leg, not yet round the mark: the boats that count as neighbours.
        let onLeg = boats.map { $0.status == .racing && $0.legIndex == gateLeg && $0.roundingStage == 0 }
        for (seat, boat) in boats.enumerated() {
            maxCurrent = max(maxCurrent, boat.current.length)
            guard boat.status == .racing else { continue }
            let offset = boat.position - geometry.gate
            if boat.legIndex > gateLeg, markUsed[seat] == nil {
                markUsed[seat] = offset.dot(geometry.along) < 0 ? 0 : 1
            }
            guard boat.legIndex == gateLeg else { continue }
            if offset.length < RoundingObservation.entryRange {
                if boat.shadow < PackScenario.dirtyAir { dirtyTicks[seat] += 1 }
                if neighbours[seat] == nil, onLeg[seat], offset.dot(geometry.up) > RoundingObservation.gateAbove {
                    let near = boats.indices.filter {
                        $0 != seat && onLeg[$0] && (boats[$0].position - boat.position).length <= PackScenario.packRange
                    }.count
                    neighbours[seat] = near
                    inPack[seat] = near >= PackScenario.packNeighbours
                }
            }
        }
    }
}

// MARK: Report

/// One row of the report: the races (and, for a tier, the boats) of one group, pooled.
public struct PackGroupRow: Codable, Hashable, Sendable {
    public var group: String
    public var races: Int
    public var boats: Int
    /// The share of races that hold their pack: at least one boat was in a pack at her entry.
    public var packHeldShare: Double
    /// The share of races with boats on both gate marks.
    public var bothMarksShare: Double
    /// The mean over races of the boats on the mark fewer of them used.
    public var lessUsedMarkBoats: Double
    /// The share of boats that completed the gate leg.
    public var gateCompletedShare: Double
    /// The gate rounding's extra metres, entry to the leg's end, over the boats that completed it.
    public var extraMetresMean: Double?
    public var extraMetresMedian: Double?
    public var extraMetresP90: Double?
    public var extraSecondsMean: Double?
    /// The extra metres of the boats in a pack, summed in a race, then the mean over the races that held a pack.
    public var packExtraMetresMean: Double?
    public var boatContactsPerRace: Double
    public var markTouchesPerRace: Double
    public var callsPerRace: Double
    public var callsByRulePerRace: [String: Double]
    public var belowSecondsMean: Double?
    public var belowSecondsP90: Double?
    public var deepestMean: Double?
    public var deepestP90: Double?
    /// Of the boats that completed the gate: those at least 3 s below the line before they crossed it, and those
    /// still below it at the end of the exit.
    public var overshootShare: Double
    public var stillBelowShare: Double
    /// Seconds a boat spent in dirty air on the gate leg within 80 m.
    public var dirtySecondsPerBoat: Double?

    /// `races`, pooled; with `keep`, only the boats it keeps count in the boat columns (the race columns are the whole
    /// races').
    init(group: String, races: [PackRaceResult], rules: [String], keep: (PackBoatResult) -> Bool = { _ in true }) {
        self.group = group
        self.races = races.count
        let boats = races.flatMap { $0.boats.filter(keep) }
        self.boats = boats.count
        let raceCount = max(races.count, 1)
        func perRace(_ value: (PackRaceResult) -> Double) -> Double { races.map(value).reduce(0, +) / Double(raceCount) }
        packHeldShare = share(races.filter(\.holdsPack).count, of: races.count)
        bothMarksShare = share(races.filter(\.bothMarksUsed).count, of: races.count)
        lessUsedMarkBoats = perRace { Double($0.lessUsedMark) }
        let done = boats.filter(\.completed)
        gateCompletedShare = share(done.count, of: boats.count)
        let metres = done.compactMap(\.extraMetres).sorted()
        extraMetresMean = Self.mean(metres)
        extraMetresMedian = metres.isEmpty ? nil : median(metres)
        extraMetresP90 = metres.isEmpty ? nil : TickTimings.percentile(90, ofSorted: metres)
        extraSecondsMean = Self.mean(done.compactMap(\.extraSeconds))
        packExtraMetresMean = Self.mean(races.filter(\.holdsPack).map(\.packExtraMetres))
        boatContactsPerRace = perRace { Double($0.boatContacts) }
        markTouchesPerRace = perRace { Double($0.markTouches) }
        callsPerRace = perRace { Double($0.calls) }
        callsByRulePerRace = Dictionary(uniqueKeysWithValues: rules.map { rule in
            (rule, perRace { Double($0.boats.reduce(0) { $0 + ($1.callsByRule[rule] ?? 0) }) })
        })
        let below = done.compactMap(\.belowSeconds).sorted()
        belowSecondsMean = Self.mean(below)
        belowSecondsP90 = below.isEmpty ? nil : TickTimings.percentile(90, ofSorted: below)
        let deepest = done.compactMap(\.deepest).sorted()
        deepestMean = Self.mean(deepest)
        deepestP90 = deepest.isEmpty ? nil : TickTimings.percentile(90, ofSorted: deepest)
        overshootShare = share(done.filter { $0.overshoot == true }.count, of: done.count)
        stillBelowShare = share(done.filter { $0.stillBelow == true }.count, of: done.count)
        dirtySecondsPerBoat = Self.mean(boats.map(\.dirtySeconds))
    }

    private static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    /// The columns' titles, in the order `cells` gives them.
    static let titles = ["group", "races", "boats", "pack held", "both marks", "less-used mark", "gate done", "extra m mean",
                         "extra m median", "extra m p90", "extra s mean", "pack extra m", "contacts/race", "touches/race",
                         "calls/race", "calls by rule", "below s mean", "below s p90", "deepest m mean", "deepest m p90",
                         "overshoot", "still below", "dirty s/boat"]

    var cells: [String] {
        func number(_ value: Double?, _ places: Int = 1) -> String { value.map { fixed($0, places) } ?? "-" }
        let rules = callsByRulePerRace.keys.sorted().map { "\($0):\(fixed(callsByRulePerRace[$0] ?? 0, 2))" }
        return [group, "\(races)", "\(boats)", fixed(packHeldShare), fixed(bothMarksShare), fixed(lessUsedMarkBoats),
                fixed(gateCompletedShare), number(extraMetresMean), number(extraMetresMedian), number(extraMetresP90),
                number(extraSecondsMean), number(packExtraMetresMean), fixed(boatContactsPerRace), fixed(markTouchesPerRace),
                fixed(callsPerRace), rules.isEmpty ? "-" : rules.joined(separator: " "), number(belowSecondsMean),
                number(belowSecondsP90), number(deepestMean), number(deepestP90), fixed(overshootShare), fixed(stillBelowShare),
                number(dirtySecondsPerBoat, 2)]
    }
}

/// `regatta-botsuite --scenario pack`'s report: one row of columns for all the races and for each group of them.
public struct PackReport: Codable, Hashable, Sendable {
    public var scenario = "pack"
    /// Metres above the gate's line the bunch's centre lay.
    public var above: Double
    public var races: [PackRaceResult]
    /// All, with and without current, by pack size, by offset, by gybes, by tier.
    public var rows: [PackGroupRow]

    init(races: [PackRaceResult], above: Double) {
        self.above = above
        self.races = races
        let rules = Set(races.flatMap { $0.boats.flatMap { $0.callsByRule.keys } }).sorted()
        func row(_ group: String, _ keep: (PackRaceResult) -> Bool) -> PackGroupRow? {
            let kept = races.filter(keep)
            return kept.isEmpty ? nil : PackGroupRow(group: group, races: kept, rules: rules)
        }
        var rows = [PackGroupRow(group: "all", races: races, rules: rules)]
        rows += [row("current with", { $0.layout.current }), row("current without", { !$0.layout.current })].compactMap { $0 }
        for size in Set(races.map(\.layout.size)).sorted() {
            rows += row("size \(size)", { $0.layout.size == size }).map { [$0] } ?? []
        }
        for offset in Set(races.map(\.layout.offset)).sorted() {
            rows += row("offset \(Self.text(offset))", { $0.layout.offset == offset }).map { [$0] } ?? []
        }
        for gybes in PackGybes.allCases {
            rows += row("gybes \(gybes.rawValue)", { $0.layout.gybes == gybes }).map { [$0] } ?? []
        }
        for tier in BotTier.allCases {
            let kept = races.filter { $0.boats.contains { $0.tier == tier.rawValue } }
            guard !kept.isEmpty else { continue }
            rows.append(PackGroupRow(group: "tier \(tier.rawValue)", races: kept, rules: rules, keep: { $0.tier == tier.rawValue }))
        }
        self.rows = rows
    }

    private static func text(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : fixed(value, 1)
    }

    /// Sorted keys, so two runs of the same options give the same bytes.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(self)
    }

    /// A summary line, then the table: a header line and a row for each group.
    public var lines: [String] {
        let boats = races.reduce(0) { $0 + $1.boats.count }
        var lines = ["pack scenario: \(races.count) races, \(boats) boats, \(races.filter(\.capped).count) capped, "
            + "bunch \(Self.text(above)) m above the gate"]
        let table = [PackGroupRow.titles] + rows.map(\.cells)
        let widths = PackGroupRow.titles.indices.map { column in table.map { $0[column].count }.max() ?? 0 }
        for row in table {
            lines.append(row.indices.map { column in
                let padding = String(repeating: " ", count: widths[column] - row[column].count)
                return column == 0 ? row[column] + padding : padding + row[column]
            }.joined(separator: "  "))
        }
        return lines
    }
}
