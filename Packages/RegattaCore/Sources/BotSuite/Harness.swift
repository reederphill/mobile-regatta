import Foundation
import RegattaBots
import RegattaCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Sails one bot-only race headless (#97): a `Race`, a bot in every seat, the 30 Hz tick loop, no app
/// and no server. Each tick the bots decide and the race steps, as the race server does it (#65);
/// the drive and the step are timed together as that tick.
///
/// Everything but the tick times comes from the race's seeds and the bots' own seeds, so the same cell
/// sails the same race and gives the same metrics every time on one platform. The wall clock lives
/// here, never in the bots (`SourceScanTests` keeps it out of RegattaCore and RegattaBots).
public enum BotRaceHarness {
    /// A boat slower than this, pointing inside the no-go zone, is in irons. Metres per second.
    public static let ironsSpeed = 0.5
    /// A boat this close to the race area's edge, or outside it, is at the edge. Metres.
    public static let edgeMargin = 10.0

    /// The wind seed for a race seed, as the bot tests derive it.
    public static func windSeed(for seed: UInt64) -> WindSeed {
        WindSeed(seed &* 0x9E37_79B9_7F4A_7C15 &+ 1)
    }

    /// `cell`'s setup: every seat a bot sailing the default class (`RaceFiles.defaults`: the skiff since #248,
    /// which the suite sails since #231; skiff@2 since #89, skiff@3 since #263, skiff@4 since #298, skiff@5 since its follow-up,
    /// skiff@6 since #377, skiff@7, the autohelm off, since #437, skiff@8, tacking by hand, since #461), the venue and conditions named by their bundled files.
    /// With `cell.autohelmOff`, the class is the default's copy with the autohelm off a centred rudder (`handSteered`,
    /// #435), which `raceFiles(for:)` resolves; on skiff@7 or skiff@8, whose autohelm is already off, that is the bundled class.
    public static func raceSetup(for cell: BotRaceCell) throws -> RaceSetup {
        let venue = try dataFileKey(cell.venue)
        let conditions = try dataFileKey(cell.conditions)
        let boatClass = cell.autohelmOff == true ? try handSteered(RaceFiles.defaults.boatClass).ref : RaceFiles.defaults.boatClass.ref
        return try RaceSetup(
            raceSeed: RaceSeed(cell.seed),
            seats: Array(repeating: .bot, count: cell.fleetSize),
            laps: cell.laps,
            boatClass: boatClass,
            venue: VenueFile.bundled(id: venue.id, version: venue.version).ref,
            conditions: ConditionsFile.bundled(id: conditions.id, version: conditions.version).ref
        )
    }

    /// The files `setup`, `cell`'s (`raceSetup(for:)`), names: the bundled ones, and the hand-steered copy of the class
    /// for a cell sailed with the autohelm off.
    static func raceFiles(for cell: BotRaceCell, setup: RaceSetup) throws -> RaceFiles {
        guard cell.autohelmOff == true else { return try RaceFiles(resolving: setup) }
        var catalog = RaceFileCatalog()
        try catalog.boatClasses.add(handSteered(RaceFiles.defaults.boatClass))
        return try RaceFiles(resolving: setup, from: catalog)
    }

    /// A copy of `file`, a bundled schema-3 or schema-4 class, with its autohelm off a centred rudder
    /// (`AutohelmTuning.holdsWhenCentred` false, #434), so bots sail it steering by hand (#435): its bytes headed as
    /// schema 4 with the value added to `steering.autohelm`, loaded as tune 1, in memory like a tuned copy. `file`
    /// itself when its autohelm is already off.
    public static func handSteered(_ file: BoatClassFile) throws -> BoatClassFile {
        guard file.content.steering.autohelm.holdsWhenCentred else { return file }
        let key = (id: file.ref.id, version: file.ref.version)
        guard let data = try BoatClassFile.bundledData(id: key.id, version: key.version) else {
            throw BotSuiteError.matrix("\(key.id)@\(key.version) is not bundled")
        }
        var text = String(decoding: data, as: UTF8.self)
        guard !text.contains("\"holdsWhenCentred\""), let helm = text.range(of: "\"autohelm\": {") else {
            throw BotSuiteError.matrix("\(key.id)@\(key.version): no autohelm to turn off")
        }
        text.replaceSubrange(helm, with: "\"autohelm\": { \"holdsWhenCentred\": false,")
        if let schema = text.range(of: "\"schemaVersion\": 3,") { text.replaceSubrange(schema, with: "\"schemaVersion\": 4,") }
        let copy = try BoatClassFile(data: Data(text.utf8), tune: 1)
        guard !copy.content.steering.autohelm.holdsWhenCentred else {
            throw BotSuiteError.matrix("\(key.id)@\(key.version): the autohelm didn't turn off")
        }
        return copy
    }

    /// Sails `cell` with the cautious bot and the set skills its profile mix gives (`BotRaceCell.cautiousSeats`,
    /// `seatSkills`): none but in the cautious (#105), rivals and rank-stability mixes.
    public static func run(_ cell: BotRaceCell) throws -> RaceResult {
        try run(cell, cautiousSeats: cell.cautiousSeats, seatSkills: cell.seatSkills)
    }

    /// Sails `cell`, with the cautious bot (#104, `BotDriver.cautious`) in `cautiousSeats` in place of the cell's bots:
    /// a dropped player's boat among them, from the start. Her metrics give her seat's tier as the cell's. `events`
    /// sees the race after each tick and that tick's events as the tally does: for tests that look for one kind of
    /// call, or the state behind it (#346). The seats in `seatSkills` sail at the skill given there
    /// (`BotDriver(seat:raceSeed:skill:)`, as the app's practice rivals do, #235) in place of the cell's draw; their
    /// metrics still give the cell's tier for the seat.
    public static func run(_ cell: BotRaceCell, cautiousSeats: Set<Int>, seatSkills: [Int: Double] = [:],
                           events: (Race, [RaceEvent]) -> Void = { _, _ in }) throws -> RaceResult {
        let setup = try raceSetup(for: cell)
        // Assembled as the server assembles a race (#81): the files the setup names, the race of record.
        let race = try Race(setup: setup, files: raceFiles(for: cell, setup: setup),
                            mode: .authoritative(windSeed: windSeed(for: cell.seed)))
        let tiers = setup.seats.indices.map { cell.tierMix.tier(ofSeat: $0, raceSeed: setup.raceSeed) }
        let profiles = setup.seats.indices.map { cell.profile(ofSeat: $0) }
        var controllers = SeatControllers(tiers.indices.map {
            if cautiousSeats.contains($0) { return .dropped(.cautious(seat: $0, raceSeed: setup.raceSeed)) }
            if let skill = seatSkills[$0] {
                return .bot(BotDriver(seat: $0, raceSeed: setup.raceSeed, skill: skill, profile: profiles[$0]))
            }
            return .bot(cell.tierMix.driver(seat: $0, raceSeed: setup.raceSeed, profile: profiles[$0]))
        })
        var tally = RaceTally(race: race)
        // #355: in a hunters race, every rule call (offender and victim), and the ticks each hunter turned at a boat she hunted.
        let hunterSeats = cell.profileMix == .hunters ? profiles.indices.filter { profiles[$0] == .hunter } : []
        var hunts = cell.profileMix == .hunters ? HuntTally(hunters: hunterSeats, race: race) : nil
        // #105: in a race with the tactician and the baseline, each pair's lead at their first cross after the gun.
        var crosses = StartCrossTally(race: race, tacticians: profiles.indices.filter { profiles[$0] == .tactician },
                                      baselines: profiles.indices.filter { profiles[$0] == .baseline })
        let lastTick = cell.capSecondsAfterGun * Race.tickRate
        var tickMs: [Double] = []
        tickMs.reserveCapacity(setup.startSequenceTicks + lastTick)
        let clock = ContinuousClock()
        let cpuStart = threadCPUSeconds()
        while !race.isOver && race.tick < lastTick {
            let start = clock.now
            controllers.drive(race)
            race.step()
            tickMs.append(milliseconds(start.duration(to: clock.now)))
            let drained = race.drainEvents()
            events(race, drained)
            tally.record(race, events: drained)
            hunts?.record(race, events: drained, controllers: controllers)
            crosses?.record(race)
        }
        let seats = tiers.indices.map { seat in
            var metrics = tally.metrics(seat: seat, of: race, tier: tiers[seat], profile: profiles[seat],
                                        style: controllers[seat].driver?.style, cautious: cautiousSeats.contains(seat))
            // #337: her fleet tactics' taps and pre-start luffs, and a live bot's engagement, by which they're banded.
            if let driver = controllers[seat].driver {
                metrics.leeBowTaps = driver.leeBowTaps
                metrics.tackOnWindTaps = driver.tackOnWindTaps
                metrics.coverTaps = driver.coverTaps
                metrics.startLuffDecisions = driver.startLuffDecisions
                if profiles[seat] == nil, !cautiousSeats.contains(seat) { metrics.engagement = driver.style.engagement }
                metrics.handling = driver.handling
            }
            return metrics
        }
        var result = RaceResult(cell: cell, finalTick: race.tick, capped: !race.isOver,
                                tideStateAtGun: race.tideStateAtGun, seats: seats,
                                ranks: race.boats.indices.map(race.place(of:)), hullLength: race.boatClass.hull.length,
                                timings: TickTimings(samples: tickMs, cpuSeconds: threadCPUSeconds() - cpuStart))
        result.ruleCalls = hunts?.calls
        result.hunterTurnTicks = hunts?.turnTicks
        result.hunterTurns = hunts.map {
            HunterTurns(radians: $0.turnRadians, ticksOverCourseChangeRate: $0.turnTicksOverRate, peakRate: $0.turnPeakRate,
                        courseChangeRate: $0.courseChangeRate)
        }
        result.rule161 = tally.rule161
        result.skillGap?.startGainLengths = crosses?.meanLead
        return result
    }

    /// Sails reference race `n` (#367, `ReferenceRegatta.race(_:)`, 1-based) with `standIn` in seat 0 and the file's
    /// bots in the rest, all built by `ReferenceRace`: the race the app's `-referenceRace <n>` sails, with only the
    /// helm in seat 0 differing. Stops at the race's close or `capSecondsAfterGun` after the gun.
    public static func runReference(_ n: Int, standIn: StandIn,
                                    capSecondsAfterGun: Int = BotMatrix.defaultCapSecondsAfterGun) throws -> ReferenceResult {
        let reference = ReferenceRegatta.race(n)
        let race = try reference.race()
        var controllers = reference.controllers(standIn: standIn)
        let lastTick = capSecondsAfterGun * Race.tickRate
        while !race.isOver && race.tick < lastTick {
            controllers.drive(race)
            race.step()
        }
        return ReferenceResult(number: n, standIn: standIn, finalTick: race.tick, capped: !race.isOver,
                               places: race.boats.indices.map(race.place(of:)), results: race.results,
                               digest: race.digest())
    }

    /// CPU time the calling thread has used, seconds: what a race costs, however busy the machine.
    /// POSIX `clock_gettime`, on Darwin and Linux alike.
    static func threadCPUSeconds() -> Double {
        var now = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &now)
        return Double(now.tv_sec) + Double(now.tv_nsec) / 1e9
    }

    static func milliseconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
    }
}

/// A hunters race's own tally (#355): every rule call, offender and victim, and the ticks a hunter held her hunting
/// branch's turn at a boat (`BotDriver.isHuntingTurn`: a luff, or a turn bringing a boat that must keep clear of her
/// closer), racing: so a scan of the mix can tell she hunted at all. Her other ticks (holding course, keeping clear,
/// tacking, rounding) aren't counted. And how she turned on those ticks (#472), as rule 16.1's course-change test reads
/// a turn (`EscapeSimulation`: her heading's change over the tick, a second's worth): how far in all, the ticks faster
/// than the rules' rate (`incidents.escape.changesCourse`), and the fastest.
struct HuntTally {
    let hunters: [Int]
    private(set) var calls: [RuleCallRecord] = []
    private(set) var turnTicks = 0
    private(set) var turnRadians = 0.0
    private(set) var turnTicksOverRate = 0
    private(set) var turnPeakRate = 0.0
    /// Each hunter's heading after the tick before.
    private var headings: [Double]
    let courseChangeRate: Double?

    init(hunters: [Int], race: Race) {
        self.hunters = hunters
        headings = hunters.map { race.boats[$0].heading }
        courseChangeRate = race.rules.incidents.escape.changesCourse
    }

    /// After a tick: its events, and the hunters' decisions held through it (`controllers`).
    mutating func record(_ race: Race, events: [RaceEvent], controllers: SeatControllers) {
        for event in events {
            guard case .ruleCall(let call) = event.kind else { continue }
            calls.append(RuleCallRecord(rule: call.rule.rawValue, offender: call.offender, victim: call.victim, tick: call.tick))
        }
        for (index, seat) in hunters.enumerated() {
            let heading = race.boats[seat].heading
            defer { headings[index] = heading }
            guard race.boats[seat].status == .racing, controllers[seat].driver?.isHuntingTurn == true else { continue }
            let turned = abs(wrapAngle(heading - headings[index]))
            let rate = turned * Double(Race.tickRate)
            turnTicks += 1
            turnRadians += turned
            turnPeakRate = max(turnPeakRate, rate)
            if let courseChangeRate, rate > courseChangeRate { turnTicksOverRate += 1 }
        }
    }
}

/// A race's tactician–baseline crosses (#105, `RaceSkillGap.startGainLengths`): how far the tactician seat of each pair
/// was ahead of the baseline seat, along the course axis in hull lengths, at the first tick after the gun their tracks
/// cross (the orchestrator's ruling on #105): her offset across the course from the baseline changes sign, one passing
/// ahead of or behind the other. Looked for while both sail their first leg; a pair that never crosses on it takes
/// its lead at `fallbackSeconds` after the gun instead.
struct StartCrossTally {
    private let pairs: [(tactician: Int, baseline: Int)]
    private let upwind: Vec2
    private let hullLength: Double
    private var sides: [Double?]
    private var leads: [Double?]
    private var fallbacks: [Double?]

    /// Seconds after the gun a pair that hasn't crossed takes its lead at.
    static let fallbackSeconds = 60

    /// Nil without a tactician and a baseline seat.
    init?(race: Race, tacticians: [Int], baselines: [Int]) {
        guard !tacticians.isEmpty, !baselines.isEmpty else { return nil }
        pairs = tacticians.flatMap { t in baselines.map { (t, $0) } }
        upwind = race.course.upwind
        hullLength = race.boatClass.hull.length
        sides = Array(repeating: nil, count: pairs.count)
        leads = sides
        fallbacks = sides
    }

    /// After a tick.
    mutating func record(_ race: Race) {
        guard race.tick >= 0 else { return }
        let atFallback = race.tick == Self.fallbackSeconds * Race.tickRate
        for (i, pair) in pairs.enumerated() where leads[i] == nil {
            let t = race.boats[pair.tactician], b = race.boats[pair.baseline]
            let offset = t.position - b.position
            let lead = offset.dot(upwind) / hullLength
            if atFallback { fallbacks[i] = lead }
            guard t.isOnCourse, b.isOnCourse, t.legIndex == 0, b.legIndex == 0 else {
                sides[i] = nil
                continue
            }
            let side = offset.dot(upwind.rightPerp)
            if let previous = sides[i], previous * side <= 0, previous != 0 { leads[i] = lead }
            sides[i] = side
        }
    }

    /// The mean over the pairs of each one's lead at its cross, or at `fallbackSeconds`; nil when none has either.
    var meanLead: Double? {
        let values = pairs.indices.compactMap { leads[$0] ?? fallbacks[$0] }
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}

/// Counts, tick by tick, what each seat did.
struct RaceTally {
    private let noGo: Double
    private let area: RaceArea
    private var ironsTicks: [Int]
    /// Ticks before the gun in irons (#99), as `ironsTicks` counts them racing.
    private var preGunIronsTicks: [Int]
    private var edgeTicks: [Int]
    /// Ticks on the water (`Boat.isOnCourse`), which `edgeTicks` counts among (#100).
    private var onCourseTicks: [Int]
    private var markContacts: [Int]
    private var landContacts: [Int]
    private var boundaryContacts: [Int]
    private var foulsAsOffender: [Int]
    /// Each seat's rule calls as the offender, by the rule called (`RacingRule.rawValue`) (#342).
    private var callsByRule: [[String: Int]]
    /// Each seat's rule calls as the offender before her first rounding: on her first leg, or before her start (#342).
    private var callsBeforeFirstRounding: [Int]
    /// Of `callsByRule`, the calls made before the gun (tick < 0), and those made while she owed a turn already: two or
    /// more owed after the step, as `record` sees it (a cascade, #351). By rule.
    private var preStartCallsByRule: [[String: Int]]
    private var cascadeCallsByRule: [[String: Int]]
    /// Each seat's tacks while racing, penalty turns aside (#342).
    private var racingTacks: [Int]
    private var disqualifications: [Int]
    private var ocsNotices: [Int]
    /// Each seat's boat contacts, oldest first: the id of the incident each one belongs to (the one it
    /// opened, or the pair's still open), if any.
    private var contacts: [[Int?]]
    /// Each pair's open encounter (#101): whether a rule call has been made between them during it. Opened when the
    /// pair comes within `encounterDistance` while rules 10–13 name one of them to keep clear (`Race.rightOfWay`),
    /// closed once their hulls are further apart than that again.
    private var openEncounters: [SeatPair: Bool] = [:]
    /// The open encounters begun before the gun (#280, #234's ruling 6: fouls split before and after the gun).
    private var preStartPairs: Set<SeatPair> = []
    private var preStartEncounters: [Int]
    private var preStartEncountersEndingInFouls: [Int]
    /// Each seat's encounters begun, and those that ended in a rule call.
    private var encounters: [Int]
    private var encountersEndingInFouls: [Int]
    /// Hulls closer than this are in an encounter, metres: the rules configuration's separation (#88), 2 hull lengths.
    private let encounterDistance: Double
    private let outline: [Vec2]
    /// The furthest any point of a hull lies from its centre, metres.
    private let hullRadius: Double
    /// Which legs are beats: those rounding the windward mark.
    private let isBeat: [Bool]
    /// Which legs are runs (#105): those to the leeward gate or the finish.
    private let isRun: [Bool]
    /// Each seat's runs sailed, in order (#105).
    private var runs: [[RunSplit]]
    /// The 16.1 watchdog (#228, #105).
    private var watchdog: Rule161Watchdog
    var rule161: Rule161Calls { watchdog.calls }
    private let upwind: Vec2
    /// Where each racing seat entered the leg she's sailing: the leg, the tick and her position.
    private var legEntries: [(leg: Int, tick: Int, position: Vec2)?]
    /// Each seat's tacks since she entered that leg (#238), penalty turns aside.
    private var legTacks: [Int]
    /// Each seat's beats sailed, in order.
    private var beats: [[BeatSplit]]
    private let startLine: CourseLayout.Line
    /// Close encounters (#234), racing: what fleet tactics make of the boats around her. Hull lengths, centre to
    /// centre, inside which two boats on opposite tacks cross (`closeEncounterDistance`), and the pairs inside it now.
    private let closeEncounterDistance: Double
    private var closePairs: Set<SeatPair> = []
    private var crossings: [Int]
    /// Ticks each seat (the first index) has sailed in one caster's shadow or backwind (the second) under
    /// `RaceTally.shadowFactor`, unbroken; an episode counts once it reaches `RaceTally.shadowSeconds`.
    private var shadowTicks: [[Int]]
    private var shadowGiven: [Int]
    private var shadowReceived: [Int]
    /// The tick each seat last tacked, penalty turns aside; and her tacks that covered a boat (`recordCover`).
    private var lastTackTicks: [Int?]
    private var covers: [Int]
    /// Where along the start line each seat's start-row slot lies (#35): `lineSpot` of where she began.
    private let rowSpots: [Double]
    /// Each seat's start (#85), once she has made it: the tick she crossed the line from the pre-start
    /// side after the gun, and where along it she was.
    private var starts: [(tick: Int, spot: Double)?]

    init(race: Race) {
        noGo = BoatDynamics.noGoAngle(race.boatClass.polar)
        area = race.course.raceArea
        let zeros = Array(repeating: 0, count: race.boats.count)
        ironsTicks = zeros
        preGunIronsTicks = zeros
        edgeTicks = zeros
        onCourseTicks = zeros
        markContacts = zeros
        landContacts = zeros
        boundaryContacts = zeros
        foulsAsOffender = zeros
        callsByRule = Array(repeating: [:], count: race.boats.count)
        callsBeforeFirstRounding = zeros
        preStartCallsByRule = Array(repeating: [:], count: race.boats.count)
        cascadeCallsByRule = Array(repeating: [:], count: race.boats.count)
        racingTacks = zeros
        disqualifications = zeros
        ocsNotices = zeros
        contacts = Array(repeating: [], count: race.boats.count)
        encounters = zeros
        encountersEndingInFouls = zeros
        preStartEncounters = zeros
        preStartEncountersEndingInFouls = zeros
        encounterDistance = race.rules.incidents.separation.metres(hullLength: race.boatClass.hull.length)
        outline = race.boatClass.hull.outline
        hullRadius = race.boatClass.hull.outline.reduce(0) { max($0, $1.length) }
        isBeat = race.course.legs.map { $0 == .round(CourseLayout.windwardIndex) }
        isRun = race.course.legs.map { $0 == .round(CourseLayout.gateIndex) || $0 == .finish }
        runs = Array(repeating: [], count: race.boats.count)
        let escape = race.rules.incidents.escape
        watchdog = Rule161Watchdog(seats: race.boats.count,
                                   windowTicks: RulesConfig.ticks(escape.horizon) + escape.startTickOffset)
        upwind = race.course.upwind
        legEntries = Array(repeating: nil, count: race.boats.count)
        legTacks = zeros
        beats = Array(repeating: [], count: race.boats.count)
        let line = race.course.startLine
        startLine = line
        rowSpots = race.boats.map { lineSpot($0.position, on: line) }
        starts = Array(repeating: nil, count: race.boats.count)
        closeEncounterDistance = race.boatClass.hull.length * RaceTally.crossingLengths
        crossings = zeros
        shadowTicks = Array(repeating: zeros, count: race.boats.count)
        shadowGiven = zeros
        shadowReceived = zeros
        lastTackTicks = Array(repeating: nil, count: race.boats.count)
        covers = zeros
    }

    /// Hull lengths, centre to centre, inside which two boats on opposite tacks cross (#234: "crossings within 3 hull
    /// lengths").
    static let crossingLengths = 3.0
    /// A boat whose wind one caster's shadow or backwind leaves under this factor is in it (#234), as a bot reads
    /// dirty air (`BotBrain.dirtyAir`) ...
    static let shadowFactor = 0.85
    /// ... and an episode of it counts once it lasts this long, seconds: a boat sailing through a ribbon doesn't.
    static let shadowSeconds = 2.0
    /// A tack covers a boat (#234) that tacked onto the same tack this many seconds before or less ...
    static let coverSeconds = 10.0
    /// ... within this many hull lengths, behind her up the course.
    static let coverLengths = 10.0

    /// Call once after each `race.step()`, with the events it emitted.
    mutating func record(_ race: Race, events: [RaceEvent]) {
        let near = openEncounters(race)
        for seat in race.boats.indices {
            watchdog.note(seat: seat, held: race.heldInputs[seat], tapping: race.boats[seat].autohelm?.isTapping == true,
                          tick: race.tick)
        }
        for event in events {
            switch event.kind {
            case .ocsNotice(let seat): ocsNotices[seat] += 1
            case .ruleCall(let call):
                if call.rule == .changingCourse { watchdog.record(offender: call.offender, tick: call.tick) }
                foulsAsOffender[call.offender] += 1
                callsByRule[call.offender][call.rule.rawValue, default: 0] += 1
                if call.leg == 0 { callsBeforeFirstRounding[call.offender] += 1 }
                if race.tick < 0 { preStartCallsByRule[call.offender][call.rule.rawValue, default: 0] += 1 }
                if race.boats[call.offender].penaltyTurnsOwed >= 2 {
                    cascadeCallsByRule[call.offender][call.rule.rawValue, default: 0] += 1
                }
                recordFoul(SeatPair(call.offender, call.victim), race)
            case .markTouch(let seat, _): markContacts[seat] += 1
            case .obstructionContact(let seat, .land): landContacts[seat] += 1
            case .obstructionContact(let seat, .boundary): boundaryContacts[seat] += 1
            case .disqualified(let seat, _): disqualifications[seat] += 1
            case .tacked(let seat) where !race.boats[seat].isTakingPenalty:
                legTacks[seat] += 1
                if race.boats[seat].status == .racing { racingTacks[seat] += 1 }
                recordCover(race, seat: seat)
            case .started(let seat): starts[seat] = (race.tick, lineSpot(race.boats[seat].position, on: startLine))
            case .contact(let pair):
                // A contact opens an incident for the pair, or touches again inside the one still open
                // (#88: one per pair until they separate): either way the pair's latest. A near miss opens
                // one with no contact, so it counts in `foulsAsOffender` only.
                let id = race.incidents.latest(between: pair.low, and: pair.high)?.id
                contacts[pair.low].append(id)
                contacts[pair.high].append(id)
            default: break
            }
        }
        openEncounters = openEncounters.filter { near.contains($0.key) }
        preStartPairs = preStartPairs.filter { near.contains($0) || openEncounters[$0] != nil }
        for (seat, boat) in race.boats.enumerated() {
            if !boat.isTakingPenalty && boat.twa < noGo && boat.speed < BotRaceHarness.ironsSpeed {
                if boat.status == .racing { ironsTicks[seat] += 1 }
                if boat.status == .prestart && race.tick < 0 { preGunIronsTicks[seat] += 1 }
            }
            if boat.isOnCourse {
                onCourseTicks[seat] += 1
                if area.inset(boat.position) < BotRaceHarness.edgeMargin { edgeTicks[seat] += 1 }
            }
            recordLeg(seat, boat, tick: race.tick)
        }
        recordCloseEncounters(race)
    }

    /// A tack of `seat`'s, racing, onto the tack of a boat behind her up the course within `coverLengths` that tacked
    /// onto it `coverSeconds` before or less: she covers it (#234). Counted for her, once a tack.
    private mutating func recordCover(_ race: Race, seat: Int) {
        defer { lastTackTicks[seat] = race.tick }
        let boats = race.boats
        let boat = boats[seat]
        guard boat.status == .racing else { return }
        let reach = race.boatClass.hull.length * RaceTally.coverLengths
        let recent = Int(RaceTally.coverSeconds * Double(Race.tickRate))
        for other in boats.indices where other != seat && !boats[other].isGhost && boats[other].status == .racing {
            guard let tacked = lastTackTicks[other], race.tick - tacked <= recent, boats[other].tack == boat.tack else { continue }
            let offset = boats[other].position - boat.position
            guard offset.length <= reach, offset.dot(upwind) < 0 else { continue }
            covers[seat] += 1
            return
        }
    }

    /// Crossings and shadow episodes this tick (#234), between racing boats: a pair on opposite tacks coming within
    /// `closeEncounterDistance` crosses, once until they are further apart again; a boat whose wind one caster leaves
    /// under `shadowFactor` for `shadowSeconds` unbroken has an episode of shadow given (the caster's) and received.
    private mutating func recordCloseEncounters(_ race: Race) {
        let boats = race.boats
        let racing = boats.map { $0.status == .racing && !$0.isGhost }
        var close: Set<SeatPair> = []
        for a in boats.indices where racing[a] {
            for b in (a + 1)..<boats.count where racing[b] {
                guard (boats[a].position - boats[b].position).length <= closeEncounterDistance else { continue }
                let pair = SeatPair(a, b)
                if closePairs.contains(pair) {
                    close.insert(pair)
                } else if boats[a].tack != boats[b].tack {
                    close.insert(pair)
                    crossings[a] += 1
                    crossings[b] += 1
                }
            }
        }
        closePairs = close
        let cones = boats.indices.map { racing[$0] ? race.shadowCone(ofSeat: $0) : nil }
        let episode = Int(RaceTally.shadowSeconds * Double(Race.tickRate))
        for receiver in boats.indices {
            for caster in boats.indices where caster != receiver {
                // Her ribbons (#377) and her backwind's loss (none for a class with a header, whose backwind turns
                // the wind instead).
                guard racing[receiver], let cone = cones[caster],
                      (1 - race.wake.loss(of: caster, at: boats[receiver].position, tick: race.tick))
                        * cone.factor(at: boats[receiver].position) < RaceTally.shadowFactor else {
                    shadowTicks[receiver][caster] = 0
                    continue
                }
                shadowTicks[receiver][caster] += 1
                if shadowTicks[receiver][caster] == episode {
                    shadowReceived[receiver] += 1
                    shadowGiven[caster] += 1
                }
            }
        }
    }

    /// Opens an encounter (#101, the owner's 2026-09-27 definition) for each pair within `encounterDistance` of each
    /// other, hull to hull, while rules 10–13 name one of them to keep clear (`Race.rightOfWay`: neither a ghost), and
    /// none open; returns every such pair, the ones whose encounters stay open.
    private mutating func openEncounters(_ race: Race) -> Set<SeatPair> {
        let boats = race.boats
        var hulls = [[Vec2]?](repeating: nil, count: boats.count)
        func hull(_ seat: Int) -> [Vec2] {
            if let hull = hulls[seat] { return hull }
            let hull = boats[seat].hull(outline: outline)
            hulls[seat] = hull
            return hull
        }
        var near: Set<SeatPair> = []
        for a in boats.indices where !boats[a].isGhost {
            for b in (a + 1)..<boats.count where !boats[b].isGhost {
                guard (boats[a].position - boats[b].position).length <= encounterDistance + 2 * hullRadius,
                      Collision.distance(convex: hull(a), simplePolygon: hull(b)) <= encounterDistance,
                      race.rightOfWay(a, b) != nil else { continue }
                let pair = SeatPair(a, b)
                near.insert(pair)
                if openEncounters[pair] == nil {
                    openEncounters[pair] = false
                    encounters[a] += 1
                    encounters[b] += 1
                    if race.tick < 0 {
                        preStartPairs.insert(pair)
                        preStartEncounters[a] += 1
                        preStartEncounters[b] += 1
                    }
                }
            }
        }
        return near
    }

    /// A rule call between `pair`'s boats: their encounter ends in a foul, once however many calls it holds. A call
    /// with no encounter open (never seen: the boats were too far apart) counts as an encounter of its own.
    private mutating func recordFoul(_ pair: SeatPair, _ race: Race) {
        guard openEncounters[pair] != true else { return }
        if openEncounters[pair] == nil {
            encounters[pair.low] += 1
            encounters[pair.high] += 1
            if race.tick < 0 {
                preStartPairs.insert(pair)
                preStartEncounters[pair.low] += 1
                preStartEncounters[pair.high] += 1
            }
        }
        openEncounters[pair] = true
        encountersEndingInFouls[pair.low] += 1
        encountersEndingInFouls[pair.high] += 1
        if preStartPairs.contains(pair) {
            preStartEncountersEndingInFouls[pair.low] += 1
            preStartEncountersEndingInFouls[pair.high] += 1
        }
    }

    /// A beat ends when she moves on from it, and a leg begins as she starts or rounds into it. Her tacks
    /// count from the leg's beginning, so none she made before her start does.
    private mutating func recordLeg(_ seat: Int, _ boat: Boat, tick: Int) {
        guard boat.status == .racing || boat.status == .finished else { return }
        let entry = legEntries[seat]
        let leg = boat.status == .finished ? isBeat.count : boat.legIndex
        guard entry?.leg != leg else { return }
        if let entry, isBeat[entry.leg] {
            beats[seat].append(BeatSplit(seconds: Double(tick - entry.tick) / Double(Race.tickRate),
                                         metres: (boat.position - entry.position).dot(upwind), tacks: legTacks[seat]))
        }
        if let entry, isRun[entry.leg] {
            runs[seat].append(RunSplit(seconds: Double(tick - entry.tick) / Double(Race.tickRate),
                                       metres: (entry.position - boat.position).dot(upwind), gybes: legTacks[seat]))
        }
        legEntries[seat] = (leg, tick, boat.position)
        legTacks[seat] = 0
    }

    /// `style` is the style of the bot sailing the seat; nil for none.
    func metrics(seat: Int, of race: Race, tier: BotTier, profile: BotProfile?, style: BotStyle?,
                 cautious: Bool = false) -> SeatMetrics {
        let boat = race.boats[seat]
        let fouls = contacts[seat].filter { id in
            guard let id, case .called = race.incidents[id]?.outcome else { return false }
            return true
        }.count
        let seconds = { (ticks: Int) in Double(ticks) / Double(Race.tickRate) }
        return SeatMetrics(
            seat: seat, tier: tier, profile: profile, skill: style?.skill ?? 0, status: SeatMetrics.name(boat.status),
            finished: boat.status == .finished, place: boat.place,
            ironsSeconds: seconds(ironsTicks[seat]),
            markContacts: markContacts[seat],
            boatContacts: contacts[seat].count,
            contactsEndingInFouls: fouls,
            contactsToFoulsShare: share(fouls, of: contacts[seat].count),
            foulsAsOffender: foulsAsOffender[seat],
            dsqMissedPenalty: disqualifications[seat],
            ocsCount: ocsNotices[seat],
            edgeSeconds: seconds(edgeTicks[seat]),
            landContacts: landContacts[seat],
            boundaryContacts: boundaryContacts[seat],
            beats: beats[seat],
            preGunIronsSeconds: seconds(preGunIronsTicks[seat]),
            startSeconds: starts[seat].map { seconds($0.tick) },
            startLineSpot: starts[seat]?.spot,
            rowSpot: rowSpots[seat],
            startSpot: style?.startSpot ?? 0.5,
            onCourseSeconds: seconds(onCourseTicks[seat]),
            encounters: encounters[seat],
            encountersEndingInFouls: encountersEndingInFouls[seat],
            encountersToFoulsShare: share(encountersEndingInFouls[seat], of: encounters[seat]),
            preStartEncounters: preStartEncounters[seat],
            preStartEncountersEndingInFouls: preStartEncountersEndingInFouls[seat],
            closeEncounters: crossings[seat] + shadowGiven[seat] + shadowReceived[seat] + covers[seat],
            crossings: crossings[seat],
            shadowGiven: shadowGiven[seat],
            shadowReceived: shadowReceived[seat],
            covers: covers[seat],
            callsByRule: callsByRule[seat],
            callsBeforeFirstRounding: callsBeforeFirstRounding[seat],
            racingTacks: racingTacks[seat],
            preStartCallsByRule: preStartCallsByRule[seat],
            cascadeCallsByRule: cascadeCallsByRule[seat],
            metresToFinish: boat.status == .finished ? nil : race.distanceToFinish(of: boat),
            onLastLeg: boat.status != .finished && race.course.legs.indices.last == boat.legIndex,
            cautious: cautious,
            runs: runs[seat]
        )
    }
}

/// Where along `line` the point `p` lies, as a share of its length from the pin (0) to the committee boat
/// (1): below 0 past the pin end, above 1 past the committee boat.
func lineSpot(_ p: Vec2, on line: CourseLayout.Line) -> Double {
    let along = line.committee.position - line.pin.position
    return (p - line.pin.position).dot(along.normalized) / along.length
}

/// `part / whole`, or 0 when `whole` is 0, so a report never holds a NaN.
func share(_ part: Int, of whole: Int) -> Double {
    whole == 0 ? 0 : Double(part) / Double(whole)
}

/// The 16.1 watchdog (#228, #105): per seat, the tick she last steered (held her rudder outside
/// `Autohelm.deadBand`, as `Race` lets go of the autohelm: a rudder inside it is centred, the autohelm holding) and the
/// tick the autohelm last sailed a tack or gybe tap of hers; and the race's rule 16.1 calls so far.
struct Rule161Watchdog {
    private var lastSteeredTicks: [Int]
    private var lastTapTicks: [Int]
    /// Ticks the escape simulation behind a 16.1 call searches for the right-of-way boat's course change
    /// (`EscapeSimulation.roomVerdict`: `last - horizon - offset + 1 ... last`): its horizon plus its start offset,
    /// the call's own tick included.
    let windowTicks: Int
    private(set) var calls = Rule161Calls()

    init(seats: Int, windowTicks: Int) {
        lastSteeredTicks = Array(repeating: Int.min, count: seats)
        lastTapTicks = lastSteeredTicks
        self.windowTicks = windowTicks
    }

    /// Call each tick, after the step, with the input `seat` held on it and whether her autohelm is tapping.
    mutating func note(seat: Int, held: BoatInput, tapping: Bool, tick: Int) {
        if abs(held.rudderValue) > Autohelm.deadBand { lastSteeredTicks[seat] = tick }
        if tapping { lastTapTicks[seat] = tick }
    }

    /// A rule 16.1 call against `offender` (the right-of-way boat) on `tick`: centred if she didn't steer on any tick
    /// of the window, so the course change it called was the autohelm's; and of those, whether a tap of hers fell in it.
    mutating func record(offender: Int, tick: Int) {
        calls.calls += 1
        let windowStart = tick - windowTicks + 1
        guard lastSteeredTicks[offender] < windowStart else { return }
        calls.centredRudder += 1
        if lastTapTicks[offender] >= windowStart { calls.centredRudderWithTap += 1 }
    }
}

/// What a reference race sailed (#367, `BotRaceHarness.runReference`): every seat's place, the results if it closed,
/// and the race's state digest. Seeded throughout, so the same race and stand-in give the same result every time.
public struct ReferenceResult: Hashable, Sendable {
    public var number: Int
    public var standIn: StandIn
    public var finalTick: Int
    /// Stopped at the cap, not closed.
    public var capped: Bool
    /// Each seat's place (`Race.place(of:)`), by seat: seat 0 is the stand-in's.
    public var places: [Int]
    /// The race's results, nil if it was capped.
    public var results: RaceResults?
    public var digest: UInt64
}
