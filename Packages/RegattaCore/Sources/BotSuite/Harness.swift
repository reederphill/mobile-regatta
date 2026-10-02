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
    /// which the suite sails since #231; skiff@2 since #89, skiff@3 since #263, skiff@4 since #298, skiff@5 since its follow-up), the venue and conditions named by their bundled files.
    public static func raceSetup(for cell: BotRaceCell) throws -> RaceSetup {
        let venue = try dataFileKey(cell.venue)
        let conditions = try dataFileKey(cell.conditions)
        return try RaceSetup(
            raceSeed: RaceSeed(cell.seed),
            seats: Array(repeating: .bot, count: cell.fleetSize),
            laps: cell.laps,
            venue: VenueFile.bundled(id: venue.id, version: venue.version).ref,
            conditions: ConditionsFile.bundled(id: conditions.id, version: conditions.version).ref
        )
    }

    public static func run(_ cell: BotRaceCell) throws -> RaceResult {
        try run(cell, cautiousSeats: [])
    }

    /// Sails `cell`, with the cautious bot (#104, `BotDriver.cautious`) in `cautiousSeats` in place of the cell's bots:
    /// a dropped player's boat among them, from the start. Her metrics give her seat's tier as the cell's. `events`
    /// sees the race after each tick and that tick's events as the tally does: for tests that look for one kind of
    /// call, or the state behind it (#346).
    public static func run(_ cell: BotRaceCell, cautiousSeats: Set<Int>,
                           events: (Race, [RaceEvent]) -> Void = { _, _ in }) throws -> RaceResult {
        let setup = try raceSetup(for: cell)
        // Assembled as the server assembles a race (#81): the files the setup names, the race of record.
        let race = try Race(setup: setup, files: RaceFiles(resolving: setup),
                            mode: .authoritative(windSeed: windSeed(for: cell.seed)))
        let tiers = setup.seats.indices.map { cell.tierMix.tier(ofSeat: $0, raceSeed: setup.raceSeed) }
        let profiles = setup.seats.indices.map { cell.profile(ofSeat: $0) }
        var controllers = SeatControllers(tiers.indices.map {
            cautiousSeats.contains($0)
                ? .dropped(.cautious(seat: $0, raceSeed: setup.raceSeed))
                : .bot(cell.tierMix.driver(seat: $0, raceSeed: setup.raceSeed, profile: profiles[$0]))
        })
        var tally = RaceTally(race: race)
        // #355: in a hunters race, every rule call (offender and victim), and the ticks each hunter turned at a boat.
        let hunterSeats = cell.profileMix == .hunters ? profiles.indices.filter { profiles[$0] == .hunter } : []
        var hunts = cell.profileMix == .hunters ? HuntTally(hunters: hunterSeats) : nil
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
            hunts?.record(race, events: drained)
        }
        let seats = tiers.indices.map { seat in
            tally.metrics(seat: seat, of: race, tier: tiers[seat], profile: profiles[seat],
                          style: controllers[seat].driver?.style)
        }
        var result = RaceResult(cell: cell, finalTick: race.tick, capped: !race.isOver,
                                tideStateAtGun: race.tideStateAtGun, seats: seats,
                                ranks: race.boats.indices.map(race.place(of:)), hullLength: race.boatClass.hull.length,
                                timings: TickTimings(samples: tickMs, cpuSeconds: threadCPUSeconds() - cpuStart))
        result.ruleCalls = hunts?.calls
        result.hunterTurnTicks = hunts?.turnTicks
        return result
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

/// A hunters race's own tally (#355): every rule call, offender and victim, and the ticks a hunter's held rudder turned
/// her towards a boat that must keep clear of her within her hunting range (`BotBrain.Hunter.rangeLengths`, 4 lengths): so
/// a scan of the mix can tell she hunted at all.
struct HuntTally {
    let hunters: [Int]
    private(set) var calls: [RuleCallRecord] = []
    private(set) var turnTicks = 0
    /// Hull lengths, centre to centre, inside which a hunter's turn at a boat counts: her hunting range.
    static let rangeLengths = 4.0

    init(hunters: [Int]) { self.hunters = hunters }

    mutating func record(_ race: Race, events: [RaceEvent]) {
        for event in events {
            guard case .ruleCall(let call) = event.kind else { continue }
            calls.append(RuleCallRecord(rule: call.rule.rawValue, offender: call.offender, victim: call.victim, tick: call.tick))
        }
        let range = race.boatClass.hull.length * Self.rangeLengths
        for seat in hunters {
            let boat = race.boats[seat]
            // Her held rudder: her own turn, not the autohelm's or a tap's.
            let rudder = race.heldInputs[seat].rudderValue
            guard boat.status == .racing, abs(rudder) > Autohelm.deadBand, boat.autohelm?.isTapping != true else { continue }
            let starboard = rudder > 0
            let turnsAtOne = race.boats.indices.contains { other in
                guard other != seat, race.rightOfWay(seat, other)?.keepClear == other else { return false }
                let offset = race.boats[other].position - boat.position
                return offset.length <= range && (offset.dot(Vec2.heading(boat.heading).rightPerp) > 0) == starboard
            }
            if turnsAtOne { turnTicks += 1 }
        }
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
    /// ... and an episode of it counts once it lasts this long, seconds: a boat sailing through a cone doesn't.
    static let shadowSeconds = 2.0
    /// A tack covers a boat (#234) that tacked onto the same tack this many seconds before or less ...
    static let coverSeconds = 10.0
    /// ... within this many hull lengths, behind her up the course.
    static let coverLengths = 10.0

    /// Call once after each `race.step()`, with the events it emitted.
    mutating func record(_ race: Race, events: [RaceEvent]) {
        let near = openEncounters(race)
        for event in events {
            switch event.kind {
            case .ocsNotice(let seat): ocsNotices[seat] += 1
            case .ruleCall(let call):
                foulsAsOffender[call.offender] += 1
                callsByRule[call.offender][call.rule.rawValue, default: 0] += 1
                if call.leg == 0 { callsBeforeFirstRounding[call.offender] += 1 }
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
                guard racing[receiver], let cone = cones[caster],
                      cone.factor(at: boats[receiver].position) < RaceTally.shadowFactor else {
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
        legEntries[seat] = (leg, tick, boat.position)
        legTacks[seat] = 0
    }

    /// `style` is the style of the bot sailing the seat; nil for none.
    func metrics(seat: Int, of race: Race, tier: BotTier, profile: BotProfile?, style: BotStyle?) -> SeatMetrics {
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
            racingTacks: racingTacks[seat]
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
