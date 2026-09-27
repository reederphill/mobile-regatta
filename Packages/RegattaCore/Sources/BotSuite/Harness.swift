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
    /// which the suite sails since #231; skiff@2 since #89), the venue and conditions named by their bundled files.
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
        let setup = try raceSetup(for: cell)
        // Assembled as the server assembles a race (#81): the files the setup names, the race of record.
        let race = try Race(setup: setup, files: RaceFiles(resolving: setup),
                            mode: .authoritative(windSeed: windSeed(for: cell.seed)))
        let tiers = setup.seats.indices.map { cell.tierMix.tier(ofSeat: $0) }
        let profiles = setup.seats.indices.map { cell.profile(ofSeat: $0) }
        var controllers = SeatControllers(tiers.indices.map {
            .bot(tiers[$0].driver(seat: $0, raceSeed: setup.raceSeed, profile: profiles[$0]))
        })
        var tally = RaceTally(race: race)
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
            tally.record(race, events: race.drainEvents())
        }
        let seats = tiers.indices.map { seat in
            tally.metrics(seat: seat, of: race, tier: tiers[seat], profile: profiles[seat],
                          skill: controllers[seat].driver?.style.skill ?? 0)
        }
        return RaceResult(cell: cell, finalTick: race.tick, capped: !race.isOver,
                          tideStateAtGun: race.tideStateAtGun, seats: seats,
                          ranks: race.boats.indices.map(race.place(of:)), hullLength: race.boatClass.hull.length,
                          timings: TickTimings(samples: tickMs, cpuSeconds: threadCPUSeconds() - cpuStart))
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

/// Counts, tick by tick, what each seat did.
struct RaceTally {
    private let noGo: Double
    private let area: RaceArea
    private var ironsTicks: [Int]
    private var edgeTicks: [Int]
    private var markContacts: [Int]
    private var landContacts: [Int]
    private var boundaryContacts: [Int]
    private var foulsAsOffender: [Int]
    private var disqualifications: [Int]
    private var ocsNotices: [Int]
    /// Each seat's boat contacts, oldest first: the id of the incident each one belongs to (the one it
    /// opened, or the pair's still open), if any.
    private var contacts: [[Int?]]
    /// Which legs are beats: those rounding the windward mark.
    private let isBeat: [Bool]
    private let upwind: Vec2
    /// Where each racing seat entered the leg she's sailing: the leg, the tick and her position.
    private var legEntries: [(leg: Int, tick: Int, position: Vec2)?]
    /// Each seat's tacks since she entered that leg (#238), penalty turns aside.
    private var legTacks: [Int]
    /// Each seat's beats sailed, in order.
    private var beats: [[BeatSplit]]

    init(race: Race) {
        noGo = BoatDynamics.noGoAngle(race.boatClass.polar)
        area = race.course.raceArea
        let zeros = Array(repeating: 0, count: race.boats.count)
        ironsTicks = zeros
        edgeTicks = zeros
        markContacts = zeros
        landContacts = zeros
        boundaryContacts = zeros
        foulsAsOffender = zeros
        disqualifications = zeros
        ocsNotices = zeros
        contacts = Array(repeating: [], count: race.boats.count)
        isBeat = race.course.legs.map { $0 == .round(CourseLayout.windwardIndex) }
        upwind = race.course.upwind
        legEntries = Array(repeating: nil, count: race.boats.count)
        legTacks = zeros
        beats = Array(repeating: [], count: race.boats.count)
    }

    /// Call once after each `race.step()`, with the events it emitted.
    mutating func record(_ race: Race, events: [RaceEvent]) {
        for event in events {
            switch event.kind {
            case .ocsNotice(let seat): ocsNotices[seat] += 1
            case .ruleCall(let call): foulsAsOffender[call.offender] += 1
            case .markTouch(let seat, _): markContacts[seat] += 1
            case .obstructionContact(let seat, .land): landContacts[seat] += 1
            case .obstructionContact(let seat, .boundary): boundaryContacts[seat] += 1
            case .disqualified(let seat, _): disqualifications[seat] += 1
            case .tacked(let seat) where !race.boats[seat].isTakingPenalty: legTacks[seat] += 1
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
        for (seat, boat) in race.boats.enumerated() {
            if boat.status == .racing && !boat.isTakingPenalty && boat.twa < noGo && boat.speed < BotRaceHarness.ironsSpeed {
                ironsTicks[seat] += 1
            }
            if boat.isOnCourse && area.inset(boat.position) < BotRaceHarness.edgeMargin {
                edgeTicks[seat] += 1
            }
            recordLeg(seat, boat, tick: race.tick)
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

    func metrics(seat: Int, of race: Race, tier: BotTier, profile: BotProfile?, skill: Double) -> SeatMetrics {
        let boat = race.boats[seat]
        let fouls = contacts[seat].filter { id in
            guard let id, case .called = race.incidents[id]?.outcome else { return false }
            return true
        }.count
        let seconds = { (ticks: Int) in Double(ticks) / Double(Race.tickRate) }
        return SeatMetrics(
            seat: seat, tier: tier, profile: profile, skill: skill, status: SeatMetrics.name(boat.status),
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
            beats: beats[seat]
        )
    }
}

/// `part / whole`, or 0 when `whole` is 0, so a report never holds a NaN.
func share(_ part: Int, of whole: Int) -> Double {
    whole == 0 ? 0 : Double(part) / Double(whole)
}
