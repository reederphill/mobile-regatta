import Foundation
import RegattaBots
import RegattaCore

// #379 PR 1 (report-only): the lanes rows. How often a boat has another in her air after the gun, and what the fleet
// does with it: upwind, a boat on her tack in her ribbons (U1, "sit on him"), footing out of them (U3), a boat to
// windward in her backwind (U1b, the safe leeward) and a crossing she could tack on (U2); downwind, a boat ahead lined
// up under her (D1, "blanket"), a trailer gybing away (D2) and a pass close by (D3). Each row is the #379 brief's
// `lanes.py` and `chances.py`, ported: the race's own state once a second after the gun (`tick % Race.tickRate == 0`),
// both boats racing and on the same leg, as the scratch dump read it. It reads the race (`race.wake`, the backwind
// envelope), so it is the truth, not a bot's forecast. Nothing here steers a boat: the harness reads the race, as the
// tally does.

/// How a boat was sailing at a sample (#379): upwind (on a beat leg, the wind under 70° off her bow) or downwind (on a
/// run leg, the wind past 110°); neither on a reach, a rounding or a beat sailed free.
enum LaneMode: Hashable, Sendable {
    case upwind, downwind

    static let upwindDegrees = 70.0
    static let downwindDegrees = 110.0

    init?(kind: LegKind?, twaDegrees: Double) {
        switch kind {
        case .firstBeat?, .beat?: if twaDegrees < Self.upwindDegrees { self = .upwind; return }
        case .run?, .lastRun?: if twaDegrees > Self.downwindDegrees { self = .downwind; return }
        default: break
        }
        return nil
    }
}

/// One racing boat once a second after the gun (#379). Positions and distances are hull lengths; `x` across the
/// course (to its right looking upwind), `y` up it, from the start line's centre; the unit vectors in the same frame.
struct LaneSample: Hashable, Sendable {
    var leg: Int
    var mode: LaneMode?
    var x: Double
    var y: Double
    /// Her heading.
    var forwardX: Double
    var forwardY: Double
    /// Where her wind comes from.
    var windX: Double
    var windY: Double
    var starboard: Bool
    /// Her velocity over ground up the course, m/s.
    var vmg: Double
    /// Hull lengths to her leg's mark (0 past the last).
    var toMark: Double
}

/// Two racing boats on the same leg within `LaneTally.pairLengths` at a sample (#379), `first` < `second`: the
/// distance, hull lengths, and each one's air at the other: her ribbons' loss there (`race.wake`), and her backwind's
/// header there, degrees (the class's header times her backwind envelope).
struct LanePair: Hashable, Sendable {
    var first: Int
    var second: Int
    var distance: Double
    var firstRibbons: Double
    var firstBackwind: Double
    var secondRibbons: Double
    var secondBackwind: Double
}

/// A run of seconds one boat (`caster`) had another (`victim`) in her air (#379): her ribbons' loss at it at least
/// `LaneTally.ribbonLoss`, or her backwind at least `LaneTally.backwindDegrees` of header there; both on the same leg
/// and sailing the same way (`LaneMode`); gaps of `LaneTally.gapSeconds` or less, `LaneTally.minSeconds` long or longer.
public struct LaneEpisode: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// U1: upwind, on the same tack, mostly her ribbons (she ahead or to windward).
        case ribbons
        /// U1b: upwind, on the same tack, mostly her backwind (the victim to windward of her: the safe leeward).
        case backwind
        /// D1: downwind, the victim ahead of her along her heading.
        case downwind
    }

    /// How it ended, the first that holds: either boat's last sample within a second of its end (the race ended for
    /// one); her tack or gybe, from a second into it to 3 s after (before or with the victim's); the victim's; either
    /// rounding a mark (from its start to 3 s after); or neither (it sailed out).
    public enum End: String, Codable, CaseIterable, Sendable {
        case raceEnd, casterTurned, victimTurned, mark, sailedOut
    }

    /// How the victim sailed out, from her offset in the caster's frame a second after the end against the start: to
    /// leeward by more than 0.3 L (not dropping back more than 1 L), astern by more than 1 L, to windward by more than
    /// 0.3 L, or none of those.
    public enum Exit: String, Codable, CaseIterable, Sendable {
        case footedOut, droppedAstern, pinchedOut, other
    }

    public var kind: Kind
    public var caster: Int
    public var victim: Int
    /// Its first second after the gun, and its length in seconds (first to last in her air).
    public var start: Int
    public var seconds: Int
    public var end: End
    /// Sailed out only, when both boats were on the same leg a second after it.
    public var exit: Exit?
    /// Her gain over the victim (distance to the mark made good, less the victim's), hull lengths, over the episode
    /// to a second after it, less the pair's own rate over the 20 s before: their speed difference out. Nil when either
    /// boat was off the leg at an end of either span, or it began at the gun.
    public var excessLengths: Double?
    /// The excess as seconds at her mean VMG over the episode; nil under 0.3 m/s.
    public var excessSeconds: Double?
    /// Whether she was nearer the mark than the victim at its start, and 60 s after its last second; nil when either
    /// boat was not on the episode's leg then.
    public var aheadAtStart: Bool?
    public var aheadAfter: Bool?
    /// The victim was more than 0.5 L ahead of her (along her heading) 15 s before it began, both on one leg (U3').
    public var victimWasAhead: Bool?
    /// Downwind, the victim got out (gybed away, or heated out: sailed out to windward): whether within her reaction
    /// delay plus `LaneTally.outSeconds` of its start. Nil when she didn't get out.
    public var victimOutQuickly: Bool?
}

/// Two boats beating on opposite tacks within 8 L whose order across the course flipped in a second (U2, #379), the
/// one further up the course ahead by `LanesSummary.crossingLengths`.
public struct LaneCrossing: Codable, Hashable, Sendable {
    public var ahead: Int
    public var behind: Int
    public var time: Int
    public var marginLengths: Double
    /// She tacked within 6 s of the cross and an upwind same-tack episode of hers on it began from 6 s before to 20 s
    /// after.
    public var taken: Bool
    /// Her gain over it from 6 s before the cross to 30 s after, hull lengths; nil when either was off the leg.
    public var gainLengths: Double?
}

/// A boat on a run lined up under a trailer (D1's chance, #379): within 8 L, within 30° of dead downwind of her, both
/// downwind and not in her air, for `LanesSummary.lineUpSeconds` or longer (gaps of 2 s or less).
public struct LaneLineUp: Codable, Hashable, Sendable {
    public var trailer: Int
    public var leader: Int
    public var start: Int
    public var seconds: Int
    /// The distance at its first second, hull lengths.
    public var rangeLengths: Double
    /// A D1 episode of the trailer's on the leader began within it or 20 s after.
    public var taken: Bool
}

/// A trailer within 8 L of a boat ahead gybed away from it on a run (D2, #379).
public struct LaneSplit: Codable, Hashable, Sendable {
    public var trailer: Int
    public var leader: Int
    public var time: Int
    /// The leader gybed within 20 s.
    public var covered: Bool
}

/// The order of two running boats within 3 L flipped by distance to the mark (D3, #379).
public struct LanePass: Codable, Hashable, Sendable {
    public var passer: Int
    public var passed: Int
    public var time: Int
    /// The passer went by up the wind of the passed boat.
    public var windward: Bool
    /// Seconds of the 20 before the pass (and its own) each had the other in its air.
    public var passedHadPasserSeconds: Int
    public var passerHadPassedSeconds: Int
}

/// A race's lanes (#379, `LaneTally`): the episodes the rows read (U1, U1b, D1), the crossings in U2's band, the
/// line-ups, splits and passes. Nil in a race the harness didn't watch.
public struct RaceLanes: Codable, Hashable, Sendable {
    public var episodes: [LaneEpisode] = []
    public var crossings: [LaneCrossing] = []
    public var lineUps: [LaneLineUp] = []
    public var splits: [LaneSplit] = []
    public var passes: [LanePass] = []
}

/// The harness's watch of the race after the gun for the lanes rows (#379): every racing boat once a second, and every
/// pair on one leg within `pairLengths`, read into `RaceLanes` at the end.
struct LaneTally {
    /// In her air: her ribbons' loss at least this ...
    static let ribbonLoss = 0.10
    /// ... or her backwind at least this many degrees of header.
    static let backwindDegrees = 2.0
    /// An episode's gaps are this many seconds or fewer, and it is this long or longer.
    static let gapSeconds = 2
    static let minSeconds = 2
    /// Pairs are read within this many hull lengths.
    static let pairLengths = 12.0
    /// A victim downwind is out quickly within her reaction delay and this many seconds.
    static let outSeconds = 3.0

    private let kinds: [LegKind]
    private let hullLength: Double
    private let headerDegrees: Double
    private var samples: [[LaneSample?]] = []
    private var pairs: [[LanePair]] = []

    init(race: Race) {
        kinds = LegKind.kinds(of: race.course)
        hullLength = race.boatClass.hull.length
        headerDegrees = race.boatClass.windShadow.header.map { rad2deg($0.angle) } ?? 0
    }

    /// Call once after each `race.step()`.
    mutating func record(_ race: Race) {
        guard race.tick >= 0, race.tick.isMultiple(of: Race.tickRate) else { return }
        let second = race.tick / Race.tickRate
        while samples.count <= second {
            samples.append(Array(repeating: nil, count: race.boats.count))
            pairs.append([])
        }
        let up = race.course.upwind, across = up.rightPerp
        let origin = race.course.startLine.centre
        let legs = race.course.legs
        for (seat, boat) in race.boats.enumerated() where boat.status == .racing {
            let offset = boat.position - origin
            let leg = boat.legIndex
            let target = leg < legs.count ? race.course.targetPosition(for: legs[leg]) : boat.position
            let wind = Vec2.heading(boat.windDirection)
            samples[second][seat] = LaneSample(
                leg: leg, mode: LaneMode(kind: leg < kinds.count ? kinds[leg] : nil, twaDegrees: rad2deg(boat.twa)),
                x: offset.dot(across) / hullLength, y: offset.dot(up) / hullLength,
                forwardX: boat.forward.dot(across), forwardY: boat.forward.dot(up), windX: wind.dot(across), windY: wind.dot(up),
                starboard: boat.tack == .starboard, vmg: boat.velocityOverGround.dot(up),
                toMark: (target - boat.position).length / hullLength)
        }
        let cones = race.boats.indices.map { race.shadowCone(ofSeat: $0) }
        let boats = race.boats
        for i in boats.indices where boats[i].status == .racing {
            for j in boats.indices where j > i && boats[j].status == .racing && boats[j].legIndex == boats[i].legIndex {
                let distance = (boats[j].position - boats[i].position).length
                guard distance < Self.pairLengths * hullLength else { continue }
                pairs[second].append(LanePair(
                    first: i, second: j, distance: distance / hullLength,
                    firstRibbons: race.wake.loss(of: i, at: boats[j].position, tick: race.tick),
                    firstBackwind: headerDegrees * (cones[i]?.backwindEnvelope(at: boats[j].position) ?? 0),
                    secondRibbons: race.wake.loss(of: j, at: boats[i].position, tick: race.tick),
                    secondBackwind: headerDegrees * (cones[j]?.backwindEnvelope(at: boats[i].position) ?? 0)))
            }
        }
    }

    /// The race's lanes, with each seat's reaction delay (seconds, `BotWeaknesses.reactionDelay`; 0 for a seat no bot
    /// sailed).
    func lanes(_ controllers: SeatControllers) -> RaceLanes {
        let delays = (0..<(samples.map(\.count).max() ?? 0)).map { controllers[$0].driver?.weaknesses.reactionDelay ?? 0 }
        return Self.lanes(samples: samples, pairs: pairs, reactionDelays: delays, hullMetres: hullLength,
                          headerDegrees: headerDegrees)
    }

    /// `lanes.py`'s `analyse`, over `samples` (by second after the gun, then seat; nil when not racing) and `pairs`
    /// (by second).
    static func lanes(samples: [[LaneSample?]], pairs: [[LanePair]], reactionDelays: [Double], hullMetres: Double,
                      headerDegrees: Double) -> RaceLanes {
        let seats = samples.map(\.count).max() ?? 0
        func boat(_ t: Int, _ seat: Int) -> LaneSample? {
            samples.indices.contains(t) && samples[t].indices.contains(seat) ? samples[t][seat] : nil
        }

        // Each seat's turns (her tack changing on one leg) with the way she was sailing, the seconds her leg changed,
        // and her last sample.
        var turns = Array(repeating: [(time: Int, mode: LaneMode?)](), count: seats)
        var legChanges = Array(repeating: [Int](), count: seats)
        var lastSeen = Array(repeating: 0, count: seats)
        var previous = [LaneSample?](repeating: nil, count: seats)
        for t in samples.indices {
            for seat in 0..<seats {
                guard let b = boat(t, seat) else { continue }
                if let p = previous[seat] {
                    if p.starboard != b.starboard && p.leg == b.leg { turns[seat].append((t, p.mode ?? b.mode)) }
                    if p.leg != b.leg { legChanges[seat].append(t) }
                }
                previous[seat] = b
                lastSeen[seat] = t
            }
        }
        func firstTurn(_ seat: Int, _ from: Int, _ to: Int) -> Int? {
            turns[seat].first { from <= $0.time && $0.time <= to }?.time
        }

        // Each ordered pair's seconds in the caster's air, and each pair's distance.
        struct Key: Hashable, Comparable {
            var a: Int, b: Int
            static func < (l: Key, r: Key) -> Bool { (l.a, l.b) < (r.a, r.b) }
        }
        var inAir: [Key: [Int: (ribbons: Double, backwind: Double)]] = [:]
        var near: [Key: [Int: Double]] = [:]
        for (t, list) in pairs.enumerated() {
            for p in list {
                near[Key(a: p.first, b: p.second), default: [:]][t] = p.distance
                if p.firstRibbons >= ribbonLoss || p.firstBackwind >= backwindDegrees {
                    inAir[Key(a: p.first, b: p.second), default: [:]][t] = (p.firstRibbons, p.firstBackwind)
                }
                if p.secondRibbons >= ribbonLoss || p.secondBackwind >= backwindDegrees {
                    inAir[Key(a: p.second, b: p.first), default: [:]][t] = (p.secondRibbons, p.secondBackwind)
                }
            }
        }

        /// The caster's distance to the mark made good over the victim's from `t0` to `t1`, all on one leg.
        func gain(_ a: Int, _ v: Int, _ t0: Int, _ t1: Int) -> Double? {
            guard let a0 = boat(t0, a), let a1 = boat(t1, a), let v0 = boat(t0, v), let v1 = boat(t1, v),
                  a0.leg == a1.leg, v0.leg == v1.leg, a0.leg == v0.leg else { return nil }
            return (a0.toMark - a1.toMark) - (v0.toMark - v1.toMark)
        }

        var lanes = RaceLanes()
        // Upwind same-tack episodes (for U2's take) and D1 episodes (for the line-ups' take), by ordered pair.
        var upwindStarts: [Key: [Int]] = [:]
        var downwindStarts: [Key: [Int]] = [:]
        for key in inAir.keys.sorted() {
            let (a, v) = (key.a, key.b)
            let air = inAir[key] ?? [:]
            let times = air.keys.sorted().filter { t in
                guard let caster = boat(t, a), let victim = boat(t, v), let mode = caster.mode else { return false }
                return mode == victim.mode
            }
            var runs: [[Int]] = []
            for t in times {
                if let last = runs.last?.last, t - last <= gapSeconds + 1 { runs[runs.count - 1].append(t) } else { runs.append([t]) }
            }
            for run in runs {
                guard let t0 = run.first, let t1 = run.last, t1 - t0 + 1 >= minSeconds,
                      let a0 = boat(t0, a), let v0 = boat(t0, v), let mode = a0.mode else { continue }
                let sameTack = a0.starboard == v0.starboard
                let (ahead, windward, _) = frame(a0, v0)
                let kind: LaneEpisode.Kind
                switch mode {
                case .upwind:
                    guard sameTack else { continue }
                    let ribbons = run.reduce(0) { $0 + (air[$1]?.ribbons ?? 0) }
                    let backwind = run.reduce(0) { $0 + (air[$1]?.backwind ?? 0) }
                    kind = headerDegrees > 0 && backwind / headerDegrees > ribbons ? .backwind : .ribbons
                    upwindStarts[key, default: []].append(t0)
                case .downwind:
                    guard ahead > 0 else { continue }
                    kind = .downwind
                    downwindStarts[key, default: []].append(t0)
                }
                let casterTurn = firstTurn(a, t0 + 1, t1 + 3), victimTurn = firstTurn(v, t0 + 1, t1 + 3)
                let rounded = (legChanges[a] + legChanges[v]).contains { t0 <= $0 && $0 <= t1 + 3 }
                let end: LaneEpisode.End
                if lastSeen[a] <= t1 + 1 || lastSeen[v] <= t1 + 1 {
                    end = .raceEnd
                } else if let casterTurn, victimTurn.map({ casterTurn <= $0 }) ?? true {
                    end = .casterTurned
                } else if victimTurn != nil {
                    end = .victimTurned
                } else if rounded {
                    end = .mark
                } else {
                    end = .sailedOut
                }
                let made = gain(a, v, t0, t1 + 1)
                let before = gain(a, v, max(t0 - 20, 0), t0)
                let beforeSeconds = t0 - max(t0 - 20, 0)
                var excess: Double?
                if let made, let before, beforeSeconds > 0 { excess = made - before / Double(beforeSeconds) * Double(t1 + 1 - t0) }
                let vmg = abs(run.reduce(0) { $0 + (boat($1, a)?.vmg ?? 0) } / Double(run.count))
                var exit: LaneEpisode.Exit?
                if end == .sailedOut, let ae = boat(t1 + 1, a), let ve = boat(t1 + 1, v), ae.leg == ve.leg {
                    let (endAhead, endWindward, _) = frame(ae, ve)
                    if endWindward < windward - 0.3 && endAhead > ahead - 1 { exit = .footedOut }
                    else if endAhead < ahead - 1 { exit = .droppedAstern }
                    else if endWindward > windward + 0.3 { exit = .pinchedOut }
                    else { exit = .other }
                }
                func order(_ t: Int) -> Bool? {
                    guard let at = boat(t, a), let vt = boat(t, v), at.leg == vt.leg, at.leg == a0.leg else { return nil }
                    return at.toMark < vt.toMark
                }
                var victimWasAhead: Bool?
                if let ab = boat(t0 - 15, a), let vb = boat(t0 - 15, v), ab.leg == vb.leg { victimWasAhead = frame(ab, vb).ahead > 0.5 }
                var victimOutQuickly: Bool?
                if kind == .downwind {
                    let out = end == .victimTurned ? victimTurn : exit == .pinchedOut ? t1 + 1 : nil
                    let delay = reactionDelays.indices.contains(v) ? reactionDelays[v] : 0
                    victimOutQuickly = out.map { Double($0 - t0) <= delay + outSeconds }
                }
                lanes.episodes.append(LaneEpisode(
                    kind: kind, caster: a, victim: v, start: t0, seconds: t1 - t0 + 1, end: end, exit: exit,
                    excessLengths: excess, excessSeconds: excess.flatMap { vmg < 0.3 ? nil : $0 * hullMetres / vmg },
                    aheadAtStart: order(t0), aheadAfter: order(t1 + 60), victimWasAhead: victimWasAhead,
                    victimOutQuickly: victimOutQuickly))
            }
        }

        // U2 crossings and D3 passes, second to second within a pair.
        for key in near.keys.sorted() {
            let (i, j) = (key.a, key.b)
            let distances = near[key] ?? [:]
            let times = distances.keys.sorted()
            for k in times.indices.dropFirst() {
                let t = times[k], tp = times[k - 1]
                guard t - tp == 1, let bi = boat(t, i), let bj = boat(t, j), let pi = boat(tp, i), let pj = boat(tp, j),
                      bi.leg == bj.leg else { continue }
                if bi.mode == .upwind, bj.mode == .upwind, bi.starboard != bj.starboard, pi.starboard == bi.starboard,
                   pj.starboard == bj.starboard, (pi.x - pj.x) * (bi.x - bj.x) < 0, abs(bi.y - bj.y) < 8 {
                    let (a, v) = bi.y > bj.y ? (i, j) : (j, i)
                    let margin = bi.y > bj.y ? bi.y - bj.y : bj.y - bi.y
                    if LanesSummary.crossingLengths.contains(margin) {
                        let tacked = firstTurn(a, t - 6, t + 6) != nil
                        let took = tacked && (upwindStarts[Key(a: a, b: v)] ?? []).contains { t - 6 <= $0 && $0 <= t + 20 }
                        lanes.crossings.append(LaneCrossing(ahead: a, behind: v, time: t, marginLengths: margin, taken: took,
                                                            gainLengths: gain(a, v, t - 6, t + 30)))
                    }
                }
                if bi.mode == .downwind, bj.mode == .downwind, (distances[t] ?? .infinity) < 3,
                   (pi.toMark - pj.toMark) * (bi.toMark - bj.toMark) < 0 {
                    let (p, q) = bi.toMark < bj.toMark ? (i, j) : (j, i)
                    guard let passer = boat(t, p), let passed = boat(t, q) else { continue }
                    func seconds(_ c: Int, _ v: Int) -> Int {
                        let air = inAir[Key(a: c, b: v)] ?? [:]
                        return (t - 20...t).filter { air[$0] != nil }.count
                    }
                    lanes.passes.append(LanePass(passer: p, passed: q, time: t, windward: frame(passed, passer).upwind > 0,
                                                 passedHadPasserSeconds: seconds(q, p), passerHadPassedSeconds: seconds(p, q)))
                }
            }
        }

        // D1 line-ups: the boat ahead within 8 L and 30° of dead downwind of the trailer, not in her air.
        let lineUpCos = cos(LanesSummary.lineUpDegrees * (Double.pi / 180))
        for key in near.keys.sorted() {
            let (i, j) = (key.a, key.b)
            let distances = near[key] ?? [:]
            var spell: (trailer: Int, leader: Int, t0: Int, t1: Int, range: Double)?
            func close() {
                guard let s = spell, s.t1 - s.t0 + 1 >= LanesSummary.lineUpSeconds else { return }
                let took = (downwindStarts[Key(a: s.trailer, b: s.leader)] ?? []).contains { s.t0 <= $0 && $0 <= s.t1 + 20 }
                lanes.lineUps.append(LaneLineUp(trailer: s.trailer, leader: s.leader, start: s.t0, seconds: s.t1 - s.t0 + 1,
                                                rangeLengths: s.range, taken: took))
            }
            for t in distances.keys.sorted() {
                let distance = distances[t] ?? .infinity
                var lined: (Int, Int)?
                if let bi = boat(t, i), let bj = boat(t, j), bi.mode == .downwind, bj.mode == .downwind, distance < 8 {
                    let (a, v) = bi.toMark > bj.toMark ? (i, j) : (j, i)
                    let (ta, tv) = bi.toMark > bj.toMark ? (bi, bj) : (bj, bi)
                    let ox = tv.x - ta.x, oy = tv.y - ta.y
                    let d = hypot(ox, oy)
                    let cosine = -(ox * ta.windX + oy * ta.windY) / (d == 0 ? 1 : d)
                    if cosine > lineUpCos && inAir[Key(a: a, b: v)]?[t] == nil { lined = (a, v) }
                }
                if let lined, let s = spell, s.trailer == lined.0, s.leader == lined.1, t - s.t1 <= 2 {
                    spell?.t1 = t
                } else {
                    close()
                    spell = lined.map { (trailer: $0.0, leader: $0.1, t0: t, t1: t, range: distance) }
                }
            }
            close()
        }

        // D2 splits: a trailer within 8 L gybes away from the boat ahead; covered if it gybes within 20 s.
        for seat in 0..<seats {
            for turn in turns[seat] where turn.mode == .downwind {
                guard let trailer = boat(turn.time, seat) else { continue }
                for other in 0..<seats where other != seat {
                    guard let leader = boat(turn.time, other), leader.leg == trailer.leg, leader.mode == .downwind,
                          leader.toMark < trailer.toMark, hypot(leader.x - trailer.x, leader.y - trailer.y) <= 8,
                          let before = boat(turn.time - 3, other), before.starboard != trailer.starboard else { continue }
                    lanes.splits.append(LaneSplit(trailer: seat, leader: other, time: turn.time,
                                                  covered: firstTurn(other, turn.time, turn.time + 20) != nil))
                }
            }
        }
        return lanes
    }

    /// `other`'s offset from `boat` in her frame, hull lengths: ahead along her heading, to windward across it, and up
    /// her wind.
    static func frame(_ boat: LaneSample, _ other: LaneSample) -> (ahead: Double, windward: Double, upwind: Double) {
        let ox = other.x - boat.x, oy = other.y - boat.y
        let ahead = ox * boat.forwardX + oy * boat.forwardY
        var nx = -boat.forwardY, ny = boat.forwardX
        if nx * boat.windX + ny * boat.windY < 0 { (nx, ny) = (-nx, -ny) }
        return (ahead, ox * nx + oy * ny, ox * boat.windX + oy * boat.windY)
    }
}

/// The lanes rows (#379) pooled over a run's races: `--diagnose`'s "lanes" table (the report's `diagnose.lanes`), by
/// the tier of the boat with the chance (the caster, the boat crossing ahead, the trailer lined up, the leader split
/// from, the boat passed), `all` first. Chances a race are over the races with a boat of the tier.
public struct LanesSummary: Codable, Hashable, Sendable {
    /// U2's band: crossing ahead by this many hull lengths (from, to exclusive).
    public static let crossingLengths = 1.5..<5.0
    /// D1's line-ups: within this many degrees of dead downwind, for this many seconds or more ...
    public static let lineUpDegrees = 30.0
    public static let lineUpSeconds = 3
    /// ... split at this range, hull lengths (its first second's).
    public static let closeLineUpLengths = 4.0
    /// A playing seat: a live bot whose engagement is this or more (`laneEngagement`).
    public static let playingEngagement = 0.3
    /// D3: the passer had her in its air this many seconds of the 20 before the pass, or more.
    public static let passAirSeconds = 3

    public var races: Int
    public var tiers: [TierRow]

    /// A count a race over the races: the mean, the p90 (`nearestRank`) and the most.
    public struct PerRace: Codable, Hashable, Sendable {
        public var mean: Double
        public var p90: Double
        public var max: Int

        init(_ counts: [Int]) {
            mean = counts.isEmpty ? 0 : Double(counts.reduce(0, +)) / Double(counts.count)
            p90 = nearestRank(counts.map(Double.init).sorted(), 0.9)
            max = counts.max() ?? 0
        }
    }

    /// One tier's rows (`DiagnoseSummary.all` for every tier). Shares are of the case's chances; values are means of
    /// `LaneEpisode.excessLengths` / `excessSeconds` (nil when none); "lost" the share of those she led at the start
    /// and trailed 60 s on, "took" the reverse.
    public struct TierRow: Codable, Hashable, Sendable {
        public var tier: String
        public var races: Int
        // U1: a boat on her tack in her ribbons.
        public var u1: PerRace
        public var u1LetGoShare: Double
        public var u1LetGo: PerRace
        public var u1PlayingLetGoShare: Double
        public var u1PlayingEpisodes: Int
        public var u1HeldSeconds: PerRace
        public var u1HeldOverLetGoLengths: Double?
        public var u1HeldOverLetGoSeconds: Double?
        public var u1PlaceLostHeld: Double
        public var u1PlaceLostLetGo: Double
        public var u1EndShares: [String: Double]
        public var u1ExitShares: [String: Double]
        // U3: footed out of her ribbons to leeward; U3': a boat astern 15 s before has her in its backwind.
        public var u3: PerRace
        public var u3Prime: PerRace
        public var u3PrimeLengths: Double?
        // U1b: a boat to windward in her backwind.
        public var u1b: PerRace
        public var u1bHeldShare: Double
        public var u1bLengths: Double?
        public var u1bLetGoPerRace: Double
        // U2: crossing ahead in the band.
        public var u2: PerRace
        public var u2TakenShare: Double
        public var u2TakenOverNotLengths: Double?
        public var u2UntakenPerRace: Double
        // D1: line-ups, then the episodes.
        public var d1LineUps: PerRace
        public var d1TakenShare: Double
        public var d1UntakenPerRace: Double
        public var d1CloseLineUps: Int
        public var d1CloseTakenShare: Double
        public var d1FarLineUps: Int
        public var d1FarTakenShare: Double
        public var d1Episodes: PerRace
        public var d1HeldMedianSeconds: Double
        public var d1Lengths: Double?
        public var d1Seconds: Double?
        public var d1TookPlaceShare: Double
        public var d1VictimGybedShare: Double
        public var d1CasterGybedShare: Double
        public var d1VictimHeatedOutShare: Double
        public var d1VictimOutShare: Double
        public var d1VictimOutQuicklyShare: Double
        // D2: a trailer gybes away.
        public var d2: PerRace
        public var d2CoveredShare: Double
        public var d2UncoveredPerRace: Double
        // D3: passes within 3 L.
        public var d3: PerRace
        public var d3DefendedShare: Double
        public var d3UndefendedPerRace: Double
        public var d3Windward: Int
        public var d3Leeward: Int
        public var d3PasserHadHerShare: Double
        public var d3WindwardPasserHadHerShare: Double
    }

    /// Over the races the harness watched after the gun (`RaceResult.lanes`); nil if none.
    public init?(_ results: [RaceResult]) {
        let watched = results.filter { $0.lanes != nil }
        guard !watched.isEmpty else { return nil }
        races = watched.count
        let sailed = BotTier.allCases.filter { tier in watched.contains { $0.seats.contains { $0.tier == tier } } }
        tiers = ([DiagnoseSummary.all] + sailed.map(\.rawValue)).map { Self.row(watched, tier: $0) }
    }

    private static func row(_ watched: [RaceResult], tier: String) -> TierRow {
        let races = watched.filter { race in tier == DiagnoseSummary.all || race.seats.contains { $0.tier.rawValue == tier } }
        func ofTier(_ race: RaceResult, _ seat: Int) -> Bool {
            tier == DiagnoseSummary.all || (race.seats.indices.contains(seat) && race.seats[seat].tier.rawValue == tier)
        }
        func playing(_ race: RaceResult, _ seat: Int) -> Bool {
            race.seats.indices.contains(seat) && (race.seats[seat].engagement ?? -1) >= playingEngagement
        }
        func gather<T>(_ records: (RaceLanes) -> [T], seat: (T) -> Int) -> [[T]] {
            races.map { race in (race.lanes.map(records) ?? []).filter { ofTier(race, seat($0)) } }
        }
        func perRace<T>(_ byRace: [[T]], _ include: (T) -> Bool = { _ in true }) -> PerRace {
            PerRace(byRace.map { $0.filter(include).count })
        }
        func mean(_ values: [Double?]) -> Double? {
            let present = values.compactMap { $0 }
            return present.isEmpty ? nil : present.reduce(0, +) / Double(present.count)
        }
        func difference(_ a: Double?, _ b: Double?) -> Double? { a.flatMap { a in b.map { a - $0 } } }
        func lost(_ rows: [LaneEpisode]) -> Double {
            let placed = rows.filter { $0.aheadAtStart != nil && $0.aheadAfter != nil }
            return Double(placed.filter { $0.aheadAtStart == true && $0.aheadAfter == false }.count) / Double(max(placed.count, 1))
        }
        let n = Double(max(races.count, 1))

        let episodes = gather({ $0.episodes }, seat: \.caster)
        // U1
        let u1ByRace = episodes.map { $0.filter { $0.kind == .ribbons } }
        let u1 = u1ByRace.flatMap { $0 }
        let letGo = u1.filter { $0.end == .casterTurned }
        let kept = u1.filter { $0.end != .casterTurned && $0.end != .mark }
        let playingU1 = zip(races, u1ByRace).flatMap { race, rows in rows.filter { playing(race, $0.caster) } }
        // U1b, U3'
        let u1bByRace = episodes.map { $0.filter { $0.kind == .backwind } }
        let u1b = u1bByRace.flatMap { $0 }
        let u3PrimeByRace = u1bByRace.map { $0.filter { $0.victimWasAhead == true } }
        // U2
        let crossingsByRace = gather({ $0.crossings }, seat: \.ahead)
        let crossings = crossingsByRace.flatMap { $0 }
        let taken = crossings.filter(\.taken), untaken = crossings.filter { !$0.taken }
        // D1
        let lineUpsByRace = gather({ $0.lineUps }, seat: \.trailer)
        let lineUps = lineUpsByRace.flatMap { $0 }
        let close = lineUps.filter { $0.rangeLengths <= closeLineUpLengths }, far = lineUps.filter { $0.rangeLengths > closeLineUpLengths }
        let d1ByRace = episodes.map { $0.filter { $0.kind == .downwind } }
        let d1 = d1ByRace.flatMap { $0 }
        let placedD1 = d1.filter { $0.aheadAtStart != nil && $0.aheadAfter != nil }
        let out = d1.filter { $0.victimOutQuickly != nil }
        // D2, D3
        let splitsByRace = gather({ $0.splits }, seat: \.leader)
        let splits = splitsByRace.flatMap { $0 }
        let passesByRace = gather({ $0.passes }, seat: \.passed)
        let passes = passesByRace.flatMap { $0 }
        let windward = passes.filter(\.windward)

        func shares<K: RawRepresentable & CaseIterable>(_ rows: [LaneEpisode], _ key: (LaneEpisode) -> K?) -> [String: Double]
            where K.RawValue == String {
            Dictionary(uniqueKeysWithValues: K.allCases.map { k in
                (k.rawValue, share(rows.filter { key($0)?.rawValue == k.rawValue }.count, of: rows.count))
            })
        }

        return TierRow(
            tier: tier, races: races.count,
            u1: perRace(u1ByRace), u1LetGoShare: share(letGo.count, of: u1.count),
            u1LetGo: perRace(u1ByRace) { $0.end == .casterTurned },
            u1PlayingLetGoShare: share(playingU1.filter { $0.end == .casterTurned }.count, of: playingU1.count),
            u1PlayingEpisodes: playingU1.count,
            u1HeldSeconds: PerRace(u1ByRace.map { $0.reduce(0) { $0 + $1.seconds } }),
            u1HeldOverLetGoLengths: difference(mean(kept.map(\.excessLengths)), mean(letGo.map(\.excessLengths))),
            u1HeldOverLetGoSeconds: difference(mean(kept.map(\.excessSeconds)), mean(letGo.map(\.excessSeconds))),
            u1PlaceLostHeld: lost(kept), u1PlaceLostLetGo: lost(letGo),
            u1EndShares: shares(u1) { $0.end }, u1ExitShares: shares(u1) { $0.exit },
            u3: perRace(u1ByRace) { $0.exit == .footedOut },
            u3Prime: perRace(u3PrimeByRace), u3PrimeLengths: mean(u3PrimeByRace.flatMap { $0 }.map(\.excessLengths)),
            u1b: perRace(u1bByRace),
            u1bHeldShare: 1 - Double(u1b.filter { $0.end == .casterTurned }.count) / Double(max(u1b.count, 1)),
            u1bLengths: mean(u1b.map(\.excessLengths)),
            u1bLetGoPerRace: Double(u1b.filter { $0.end == .casterTurned }.count) / n,
            u2: perRace(crossingsByRace), u2TakenShare: share(taken.count, of: crossings.count),
            u2TakenOverNotLengths: difference(mean(taken.map(\.gainLengths)), mean(untaken.map(\.gainLengths))),
            u2UntakenPerRace: Double(untaken.count) / n,
            d1LineUps: perRace(lineUpsByRace), d1TakenShare: share(lineUps.filter(\.taken).count, of: lineUps.count),
            d1UntakenPerRace: Double(lineUps.filter { !$0.taken }.count) / n,
            d1CloseLineUps: close.count, d1CloseTakenShare: share(close.filter(\.taken).count, of: close.count),
            d1FarLineUps: far.count, d1FarTakenShare: share(far.filter(\.taken).count, of: far.count),
            d1Episodes: perRace(d1ByRace),
            d1HeldMedianSeconds: nearestRank(d1.map { Double($0.seconds) }.sorted(), 0.5),
            d1Lengths: mean(d1.map(\.excessLengths)), d1Seconds: mean(d1.map(\.excessSeconds)),
            d1TookPlaceShare: Double(placedD1.filter { $0.aheadAtStart == false && $0.aheadAfter == true }.count)
                / Double(max(placedD1.count, 1)),
            d1VictimGybedShare: share(d1.filter { $0.end == .victimTurned }.count, of: d1.count),
            d1CasterGybedShare: share(d1.filter { $0.end == .casterTurned }.count, of: d1.count),
            d1VictimHeatedOutShare: share(d1.filter { $0.exit == .pinchedOut }.count, of: d1.count),
            d1VictimOutShare: share(out.count, of: d1.count),
            d1VictimOutQuicklyShare: share(out.filter { $0.victimOutQuickly == true }.count, of: d1.count),
            d2: perRace(splitsByRace), d2CoveredShare: share(splits.filter(\.covered).count, of: splits.count),
            d2UncoveredPerRace: Double(splits.filter { !$0.covered }.count) / n,
            d3: perRace(passesByRace),
            d3DefendedShare: share(passes.filter { $0.passedHadPasserSeconds >= passAirSeconds }.count, of: passes.count),
            d3UndefendedPerRace: Double(passes.filter { $0.passedHadPasserSeconds < passAirSeconds }.count) / n,
            d3Windward: windward.count, d3Leeward: passes.count - windward.count,
            d3PasserHadHerShare: share(passes.filter { $0.passerHadPassedSeconds >= passAirSeconds }.count, of: passes.count),
            d3WindwardPasserHadHerShare: share(windward.filter { $0.passerHadPassedSeconds >= passAirSeconds }.count,
                                               of: windward.count))
    }

    public var lines: [String] {
        let single = tiers.count == 2
        let shown = tiers.filter { !single || $0.tier != DiagnoseSummary.all }
        func perRace(_ p: PerRace) -> String { "\(fixed(p.mean, 2)) / \(fixed(p.p90, 0)) / \(p.max)" }
        func signed(_ value: Double?, _ places: Int) -> String { value.map { String(format: "%+.\(places)f", $0) } ?? "-" }
        func value(_ lengths: Double?, _ seconds: Double?) -> String { "\(signed(lengths, 2)) L (\(signed(seconds, 1)) s)" }
        func share3(_ value: Double) -> String { fixed(value, 3) }
        let rows: [(String, (TierRow) -> String)] = [
            ("races", { "\($0.races)" }),
            ("U1 sit on him: a race (mean / p90 / max)", { perRace($0.u1) }),
            ("U1 let go by her own tack", { share3($0.u1LetGoShare) }),
            ("U1 let go, playing seats (eng >= \(fixed(Self.playingEngagement, 1)))",
             { "\(share3($0.u1PlayingLetGoShare)) of \($0.u1PlayingEpisodes)" }),
            ("U1 let go a race", { perRace($0.u1LetGo) }),
            ("U1 seconds held a race", { perRace($0.u1HeldSeconds) }),
            ("U1 held vs let go", { value($0.u1HeldOverLetGoLengths, $0.u1HeldOverLetGoSeconds) }),
            ("U1 place lost 60 s on, held / let go", { "\(share3($0.u1PlaceLostHeld)) / \(share3($0.u1PlaceLostLetGo))" }),
            ("U1 ends: sailed out / victim tacked / mark / race end", { row in
                [LaneEpisode.End.sailedOut, .victimTurned, .mark, .raceEnd].map { share3(row.u1EndShares[$0.rawValue] ?? 0) }
                    .joined(separator: " / ")
            }),
            ("U1 sailed out: astern / footed out / other / pinched out", { row in
                [LaneEpisode.Exit.droppedAstern, .footedOut, .other, .pinchedOut].map { share3(row.u1ExitShares[$0.rawValue] ?? 0) }
                    .joined(separator: " / ")
            }),
            ("U3 squeeze, footed out to leeward: a race", { perRace($0.u3) }),
            ("U3' safe leeward from behind: a race; L", { "\(perRace($0.u3Prime)); \(signed($0.u3PrimeLengths, 2))" }),
            ("U1b safe leeward: a race", { perRace($0.u1b) }),
            ("U1b held; L a hold; let go a race",
             { "\(share3($0.u1bHeldShare)); \(signed($0.u1bLengths, 2)); \(fixed($0.u1bLetGoPerRace, 2))" }),
            ("U2 crossing ahead 1.5-5 L: a race", { perRace($0.u2) }),
            ("U2 taken; taken vs not L; untaken a race",
             { "\(share3($0.u2TakenShare)); \(signed($0.u2TakenOverNotLengths, 2)); \(fixed($0.u2UntakenPerRace, 1))" }),
            ("D1 lined up, not in her air: a race", { perRace($0.d1LineUps) }),
            ("D1 taken; untaken a race", { "\(share3($0.d1TakenShare)); \(fixed($0.d1UntakenPerRace, 1))" }),
            ("D1 taken <= \(fixed(Self.closeLineUpLengths, 0)) L / \(fixed(Self.closeLineUpLengths, 0))-8 L",
             { "\(share3($0.d1CloseTakenShare)) of \($0.d1CloseLineUps) / \(share3($0.d1FarTakenShare)) of \($0.d1FarLineUps)" }),
            ("D1 episodes: a race", { perRace($0.d1Episodes) }),
            ("D1 episode value; took the place in 60 s", { "\(value($0.d1Lengths, $0.d1Seconds)); \(share3($0.d1TookPlaceShare))" }),
            ("D1 held p50 s; victim gybed out; she gybed off", {
                "\(fixed($0.d1HeldMedianSeconds, 0)); \(share3($0.d1VictimGybedShare)); \(share3($0.d1CasterGybedShare))"
            }),
            ("D1 victims out (gybed or heated out); heated out; within reaction + \(fixed(LaneTally.outSeconds, 0)) s", {
                "\(share3($0.d1VictimOutShare)); \(share3($0.d1VictimHeatedOutShare)); \(share3($0.d1VictimOutQuicklyShare))"
            }),
            ("D2 a trailer within 8 L gybes away: a race", { perRace($0.d2) }),
            ("D2 covered in 20 s; uncovered a race", { "\(share3($0.d2CoveredShare)); \(fixed($0.d2UncoveredPerRace, 1))" }),
            ("D3 passes within 3 L: a race", { perRace($0.d3) }),
            ("D3 defended (passer in her air >= 3 s); undefended a race",
             { "\(share3($0.d3DefendedShare)); \(fixed($0.d3UndefendedPerRace, 2))" }),
            ("D3 to windward / to leeward", { "\($0.d3Windward) / \($0.d3Leeward)" }),
            ("D3 the passer had her in its air >= 3 s: all; windward passes",
             { "\(share3($0.d3PasserHadHerShare)); \(share3($0.d3WindwardPasserHadHerShare))" }),
        ]
        var lines = ["lanes (#379): \(races) races, after the gun once a second, both boats racing on one leg; in her air is "
            + "her ribbons' loss >= \(fixed(LaneTally.ribbonLoss, 2)) or her backwind >= \(fixed(LaneTally.backwindDegrees, 0)) "
            + "deg of header there; an episode >= \(LaneTally.minSeconds) s with gaps <= \(LaneTally.gapSeconds) s; values are "
            + "her gain less the pair's rate over the 20 s before; by the tier of the boat with the chance"]
        lines += table([["lanes"] + shown.map(\.tier)] + rows.map { label, cell in [label] + shown.map(cell) })
        return lines
    }
}
