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
// - Tack on her wind: ahead of a boat on the other tack, she tacks to put her in her wind shadow, when that pays
//   against her own plan (the tack's cost, the shift, puffs and pressure).
//
// Targets are chosen from her `SeatView` alone (#98), by where the boats are and how they sail: never by who sails
// them (`BotSourceTests` keeps the seat kinds out of every brain file). How willing she is to play them is her style's
// engagement (`Tactics.engagement`); how well, her skill's: she sees a boat tack only after her reaction delay
// (`BotWeaknesses.reactionDelay`), and reads a lee-bow or a tack on a boat's wind up to `FleetTactics.timingError`
// seconds early or late the less tactical quality she has (`BotWeaknesses.tacticalQuality`), a draw of her own per boat
// (`BotBrain.tacticsRng`). Every tack is still her tap (`canTap`): only clear of every boat (`tapIsClear`, rules 13
// and 15), never within `tackInterval` of her last, never inside `tacticalRange` of her mark or past the corridor or
// a layline. She never forces a foul, and never protests (#19).

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
        /// A lee-bow (`LeeBowTests`: a tack 3 L ahead and 1.5 L to leeward of a starboard boat lands her on her lee
        /// bow, the starboard boat 1 to 2.5 L astern of her in her backwind): on port, to leeward of a starboard boat
        /// within `leeBowRange` she can just cross (sailing on she would pass ahead of her and clear, as she keeps clear,
        /// `BotBrain.keepClearDistance`), she tacks when her tack now, as she reckons it (`tackCarry`, `tackPickUp`),
        /// would leave the starboard boat in her backwind and `leeBowAstern` lengths or more astern of her at every one
        /// of `tackOnWindSeconds`. The geometry is her reckoning's, not a fixed window.
        static let leeBowRange = 8.0
        static let leeBowAstern = 0.75
        /// She tacks on a boat's wind within this many lengths of her ...
        static let tackOnWindRange = 8.0
        /// ... when, her tack done, the boat sits in her wind shadow these seconds on, at a factor under
        /// `tackOnWindShadow` on average ...
        static let tackOnWindSeconds: [Double] = [4, 5, 6]
        static let tackOnWindShadow = 0.75
        /// ... clear astern of her on her new tack by this many lengths or more, so she is clear ahead ...
        static let tackOnWindAstern = 1.0
        /// ... and the tack pays against her own plan (`paysToTackOnWind`): the boat's loss, `shadowCost` lengths a
        /// second per unit of shadow (#263: 1.22-1.47 L per 5 s at the cone's 0.48 close in) for the `shadowHeld`
        /// seconds she holds her there (until the boat sees it and is out of it: a reaction, up to 8 s at Club, and a
        /// tack away), beats her tack's cost (`tackCost`: lengths, by the wind she sails in, m/s; #263's 0.74 / 1.10 /
        /// 1.27 L at 6 / 10 / 14 kn on skiff@4): more on a lift or with the puffs or pressure this side, less on a
        /// header or in dirty air (her plan's lean to the other tack, as a share of her threshold).
        static let shadowCost = 0.56
        static let shadowHeld = 10.0
        static let tackCost: [(wind: Double, lengths: Double)] = [(3.09, 0.74), (5.14, 1.10), (7.20, 1.27)]
        /// How she reckons her tack, measured in the scripted scenes (`BotTacticsTests`, skiff@4 rolling her tack at
        /// 10 kn: through it in about 2.5 s, back to speed about 6 s after her tap): sailing on her heading now at this
        /// share of her speed now for so many seconds ...
        static let tackCarry = (seconds: 2.0, share: 0.58)
        /// ... and on her new heading, at these shares of her speed now between these seconds after her tap; at her
        /// speed now after the last.
        static let tackPickUp: [(from: Double, to: Double, share: Double)] = [(0.75, 3.5, 0.55), (3.5, 6, 0.75), (6, .infinity, 1)]
        /// Seconds early or late she reads a lee-bow or a tack on a boat's wind, at no tactical quality; none at full.
        static let timingError = 2.0
        /// A boat further off the wind than this, radians, isn't beating: no fleet tactic plays her.
        static let beating = Double.pi / 3
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
    func fleetPlay(_ b: SeatView.OwnBoat, _ view: SeatView, planned tack: Tack, headed: Double, lean: Double,
                   threshold: Double, overstood: (Tack) -> Bool) -> FleetPlay? {
        guard playsTheFleet, b.status == .racing, tack == b.tack, !senses.tacking else { return nil }
        if tactics.holdsLane, let seat = laneNeighbour(b, view) { return FleetPlay(seat: seat, play: .holdLane) }
        guard headed > -threshold, !overstood(tack.other) else { return nil }
        // The lee-bow before the cover: a crossing passes in a second or two, a cover's chance lasts `coverLate`.
        let play = (tactics.leeBows ? leeBowTarget(b, view).map { FleetPlay(seat: $0, play: .leeBow) } : nil)
            ?? (tactics.coversTackers ? coverTackTarget(b, view).map { FleetPlay(seat: $0, play: .cover) } : nil)
            ?? (tactics.tacksOnWind
                ? tackOnWindTarget(b, view, lean: lean, threshold: threshold).map { FleetPlay(seat: $0, play: .tackOnWind) }
                : nil)
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
    /// she keeps clear, so she isn't ducking it), and that her tack now would leave in her backwind and clear astern of
    /// her (`tackForecast`), as she reads it (`timing`).
    func leeBowTarget(_ b: SeatView.OwnBoat, _ view: SeatView) -> Int? {
        guard b.tack == .port, isBeating(b) else { return nil }
        let length = view.boatClass.hull.length
        return nearest(view, within: length * FleetTactics.leeBowRange, of: b) { other, _ in
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
            // ... clear of it as she keeps clear (`isAboutToHit`): she can cross, and won't duck it.
            guard Self.closestApproach(of: other, to: b, heading: b.heading, lookahead: keepClearLookahead)
                    >= length * Self.keepClearDistance,
                  let forecast = tackForecast(b, view, on: other) else { return false }
            return forecast.allSatisfy { $0.astern >= length * FleetTactics.leeBowAstern && $0.backwind }
        }
    }

    /// The boat she tacks on the wind of (`Tactics.tacksOnWind`): the nearest one beating on the other tack within
    /// `tackOnWindRange`, whose bow she has crossed (she is to windward of it), that her tack now would leave in her wind
    /// shadow, clear astern of her (`tackForecast`), at a factor under `FleetTactics.tackOnWindShadow` on average, when
    /// that pays against her own plan (`paysToTackOnWind`).
    func tackOnWindTarget(_ b: SeatView.OwnBoat, _ view: SeatView, lean: Double, threshold: Double) -> Int? {
        guard isBeating(b) else { return nil }
        let length = view.boatClass.hull.length
        return nearest(view, within: length * FleetTactics.tackOnWindRange, of: b) { other, offset in
            // She has crossed her: to windward of her.
            let windward = other.tack == .starboard ? other.forward.rightPerp : -other.forward.rightPerp
            guard other.tack != b.tack, -offset.dot(windward) > 0, let forecast = tackForecast(b, view, on: other),
                  forecast.allSatisfy({ $0.astern >= length * FleetTactics.tackOnWindAstern }) else { return false }
            let factor = forecast.reduce(0) { $0 + $1.factor } / Double(forecast.count)
            return factor < FleetTactics.tackOnWindShadow
                && paysToTackOnWind(b, factor: factor, lean: lean, threshold: threshold)
        }
    }

    /// Whether a tack on a boat's wind that leaves her at `factor` pays (`FleetTactics.shadowCost`): her loss in the
    /// shadow over `shadowHeld` seconds against the tack's cost in the wind she sails in (`tackCost`), scaled by her
    /// own plan's `lean` to the other tack: none at her threshold, twice it lifted by as much.
    func paysToTackOnWind(_ b: SeatView.OwnBoat, factor: Double, lean: Double, threshold: Double) -> Bool {
        let gain = (1 - factor) * FleetTactics.shadowCost * FleetTactics.shadowHeld
        let plan = min(max(1 - lean / threshold, 0), 2)
        return gain >= Self.tackCost(windSpeed: b.polarWindSpeed) * plan
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
    func ownCone(_ view: SeatView) -> ShadowCone? {
        let index = view.others.reduce(0) { $0 + ($1.seat < view.seat && !$1.isGhost ? 1 : 0) }
        return view.shadowCones.indices.contains(index) ? view.shadowCones[index] : nil
    }

    /// Where `other` would sit from her were she to tack now, as she reckons her tack (`tackCarry`, `tackPickUp`) and
    /// it sailing on, as she reads it (`timing`), at each of `tackOnWindSeconds`: metres astern of her along her new
    /// heading, her shadow's factor on it (wind shadow or backwind), and whether that is her backwind. Nil without her
    /// shadow (`ownCone`).
    func tackForecast(_ b: SeatView.OwnBoat, _ view: SeatView, on other: SeatView.OtherBoat)
        -> [(astern: Double, factor: Double, backwind: Bool)]? {
        guard let cone = ownCone(view) else { return nil }
        let w = b.windDirection
        let heading = 2 * w - b.heading
        let apparent = 2 * w - (-cone.axis).bearing
        let forward = Vec2.heading(heading)
        let carry = FleetTactics.tackCarry
        let read = timing(other)
        return FleetTactics.tackOnWindSeconds.map { t in
            var her = b.position + b.forward * (b.speed * carry.share * min(t, carry.seconds))
            for phase in FleetTactics.tackPickUp where t > phase.from {
                her += forward * (b.speed * phase.share * (min(t, phase.to) - phase.from))
            }
            let them = other.position + other.velocity * (t + read)
            let after = ShadowCone(apex: her, apparentWindDirection: apparent, heading: heading,
                                   windwardSide: b.tack.other, shadow: view.boatClass.windShadow)
            return ((her - them).dot(forward), after.factor(at: them), after.isInBackwind(them))
        }
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
