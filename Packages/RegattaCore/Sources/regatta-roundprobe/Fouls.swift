// regatta-roundprobe --fouls (#527 Part A, PROBE on the prototype branch, never merged): every rule call as offender in
// the bot suite's races, with the geometry, the brain's last 5 s of decisions, and counterfactual manoeuvres forked
// from saved snapshots.
//
//   regatta-roundprobe --fouls [regatta-botsuite's matrix flags: --matrix, --seeds, --fleet-size, --tier-mix,
//                      --profile-mix, --boat-class, --laps, --autohelm, --jobs] [--json path] [--lead-in s]
//                      [--no-cf] [--identity-only]
//
// The races are `regatta-botsuite`'s with the same flags (`BotSuiteOptions.matrix()`, `BotRaceHarness.run`): the
// gate check is that the calls counted here equal the suite's `foulsAsOffender` and `preStartCallsByRule`.
import BotSuite
import Foundation
import RegattaBots
import RegattaCore

struct FoulOptions {
    var suite = BotSuiteOptions()
    var json: String?
    var noCounterfactual = false
    var identityOnly = false
    /// Seconds of recorded inputs replayed on every seat before the branch, so the fork's umpire has the boats' track
    /// back as far as its rules read (`RulesConfig.Escape` record ticks): `importSnapshot` forgets it.
    var leadIn = 9.0
    /// Seconds after the call a fork sails on (#527 critique: 8 s, so a foul only put off is not counted avoided).
    var after = 3.0
    var jobs = 4
}

func parseFouls() throws -> FoulOptions {
    var o = FoulOptions()
    var rest: [String] = []
    var args = Array(CommandLine.arguments.dropFirst())[...]
    while let flag = args.popFirst() {
        switch flag {
        case "--fouls": continue
        case "--json": o.json = args.popFirst()
        case "--no-cf": o.noCounterfactual = true
        case "--identity-only": o.identityOnly = true
        case "--lead-in": o.leadIn = Double(args.popFirst() ?? "") ?? o.leadIn
        case "--after": o.after = Double(args.popFirst() ?? "") ?? o.after
        case "--jobs": o.jobs = Int(args.popFirst() ?? "") ?? o.jobs
        default: rest.append(flag)
        }
    }
    o.suite = try BotSuiteOptions(arguments: rest)
    return o
}

// MARK: - Records

struct BoatGeo: Codable, Sendable {
    var twaSignedDeg: Double // relative wind, degrees: + wind over starboard
    var speedShare: Double // speed / polar speed at her TWA
    var turning: Bool // |yaw rate| > FoulsProbe.turningRate
    var yawRateDegS: Double
    var tacking: Bool
    var penalty: Bool
    var stopped: Bool // < 0.30 polar
    var luffingAtLine: Bool // pre-start, within 2 lengths of the line, TWA < 35°
    var tack: String
    var status: String
}

struct Geometry: Codable, Sendable {
    var tick: Int
    var bearingDeg: Double // the other boat's bearing from the offender's bow, + to starboard
    var rangeM: Double
    var offender: BoatGeo
    var other: BoatGeo?
    var lineM: Double // signed distance to the start line, + course side
    var markM: Double // to the nearest mark
    var thirdSeat: Int // nearest third boat within 2 hull lengths of the offender, or -1
    var thirdM: Double
}

struct BrainSummary: Codable, Sendable {
    var decisions = 0
    var evaluated = 0
    var keepClearDecisions = 0
    var keepClearShare = 0.0
    var targetedOther = 0 // decisions whose `ruleKeepClear` returned on the boat of the call
    var targetedThird = 0 // ... on another boat (first boat wins, limit 3)
    var thirdTargets: [Int] = []
    var aboutToHitOther = 0 // decisions `isAboutToHit` fired on the boat of the call
    var aboutToHitAny = 0
    var misjudgedOther = 0
    var lineFallback = 0 // pre-start: keep-clear crossed the line early, fell back to `startKeepClear` (limit 5)
    var lineKept = 0 // ... and no fallback heading, kept the rule's
    var startKeepClear = 0
    var ruleKeepClearPath = 0 // decisions whose keep-clear went through `ruleKeepClear` (racing, or a starboard boat before her start)
    var lookahead = 0.0
    var wantsOtherTack = 0
    var cantTap: [String: Int] = [:] // limit 6
    var maxHeadingDeltaDeg = 0.0
    var meanHeadingDeltaDeg = 0.0
    var toggles = 0 // sign changes of chosen − desired (limit 4)
    var branches: [String: Int] = [:]
    var evasions: [String: Int] = [:]
    var keepClearRules: [String: Int] = [:]
}

struct Candidate: Codable, Sendable {
    var name: String
    var avoided: Bool // no call on her with the same other boat in the window
    var anyCall: Bool // any call on her in the window
    var calls: [String] = [] // "rule>victim@s"
    var ocs = false
    var tacked = false // crossed the wind (tack or gybe) in the fork
    var inScan = false // a heading on her own tack within `clearingHeading`'s range at the branch
    var minRangeM = 0.0 // closest approach to the other boat in the window
    /// Avoided, but the same pair is called in the 2 s after the window (call tick + 1 s to + 3 s): only put off.
    var delayed = false
    /// Any call on her (any boat, or a mark) after the call tick + 1 s, to the end of the `--after` window.
    var lateCall = false
}

struct FoulRecord: Codable, Sendable {
    var seed: UInt64
    var venue: String
    var conditions: String
    var fleetSize: Int
    var boatClass: String
    var tick: Int
    var seconds: Double
    var rule: String
    var turnsOwed: Int
    var offender: Int
    var other: Int
    var phase: String
    var offenderTier: String
    var offenderSkill: Double
    var otherTier: String
    var otherSkill: Double
    var cautious: Bool
    var otherCautious: Bool
    var atCall: Geometry
    var before3s: Geometry?
    var brain: BrainSummary
    var cascade: Bool
    var cascadeTurning: Bool
    var cascadeRecent: Bool
    var geometryClass: String
    // Counterfactuals.
    var identity5: Candidate?
    var identityExact5 = false
    var at5: [Candidate] = []
    var identity10: Candidate?
    var at10: [Candidate] = []
    var category = ""
    var avoidable10 = false
}

// MARK: - Probe

enum FoulsProbe {
    static let rate = Race.tickRate
    static let turningRate = 8.0 // deg/s
    static let ringSeconds = 21.0
    static let stateTicks = 6 * Race.tickRate // per-boat state kept, ticks (5 s brain + slack)

    struct State {
        var position: Vec2
        var heading: Double
        var speed: Double
        var relativeWind: Double
        var tws: Double
        var tack: Tack
        var status: BoatStatus
        var tacking: Bool
        var penalty: Bool
        var leg: Int
    }

    struct Pending {
        var record: FoulRecord
        var snapshots: [WorldSnapshot] // the ring at the call, oldest first
        var victim: Int
        var isMark: Bool
    }

    static func run() throws {
        let o = try parseFouls()
        let matrix = try o.suite.matrix()
        let cells = matrix.cells
        FileHandle.standardError.write(Data("fouls probe: \(cells.count) races, jobs \(o.jobs)\n".utf8))
        let clock = ContinuousClock()
        let start = clock.now
        let opts = o
        let perRace = try BotSuite.inParallel(cells, jobs: o.jobs) { cell in try sail(cell, opts) }
        let records = perRace.flatMap(\.records)
        let elapsed = start.duration(to: clock.now)
        var text: [String] = []
        let gate = perRace.reduce((0, 0)) { ($0.0 + $1.gatePre, $0.1 + $1.gateRacing) }
        text.append("races \(cells.count), elapsed \(elapsed)")
        text.append("GATE CHECK calls as offender (all .ruleCall, as RaceTally.foulsAsOffender): pre-start \(gate.0), racing \(gate.1), total \(gate.0 + gate.1); mark touches \(records.filter { $0.rule == "31" }.count)")
        text += report(records, o)
        let out = text.joined(separator: "\n")
        print(out)
        if let path = o.json {
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            try enc.encode(records).write(to: URL(fileURLWithPath: path))
        }
    }

    struct RaceOut: Sendable {
        var records: [FoulRecord]
        var gatePre: Int
        var gateRacing: Int
    }

    static func sail(_ cell: BotRaceCell, _ o: FoulOptions) throws -> RaceOut {
        let ringSnaps = Int(ringSeconds * 2)
        var race: Race?
        var ring: [WorldSnapshot] = []
        var states: [[State]] = []
        var decisions: [[(tick: Int, probe: BotProbeTrace)]] = []
        var lastDecision: [Int] = []
        var lastCallTick: [Int: Int] = [:]
        var pending: [Pending] = []
        var gatePre = 0, gateRacing = 0
        var skills: [Double] = []
        var tiers: [String] = []
        let cautious = cell.cautiousSeats
        let className = cell.boatClass ?? "\(RaceFiles.defaults.boatClass.ref.id)@\(RaceFiles.defaults.boatClass.ref.version)"
        func geoBoat(_ s: State, _ prev: State?, _ r: Race) -> BoatGeo {
            let polar = r.boatClass.polar
            let twa = abs(s.relativeWind)
            let target = polar.speed(twa: twa, tws: s.tws)
            let share = target > 0.01 ? s.speed / target : 0
            let yaw = prev.map { rad2deg(wrapAngle(s.heading - $0.heading)) * Double(rate) / 3 } ?? 0 // prev is 3 ticks back
            let line = r.course.startLine
            let atLine = (s.status == .prestart || r.tick < 0) && abs(line.side(s.position)) < 2 * r.boatClass.hull.length
                && twa < deg2rad(35)
            return BoatGeo(twaSignedDeg: rad2deg(s.relativeWind), speedShare: share, turning: abs(yaw) > turningRate,
                           yawRateDegS: yaw, tacking: s.tacking, penalty: s.penalty, stopped: share < 0.30, luffingAtLine: atLine,
                           tack: s.tack == .port ? "port" : "stbd", status: "\(s.status)")
        }
        func geometry(_ seat: Int, _ other: Int, back: Int, _ r: Race) -> Geometry? {
            let hist = states[seat]
            guard hist.count > back + 3 else { return nil }
            let s = hist[hist.count - 1 - back], sp = hist[hist.count - 4 - back]
            var bearing = 0.0, range = 0.0
            var og: BoatGeo?
            if other >= 0, states[other].count > back + 3 {
                let oh = states[other]
                let os = oh[oh.count - 1 - back], osp = oh[oh.count - 4 - back]
                let d = os.position - s.position
                bearing = rad2deg(wrapAngle(d.bearing - s.heading))
                range = d.length
                og = geoBoat(os, osp, r)
            }
            var marks = r.course.elements.flatMap(\.marks).map(\.position)
            marks += [r.course.startLine.pin.position, r.course.startLine.committee.position,
                      r.course.finishLine.pin.position, r.course.finishLine.committee.position]
            let markM = marks.map { ($0 - s.position).length }.min() ?? .infinity
            var third = -1, thirdM = Double.infinity
            for k in states.indices where k != seat && k != other && states[k].count > back {
                let ks = states[k][states[k].count - 1 - back]
                guard ks.status != .finished && ks.status != .dsq else { continue }
                let d = (ks.position - s.position).length
                if d < 2 * r.boatClass.hull.length && d < thirdM { third = k; thirdM = d }
            }
            return Geometry(tick: r.tick - back, bearingDeg: bearing, rangeM: range, offender: geoBoat(s, sp, r), other: og,
                            lineM: r.course.startLine.side(s.position), markM: markM, thirdSeat: third,
                            thirdM: third >= 0 ? thirdM : -1)
        }
        func brain(_ seat: Int, _ other: Int, callTick: Int) -> BrainSummary {
            var b = BrainSummary()
            var lastSign = 0.0
            var deltas: [Double] = []
            var thirds = Set<Int>()
            for (tick, p) in decisions[seat] where tick >= callTick - 5 * rate && tick <= callTick {
                b.decisions += 1
                b.branches[p.branch, default: 0] += 1
                if !p.evasion.isEmpty { b.evasions[p.evasion, default: 0] += 1 }
                if p.wantsOtherTack { b.wantsOtherTack += 1 }
                if !p.cantTapWhy.isEmpty { b.cantTap[p.cantTapWhy, default: 0] += 1 }
                guard p.evaluated else { continue }
                b.evaluated += 1
                b.lookahead = p.lookahead
                if p.evasion.hasPrefix("keepClear") {
                    b.keepClearDecisions += 1
                    if !p.keepClearRule.isEmpty { b.keepClearRules[p.keepClearRule, default: 0] += 1 }
                }
                if p.keepClearTarget == other { b.targetedOther += 1 }
                if p.keepClearTarget >= 0 && p.keepClearTarget != other { b.targetedThird += 1; thirds.insert(p.keepClearTarget) }
                if p.aboutToHit.contains(other) { b.aboutToHitOther += 1 }
                if !p.aboutToHit.isEmpty { b.aboutToHitAny += 1 }
                if p.misjudgedSeats.contains(other) { b.misjudgedOther += 1 }
                switch p.keepClearPath {
                case "line": b.lineFallback += 1
                case "lineKept": b.lineKept += 1
                case "start": b.startKeepClear += 1
                case "rule": b.ruleKeepClearPath += 1
                default: break
                }
                let delta = rad2deg(wrapAngle(p.chosenHeading - p.desiredHeading))
                deltas.append(abs(delta))
                if abs(delta) > 1 {
                    let sign: Double = delta > 0 ? 1 : -1
                    if lastSign != 0 && sign != lastSign { b.toggles += 1 }
                    lastSign = sign
                }
            }
            b.thirdTargets = thirds.sorted()
            b.keepClearShare = b.evaluated > 0 ? Double(b.keepClearDecisions) / Double(b.evaluated) : 0
            b.maxHeadingDeltaDeg = deltas.max() ?? 0
            b.meanHeadingDeltaDeg = deltas.isEmpty ? 0 : deltas.reduce(0, +) / Double(deltas.count)
            return b
        }

        let result = try BotRaceHarness.run(cell, cautiousSeats: cell.cautiousSeats, seatSkills: cell.seatSkills,
                                            observe: { r, events, controllers in
            if race == nil {
                race = r
                let n = r.boats.count
                states = Array(repeating: [], count: n)
                decisions = Array(repeating: [], count: n)
                lastDecision = Array(repeating: 0, count: n)
                skills = (0..<n).map { controllers[$0].driver?.style.skill ?? -1 }
                tiers = (0..<n).map { "\(cell.tierMix.tier(ofSeat: $0, raceSeed: r.setup.raceSeed))" }
            }
            for (i, b) in r.boats.enumerated() {
                states[i].append(State(position: b.position, heading: b.heading, speed: b.speed, relativeWind: b.relativeWind,
                                       tws: b.polarWindSpeed(in: r.boatClass), tack: b.tack, status: b.status,
                                       tacking: b.isTacking, penalty: b.isTakingPenalty, leg: b.legIndex))
                if states[i].count > stateTicks * 2 { states[i].removeFirst(states[i].count - stateTicks) }
                if let p = controllers[i].driver?.probe, p.decisions != lastDecision[i] {
                    lastDecision[i] = p.decisions
                    decisions[i].append((r.tick - 1, p))
                    if decisions[i].count > 64 { decisions[i].removeFirst(decisions[i].count - 32) }
                }
            }
            for event in events {
                var call: (offender: Int, victim: Int, rule: String, owed: Int, leg: Int)?
                switch event.kind {
                case .ruleCall(let c):
                    if r.tick < 0 { gatePre += 1 } else { gateRacing += 1 }
                    call = (c.offender, c.victim, c.rule.rawValue, c.turnsOwed, c.leg)
                case .markTouch(let seat, _):
                    call = (seat, -1, "31", 1, r.boats[seat].legIndex)
                default: break
                }
                guard let call else { continue }
                let seat = call.offender
                let b = r.boats[seat]
                let phase = PenaltyPhase.at(tick: r.tick, status: b.status, leg: b.legIndex, legs: r.course.legs.count)
                guard let atCall = geometry(seat, call.victim, back: 0, r) else { continue }
                let before = geometry(seat, call.victim, back: 3 * rate, r)
                let turning = b.isTakingPenalty || (states[seat].dropLast().last?.penalty ?? false)
                let recent = lastCallTick[seat].map { r.tick - $0 <= 15 * rate } ?? false
                lastCallTick[seat] = r.tick
                var record = FoulRecord(
                    seed: cell.seed, venue: cell.venue, conditions: cell.conditions, fleetSize: cell.fleetSize, boatClass: className,
                    tick: r.tick, seconds: Double(r.tick) / Double(rate), rule: call.rule, turnsOwed: call.owed, offender: seat,
                    other: call.victim, phase: phase.rawValue, offenderTier: tiers[seat], offenderSkill: skills[seat],
                    otherTier: call.victim >= 0 ? tiers[call.victim] : "", otherSkill: call.victim >= 0 ? skills[call.victim] : -1,
                    cautious: cautious.contains(seat), otherCautious: cautious.contains(call.victim),
                    atCall: atCall, before3s: before, brain: brain(seat, call.victim, callTick: r.tick),
                    cascade: turning || recent, cascadeTurning: turning, cascadeRecent: recent, geometryClass: "")
                record.geometryClass = classify(record)
                pending.append(Pending(record: record, snapshots: ring, victim: call.victim, isMark: call.rule == "31"))
            }
            if r.tick % (rate / 2) == 0 {
                ring.append(r.exportSnapshot())
                if ring.count > ringSnaps { ring.removeFirst(ring.count - ringSnaps) }
            }
        })
        _ = result
        guard let race else { return RaceOut(records: [], gatePre: 0, gateRacing: 0) }
        let inputs = race.log?.inputs ?? []
        var records: [FoulRecord] = []
        if o.noCounterfactual { return RaceOut(records: pending.map(\.record), gatePre: gatePre, gateRacing: gateRacing) }
        let setup = race.setup
        let files = try BotRaceHarness.raceFiles(for: cell, setup: setup)
        for p in pending {
            var rec = p.record
            let fork = Forker(cell: cell, setup: setup, files: files, inputs: inputs, snapshots: p.snapshots, seat: rec.offender,
                              victim: p.victim, isMark: p.isMark, callTick: rec.tick, leadIn: Int(o.leadIn * Double(rate)), after: Int(o.after * Double(rate)))
            for back in [5, 10] {
                let branch = rec.tick - back * rate
                guard let id = fork.run(.recorded, branch: branch) else { break }
                if back == 5 {
                    rec.identity5 = id
                    rec.identityExact5 = id.calls.contains { $0.hasPrefix("\(rec.rule)>\(p.victim)@\(fmt(rec.seconds, 2))") }
                } else {
                    rec.identity10 = id
                }
                if o.identityOnly { break }
                let cands = Manoeuvre.all.compactMap { fork.run($0, branch: branch) }
                if back == 5 { rec.at5 = cands } else { rec.at10 = cands }
                if back == 5, cands.contains(where: \.avoided) { break }
            }
            rec.category = category(rec)
            rec.avoidable10 = rec.at10.contains(where: \.avoided)
            records.append(rec)
        }
        FileHandle.standardError.write(Data("sailed seed \(cell.seed) \(cell.venue) \(cell.fleetSize) boats: \(records.count) calls\n".utf8))
        return RaceOut(records: records, gatePre: gatePre, gateRacing: gateRacing)
    }

    // MARK: Classification

    /// The dominant geometry of a call, the first that holds.
    static func classify(_ r: FoulRecord) -> String {
        let g = r.atCall, g3 = r.before3s
        let o = g.offender
        if r.rule == "31" { return "mark touch" }
        if r.rule == "18.2" { return "mark-room" }
        if r.rule == "21.2" || o.penalty || (g3?.offender.penalty ?? false) { return "turning a penalty" }
        guard let v = g.other else { return "other" }
        if v.penalty || (g3?.other?.penalty ?? false) { return "into a penalty turner" }
        if r.rule == "13" || r.rule == "15" || o.tacking || (g3?.offender.tacking ?? false) { return "tacking too close" }
        if r.phase == PenaltyPhase.preStart.rawValue && (o.luffingAtLine || v.luffingAtLine || (g3?.other?.luffingAtLine ?? false)) {
            return "luffing at the line"
        }
        if r.rule == "16.1" { return "changing course (16.1)" }
        if o.tack != v.tack { return "port/starboard crossing" }
        if v.stopped || (g3?.other?.stopped ?? false) { return "into a stopped boat" }
        let b = abs(g3?.bearingDeg ?? g.bearingDeg)
        if b < 45 { return "clear astern, overtaking" }
        if b <= 135 { return "windward/leeward overlapped" }
        return "other boat astern"
    }

    /// (a) own-tack heading within the scan, (b) a manoeuvre the evaluator can't produce, (c) weighing a second
    /// boat, (d) nothing within 5 s.
    static func category(_ r: FoulRecord) -> String {
        let avoiding = r.at5.filter(\.avoided)
        guard !avoiding.isEmpty else { return "d" }
        if r.brain.targetedThird > 0 { return "c" }
        // Hold (her heading as it is, rudder centred) is a heading on her own tack the scan reaches as well.
        if avoiding.contains(where: { !$0.tacked && ($0.name == "hold" || ($0.inScan && Manoeuvre(rawValue: $0.name)?.isHeading == true)) }) {
            return "a"
        }
        return "b"
    }

    // MARK: Report

    static func report(_ all: [FoulRecord], _ o: FoulOptions) -> [String] {
        var lines: [String] = []
        let calls = all.filter { $0.rule != "31" }
        lines.append("calls as offender: \(calls.count) (pre-start \(calls.filter { $0.phase == "preStart" }.count)), turns owed > 0: \(calls.filter { $0.turnsOwed > 0 }.count); mark touches \(all.count - calls.count)")
        let withId = calls.filter { $0.identity5 != nil }
        if !withId.isEmpty {
            let pair = withId.filter { $0.identity5.map { !$0.avoided } ?? false }.count
            let exact = withId.filter(\.identityExact5).count
            lines.append("identity check (offender on her recorded inputs from T-5 s): same pair called \(pair)/\(withId.count) = \(fmt(Double(pair) / Double(withId.count), 3)); same rule, pair and tick \(exact)/\(withId.count) = \(fmt(Double(exact) / Double(withId.count), 3))")
            let id10 = calls.filter { $0.identity10 != nil }
            if !id10.isEmpty {
                let p10 = id10.filter { $0.identity10.map { !$0.avoided } ?? false }.count
                lines.append("identity check from T-10 s: same pair called \(p10)/\(id10.count)")
            }
        }
        guard !o.identityOnly else { return lines }
        let cats = ["a", "b", "c", "d"]
        func row(_ name: String, _ rs: [FoulRecord]) -> [String] {
            let n = Double(max(rs.count, 1))
            var cells = [name, "\(rs.count)", fmt(Double(rs.count) / Double(max(calls.count, 1)) * 100, 1)]
            for c in cats { cells.append(fmt(Double(rs.filter { $0.category == c }.count) / n * 100, 0)) }
            let d = rs.filter { $0.category == "d" }
            cells.append(d.isEmpty ? "-" : "\(d.filter(\.avoidable10).count)/\(d.count)")
            cells.append(fmt(Double(rs.filter { $0.at5.contains { $0.name == "hold" && $0.avoided } }.count) / n * 100, 0))
            cells.append(fmt(Double(rs.filter(\.cascade).count) / n * 100, 0))
            return cells
        }
        let header = ["rule × phase × geometry", "n", "% all", "a%", "b%", "c%", "d%", "d→10s", "hold%", "casc%"]
        var rows: [[String]] = [header, row("ALL", calls)]
        for phase in ["preStart", "firstBeat", "laterLegs", "lastLeg"] { rows.append(row("phase \(phase)", calls.filter { $0.phase == phase })) }
        var ruleCounts: [String: Int] = [:]
        for r in calls { ruleCounts[r.rule, default: 0] += 1 }
        let rules = ruleCounts.sorted { $0.value > $1.value }.map(\.key)
        for rule in rules { rows.append(row("rule \(rule)", calls.filter { $0.rule == rule })) }
        rows.append(row("rule 31 (mark touch; not in n)", all.filter { $0.rule == "31" }))
        let geos = Set(calls.map(\.geometryClass)).sorted()
        for g in geos { rows.append(row("geo \(g)", calls.filter { $0.geometryClass == g })) }
        lines.append("")
        lines.append("BY MARGIN (a = own-tack heading in the scan, hold included, b = a manoeuvre the evaluator can't produce, c = weighing a second boat, d = nothing at 5 s; d→10s = avoidable from 10 s)")
        lines += table(rows)
        var cellRows: [[String]] = [header]
        var groups: [String: [FoulRecord]] = [:]
        for r in calls { groups["\(r.rule) | \(r.phase) | \(r.geometryClass)", default: []].append(r) }
        for (k, v) in groups.sorted(by: { $0.value.count > $1.value.count }) where v.count >= 3 { cellRows.append(row(k, v)) }
        lines.append("")
        lines.append("CELLS rule | phase | geometry (n >= 3)")
        lines += table(cellRows)
        // Which manoeuvres avoid, overall.
        lines.append("")
        lines.append("avoided by each candidate from T-5 s (share of calls with candidates run):")
        let ran = calls.filter { !$0.at5.isEmpty }
        for m in Manoeuvre.all {
            let a = ran.filter { $0.at5.contains { $0.name == m.rawValue && $0.avoided } }.count
            let ocs = ran.filter { $0.at5.contains { $0.name == m.rawValue && $0.avoided && $0.ocs } }.count
            let other = ran.filter { $0.at5.contains { $0.name == m.rawValue && $0.avoided && $0.anyCall } }.count
            let late = ran.filter { $0.at5.contains { $0.name == m.rawValue && $0.avoided && $0.delayed } }.count
            let ranges = ran.compactMap { r in r.at5.first { $0.name == m.rawValue && $0.avoided && $0.minRangeM >= 0 }?.minRangeM }.sorted()
            let median = ranges.isEmpty ? -1 : ranges[ranges.count / 2]
            let p10 = ranges.isEmpty ? -1 : ranges[ranges.count / 10]
            lines.append("  \(m.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)) \(fmt(Double(a) / Double(max(ran.count, 1)) * 100, 1))%  (of which OCS \(ocs), another call on her \(other), same pair called 1-3 s after the window \(late); closest approach when avoided median \(fmt(median)) m, p10 \(fmt(p10)) m)")
        }
        let base = ran.compactMap { $0.identity5?.minRangeM }.filter { $0 >= 0 }.sorted()
        if !base.isEmpty { lines.append("  (recorded inputs: closest approach median \(fmt(base[base.count / 2])) m, p10 \(fmt(base[base.count / 10])) m)") }
        let aOnly40 = calls.filter { $0.category == "a" && !$0.at5.contains { $0.avoided && $0.inScan && ["luff10", "luff20", "bear10", "bear20"].contains($0.name) } }.count
        lines.append("(a) avoided only by a 40° luff/bear-away (still in the scan): \(aOnly40) of \(calls.filter { $0.category == "a" }.count)")
        let cs = calls.filter { $0.category == "c" }
        let cOwn = cs.filter { r in r.at5.contains { $0.avoided && !$0.tacked && ($0.name == "hold" || ($0.inScan && Manoeuvre(rawValue: $0.name)?.isHeading == true)) } }.count
        lines.append("(c) is any call whose 5 s before had a decision with `ruleKeepClear` returning on a boat other than the one called, and some candidate avoids it: \(cs.count); of those an own-tack heading or hold also avoids \(cOwn), only ease/tack/gybe \(cs.count - cOwn)")
        lines.append("")
        lines.append("cascades: \(calls.filter(\.cascade).count) (on a boat already turning \(calls.filter(\.cascadeTurning).count), within 15 s of her last call \(calls.filter(\.cascadeRecent).count))")
        let pre = calls.filter { $0.phase == "preStart" }
        lines.append("pre-start line-over-rules fallback in the 5 s before: fell back to startKeepClear \(pre.filter { $0.brain.lineFallback > 0 }.count), kept the line-crossing heading \(pre.filter { $0.brain.lineKept > 0 }.count), of \(pre.count)")
        let ev = calls.filter { $0.brain.evaluated > 0 }
        lines.append("brain in the 5 s before (calls with evaluated decisions \(ev.count)): isAboutToHit fired on the other boat \(ev.filter { $0.brain.aboutToHitOther > 0 }.count), keep-clear evasion targeted her \(ev.filter { $0.brain.targetedOther > 0 }.count), targeted a third boat \(ev.filter { $0.brain.targetedThird > 0 }.count), misjudged \(ev.filter { $0.brain.misjudgedOther > 0 }.count), heading toggled 2+ times \(ev.filter { $0.brain.toggles >= 2 }.count), tap wanted and refused \(ev.filter { !$0.brain.cantTap.isEmpty }.count)")
        var why: [String: Int] = [:]
        for r in ev { for k in r.brain.cantTap.keys { why[k, default: 0] += 1 } }
        lines.append("  refused tap reasons (calls): \(why.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
        return lines
    }

    static func table(_ rows: [[String]]) -> [String] {
        guard let first = rows.first else { return [] }
        let widths = first.indices.map { i in rows.map { i < $0.count ? $0[i].count : 0 }.max() ?? 0 }
        return rows.map { row in
            row.enumerated().map { i, c in i == 0 ? c.padding(toLength: widths[i], withPad: " ", startingAt: 0)
                : String(repeating: " ", count: widths[i] - c.count) + c }.joined(separator: "  ")
        }
    }
}

// MARK: - Counterfactuals

enum Manoeuvre: String, CaseIterable, Sendable {
    case recorded, hold, luff10, luff20, luff40, bear10, bear20, bear40, ease, tack, gybe

    static let all: [Manoeuvre] = [.hold, .luff10, .luff20, .luff40, .bear10, .bear20, .bear40, .ease, .tack, .gybe]

    var isHeading: Bool { [.luff10, .luff20, .luff40, .bear10, .bear20, .bear40].contains(self) }

    /// The signed heading change (radians, + to starboard) to reach from `heading` in `relativeWind`.
    func turn(relativeWind r: Double) -> Double {
        let towards: Double = r >= 0 ? 1 : -1 // + heading turns her towards a wind over her starboard side
        let twa = abs(r)
        switch self {
        case .luff10: return towards * deg2rad(10)
        case .luff20: return towards * deg2rad(20)
        case .luff40: return towards * deg2rad(40)
        case .bear10: return -towards * deg2rad(10)
        case .bear20: return -towards * deg2rad(20)
        case .bear40: return -towards * deg2rad(40)
        case .tack: return towards * (twa + deg2rad(45))
        case .gybe: return -towards * (deg2rad(210) - twa)
        default: return 0
        }
    }
}

struct Forker {
    let cell: BotRaceCell
    let setup: RaceSetup
    let files: RaceFiles
    let inputs: [InputRecord]
    let snapshots: [WorldSnapshot]
    let seat: Int
    let victim: Int
    let isMark: Bool
    let callTick: Int
    let leadIn: Int
    let after: Int

    static let fullRudderError = deg2rad(15)
    static let leastRudder = 0.08
    static let letGo = deg2rad(1.5)

    /// Forks at the latest snapshot `leadIn` ticks or more before `branch`, replays every seat's recorded inputs to
    /// `branch`, then sails her by `m` (the others on their recorded inputs) to the call tick + 1 s.
    func run(_ m: Manoeuvre, branch: Int) -> Candidate? {
        // Near the sequence's start there may be less lead-in than asked: the earliest snapshot before the branch.
        guard let snap = snapshots.last(where: { $0.tick <= branch - leadIn }) ?? snapshots.first(where: { $0.tick <= branch })
        else { return nil }
        guard let race = try? Race(setup: setup, files: files, mode: .authoritative(windSeed: BotRaceHarness.windSeed(for: cell.seed))),
              (try? race.importSnapshot(snap)) != nil else { return nil }
        _ = race.drainEvents()
        let windowEnd = callTick + Race.tickRate
        let end = callTick + max(after, Race.tickRate)
        var cursor = inputs.partitioningIndex { $0.tick > snap.tick }
        var c = Candidate(name: m.rawValue, avoided: true, anyCall: false)
        var turnTarget = 0.0, turned = 0.0, lastHeading = 0.0, startTack = Tack.port
        var minRange = Double.infinity
        var lastInput: BoatInput?
        while race.tick < end && !race.isOver {
            let next = race.tick + 1
            while cursor < inputs.count && inputs[cursor].tick <= next {
                let rec = inputs[cursor]
                cursor += 1
                if rec.seat == seat && rec.tick > branch && m != .recorded { continue }
                switch rec.kind {
                case .held(let input): race.apply(input, seat: rec.seat, atTick: rec.tick)
                case .tap(let tap): race.tap(tap, seat: rec.seat, atTick: rec.tick)
                }
            }
            if m != .recorded && next > branch {
                let b = race.boats[seat]
                if next == branch + 1 {
                    turnTarget = m.turn(relativeWind: b.relativeWind)
                    lastHeading = b.heading
                    startTack = b.tack
                    if m.isHeading {
                        let endTWA = abs(b.relativeWind) + (m.rawValue.hasPrefix("luff") ? -1 : 1) * abs(turnTarget)
                        let closest = BoatDynamics.noGoAngle(race.boatClass.polar) + deg2rad(5)
                        c.inScan = endTWA >= closest && endTWA <= .pi
                    }
                }
                turned += wrapAngle(b.heading - lastHeading)
                lastHeading = b.heading
                let input: BoatInput
                switch m {
                case .hold: input = .neutral
                case .ease: input = BoatInput(rudder: 0 as Int8, ease: true)
                default:
                    let error = turnTarget - turned
                    if abs(error) < Self.letGo {
                        input = .neutral
                    } else {
                        let p = (error / Self.fullRudderError).clamped(to: -1...1)
                        input = BoatInput(rudder: abs(p) < Self.leastRudder ? (p < 0 ? -Self.leastRudder : Self.leastRudder) : p)
                    }
                }
                if input != lastInput {
                    race.apply(input, seat: seat, atTick: next)
                    lastInput = input
                }
            }
            race.step()
            if race.tick > branch && race.tick <= windowEnd {
                if victim >= 0 { minRange = min(minRange, (race.boats[victim].position - race.boats[seat].position).length) }
                if race.boats[seat].tack != startTack && m != .recorded && race.tick > branch + 1 { c.tacked = true }
            }
            for e in race.drainEvents() where race.tick > branch {
                if race.tick > windowEnd {
                    switch e.kind {
                    case .ruleCall(let call) where call.offender == seat:
                        c.lateCall = true
                        if !isMark && call.victim == victim { c.delayed = c.avoided }
                    case .markTouch(let s, _) where s == seat:
                        c.lateCall = true
                        if isMark { c.delayed = c.avoided }
                    case .ocsNotice(let s) where s == seat: c.ocs = true
                    default: break
                    }
                    continue
                }
                switch e.kind {
                case .ruleCall(let call) where call.offender == seat:
                    c.anyCall = true
                    c.calls.append("\(call.rule.rawValue)>\(call.victim)@\(fmt(Double(call.tick) / Double(Race.tickRate), 2))")
                    if !isMark && call.victim == victim { c.avoided = false }
                case .markTouch(let s, _) where s == seat:
                    c.anyCall = true
                    c.calls.append("31>-1@\(fmt(Double(race.tick) / Double(Race.tickRate), 2))")
                    if isMark { c.avoided = false }
                case .ocsNotice(let s) where s == seat: c.ocs = true
                default: break
                }
            }
        }
        c.minRangeM = minRange.isFinite ? minRange : -1
        return c
    }
}

extension Array {
    func partitioningIndex(where belongs: (Element) -> Bool) -> Int {
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if belongs(self[mid]) { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }
}
