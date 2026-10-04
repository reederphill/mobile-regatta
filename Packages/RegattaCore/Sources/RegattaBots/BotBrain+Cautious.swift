import RegattaCore

// The cautious bot (#19, #104): the bot that sails a dropped player's boat until they come back (CONTEXT.md **Cautious
// bot**). A Club-bottom bot, not a fourth tier: Club's lowest skill, sailing her own race, giving way early and wide.
// Dropping never helps: she places no better than the Club bots around her (`CautiousBotSuiteTests`).
//
// - "Gives way early and wide": she never misjudges an encounter she must keep clear in (`ruleMisjudgeRate` 0, so she
//   fouls only through what she can't avoid), looks further ahead for a boat she must keep clear of
//   (`Caution.keepClearLookahead`) and keeps every clearance her conduct keeps (`keepClearLengths`,
//   `tapClearanceLengths`, `roomLengths`) `Caution.clearanceFactor` times as wide, looking as much further through a
//   tack or gybe (`tapLookaheadScale`). Before her start she keeps clear of every boat, on either tack
//   (`keepsClearOfEveryBoat`), and a tack is hers to finish under rule 13: she bears away to close-hauled before
//   she holds any closer to the wind, racing too.
// - "Hang back" (`hangBackAim`): before the gun she keeps out of the crowd below the line, and starts late.
// - "Look before you leap" (`guarded`): every helm she holds she first sails in her mind for a few seconds among
//   the boats around her, and holds another that keeps further from them when it brings her too close to a boat she
//   would have to keep clear of.
// - "Never attacks": her style's engagement is 0 (#234), so she plays no fleet tactic: no cover, no held lane, no
//   lee-bow, no tacking on a boat's wind.
// - As the right-of-way boat she holds her course as every bot does (#101, `holdingCourse`), before her start too,
//   and never turns towards a boat keeping clear of her to keep clear of another; rule 14 asks no more.
//
// Taking over (`takingOver`, `adopt`): any bot taking a seat over mid-race, cautious or the fleet's draw before the
// gun, rebuilds what she would have planned from what the seat sees on her first decision, and nothing else.

extension BotBrain {
    /// What makes a bot cautious (#104). Placeholders, tuned by measurement (#105), never by feel.
    struct Caution: Hashable, Sendable {
        /// How much wider than any other bot's she keeps her conduct's clearances (`keepClearLengths`,
        /// `tapClearanceLengths`, `roomLengths`).
        var clearanceFactor: Double

        /// The cautious bot's (#104).
        static let standard = Caution(clearanceFactor: Self.clearanceFactor)

        /// Placeholder: half as wide again as any other bot's clearances.
        static let clearanceFactor = 1.5
        /// Seconds ahead she looks for a boat she must keep clear of, in place of her skill's
        /// (`BotWeaknesses.keepClearLookahead`, 3.2 s at Club's bottom; `BotBrain.keepClearLookahead`). Placeholder.
        static let keepClearLookahead = 6.0

        /// The cautious bot's skill: the bottom of Club's band (`BotTier.club`), so retuning the band moves her with it.
        /// Placeholder.
        static var skill: Double { BotTier.club.skillBand.lowerBound }

        /// Her weaknesses: her skill's, but she misjudges no encounter (she always gives way, #19).
        static func weaknesses(skill: Double) -> BotWeaknesses {
            var weaknesses = BotWeaknesses(skill: skill)
            weaknesses.ruleMisjudgeRate = 0
            return weaknesses
        }

        /// Her style, drawn from her own seed as any bot's of her skill is (`BotStyle(skill:rng:)`), with no engagement:
        /// she sails her own race and never attacks (#234).
        static func style(skill: Double, rng: inout SplitMix64) -> BotStyle {
            var style = BotStyle(skill: skill, rng: &rng)
            style.engagement = 0
            return style
        }
    }

    /// The cautious bot's `Caution.clearanceFactor`; 1 for every other bot, so their clearances are exactly as before
    /// #104.
    private var clearanceScale: Double { caution?.clearanceFactor ?? 1 }
    /// Before her start she keeps clear of every boat, on either tack, as a boat returning keeps clear (`startKeepClear`):
    /// the cautious bot (#104). False for every other bot.
    var keepsClearOfEveryBoat: Bool { caution != nil }
    /// Hull lengths, centre to centre, she keeps from a boat she must keep clear of (`keepClearDistance`, scaled for a
    /// cautious bot).
    var keepClearLengths: Double { Self.keepClearDistance * clearanceScale }
    /// Hull lengths a boat must pass off her through a tack or gybe (`tapClearance`, scaled for a cautious bot).
    var tapClearanceLengths: Double { Self.tapClearance * clearanceScale }
    /// Hull lengths inside which a turn of hers towards a boat keeping clear of her takes its room (`roomDistance`,
    /// scaled for a cautious bot).
    var roomLengths: Double { Self.roomDistance * clearanceScale }
    /// How much further ahead than `tapLookahead` she looks through a tack or gybe (`tapIsClear`): `clearanceScale`.
    var tapLookaheadScale: Double { clearanceScale }

    // MARK: - Looking ahead

    /// Seconds ahead she sails each candidate helm on (`guarded`).
    static let guardHorizon = 3.0
    /// Seconds between the steps of that look ahead.
    static let guardStep = 0.1
    /// Hull lengths, centre to centre, inside which a boat she must keep clear of is too close (`guarded`). Placeholder:
    /// at 1.5 she was the offender in 6 of `CautiousBotSuiteTests`' 100 races, at 2.5 in 2, at 3 in none.
    static let guardLengths = 3.0
    /// Hull lengths of water she keeps between her and a mark's edge while she steers off for a boat (`guarded`).
    static let guardMarkLengths = 1.0
    /// The rudders she tries, each held and eased or not.
    static let guardRudders: [Double] = [-1, -0.5, 0, 0.5, 1]
    /// Radians per second and metres per second per second she assumes another boat goes on turning and speeding up or
    /// slowing down by, at most: what she saw it do since her last decision.
    static let guardTurnRate = 0.6
    /// See `guardTurnRate`.
    static let guardSlowing = 3.0
    /// See `guardTurnRate`.
    static let guardSpeeding = 1.0

    /// Another boat as she saw it at her last decision (`guarded`).
    struct Seen: Hashable, Sendable {
        var time: Double
        var heading: Double
        var speed: Double
    }

    /// "Look before you leap" (#104): the cautious bot sails every helm she might hold on in her mind for
    /// `guardHorizon` seconds, the boats around her going on as she saw them going (turning and slowing as they were
    /// since her last decision), and keeps the one she chose unless it brings her within `guardLengths` of a boat she
    /// would have to keep clear of then (rules 10–13 on the boats as they would be: her own tack and tack change
    /// included), of one she owes mark-room to (rule 18, #93), or of one she would have just gained the right of way
    /// over (rule 15). Then she holds the helm that keeps furthest from them, nearest the one she chose; as the
    /// right-of-way boat never one turning towards a boat keeping clear of her (#101). Nil when she keeps the one she
    /// chose.
    func guarded(_ view: SeatView, _ input: BoatInput) -> BoatInput? {
        let b = view.own
        guard caution != nil, b.isOnCourse, b.penaltyTurnsOwed == 0,
              b.autohelm?.isTapping != true else { return nil }
        let hull = view.boatClass.hull
        let clear = hull.length * Self.guardLengths
        let reach = clear + (b.speed + 8) * Self.guardHorizon
        let near = view.others.filter { !$0.isGhost && ($0.position - b.position).length < reach }
        guard !near.isEmpty else { return nil }
        let steps = Int((Self.guardHorizon / Self.guardStep).rounded())
        // Each nearby boat's track, step by step.
        let tracks: [[Boat]] = near.map { other in
            var rate = 0.0, accel = 0.0
            if other.seat < seen.count, let last = seen[other.seat], view.time > last.time {
                let dt = view.time - last.time
                rate = (wrapAngle(other.heading - last.heading) / dt).clamped(to: -Self.guardTurnRate...Self.guardTurnRate)
                accel = ((other.speed - last.speed) / dt).clamped(to: -Self.guardSlowing...Self.guardSpeeding)
            }
            var boat = Boat(id: other.seat, isPlayer: false, colorIndex: 0, position: other.position,
                            heading: other.heading, speed: other.speed, boomSide: other.boomSide)
            boat.isTacking = other.rightOfWay?.rule == .whileTacking && other.rightOfWay?.keepClear == other.seat
            return (1...steps).map { _ in
                boat.heading = wrapAngle(boat.heading + rate * Self.guardStep)
                boat.speed = max(0, boat.speed + accel * Self.guardStep)
                boat.position = boat.position + Vec2.heading(boat.heading) * boat.speed * Self.guardStep
                return boat
            }
        }
        // A boat she owes mark-room to (rule 18, `OwnBoat.markRoom`) she keeps clear of whatever rules 10–13 give her,
        // as her conduct does (`keepClearRule`): she holds no right over her (#93).
        let holdsRight = near.map { other in
            other.rightOfWay?.keepClear == other.seat
                && !b.markRoom.contains(where: { $0.owing == view.seat && $0.entitled == other.seat })
        }
        let env = BoatDynamics.Environment(windDirection: b.windDirection, windSpeed: b.polarWindSpeed,
                                           shadow: b.speedShadow)
        let closeHauled = view.boatClass.polar.bestUpwind(tws: b.polarWindSpeed).twa - deg2rad(5)
        let obstacles = view.course.obstacles.filter { ($0.position - b.position).length < $0.radius + reach }
        let markRoom = hull.length * Self.guardMarkLengths
        /// How far inside `clear` of a boat she must keep clear of the helm takes her, at worst (0: never), and how far
        /// inside `guardMarkLengths` of a mark or other obstacle.
        func intrusion(_ rudder: Double, _ ease: Bool) -> (boats: Double, marks: Double) {
            var state = BoatDynamics.State(position: b.position, heading: b.heading, speed: b.speed, rudder: b.rudder,
                                           boomSide: b.boomSide)
            var tacking = senses.tacking
            var worst = 0.0, marks = 0.0
            for step in 0..<steps {
                state = BoatDynamics.advance(state, control: .init(rudder: rudder, ease: ease), env: env,
                                             boatClass: view.boatClass, dt: Self.guardStep)
                let twa = abs(wrapAngle(b.windDirection - state.heading))
                if state.boomSide != b.boomSide, twa < .pi / 2 { tacking = true }
                if twa >= closeHauled { tacking = false }
                for obstacle in obstacles {
                    marks = max(marks, obstacle.radius + markRoom - (obstacle.position - state.position).length)
                }
                for (i, track) in tracks.enumerated() {
                    let other = track[step]
                    let distance = (other.position - state.position).length
                    guard distance < clear, clear - distance > worst else { continue }
                    var me = Boat(id: view.seat, isPlayer: false, colorIndex: 0, position: state.position,
                                  heading: state.heading, speed: state.speed, boomSide: state.boomSide)
                    me.isTacking = tacking
                    let overlapped = !Rules.isClearAstern(me, of: other, hull: hull)
                        && !Rules.isClearAstern(other, of: me, hull: hull)
                    let right = Rules.rightOfWay(me, other, overlapped: overlapped, hull: hull)?.keepClear == other.id
                    if right && holdsRight[i] { continue }
                    worst = clear - distance
                }
            }
            return (worst, marks)
        }
        let chosen = intrusion(input.rudderValue, input.ease)
        guard chosen.boats > 0 else { return nil }
        // Ranks a helm: clear of the marks first (or no further into their room than she chose), then furthest from
        // the boats, then nearest what she chose.
        func rank(_ i: (boats: Double, marks: Double), change: Double) -> (Int, Double, Double) {
            (i.marks > max(chosen.marks, 0) + 0.01 ? 1 : 0, (i.boats * 100).rounded(), change)
        }
        var best: (input: BoatInput, rank: (Int, Double, Double))?
        for rudder in Self.guardRudders {
            if rudder != 0, holdsRight.contains(true), turnsTowardsKeepClearBoat(b, view, turn: rudder > 0 ? 1 : -1) { continue }
            for ease in [false, true] {
                let change = abs(rudder - input.rudderValue) + (ease == input.ease ? 0 : 0.25)
                let r = rank(intrusion(rudder, ease), change: change)
                if best == nil || r < best!.rank { best = (BoatInput(rudder: rudder, ease: ease), r) }
            }
        }
        guard let best, best.rank < rank(chosen, change: 0) else { return nil }
        return best.input
    }

    /// Her own track through a tack or gybe tapped now, a `guardStep` apart for `seconds`: the autohelm sailing the tap
    /// through head to wind or the gybe and on in the groove of the new tack, as the race sails it, in the wind she has
    /// now. The cautious bot's look before she taps (`tapIsClear`, #350): from a reach, or slow, the turn alone takes
    /// seconds, sailing on where she was going and stopping in head to wind, not straight off on the new tack.
    func tapTrack(_ b: SeatView.OwnBoat, _ view: SeatView, seconds: Double) -> [Vec2] {
        let boatClass = view.boatClass
        var state = BoatDynamics.State(position: b.position, heading: b.heading, speed: b.speed, rudder: b.rudder,
                                       boomSide: b.boomSide)
        var helm = Autohelm.tackOrGybe(sailingAngle: b.boomSide.sailingAngle(relativeWind: b.relativeWind))
        let env = BoatDynamics.Environment(windDirection: b.windDirection, windSpeed: b.polarWindSpeed, shadow: b.speedShadow)
        return (0..<Int((seconds / Self.guardStep).rounded())).map { _ in
            let angle = state.boomSide.sailingAngle(relativeWind: wrapAngle(b.windDirection - state.heading))
            let rudder = helm.rudder(sailingAngle: angle, boomSide: state.boomSide, tws: b.polarWindSpeed, boatClass: boatClass)
            let moved = BoatDynamics.advance(state, control: .init(rudder: rudder), env: env, boatClass: boatClass,
                                             dt: Self.guardStep)
            if moved.boomSide != state.boomSide { helm.isTapping = false }
            state = moved
            return state.position
        }
    }

    /// The closest `other` comes to her over the next `lookahead` seconds, metres between centres, as she sails `track`
    /// (`tapTrack`) and `other` goes on as she saw it going: turning as it turned since her last decision (`seen`, at
    /// most `guardTurnRate`). The cautious bot's look before she taps (`tapIsClear`, #350): a boat bearing away out of
    /// its own tack crossed her bow as she tacked from a reach (seed 69 of `CautiousBotSuiteTests`), clear of her by
    /// the straight-line reckoning every bot makes.
    func tapApproach(of other: SeatView.OtherBoat, track: [Vec2], lookahead: Double, _ view: SeatView) -> Double {
        var rate = 0.0
        if other.seat < seen.count, let last = seen[other.seat], view.time > last.time {
            rate = (wrapAngle(other.heading - last.heading) / (view.time - last.time))
                .clamped(to: -Self.guardTurnRate...Self.guardTurnRate)
        }
        var position = other.position, heading = other.heading
        var closest = (position - view.own.position).length
        for own in track.prefix(Int((lookahead / Self.guardStep).rounded())) {
            heading = wrapAngle(heading + rate * Self.guardStep)
            position = position + Vec2.heading(heading) * other.speed * Self.guardStep
            closest = min(closest, (position - own).length)
        }
        return closest
    }

    /// Notes every boat as she sees it now, for `guarded` at her next decision.
    mutating func see(_ view: SeatView) {
        guard caution != nil else { return }
        for other in view.others {
            if other.seat >= seen.count { seen += Array(repeating: nil, count: other.seat + 1 - seen.count) }
            seen[other.seat] = Seen(time: view.time, heading: other.heading, speed: other.speed)
        }
    }

    // MARK: - Hanging back

    /// Metres beyond the nearer end of the start line, along it, she waits before the gun (`hangBackAim`). Placeholder.
    static let hangBackBeyond = 25.0
    /// Metres below the line she waits, at most (`maxHoldDepth` permitting). Placeholder.
    static let hangBackDepth = 15.0
    /// Metres from her waiting point within which she waits rather than sails to it.
    static let hangBackRadius = 12.0
    /// Metres of race area she keeps between her waiting point and its edge.
    static let hangBackEdgeRoom = 25.0

    /// "Hang back" (#104): before the gun the cautious bot keeps out of the crowd below the line altogether. She waits
    /// off the nearer end of the line, beyond it and below it, on a beam reach with the sheets eased, and starts once
    /// the gun has gone and the fleet has sailed off (`startAim`). Nil when it doesn't apply: not the cautious bot, or
    /// the gun has gone.
    mutating func hangBackAim(_ b: SeatView.OwnBoat, _ view: SeatView) -> Aim? {
        guard caution != nil, b.status == .prestart, view.time < 0 else { return nil }
        let c = view.course
        let line = c.startLine
        let along = (line.committee.position - line.pin.position).normalized
        let end = (b.position - line.centre).dot(along) < 0
            ? line.pin.position - along * Self.hangBackBeyond
            : line.committee.position + along * Self.hangBackBeyond
        var point = end - c.upwind * min(Self.hangBackDepth, max(maxHoldDepth(view, at: end), 0))
        // Inside the race area, with room to wait: drawn in towards the line's centre until it is.
        var tries = 0
        while c.raceArea.inset(point) < Self.hangBackEdgeRoom && tries < 20 {
            point = point + (line.centre - c.upwind * Self.hangBackDepth - point) * 0.1
            tries += 1
        }
        guard (point - b.position).length <= Self.hangBackRadius else { return navigate(b, to: point, view) }
        return Aim(angle: .pi / 2, tack: b.tack, tolerance: deg2rad(5), ease: true)
    }

    // MARK: - Taking over

    /// "Picks up where the boat is": what a bot taking a seat over mid-race (#19: a dropped player's boat, or before the
    /// gun one given away) makes of it on her first decision, from what the seat sees and nothing else (#98). Her plan
    /// starts from the boat's tack, as though she had just chosen it, so she doesn't tack on a shift the moment she takes
    /// the helm; a tack or gybe the autohelm is sailing she lets finish, and a tack is hers under rule 13 until she is
    /// close-hauled. A penalty turn already under way she turns on the same way: turning it back would give it up (the
    /// race resets a turn reversed). The rudder held off centre shows the way; a centred one doesn't, so she reads it
    /// off her next decision (`readPenaltyTurn`).
    mutating func adopt(_ view: SeatView) {
        let b = view.own
        plannedTack = b.tack
        lastTackTime = view.time
        if b.autohelm?.isTapping == true {
            lastTapTime = view.time
            senses.tacking = b.twa < .pi / 2
            if senses.tacking { senses.tackCrossedAt = view.time }
        }
        guard let owed = b.penalty, owed.progress > 0 else { return }
        penaltyProgress = owed.progress
        if b.autohelm == nil, b.rudder != 0 {
            penaltyTurn = b.rudder > 0 ? 1 : -1
        } else {
            penaltyRead = PenaltyRead(time: view.time, heading: b.heading, progress: owed.progress)
        }
    }

    /// A penalty turn she took over part-turned with the rudder centred (`adopt`): when, her heading and how far into
    /// the turn she was.
    struct PenaltyRead: Hashable, Sendable {
        var time: Double
        var heading: Double
        var progress: Double
    }

    /// Reads the way of a penalty turn she took over part-turned with the rudder centred (`adopt`): one decision on the
    /// centred rudder, then the way her heading went and whether that turned the penalty on or back. Returns the
    /// neutral input to hold meanwhile, or nil once read (`penaltyTurn` set if it showed, otherwise she starts it as
    /// she would any turn).
    mutating func readPenaltyTurn(_ b: SeatView.OwnBoat, _ view: SeatView, _ owed: OwedPenalty) -> BoatInput? {
        guard let read = penaltyRead else { return nil }
        if read.time == view.time { return .neutral }
        penaltyRead = nil
        let turned = wrapAngle(b.heading - read.heading)
        let progressed = owed.progress - read.progress
        if turned != 0, progressed != 0 {
            penaltyTurn = (turned > 0) == (progressed > 0) ? 1 : -1
        }
        return nil
    }
}

extension BotDriver {
    /// The cautious bot for `seat` (#19, #104, `BotBrain.Caution`): Club's bottom skill, her style from her own seed
    /// with no engagement, never misjudging an encounter, keeping clear early and wide. She only ever takes a seat
    /// over, a dropped player's boat (`SeatControllers.takeOver`), so she picks up where the boat is
    /// (`BotBrain.adopt`).
    public static func cautious(seat: Int, raceSeed: RaceSeed) -> BotDriver {
        let skill = BotBrain.Caution.skill
        var rng = SplitMix64(seed: botSeed(raceSeed: raceSeed, seat: seat))
        let style = BotBrain.Caution.style(skill: skill, rng: &rng)
        return BotDriver(seat: seat, raceSeed: raceSeed, style: style, weaknesses: BotBrain.Caution.weaknesses(skill: skill),
                         caution: .standard).takingOver()
    }
}
