import RegattaCore

/// What a bot plays beyond sailing the groove to the marks (#231): when she tacks or gybes, and when she
/// leaves the groove, and how she plays the boats around her (#234, `BotBrain+Fleet.swift`). Set by a bot-suite profile
/// (`BotProfile`), or for a live bot by her skill's weaknesses and her style (#102, #234).
struct Tactics: Sendable, Equatable {
    /// She tacks on a header past this, radians, against the course axis; nil: never on a header.
    var headerThreshold: Double?
    /// Seconds after a tack or gybe before a shift, a puff or dirty air turns her again.
    var tackInterval: Double
    /// Seconds ahead she reads the shift at the rate the wind is turning: she tacks on the header coming.
    var anticipation: Double
    /// How far across the wind from her mark she sails before she turns back, as a share of her distance to
    /// it: the corridor. The baseline's narrow one funnels her in with a tack or gybe each time it halves; a
    /// wide one leaves the turns to the laylines and the shifts.
    var corridor: Double
    /// Her favoured side (`BotStyle.favouredSide`, a live bot's): the corridor shifted that way by this share of
    /// its width, −0.5 (left, looking upwind) … 0.5 (right).
    var corridorBias = 0.0
    /// Downwind, she gybes on a shift past this that swings her away from her mark, radians; nil: never.
    var downwindShiftThreshold: Double?
    /// Off the plane, she heads up to plane again, then bears away to the groove.
    var replanes: Bool
    /// On the plane in a lull, she heads up to stay on it; not in another boat's wind shadow (#263).
    var heatsUpInLulls: Bool
    /// Close to her mark and just below its layline, she pinches up to fetch it rather than tack twice.
    var pinchesToFetch: Bool
    /// Upwind, she weighs the puffs and lulls drawn on the water ahead on each tack.
    var seeksPuffs: Bool
    /// Upwind, she weighs the pressure ahead on each tack (#290): she goes to the pressure, and into a pressure lane
    /// on the edge whose bend lifts her.
    var seeksPressure: Bool
    /// With the shift neutral, she tacks to the pressure on half the case a shift needs: she goes to the pressure
    /// when there's no shift to play; and she weighs the pressure along her whole track on each tack
    /// (`pressureAdvantage`). The tactician's; a live bot weighs the pressure only against the shift, and by the best
    /// spot she sees on each tack (#290).
    var goesToThePressure: Bool
    /// Upwind, she tacks out of another boat's wind shadow.
    var seeksClearAir: Bool
    /// Upwind, she tacks with the nearest boat close behind her, to stay between it and the mark: the tactician's
    /// cover (#231), with no memory of when that boat tacked. A live bot's is `coversTackers`.
    var covers: Bool
    /// How she engages the boats around her (`BotStyle.engagement`, #234), 0 sailing her own race … 1 combative: the
    /// one scalar every fleet tactic reads, for whether she plays it (`FleetTactics` floors) and how far off a boat she
    /// covers. Zero for the profiles, unless one plays a fleet tactic.
    var engagement = 0.0
    /// Fleet tactics (#234, `BotBrain+Fleet.swift`). "Cover": she tacks with a boat behind her that tacked away, once
    /// she has seen it (her reaction delay) and while it isn't too late.
    var coversTackers = false
    /// "Lee-bow": on port, meeting a starboard boat she can just cross, she tacks onto her lee bow, when her tack as she
    /// reckons it would leave the boat in her backwind.
    var leeBows = false
    /// "Tack on her wind": ahead of a boat on the other tack, she tacks to put her in her wind shadow, when that pays
    /// against her own plan.
    var tacksOnWind = false
    /// "Hold her lane": in clear air with a boat in her backwind or to windward close by on her tack, she holds on
    /// rather than tack away on a small header, a puff, the pressure or another boat.
    var holdsLane = false
    /// She rolls her tacks (#263, `planRoll`), as well as her skill lets her. The groove-only profiles leave the tack
    /// to the autohelm's tap.
    var rollsTacks = true
    /// As the right-of-way boat racing, she turns towards a boat that must keep clear of her, within rule 16.1's rate,
    /// instead of holding her course (#355, `BotProfile.hunter`, `hunting`). Only the suite's hunter.
    var hunts = false

    /// Metres ahead she notices puffs and lulls (`BotWeaknesses.puffPerception`), when she seeks them; she reads the
    /// pressure out to twice as far (`pressureLookAhead`).
    var puffRange = BotWeaknesses.fullPuffPerception
    /// How well she times cover and lee-bow, 0…1 (`BotWeaknesses.tacticalQuality`, #223): she covers a boat within
    /// this share of `BotBrain.coverRange` (and more of it the better she is); #234's fleet tactics read it too.
    var tacticalQuality = 1.0

    init(profile: BotProfile?, skill: Double, style: BotStyle? = nil, weaknesses: BotWeaknesses? = nil) {
        switch profile {
        case nil:
            // A live bot (#102): she plays the shifts, on smaller ones the more skilled and the more willing to tack
            // she is (her style), and the puffs she notices (`BotWeaknesses.puffPerception`); she planes as a
            // player would.
            let weaknesses = weaknesses ?? BotWeaknesses(skill: skill)
            let willingness = style?.tackWillingness ?? 0.5
            let threshold = deg2rad(3 + 2 * (1 - willingness) + 12 * max(0, 0.75 - skill))
            self.init(headerThreshold: threshold, tackInterval: 15 * (1.3 - 0.6 * willingness), replanes: true,
                      seeksPuffs: weaknesses.puffPerception > 0, seeksPressure: weaknesses.puffPerception > 0)
            puffRange = weaknesses.puffPerception
            corridorBias = 0.5 * (style?.favouredSide ?? 0)
            tacticalQuality = weaknesses.tacticalQuality
            // #234: how she plays the fleet is her style's engagement; how well, her skill's tactical quality.
            engagement = style?.engagement ?? 0.5
            coversTackers = engagement >= BotBrain.FleetTactics.coverEngagement
            holdsLane = engagement >= BotBrain.FleetTactics.laneEngagement
            leeBows = engagement >= BotBrain.FleetTactics.leeBowEngagement
            tacksOnWind = engagement >= BotBrain.FleetTactics.tackOnWindEngagement
        case .baseline:
            // The groove only: headers past a threshold, the corridor, and nothing off the groove.
            self.init(headerThreshold: deg2rad(5), tackInterval: 15)
            rollsTacks = false
        case .tactician, .hunter:
            // #263: a corridor a little wider than the baseline's and her tacks as close together as hers, measured in
            // the fun pass: with skiff@3's tack cost and momentum, 0.8 and 20 s cost her the edge (#300 retunes).
            self.init(headerThreshold: deg2rad(4), tackInterval: 15, anticipation: 6, corridor: 0.5,
                      downwindShiftThreshold: deg2rad(5), replanes: true, heatsUpInLulls: true, pinchesToFetch: true,
                      seeksPuffs: true, seeksPressure: true, goesToThePressure: true, seeksClearAir: true, covers: true)
            // #234 (ruling 3): her cover stays #231's (`covers`) and she holds no lane. #234's first lee-bow and tack on
            // a boat's wind cost her fun-pass gain on 16 seeds (1.91 → 1.74 L/beat); with #329's forecast trigger and
            // pays-check nothing fell, so she plays both, fully engaged (`FleetTactics.tacticianLeeBowsAndTacksOnWind`).
            if BotBrain.FleetTactics.tacticianLeeBowsAndTacksOnWind {
                engagement = 1
                leeBows = true
                tacksOnWind = true
            }
            // #355: the hunter is the tactician, hunting.
            hunts = profile == .hunter
        case .blipTacker:
            // The baseline with a hair trigger: a 3° blip tacks her as a real header does.
            self.init(headerThreshold: deg2rad(3), tackInterval: 15)
            rollsTacks = false
        }
    }

    init(headerThreshold: Double?, tackInterval: Double, anticipation: Double = 0, corridor: Double = 0.35,
         downwindShiftThreshold: Double? = nil, replanes: Bool = false, heatsUpInLulls: Bool = false,
         pinchesToFetch: Bool = false, seeksPuffs: Bool = false, seeksPressure: Bool = false,
         goesToThePressure: Bool = false, seeksClearAir: Bool = false, covers: Bool = false) {
        self.headerThreshold = headerThreshold
        self.tackInterval = tackInterval
        self.anticipation = anticipation
        self.corridor = corridor
        self.downwindShiftThreshold = downwindShiftThreshold
        self.replanes = replanes
        self.heatsUpInLulls = heatsUpInLulls
        self.pinchesToFetch = pinchesToFetch
        self.seeksPuffs = seeksPuffs
        self.seeksPressure = seeksPressure
        self.goesToThePressure = goesToThePressure
        self.seeksClearAir = seeksClearAir
        self.covers = covers
    }
}

/// What a bot has made of her own wind and speed over the decisions so far (`BotBrain.observe`): what a
/// player reads off her readouts and her boat, remembered.
struct Senses: Sendable, Equatable {
    /// The race clock at her last decision.
    var time: Double?
    /// Her reckoning of the wind strength her grooves read (`Boat.grooveWindSpeed`): the class's running
    /// average of what her polar reads, m/s.
    var grooveWind: Double?
    /// Whether she reckons she is on the plane (`BoatClass.PlaningTuning.isPlaning`, from her speed and angle).
    var planing = false
    /// The wind direction at her, smoothed over a few seconds, radians.
    var direction: Double?
    /// How fast it is turning, radians per second, positive veering.
    var directionRate = 0.0
    /// Her boom's side at her last decision.
    var boomSide: BoomSide?
    /// Whether she is tacking as rule 13 has it (#99): from her boom crossing head to wind until she is
    /// close-hauled on the new tack. Until then she keeps clear of every boat.
    var tacking = false
    /// The race clock at the decision she first saw her boom across on her latest tack (#263: when she rolls it).
    var tackCrossedAt: Double?
    /// The observation delay line (`BotWeaknesses.reactionDelay`, #102): the wind directions she has seen at her
    /// boat, oldest first, back to the one she reads now, that many seconds ago.
    var windHistory: [WindSample] = []

    struct WindSample: Sendable, Equatable {
        var time: Double
        var direction: Double
    }
}

extension BotBrain {
    /// Seconds the wind direction is smoothed over before she reads a shift in it.
    static let directionSmoothing = 4.0
    /// Seconds its rate of turn is smoothed over.
    static let rateSmoothing = 8.0

    /// Takes in what she sees of her own boat now.
    mutating func observe(_ b: SeatView.OwnBoat, _ view: SeatView) {
        let dt = senses.time.map { max(0, view.time - $0) } ?? 0
        senses.time = view.time
        let tws = b.polarWindSpeed
        let average = view.boatClass.steering.autohelm.grooveWindAverage
        if let groove = senses.grooveWind, average > 0 {
            senses.grooveWind = groove + (tws - groove) * min(1, dt / average)
        } else {
            senses.grooveWind = tws
        }
        if let planing = view.boatClass.planing {
            senses.planing = b.isOnCourse && planing.isPlaning(was: senses.planing, twa: b.twa, speed: b.speed, tws: tws)
        }
        if let side = senses.boomSide, side != b.boomSide {
            senses.tacking = b.twa < .pi / 2
            if senses.tacking { senses.tackCrossedAt = view.time }
        }
        if senses.tacking && b.twa >= Self.closeHauled(tws, view) { senses.tacking = false }
        senses.boomSide = b.boomSide
        // What she reads of the wind's direction: as it was `reactionDelay` seconds ago.
        senses.windHistory.append(Senses.WindSample(time: view.time, direction: b.windDirection))
        while senses.windHistory.count > 1 && senses.windHistory[1].time <= view.time - weaknesses.reactionDelay {
            senses.windHistory.removeFirst()
        }
        let seen = senses.windHistory[0].direction
        if let direction = senses.direction, dt > 0 {
            let next = wrapAngle(direction + wrapAngle(seen - direction) * min(1, dt / Self.directionSmoothing))
            let rate = wrapAngle(next - direction) / dt
            senses.directionRate += (rate - senses.directionRate) * min(1, dt / Self.rateSmoothing)
            senses.direction = next
        } else {
            senses.direction = seen
        }
        observeFleet(view)
    }

    /// The sailing angle at which a boat that has tacked is close-hauled, and no longer tacking (rule 13): a
    /// little below the upwind groove in `tws`.
    static func closeHauled(_ tws: Double, _ view: SeatView) -> Double {
        view.boatClass.polar.bestUpwind(tws: tws).twa - deg2rad(5)
    }

    /// Her reckoning of `groove`'s sailing angle: at the wind strength her grooves read.
    func grooveAngle(_ groove: Autohelm.Groove, _ b: SeatView.OwnBoat, _ view: SeatView) -> Double {
        Autohelm.grooveAngle(groove, tws: senses.grooveWind ?? b.polarWindSpeed, boatClass: view.boatClass)
    }

    // MARK: - Upwind

    /// The tack to beat on inside the corridor to her mark, starting from `planned`: the other one on a
    /// header past her threshold, and for a tactician, when the other side's puffs, pressure, clear air or a boat to
    /// cover make it worth a tack. Her fleet tactics (#234, `fleetPlay`) come first: holding her lane she tacks only on a
    /// header past twice her threshold; a cover, a lee-bow or a tack on a boat's wind tacks her (the last only when it
    /// pays against her plan: the shift, puffs, pressure and dirty air). Neither ever onto a board she has `overstood`
    /// (past its layline, where navigating would tack her straight back), and only when she can tap now (`canTap`).
    /// Inside her tack interval only a lee-bow tacks her (#329, `FleetTactics.leeBowInsideTackInterval`): it answers a
    /// crossing, not a tack of her choosing.
    mutating func upwindTack(_ b: SeatView.OwnBoat, _ view: SeatView, planned tack: Tack,
                             overstood: (Tack) -> Bool = { _ in false }) -> Tack {
        guard let threshold = tactics.headerThreshold else { return tack }
        let direction = (senses.direction ?? b.windDirection) + senses.directionRate * tactics.anticipation
        let shift = wrapAngle(direction - view.course.axis)
        // Headed: backed on starboard, veered on port.
        var headed = tack == .starboard ? -shift : shift
        let shifted = headed
        guard view.time - lastTackTime > tactics.tackInterval else {
            guard FleetTactics.leeBowInsideTackInterval, tactics.leeBows,
                  let play = fleetPlay(b, view, planned: tack, headed: shifted, lean: shifted, threshold: threshold,
                                       leeBowOnly: true, overstood: overstood), play.play == .leeBow else { return tack }
            return tack.other
        }
        // Goes to the pressure (`Tactics.goesToThePressure`): with the shift neutral, nothing in it to play, the
        // pressure calls her tack on half the case a shift needs.
        let neutral = abs(headed) < threshold / 2
        let pressure = tactics.seeksPressure ? pressureAdvantage(b, view, over: tack) : 0
        if tactics.seeksPuffs { headed += puffAdvantage(b, view, over: tack) }
        headed += pressure
        if tactics.seeksClearAir && tack == b.tack && b.shadow < Self.dirtyAir { headed += Self.dirtyAirWeight }
        if let play = fleetPlay(b, view, planned: tack, headed: shifted, lean: headed, threshold: threshold,
                                overstood: overstood) {
            guard play.play == .holdLane else { return tack.other }
            // Holding her lane, only a big header tacks her, and like any fleet tactic's tack, only when she can tap
            // it now and onto a board she hasn't overstood.
            let tacks = shifted > threshold * FleetTactics.laneHeader && !overstood(tack.other) && canTap(b, view)
            return tacks ? tack.other : tack
        }
        if tactics.covers, let rival = coverTarget(b, view), rival.tack != tack, headed > -threshold {
            return rival.tack
        }
        let bar = tactics.goesToThePressure && neutral && pressure > threshold / 2 ? threshold / 2 : threshold
        return headed > bar ? tack.other : tack
    }

    /// Her wind shadow factor under which she is in another boat's dirty air.
    static let dirtyAir = 0.85
    /// Dirty air, worth this much header: enough to tack out of on a header short of her threshold.
    static let dirtyAirWeight = deg2rad(2)
    /// A puff on the water ahead, per unit of its tone averaged along her track, is worth this much shift: a
    /// tenth more wind makes about 5% more VMG upwind, as about a degree and a half of shift does.
    static let puffWeight = deg2rad(14)
    /// Hull lengths within which she covers a boat behind her.
    static let coverRange = 5.0
    /// How far ahead she looks along each tack for puffs, metres, in steps.
    static let puffLookAhead: [Double] = [30, 60, 90, 120, 150]

    /// How much better, as degrees of shift, the wind drawn on the water ahead is on the other tack than on
    /// `tack`: positive when the puffs are that way, or the lulls this way.
    func puffAdvantage(_ b: SeatView.OwnBoat, _ view: SeatView, over tack: Tack) -> Double {
        guard !view.puffs.isEmpty else { return 0 }
        let up = grooveAngle(.upwind, b, view)
        let speed = max(b.speed, 2)
        func tone(_ tack: Tack) -> Double {
            let ahead = Vec2.heading(Aim(angle: up, tack: tack).heading(wind: b.windDirection))
            var total = 0.0
            for distance in Self.puffLookAhead where distance <= tactics.puffRange {
                let point = b.position + ahead * distance
                let seconds = distance / speed
                for puff in view.puffs {
                    let offset = point - (puff.center + puff.drift * seconds)
                    let d2 = offset.lengthSquared / (puff.radius * puff.radius)
                    guard d2 < 1 else { continue }
                    total += puff.tone * (1 - d2) * (1 - d2)
                }
            }
            return total / Double(Self.puffLookAhead.count)
        }
        return (tone(tack.other) - tone(tack)) * Self.puffWeight
    }

    /// More pressure ahead, per unit of the factor over hers, averaged along her track, is worth this much shift: as a
    /// puff's (`puffWeight`), a tenth more wind about a degree and a half. Weighed against the shift, so she plays the
    /// shifts first and leans to the pressure, rather than sailing off to it through them (#290's bot suite). The
    /// tactician's read (`Tactics.goesToThePressure`).
    static let pressureWeight = deg2rad(14)
    /// More pressure at the best spot she sees on a tack, per unit of the factor over hers, is worth this much shift: a
    /// live bot's read. More than a puff's: the pressure lasts, and a boat in it keeps its gain for as long as she stays.
    static let spotPressureWeight = deg2rad(30)
    /// How far ahead she reads the pressure along each tack, as shares of her `Tactics.puffRange`: out to twice it.
    static let pressureLookAhead: [Double] = [0.5, 1, 1.5, 2]
    /// The pressure over hers at which a place's bend counts in full: the edge of a pressure lane she'd sail into.
    /// Less, and its bend counts for that share; none, and not at all.
    static let laneEdgePressure = 0.1

    /// How much better, as degrees of shift, the pressure ahead is on the other tack than on `tack` (#290), out as far
    /// as she sees it on each (`pressureLookAhead`): its pressure over hers, and its wind's turn from hers as a lift on
    /// that tack. So she goes to the pressure, and into a pressure lane on the edge whose bend lifts her; the edge that
    /// would head her she leaves. Nothing past the race area's edge counts.
    ///
    /// How well she reads it is her skill's (#102, #290's ruling 2): a live bot reads each tack by the best spot she
    /// sees on it (`spotPressureWeight`), so the further she sees (`BotWeaknesses.puffPerception`) the better the spot
    /// she finds, and the tiers differ in how well they play the field. The tactician weighs the whole of her track
    /// (`pressureWeight`), and a bend only where she'd sail into more pressure: a bend with no more pressure in it is
    /// a shift she'd only sail into and out of again, not worth a tack.
    func pressureAdvantage(_ b: SeatView.OwnBoat, _ view: SeatView, over tack: Tack) -> Double {
        guard let map = view.pressure, tactics.puffRange > 0, let here = map.sample(at: b.position) else { return 0 }
        let up = grooveAngle(.upwind, b, view)
        let alongTrack = tactics.goesToThePressure
        func read(_ tack: Tack) -> Double {
            let ahead = Vec2.heading(Aim(angle: up, tack: tack).heading(wind: b.windDirection))
            // A veer lifts her on starboard, a back on port.
            let lift: Double = tack == .starboard ? 1 : -1
            var total = 0.0
            var best: Double?
            for share in Self.pressureLookAhead {
                guard let there = map.sample(at: b.position + ahead * (share * tactics.puffRange)) else { break }
                let gain = there.factor - here.factor
                let bend = lift * wrapAngle(there.turn - here.turn)
                if alongTrack {
                    total += gain * Self.pressureWeight + min(max(gain / Self.laneEdgePressure, 0), 1) * bend
                } else {
                    let value = gain * Self.spotPressureWeight + bend
                    best = max(best ?? value, value)
                }
            }
            return alongTrack ? total / Double(Self.pressureLookAhead.count) : best ?? 0
        }
        return read(tack.other) - read(tack)
    }

    /// The boat close behind her on the beat she'd cover: sailing upwind, within a few lengths and not
    /// ahead of her up the course, and far enough abeam that a tack onto her tack is clear of her.
    func coverTarget(_ b: SeatView.OwnBoat, _ view: SeatView) -> SeatView.OtherBoat? {
        let length = view.boatClass.hull.length
        let up = view.course.upwind
        var nearest: (boat: SeatView.OtherBoat, distance: Double)?
        for other in view.others where !other.isGhost {
            let offset = other.position - b.position
            let distance = offset.length
            guard distance < length * Self.coverRange * (0.5 + 0.5 * tactics.tacticalQuality), abs(wrapAngle(b.windDirection - other.heading)) < .pi / 3 else { continue }
            let behind = -offset.dot(up)
            guard behind > length, abs(offset.dot(up.rightPerp)) > length * 2 else { continue }
            if distance < nearest?.distance ?? .infinity { nearest = (other, distance) }
        }
        return nearest?.boat
    }

    /// The upwind groove on `tack`.
    func upwindAim(_ b: SeatView.OwnBoat, _ view: SeatView, tack: Tack) -> Aim {
        .groove(.upwind, tack: tack, angle: grooveAngle(.upwind, b, view))
    }

    /// Metres from her mark inside which she pinches to fetch it.
    static let pinchRange = 60.0
    /// The highest she pinches: this far off the wind, radians, well clear of the no-go zone.
    static let pinchAngle = deg2rad(38)

    /// The upwind aim on `tack` for a target `distance` metres off, bearing `relative` to the wind (to the right
    /// positive): the groove, or for a tactician close to it and just below its layline, the pinch that fetches it.
    func upwindAim(_ b: SeatView.OwnBoat, _ view: SeatView, tack: Tack, relative: Double, distance: Double) -> Aim {
        let groove = upwindAim(b, view, tack: tack)
        guard tactics.pinchesToFetch, distance < Self.pinchRange, tack == b.tack else { return groove }
        let off = tack == .starboard ? -relative : relative
        guard off >= Self.pinchAngle && off < groove.angle - view.boatClass.steering.autohelm.upwindSnap else { return groove }
        return Aim(angle: off, tack: tack)
    }

    // MARK: - Downwind

    /// The gybe to run on inside the corridor to her mark, starting from `planned`: the other one when the
    /// wind has shifted past her threshold the way that swings her heading away from the mark. Downwind that
    /// is a veer on starboard (her heading turns further from dead downwind) and a back on port: the mirror
    /// of a header upwind.
    mutating func downwindGybe(_ b: SeatView.OwnBoat, _ view: SeatView, planned gybe: Tack) -> Tack {
        guard let threshold = tactics.downwindShiftThreshold, view.time - lastTackTime > tactics.tackInterval else { return gybe }
        let direction = (senses.direction ?? b.windDirection) + senses.directionRate * tactics.anticipation
        let shift = wrapAngle(direction - view.course.axis)
        let away = gybe == .starboard ? shift : -shift
        return away > threshold ? gybe.other : gybe
    }

    /// How far above the groove she sails in a lull to stay on the plane: past the downwind snap.
    static let lullHeatUp = deg2rad(12)
    /// On the plane, she is in a lull when her speed is within this share above the class's off-plane speed.
    static let lullSpeedMargin = 1.25
    /// She heads up to plane at an angle where her speed off the plane reaches this share of the class's
    /// on-plane speed, so she gets there soon.
    static let planingSpeedMargin = 1.08
    /// The steps she searches for that angle in.
    static let planingSearchStep = deg2rad(2)

    /// `aim`, a groove or an angle off the wind, as her tactics sail it: headed up to get back on the plane
    /// when she has come off it and the wind is strong enough to plane, or above the groove in a lull on it.
    func downwindAim(_ b: SeatView.OwnBoat, _ view: SeatView, aim: Aim) -> Aim {
        guard let planing = view.boatClass.planing, aim.angle >= planing.fromTWA else { return aim }
        let tws = b.polarWindSpeed
        if !senses.planing {
            guard tactics.replanes, let angle = Self.planingAngle(tws: tws, deepest: aim.angle, view.boatClass),
                  aim.angle - angle > view.boatClass.steering.autohelm.downwindSnap else { return aim }
            return Aim(angle: angle, tack: aim.tack, tolerance: deg2rad(3))
        }
        // "Heats up in a lull, not in a shadow" (#263): a boat's wind shadow slows her whatever angle she sails
        // (`speedShadow`), so heading up there only sails her further.
        if tactics.heatsUpInLulls && b.speed < planing.offSpeed * Self.lullSpeedMargin && b.speedShadow >= 1 {
            return aim.offset(by: -Self.lullHeatUp, tolerance: deg2rad(3))
        }
        return aim
    }

    /// The deepest angle, no deeper than `deepest`, from which a boat of `boatClass` off the plane gets on
    /// it in `tws` (m/s): where her speed off the plane reaches the on-plane speed, with the margin, and the
    /// apparent wind comes no further aft than the class lets her plane with. Nil when the wind is too light
    /// to plane at any angle.
    static func planingAngle(tws: Double, deepest: Double, _ boatClass: BoatClass) -> Double? {
        guard let planing = boatClass.planing else { return nil }
        var angle = deepest
        while angle >= planing.fromTWA {
            var speed = planing.offPlaneSpeed(twa: angle, tws: tws, polar: boatClass.polar)
            // Heading up past the spinnaker's drop she sails on two sails.
            if let spinnaker = boatClass.spinnaker, angle < spinnaker.dropBelowTWA { speed *= spinnaker.twoSailFactor(twa: angle) }
            // Her apparent wind: the true wind plus her own, over the bow. RegattaCore's sine and cosine
            // (`Vec2.heading`), so a debug build decides as a release build does.
            let wind = Vec2.heading(angle) * tws
            let ahead = wind.y + speed
            let apparent = (ahead * ahead + wind.x * wind.x).squareRoot()
            if speed >= planing.onSpeed * planingSpeedMargin && apparent > 0 && ahead / apparent >= Vec2.heading(planing.onMaxAWA).y {
                return angle
            }
            angle -= planingSearchStep
        }
        return nil
    }
}

extension Tack {
    /// The other tack.
    var other: Tack { self == .port ? .starboard : .port }
}
