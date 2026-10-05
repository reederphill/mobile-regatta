import RegattaCore

// A bot's fleet tactics (#234, #223): how she plays the boats around her up a beat, as a handful of named heuristics,
// the way real sailors do (#276: "predictable heuristics like real life"). Internal: nothing here is ever shown to a
// player, as a notice or anything else, and nothing here is a decision field.
//
// - Hold her lane: in clear air with a boat in her backwind or close to windward on her tack, she holds on rather than
//   tack away, on all but a big header. Her tactical choice; defending a lane as the right-of-way boat under the
//   rules is #101's (`holdingCourse`).
// - Cover: she tacks with the nearest boat behind her that has tacked away, to stay between it and the mark.
// - Lee-bow: on port, meeting a starboard boat she can just cross, she tacks onto her lee bow when her tack, as she
//   reckons it, would leave her in her backwind; one she can't cross she ducks, as she keeps clear (`racingKeepClear`),
//   no code here.
// - Tack on her wind: ahead of a boat on the other tack and upwind of it (to windward in the wind's frame, up to
//   `FleetTactics.tackOnWindLeewardSlack` to leeward of its track), she tacks to put her in her wind shadow, when that
//   pays against her own plan (the tack's cost, the shift, puffs and pressure).
//
// Targets are chosen from her `SeatView` alone (#98), by where the boats are and how they sail: never by who sails
// them (`BotSourceTests` keeps the seat kinds out of every brain file). How willing she is to play them is her style's
// engagement (`Tactics.engagement`); how well, her skill's: she sees a boat tack only after her reaction delay
// (`BotWeaknesses.reactionDelay`), and reads a lee-bow or a tack on a boat's wind up to `FleetTactics.timingError`
// seconds early or late the less tactical quality she has (`BotWeaknesses.tacticalQuality`), a draw of her own per boat
// (`BotBrain.tacticsRng`). Every tack is still her tap (`canTap`): only clear of every boat (`tapIsClear`, rules 13
// and 15), never within `tackInterval` of her last, never inside `tacticalRange` of her mark or past the corridor or
// a layline (a lee-bow alone may come inside her tack interval, #329). She never forces a foul, and never protests
// (#19).

/// What a bot has made of the boats around her (#234): each boat's tack as she last saw it, when she saw it change, and
/// her timing error on that boat. Keyed by seat, and rebuilt every decision in `SeatView.others`' order, never
/// iterated (ADR 0002).
struct FleetSense: Sendable {
    struct Boat: Sendable, Equatable {
        var tack: Tack
        /// The race clock when she saw it tack onto `tack`; −∞ for a tack she never saw it make.
        var tackedAt: Double
        /// −1…1: how early (positive) or late she reads this boat (`FleetTactics.timingError`).
        var timing: Double
    }

    var bySeat: [Int: Boat] = [:]
}

extension BotBrain {
    /// A fleet tactic she plays (#234), on the boat in `seat`.
    struct FleetPlay: Sendable, Equatable {
        enum Kind: Sendable, Equatable { case holdLane, cover, leeBow, tackOnWind }
        var seat: Int
        var play: Kind
    }

    /// The fleet tactics' placeholders (#234): engagement floors, ranges and geometry, in hull lengths unless named.
    enum FleetTactics {
        /// The engagement from which she plays each (`BotStyle.engagement`): below the cover floor she sails her own
        /// race, still tacking out of dirty air.
        static let coverEngagement = 0.3
        static let laneEngagement = 0.3
        static let leeBowEngagement = 0.5
        static let tackOnWindEngagement = 0.6
        /// Holding her lane, she tacks only on a header past this many times her threshold.
        static let laneHeader = 2.0
        /// A boat within this many lengths, on her tack, to windward of her by `laneWindward` or more and no further
        /// ahead than `laneAhead`, is one she holds her lane against.
        static let laneRange = 3.0
        static let laneWindward = 0.3
        static let laneAhead = 0.5
        /// She covers a boat behind her within this many lengths, at full engagement and tactical quality: less of it
        /// with less of each (`Tactics.engagement`, `Tactics.tacticalQuality`).
        static let coverRange = 8.0
        /// Seconds after her reaction delay before she covers a boat that has tacked away, and after which it's too
        /// late to (a Club bot "covers badly and late", #223).
        static let coverReaction = 1.0
        static let coverLate = 8.0
        /// Lengths abeam a boat must be to have tacked away from her, and behind her up the course.
        static let coverAbeam = 2.0
        static let coverBehind = 1.0
        /// A lee-bow (#298's trapezoid, before #377's upwash: a tack 3 L ahead and 1.5 L to leeward of a starboard boat
        /// lands her on her lee bow, the starboard boat 1 to 2.5 L astern of her in her backwind): on port, to leeward of a starboard boat
        /// within `leeBowRange` she can just cross (sailing on she would pass ahead of her and clear, as she keeps clear,
        /// `BotBrain.keepClearDistance`), she tacks when her tack now, as she reckons it (`tackCarry`, `tackPickUp`),
        /// would leave the starboard boat in her backwind and `leeBowAstern` lengths or more astern of her at every one
        /// of `tackOnWindSeconds`. The geometry is her reckoning's, not a fixed window.
        static let leeBowRange = 8.0
        static let leeBowAstern = 0.75
        /// For a class whose backwind is the upwash beside her sail (#377, `BoatClass.WindShadow.upwashExtent`): the
        /// zone lies along her hull, from her mast back past her stern (to `upwashAftHullLengths` astern of it), so a
        /// lee-bow lands beside her or close astern, not only clear astern.
        /// Her tack lands when the boat is in that zone and this many lengths or more to windward of her centre line
        /// (clear of her hull, centre to centre) at every one of `tackOnWindSeconds`, in place of `leeBowAstern`.
        static let leeBowAbeam = 0.5
        /// Whether a lee-bow tacks her inside her tack interval (`Tactics.tackInterval`, #329, the owner's call): it
        /// answers a crossing, it isn't a tack of her choosing. Every other guard still holds (`canTap`, the corridor,
        /// the laylines and `tacticalRange`).
        static let leeBowInsideTackInterval = true
        /// Whether the tactician (`BotProfile.tactician`) lee-bows and tacks on a boat's wind, fully engaged (#234's ruling
        /// 3: only if her fun-pass win share, gain and beat-the-blip-tacker don't fall). #329 measured it on 16 seeds with
        /// the forecast trigger and the pays-check: none fell (0.72, 1.87, 0.71 either way; 12 of 256 races differ), so
        /// she does. Her cover stays #231's, and she holds no lane.
        static let tacticianLeeBowsAndTacksOnWind = true
        /// She tacks on a boat's wind within this many lengths of her ...
        static let tackOnWindRange = 8.0
        /// ... and she no more than this many hull lengths to leeward of its track (#349): her distance from its track,
        /// measured from her position perpendicular to its heading; to windward of its track always passes. skiff@5's
        /// cone, swung half astern (#339), covers a boat best while she is still 0.1 to 0.5 L to leeward of its track and
        /// lets go as she crosses it (`BotTacticsTests.crossingAhead`, seeds 3, 11 and 20: a forecast factor of
        /// 0.69–0.74 to leeward, 0.75–0.79 at best once across), so a gate at its track hid the window. Measured: 0.5,
        /// 1.0 and no slack at all tap at the same moment in that scene; 1.0 clears the 0.4 L the first good decision
        /// needs with room (`BotTacticsTests.tackOnWindGateAllowsOnlyTheSlackToLeeward`).
        static let tackOnWindLeewardSlack = 1.0
        /// ... when, her tack done, the boat sits in her wind shadow these seconds on, at a factor under
        /// `tackOnWindShadow` on average ...
        static let tackOnWindSeconds: [Double] = [4, 5, 6]
        static let tackOnWindShadow = 0.75
        /// ... clear astern of her on her new tack by this many lengths or more, so she is clear ahead ...
        static let tackOnWindAstern = 1.0
        /// ... and the tack pays against her own plan (`paysToTackOnWind`): the boat's loss, `shadowCost` lengths a
        /// second per unit of shadow (1 − her forecast factor) for the `shadowHeld` seconds she holds her there (until
        /// the boat sees it and is out of it: a reaction, up to 8 s at Club, and a tack away), beats her tack's cost
        /// (`tackCost`: lengths, by the wind she sails in, m/s; #263's 0.74 / 1.10 / 1.27 L at 6 / 10 / 14 kn on
        /// skiff@4): more on a lift or with the puffs or pressure this side, less on a header or in dirty air (her
        /// plan's lean to the other tack, as a share of her threshold).
        ///
        /// `shadowCost` is measured in the scene she plays it in (#329, `BotTacticsTests.crossingAhead`'s geometry,
        /// four seeds, three crossings, her tap scripted at the forecast trigger, factor 0.70–0.78): the starboard boat
        /// loses 0.65–0.93 L (mean 0.85) over the 10 s after her tap against a clean twin, nearly all of it after the
        /// first 5 s (her tack, then the boat's own slowing down), so 0.32 L a second per unit of forecast shadow. It
        /// is less than #263's 1.36–1.47 L over 5 s with a boat 1 L down the cone (0.56 a unit), which sits deep in it
        /// from the first second; the forecast factor (4 to 6 s on) is shallower than where she sits once in it. So a
        /// tack on a boat's wind at the trigger pays on its own (a neutral plan) only in light air: about 0.85 L against
        /// 0.74 L at 6 kn and 1.10 L at 10 kn; in more wind, only when her plan leans to the other tack.
        ///
        /// #349 re-measured it on skiff@5's cone (#339) in the same scene, the real bot tapping at the forecast trigger
        /// (seeds 3, 11, 20; forecast 0.71 / 0.74 / 0.75): the loss over the 10 s after her tap against the clean twin
        /// over 10 × (1 − forecast) is 0.46 / 0.42 / 0.41 L. It stays 0.32: a larger cost makes the pays-check easier
        /// (a loosening), which is the owner's call (`FleetTacticsTuningTests.tackOnWindPayoffBinds` binds at 0.32).
        static let shadowCost = 0.32
        static let shadowHeld = 10.0
        static let tackCost: [(wind: Double, lengths: Double)] = [(3.09, 0.74), (5.14, 1.10), (7.20, 1.27)]
        /// How she reckons her tack, measured in the scripted scenes (`BotTacticsTests`, skiff@4 rolling her tack at
        /// 10 kn: through it in about 2.5 s, back to speed about 6 s after her tap): sailing on her heading now at this
        /// share of her speed now for so many seconds ...
        static let tackCarry = (seconds: 2.0, share: 0.58)
        /// ... and on her new heading, at these shares of her speed now between these seconds after her tap; at her
        /// speed now after the last.
        /// One phase of her reckoned pick-up (an array element, not a dictionary: the determinism scan reads a
        /// `[label: Type]` annotation as one).
        typealias PickUpPhase = (from: Double, to: Double, share: Double)
        static let tackPickUp: [PickUpPhase] = [(0.75, 3.5, 0.55), (3.5, 6, 0.75), (6, .infinity, 1)]
        /// The share of her speed now she is making `t` seconds after her tap, as she reckons it: her cone's backwind
        /// grows with her speed through the water (`BoatClass.WindShadow.backwindScale(speed:)`), so a boat just out of
        /// a tack casts a smaller one than at full speed. The pick-up's share in force at `t`, else the carry's.
        static func tackSpeedShare(at t: Double) -> Double {
            for phase in FleetTactics.tackPickUp where t > phase.from && t <= phase.to { return phase.share }
            return tackCarry.share
        }
        /// Seconds early or late she reads a lee-bow or a tack on a boat's wind, at no tactical quality; none at full.
        static let timingError = 2.0
        /// A boat further off the wind than this, radians, isn't beating: no fleet tactic plays her.
        static let beating = Double.pi / 3
        /// How far her cone's apex may sit from her, metres, and its forward from her heading, radians, for it to be
        /// hers (`ownCone`; the sine of the angle between them, for a small one): float noise, no more.
        static let ownConeTolerance = (metres: 1e-6, radians: 1e-6)
    }

    /// Whether she plays any fleet tactic.
    var playsTheFleet: Bool { tactics.coversTackers || tactics.leeBows || tactics.tacksOnWind || tactics.holdsLane }

    /// Takes in what she sees of the boats around her now (`FleetSense`): a boat's tack seen to change marks when.
    mutating func observeFleet(_ view: SeatView) {
        guard playsTheFleet else { return }
        var bySeat: [Int: FleetSense.Boat] = [:]
        for other in view.others where !other.isGhost {
            if var boat = fleet.bySeat[other.seat] {
                if boat.tack != other.tack {
                    boat.tack = other.tack
                    boat.tackedAt = view.time
                }
                bySeat[other.seat] = boat
            } else {
                bySeat[other.seat] = FleetSense.Boat(tack: other.tack, tackedAt: -.infinity, timing: tacticsRng.range(-1, 1))
            }
        }
        fleet.bySeat = bySeat
    }

    /// The fleet tactic she plays now, beating on her own tack (`planned` hers), racing and not tacking, or nil: holding
    /// her lane, or a lee-bow, a cover or a tack on a boat's wind, in that order. A tack only when she can tap it now
    /// (`canTap`), onto a board she hasn't `overstood`, and not onto a header worse than her threshold (`headed`, the
    /// shift on her tack, positive headed). `lean` is how much her own plan leans to the other tack, as `headed` with
    /// the puffs, the pressure and her dirty air in it: a tack on a boat's wind must pay against it.
    ///
    /// `leeBowOnly`: inside her tack interval (`Tactics.tackInterval`) she answers a crossing with a lee-bow all the
    /// same (#329: it answers a crossing, it isn't a tack of her choosing), and plays nothing else.
    func fleetPlay(_ b: SeatView.OwnBoat, _ view: SeatView, planned tack: Tack, headed: Double, lean: Double,
                   threshold: Double, leeBowOnly: Bool = false, overstood: (Tack) -> Bool) -> FleetPlay? {
        guard playsTheFleet, b.status == .racing, tack == b.tack, !senses.tacking else { return nil }
        if tactics.holdsLane, let seat = laneNeighbour(b, view) { return FleetPlay(seat: seat, play: .holdLane) }
        guard headed > -threshold, !overstood(tack.other) else { return nil }
        // The lee-bow before the cover: a crossing passes in a second or two, a cover's chance lasts `coverLate`.
        let leeBow = tactics.leeBows ? leeBowTarget(b, view).map { FleetPlay(seat: $0, play: .leeBow) } : nil
        let play = leeBowOnly ? leeBow : (leeBow
            ?? (tactics.coversTackers ? coverTackTarget(b, view).map { FleetPlay(seat: $0, play: .cover) } : nil)
            ?? (tactics.tacksOnWind
                ? tackOnWindTarget(b, view, lean: lean, threshold: threshold).map { FleetPlay(seat: $0, play: .tackOnWind) }
                : nil))
        guard let play, canTap(b, view) else { return nil }
        return play
    }

    /// The boat she holds her lane against, if she has one: she in clear air, the nearest boat on her tack within
    /// `laneRange` that is to windward of her and not ahead of her (in her backwind, or alongside to windward).
    func laneNeighbour(_ b: SeatView.OwnBoat, _ view: SeatView) -> Int? {
        guard b.shadow >= 1 else { return nil }
        let length = view.boatClass.hull.length
        let forward = b.forward
        let windward = b.tack == .starboard ? forward.rightPerp : -forward.rightPerp
        return nearest(view, within: length * FleetTactics.laneRange, of: b) { other, offset in
            other.tack == b.tack && offset.dot(windward) >= length * FleetTactics.laneWindward
                && offset.dot(forward) <= length * FleetTactics.laneAhead
        }
    }

    /// The boat she covers (`Tactics.coversTackers`): the nearest one beating behind her up the course, within her cover
    /// range and far enough abeam to have tacked away, that she has seen tack onto the other tack from hers, a reaction
    /// time ago (`BotWeaknesses.reactionDelay` and `FleetTactics.coverReaction`) and not too late (`coverLate`).
    func coverTackTarget(_ b: SeatView.OwnBoat, _ view: SeatView) -> Int? {
        let length = view.boatClass.hull.length
        let range = length * FleetTactics.coverRange * (0.5 + 0.5 * tactics.tacticalQuality) * (0.25 + 0.75 * tactics.engagement)
        let up = view.course.upwind
        let seen = weaknesses.reactionDelay + FleetTactics.coverReaction
        return nearest(view, within: range, of: b) { other, offset in
            guard other.tack != b.tack, let boat = fleet.bySeat[other.seat], boat.tack == other.tack else { return false }
            let age = view.time - boat.tackedAt
            return age >= seen && age <= max(seen, FleetTactics.coverLate) && -offset.dot(up) > length * FleetTactics.coverBehind
                && abs(offset.dot(up.rightPerp)) > length * FleetTactics.coverAbeam
        }
    }

    /// The starboard boat she lee-bows (`Tactics.leeBows`), she on port: the nearest one beating within `leeBowRange`,
    /// she to leeward of its track, that she can just cross were she to sail on (passing ahead of it, and clear of it as
    /// she keeps clear, so she isn't ducking it: `canJustCross`), and that her tack now would leave in her backwind and
    /// clear astern of her (`leeBowLands`), as she reads it (`timing`).
    func leeBowTarget(_ b: SeatView.OwnBoat, _ view: SeatView) -> Int? {
        guard b.tack == .port, isBeating(b) else { return nil }
        return nearest(view, within: view.boatClass.hull.length * FleetTactics.leeBowRange, of: b) { other, _ in
            canJustCross(b, view, other) && leeBowLands(b, view, other)
        }
    }

    /// Whether she, on port, to leeward of `other`'s track on starboard, can just cross it, as she reads it (`timing`):
    /// sailing on she would pass ahead of it, and clear of it as she keeps clear (`isAboutToHit`), so she isn't ducking
    /// it. The lee-bow's first gate (`leeBowTarget`); one she can't cross she ducks.
    ///
    /// A safety gate on skiff@5 (#349): its narrow backwind starts at her stern, so wherever her tack lands a boat in it
    /// she can also cross it (312 starts on seeds 3, 11 and 20, 0.5–6.5 L ahead and 0.5–4 L to leeward: 46 landings,
    /// none she couldn't cross). It refuses nothing there today; it stays so a lee-bow never becomes a tack under a boat
    /// she should duck.
    func canJustCross(_ b: SeatView.OwnBoat, _ view: SeatView, _ other: SeatView.OtherBoat) -> Bool {
        guard other.tack == .starboard else { return false }
        let forward = other.forward
        let leeward = -forward.rightPerp
        let relative = b.velocity - other.velocity
        let offset = b.position - other.position + relative * timing(other)
        let toLeeward = offset.dot(leeward)
        let closing = -relative.dot(leeward)
        guard toLeeward > 0, closing > 0.1 else { return false }
        // Sailing on she crosses its track ahead of it ...
        guard offset.dot(forward) + relative.dot(forward) * (toLeeward / closing) > 0 else { return false }
        // ... clear of it as she keeps clear (`isAboutToHit`).
        return Self.closestApproach(of: other, to: b, heading: b.heading, lookahead: keepClearLookahead)
            >= view.boatClass.hull.length * keepClearLengths
    }

    /// Whether her tack now would land her on `other`'s lee bow (`tackForecast`): the boat in her backwind and
    /// `leeBowAstern` lengths or more astern of her at every one of `tackOnWindSeconds`. The lee-bow's second gate.
    /// For a class whose backwind is the upwash beside her sail (#377), the boat in it and `leeBowAbeam` lengths or more
    /// to windward of her instead: that zone lies alongside her and on astern, so the lee-bow may be overlapped.
    func leeBowLands(_ b: SeatView.OwnBoat, _ view: SeatView, _ other: SeatView.OtherBoat) -> Bool {
        guard let forecast = tackForecast(b, view, on: other) else { return false }
        let length = view.boatClass.hull.length
        if view.boatClass.windShadow.upwashExtent != nil {
            return forecast.allSatisfy { $0.abeam >= length * FleetTactics.leeBowAbeam && $0.backwind }
        }
        return forecast.allSatisfy { $0.astern >= length * FleetTactics.leeBowAstern && $0.backwind }
    }

    /// The boat she tacks on the wind of (`Tactics.tacksOnWind`): the nearest one beating on the other tack within
    /// `tackOnWindRange`, upwind of it (to windward of its track, or up to `tackOnWindLeewardSlack` lengths to leeward
    /// of it, #349), that her tack now would leave in her wind shadow, clear astern of her (`tackForecast`), at a factor
    /// under `FleetTactics.tackOnWindShadow` on average, when that pays against her own plan (`paysToTackOnWind`).
    func tackOnWindTarget(_ b: SeatView.OwnBoat, _ view: SeatView, lean: Double, threshold: Double) -> Int? {
        guard isBeating(b) else { return nil }
        let length = view.boatClass.hull.length
        return nearest(view, within: length * FleetTactics.tackOnWindRange, of: b) { other, offset in
            // Upwind of her: to windward of her track, or no more than the slack to leeward of it (#349).
            let windward = other.tack == .starboard ? other.forward.rightPerp : -other.forward.rightPerp
            guard other.tack != b.tack, -offset.dot(windward) > -length * FleetTactics.tackOnWindLeewardSlack,
                  let forecast = tackForecast(b, view, on: other),
                  forecast.allSatisfy({ $0.astern >= length * FleetTactics.tackOnWindAstern }) else { return false }
            let factor = forecast.reduce(0) { $0 + $1.factor } / Double(forecast.count)
            return factor < FleetTactics.tackOnWindShadow
                && Self.paysToTackOnWind(windSpeed: b.polarWindSpeed, factor: factor, lean: lean, threshold: threshold)
        }
    }

    /// Whether a tack on a boat's wind that leaves her at `factor` pays (`FleetTactics.shadowCost`): the boat's loss in
    /// the shadow over `shadowHeld` seconds against the tack's cost in `windSpeed`, m/s, the wind she sails in
    /// (`tackCost`), scaled by her own plan's `lean` to the other tack (positive: headed on this one, or the puffs,
    /// pressure or clean air that way): the full cost with her plan neutral, none when it leans to the other tack by
    /// her threshold (it would tack her anyway), twice it when it leans to this tack by as much (lifted on this one).
    static func paysToTackOnWind(windSpeed: Double, factor: Double, lean: Double, threshold: Double) -> Bool {
        let gain = (1 - factor) * FleetTactics.shadowCost * FleetTactics.shadowHeld
        let plan = min(max(1 - lean / threshold, 0), 2)
        return gain >= tackCost(windSpeed: windSpeed) * plan
    }

    /// A tack's cost in lengths at `windSpeed`, m/s (`FleetTactics.tackCost`): between its points, and flat past them.
    static func tackCost(windSpeed: Double) -> Double {
        let points = FleetTactics.tackCost
        guard let first = points.first, let last = points.last else { return 0 }
        if windSpeed <= first.wind { return first.lengths }
        for (low, high) in zip(points, points.dropFirst()) where windSpeed <= high.wind {
            return low.lengths + (high.lengths - low.lengths) * (windSpeed - low.wind) / (high.wind - low.wind)
        }
        return last.lengths
    }

    /// Whether she is beating: close enough to the wind that a tack now lands her close-hauled on the other tack, as
    /// `tackForecast` reckons it. Not while she bears away to keep clear.
    func isBeating(_ b: SeatView.OwnBoat) -> Bool {
        abs(wrapAngle(b.windDirection - b.heading)) < FleetTactics.beating
    }

    /// Her own wind shadow and backwind now: `SeatView.shadowCones` is in seat order with the ghosts left out, so hers
    /// comes after every other boat's in a seat before hers that casts one.
    /// The cone found there must be hers (#329): its apex where she is and its forward along her heading, to within
    /// `FleetTactics.ownConeTolerance` (both are copied from her boat, so only float noise separates them); were a seat
    /// before hers to cast none without being a ghost in her view (`Race.isGhost(seat:)` once the race is over), the
    /// one there is another boat's, and she has none.
    func ownCone(_ b: SeatView.OwnBoat, _ view: SeatView) -> ShadowCone? {
        let index = view.others.reduce(0) { $0 + ($1.seat < view.seat && !$1.isGhost ? 1 : 0) }
        guard view.shadowCones.indices.contains(index) else { return nil }
        let cone = view.shadowCones[index]
        return Self.isCone(cone, castFrom: b.position, heading: b.heading) ? cone : nil
    }

    /// Whether `cone` is the one a boat at `position` on `heading` casts (`ownCone`), to within float noise
    /// (`FleetTactics.ownConeTolerance`).
    static func isCone(_ cone: ShadowCone, castFrom position: Vec2, heading: Double) -> Bool {
        let tolerance = FleetTactics.ownConeTolerance
        let forward = Vec2.heading(heading)
        return (cone.apex - position).length <= tolerance.metres && cone.forward.dot(forward) > 0
            && abs(cone.forward.cross(forward)) <= tolerance.radians
    }

    /// Where `other` would sit from her were she to tack now, as she reckons her tack (`tackCarry`, `tackPickUp`) and
    /// it sailing on, as she reads it (`timing`), at each of `tackOnWindSeconds`: metres astern of her along her new
    /// heading, metres to windward of her new heading's line (`abeam`), her shadow's factor on it, and whether that is her
    /// backwind. Nil without her backwind zone (`ownCone`).
    ///
    /// Her shadow is her ribbons (#377): the wake she has left on the water (`SeatView.wake`, her points drifting on) and
    /// the new one she lays from her new tack, building from nothing as her sail works again (`ribbonForecast`), the
    /// stronger of the two; times her backwind's loss there (none for a class with a header). Her backwind is her zone on
    /// her new side, there once her old one has faded out and her new one has started to build
    /// (`backwindLevelForecast`): as the race steps it.
    func tackForecast(_ b: SeatView.OwnBoat, _ view: SeatView, on other: SeatView.OtherBoat)
        -> [(astern: Double, abeam: Double, factor: Double, backwind: Bool)]? {
        guard let cone = ownCone(b, view) else { return nil }
        let w = b.windDirection
        let heading = 2 * w - b.heading
        // Her apparent wind now, mirrored about the true wind as her tack mirrors it.
        let apparent = 2 * w - cone.apparentWindDirection
        let forward = Vec2.heading(heading)
        // Her windward side on her new tack.
        let windward = b.tack.other == .starboard ? forward.rightPerp : -forward.rightPerp
        let carry = FleetTactics.tackCarry
        let read = timing(other)
        let shadow = view.boatClass.windShadow
        func her(at t: Double) -> Vec2 {
            var her = b.position + b.forward * (b.speed * carry.share * min(t, carry.seconds))
            for phase in FleetTactics.tackPickUp where t > phase.from {
                her += forward * (b.speed * phase.share * (min(t, phase.to) - phase.from))
            }
            return her
        }
        let apparentSpeed = max((b.sailingWind.velocity - b.velocity).length, 0.5)
        return FleetTactics.tackOnWindSeconds.map { t in
            let at = her(at: t)
            let them = other.position + other.velocity * (t + read)
            // Her tack keeps her true wind angle (mirrored); her speed is her reckoned one at `t`, not her speed now.
            var after = ShadowCone(apex: at, apparentWindDirection: apparent, heading: heading,
                                   windwardSide: b.tack.other, shadow: shadow, trueWindAngle: b.twa,
                                   speed: b.speed * FleetTactics.tackSpeedShare(at: t))
            if shadow.header != nil { after.backwindSail = Self.backwindLevelForecast(at: t, shadow: shadow) }
            let tick = TurbulenceRibbons.tick(after: t, from: view.tick)
            let old = view.wake.loss(of: view.seat, at: them, tick: tick)
            let new = TurbulenceRibbons.loss(along: Self.ribbonForecast(at: t, track: her(at:), drift: b.windOverGround.velocity,
                                                                        apparentSpeed: apparentSpeed, shadow: shadow), at: them)
            return ((at - them).dot(forward), (them - at).dot(windward), (1 - max(old, new)) * after.factor(at: them),
                    after.isInBackwind(them))
        }
    }

    /// Her new ribbon `t` seconds after her tap, as she reckons it (#377): a point every emission interval along her
    /// reckoned track (`track`), shed once her sail works again on her new heading (`tackPickUp`'s first phase), its
    /// level building from nothing over the class's `buildSeconds`, drifting with the wind `drift` and living as the
    /// race's do at her apparent wind now.
    static func ribbonForecast(at t: Double, track: (Double) -> Vec2, drift: Vec2, apparentSpeed: Double,
                               shadow: BoatClass.WindShadow) -> [TurbulenceRibbons.Live] {
        let p = shadow.ribbons
        let working = FleetTactics.tackPickUp.first?.from ?? 0
        let life = p.life(apparent: apparentSpeed, coneLength: shadow.coneLength)
        let s0 = p.startWidth / 2, s1 = p.endWidth / 2
        var run: [TurbulenceRibbons.Live] = []
        var tau = p.emitSeconds
        while tau <= t {
            let level = p.buildSeconds > 0 ? ((tau - working) / p.buildSeconds).clamped(to: 0...1) : (tau > working ? 1 : 0)
            let age = t - tau
            if level > 0, age < life {
                let point = TurbulenceRibbons.Point(position: track(tau), drift: drift, born: 0, peak: p.peak * level,
                                                    scale: s0 * level, growth: (s1 - s0) / life.squareRoot() * level, life: life)
                run.append(TurbulenceRibbons.Live(position: point.position + point.drift * age,
                                                  strength: point.peak * (1 - TurbulenceRibbons.smoothstep(age / life)),
                                                  scale: point.scale + point.growth * age.squareRoot()))
            }
            tau += p.emitSeconds
        }
        return run
    }

    /// Her backwind's level on her new side `t` seconds after her tap, as she reckons it (#377, a class with a header):
    /// her old side's zone fades out over the class's `backwindFadeSeconds` from her boom crossing (`tackPickUp`'s first
    /// phase), then her new one builds over the ribbons' `buildSeconds` (`BackwindSails`).
    static func backwindLevelForecast(at t: Double, shadow: BoatClass.WindShadow) -> Double {
        let crossing = FleetTactics.tackPickUp.first?.from ?? 0
        let start = crossing + shadow.backwindFadeSeconds
        let build = shadow.ribbons.buildSeconds
        guard build > 0 else { return t > start ? 1 : 0 }
        return ((t - start) / build).clamped(to: 0...1)
    }

    /// Seconds early (positive) or late she reads `other` (`FleetTactics.timingError`): none at full tactical quality.
    func timing(_ other: SeatView.OtherBoat) -> Double {
        (1 - tactics.tacticalQuality) * FleetTactics.timingError * (fleet.bySeat[other.seat]?.timing ?? 0)
    }

    /// The nearest boat to her within `range` metres, beating and no ghost, that `matches` (with its offset from her):
    /// its seat, the first in seat order of two as near.
    func nearest(_ view: SeatView, within range: Double, of b: SeatView.OwnBoat,
                 matching matches: (SeatView.OtherBoat, Vec2) -> Bool) -> Int? {
        var best: (seat: Int, distance: Double)?
        for other in view.others where !other.isGhost {
            let offset = other.position - b.position
            let distance = offset.length
            guard distance < range, distance < best?.distance ?? .infinity,
                  abs(wrapAngle(b.windDirection - other.heading)) < FleetTactics.beating, matches(other, offset) else { continue }
            best = (other.seat, distance)
        }
        return best?.seat
    }
}
