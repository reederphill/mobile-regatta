import RegattaCore

// Her planing on a class with the new planing rule (#462, skiff@9: `PlaningTuning.stayOnSpeedShare` and
// `apparentWind`), where a bad gybe, a run sailed too deep and a lull take her off the plane and only heading up gets
// her back on. A class without those values keeps `downwindAim`'s tactics as they were, to the bit. Internal
// heuristics, never shown to a player:
//
// - "Head up to plane after a drop": off the plane she luffs until she is planing again, holds that angle until she
//   is up to speed, then bears back to her groove. Every bot does, as every sailor does; how well is her handling
//   (`BotBrain.turnHandling`): a poor helm is slower to notice she is off, and luffs too little or too much at first.
//   Bearing away the moment the hull lifts she would drop straight off again: slow, with the wind coming aft.
// - "Keep the wind in her sails": on the plane she sails no deeper than leaves her the apparent wind she planes on,
//   with a margin. For most bots that is the wind her groove reads; one who reads the lulls (`Tactics.heatsUpInLulls`)
//   heads up as the wind drops, before she falls rather than after.
// - "Build speed before she bears away": slow for her angle (round the windward mark, out of a turn) she comes down
//   only as she gathers speed, the apparent wind kept forward.
// - "Bear away gently": planing, she bears away with no more rudder than she gybes with.
// - "The kite goes soft, she heads up": her hand wanders off the angle she aims at; when the one she is at is about
//   to drop her she luffs from there, a good helm sooner than a poor one.
// - "Not at the mark": close to her mark she sails for it, on the plane or off.
//
// Bots err on the side of caution (the owner's ruling of 2026-10-11): each sails within her own skill, a safer line for
// herself and nothing to do with the boats around her.
// - "Inside her own hand": she aims above the plane's edge by what her hand wanders (`ownRunAngle`), so its
//   excursions stay on the plane: nothing for a perfect hand, 10° above her groove for Club's centre.
// - "Come down as she gathers speed": slow out of a rounding she bears away only as fast as her speed lets her stay
//   on, however deep her mark or a missed groove asks her to sail (`floorAim`'s reach, from her groove).
// - "A gybe within her skill": a helm who would slam gybes on half rudder, a wider, slower arc that stays on the plane
//   (`PlaningTable.safeGybe`, `startHandTurn`); a flubbed gybe is still cranked, and falls.

/// The planing heuristics' values (#462), one table to tune, as `HandTackTable` is the hand turn's.
public enum PlaningTable {
    /// Seconds off the plane before she notices and heads up: `good` at `noticeHandling.good` or better, in a line to
    /// `poor` at `noticeHandling.poor` or worse.
    public static let notice = (good: 0.3, poor: 2.5)
    public static let noticeHandling = (good: 0.8, poor: 0.3)
    /// How far off the angle that planes soonest she first luffs, radians, either side (too little or too much), drawn
    /// up to this at `noticeHandling.poor`; none at `good`. It fades over `correctSeconds` as she feels for it.
    public static let misjudge = deg2rad(10)
    public static let correctSeconds = 4.0
    /// She heads up to where the class lets her on the plane at this share of the speed she comes to there off the
    /// plane (the first that has an angle): she is there in a few seconds, not at the end of her acceleration.
    public static let soon = [0.92, 0.96, 1.0]
    /// Back on the plane she holds the angle that got her there until she has this share of her polar speed at the
    /// angle she is bearing back to (the class drops her off under `stayOnSpeedShare` of it with the wind aft), or
    /// `longestHold` seconds.
    public static let upToSpeed = 0.85
    public static let longestHold = 12.0
    /// Metres from her mark inside which she sails for it rather than head up to plane.
    public static let markRange = 60.0
    /// On the plane she keeps this much apparent wind in hand over what the class drops her off at, m/s.
    public static let floorMargin = metresPerSecond(knots: 0.5)
    /// The furthest above her aim she heads up to keep it, radians, in `floorStep`s.
    public static let floorReach = deg2rad(40)
    public static let floorStep = deg2rad(1)
    /// Slow for her angle she bears away only with this much of her polar speed there over the class's stay-on share
    /// (`good` at `noticeHandling.good` or better, to `poor`), or with the apparent wind this much (a cosine) forward
    /// of the class's limit.
    public static let speedMargin = (good: 0.1, poor: 0.03)
    public static let forwardMargin = 0.17
    /// "The kite goes soft": the apparent wind over what the class drops her off at, m/s, under which she luffs from
    /// where she is (`good` at `noticeHandling.good` or better, to `poor`), `luffStep` radians a decision: little
    /// enough rudder that it costs her no speed, enough that the class does not count it centred.
    public static let reflexMargin = (good: metresPerSecond(knots: 0.6), poor: metresPerSecond(knots: 0.1))
    public static let luffStep = deg2rad(6)
    /// Luffing to plane again she turns this far a decision at most, radians.
    public static let replaneStep = deg2rad(9)

    /// Switches for measuring each heuristic by itself (#462's build order); all on in play.
    public static let headsUpAfterAFall = true
    public static let keepsTheFloor = true
    public static let luffsOnASoftKite = true
    public static let bearsAwayGently = true
    /// Hull lengths from a mark inside which she bears away with all the rudder its rounding asks.
    public static let gentleMarkLengths = 3.0

    /// "Inside her own hand" (the owner's ruling of 2026-10-11, bots err on the side of caution): she aims this share
    /// of her hand's wander running (`BotWeaknesses.wander` times `HandSteeringTable.downwindWander`) above the
    /// deepest angle that keeps `floorMargin`. More than the wander itself: her lag on a shift and her overshoot carry
    /// her past it (measured: a hand that wanders 13° was dropped 15° deep of her aim). In 9 to 13 kn Club's centre
    /// (handling 0.55) aims 10° to 11° above her groove and the floor of her band 18°, National's (0.8) 1° to 2°; a
    /// perfect hand sails her groove.
    /// Measured on the mixed quick loop, Club / Regional / National falls for want of apparent wind a boat a race:
    /// 1.40 / 1.54 / 0.85 at 0, 1.08 / 1.19 / 1.06 at 1, 0.67 / 0.82 / 1.14 at 1.3, 0.51 / 0.61 / 0.74 at 1.6.
    public static let handMargin = 1.6
    /// "A gybe within her skill": racing, the most rudder she gybes with, a share of full, whatever her handling
    /// (`HandTackTable.gybeFraction` gives a poor helm all of it). Half is on the plane from every speed she gybes at;
    /// at 75 % she fell entering slow (70 % of her polar speed; 60 %: gybe falls 1.89 to 1.57 a boat a race for Club,
    /// 50 %: 1.29). A flubbed gybe is still cranked hard over, and falls.
    public static let safeGybe = 0.5
}

extension BotBrain {
    /// What she is doing about a fall off the plane (`planingAim`).
    struct Replane: Sendable, Equatable {
        /// The race clock at her last decision with it.
        var time: Double
        /// When she notices she is off.
        var noticeAt: Double
        /// How far off the angle that planes soonest she first luffs, radians: positive too little (deeper).
        var error: Double
        /// The angle she luffed to, once she has; and since when she has been back on the plane holding it.
        var angle: Double?
        var backOnAt: Double?
    }

    /// The stream of her seed her planing's draws come from: ASCII "planeagn". Only a class with the new rule draws.
    static let planingStream: UInt64 = 0x706C_616E_6561_676E

    /// Whether her class has the new planing rule (#462): everything in this file is behind it.
    static func hasPlaningRule(_ boatClass: BoatClass) -> Bool {
        guard let planing = boatClass.planing else { return false }
        return planing.stayOnSpeedShare != nil || planing.apparentWind != nil
    }

    /// `aim` downwind on a class with the new planing rule: headed up to plane after a fall, held there until she is up
    /// to speed, and on the plane no deeper than keeps the wind in her sails. `nearMark`: within
    /// `PlaningTable.markRange` of her mark.
    mutating func planingAim(_ b: SeatView.OwnBoat, _ view: SeatView, aim: Aim, nearMark: Bool) -> Aim {
        let boatClass = view.boatClass
        guard let planing = boatClass.planing, aim.angle >= planing.fromTWA, b.status == .racing else {
            replane = nil
            return aim
        }
        let tws = b.polarWindSpeed
        // A fall she was dealing with on another leg is not this one.
        if let state = replane, view.time - state.time > 2 { replane = nil }
        guard PlaningTable.headsUpAfterAFall, !nearMark else {
            replane = nil
            return senses.planing ? floorAim(b, view, aim: aim) : aim
        }
        if !senses.planing {
            guard let angle = Self.replaneAngle(tws: tws, deepest: aim.angle, boatClass, speedNow: b.speed) else {
                replane = nil
                return aim
            }
            var state = replane ?? newReplane(view)
            state.time = view.time
            state.backOnAt = nil
            defer { replane = state }
            guard view.time >= state.noticeAt else { return aim }
            let fade = max(0, 1 - (view.time - state.noticeAt) / PlaningTable.correctSeconds)
            let target = min(aim.angle, max(planing.fromTWA, angle + state.error * fade))
            state.angle = target
            guard target < aim.angle else { return aim }
            // She luffs to it a step a decision: hard over, the rudder takes the speed she is luffing for.
            let actual = abs(sailingAngle(b))
            let step = aim.tack == b.tack && target < actual ? max(target, actual - PlaningTable.replaneStep) : target
            return Aim(angle: step, tack: aim.tack, tolerance: deg2rad(3))
        }
        guard var state = replane, let held = state.angle else {
            replane = nil
            return floorAim(b, view, aim: aim)
        }
        // Back on: she holds her angle until she is up to speed.
        let since = state.backOnAt ?? view.time
        let fast = boatClass.polar.speed(twa: aim.angle, tws: tws) * b.speedShadow * PlaningTable.upToSpeed
        guard b.speed < fast, view.time - since <= PlaningTable.longestHold, held < aim.angle else {
            replane = nil
            return floorAim(b, view, aim: aim)
        }
        state.time = view.time
        state.backOnAt = since
        replane = state
        return Aim(angle: held, tack: aim.tack, tolerance: deg2rad(3))
    }

    /// The deepest angle, no deeper than `deepest`, at which a boat of `boatClass` off the plane in `tws` (m/s) is
    /// planing again soon: where the class's rule lets her on at `PlaningTable.soon` of the speed she comes to there
    /// off the plane, or at the speed she still has, less a twentieth (just off the plane for want of apparent wind, a
    /// few degrees up get her back on before she has slowed). Nil when the wind is too light to plane at any angle.
    ///
    /// `planingAngle`, an older class's, asks for the speed with a margin and the apparent wind's angle with none:
    /// at 12 kn of wind it finds the angle where her apparent wind comes abeam only at the very speed she ends at, and
    /// she sits there 12 s and more (measured: 138° at 9.4 kn in 12.5 kn of wind, back on after 20 s; never in 30 s at
    /// 13.4 kn). Kept for those classes, to the bit.
    static func replaneAngle(tws: Double, deepest: Double, _ boatClass: BoatClass, speedNow: Double = 0) -> Double? {
        guard let planing = boatClass.planing else { return nil }
        for share in PlaningTable.soon {
            var angle = deepest
            while angle >= planing.fromTWA {
                var speed = planing.offPlaneSpeed(twa: angle, tws: tws, polar: boatClass.polar)
                // Heading up past the spinnaker's drop she sails on two sails.
                if let spinnaker = boatClass.spinnaker, angle < spinnaker.dropBelowTWA { speed *= spinnaker.twoSailFactor(twa: angle) }
                speed = max(share * speed, 0.95 * speedNow)
                if planing.isPlaning(was: false, twa: angle, speed: speed, tws: tws, rudder: 0, polar: boatClass.polar) { return angle }
                angle -= PlaningTable.floorStep
            }
        }
        return nil
    }

    /// A fall she has just had: when she notices it and how far off she first luffs, from her handling.
    private mutating func newReplane(_ view: SeatView) -> Replane {
        let h = turnHandling
        let notice = HandTackTable.ramp(h, PlaningTable.notice, PlaningTable.noticeHandling)
        let size = HandTackTable.ramp(h, (0, PlaningTable.misjudge), PlaningTable.noticeHandling)
        let error = size > 0 ? planingRng.range(-size, size) : 0
        return Replane(time: view.time, noticeAt: view.time + notice, error: error)
    }

    /// "Keep the wind in her sails" and "build speed before she bears away": `aim`, or an angle above it that keeps
    /// her on the plane.
    ///
    /// - It leaves her `PlaningTable.floorMargin` of apparent wind over what the class drops her off at. A bot who
    ///   reads the lulls reckons it in the wind she has now, at her speed and at her polar's, out of a boat's shadow
    ///   (heading up there only sails her further into it, #263); every other in the wind her groove reads, at her
    ///   polar's speed: she sails no deeper than planes in a steady wind, and a lull catches her.
    /// - Slow for the angle (round a windward mark, out of a turn, after a boat) she keeps the apparent wind forward
    ///   of where the class lets her plane with it, or has the class's share of her polar speed there and
    ///   `PlaningTable.speedMargin` more: she bears away as she gathers speed, not before.
    /// - "The kite goes soft, she heads up": whatever she aims at, her hand wanders (`HandSteering`), and the angle
    ///   she is at now may be the one about to drop her. Then she luffs from where she is, `PlaningTable.luffStep` a
    ///   decision, until it is not; how close to the edge she lets it get is her handling (`reflexMargin`).
    ///
    /// Never more than `luffStep` above the angle she is at: a rudder put hard over to get there would cost her the
    /// speed she is short of.
    func floorAim(_ b: SeatView.OwnBoat, _ view: SeatView, aim: Aim) -> Aim {
        guard PlaningTable.keepsTheFloor, let planing = view.boatClass.planing else { return aim }
        let polar = view.boatClass.polar
        let now = b.polarWindSpeed
        let reads = tactics.heatsUpInLulls && b.speedShadow >= 1
        let tws = reads ? now : senses.grooveWind ?? now
        let share = planing.stayOnSpeedShare.map {
            $0 + HandTackTable.ramp(turnHandling, PlaningTable.speedMargin, PlaningTable.noticeHandling)
        }
        let forward = Vec2.heading(planing.onMaxAWA).y
        /// Whether she is fast enough for `angle`, or has the apparent wind forward enough not to need to be.
        func fast(_ angle: Double) -> Bool {
            guard let share, b.speed < share * polar.speed(twa: angle, tws: now) else { return true }
            // Her apparent wind: the true wind plus her own, over the bow (`Vec2.heading`'s sine and cosine).
            let wind = Vec2.heading(angle) * now
            let ahead = wind.y + b.speed
            let apparent = (ahead * ahead + wind.x * wind.x).squareRoot()
            return apparent > 0 && ahead / apparent >= forward + PlaningTable.forwardMargin
        }
        func keeps(_ angle: Double) -> Bool {
            if let floor = planing.apparentWind {
                let need = floor.offSpeed(tws: tws) + PlaningTable.floorMargin
                if BoatClass.PlaningTuning.apparentWindSpeed(twa: angle, speed: polar.speed(twa: angle, tws: tws), tws: tws) < need { return false }
                if reads, BoatClass.PlaningTuning.apparentWindSpeed(twa: angle, speed: b.speed, tws: tws) < need { return false }
            }
            return fast(angle)
        }
        let actual = abs(sailingAngle(b))
        // Reckoned from her groove, not from an aim far below it (a groove she misses, a mark dead downwind): slow out
        // of a rounding she comes down as she gathers speed, however deep she is asked to sail.
        let highest = max(planing.fromTWA, min(aim.angle, polar.bestDownwind(tws: now).twa) - PlaningTable.floorReach)
        // The reflex: the angle she is at is about to drop her.
        if PlaningTable.luffsOnASoftKite, actual > highest, aim.tack == b.tack {
            let margin = HandTackTable.ramp(turnHandling, PlaningTable.reflexMargin, PlaningTable.noticeHandling)
            let soft = planing.apparentWind.map {
                BoatClass.PlaningTuning.apparentWindSpeed(twa: actual, speed: b.speed, tws: now) < $0.offSpeed(tws: now) + margin
            } ?? false
            if soft || !fast(actual) {
                var luff = Aim(angle: max(min(aim.angle, actual - PlaningTable.luffStep), highest), tack: aim.tack, tolerance: deg2rad(1))
                luff.insists = true
                return luff
            }
        }
        var angle = aim.angle
        let held = !keeps(angle)
        if held {
            while angle > highest, !keeps(angle) { angle -= PlaningTable.floorStep }
            // No further up from where she is than a step: she holds what she has while she gathers speed.
            if angle < actual { angle = min(aim.angle, max(angle, actual - PlaningTable.luffStep)) }
            angle = max(angle, highest)
        }
        // Inside her own hand: the same angle wherever her hand has her now, or she would give it up just as it
        // carries her deep.
        let own = ownRunAngle(b, view, deepest: aim.angle)
        if own < angle { return Aim(angle: own, tack: aim.tack, tolerance: deg2rad(2)) }
        return held ? Aim(angle: angle, tack: aim.tack, tolerance: deg2rad(2)) : aim
    }

    /// "Inside her own hand": the deepest angle, no deeper than `deepest`, from which her hand's wander leaves her on
    /// the plane: `PlaningTable.handMargin` of her wander running deeper than it she still has `floorMargin` of
    /// apparent wind over the class's floor, at her polar speed in the wind her groove reads. A boat sailing within her
    /// own skill: a helm with no wander sails `deepest`; a poor one sails hotter, and further for it.
    func ownRunAngle(_ b: SeatView.OwnBoat, _ view: SeatView, deepest: Double) -> Double {
        let hand = PlaningTable.handMargin * weaknesses.wander * HandSteeringTable.downwindWander
        guard hand > 0, let planing = view.boatClass.planing, let floor = planing.apparentWind else { return deepest }
        let polar = view.boatClass.polar
        let tws = senses.grooveWind ?? b.polarWindSpeed
        let need = floor.offSpeed(tws: tws) + PlaningTable.floorMargin
        let highest = max(planing.fromTWA, deepest - PlaningTable.floorReach)
        var angle = deepest
        while angle > highest {
            let deep = min(angle + hand, .pi)
            if BoatClass.PlaningTuning.apparentWindSpeed(twa: deep, speed: polar.speed(twa: deep, tws: tws), tws: tws) >= need { break }
            angle -= PlaningTable.floorStep
        }
        return angle
    }

    /// "Bear away gently": `input`, her helm's rudder for an aim `error` radians off, with no more rudder than she
    /// gybes with (`HandTackTable.gybeFraction`: a good helm's 30 %, a poor one's all of it) while she is planing,
    /// racing, and it bears her away. Hard over round the windward mark and the offset the rudder's drag took her
    /// off the plane she had just got on (a class with the new rule drops her under a share of her polar speed).
    func bearingAwayGently(_ input: BoatInput, _ error: Double, _ b: SeatView.OwnBoat, _ view: SeatView) -> BoatInput {
        guard PlaningTable.bearsAwayGently, error > 0, senses.planing, b.status == .racing, Self.hasPlaningRule(view.boatClass),
              let planing = view.boatClass.planing, abs(sailingAngle(b)) >= planing.fromTWA,
              // Not round a mark: there she turns as tight as the mark asks.
              isClearOfMarks(b, view, lengths: PlaningTable.gentleMarkLengths) else { return input }
        let most = HandTackTable.gybeFraction(handling: turnHandling)
        guard abs(input.rudderValue) > most else { return input }
        return BoatInput(rudder: input.rudderValue < 0 ? -most : most, ease: input.ease)
    }
}
