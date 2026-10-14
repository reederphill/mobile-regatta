import Foundation
import RegattaCore

// PROTOTYPE (#525, never merged): a look-ahead planner for the leg to the leeward gate (variant P).
// Candidates {left, right mark} x {gybe now, at the layline, none} x {outside, inside the boat ahead} are each sailed
// `horizon` seconds ahead with `BoatDynamics.advance` against the other boats on constant velocity (variant t: at the
// turn rate she saw them turn) and the wake the ribbons leave; the best sailed by the pick's hysteresis. Scores are
// metres. Tier lever: horizon and candidate count are pure functions of her skill.

extension BotVariant {
    static let planDt = number("REGATTA_PLAN_DT", 0.2)
    static let planDirty = number("REGATTA_PLAN_DIRTY", 3)
    static let planGybeWeight = number("REGATTA_PLAN_GYBE_W", 0.5)
    static let planKeepPenalty = number("REGATTA_PLAN_KEEP_PEN", 80)
    static let planEvery = max(1, Int(number("REGATTA_PLAN_EVERY", 1)))
    static let planHorizonClub = number("REGATTA_PLAN_H_CLUB", 8)
    static let planHorizonTop = number("REGATTA_PLAN_H_TOP", 15)
    static let planCandClub = number("REGATTA_PLAN_N_CLUB", 4)
    static let planCandTop = number("REGATTA_PLAN_N_TOP", 12)
    static let planNoTiers = ProcessInfo.processInfo.environment["REGATTA_PLAN_NOTIERS"] != nil
    static let planMarkPenalty = number("REGATTA_PLAN_MARK_PEN", 80)
    static let planMarkHysteresis = number("REGATTA_PLAN_MARK_HYST", 2.5)
    static let planNoneGroove = number("REGATTA_PLAN_NONE", 0) != 0
    static let planMissPenalty = number("REGATTA_PLAN_MISS", 40)
    /// Variant m: main's own pick stands unless a candidate beats it by this many metres.
    static let planAnchor = number("REGATTA_PLAN_ANCHOR", 25)
    static let planFD = ProcessInfo.processInfo.environment["REGATTA_PLAN_FD"] != nil
}

enum GatePlanGybe: Int, Sendable { case now, layline, none }

struct GatePlanChoice: Equatable, Sendable {
    var left: Bool
    var gybe: GatePlanGybe
    var inside: Bool
    var name: String { (left ? "L" : "R") + ["gybe-now", "layline", "no-gybe"][gybe.rawValue] + (inside ? "-in" : "-out") }
}

/// What the brain keeps of its plan between decisions.
struct GatePlanState: Sendable {
    var leg = -1
    var choice: GatePlanChoice?
    var decisions = 0
    /// The leg whose rounding she may shoot the gap on: boats that owe her room are not boats she keeps clear of.
    var gapLeg: Int?
    /// The chosen candidate's track, one point a second from `trackTime`, for the fidelity log (Q3).
    var track: [Vec2] = []
    var trackTime = 0.0
    var trackLogged: [Bool] = []
}

private struct PlanOther {
    enum Kind { case keepClear, owes, neutral }
    var seat: Int
    var position: Vec2
    var velocity: Vec2
    var rate: Double
    var kind: Kind
}

private struct PlanContext {
    var gate: BotBrain.Gate
    var others: [PlanOther]
    var current: Vec2
    var wind: Double
    var cleanWind: Double
    var polarWind: Double
    var down: Double
    var hull: Double
    var beam: Double
    var wake: TurbulenceRibbons
    var tick: Int
    var seat: Int
    var up: Vec2
    var speedLoss: Bool
    var keepLengths: Double
    var horizon: Double
    var dt: Double
}

extension BotBrain {
    /// Horizon (s) and candidate count from her skill: 8 s / 4 at the bottom of Club's band, 15 s / 12 at the top of National's.
    var planTier: (horizon: Double, count: Int) {
        let t = BotVariant.planNoTiers ? 1 : ((style.skill - 0.35) / 0.65).clamped(to: 0...1)
        let h = BotVariant.planHorizonClub + (BotVariant.planHorizonTop - BotVariant.planHorizonClub) * t
        let n = BotVariant.planCandClub + (BotVariant.planCandTop - BotVariant.planCandClub) * t
        return (h, Int(n.rounded()))
    }

    /// The plan for the leg to her gate: the candidate to sail, or the held one.
    mutating func gatePlanChoice(_ b: SeatView.OwnBoat, _ view: SeatView, gate: Gate, l: GateOption, r: GateOption) -> GatePlanChoice? {
        if gatePlan.leg != b.legIndex { gatePlan = GatePlanState(); gatePlan.leg = b.legIndex }
        gatePlan.decisions += 1
        let tier = planTier
        // A gybe she has just made is not made again at once.
        let recentGybe = view.time - lastTackTime <= 6
        if let held = gatePlan.choice, gatePlan.decisions % BotVariant.planEvery != 1 && BotVariant.planEvery > 1 {
            return held.gybe == .now && recentGybe ? GatePlanChoice(left: held.left, gybe: .layline, inside: held.inside) : held
        }
        let ctx = planContext(b, view, gate: gate, horizon: tier.horizon)
        // Candidates, main's pick first; inside only where a boat is between her and the point.
        let anchored = BotVariant.on("m")
        let heldMain = gatePick.flatMap { $0.leg == b.legIndex ? $0.left : nil }
        let mainLeft = anchored ? Self.picksLeftGateMark(held: heldMain, left: l.cost, right: r.cost) : l.cost <= r.cost
        func mainMode(_ o: GateOption) -> GatePlanGybe {
            if b.tack == o.needs { return !o.onOwn || o.farDeep ? .now : .none }
            return anchored ? .layline : (o.onOwn ? .layline : .now)
        }
        let mainChoice = GatePlanChoice(left: mainLeft, gybe: mainMode(mainLeft ? l : r), inside: false)
        var list: [GatePlanChoice] = []
        func add(_ left: Bool, _ g: GatePlanGybe, _ inside: Bool) {
            let c = GatePlanChoice(left: left, gybe: g, inside: inside)
            if !(g == .now && recentGybe && !(anchored && c == mainChoice)), !list.contains(c) { list.append(c) }
        }
        let marks = [mainLeft, !mainLeft]
        let main = [mainMode(mainLeft ? l : r), mainMode(mainLeft ? r : l)]
        let modes: [GatePlanGybe] = [.now, .layline, .none]
        for inside in [false, true] {
            if inside && !blockedPath(b, view, ctx, l: l, r: r) { continue }
            add(marks[0], main[0], inside)
            add(marks[1], main[1], inside)
            for m in modes where m != main[0] { add(marks[0], m, inside) }
            for m in modes where m != main[1] { add(marks[1], m, inside) }
        }
        var cands = Array(list.prefix(tier.count))
        var held = gatePlan.choice
        if let h = held, h.gybe == .now, recentGybe { held = GatePlanChoice(left: h.left, gybe: .layline, inside: h.inside) }
        if let h = held, !cands.contains(h) { cands.append(h) }
        var scored: [(choice: GatePlanChoice, score: Double, path: [Vec2])] = []
        for c in cands {
            let (score, path) = planRollout(c, ctx, b, view, l: l, r: r)
            scored.append((c, score, path))
        }
        var best = scored[0]
        for s in scored.dropFirst() where s.score > best.score { best = s }
        var chosen = best
        if anchored, let mainScored = scored.first(where: { $0.choice == mainChoice }) {
            // Main's pick stands unless another beats it by the anchor; a held override stays while it still beats main by half.
            var ref = mainScored
            if let h = held, h != mainChoice, let hs = scored.first(where: { $0.choice == h }), hs.score >= mainScored.score + BotVariant.planAnchor / 2 { ref = hs }
            let margin = ref.choice == mainChoice ? BotVariant.planAnchor
                : (best.choice.left == ref.choice.left ? Self.gateRepickMetres : Self.gateRepickMetres * BotVariant.planMarkHysteresis)
            chosen = best.score >= ref.score + margin ? best : ref
        } else if let h = held, let hs = scored.first(where: { $0.choice == h }) {
            // Another mark must beat the held one by more than another way to the same mark.
            let margin = best.choice.left == h.left ? Self.gateRepickMetres : Self.gateRepickMetres * BotVariant.planMarkHysteresis
            if best.score < hs.score + margin { chosen = hs }
        }
        if BotVariant.traces {
            let line = "PT t=\(String(format: "%.1f", view.time)) seat=\(view.seat) above=\(String(format: "%.0f", view.course.upwind.dot(b.position - gate.centre))) right=\(String(format: "%.0f", view.course.upwind.rightPerp.dot(b.position - gate.centre))) ml=\(String(format: "%.0f", view.course.upwind.rightPerp.dot(gate.left.position - gate.centre))) mr=\(String(format: "%.0f", view.course.upwind.rightPerp.dot(gate.right.position - gate.centre))) rad=\(String(format: "%.1f", gate.left.radius)) hd=\(String(format: "%.0f", b.heading * 180 / .pi)) v=\(String(format: "%.1f", b.speed)) tack=\(b.tack == .port ? "P" : "S") " +
                scored.map { "\($0.choice.name):\(String(format: "%.0f", $0.score))" }.joined(separator: " ") + " -> \(chosen.choice.name)\n"
            FileHandle.standardError.write(line.data(using: .utf8)!)
        }
        // The fidelity log (Q3): the chosen candidate's track, compared a few seconds on (`gatePlanFidelity`).
        if BotVariant.planFD, gatePlan.track.isEmpty || view.time - gatePlan.trackTime >= tier.horizon {
            gatePlan.track = chosen.path
            gatePlan.trackTime = view.time
            gatePlan.trackLogged = []
        }
        if anchored, chosen.choice == mainChoice {
            gatePlan.choice = nil
            gatePlan.gapLeg = nil
            return nil
        }
        gatePlan.choice = chosen.choice
        gatePlan.gapLeg = chosen.choice.inside ? b.legIndex : nil
        return chosen.choice
    }

    /// Q3: called every decision on the gate leg: logs the error against the stored track when its second comes round.
    mutating func gatePlanFidelity(_ b: SeatView.OwnBoat, _ view: SeatView) {
        guard BotVariant.planFD, gatePlan.leg == b.legIndex, !gatePlan.track.isEmpty else { return }
        let k = Int((view.time - gatePlan.trackTime).rounded())
        guard k >= 1, k < gatePlan.track.count else { return }
        if gatePlan.trackLogged.count < gatePlan.track.count { gatePlan.trackLogged += Array(repeating: false, count: gatePlan.track.count - gatePlan.trackLogged.count) }
        guard [4, 8, 12].contains(k), !gatePlan.trackLogged[k], abs(view.time - gatePlan.trackTime - Double(k)) < 0.1 else { return }
        gatePlan.trackLogged[k] = true
        let err = (gatePlan.track[k] - b.position).length
        let line = String(format: "FD seat=%d skill=%.2f tws=%.1f k=%d err=%.1f horizon=%.0f\n", view.seat, style.skill, b.polarWindSpeed, k, err, planTier.horizon)
        FileHandle.standardError.write(line.data(using: .utf8)!)
    }

    // MARK: - Context

    private func planContext(_ b: SeatView.OwnBoat, _ view: SeatView, gate: Gate, horizon: Double) -> PlanContext {
        let current = b.velocityOverGround - Vec2.heading(b.heading) * b.speed
        var others: [PlanOther] = []
        let useRates = BotVariant.on("t")
        for o in view.others where !o.isGhost && (o.position - b.position).length < 70 {
            var kind = PlanOther.Kind.neutral
            if keepClearRule(b, view, o) != nil { kind = .keepClear }
            if owesHerRoom(o, b, view) { kind = .owes }
            var rate = 0.0
            if useRates, o.seat < seen.count, let last = seen[o.seat], view.time > last.time {
                rate = (wrapAngle(o.heading - last.heading) / (view.time - last.time)).clamped(to: -Self.guardTurnRate...Self.guardTurnRate)
            }
            others.append(PlanOther(seat: o.seat, position: o.position, velocity: o.velocity, rate: rate, kind: kind))
        }
        // The wake with the near boats' future emissions added, once for every candidate.
        let wake = view.wake
        var points = wake.points
        var extended: [[TurbulenceRibbons.Point]] = Array(repeating: [], count: points.count)
        let every = wake.every
        let tick = view.tick
        for o in others where o.seat < points.count {
            extended[o.seat] = points[o.seat]
            guard let last = points[o.seat].last else { continue }
            var born = ((tick / every) + 1) * every
            while Double(born - tick) * Race.dt < horizon {
                let t = Double(born - tick) * Race.dt
                var p = last
                p.position = Self.planPredict(o, t)
                p.born = born
                p.drift = b.windOverGround.velocity
                extended[o.seat].append(p)
                born += every
            }
        }
        points = extended
        let near = TurbulenceRibbons(shadow: wake.shadow, points: points, levels: wake.levels)
        return PlanContext(gate: gate, others: others, current: current, wind: b.windDirection, cleanWind: b.sailingWind.speed,
                           polarWind: b.polarWindSpeed, down: grooveAngle(.downwind, b, view), hull: view.boatClass.hull.length,
                           beam: view.boatClass.hull.beam, wake: near, tick: tick, seat: view.seat, up: view.course.upwind,
                           speedLoss: view.boatClass.windShadow.isSpeedLoss, keepLengths: keepClearLengths * Self.keepClearMargin,
                           horizon: horizon, dt: BotVariant.planDt)
    }

    private static func planPredict(_ o: PlanOther, _ t: Double) -> Vec2 {
        guard o.rate != 0 else { return o.position + o.velocity * t }
        // Turning at `rate`: the integral of the velocity rotating.
        let speed = o.velocity.length, h0 = o.velocity.bearing
        let h1 = h0 + o.rate * t
        let d = (Vec2.heading(h0 + o.rate * t / 2)) * (speed * t)
        _ = h1
        return o.position + d
    }

    /// Whether a boat stands between her and the point inside either mark (within H1's reach of the line), so there is a gap.
    private func blockedPath(_ b: SeatView.OwnBoat, _ view: SeatView, _ ctx: PlanContext, l: GateOption, r: GateOption) -> Bool {
        for point in [l.entry, r.entry] {
            let line = point - b.position
            let length = line.length
            guard length > 1 else { continue }
            let dir = line / length
            for o in ctx.others {
                let rel = o.position - b.position
                let along = rel.dot(dir)
                guard along > 0, along < length + 5, rel.dot(ctx.up) < 0, ctx.up.dot(o.position - ctx.gate.centre) > -3 else { continue }
                if abs(rel.cross(dir)) < 25 { return true }
            }
        }
        return false
    }

    // MARK: - Roll-out

    /// One candidate sailed ahead: its score, metres, and its track a second apart.
    private func planRollout(_ c: GatePlanChoice, _ ctx: PlanContext, _ b: SeatView.OwnBoat, _ view: SeatView,
                             l: GateOption, r: GateOption) -> (Double, [Vec2]) {
        let boatClass = view.boatClass
        let mark = ctx.gate.mark(left: c.left)
        let other = ctx.gate.mark(left: !c.left)
        let target = c.left ? l.entry : r.entry
        let needs = c.left ? l.needs : r.needs
        var state = BoatDynamics.State(position: b.position, heading: b.heading, speed: b.speed, rudder: b.rudder, boomSide: b.boomSide)
        var helm: Autohelm?
        var gybes = 0
        var gybed = false
        if c.gybe == .now {
            helm = Autohelm.tackOrGybe(sailingAngle: state.boomSide.sailingAngle(relativeWind: wrapAngle(ctx.wind - state.heading)))
        }
        let steps = Int((ctx.horizon / ctx.dt).rounded())
        var shadow = 1.0
        var dirtySeconds = 0.0
        var path: [Vec2] = []
        var closest: [Double] = Array(repeating: .infinity, count: ctx.others.count)
        var markClose = Double.infinity
        var reachedAt: Double?
        var missed = false
        var f = 1.0
        let keepD = ctx.hull * ctx.keepLengths
        let sampleEvery = max(1, Int((1.0 / ctx.dt).rounded()))
        let marksR = mark.radius + ctx.beam / 2 + 1.0
        for step in 0..<steps {
            let t = Double(step) * ctx.dt
            if step % sampleEvery == 0 {
                f = ctx.wake.factor(at: state.position, tick: ctx.tick + Int((t * Double(Race.tickRate)).rounded()), receiver: ctx.seat)
                if f < BotBrain.dirtyAir { dirtySeconds += 1 }
                path.append(state.position)
            }
            shadow = f
            // The helm.
            let toTarget = target - state.position
            if reachedAt == nil, toTarget.length < 5 { reachedAt = t }
            if reachedAt == nil, ctx.up.dot(state.position - ctx.gate.centre) < -3 { missed = true; break }
            if helm == nil || !(helm!.isTapping) {
                var heading = toTarget.bearing
                if !c.inside {
                    // Outside: turn away from a boat she must keep clear of that she would pass too close.
                    for (i, o) in ctx.others.enumerated() where o.kind == .keepClear {
                        let p = Self.planPredict(o, t) + ctx.current * t
                        let rel = p - state.position
                        let fwd = Vec2.heading(state.heading)
                        let ahead = rel.dot(fwd)
                        if rel.length < keepD * 1.5, ahead > -ctx.hull {
                            let side = rel.dot(fwd.rightPerp) > 0 ? -1.0 : 1.0
                            heading += side * deg2rad(30)
                        }
                        _ = i
                    }
                }
                var sa = state.boomSide.sailingAngle(relativeWind: wrapAngle(ctx.wind - heading))
                var tap = false
                if BotVariant.on("f"), c.gybe != .now || gybed, c.gybe == .none || toTarget.length < Self.gateStraightRange,
                   (sa > 0 && sa >= ctx.down - Self.gateDeeperMargin) || abs(sa) >= .pi - Self.gateLee {
                    // As `gateAim` sails it: straight for the point on her own gybe, deeper than her groove by the lee no further than gateMaxAngle.
                    sa = min(abs(sa), Self.gateMaxAngle)
                } else if sa < 0 {
                    // The point is on the other gybe.
                    if (c.gybe == .layline || (c.gybe == .none && BotVariant.on("f"))), !gybed, abs(sa) <= ctx.down + deg2rad(2), toTarget.length > 8 { tap = true }
                    else if c.gybe == .layline, !gybed, abs(sa) > .pi - deg2rad(4) { sa = ctx.down }
                    else { sa = ctx.down }
                } else if sa > ctx.down {
                    sa = ctx.down
                } else {
                    sa = max(sa, BoatDynamics.noGoAngle(boatClass.polar) + deg2rad(5))
                }
                if tap {
                    helm = Autohelm.tackOrGybe(sailingAngle: state.boomSide.sailingAngle(relativeWind: wrapAngle(ctx.wind - state.heading)))
                    gybed = true
                } else {
                    helm = Autohelm(target: .angle(sa))
                }
            }
            let angle = state.boomSide.sailingAngle(relativeWind: wrapAngle(ctx.wind - state.heading))
            let rudder = helm!.rudder(sailingAngle: angle, boomSide: state.boomSide, tws: ctx.polarWind, boatClass: boatClass)
            let env = BoatDynamics.Environment(windDirection: ctx.wind, windSpeed: ctx.speedLoss ? ctx.cleanWind : ctx.cleanWind * shadow,
                                               current: ctx.current, shadow: ctx.speedLoss ? shadow : 1)
            let moved = BoatDynamics.advance(state, control: .init(rudder: rudder), env: env, boatClass: boatClass, dt: ctx.dt)
            if moved.boomSide != state.boomSide {
                gybes += 1
                helm = nil
                if c.gybe == .now { gybed = true }
            }
            state = moved
            // Others and marks.
            let t1 = t + ctx.dt
            for (i, o) in ctx.others.enumerated() {
                let p = Self.planPredict(o, t1) + ctx.current * t1
                closest[i] = min(closest[i], (p - state.position).length)
            }
            markClose = min(markClose, (mark.position - state.position).length - marksR, (other.position - state.position).length - (other.radius + ctx.beam / 2 + 1.0))
            if reachedAt != nil { break }
        }
        // Metres: what is left to her point from where she ends (with her gybes to come), or the time she has to spare.
        var score: Double
        if let reached = reachedAt {
            score = max(ctx.horizon - reached, 0) * max(state.speed, 2)
        } else {
            score = -planRemaining(state.position, tack: state.boomSide == .port ? Tack.starboard : Tack.port,
                                   mark: mark, needs: needs, target: target, ctx: ctx)
        }
        if missed { score -= BotVariant.planMissPenalty + (target - state.position).length }
        score -= BotVariant.planDirty * dirtySeconds
        score -= Double(gybes) * Self.gateGybeMetres * BotVariant.planGybeWeight
        let kp = BotVariant.planKeepPenalty
        for (i, o) in ctx.others.enumerated() {
            let d = closest[i]
            switch o.kind {
            case .keepClear:
                let ratio = ((keepD - d) / keepD).clamped(to: 0...1)
                score -= kp * ratio
            case .owes, .neutral:
                let ratio = ((ctx.hull - d) / ctx.hull).clamped(to: 0...1)
                score -= kp * 0.5 * ratio
            }
        }
        if markClose < 0 { score -= BotVariant.planMarkPenalty * min(1, -markClose / mark.radius) }
        // Pad the path to the horizon: a candidate that reaches early stays at her end.
        while path.count < Int(ctx.horizon) { path.append(state.position) }
        return (score, path)
    }

    /// Metres left from `position` to her point inside `mark`, on `tack`: `gateOption`'s cost without a boat in hand.
    private func planRemaining(_ position: Vec2, tack: Tack, mark: CourseLayout.Mark, needs: Tack, target: Vec2, ctx: PlanContext) -> Double {
        let to = target - position
        let relative = wrapAngle(ctx.wind - to.bearing)
        let aimTack: Tack = abs(relative) > .pi - deg2rad(3) ? tack : (relative >= 0 ? .starboard : .port)
        let angle = abs(relative)
        let onOwn = aimTack == tack || angle >= .pi - Self.gateLee
        let down = ctx.down
        let cone = to.length * Vec2.heading(.pi - angle).y / Vec2.heading(.pi - down).y
        let length = angle > down ? cone : to.length
        if tack == needs { return !onOwn ? length + 2 * Self.gateGybeMetres : length }
        if !onOwn { return length + Self.gateGybeMetres }
        if angle > down, to.length >= Self.gateStraightRange { return cone + Self.gateGybeMetres }
        return length + Self.gateMarkGybeMetres
    }
}
