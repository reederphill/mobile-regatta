import Foundation
import RegattaBots
import RegattaCore

/// What one seat did in one race (#97). Every key is always encoded, `place` and `profile` as null when
/// there is none.
public struct SeatMetrics: Codable, Hashable, Sendable {
    public var seat: Int
    public var tier: BotTier
    /// The scripted profile she sailed (#231), or nil for a live bot.
    public var profile: BotProfile? = nil
    public var skill: Double
    /// Her handling skill (#443, `BotDriver.handling`): a live bot's, drawn apart from her skill; nil for a profile, a
    /// pinned or cautious bot, and in runs from before #443.
    public var handling: Double? = nil
    /// The boat's status at the end: prestart, ocs, racing, finished or dsq.
    public var status: String
    public var finished: Bool
    public var place: Int?
    /// Seconds racing, not taking a penalty, inside the no-go zone and slower than `BotRaceHarness.ironsSpeed`.
    public var ironsSeconds: Double
    public var markContacts: Int
    public var boatContacts: Int
    /// Of `boatContacts`, those whose incident ended in a rule call, on either boat.
    public var contactsEndingInFouls: Int
    public var contactsToFoulsShare: Double
    public var foulsAsOffender: Int
    /// Disqualified for not taking a penalty.
    public var dsqMissedPenalty: Int
    public var ocsCount: Int
    /// Seconds on the water within `BotRaceHarness.edgeMargin` of the race area's edge, or outside it.
    public var edgeSeconds: Double
    /// Obstruction contacts begun (#82): with land, and with the race area's boundary.
    public var landContacts: Int
    public var boundaryContacts: Int
    /// Each beat she sailed, in order (#231): from her start or rounding into it until she rounds out of it.
    public var beats: [BeatSplit] = []
    /// Seconds before the gun inside the no-go zone and slower than `BotRaceHarness.ironsSpeed`, not taking a
    /// penalty (#99): stalled head to wind, as `ironsSeconds` counts it racing. A hold with Ease outside the
    /// no-go zone is slow, but it isn't irons.
    public var preGunIronsSeconds: Double = 0
    /// Seconds after the gun she started, crossing the line from the pre-start side (#85); nil if she never did.
    public var startSeconds: Double? = nil
    /// Where along the start line she started, as a share of it from the pin (0) to the committee boat (1);
    /// nil if she never did.
    public var startLineSpot: Double? = nil
    /// Where along the start line her start-row slot lies (#35), on the same scale: the row reaches past
    /// both ends.
    public var rowSpot: Double = 0.5
    /// Where on the line her style means her to start (`BotStyle.startSpot`), on the same scale.
    public var startSpot: Double = 0.5
    /// Seconds on the water (`Boat.isOnCourse`: before her start, OCS or racing), the time `edgeSeconds` is counted
    /// over (#100): what the navigation gate's edge share is a share of.
    public var onCourseSeconds: Double = 0
    /// Her encounters (#101, the owner's 2026-09-27 definition): each time she and another boat came within 2 hull
    /// lengths of each other while rules 10–13 named one of them to keep clear, counted once until they separated
    /// past that again.
    public var encounters: Int = 0
    /// Of `encounters`, those during which a rule call was made between the two, on either boat.
    public var encountersEndingInFouls: Int = 0
    public var encountersToFoulsShare: Double = 0
    /// Of `encounters` and `encountersEndingInFouls`, those begun before the gun (#280; #234 reports the split).
    public var preStartEncounters: Int = 0
    public var preStartEncountersEndingInFouls: Int = 0
    /// Her close encounters racing (#234: "crossings within 3 hull lengths, shadow time given/received, covers"):
    /// `crossings + shadowGiven + shadowReceived + covers`. Not `encounters`, which counts rule relations.
    public var closeEncounters: Int = 0
    /// Each time she and a boat on the other tack came within 3 hull lengths of each other, centre to centre, counted
    /// once until they were further apart again.
    public var crossings: Int = 0
    /// Episodes of 2 s or more in which her shadow or backwind left a boat's wind under 0.85 (`shadowGiven`), and in
    /// which one boat's left hers so (`shadowReceived`).
    public var shadowGiven: Int = 0
    public var shadowReceived: Int = 0
    /// Her tacks onto the tack of a boat behind her within 10 hull lengths that had tacked onto it 10 s before or less.
    public var covers: Int = 0
    /// Her rule calls as the offender by the rule called, keyed by `RacingRule.rawValue` (#342); `foulsAsOffender`
    /// in all.
    public var callsByRule: [String: Int] = [:]
    /// Of `foulsAsOffender`, the calls made before her first rounding: on her first leg, or before her start (#342).
    public var callsBeforeFirstRounding: Int = 0
    /// Her tacks while racing, penalty turns aside (#342).
    public var racingTacks: Int = 0
    /// Of `callsByRule`, the calls before the gun, and the calls made while she already owed a turn (a cascade:
    /// two or more owed after the call), by rule (#351).
    public var preStartCallsByRule: [String: Int] = [:]
    public var cascadeCallsByRule: [String: Int] = [:]
    /// Unfinished at the race's close: metres she had to go (`Race.distanceToFinish(of:)`), and whether she was on the
    /// last leg (#351). Nil and false once finished.
    public var metresToFinish: Double?
    public var onLastLeg: Bool = false
    /// Whether the cautious bot sailed her seat (#104, #105's cautious mix): `tier` is then the cell's for the seat.
    public var cautious: Bool = false
    /// Each run she sailed, in order (#105): from her rounding into it until she rounds the gate or finishes.
    public var runs: [RunSplit] = []
    /// A live bot's engagement (`BotStyle.engagement`, #337); nil for a profile and the cautious bot.
    public var engagement: Double? = nil
    /// Her taps that played a fleet tactic (#234, `BotDriver.leeBowTaps` …), and her decisions luffing a windward boat
    /// before her start (#337, `BotDriver.startLuffDecisions`); nil for a seat no bot sailed.
    public var leeBowTaps: Int? = nil
    public var tackOnWindTaps: Int? = nil
    public var coverTaps: Int? = nil
    public var startLuffDecisions: Int? = nil

    public static let metricKeys = [
        "finished", "place", "ironsSeconds", "markContacts", "boatContacts", "contactsEndingInFouls",
        "contactsToFoulsShare", "foulsAsOffender", "dsqMissedPenalty", "ocsCount", "edgeSeconds",
        "landContacts", "boundaryContacts", "beats", "preGunIronsSeconds", "startSeconds", "startLineSpot",
        "rowSpot", "startSpot", "onCourseSeconds", "encounters", "encountersEndingInFouls", "encountersToFoulsShare",
        "preStartEncounters", "preStartEncountersEndingInFouls", "closeEncounters", "crossings", "shadowGiven", "shadowReceived", "covers",
        "callsByRule", "callsBeforeFirstRounding", "racingTacks",
        "preStartCallsByRule", "cascadeCallsByRule", "metresToFinish", "onLastLeg", "cautious", "runs",
    ]

    private enum CodingKeys: String, CodingKey {
        case seat, tier, profile, skill, handling, status, finished, place, ironsSeconds, markContacts, boatContacts
        case contactsEndingInFouls, contactsToFoulsShare, foulsAsOffender, dsqMissedPenalty, ocsCount
        case edgeSeconds, landContacts, boundaryContacts, beats
        case preGunIronsSeconds, startSeconds, startLineSpot, rowSpot, startSpot, onCourseSeconds
        case encounters, encountersEndingInFouls, encountersToFoulsShare
        case preStartEncounters, preStartEncountersEndingInFouls, closeEncounters, crossings, shadowGiven, shadowReceived, covers
        case callsByRule, callsBeforeFirstRounding, racingTacks
        case preStartCallsByRule, cascadeCallsByRule, metresToFinish, onLastLeg, cautious, runs
        case engagement, leeBowTaps, tackOnWindTaps, coverTaps, startLuffDecisions
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(seat, forKey: .seat)
        try c.encode(tier, forKey: .tier)
        try c.encode(profile, forKey: .profile)
        try c.encode(skill, forKey: .skill)
        try c.encodeIfPresent(handling, forKey: .handling)
        try c.encode(status, forKey: .status)
        try c.encode(finished, forKey: .finished)
        try c.encode(place, forKey: .place)
        try c.encode(ironsSeconds, forKey: .ironsSeconds)
        try c.encode(markContacts, forKey: .markContacts)
        try c.encode(boatContacts, forKey: .boatContacts)
        try c.encode(contactsEndingInFouls, forKey: .contactsEndingInFouls)
        try c.encode(contactsToFoulsShare, forKey: .contactsToFoulsShare)
        try c.encode(foulsAsOffender, forKey: .foulsAsOffender)
        try c.encode(dsqMissedPenalty, forKey: .dsqMissedPenalty)
        try c.encode(ocsCount, forKey: .ocsCount)
        try c.encode(edgeSeconds, forKey: .edgeSeconds)
        try c.encode(landContacts, forKey: .landContacts)
        try c.encode(boundaryContacts, forKey: .boundaryContacts)
        try c.encode(beats, forKey: .beats)
        try c.encode(preGunIronsSeconds, forKey: .preGunIronsSeconds)
        try c.encode(startSeconds, forKey: .startSeconds)
        try c.encode(startLineSpot, forKey: .startLineSpot)
        try c.encode(rowSpot, forKey: .rowSpot)
        try c.encode(startSpot, forKey: .startSpot)
        try c.encode(onCourseSeconds, forKey: .onCourseSeconds)
        try c.encode(encounters, forKey: .encounters)
        try c.encode(encountersEndingInFouls, forKey: .encountersEndingInFouls)
        try c.encode(encountersToFoulsShare, forKey: .encountersToFoulsShare)
        try c.encode(preStartEncounters, forKey: .preStartEncounters)
        try c.encode(preStartEncountersEndingInFouls, forKey: .preStartEncountersEndingInFouls)
        try c.encode(closeEncounters, forKey: .closeEncounters)
        try c.encode(crossings, forKey: .crossings)
        try c.encode(shadowGiven, forKey: .shadowGiven)
        try c.encode(shadowReceived, forKey: .shadowReceived)
        try c.encode(covers, forKey: .covers)
        try c.encode(callsByRule, forKey: .callsByRule)
        try c.encode(callsBeforeFirstRounding, forKey: .callsBeforeFirstRounding)
        try c.encode(racingTacks, forKey: .racingTacks)
        try c.encode(preStartCallsByRule, forKey: .preStartCallsByRule)
        try c.encode(cascadeCallsByRule, forKey: .cascadeCallsByRule)
        try c.encode(metresToFinish, forKey: .metresToFinish)
        try c.encode(onLastLeg, forKey: .onLastLeg)
        try c.encode(cautious, forKey: .cautious)
        try c.encode(runs, forKey: .runs)
        try c.encodeIfPresent(engagement, forKey: .engagement)
        try c.encodeIfPresent(leeBowTaps, forKey: .leeBowTaps)
        try c.encodeIfPresent(tackOnWindTaps, forKey: .tackOnWindTaps)
        try c.encodeIfPresent(coverTaps, forKey: .coverTaps)
        try c.encodeIfPresent(startLuffDecisions, forKey: .startLuffDecisions)
    }

    /// Whether her style means her to start in the line's pin third (#99).
    public var isPinStyle: Bool { startSpot < 1.0 / 3 }
    /// Whether her start-row slot is off the line's committee third, or past its committee end (#99).
    public var isFromCommitteeSlot: Bool { rowSpot > 2.0 / 3 }
    /// Whether she started in the line's pin third (#99).
    public var startedInPinThird: Bool { startLineSpot.map { $0 < 1.0 / 3 } ?? false }

    static func name(_ status: BoatStatus) -> String {
        switch status {
        case .prestart: "prestart"
        case .ocs: "ocs"
        case .racing: "racing"
        case .finished: "finished"
        case .dsq: "dsq"
        }
    }
}

/// One beat a seat sailed (#231): how long it took her, how far she made good up the course over it, and how
/// often she tacked on it (#238).
public struct BeatSplit: Codable, Hashable, Sendable {
    public var seconds: Double
    /// Metres along the course axis from where she began the beat to where she rounded out of it.
    public var metres: Double
    /// Her tacks from the beat's beginning to her rounding out of it; penalty turns aside.
    public var tacks: Int = 0
}

/// One run a seat sailed (#105): how long it took her, how far she made good down the course over it, and how often
/// she gybed on it.
public struct RunSplit: Codable, Hashable, Sendable {
    public var seconds: Double
    /// Metres along the course axis, downwind, from where she began the run to where she rounded the gate or finished.
    public var metres: Double
    /// Her gybes (and any tacks) from the run's beginning to its end; penalty turns aside.
    public var gybes: Int = 0
}

/// A leg a seat sailed, for a gain over it (`legGains`): a beat or a run.
protocol LegSplit {
    var seconds: Double { get }
    /// Metres made good along the leg's way.
    var metres: Double { get }
}

extension BeatSplit: LegSplit {}
extension RunSplit: LegSplit {}

/// Each leg's gain of `ahead` over `behind`, in leg order, hull lengths: the time `behind`'s seats took over it less
/// `ahead`'s (each side's mean over the seats that sailed it), at `behind`'s mean speed along it. A leg either side
/// didn't complete has none. `legs` gives a seat's legs of the kind: her beats, or her runs.
func legGains<Split: LegSplit>(_ ahead: [SeatMetrics], over behind: [SeatMetrics], hullLength: Double,
                               legs: (SeatMetrics) -> [Split]) -> [Double] {
    legGainSeconds(ahead, over: behind, legs: legs).map { $0.seconds * $0.speed / hullLength }
}

/// Each leg's gain of `ahead` over `behind`, as `legGains`, in seconds (#435: the time `behind`'s seats took over it
/// less `ahead`'s), with `behind`'s mean speed along it, metres per second.
func legGainSeconds<Split: LegSplit>(_ ahead: [SeatMetrics], over behind: [SeatMetrics],
                                     legs: (SeatMetrics) -> [Split]) -> [(seconds: Double, speed: Double)] {
    let legCount = (ahead + behind).map { legs($0).count }.max() ?? 0
    return (0..<legCount).compactMap { leg in
        let t = ahead.compactMap { legs($0).indices.contains(leg) ? legs($0)[leg] : nil }
        let b = behind.compactMap { legs($0).indices.contains(leg) ? legs($0)[leg] : nil }
        guard !t.isEmpty, !b.isEmpty else { return nil }
        let seconds = { (splits: [Split]) in splits.reduce(0) { $0 + $1.seconds } / Double(splits.count) }
        let baselineSeconds = seconds(b)
        let baselineSpeed = b.reduce(0) { $0 + $1.metres } / Double(b.count) / max(baselineSeconds, 1)
        return (baselineSeconds - seconds(t), baselineSpeed)
    }
}

/// A race's rule 16.1 calls (#228, #105's watchdog): all of them, those whose offender (the right-of-way boat) held her
/// rudder centred throughout the window the escape simulation read (the autohelm's course change: following a shift,
/// or a snap), and of those the ones with a tack or gybe tap of hers in the window.
public struct Rule161Calls: Codable, Hashable, Sendable {
    public var calls = 0
    public var centredRudder = 0
    public var centredRudderWithTap = 0

    public init(calls: Int = 0, centredRudder: Int = 0, centredRudderWithTap: Int = 0) {
        self.calls = calls
        self.centredRudder = centredRudder
        self.centredRudderWithTap = centredRudderWithTap
    }
}

/// Tick times over one race, milliseconds: the bots' decisions and the race step together; and the race's
/// CPU time. Kept apart from everything else in the report, since they're the only numbers that differ
/// between two runs.
public struct TickTimings: Codable, Hashable, Sendable {
    public var ticks: Int
    public var p50Ms: Double
    public var p99Ms: Double
    public var maxMs: Double
    /// CPU time the race took on its thread: the bots, the steps and the tally.
    public var cpuSeconds: Double

    public init(samples: [Double], cpuSeconds: Double) {
        self.cpuSeconds = cpuSeconds
        let sorted = samples.sorted()
        ticks = sorted.count
        p50Ms = TickTimings.percentile(50, ofSorted: sorted)
        p99Ms = TickTimings.percentile(99, ofSorted: sorted)
        maxMs = sorted.last ?? 0
    }

    /// The nearest-rank `p`th percentile of `sorted` (ascending), as `regatta-bench` takes it (#69); 0 for none.
    public static func percentile(_ p: Double, ofSorted sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }
}

/// The fleet's totals over one race.
public struct FleetMetrics: Codable, Hashable, Sendable {
    public var finished: Int
    public var finishShare: Double
    public var ironsSeconds: Double
    public var markContacts: Int
    /// Each contact once, though both boats count it.
    public var boatContacts: Int
    public var ruleCalls: Int
    public var dsqMissedPenalty: Int
    public var ocsCount: Int
    public var edgeSeconds: Double

    init(_ seats: [SeatMetrics]) {
        finished = seats.filter(\.finished).count
        finishShare = share(finished, of: seats.count)
        ironsSeconds = seats.reduce(0) { $0 + $1.ironsSeconds }
        markContacts = seats.reduce(0) { $0 + $1.markContacts }
        boatContacts = seats.reduce(0) { $0 + $1.boatContacts } / 2
        ruleCalls = seats.reduce(0) { $0 + $1.foulsAsOffender }
        dsqMissedPenalty = seats.reduce(0) { $0 + $1.dsqMissedPenalty }
        ocsCount = seats.reduce(0) { $0 + $1.ocsCount }
        edgeSeconds = seats.reduce(0) { $0 + $1.edgeSeconds }
    }
}

/// One race of the matrix: its cell, how far it sailed, each seat, the fleet, and the tick times.
public struct RaceResult: Codable, Hashable, Sendable {
    public var cell: BotRaceCell
    /// The race clock when it ended or was stopped, seconds after the gun.
    public var raceSeconds: Double
    /// Stopped at `capSecondsAfterGun` before the race closed.
    public var capped: Bool
    /// The tide state the race drew at the gun (#78), degrees through the cycle; absent at a venue
    /// without current. The race seed draws it, so the cell's `tideStateDegrees` doesn't choose it.
    public var tideStateAtGunDegrees: Double?
    public var seats: [SeatMetrics]
    public var fleet: FleetMetrics
    /// The baseline against the tactician (#231), in a race that has both; nil otherwise.
    public var skillGap: RaceSkillGap?
    /// How the profiles sailed the shifts (#238), in a race of the fun-pass mix; nil otherwise.
    public var funPass: RaceFunPass?
    /// The middle third of the fleet by rank at the end (#234), and their close encounters
    /// (`SeatMetrics.closeEncounters`), on average: what a mid-fleet boat met. Nil in a race from before #234.
    public var midFleetSeats: [Int]?
    public var midFleetCloseEncounters: Double?
    public var timings: TickTimings
    /// Every rule call in the race, oldest first, in a race of the hunters mix (#355); nil otherwise.
    public var ruleCalls: [RuleCallRecord]? = nil
    /// The ticks its hunters held their hunting turn at a boat that must keep clear of them (`HuntTally`, a luff or a
    /// turn bringing it closer), in a race of the hunters mix (#355); nil otherwise.
    public var hunterTurnTicks: Int? = nil
    /// How its hunters turned on those ticks (#472, `HuntTally`), in a race of the hunters mix; nil otherwise.
    public var hunterTurns: HunterTurns? = nil
    /// Its rule 16.1 calls, for the watchdog (#105); nil in a race not sailed by the harness.
    public var rule161: Rule161Calls? = nil
    /// The executor against the tactician at Club-level execution (#105), in a race that has both; nil otherwise.
    public var execution: RaceExecution? = nil
    /// The player stand-in against her rivals (#105), in a race of the rivals mix; nil otherwise.
    public var rivals: RaceRivals? = nil
    /// Skill against finishing order (#105), in a race of the rank-stability mix; nil otherwise.
    public var rank: RaceRank? = nil
    /// Perfect hand steering against Club's (#435), in a race of the handling mix; nil otherwise.
    public var handling: RaceHandling? = nil

    /// `ranks`: each seat's place in the race's order at the end (`Race.place(of:)`), finished or not.
    init(cell: BotRaceCell, finalTick: Int, capped: Bool, tideStateAtGun: Double?, seats: [SeatMetrics],
         ranks: [Int], hullLength: Double, timings: TickTimings) {
        self.cell = cell
        raceSeconds = Double(finalTick) / Double(Race.tickRate)
        self.capped = capped
        tideStateAtGunDegrees = tideStateAtGun.map { $0 * 180 / .pi }
        self.seats = seats
        fleet = FleetMetrics(seats)
        // The handling mix's baseline and tactician steer by hand: their gap is the handling's, not the skill gap's.
        skillGap = cell.profileMix == .handling ? nil : RaceSkillGap(seats: seats, ranks: ranks, hullLength: hullLength)
        funPass = cell.profileMix == .funPass ? RaceFunPass(seats: seats, ranks: ranks) : nil
        let middle = midFleet(ranks)
        midFleetSeats = middle
        midFleetCloseEncounters = middle.isEmpty ? nil
            : Double(middle.reduce(0) { $0 + seats[$1].closeEncounters }) / Double(middle.count)
        self.timings = timings
        execution = RaceExecution(seats: seats, ranks: ranks)
        rivals = cell.profileMix == .rivals ? RaceRivals(cell: cell, seats: seats, ranks: ranks) : nil
        rank = cell.profileMix == .rankStability ? RaceRank(seats: seats, ranks: ranks) : nil
        handling = cell.profileMix == .handling ? RaceHandling(seats: seats, hullLength: hullLength) : nil
    }
}

/// One rule call (#355): the rule (`RacingRule.rawValue`), on which seat, against which, and when.
public struct RuleCallRecord: Codable, Hashable, Sendable {
    public var rule: String
    public var offender: Int
    public var victim: Int
    public var tick: Int

    public init(rule: String, offender: Int, victim: Int, tick: Int) {
        self.rule = rule
        self.offender = offender
        self.victim = victim
        self.tick = tick
    }
}

/// The seats in the middle third of a fleet whose places at the end are `ranks` (each seat's, from 1), in seat order:
/// those whose place, counted from 0, is at least a third of the fleet and under two thirds (#234: "a mid-fleet boat").
func midFleet(_ ranks: [Int]) -> [Int] {
    let n = Double(ranks.count)
    return ranks.indices.filter { Double(ranks[$0] - 1) >= n / 3 && Double(ranks[$0] - 1) < 2 * n / 3 }
}

/// The scripted profiles of `seats` in the race's order at the end (`ranks`, each seat's place), first place
/// first: finishers, then the rest by rank. Live seats are left out.
func profileOrder(_ seats: [SeatMetrics], ranks: [Int]) -> [BotProfile] {
    seats.indices.filter { seats[$0].profile != nil }.sorted { ranks[$0] < ranks[$1] }.compactMap { seats[$0].profile }
}

/// Whether `profile` beat `other` in a race whose profiles finished in `order`, both among them: 1 when its
/// seats' mean place in `order` is ahead of the other's seats', 0 when behind, ½ for a tie.
func win(_ profile: BotProfile, over other: BotProfile, in order: [BotProfile]) -> Double {
    let meanPlace = { (profile: BotProfile) -> Double in
        let places = order.indices.filter { order[$0] == profile }
        return Double(places.reduce(0, +)) / Double(places.count)
    }
    let (a, b) = (meanPlace(profile), meanPlace(other))
    return a < b ? 1 : a > b ? 0 : 0.5
}

/// Each profile's tacks over the beats `seats` completed, and those beats, keyed by `BotProfile.rawValue`;
/// only the profiles that completed a beat.
func beatTacks(_ seats: [SeatMetrics]) -> [String: (tacks: Int, beats: Int)] {
    var tallies: [String: (tacks: Int, beats: Int)] = [:]
    for seat in seats where !seat.beats.isEmpty {
        guard let profile = seat.profile?.rawValue else { continue }
        let tally = tallies[profile] ?? (0, 0)
        tallies[profile] = (tally.tacks + seat.beats.reduce(0) { $0 + $1.tacks }, tally.beats + seat.beats.count)
    }
    return tallies
}

/// How a race's tactician seats did against its baseline seats (#231, ADR 0007: "a tactician bot clearly
/// beats a groove-only bot, or the autohelm has flattened skill").
public struct RaceSkillGap: Codable, Hashable, Sendable {
    /// The profiles in the race's order at the end, first place first: finishers, then the rest by rank.
    public var order: [BotProfile]
    /// Whether the tactician won the race: 1 when its seats' mean place in `order` is ahead of the baseline
    /// seats', 0 when behind, ½ for a tie.
    public var tacticianWin: Double
    /// Of the race's tactician–baseline pairs of seats, the share in which the tactician ranked ahead: the
    /// seat-by-seat view of the same order, which a big fleet's spread pulls towards ½.
    public var tacticianPairShare: Double
    /// Each beat's gain of the tactician over the baseline, in beat order, hull lengths: the time the baseline
    /// seats took over it less the tactician seats' (each side's mean over the seats that sailed it), at the
    /// baseline seats' mean speed up the course. A beat either side didn't complete has none.
    public var gainLengthsPerBeat: [Double]
    /// Each run's gain of the tactician over the baseline, in run order, hull lengths, as `gainLengthsPerBeat` (#105).
    public var gainLengthsPerRun: [Double] = []
    /// The tactician's lead over the baseline at their first cross after the gun (#105, `StartCrossTally`): along the
    /// course axis, hull lengths, the mean over the race's tactician–baseline pairs; nil when no pair crossed or reached
    /// the fallback.
    public var startGainLengths: Double? = nil

    /// Nil for a race without both profiles.
    init?(seats: [SeatMetrics], ranks: [Int], hullLength: Double) {
        let tacticians = seats.filter { $0.profile == .tactician }
        let baselines = seats.filter { $0.profile == .baseline }
        guard !tacticians.isEmpty, !baselines.isEmpty else { return nil }
        order = profileOrder(seats, ranks: ranks)
        tacticianWin = win(.tactician, over: .baseline, in: order)
        let wins = tacticians.reduce(0) { total, t in total + baselines.filter { ranks[t.seat] < ranks[$0.seat] }.count }
        tacticianPairShare = share(wins, of: tacticians.count * baselines.count)
        gainLengthsPerBeat = legGains(tacticians, over: baselines, hullLength: hullLength) { $0.beats }
        gainLengthsPerRun = legGains(tacticians, over: baselines, hullLength: hullLength) { $0.runs }
    }
}

/// How a fun-pass race's profiles sailed its shifts (#221, #238: "the tactician averages ≥ 4 tacks per beat;
/// a blip-tacker profile (tacks on every header > 3°) loses to the tactician").
public struct RaceFunPass: Codable, Hashable, Sendable {
    /// The profiles in the race's order at the end, first place first: finishers, then the rest by rank.
    public var order: [BotProfile]
    /// Each profile's tacks per beat over the beats its seats completed, keyed by `BotProfile.rawValue`; only
    /// the profiles that completed one.
    public var tacksPerBeat: [String: Double]
    /// Whether the tactician beat the blip-tacker: 1 when its seats' mean place in `order` is ahead of the
    /// blip-tacker seats', 0 when behind, ½ for a tie; nil for a race without both (a two-boat fleet).
    public var tacticianBeatsBlipTacker: Double?

    init(seats: [SeatMetrics], ranks: [Int]) {
        order = profileOrder(seats, ranks: ranks)
        tacksPerBeat = beatTacks(seats).mapValues { Double($0.tacks) / Double($0.beats) }
        tacticianBeatsBlipTacker = order.contains(.tactician) && order.contains(.blipTacker)
            ? win(.tactician, over: .blipTacker, in: order) : nil
    }
}

/// The fun pass over a run (#238): what `minTacticianTacksPerBeat` and `minTacticianBeatsBlipTackerShare` hold.
public struct FunPassSummary: Codable, Hashable, Sendable {
    /// Races of the fun-pass mix.
    public var races: Int
    /// Each profile's tacks per beat: its seats' tacks over the beats they completed, every fun-pass race's
    /// together, keyed by `BotProfile.rawValue`; only the profiles that completed a beat.
    public var tacksPerBeat: [String: Double]
    /// The beats behind each of those.
    public var beats: [String: Int]
    /// Races with both the tactician and the blip-tacker.
    public var blipTackerRaces: Int
    /// The share of those the tactician won (`RaceFunPass.tacticianBeatsBlipTacker`); nil when there were none.
    public var tacticianBeatsBlipTackerShare: Double?

    /// Nil when no race was of the fun-pass mix.
    init?(_ races: [RaceResult]) {
        let races = races.filter { $0.funPass != nil }
        guard !races.isEmpty else { return nil }
        self.races = races.count
        let tallies = beatTacks(races.flatMap(\.seats))
        tacksPerBeat = tallies.mapValues { Double($0.tacks) / Double($0.beats) }
        beats = tallies.mapValues(\.beats)
        let wins = races.compactMap(\.funPass?.tacticianBeatsBlipTacker)
        blipTackerRaces = wins.count
        tacticianBeatsBlipTackerShare = wins.isEmpty ? nil : wins.reduce(0, +) / Double(wins.count)
    }
}

/// The skill gap over a run (#231): what `minTacticianWinShare` and `minTacticianGainLengthsPerBeat` hold.
public struct SkillGapSummary: Codable, Hashable, Sendable {
    /// Races with both profiles.
    public var races: Int
    /// The share of those races the tactician won (`RaceSkillGap.tacticianWin`).
    public var tacticianWinShare: Double
    /// The mean over those races of each one's `RaceSkillGap.tacticianPairShare`.
    public var tacticianPairShare: Double
    /// Beats with a gain: every race's, together.
    public var beats: Int
    /// The median of those gains, hull lengths.
    public var medianGainLengthsPerBeat: Double
    /// Runs with a gain (#105): every race's, together; and their median, hull lengths (0 for none).
    public var runs: Int = 0
    public var medianGainLengthsPerRun: Double = 0
    /// Races with a lead at the first cross (#105, `RaceSkillGap.startGainLengths`), and those leads' mean, hull
    /// lengths; nil for none.
    public var startRaces: Int = 0
    public var meanStartGainLengths: Double? = nil

    /// Nil when no race had both profiles.
    init?(_ races: [RaceSkillGap]) {
        guard !races.isEmpty else { return nil }
        self.races = races.count
        tacticianWinShare = races.reduce(0) { $0 + $1.tacticianWin } / Double(races.count)
        tacticianPairShare = races.reduce(0) { $0 + $1.tacticianPairShare } / Double(races.count)
        let gains = races.flatMap(\.gainLengthsPerBeat).sorted()
        beats = gains.count
        medianGainLengthsPerBeat = median(gains)
        let runGains = races.flatMap(\.gainLengthsPerRun).sorted()
        runs = runGains.count
        medianGainLengthsPerRun = median(runGains)
        let leads = races.compactMap(\.startGainLengths)
        startRaces = leads.count
        meanStartGainLengths = leads.isEmpty ? nil : leads.reduce(0, +) / Double(leads.count)
    }
}

/// The median of `sorted` (ascending); 0 for none.
func median(_ sorted: [Double]) -> Double {
    sorted.isEmpty ? 0 : (sorted[(sorted.count - 1) / 2] + sorted[sorted.count / 2]) / 2
}

/// How a race's tactician at Club-level execution did against its executor (#222, #105: "a perfect-execution,
/// poor-tactics bot loses to a good-tactics, average-execution bot: decisions stay the main skill").
public struct RaceExecution: Codable, Hashable, Sendable {
    /// The profiles in the race's order at the end, first place first.
    public var order: [BotProfile]
    /// Whether tactics won: 1 when the tactician's seats' mean place in `order` is ahead of the executor's, 0 when
    /// behind, ½ for a tie.
    public var tacticsWin: Double

    /// Nil for a race without both profiles.
    init?(seats: [SeatMetrics], ranks: [Int]) {
        guard seats.contains(where: { $0.profile == .executor }),
              seats.contains(where: { $0.profile == .tacticianClubExecution }) else { return nil }
        order = profileOrder(seats, ranks: ranks)
        tacticsWin = win(.tacticianClubExecution, over: .executor, in: order)
    }
}

/// What steering well by hand gains over Club's hand steering (#435) for one pair of profiles in a race: `perfect`
/// over `club`, each beat and run in leg order.
public struct HandlingGain: Codable, Hashable, Sendable {
    /// Each beat's gain, seconds (`legGainSeconds`); a beat either side didn't complete has none.
    public var secondsPerBeat: [Double]
    /// Each run's gain, seconds.
    public var secondsPerRun: [Double]
    /// The same gains in hull lengths, at the Club seats' speed along the leg (`legGains`).
    public var lengthsPerBeat: [Double]
    public var lengthsPerRun: [Double]

    /// Nil unless the race has both.
    init?(_ perfect: BotProfile, over club: BotProfile, seats: [SeatMetrics], hullLength: Double) {
        let ahead = seats.filter { $0.profile == perfect }
        let behind = seats.filter { $0.profile == club }
        guard !ahead.isEmpty, !behind.isEmpty else { return nil }
        let beats = legGainSeconds(ahead, over: behind) { $0.beats }
        let runs = legGainSeconds(ahead, over: behind) { $0.runs }
        secondsPerBeat = beats.map(\.seconds)
        secondsPerRun = runs.map(\.seconds)
        lengthsPerBeat = beats.map { $0.seconds * $0.speed / hullLength }
        lengthsPerRun = runs.map { $0.seconds * $0.speed / hullLength }
    }
}

/// A handling race's dividend of steering well by hand (#435): perfect hand steering over Club's, without tactics (the
/// baseline over `clubSteering`) and with them (the tactician over `tacticianClubSteering`).
public struct RaceHandling: Codable, Hashable, Sendable {
    public var baseline: HandlingGain?
    public var tactician: HandlingGain?

    init(seats: [SeatMetrics], hullLength: Double) {
        baseline = HandlingGain(.baseline, over: .clubSteering, seats: seats, hullLength: hullLength)
        tactician = HandlingGain(.tactician, over: .tacticianClubSteering, seats: seats, hullLength: hullLength)
    }
}

/// The handling mix over a run (#435): the median gain per beat and per run of perfect hand steering over Club's, read
/// against #426's T1 (placeholders ≈ 6 s/beat, ≈ 4 s/run). Reported, not gated.
public struct HandlingSummary: Codable, Hashable, Sendable {
    /// One pair's gains over every race with both, pooled.
    public struct Medians: Codable, Hashable, Sendable {
        public var beats: Int
        public var medianSecondsPerBeat: Double
        public var medianLengthsPerBeat: Double
        public var runs: Int
        public var medianSecondsPerRun: Double
        public var medianLengthsPerRun: Double

        init(_ gains: [HandlingGain]) {
            beats = gains.reduce(0) { $0 + $1.secondsPerBeat.count }
            medianSecondsPerBeat = median(gains.flatMap(\.secondsPerBeat).sorted())
            medianLengthsPerBeat = median(gains.flatMap(\.lengthsPerBeat).sorted())
            runs = gains.reduce(0) { $0 + $1.secondsPerRun.count }
            medianSecondsPerRun = median(gains.flatMap(\.secondsPerRun).sorted())
            medianLengthsPerRun = median(gains.flatMap(\.lengthsPerRun).sorted())
        }
    }

    /// Races of the handling mix.
    public var races: Int
    /// Without tactics (the baseline over `clubSteering`), with them (the tactician over `tacticianClubSteering`), and
    /// both pooled.
    public var baseline: Medians
    public var tactician: Medians
    public var all: Medians

    /// Nil when no race was of the handling mix.
    init?(_ races: [RaceHandling]) {
        guard !races.isEmpty else { return nil }
        self.races = races.count
        let baselines = races.compactMap(\.baseline)
        let tacticians = races.compactMap(\.tactician)
        baseline = Medians(baselines)
        tactician = Medians(tacticians)
        all = Medians(baselines + tacticians)
    }
}

/// Places by each axis a bot sails on (#443): her tactics skill and her handling skill, drawn apart, so does each buy
/// places on its own? The mean place of the seats in each bucket of either axis, and in each cell of the two, for the
/// off-diagonals (a sharp tactician on a sloppy helm, and the reverse). Reported, not gated.
public struct AxesSummary: Codable, Hashable, Sendable {
    /// Seats in a bucket, those that finished, and their mean place; nil when none finished.
    public struct Places: Codable, Hashable, Sendable {
        public var seats: Int
        public var finished: Int
        public var meanPlace: Double?

        init(_ seats: [SeatMetrics]) {
            self.seats = seats.count
            let places = seats.compactMap(\.place)
            finished = places.count
            meanPlace = places.isEmpty ? nil : Double(places.reduce(0, +)) / Double(places.count)
        }
    }

    /// The buckets of each axis, worst first: their keys in `bySkill`, `byHandling` and `grid`.
    public var skillBuckets: [String]
    public var handlingBuckets: [String]
    /// Keyed by `skillBuckets`' and `handlingBuckets`' names.
    public var bySkill: [String: Places]
    public var byHandling: [String: Places]
    /// Skill bucket, then handling bucket: only cells with any seat.
    public var grid: [String: [String: Places]]

    /// `seats` bucketed on either axis by `skill` and `handling` (nil leaves a seat out), buckets named worst first.
    init?(_ seats: [SeatMetrics], skillBuckets: [String], handlingBuckets: [String],
          skill: (SeatMetrics) -> String?, handling: (SeatMetrics) -> String?) {
        let keyed = seats.compactMap { seat in skill(seat).flatMap { s in handling(seat).map { (seat, s, $0) } } }
        guard !keyed.isEmpty else { return nil }
        self.skillBuckets = skillBuckets
        self.handlingBuckets = handlingBuckets
        bySkill = Dictionary(grouping: keyed, by: \.1).mapValues { Places($0.map(\.0)) }
        byHandling = Dictionary(grouping: keyed, by: \.2).mapValues { Places($0.map(\.0)) }
        grid = Dictionary(grouping: keyed, by: \.1).mapValues { row in
            Dictionary(grouping: row, by: \.2).mapValues { Places($0.map(\.0)) }
        }
    }

    /// The live mix's live bots (#443): buckets by tier, her skill's the tier whose skill band holds it
    /// (`BotTier.holding`), her handling's the tier whose handling band's centre is nearest (the bands overlap).
    /// Nil when no live bot with a handling skill sailed.
    init?(live races: [RaceResult]) {
        let seats = races.filter { $0.cell.profileMix == .live }.flatMap(\.seats).filter { $0.profile == nil && !$0.cautious }
        let names = BotTier.allCases.map(\.rawValue)
        self.init(seats, skillBuckets: names, handlingBuckets: names,
                  skill: { BotTier.holding(skill: $0.skill).rawValue },
                  handling: { $0.handling.map { Self.handlingTier($0).rawValue } })
    }

    /// The handling mix (#435) by its two axes: tactics or none (the tactician's profiles or the baseline's), and a
    /// perfect hand or Club's. Nil when none sailed.
    init?(handlingMix races: [RaceResult]) {
        let seats = races.filter { $0.cell.profileMix == .handling }.flatMap(\.seats)
        self.init(seats, skillBuckets: ["without", "with"], handlingBuckets: ["club", "perfect"],
                  skill: { seat in
                      switch seat.profile {
                      case .baseline, .clubSteering: "without"
                      case .tactician, .tacticianClubSteering: "with"
                      default: nil
                      }
                  },
                  handling: { seat in
                      switch seat.profile {
                      case .baseline, .tactician: "perfect"
                      case .clubSteering, .tacticianClubSteering: "club"
                      default: nil
                      }
                  })
    }

    /// The tier whose handling band's centre is nearest `handling`.
    static func handlingTier(_ handling: Double) -> BotTier {
        BotTier.allCases.min { a, b in
            abs(a.handling(at: 0.5) - handling) < abs(b.handling(at: 0.5) - handling)
        } ?? .club
    }

    /// Text lines: each axis's buckets, then the grid's rows.
    func lines(skillAxis: String, handlingAxis: String) -> [String] {
        func cell(_ p: Places?) -> String {
            guard let p else { return "-" }
            return "\(p.meanPlace.map { fixed($0, 1) } ?? "-") (\(p.finished)/\(p.seats))"
        }
        var lines = ["  by \(skillAxis): " + skillBuckets.map { "\($0) \(cell(bySkill[$0]))" }.joined(separator: ", "),
                     "  by \(handlingAxis): " + handlingBuckets.map { "\($0) \(cell(byHandling[$0]))" }.joined(separator: ", ")]
        for row in skillBuckets {
            guard let cells = grid[row] else { continue }
            lines.append("  \(skillAxis) \(row), by \(handlingAxis): "
                + handlingBuckets.map { "\($0) \(cell(cells[$0]))" }.joined(separator: ", "))
        }
        return lines
    }
}

/// Execution against tactics over a run (#105): what `minTacticsBeatsExecutionShare` holds.
public struct ExecutionSummary: Codable, Hashable, Sendable {
    /// Races with both profiles.
    public var races: Int
    /// The share of them tactics won (`RaceExecution.tacticsWin`).
    public var tacticsBeatsExecutionShare: Double

    /// Nil when no race had both.
    init?(_ races: [RaceExecution]) {
        guard !races.isEmpty else { return nil }
        self.races = races.count
        tacticsBeatsExecutionShare = races.reduce(0) { $0 + $1.tacticsWin } / Double(races.count)
    }
}

/// The 16.1 watchdog over a run (#228, #105): rule 16.1 calls whose right-of-way boat held her rudder centred
/// throughout the escape window (`Rule161Calls`), over the all-National live fleets sailed in the conditions where the
/// autohelm follows the shifts fastest (`watchedConditions`, by id whatever the version): what `watchdog` holds.
public struct WatchdogSummary: Codable, Hashable, Sendable {
    /// Races of all-National live fleets in those conditions.
    public var races: Int
    /// By conditions id, every one of `watchedConditions` listed even at 0: all 16.1 calls, the centred-rudder ones the
    /// watchdog counts, and of those the ones with a tack or gybe tap in the window (reported, never gated).
    public var rule161CallsByConditions: [String: Int]
    public var centredRudder161CallsByConditions: [String: Int]
    public var centredRudderWithTap161CallsByConditions: [String: Int]
    /// The centred-rudder calls, all conditions together: what `maxCentredRudder161Calls` holds.
    public var centredRudder161Calls: Int

    /// #228: "classic-oscillating @3 and gusty-offshore @3 (the fastest shift-following)"; on main their version 7.
    public static let watchedConditions = ["classic-oscillating", "gusty-offshore"]

    /// Nil when no race was of an all-National live fleet in those conditions.
    init?(_ races: [RaceResult]) {
        let races = races.filter {
            guard $0.cell.isAllNationalLive, let id = try? dataFileKey($0.cell.conditions).id else { return false }
            return WatchdogSummary.watchedConditions.contains(id)
        }
        guard !races.isEmpty else { return nil }
        self.races = races.count
        var calls: [String: Int] = [:], centred: [String: Int] = [:], tapped: [String: Int] = [:]
        for id in WatchdogSummary.watchedConditions { (calls[id], centred[id], tapped[id]) = (0, 0, 0) }
        for race in races {
            guard let id = try? dataFileKey(race.cell.conditions).id, let counts = race.rule161 else { continue }
            calls[id, default: 0] += counts.calls
            centred[id, default: 0] += counts.centredRudder
            tapped[id, default: 0] += counts.centredRudderWithTap
        }
        rule161CallsByConditions = calls
        centredRudder161CallsByConditions = centred
        centredRudderWithTap161CallsByConditions = tapped
        centredRudder161Calls = centred.values.reduce(0, +)
    }
}

/// A rivals race (#235, #105): the player stand-in (seat 0) and her rivals (`Rivals.seats`), all at `skill`, and their
/// places in the race's order at the end, finished or not.
public struct RaceRivals: Codable, Hashable, Sendable {
    public var skill: Double
    public var seatPlace: Int
    public var rivalPlaces: [Int]

    init(cell: BotRaceCell, seats: [SeatMetrics], ranks: [Int]) {
        skill = seats[0].skill
        seatPlace = ranks[0]
        rivalPlaces = ProfileMix.rivalSeats(seed: cell.seed, fleetSize: cell.fleetSize).sorted().map { ranks[$0] }
    }
}

/// The rival pace band over a run (#235, #105): at each skill, the player stand-in's mean place and her rivals' (both
/// rivals pooled), and how far apart they are: what `rivals` holds.
public struct RivalPaceSummary: Codable, Hashable, Sendable {
    /// Races of the rivals mix.
    public var races: Int
    /// The fleet sizes they were sailed in, ascending: one in the bundled matrix (`BotMatrix.mixFleetSizes`), so the
    /// mean places aren't pooled over fleets of different sizes.
    public var fleetSizes: [Int]
    /// By skill (`fixed`, two places): the stand-in's mean place, her rivals' mean place, and the gap between them.
    public var seatMeanPlace: [String: Double]
    public var rivalMeanPlace: [String: Double]
    public var meanPlaceGap: [String: Double]
    /// The widest of those gaps: what `maxMeanPlaceGap` holds.
    public var maxMeanPlaceGap: Double

    public init(races: Int, fleetSizes: [Int] = [], seatMeanPlace: [String: Double], rivalMeanPlace: [String: Double]) {
        self.races = races
        self.fleetSizes = fleetSizes
        self.seatMeanPlace = seatMeanPlace
        self.rivalMeanPlace = rivalMeanPlace
        meanPlaceGap = seatMeanPlace.reduce(into: [:]) { gaps, entry in
            if let rival = rivalMeanPlace[entry.key] { gaps[entry.key] = abs(entry.value - rival) }
        }
        maxMeanPlaceGap = meanPlaceGap.values.max() ?? 0
    }

    /// Nil when no race was of the rivals mix.
    init?(_ races: [RaceResult]) {
        let rivals = races.compactMap(\.rivals)
        guard !rivals.isEmpty else { return nil }
        let fleetSizes = Set(races.filter { $0.rivals != nil }.map(\.cell.fleetSize)).sorted()
        var seat: [String: [Int]] = [:], rival: [String: [Int]] = [:]
        for race in rivals {
            seat[fixed(race.skill), default: []].append(race.seatPlace)
            rival[fixed(race.skill), default: []] += race.rivalPlaces
        }
        let mean = { (places: [Int]) in Double(places.reduce(0, +)) / Double(max(places.count, 1)) }
        self.init(races: rivals.count, fleetSizes: fleetSizes, seatMeanPlace: seat.mapValues(mean), rivalMeanPlace: rival.mapValues(mean))
    }
}

/// A rank-stability race (#105): each seat's skill and place in the race's order at the end, finished or not, and the
/// Spearman correlation between skill and finishing order (1: the more skilled always ahead); nil for a race whose
/// seats share one skill.
public struct RaceRank: Codable, Hashable, Sendable {
    public var skills: [Double]
    public var places: [Int]
    public var spearman: Double?

    init(seats: [SeatMetrics], ranks: [Int]) {
        skills = seats.map(\.skill)
        places = ranks
        spearman = spearmanCorrelation(skills, places.map { -Double($0) })
    }
}

/// Spearman's rank correlation of `x` and `y`: Pearson's over their ranks, ties given their mean rank; nil when either
/// has no spread.
func spearmanCorrelation(_ x: [Double], _ y: [Double]) -> Double? {
    precondition(x.count == y.count)
    func ranks(_ values: [Double]) -> [Double] {
        let order = values.indices.sorted { values[$0] < values[$1] }
        var ranks = [Double](repeating: 0, count: values.count)
        var i = 0
        while i < order.count {
            var j = i
            while j + 1 < order.count && values[order[j + 1]] == values[order[i]] { j += 1 }
            for k in i...j { ranks[order[k]] = Double(i + j) / 2 + 1 }
            i = j + 1
        }
        return ranks
    }
    let (rx, ry) = (ranks(x), ranks(y))
    let n = Double(x.count)
    guard n > 1 else { return nil }
    let (mx, my) = (rx.reduce(0, +) / n, ry.reduce(0, +) / n)
    var sxy = 0.0, sxx = 0.0, syy = 0.0
    for i in rx.indices {
        sxy += (rx[i] - mx) * (ry[i] - my)
        sxx += (rx[i] - mx) * (rx[i] - mx)
        syy += (ry[i] - my) * (ry[i] - my)
    }
    guard sxx > 0, syy > 0 else { return nil }
    return sxy / (sxx * syy).squareRoot()
}

/// Rank stability over a run (#105): a fleet of a fixed mix of skills (`ProfileMix.rankSkills`) raced over the seeds.
/// How well skill orders the finish (`meanSkillRankCorrelation`, what `rank` holds), and the luck floor: how far boats
/// of the same skill spread in one race (reported, never gated).
public struct RankSummary: Codable, Hashable, Sendable {
    /// Races of the rank-stability mix, and of them those with a correlation.
    public var races: Int
    public var correlatedRaces: Int
    /// The fleet sizes they were sailed in, ascending: one in the bundled matrix (`BotMatrix.mixFleetSizes`), so the
    /// correlation isn't averaged over fleets of different sizes.
    public var fleetSizes: [Int]
    /// The mean over those races of each one's Spearman correlation (`RaceRank.spearman`).
    public var meanSkillRankCorrelation: Double
    /// The luck floor: by skill (`fixed`, two places), the mean gap in places between two seats of that skill in one
    /// race, every such pair of every race; and over every skill together.
    public var sameSkillPlaceGap: [String: Double]
    public var meanSameSkillPlaceGap: Double?

    public init(races: Int, correlatedRaces: Int, fleetSizes: [Int] = [], meanSkillRankCorrelation: Double,
                sameSkillPlaceGap: [String: Double] = [:], meanSameSkillPlaceGap: Double? = nil) {
        self.races = races
        self.correlatedRaces = correlatedRaces
        self.fleetSizes = fleetSizes
        self.meanSkillRankCorrelation = meanSkillRankCorrelation
        self.sameSkillPlaceGap = sameSkillPlaceGap
        self.meanSameSkillPlaceGap = meanSameSkillPlaceGap
    }

    /// Nil when no race was of the rank-stability mix.
    init?(_ races: [RaceResult]) {
        let ranks = races.compactMap(\.rank)
        guard !ranks.isEmpty else { return nil }
        let correlations = ranks.compactMap(\.spearman)
        var gaps: [String: [Int]] = [:]
        for race in ranks {
            for a in race.skills.indices {
                for b in (a + 1)..<race.skills.count where race.skills[b] == race.skills[a] {
                    gaps[fixed(race.skills[a]), default: []].append(abs(race.places[a] - race.places[b]))
                }
            }
        }
        let all = gaps.values.flatMap { $0 }
        self.init(races: ranks.count, correlatedRaces: correlations.count,
                  fleetSizes: Set(races.filter { $0.rank != nil }.map(\.cell.fleetSize)).sorted(),
                  meanSkillRankCorrelation: correlations.isEmpty ? 0 : correlations.reduce(0, +) / Double(correlations.count),
                  sameSkillPlaceGap: gaps.mapValues { Double($0.reduce(0, +)) / Double($0.count) },
                  meanSameSkillPlaceGap: all.isEmpty ? nil : Double(all.reduce(0, +)) / Double(all.count))
    }
}

/// The cautious mix over a run (#104, #105): the cautious seats among live bots, reported for #389's cautious gate.
public struct CautiousSummary: Codable, Hashable, Sendable {
    /// Races of the cautious mix, and their cautious seats.
    public var races: Int
    public var seats: Int
    /// The cautious seats' rule calls as the offender, and the races in which she had one.
    public var foulsAsOffender: Int
    public var racesWithFoul: Int
    /// Mean place of the cautious seats and of the live seats beside them, a boat that didn't finish placed last.
    public var meanPlace: Double
    public var liveMeanPlace: Double

    /// Nil when no race was of the cautious mix.
    init?(_ races: [RaceResult]) {
        let races = races.filter { $0.cell.profileMix == .cautious }
        guard !races.isEmpty else { return nil }
        self.races = races.count
        var cautious: [SeatMetrics] = [], live: [Double] = [], places: [Double] = []
        for race in races {
            for seat in race.seats {
                let place = Double(seat.place ?? race.cell.fleetSize)
                if seat.cautious {
                    cautious.append(seat)
                    places.append(place)
                } else {
                    live.append(place)
                }
            }
        }
        seats = cautious.count
        foulsAsOffender = cautious.reduce(0) { $0 + $1.foulsAsOffender }
        racesWithFoul = races.filter { $0.seats.contains { $0.cautious && $0.foulsAsOffender > 0 } }.count
        meanPlace = places.reduce(0, +) / Double(max(places.count, 1))
        liveMeanPlace = live.reduce(0, +) / Double(max(live.count, 1))
    }
}

/// The start over a run (#99), over its all-National fleets of `fleetSize` live bots (`TierMix.national`,
/// `ProfileMix.live`), the fleets #99's acceptance names: what the thresholds' `start` limits hold. How cleanly and
/// on time the best bots start, and whether the pin-style ones seeded at the committee end of the row work down
/// the line to its pin third. Other fleet sizes and tiers aren't gated on their start yet (#105).
public struct StartSummary: Codable, Hashable, Sendable {
    /// Races of all-National live fleets of `fleetSize`.
    public var races: Int
    public var seats: Int
    /// The share of those seats OCS at the gun.
    public var ocsShare: Double
    /// The share of those seats that started within `onTimeSeconds` of the gun.
    public var onTimeShare: Double
    /// Seconds after the gun the seats that started took to, on average; 0 when none did.
    public var meanStartSeconds: Double
    /// Seconds in irons before the gun per seat (`SeatMetrics.preGunIronsSeconds`), on average and at most.
    public var meanPreGunIronsSeconds: Double
    public var maxPreGunIronsSeconds: Double
    /// Pin-style seats from committee slots: their style's spot in the line's pin third, their start-row slot
    /// off its committee third or past its end (`SeatMetrics.isPinStyle`, `isFromCommitteeSlot`).
    public var pinStyleFromCommitteeSeats: Int
    /// The share of those that started in the line's pin third; nil when there were none.
    public var pinThirdShare: Double?

    /// Seconds after the gun within which a start is on time (#99).
    public static let onTimeSeconds = 3.0
    /// The fleets it's taken over: ten boats.
    public static let fleetSize = 10

    /// Nil when no race was of an all-National live fleet of `fleetSize`.
    init?(_ races: [RaceResult]) {
        let races = races.filter {
            $0.cell.tierMix == .national && $0.cell.profileMix == .live && $0.cell.fleetSize == StartSummary.fleetSize
        }
        guard !races.isEmpty else { return nil }
        let seats = races.flatMap(\.seats)
        self.races = races.count
        self.seats = seats.count
        ocsShare = share(seats.filter { $0.ocsCount > 0 }.count, of: seats.count)
        let starts = seats.compactMap(\.startSeconds)
        onTimeShare = share(starts.filter { $0 <= StartSummary.onTimeSeconds }.count, of: seats.count)
        meanStartSeconds = starts.isEmpty ? 0 : starts.reduce(0, +) / Double(starts.count)
        meanPreGunIronsSeconds = seats.reduce(0) { $0 + $1.preGunIronsSeconds } / Double(max(seats.count, 1))
        maxPreGunIronsSeconds = seats.map(\.preGunIronsSeconds).max() ?? 0
        let pinStyle = seats.filter { $0.isPinStyle && $0.isFromCommitteeSlot }
        pinStyleFromCommitteeSeats = pinStyle.count
        pinThirdShare = pinStyle.isEmpty ? nil : share(pinStyle.filter(\.startedInPinThird).count, of: pinStyle.count)
    }
}

/// Navigation over a run (#100), over its all-National fleets of live bots (`TierMix.national`, `ProfileMix.live`) of
/// every size, at every venue and in every conditions they sailed: what the thresholds' `navigation` limits hold. Whether
/// the best bots sail the course cleanly: finish, turn every penalty inside its deadlines, keep off the race area's
/// edge, and keep off the marks.
public struct NavigationSummary: Codable, Hashable, Sendable {
    /// Races of all-National live fleets.
    public var races: Int
    public var seats: Int
    /// The venue × conditions pairings they sailed, each `venue × conditions` (data files as `id@version`), sorted.
    public var pairings: [String]
    /// The share of those seats that finished.
    public var finishShare: Double
    /// Their disqualifications for a penalty turn not started or completed in time (`SeatMetrics.dsqMissedPenalty`).
    public var dsqMissedPenalty: Int
    /// The share of their time on the water spent at the race area's edge: every seat's `edgeSeconds` over every
    /// seat's `onCourseSeconds`.
    public var edgeShare: Double
    /// Mark contacts per boat per race: every seat's `markContacts` over the seats.
    public var markContactsPerBoat: Double

    /// Nil when no race was of an all-National live fleet.
    init?(_ races: [RaceResult]) {
        let races = races.filter(\.cell.isAllNationalLive)
        guard !races.isEmpty else { return nil }
        let seats = races.flatMap(\.seats)
        self.races = races.count
        self.seats = seats.count
        pairings = Set(races.map { "\($0.cell.venue) × \($0.cell.conditions)" }).sorted()
        finishShare = share(seats.filter(\.finished).count, of: seats.count)
        dsqMissedPenalty = seats.reduce(0) { $0 + $1.dsqMissedPenalty }
        let onCourse = seats.reduce(0) { $0 + $1.onCourseSeconds }
        edgeShare = onCourse > 0 ? seats.reduce(0) { $0 + $1.edgeSeconds } / onCourse : 0
        markContactsPerBoat = Double(seats.reduce(0) { $0 + $1.markContacts }) / Double(max(seats.count, 1))
    }
}

/// Conduct under the rules over a run (#101), over the same all-National live fleets as navigation: what the
/// thresholds' `conduct` limits hold. Whether the best bots keep clear, and hold their rights, without a rule call: the
/// share of their encounters (`SeatMetrics.encounters`) that ended in one.
public struct ConductSummary: Codable, Hashable, Sendable {
    /// Races of all-National live fleets.
    public var races: Int
    public var seats: Int
    /// Their seats' encounters: an encounter between two of them counts for each.
    public var encounters: Int
    /// Of `encounters`, those during which a rule call was made between the two.
    public var encountersEndingInFouls: Int
    public var encountersToFoulsShare: Double

    /// Nil when no race was of an all-National live fleet.
    init?(_ races: [RaceResult]) {
        let races = races.filter(\.cell.isAllNationalLive)
        guard !races.isEmpty else { return nil }
        let seats = races.flatMap(\.seats)
        self.races = races.count
        self.seats = seats.count
        encounters = seats.reduce(0) { $0 + $1.encounters }
        encountersEndingInFouls = seats.reduce(0) { $0 + $1.encountersEndingInFouls }
        encountersToFoulsShare = share(encountersEndingInFouls, of: encounters)
    }
}

/// Close encounters over a run (#234), over the same all-National live fleets as navigation and conduct: what the
/// thresholds' `encounters` limit holds. How much racing a mid-fleet boat sees (#223: "the bot suite counts close
/// encounters per race for a mid-fleet boat"): each race's middle third by rank (`RaceResult.midFleetSeats`), their
/// close encounters on average, and the mean of that over the races.
public struct CloseEncounterSummary: Codable, Hashable, Sendable {
    /// Races of all-National live fleets.
    public var races: Int
    /// Their mid-fleet seats, all races together.
    public var midFleetSeats: Int
    /// A mid-fleet boat's close encounters per race, and their parts.
    public var closeEncountersPerRace: Double
    public var crossingsPerRace: Double
    public var shadowGivenPerRace: Double
    public var shadowReceivedPerRace: Double
    public var coversPerRace: Double

    /// Nil when no race was of an all-National live fleet.
    init?(_ races: [RaceResult]) {
        let races = races.filter(\.cell.isAllNationalLive)
        guard !races.isEmpty else { return nil }
        self.races = races.count
        let middles = races.map { race in (race.midFleetSeats ?? []).map { race.seats[$0] } }
        midFleetSeats = middles.reduce(0) { $0 + $1.count }
        func perRace(_ value: (SeatMetrics) -> Int) -> Double {
            let means = middles.map { seats in seats.isEmpty ? 0 : Double(seats.reduce(0) { $0 + value($1) }) / Double(seats.count) }
            return means.reduce(0, +) / Double(means.count)
        }
        closeEncountersPerRace = perRace(\.closeEncounters)
        crossingsPerRace = perRace(\.crossings)
        shadowGivenPerRace = perRace(\.shadowGiven)
        shadowReceivedPerRace = perRace(\.shadowReceived)
        coversPerRace = perRace(\.covers)
    }
}

/// #337: the live bots' fleet tactics by engagement band over every live race (all tiers): how often each band
/// lee-bows, tacks on a boat's wind and covers, luffs before her start, and is called. Bands: mild under 0.4,
/// middle 0.4 to 0.6, combative 0.6 and up.
public struct EngagementBandSummary: Codable, Hashable, Sendable {
    public struct Band: Codable, Hashable, Sendable {
        public var name: String
        /// Live seats in the band, all races together (seat-races).
        public var seatRaces: Int
        /// Per seat-race.
        public var leeBows: Double
        public var tacksOnWind: Double
        public var covers: Double
        /// Seconds she luffed a windward boat before her start (`SeatMetrics.startLuffDecisions`, one decision
        /// `BotDriver.decisionInterval` ticks), over every seat-race in the band, those with no luff included.
        public var startLuffSeconds: Double
        public var foulsAsOffender: Double
        public var preStartCalls: Double
    }
    public var bands: [Band]

    static let edges: [(name: String, range: Range<Double>)] = [
        ("mild", 0..<0.4), ("middle", 0.4..<0.6), ("combative", 0.6..<1.000_001),
    ]

    /// Seconds one bot decision holds (`BotDriver.decisionInterval` ticks at `Race.tickRate`).
    static let decisionSeconds = Double(BotDriver.decisionInterval) / Double(Race.tickRate)

    /// Nil when no live seat sailed.
    init?(_ races: [RaceResult]) {
        let seats = races.filter { $0.cell.profileMix == .live }.flatMap(\.seats).filter { $0.engagement != nil }
        guard !seats.isEmpty else { return nil }
        bands = Self.edges.map { edge in
            let band = seats.filter { edge.range.contains($0.engagement ?? -1) }
            func per(_ value: (SeatMetrics) -> Int) -> Double {
                band.isEmpty ? 0 : Double(band.reduce(0) { $0 + value($1) }) / Double(band.count)
            }
            return Band(name: edge.name, seatRaces: band.count, leeBows: per { $0.leeBowTaps ?? 0 },
                        tacksOnWind: per { $0.tackOnWindTaps ?? 0 }, covers: per { $0.coverTaps ?? 0 },
                        startLuffSeconds: per { $0.startLuffDecisions ?? 0 } * Self.decisionSeconds, foulsAsOffender: per(\.foulsAsOffender),
                        preStartCalls: per { $0.preStartCallsByRule.values.reduce(0, +) })
        }
    }
}

extension BotRaceCell {
    /// Whether it sails an all-National fleet of live bots: the fleets navigation (#100) and conduct (#101) are gated
    /// over.
    var isAllNationalLive: Bool { tierMix == .national && profileMix == .live }
}

/// How a race's hunters turned on their hunting-turn ticks (#472, `RaceResult.hunterTurnTicks`), read as rule 16.1's
/// course-change test reads a turn: a heading's change over a tick.
public struct HunterTurns: Codable, Hashable, Sendable {
    /// The headings' changes over those ticks, summed, radians: over the ticks' seconds, the mean rate she turned at.
    public var radians: Double
    /// The ticks she turned faster than the rules' course-change rate (`incidents.escape.changesCourse`): a turn of
    /// hers rule 16.1 can be called on.
    public var ticksOverCourseChangeRate: Int
    /// The fastest she turned on one of those ticks, radians a second.
    public var peakRate: Double
    /// The rules' course-change rate the race was sailed under, radians a second; nil under rules without one.
    public var courseChangeRate: Double?
}

/// The hunters scenario over a run (#355): how the live bots fare against hunters (`BotProfile.hunter`) that sail to
/// the edge of the rules, and how the hunters fare under them. Over the races of the hunters mix, and their live
/// twins: the same cell (seed, venue, conditions, tide, fleet, tier mix, laps) with every seat a live bot, when the run
/// sailed it (`--profile-mix live --profile-mix hunters`). The hunters' own seats are `BotSuiteReport.profiles`'s.
public struct HuntersSummary: Codable, Hashable, Sendable {
    /// Races of the hunters mix.
    public var races: Int
    /// Of those, the ones whose live twin the run sailed.
    public var twinRaces: Int
    /// Rule calls on live bots with a hunter as the right-of-way boat or the victim, by rule (`RacingRule.rawValue`).
    public var liveOnHunter: [String: Int]
    /// Rule calls on hunters with a live bot as the victim, by rule.
    public var hunterOnLive: [String: Int]
    /// Rule calls between hunters, and between live bots, by rule: the control.
    public var hunterOnHunter: [String: Int]
    public var liveOnLive: [String: Int]
    /// Calls on hunters under rule 16.1 or 17: her overdoing it. Reported, never gated.
    public var overdoneCalls: Int
    /// Ticks the hunters held their hunting turn at a boat that must keep clear of them (`RaceResult.hunterTurnTicks`):
    /// that they hunted at all.
    public var hunterTurnTicks: Int
    /// The live seats of the hunters races.
    public var live: TierSummary
    /// The same seats of the live twins; nil without twins.
    public var twinLive: TierSummary?
    /// The live seats' mean finishing place in the hunters races, ranked by order of finish among the live seats that
    /// finished only (hunters not counted), and the same seats' in their live twins, ranked among themselves; nil when
    /// none finished. Each race's ranks run 1 to its finishers, so this reads with the DNFs beside it.
    public var liveMeanPlace: Double?
    public var twinLiveMeanPlace: Double?
    /// The live seats of the hunters races that didn't finish, and the same seats of their live twins; nil without twins.
    public var liveDNFs: Int
    public var twinLiveDNFs: Int?

    /// Nil when no race was of the hunters mix.
    init?(_ races: [RaceResult]) {
        let hunted = races.filter { $0.cell.profileMix == .hunters }
        guard !hunted.isEmpty else { return nil }
        var twins: [BotRaceCell: RaceResult] = [:]
        for race in races where race.cell.profileMix == .live { twins[race.cell] = race }
        self.races = hunted.count
        var liveOnHunter: [String: Int] = [:], hunterOnLive: [String: Int] = [:]
        var hunterOnHunter: [String: Int] = [:], liveOnLive: [String: Int] = [:]
        var liveSeats: [SeatMetrics] = [], twinSeats: [SeatMetrics] = []
        var places: [Int] = [], twinPlaces: [Int] = []
        var twinRaces = 0, liveDNFs = 0, twinLiveDNFs = 0
        // Ranks by order of finish among `seats` only, 1 for the first of them home, by their places in the race; and
        // how many didn't finish.
        func ranked(_ seats: [SeatMetrics]) -> (ranks: [Int], dnfs: Int) {
            let home = seats.compactMap(\.place).sorted()
            return (home.indices.map { $0 + 1 }, seats.count - home.count)
        }
        for race in hunted {
            let isHunter = { (seat: Int) in race.seats[seat].profile == .hunter }
            for call in race.ruleCalls ?? [] {
                switch (isHunter(call.offender), isHunter(call.victim)) {
                case (false, true): liveOnHunter[call.rule, default: 0] += 1
                case (true, false): hunterOnLive[call.rule, default: 0] += 1
                case (true, true): hunterOnHunter[call.rule, default: 0] += 1
                case (false, false): liveOnLive[call.rule, default: 0] += 1
                }
            }
            let live = race.seats.filter { $0.profile == nil }
            liveSeats += live
            let (ranks, dnfs) = ranked(live)
            places += ranks
            liveDNFs += dnfs
            var twinCell = race.cell
            twinCell.profileMix = .live
            guard let twin = twins[twinCell] else { continue }
            twinRaces += 1
            let same = live.map { twin.seats[$0.seat] }
            twinSeats += same
            let (twinRanks, twinDNFs) = ranked(same)
            twinPlaces += twinRanks
            twinLiveDNFs += twinDNFs
        }
        self.twinRaces = twinRaces
        self.liveOnHunter = liveOnHunter
        self.hunterOnLive = hunterOnLive
        self.hunterOnHunter = hunterOnHunter
        self.liveOnLive = liveOnLive
        overdoneCalls = [RacingRule.changingCourse, .properCourse].reduce(0) { sum, rule in
            sum + (hunterOnLive[rule.rawValue] ?? 0) + (hunterOnHunter[rule.rawValue] ?? 0)
        }
        hunterTurnTicks = hunted.reduce(0) { $0 + ($1.hunterTurnTicks ?? 0) }
        live = TierSummary(liveSeats)
        twinLive = twinSeats.isEmpty ? nil : TierSummary(twinSeats)
        let mean = { (places: [Int]) in places.isEmpty ? nil : Double(places.reduce(0, +)) / Double(places.count) }
        liveMeanPlace = mean(places)
        twinLiveMeanPlace = mean(twinPlaces)
        self.liveDNFs = liveDNFs
        self.twinLiveDNFs = twinRaces == 0 ? nil : twinLiveDNFs
    }
}

/// One tier's seats over the whole run: what the thresholds hold it to.
public struct TierSummary: Codable, Hashable, Sendable {
    public var seats: Int
    public var finished: Int
    public var finishShare: Double
    public var meanIronsSeconds: Double
    public var maxIronsSeconds: Double
    public var meanMarkContacts: Double
    /// Seat contacts: a contact between two seats of the tier counts for each.
    public var boatContacts: Int
    public var contactsEndingInFouls: Int
    public var contactsToFoulsShare: Double
    /// Seat encounters (#101): an encounter between two seats of the tier counts for each.
    public var encounters: Int
    public var encountersEndingInFouls: Int
    /// The share of the tier's encounters during which a rule call was made (#101), for the report: the gate holds it
    /// over the all-National live fleets (`ConductSummary`), not per tier.
    public var encountersToFoulsShare: Double
    /// Of those, the ones begun before the gun, and those of them ending in a rule call (#280, #234).
    public var preStartEncounters: Int
    public var preStartEncountersEndingInFouls: Int
    public var foulsAsOffender: Int
    public var dsqMissedPenalty: Int
    public var ocsCount: Int
    public var meanEdgeSeconds: Double
    public var maxEdgeSeconds: Double
    /// The tier's rule calls as the offender by the rule called (#342), keyed by `RacingRule.rawValue`.
    public var callsByRule: [String: Int]
    /// The share of its seats called as the offender before their first rounding (#342): owing a penalty already.
    public var calledBeforeFirstRoundingShare: Double
    /// Its seats' tacks while racing, per boat (#342).
    public var racingTacksPerBoat: Double
    /// Of `callsByRule`, the calls before the gun, and the cascades: calls on a boat that already owed a turn (#351).
    public var preStartCallsByRule: [String: Int]
    public var cascadeCallsByRule: [String: Int]
    /// Its unfinished seats at the close by metres to go (#351), keyed by `DNFBucket.rawValue`; only buckets with any.
    public var dnfByMetresToGo: [String: Int]
    /// Of its unfinished seats, those on the last leg at the close, and those called at least once (#351).
    public var dnfOnLastLeg: Int
    public var dnfCalled: Int

    /// Metres to go at the close of an unfinished boat, for the DNF line (#351).
    public enum DNFBucket: String, CaseIterable, Sendable {
        case within60 = "<=60", within150 = "<=150", within300 = "<=300", further = ">300"

        init(metres: Double) {
            self = metres <= 60 ? .within60 : metres <= 150 ? .within150 : metres <= 300 ? .within300 : .further
        }
    }

    init(_ seats: [SeatMetrics]) {
        let n = Double(max(seats.count, 1))
        self.seats = seats.count
        finished = seats.filter(\.finished).count
        finishShare = share(finished, of: seats.count)
        meanIronsSeconds = seats.reduce(0) { $0 + $1.ironsSeconds } / n
        maxIronsSeconds = seats.map(\.ironsSeconds).max() ?? 0
        meanMarkContacts = Double(seats.reduce(0) { $0 + $1.markContacts }) / n
        boatContacts = seats.reduce(0) { $0 + $1.boatContacts }
        contactsEndingInFouls = seats.reduce(0) { $0 + $1.contactsEndingInFouls }
        contactsToFoulsShare = share(contactsEndingInFouls, of: boatContacts)
        encounters = seats.reduce(0) { $0 + $1.encounters }
        encountersEndingInFouls = seats.reduce(0) { $0 + $1.encountersEndingInFouls }
        encountersToFoulsShare = share(encountersEndingInFouls, of: encounters)
        preStartEncounters = seats.reduce(0) { $0 + $1.preStartEncounters }
        preStartEncountersEndingInFouls = seats.reduce(0) { $0 + $1.preStartEncountersEndingInFouls }
        foulsAsOffender = seats.reduce(0) { $0 + $1.foulsAsOffender }
        dsqMissedPenalty = seats.reduce(0) { $0 + $1.dsqMissedPenalty }
        ocsCount = seats.reduce(0) { $0 + $1.ocsCount }
        meanEdgeSeconds = seats.reduce(0) { $0 + $1.edgeSeconds } / n
        maxEdgeSeconds = seats.map(\.edgeSeconds).max() ?? 0
        callsByRule = seats.reduce(into: [:]) { sum, seat in sum.merge(seat.callsByRule, uniquingKeysWith: +) }
        calledBeforeFirstRoundingShare = share(seats.filter { $0.callsBeforeFirstRounding > 0 }.count, of: seats.count)
        racingTacksPerBoat = Double(seats.reduce(0) { $0 + $1.racingTacks }) / n
        preStartCallsByRule = seats.reduce(into: [:]) { sum, seat in sum.merge(seat.preStartCallsByRule, uniquingKeysWith: +) }
        cascadeCallsByRule = seats.reduce(into: [:]) { sum, seat in sum.merge(seat.cascadeCallsByRule, uniquingKeysWith: +) }
        let unfinished = seats.filter { !$0.finished }
        dnfByMetresToGo = unfinished.reduce(into: [:]) { sum, seat in
            sum[DNFBucket(metres: seat.metresToFinish ?? .infinity).rawValue, default: 0] += 1
        }
        dnfOnLastLeg = unfinished.filter(\.onLastLeg).count
        dnfCalled = unfinished.filter { $0.foulsAsOffender > 0 }.count
    }
}

/// A suite run's report (#97): the matrix, every race, each tier's and profile's summary, the skill gap, the
/// fun pass (#238), the start (#99), navigation (#100), conduct (#101), and the gate's verdict.
public struct BotSuiteReport: Codable, Hashable, Sendable {
    public var simulationVersion: String
    public var matrix: BotMatrix
    public var thresholds: BotThresholds
    public var races: [RaceResult]
    /// The live bots' seats by tier, keyed by `BotTier.rawValue`; only the tiers that sailed.
    public var tiers: [String: TierSummary]
    /// The scripted profiles' seats (#231), keyed by `BotProfile.rawValue`; only the profiles that sailed.
    public var profiles: [String: TierSummary]
    /// The tactician against the baseline over the races that had both; nil when none did.
    public var skillGap: SkillGapSummary?
    /// The fun-pass scenario (#238) over its races; nil when none sailed.
    public var funPass: FunPassSummary?
    /// The start (#99) over the all-National live ten-boat fleets; nil when none sailed.
    public var start: StartSummary?
    /// Navigation (#100) over the all-National live fleets; nil when none sailed.
    public var navigation: NavigationSummary?
    /// Conduct (#101) over the all-National live fleets; nil when none sailed.
    public var conduct: ConductSummary?
    /// Close encounters (#234) over the all-National live fleets; nil when none sailed.
    public var closeEncounters: CloseEncounterSummary?
    /// The live bots' fleet tactics by engagement band (#337) over every live race; nil when none sailed.
    public var engagementBands: EngagementBandSummary? = nil
    /// The hunters scenario (#355) over its races; nil when none sailed.
    public var hunters: HuntersSummary?
    /// Execution against tactics (#105) over the races with both; nil when none did.
    public var execution: ExecutionSummary?
    /// The 16.1 watchdog (#105) over the all-National live fleets in its conditions; nil when none sailed.
    public var watchdog: WatchdogSummary?
    /// The rival pace band (#105) over the rivals mix's races; nil when none sailed.
    public var rivals: RivalPaceSummary?
    /// Rank stability (#105) over the rank-stability mix's races; nil when none sailed.
    public var rank: RankSummary?
    /// The cautious mix (#105) over its races; nil when none sailed.
    public var cautious: CautiousSummary?
    /// The handling mix (#435) over its races; nil when none sailed.
    public var handling: HandlingSummary?
    /// Places by tactics skill and by handling skill (#443): the live mix's live bots; nil when none sailed.
    public var axes: AxesSummary? = nil
    /// The same over the handling mix's profiles (tactics or none, a perfect or Club hand); nil when none sailed.
    public var handlingAxes: AxesSummary? = nil
    public var timings: RunTimings
    /// Why the run misses the thresholds; empty when it passes.
    public var breaches: [String]
    public var passed: Bool

    public struct RunTimings: Codable, Hashable, Sendable {
        /// The worst race's p99 tick.
        public var maxP99Ms: Double
        public var maxMs: Double
    }

    public init(matrix: BotMatrix, thresholds: BotThresholds, races: [RaceResult]) {
        simulationVersion = RegattaCore.simulationVersion
        self.matrix = matrix
        self.thresholds = thresholds
        self.races = races
        let seats = races.flatMap(\.seats)
        // The live bots the tiers gate: never those racing hunters (#355), whose numbers are `hunters`', a cautious bot, or
        // at a skill their mix sets (#105: `ProfileMix.gatesLiveTiers`).
        let gated = races.filter(\.cell.profileMix.gatesLiveTiers).flatMap(\.seats)
        tiers = Dictionary(uniqueKeysWithValues: BotTier.allCases.compactMap { tier in
            let ofTier = gated.filter { $0.tier == tier && $0.profile == nil }
            return ofTier.isEmpty ? nil : (tier.rawValue, TierSummary(ofTier))
        })
        profiles = Dictionary(uniqueKeysWithValues: BotProfile.allCases.compactMap { profile in
            let ofProfile = seats.filter { $0.profile == profile }
            return ofProfile.isEmpty ? nil : (profile.rawValue, TierSummary(ofProfile))
        })
        skillGap = SkillGapSummary(races.compactMap(\.skillGap))
        funPass = FunPassSummary(races)
        start = StartSummary(races)
        navigation = NavigationSummary(races)
        conduct = ConductSummary(races)
        closeEncounters = CloseEncounterSummary(races)
        engagementBands = EngagementBandSummary(races)
        hunters = HuntersSummary(races)
        execution = ExecutionSummary(races.compactMap(\.execution))
        watchdog = WatchdogSummary(races)
        rivals = RivalPaceSummary(races)
        rank = RankSummary(races)
        cautious = CautiousSummary(races)
        handling = HandlingSummary(races.compactMap(\.handling))
        axes = AxesSummary(live: races)
        handlingAxes = AxesSummary(handlingMix: races)
        timings = RunTimings(maxP99Ms: races.map(\.timings.p99Ms).max() ?? 0,
                             maxMs: races.map(\.timings.maxMs).max() ?? 0)
        breaches = thresholds.breaches(tiers: tiers, timings: timings, skillGap: skillGap, funPass: funPass, start: start,
                                       navigation: navigation, conduct: conduct, closeEncounters: closeEncounters,
                                       execution: execution, watchdog: watchdog, rivals: rivals, rank: rank)
        passed = breaches.isEmpty
    }

    /// Sorted keys, so two runs of the same matrix differ only in their timings.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(self)
    }

    /// A short text summary: one line per tier, then the gate.
    public var lines: [String] {
        var lines = ["\(races.count) races, \(races.reduce(0) { $0 + $1.seats.count }) boats, \(races.filter(\.capped).count) capped"]
        for tier in BotTier.allCases {
            guard let s = tiers[tier.rawValue] else { continue }
            lines.append("\(tier.rawValue): \(s.finished)/\(s.seats) finished, irons \(fixed(s.meanIronsSeconds)) s/boat, "
                + "marks \(fixed(s.meanMarkContacts))/boat, contacts \(s.boatContacts) (\(fixed(s.contactsToFoulsShare)) fouls), "
                + "encounters \(s.encounters) (\(fixed(s.encountersToFoulsShare, 3)) fouls; "
                + "pre-start \(s.preStartEncountersEndingInFouls)/\(s.preStartEncounters), "
                + "racing \(s.encountersEndingInFouls - s.preStartEncountersEndingInFouls)/\(s.encounters - s.preStartEncounters)), "
                + "edge \(fixed(s.meanEdgeSeconds)) s/boat, dsq \(s.dsqMissedPenalty), ocs \(s.ocsCount)")
            lines.append("  \(tier.rawValue) calls: \(callsLine(s.callsByRule)); called before the first rounding "
                + "\(fixed(s.calledBeforeFirstRoundingShare)) of boats; tacks racing \(fixed(s.racingTacksPerBoat, 1))/boat")
            lines.append("  \(tier.rawValue) calls pre-start: \(callsLine(s.preStartCallsByRule)); "
                + "cascade (owing a turn already): \(callsLine(s.cascadeCallsByRule))")
            if s.finished < s.seats {
                let buckets = TierSummary.DNFBucket.allCases.map { "\($0.rawValue) m \(s.dnfByMetresToGo[$0.rawValue] ?? 0)" }
                lines.append("  \(tier.rawValue) DNFs \(s.seats - s.finished) by metres to go: \(buckets.joined(separator: ", ")); "
                    + "on the last leg \(s.dnfOnLastLeg), called at least once \(s.dnfCalled)")
            }
        }
        for profile in BotProfile.allCases {
            guard let s = profiles[profile.rawValue] else { continue }
            lines.append("\(profile.rawValue): \(s.finished)/\(s.seats) finished, irons \(fixed(s.meanIronsSeconds)) s/boat, "
                + "marks \(fixed(s.meanMarkContacts))/boat")
        }
        if let gap = skillGap {
            lines.append("skill gap: tactician won \(fixed(gap.tacticianWinShare)) of \(gap.races) races "
                + "(\(fixed(gap.tacticianPairShare)) of pairs), median gain \(fixed(gap.medianGainLengthsPerBeat)) "
                + "lengths/beat over \(gap.beats) beats, \(fixed(gap.medianGainLengthsPerRun)) lengths/run over \(gap.runs) runs, "
                + "start \(gap.meanStartGainLengths.map { fixed($0) } ?? "-") lengths ahead at the first cross over "
                + "\(gap.startRaces) races")
        }
        if let handling {
            func line(_ name: String, _ m: HandlingSummary.Medians) -> String {
                "  \(name): median \(fixed(m.medianSecondsPerBeat)) s/beat (\(fixed(m.medianLengthsPerBeat)) lengths) over "
                    + "\(m.beats) beats, \(fixed(m.medianSecondsPerRun)) s/run (\(fixed(m.medianLengthsPerRun)) lengths) over \(m.runs) runs"
            }
            lines.append("handling: perfect hand steering over Club's in \(handling.races) races"
                + (matrix.handSteers ? "" : " (the class's autohelm holds a centred rudder: sail with --autohelm off)"))
            lines.append(line("without tactics", handling.baseline))
            lines.append(line("with tactics", handling.tactician))
            lines.append(line("both", handling.all))
            if let handlingAxes {
                lines.append("handling places (mean place, finished/seats):")
                lines += handlingAxes.lines(skillAxis: "tactics", handlingAxis: "hand")
            }
        }
        if let axes {
            lines.append("live places by tactics skill and handling skill (mean place, finished/seats)"
                + (matrix.handSteers ? ":" : " (the class's autohelm holds a centred rudder: handling unfelt; sail with --autohelm off):"))
            lines += axes.lines(skillAxis: "skill", handlingAxis: "handling")
        }
        if let execution {
            lines.append("execution: tactician at Club execution beat the executor in \(fixed(execution.tacticsBeatsExecutionShare)) "
                + "of \(execution.races) races")
        }
        if let pass = funPass {
            let tacks = BotProfile.allCases.compactMap { profile in
                pass.tacksPerBeat[profile.rawValue].map { "\(profile.rawValue) \(fixed($0))" }
            }
            var line = "fun pass: \(pass.races) races, tacks/beat \(tacks.joined(separator: ", "))"
            if let share = pass.tacticianBeatsBlipTackerShare {
                line += "; tactician beat the blip-tacker in \(fixed(share)) of \(pass.blipTackerRaces) races"
            }
            lines.append(line)
        }
        if let start {
            lines.append("start: \(start.races) all-National \(StartSummary.fleetSize)-boat races, ocs \(fixed(start.ocsShare)), on time \(fixed(start.onTimeShare)) "
                + "(mean \(fixed(start.meanStartSeconds)) s after the gun), pre-gun irons \(fixed(start.meanPreGunIronsSeconds)) s/boat, "
                + "pin third \(start.pinThirdShare.map { fixed($0) } ?? "-") of \(start.pinStyleFromCommitteeSeats) pin-style boats "
                + "from committee slots")
        }
        if let navigation {
            lines.append("navigation: \(navigation.races) all-National races, \(navigation.seats) boats over "
                + "\(navigation.pairings.count) venue × conditions pairings, finished \(fixed(navigation.finishShare, 3)), "
                + "dsq \(navigation.dsqMissedPenalty), edge \(fixed(navigation.edgeShare, 4)) of the time, "
                + "marks \(fixed(navigation.markContactsPerBoat, 3))/boat/race")
        }
        if let conduct {
            lines.append("conduct: \(conduct.races) all-National races, \(conduct.seats) boats, encounters \(conduct.encounters), "
                + "\(conduct.encountersEndingInFouls) ending in fouls (\(fixed(conduct.encountersToFoulsShare, 3)))")
        }
        if let close = closeEncounters {
            lines.append("close encounters: \(close.races) all-National races, \(fixed(close.closeEncountersPerRace)) per mid-fleet boat "
                + "per race (crossings \(fixed(close.crossingsPerRace)), shadow given \(fixed(close.shadowGivenPerRace)), "
                + "received \(fixed(close.shadowReceivedPerRace)), covers \(fixed(close.coversPerRace)))")
        }
        if let engagementBands {
            for band in engagementBands.bands {
                lines.append("engagement \(band.name): \(band.seatRaces) live seat-races, per seat-race lee-bows "
                    + "\(fixed(band.leeBows, 3)), tacks on wind \(fixed(band.tacksOnWind, 3)), covers \(fixed(band.covers, 3)), "
                    + "pre-start luffing \(fixed(band.startLuffSeconds, 2)) s, fouls \(fixed(band.foulsAsOffender, 3)), "
                    + "pre-start calls \(fixed(band.preStartCalls, 3))")
            }
        }
        if let hunters {
            let profile = profiles[BotProfile.hunter.rawValue]
            lines.append("hunters: \(hunters.races) races (\(hunters.twinRaces) with live twins), hunter turn ticks "
                + "\(hunters.hunterTurnTicks), calls on hunters under 16.1/17 \(hunters.overdoneCalls)")
            lines.append("  calls on live bots, hunter the victim: \(callsLine(hunters.liveOnHunter))")
            lines.append("  calls on hunters, live bot the victim: \(callsLine(hunters.hunterOnLive)); hunter on hunter: "
                + "\(callsLine(hunters.hunterOnHunter))")
            lines.append("  calls between live bots: \(callsLine(hunters.liveOnLive))")
            if let profile {
                lines.append("  hunters: \(profile.finished)/\(profile.seats) finished, contacts \(profile.boatContacts), "
                    + "calls \(callsLine(profile.callsByRule))")
            }
            func liveLine(_ name: String, _ s: TierSummary, place: Double?, dnfs: Int?) -> String {
                "  \(name): \(s.finished)/\(s.seats) finished (\(fixed(s.finishShare, 3))), mean place among live seats "
                    + "\(place.map { fixed($0) } ?? "-") (DNF \(dnfs.map(String.init) ?? "-")), contacts \(s.boatContacts), encounters \(s.encounters) "
                    + "(\(fixed(s.encountersToFoulsShare, 3)) fouls), called before the first rounding "
                    + "\(fixed(s.calledBeforeFirstRoundingShare)) of boats, tacks racing \(fixed(s.racingTacksPerBoat, 1))/boat, "
                    + "calls \(callsLine(s.callsByRule))"
            }
            lines.append(liveLine("live with hunters", hunters.live, place: hunters.liveMeanPlace, dnfs: hunters.liveDNFs))
            if let twin = hunters.twinLive {
                lines.append(liveLine("same seats without", twin, place: hunters.twinLiveMeanPlace, dnfs: hunters.twinLiveDNFs))
            }
        }
        if let watchdog {
            let ids = WatchdogSummary.watchedConditions
            let parts = ids.map { id in
                "\(id) \(watchdog.centredRudder161CallsByConditions[id] ?? 0) of \(watchdog.rule161CallsByConditions[id] ?? 0) "
                    + "(tap in window \(watchdog.centredRudderWithTap161CallsByConditions[id] ?? 0))"
            }
            lines.append("watchdog: \(watchdog.races) all-National races, centred-rudder 16.1 calls \(parts.joined(separator: ", "))")
        }
        if let rivals {
            let parts = rivals.meanPlaceGap.keys.sorted().map { skill in
                "s \(skill) seat \(fixed(rivals.seatMeanPlace[skill] ?? 0)) rivals \(fixed(rivals.rivalMeanPlace[skill] ?? 0))"
            }
            lines.append("rivals: \(rivals.races) races, fleet \(fleetText(rivals.fleetSizes)), \(parts.joined(separator: ", ")); widest gap \(fixed(rivals.maxMeanPlaceGap)) places")
        }
        if let rank {
            let spread = rank.sameSkillPlaceGap.keys.sorted().map { "s \($0) \(fixed(rank.sameSkillPlaceGap[$0] ?? 0))" }
            lines.append("rank: fleet \(fleetText(rank.fleetSizes)), skill vs finishing order \(fixed(rank.meanSkillRankCorrelation)) "
                + "(Spearman, mean of \(rank.correlatedRaces) races); same-skill place gap \(rank.meanSameSkillPlaceGap.map { fixed($0) } ?? "-") "
                + "(\(spread.joined(separator: ", ")))")
        }
        if let cautious {
            lines.append("cautious: \(cautious.races) races, fouls as offender \(cautious.foulsAsOffender) in \(cautious.racesWithFoul) races, "
                + "mean place \(fixed(cautious.meanPlace)) (live beside her \(fixed(cautious.liveMeanPlace)))")
        }
        lines.append("tick: worst p99 \(fixed(timings.maxP99Ms, 3)) ms, max \(fixed(timings.maxMs, 3)) ms "
            + "(budget \(fixed(thresholds.maxP99TickMs, 3)) ms)")
        if !thresholds.placeholders.isEmpty { lines.append("placeholder keys: \(thresholds.placeholders.count)") }
        lines.append(passed ? "gate: pass" : "gate: FAIL")
        lines += breaches.map { "  \($0)" }
        return lines
    }
}

/// Rule calls by rule, in the rule book's order (`RacingRule.allCases`): "11 4, 10 2", or "none".
func callsLine(_ calls: [String: Int]) -> String {
    let parts = RacingRule.allCases.compactMap { rule in calls[rule.rawValue].map { "\(rule.rawValue) \($0)" } }
    return parts.isEmpty ? "none" : parts.joined(separator: ", ")
}

func fixed(_ value: Double, _ places: Int = 2) -> String {
    String(format: "%.\(places)f", value)
}

/// Fleet sizes as the summary prints them: `10`, or `2/5` when a run pooled several.
func fleetText(_ sizes: [Int]) -> String { sizes.isEmpty ? "-" : sizes.map(String.init).joined(separator: "/") }
