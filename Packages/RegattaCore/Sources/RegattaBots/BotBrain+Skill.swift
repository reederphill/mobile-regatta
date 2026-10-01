import RegattaCore

/// Where her skill shows as she sails the course (#102, `BotWeaknesses`): the current she allows for, the laylines
/// she misjudges and the groove choices she misses. Her start's (timing, line bias) are `BotBrain+Start.swift`'s, her
/// reaction delay `observe`'s and the puffs she notices `puffAdvantage`'s.
extension BotBrain {
    /// Seconds ahead she reckons the current over, at most: the rest of a long leg is a guess.
    static let currentHorizon = 300.0
    /// Points along her way to her mark she samples the current at: now, halfway and there, when she'll be there.
    static let currentSamples = 3

    /// Seconds she reckons it takes her to sail to `target` at her speed: a straight line, at 1 m/s at least.
    func secondsToSail(_ b: SeatView.OwnBoat, to target: Vec2) -> Double {
        min((target - b.position).length / max(b.speed, 1), Self.currentHorizon)
    }

    /// The current she allows for sailing to `target`, m/s (a velocity: the way the water moves): the forecast's
    /// mean over her way there (ADR 0003: the current is public, a function of the venue, the tide and the clock),
    /// her position now to `target` as she sails it, times her current sense (`BotWeaknesses.currentSense`). None at
    /// Club: she navigates by the wind alone, laylines included (#100). At National she allows for all of it, and for
    /// the turn of the tide on the way.
    func currentAllowance(_ b: SeatView.OwnBoat, _ view: SeatView, to target: Vec2) -> Vec2 {
        guard weaknesses.currentSense > 0 else { return .zero }
        return forecastSet(b, view, to: target) * weaknesses.currentSense
    }

    /// The forecast's mean current over her way to `target` (`currentAllowance`), m/s; zero at a venue without.
    func forecastSet(_ b: SeatView.OwnBoat, _ view: SeatView, to target: Vec2) -> Vec2 {
        guard view.current.current != nil else { return .zero }
        let seconds = secondsToSail(b, to: target)
        var sum = Vec2.zero
        for i in 0..<Self.currentSamples {
            let t = Double(i) / Double(Self.currentSamples - 1)
            let point = b.position + (target - b.position) * t
            sum += view.current.sample(point, tick: view.tick + RulesConfig.ticks(seconds * t))
        }
        return sum / Double(Self.currentSamples)
    }

    /// Radians past a layline she tacks or gybes onto it on this leg: the rules' own `overstand`, and her
    /// misjudgement of it (`BotWeaknesses.laylineMisjudge`), drawn once a leg, more often over than under.
    mutating func laylineOverstand(_ b: SeatView.OwnBoat) -> Double {
        if laylineError?.leg != b.legIndex {
            let error = weaknesses.laylineMisjudge > 0 ? weaknesses.laylineMisjudge * rng.range(-0.3, 1) : 0
            laylineError = (b.legIndex, error)
        }
        return Self.overstand + (laylineError?.error ?? 0)
    }

    /// Radians past the snap width a miss is off at the least: clear of it, so the autohelm holds her angle rather
    /// than snapping her back into the groove each time her reckoning of it differs from its.
    static let missMargin = deg2rad(2)
    /// Hull lengths of clear water around her she needs to miss the groove.
    static let missClearance = 2.0
    /// Seconds she keeps a groove choice before she makes it again (`missingGroove`). Longer than skiff@3's 10 s
    /// slow-down (#263): a pinch held for less hardly costs her speed before she chooses again, which hid the miss and
    /// pressed the tiers together (#300: National/Regional mean-place gap 0.98 at 6–14 s, 1.31 at 10–20 s).
    static let grooveChoiceSeconds = (min: 10.0, max: 20.0)

    /// `aim`, a groove, as she chooses it racing (#219, #231, `BotWeaknesses.angleMissRate`): every so often she
    /// chooses again, and a miss has her pinch or foot past the autohelm's snap to the groove, so it holds the
    /// angle she chose instead: never into the no-go zone, nor past dead downwind.
    mutating func missingGroove(_ aim: Aim, _ b: SeatView.OwnBoat, _ view: SeatView) -> Aim {
        guard let groove = aim.groove, b.status == .racing, weaknesses.angleMissRate > 0 else { return aim }
        // With a boat close aboard she sails the groove: a change of course there is one the boats around her
        // didn't expect (rules 15 and 16), and she has them to watch.
        let close = view.boatClass.hull.length * Self.missClearance
        guard !view.others.contains(where: { !$0.isGhost && ($0.position - b.position).length < close }) else { return aim }
        let tuning = view.boatClass.steering.autohelm
        let snap = groove == .upwind ? tuning.upwindSnap : tuning.downwindSnap
        if view.time >= grooveMiss.until {
            let hold = rng.range(Self.grooveChoiceSeconds.min, Self.grooveChoiceSeconds.max)
            let misses = rng.unit() < weaknesses.angleMissRate
            let size = snap + Self.missMargin + weaknesses.angleMissSize * rng.unit()
            let side: Double = rng.bool() ? 1 : -1
            grooveMiss = (misses ? side * size : 0, view.time + hold)
        }
        guard grooveMiss.offset != 0 else { return aim }
        let lowest = BoatDynamics.noGoAngle(view.boatClass.polar) + deg2rad(3)
        let angle = min(max(aim.angle + grooveMiss.offset, lowest), .pi - deg2rad(3))
        guard abs(angle - aim.angle) > snap + Self.missMargin else { return aim }
        return Aim(angle: angle, tack: aim.tack, tolerance: deg2rad(2))
    }
}
