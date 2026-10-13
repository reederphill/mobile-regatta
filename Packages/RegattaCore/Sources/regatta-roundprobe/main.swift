// regatta-roundprobe (#464, PROBE on the prototype branch, never merged): sails bot fleets headless and scores every
// mark rounding against an ideal path, to find the tail of large losses and what the bot was doing before each.
//
//   regatta-roundprobe [--seeds n] [--venue v@n ...] [--conditions c@n ...] [--tier-mix m] [--fleet-size n] [--laps n]
//                      [--boat-class id@v] [--json path] [--trace k] [--trace-one seed:seat:leg] [--min-extra m]
//
// Per rounding (one boat, one rounding leg): the approach from 80 m out to the stage-1 crossing against the ideal
// upwind/downwind/reach distance at the polar's speed, the rounding itself (stage 1 to the leg's end), and the exit
// (the 15 s after), each as extra metres and seconds; plus wrong side, abeam at the crossing, tacks/gybes, seconds
// steered off the plan by kind, hand-turn flubs, mark touches and the dominant brain branch. `--trace k` prints a
// per-second account of the k worst.
import BotSuite
import Foundation
import RegattaBots
import RegattaCore

struct Options {
    var seeds = 4
    var venues = ["dev-venue@7"]
    var conditions = ["classic-oscillating@7"]
    var tierMix = TierMix.mixed
    var fleetSize = 8
    var laps = 2
    var boatClass: String?
    var json: String?
    var trace = 0
    var traceOne: (seed: UInt64, seat: Int, leg: Int)?
    var minExtra = 30.0
    var seedStart: UInt64 = 1
    var byVenue: [String: [String]] = [:]
    var traceMode: (mode: String, count: Int)?
}

func parse() -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())[...]
    var venues: [String] = [], conditions: [String] = []
    while let flag = args.popFirst() {
        func value() -> String { args.popFirst() ?? "" }
        switch flag {
        case "--seeds": o.seeds = Int(value()) ?? o.seeds
        case "--seed-start": o.seedStart = UInt64(value()) ?? 1
        case "--venue": venues.append(value())
        case "--conditions": conditions.append(value())
        case "--pair":
            let parts = value().split(separator: ":").map(String.init)
            if parts.count == 2 { venues.append(parts[0]); o.byVenue[parts[0], default: []].append(parts[1]); conditions.append(parts[1]) }
        case "--tier-mix": o.tierMix = TierMix(rawValue: value()) ?? o.tierMix
        case "--fleet-size": o.fleetSize = Int(value()) ?? o.fleetSize
        case "--laps": o.laps = Int(value()) ?? o.laps
        case "--boat-class": o.boatClass = value()
        case "--json": o.json = value()
        case "--trace": o.trace = Int(value()) ?? 0
        case "--trace-mode":
            let parts = value().split(separator: ":").map(String.init)
            if parts.count == 2, let n = Int(parts[1]) { o.traceMode = (parts[0], n) }
        case "--min-extra": o.minExtra = Double(value()) ?? o.minExtra
        case "--trace-one":
            let parts = value().split(separator: ":").map(String.init)
            if parts.count == 3, let s = UInt64(parts[0]), let seat = Int(parts[1]), let leg = Int(parts[2]) {
                o.traceOne = (s, seat, leg)
            }
        default: FileHandle.standardError.write(Data("unknown argument \(flag)\n".utf8)); exit(2)
        }
    }
    if !venues.isEmpty { o.venues = Array(Set(venues)).sorted() }
    if !conditions.isEmpty { o.conditions = Array(Set(conditions)).sorted() }
    return o
}

/// One tick of one boat, as the probe records it.
struct Sample {
    var tick: Int
    var position: Vec2
    var heading: Double
    var speed: Double
    var tack: Tack
    var twa: Double
    var windDirection: Double
    var tws: Double
    var legIndex: Int
    var stage: Int
    var status: BoatStatus
    var isTacking: Bool
    var isPlaning: Bool
    var penalty: Bool
    var probe: BotProbeTrace
}

struct Rounding: Codable {
    var seed: UInt64
    var venue: String
    var conditions: String
    var seat: Int
    var tier: String
    var skill: Double
    var handling: Double
    var leg: Int
    var mark: String // W, O, G
    var entryTick: Int
    var crossTick: Int
    var doneTick: Int
    var approachM: Double
    var approachIdealM: Double
    var approachS: Double
    var approachIdealS: Double
    var roundM: Double
    var roundIdealM: Double
    var roundS: Double
    var exitM: Double
    var exitIdealM: Double
    var exitMaxLateral: Double
    var extraM: Double
    var extraS: Double
    var wrongSide: Bool
    var abeam: Double
    var gateMark: String
    var gateCrossAlong: Double
    var tacks: Int
    var gybes: Int
    var reachingS: Double
    var keepClearS: Double
    var avoidMarkS: Double
    var edgeS: Double
    var handTurnS: Double
    var flubbed: Bool
    var cantTapS: Double
    var cantTapWhy: String
    var minSpeedShare: Double
    var markTouches: Int
    var penaltyS: Double
    var branches: String
    var waypoints: String
    var mode: String
    /// Seconds below the gate line (or past the mark's altitude on its wrong side) before crossing, and whether she went
    /// past the line outside a gate mark.
    var pastBeforeCrossS: Double
    var passedOutside: Bool
    var ruleCalls: String
    var keepClearRules: String
    var recoveryS: Double
}

func fmt(_ x: Double, _ d: Int = 1) -> String { String(format: "%.\(d)f", x) }

@main
struct Main {
    static func main() throws {
        let o = parse()
        let matrix = BotMatrix(seeds: (0..<UInt64(o.seeds)).map { o.seedStart + $0 }, venues: o.venues, conditions: o.conditions,
                               conditionsByVenue: o.byVenue, fleetSizes: [o.fleetSize], tierMixes: [o.tierMix], profileMixes: [.live], laps: o.laps,
                               capSecondsAfterGun: 1500, boatClass: o.boatClass)
        var all: [Rounding] = []
        var traces: [String: [Sample]] = [:] // "seed:seat"
        var raceInfo: [String: (course: CourseLayout, boatClass: BoatClass, events: [RaceEvent])] = [:]
        for cell in matrix.cells {
            let setup = try BotRaceHarness.raceSetup(for: cell)
            let race = try Race(setup: setup, files: RaceFiles(resolving: setup), mode: .authoritative(windSeed: BotRaceHarness.windSeed(for: cell.seed)))
            var controllers = SeatControllers(setup.seats.indices.map { .bot(cell.tierMix.driver(seat: $0, raceSeed: setup.raceSeed, profile: nil)) })
            var samples = Array(repeating: [Sample](), count: setup.seats.count)
            var events: [RaceEvent] = []
            let lastTick = cell.capSecondsAfterGun * Race.tickRate
            while !race.isOver && race.tick < lastTick {
                controllers.drive(race)
                race.step()
                events += race.drainEvents()
                for (i, b) in race.boats.enumerated() {
                    guard b.status == .racing else { continue }
                    samples[i].append(Sample(tick: race.tick, position: b.position, heading: b.heading, speed: b.speed, tack: b.tack,
                                             twa: b.twa, windDirection: b.windDirection, tws: b.polarWindSpeed(in: race.boatClass),
                                             legIndex: b.legIndex, stage: b.roundingStage, status: b.status, isTacking: b.isTacking,
                                             isPlaning: b.isPlaning, penalty: b.isTakingPenalty, probe: controllers[i].driver?.probe ?? BotProbeTrace()))
                }
            }
            let key = "\(cell.seed)|\(cell.venue)|\(cell.conditions)"
            raceInfo[key] = (race.course, race.boatClass, events)
            for seat in setup.seats.indices {
                traces["\(key):\(seat)"] = samples[seat]
                let driver = controllers[seat].driver!
                let tier = cell.tierMix.tier(ofSeat: seat, raceSeed: setup.raceSeed)
                all += score(samples[seat], course: race.course, boatClass: race.boatClass, events: events, seat: seat, cell: cell,
                             tier: "\(tier)", skill: driver.style.skill, handling: driver.handling ?? -1)
            }
            FileHandle.standardError.write(Data("sailed seed \(cell.seed) \(cell.venue) \(cell.conditions): \(race.tick / Race.tickRate) s\n".utf8))
        }
        report(all, o)
        if let path = o.json {
            let data = try JSONEncoder().encode(all)
            try data.write(to: URL(fileURLWithPath: path))
        }
        let worst = all.sorted { $0.extraM > $1.extraM }
        for r in worst.prefix(o.trace) {
            let key = "\(r.seed)|\(r.venue)|\(r.conditions)"
            printTrace(r, traces["\(key):\(r.seat)"] ?? [], raceInfo[key]!)
        }
        if let tm = o.traceMode {
            for r in worst.filter({ $0.mode.hasPrefix(tm.mode) }).prefix(tm.count) {
                let key = "\(r.seed)|\(r.venue)|\(r.conditions)"
                printTrace(r, traces["\(key):\(r.seat)"] ?? [], raceInfo[key]!)
            }
        }
        if let one = o.traceOne {
            for r in all where r.seed == one.seed && r.seat == one.seat && r.leg == one.leg {
                let key = "\(r.seed)|\(r.venue)|\(r.conditions)"
                printTrace(r, traces["\(key):\(r.seat)"] ?? [], raceInfo[key]!)
            }
        }
    }

    // MARK: - Scoring

    static let entryRange = 80.0
    static let exitSeconds = 15

    /// Ideal sailing distance and speed from `p` to `t` in `wind` (direction the wind blows from, m/s `tws`) for a leg
    /// sailed `mode`: "up" (tacking inside the laylines' cone), "down" (gybing likewise), "reach" (straight).
    static func ideal(from p: Vec2, to t: Vec2, wind: Double, tws: Double, mode: String, polar: PolarTable) -> (m: Double, s: Double) {
        let d = t - p
        let straight = d.length
        guard straight > 0.01 else { return (0, 0) }
        let upwind = Vec2.heading(wind)
        if mode == "up" {
            let u = d.dot(upwind), l = abs(d.dot(upwind.rightPerp))
            let best = polar.bestUpwind(tws: tws)
            if u > 0, l <= u * tan(best.twa) {
                let m = u / cos(best.twa)
                return (m, m / max(best.speed, 0.1))
            }
            let twa = abs(wrapAngle(d.bearing - wind))
            return (straight, straight / max(polar.speed(twa: max(twa, best.twa), tws: tws), 0.1))
        }
        if mode == "down" {
            let u = -d.dot(upwind), l = abs(d.dot(upwind.rightPerp))
            let best = polar.bestDownwind(tws: tws)
            let half = .pi - best.twa
            if u > 0, l <= u * tan(half) {
                let m = u / cos(half)
                return (m, m / max(best.speed, 0.1))
            }
            let twa = abs(wrapAngle(d.bearing - wind))
            return (straight, straight / max(polar.speed(twa: min(twa, best.twa), tws: tws), 0.1))
        }
        let twa = abs(wrapAngle(d.bearing - wind))
        return (straight, straight / max(polar.speed(twa: twa, tws: tws), 0.1))
    }

    static func pathLength(_ s: ArraySlice<Sample>) -> Double {
        var m = 0.0
        var last: Vec2?
        for x in s { if let l = last { m += (x.position - l).length }; last = x.position }
        return m
    }

    static func score(_ samples: [Sample], course: CourseLayout, boatClass: BoatClass, events: [RaceEvent], seat: Int,
                      cell: BotRaceCell, tier: String, skill: Double, handling: Double) -> [Rounding] {
        var out: [Rounding] = []
        let polar = boatClass.polar
        let W = course.elements[CourseLayout.windwardIndex].marks[0]
        for (leg, legKind) in course.legs.enumerated() {
            guard case .round(let index) = legKind else { continue }
            let element = course.elements[index]
            let centre = course.targetPosition(for: legKind)
            let onLeg = samples.indices.filter { samples[$0].legIndex == leg }
            guard let first = onLeg.first, let lastOn = onLeg.last else { continue }
            // Entry: first tick on this leg, stage 0, within range of the leg's target and (W) below it / (gate) above.
            guard let entry = onLeg.first(where: { i in
                let s = samples[i]
                guard s.stage == 0, (s.position - centre).length < entryRange else { return false }
                switch element {
                case .mark where index == CourseLayout.windwardIndex: return (s.position - W.position).dot(course.upwind) < -5
                case .mark: return true
                case .gate: return (s.position - centre).dot(course.upwind) > 3
                }
            }) else { continue }
            guard let cross = onLeg.first(where: { samples[$0].stage >= 1 }) else { continue }
            // Done: first sample on a later leg.
            guard lastOn + 1 < samples.count, samples[lastOn + 1].legIndex > leg else { continue }
            let done = lastOn + 1
            _ = first
            let e = samples[entry], c = samples[cross], d = samples[done]
            let mode: String, markName: String
            var target: Vec2
            var wrongSide = false, abeam = 0.0, gateMark = "", gateAlong = 0.0
            var roundIdeal = 0.0
            switch element {
            case .mark(let mark, _):
                let approach = index == CourseLayout.windwardIndex ? course.upwind : (mark.position - W.position).normalized
                let side = approach.rightPerp
                if index == CourseLayout.windwardIndex { mode = "up"; markName = "W" } else { mode = "reach"; markName = "O" }
                target = mark.position + side * 3
                abeam = (c.position - mark.position).dot(side)
                // The rounding: from the crossing to leaving, ideally the quarter turn past the mark: ~ 3 m out, 9 m on.
                roundIdeal = (d.position - c.position).length
            case .gate(let left, let right):
                mode = "down"; markName = "G"
                let line = right.position - left.position
                gateAlong = (c.position - left.position).dot(line.normalized) / line.length
                // The nearer mark at the crossing is the one she rounds.
                let nearLeft = (c.position - left.position).length <= (c.position - right.position).length
                gateMark = nearLeft ? "L" : "R"
                let tl = left.position + line.normalized * 4, tr = right.position - line.normalized * 4
                let il = ideal(from: e.position, to: tl, wind: e.windDirection, tws: e.tws, mode: mode, polar: polar)
                let ir = ideal(from: e.position, to: tr, wind: e.windDirection, tws: e.tws, mode: mode, polar: polar)
                target = il.s <= ir.s ? tl : tr
                roundIdeal = (d.position - c.position).length
            }
            // Wrong side / overshoot: ticks before the stage-1 crossing spent past the mark's altitude (W, O) on its wrong
            // side, or below the gate's line; and whether she passed the gate line outside a mark.
            var past = 0, passedOutside = false
            switch element {
            case .mark(let mark, _):
                let approach = index == CourseLayout.windwardIndex ? course.upwind : (mark.position - W.position).normalized
                for s in samples[entry..<cross] where (s.position - mark.position).dot(approach) >= -0.5 {
                    past += 1
                    if (s.position - mark.position).dot(approach.rightPerp) < 0 { wrongSide = true }
                }
            case .gate(let left, let right):
                let along = (right.position - left.position).normalized
                let width = (right.position - left.position).length
                // Up from the line: its normal on the course's upwind side.
                var normal = along.rightPerp
                if normal.dot(course.upwind) < 0 { normal = -normal }
                func side(_ p: Vec2) -> Double { normal.dot(p - left.position) }
                for s in samples[entry..<cross] where side(s.position) < -1 {
                    past += 1
                    let t = (s.position - left.position).dot(along)
                    if t < -2 || t > width + 2 { passedOutside = true }
                }
            }
            let appIdeal = ideal(from: e.position, to: target, wind: e.windDirection, tws: e.tws, mode: mode, polar: polar)
            let approachM = pathLength(samples[entry...cross])
            let approachS = Double(c.tick - e.tick) / Double(Race.tickRate)
            let roundM = pathLength(samples[cross...done])
            let roundS = Double(d.tick - c.tick) / Double(Race.tickRate)
            // Exit: the 15 s after, against the ideal distance for the next leg's mode between where she was and where she got.
            let exitEnd = min(done + exitSeconds * Race.tickRate, samples.count - 1)
            let nextMode: String
            if leg + 1 < course.legs.count, case .round(let ni) = course.legs[leg + 1] {
                nextMode = ni == CourseLayout.windwardIndex ? "up" : ni == CourseLayout.offsetIndex ? "reach" : "down"
            } else { nextMode = "down" }
            let exitM = pathLength(samples[done...exitEnd])
            let exitIdeal = ideal(from: d.position, to: samples[exitEnd].position, wind: d.windDirection, tws: d.tws, mode: nextMode, polar: polar).m
            let nextTarget = leg + 1 < course.legs.count ? course.targetPosition(for: course.legs[leg + 1]) : course.finishLine.centre
            let exitLine = (nextTarget - d.position).normalized
            var exitMaxLateral = 0.0
            for s in samples[done...exitEnd] { exitMaxLateral = max(exitMaxLateral, abs((s.position - d.position).cross(exitLine))) }
            // What she did in the approach window.
            var tacks = 0, gybes = 0, reaching = 0, keepClear = 0, avoidMark = 0, edge = 0, hand = 0, cantTap = 0, penalty = 0
            var flubbed = false, minShare = 10.0
            var branches: [String: Int] = [:], waypoints: [String: Int] = [:], whys: [String: Int] = [:]
            let best = polar.bestUpwind(tws: e.tws)
            var lastTack = e.tack
            for s in samples[entry...done] {
                if s.tack != lastTack {
                    if s.twa < .pi / 2 { tacks += 1 } else { gybes += 1 }
                    lastTack = s.tack
                }
                if mode == "up", s.twa > best.twa + deg2rad(20), (s.position - centre).length < 50, s.stage == 0 { reaching += 1 }
                switch s.probe.evasion {
                case "keepClear", "keepClear+mark": keepClear += 1
                case "avoidMarks", "shoot": avoidMark += 1
                case "edge": edge += 1
                default: break
                }
                if s.probe.handTurning { hand += 1 }
                if s.probe.handTurnFlubbed { flubbed = true }
                if s.probe.wantsOtherTack, !s.probe.cantTapWhy.isEmpty { cantTap += 1; whys[s.probe.cantTapWhy, default: 0] += 1 }
                if s.penalty { penalty += 1 }
                let ref = mode == "up" ? best.speed : mode == "down" ? polar.bestDownwind(tws: s.tws).speed : polar.speed(twa: s.twa, tws: s.tws)
                minShare = min(minShare, s.speed / max(ref, 0.1))
                branches[s.probe.branch, default: 0] += 1
                waypoints[s.probe.waypoint, default: 0] += 1
            }
            var calls: [String] = []
            for ev in events where ev.tick >= e.tick - 5 * Race.tickRate && ev.tick <= d.tick {
                if case .ruleCall(let call) = ev.kind, call.offender == seat || call.victim == seat {
                    calls.append("\(call.rule)\(call.offender == seat ? "!" : "v")")
                }
            }
            var kcRules: [String: Int] = [:]
            for s in samples[entry...done] where !s.probe.keepClearRule.isEmpty { kcRules[s.probe.keepClearRule, default: 0] += 1 }
            let touches = events.filter { ev in
                if case .markTouch(let s, _) = ev.kind, s == seat, ev.tick >= e.tick, ev.tick <= d.tick { return true }
                return false
            }.count
            let tr = Double(Race.tickRate)
            let extraM = (approachM - appIdeal.m) + (roundM - roundIdeal) + (exitM - exitIdeal)
            let extraS = approachS - appIdeal.s
            func top(_ h: [String: Int]) -> String {
                h.sorted { $0.value > $1.value }.prefix(3).map { "\($0.key):\(Int(Double($0.value) / tr))s" }.joined(separator: " ")
            }
            var r = Rounding(seed: cell.seed, venue: cell.venue, conditions: cell.conditions, seat: seat, tier: tier, skill: skill,
                             handling: handling, leg: leg, mark: markName, entryTick: e.tick, crossTick: c.tick, doneTick: d.tick,
                             approachM: approachM, approachIdealM: appIdeal.m, approachS: approachS, approachIdealS: appIdeal.s,
                             roundM: roundM, roundIdealM: roundIdeal, roundS: roundS, exitM: exitM, exitIdealM: exitIdeal,
                             exitMaxLateral: exitMaxLateral, extraM: extraM, extraS: extraS, wrongSide: wrongSide, abeam: abeam,
                             gateMark: gateMark, gateCrossAlong: gateAlong, tacks: tacks, gybes: gybes, reachingS: Double(reaching) / tr,
                             keepClearS: Double(keepClear) / tr, avoidMarkS: Double(avoidMark) / tr, edgeS: Double(edge) / tr,
                             handTurnS: Double(hand) / tr, flubbed: flubbed, cantTapS: Double(cantTap) / tr, cantTapWhy: top(whys),
                             minSpeedShare: minShare, markTouches: touches, penaltyS: Double(penalty) / tr, branches: top(branches),
                             waypoints: top(waypoints), mode: "", pastBeforeCrossS: Double(past) / tr, passedOutside: passedOutside,
                             ruleCalls: calls.joined(separator: ","), keepClearRules: top(kcRules), recoveryS: Double(past) / tr)
            r.mode = classify(r)
            out.append(r)
        }
        return out
    }

    static func classify(_ r: Rounding) -> String {
        let approachExtra = r.approachM - r.approachIdealM
        let roundExtra = r.roundM - r.roundIdealM
        let exitExtra = r.exitM - r.exitIdealM
        if r.penaltyS > 2 { return "penalty-turn" + (r.ruleCalls.isEmpty ? "" : "(" + r.ruleCalls.split(separator: ",").filter { $0.hasSuffix("!") }.map { String($0.dropLast()) }.joined(separator: "+") + ")") }
        if r.mark == "G", r.pastBeforeCrossS >= 3 { return r.passedOutside ? "gate-overshoot-outside" : "gate-overshoot" }
        if r.wrongSide { return r.pastBeforeCrossS >= 3 ? "wrong-side-recovery" : "wrong-side" }
        if r.keepClearS >= 3 { return "avoid-boats" }
        if r.markTouches > 0 { return "mark-touch" }
        if exitExtra >= max(approachExtra, roundExtra), exitExtra > 8 { return "exit-swing" }
        if roundExtra >= approachExtra, roundExtra > 8 { return r.mark == "G" ? "gate-round-wide" : "round-wide" }
        if r.avoidMarkS >= 1.5 { return "avoid-mark" }
        if r.mark == "W" {
            if r.tacks >= 3 { return "multi-tack" }
            if r.tacks == 2 { return r.reachingS >= 3 ? "double-tack+reach" : "double-tack" }
            if r.reachingS >= 4 { return r.tacks == 1 ? "late-tack-reach-in" : "missed-layline-reach" }
            if r.abeam > 12 { return "overstood" }
            if r.flubbed { return "flubbed-turn" }
            if r.minSpeedShare < 0.5 { return "slow" }
            return "other"
        }
        if r.mark == "G" {
            if r.gybes >= 2 { return "multi-gybe" }
            if r.flubbed { return "flubbed-gybe" }
            if r.minSpeedShare < 0.5 { return "slow" }
            return "other"
        }
        if r.flubbed { return "flubbed-turn" }
        if r.minSpeedShare < 0.5 { return "slow" }
        return "other"
    }

    // MARK: - Report

    static func report(_ all: [Rounding], _ o: Options) {
        print("roundings: \(all.count)")
        func dist(_ xs: [Double]) -> String {
            guard !xs.isEmpty else { return "-" }
            let s = xs.sorted()
            func q(_ p: Double) -> Double { s[min(s.count - 1, Int(Double(s.count) * p))] }
            return "n=\(s.count) median \(fmt(q(0.5))) p90 \(fmt(q(0.9))) p97 \(fmt(q(0.97))) max \(fmt(s.last!)) " +
                   ">=30m \(s.filter { $0 >= 30 }.count) >=50m \(s.filter { $0 >= 50 }.count)"
        }
        for mark in ["W", "O", "G"] {
            let rs = all.filter { $0.mark == mark }
            print("\(mark): extraM \(dist(rs.map(\.extraM)))")
            print("   extraS(approach) \(dist(rs.map(\.extraS)))")
            if mark == "W" { print("   wrong side \(rs.filter(\.wrongSide).count)/\(rs.count); abeam median \(fmt(rs.map(\.abeam).sorted()[max(0, rs.count / 2)]))") }
        }
        func table(_ title: String, _ key: (Rounding) -> String, _ rs: [Rounding]) {
            print("\n\(title) (roundings with extra >= \(Int(o.minExtra)) m; count, share, sum extra m, mean extra s):")
            let total = rs.count
            var groups: [String: [Rounding]] = [:]
            for r in rs { groups[key(r), default: []].append(r) }
            for (k, g) in groups.sorted(by: { $0.value.count > $1.value.count }) {
                let meanS = g.map(\.extraS).reduce(0, +) / Double(g.count)
                print("  \(k.padding(toLength: 22, withPad: " ", startingAt: 0)) \(g.count)  \(fmt(Double(g.count) / Double(max(total, 1)) * 100, 0))%  \(fmt(g.map(\.extraM).reduce(0, +), 0)) m  \(fmt(meanS)) s")
            }
        }
        let tail = all.filter { $0.extraM >= o.minExtra }
        print("\ntail: \(tail.count) of \(all.count) roundings lose >= \(Int(o.minExtra)) m")
        table("by mode", \.mode, tail)
        table("by mark", \.mark, tail)
        table("by tier", \.tier, tail)
        table("by venue", \.venue, tail)
        table("by conditions", \.conditions, tail)
        table("by mode x mark", { "\($0.mark) \($0.mode)" }, tail)
        print("\nall roundings by mode (count, sum extra m):")
        var groups: [String: [Rounding]] = [:]
        for r in all { groups[r.mode, default: []].append(r) }
        for (k, g) in groups.sorted(by: { $0.value.map(\.extraM).reduce(0, +) > $1.value.map(\.extraM).reduce(0, +) }) {
            print("  \(k.padding(toLength: 22, withPad: " ", startingAt: 0)) \(g.count)  \(fmt(g.map(\.extraM).reduce(0, +), 0)) m")
        }
        print("\nworst 40:")
        for r in all.sorted(by: { $0.extraM > $1.extraM }).prefix(40) {
            print("  seed \(r.seed) \(r.venue) \(r.conditions) seat \(r.seat) \(r.tier) skill \(fmt(r.skill, 2)) hand \(fmt(r.handling, 2)) leg \(r.leg) \(r.mark): extra \(fmt(r.extraM, 0)) m / \(fmt(r.extraS, 0)) s [approach +\(fmt(r.approachM - r.approachIdealM, 0)) round +\(fmt(r.roundM - r.roundIdealM, 0)) exit +\(fmt(r.exitM - r.exitIdealM, 0))] \(r.mode) wrong=\(r.wrongSide) abeam \(fmt(r.abeam, 0)) tacks \(r.tacks) gybes \(r.gybes) reach \(fmt(r.reachingS, 0))s kc \(fmt(r.keepClearS, 0))s am \(fmt(r.avoidMarkS, 0))s hand \(fmt(r.handTurnS, 0))s flub=\(r.flubbed) cantTap \(fmt(r.cantTapS, 0))s[\(r.cantTapWhy)] minV \(fmt(r.minSpeedShare, 2)) touch \(r.markTouches) past \(fmt(r.pastBeforeCrossS, 0))s out=\(r.passedOutside) calls[\(r.ruleCalls)] kcr[\(r.keepClearRules)] br[\(r.branches)] wp[\(r.waypoints)]")
        }
    }

    static func printTrace(_ r: Rounding, _ samples: [Sample], _ info: (course: CourseLayout, boatClass: BoatClass, events: [RaceEvent])) {
        let course = info.course
        guard case .round(let index) = course.legs[r.leg] else { return }
        let centre = course.targetPosition(for: course.legs[r.leg])
        let marks = course.elements[index].marks
        print("\n=== trace seed \(r.seed) \(r.venue) \(r.conditions) seat \(r.seat) \(r.tier) skill \(fmt(r.skill, 2)) hand \(fmt(r.handling, 2)) leg \(r.leg) \(r.mark) extra \(fmt(r.extraM, 0)) m mode \(r.mode)")
        print("    marks: " + marks.map { "\($0.name) (\(fmt($0.position.x, 0)), \(fmt($0.position.y, 0)))" }.joined(separator: ", ") + "  upwind axis \(fmt(rad2deg(course.axis), 0))°")
        print("    t     up    across  dist  hdg  twa  spd  tack st  branch           waypoint      evasion         aim    rel   lat/cor   hand  cantTap   notes")
        let from = max(0, r.entryTick - 15 * Race.tickRate), to = min(samples.last?.tick ?? 0, r.doneTick + 15 * Race.tickRate)
        var lastTack: Tack?
        for s in samples where s.tick >= from && s.tick <= to && s.tick % Race.tickRate == 0 {
            let rel = s.position - centre
            let up = rel.dot(course.upwind), across = rel.dot(course.right)
            var notes = ""
            if let l = lastTack, l != s.tack { notes += s.twa < .pi / 2 ? "TACKED " : "GYBED " }
            lastTack = s.tack
            if s.isTacking { notes += "tacking " }
            if s.penalty { notes += "PENALTY " }
            if s.isPlaning { notes += "plane " }
            for ev in info.events where ev.tick > s.tick - Race.tickRate && ev.tick <= s.tick {
                if case .markTouch(let seat, let m) = ev.kind, seat == r.seat { notes += "TOUCH \(m) " }
                if case .ruleCall(let call) = ev.kind, call.offender == r.seat || call.victim == r.seat { notes += "CALL \(call.rule) off \(call.offender) " }
            }
            let stageMark = s.tick == r.crossTick ? "*" : s.tick == r.doneTick ? "#" : " "
            print("  \(String(format: "%5d", s.tick / Race.tickRate))\(stageMark) \(String(format: "%6.0f %6.0f %5.0f %4.0f %4.0f %4.1f", up, across, rel.length, rad2deg(s.heading), rad2deg(s.twa), s.speed))  \(s.tack == .starboard ? "S" : "P")   \(s.legIndex).\(s.stage) \(s.probe.branch.padding(toLength: 16, withPad: " ", startingAt: 0)) \(s.probe.waypoint.padding(toLength: 13, withPad: " ", startingAt: 0)) \((s.probe.evasion + (s.probe.keepClearRule.isEmpty ? "" : "/" + s.probe.keepClearRule)).padding(toLength: 15, withPad: " ", startingAt: 0)) \(String(format: "%3.0f", s.probe.aimAngleDeg))\(s.probe.aimTack == .starboard ? "S" : "P")\(s.probe.pinching ? "p" : " ") \(String(format: "%5.0f", s.probe.relativeDeg)) \(String(format: "%4.0f/%-3.0f", s.probe.lateral, s.probe.corridor)) \(s.probe.handTurning ? (s.probe.handTurnFlubbed ? "FLUB" : "turn") : "    ")  \((s.probe.wantsOtherTack ? s.probe.cantTapWhy : "").padding(toLength: 9, withPad: " ", startingAt: 0)) \(notes)")
        }
    }
}
