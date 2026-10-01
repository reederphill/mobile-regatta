import RegattaCore

// A bot's fleet tactics (#234, #223): how she plays the boats around her up a beat, as a handful of named heuristics,
// the way real sailors do (#276: "predictable heuristics like real life"). Internal: nothing here is ever shown to a
// player, as a notice or anything else, and nothing here is a decision field.
//
// - Hold her lane: in clear air with a boat in her backwind or close to windward on her tack, she holds on rather than
//   tack away, on all but a big header. Her tactical choice; defending a lane as the right-of-way boat under the
//   rules is #101's (`holdingCourse`).
// - Cover: she tacks with the nearest boat behind her that has tacked away, to stay between it and the mark.
// - Lee-bow: on port, meeting a starboard boat she can just cross, she tacks onto her lee bow, putting her in her
//   backwind; one she can't cross she ducks, as she keeps clear (`racingKeepClear`), no code here.
// - Tack on her wind: ahead of a boat on the other tack, she tacks to put her in her wind shadow.
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
        /// bow): she tacks between these lengths to leeward of the starboard boat's track, when she can just cross
        /// her: sailing on, she would pass clear of her (`BotBrain.keepClearDistance` or more, so she isn't ducking
        /// her), crossing her track no more than `leeBowCrossing` lengths ahead of her.
        static let leeBowLeeward = (min: 0.6, max: 1.2)
        static let leeBowCrossing = 3.0
        /// She tacks on a boat's wind within this many lengths of her ...
        static let tackOnWindRange = 8.0
        /// ... when, her tack done, the boat sits in her wind shadow these seconds on, at a factor under
        /// `tackOnWindShadow` on average: a loss of about half a length or more over 5 s (#263's shadow cost) ...
        static let tackOnWindSeconds: [Double] = [4, 5, 6]
        static let tackOnWindShadow = 0.75
        /// ... and clear astern of her on her new tack by this many lengths or more, so she is clear ahead.
        static let tackOnWindAstern = 1.0
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
    /// her lane, or a cover, a lee-bow or a tack on a boat's wind, in that order. A tack only when she can tap it now
    /// (`canTap`), onto a board she hasn't `overstood`, and not onto a header worse than her threshold (`headed`, on her
    /// tack, positive headed).
    func fleetPlay(_ b: SeatView.OwnBoat, _ view: SeatView, planned tack: Tack, headed: Double, threshold: Double,
                   overstood: (Tack) -> Bool) -> FleetPlay? {
        guard playsTheFleet, b.status == .racing, tack == b.tack, !senses.tacking else { return nil }
        if tactics.holdsLane, let seat = laneNeighbour(b, view) { return FleetPlay(seat: seat, play: .holdLane) }
        guard headed > -threshold, !overstood(tack.other) else { return nil }
        let play = (tactics.coversTackers ? coverTackTarget(b, view).map { FleetPlay(seat: $0, play: .cover) } : nil)
            ?? (tactics.leeBows ? leeBowTarget(b, view).map { FleetPlay(seat: $0, play: .leeBow) } : nil)
            ?? (tactics.tacksOnWind ? tackOnWindTarget(b, view).map { FleetPlay(seat: $0, play: .tackOnWind) } : nil)
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

    /// The starboard boat she lee-bows (`Tactics.leeBows`), she on port: the nearest one beating whose track she is
    /// sailing across from leeward, between `leeBowLeeward` lengths to leeward of it, that she can just cross were she
    /// to sail on, as she reads it (`timing`): passing clear of it, crossing its track within `leeBowCrossing` lengths
    /// ahead of it.
    func leeBowTarget(_ b: SeatView.OwnBoat, _ view: SeatView) -> Int? {
        guard b.tack == .port else { return nil }
        let length = view.boatClass.hull.length
        return nearest(view, within: length * 6, of: b) { other, _ in
            guard other.tack == .starboard else { return false }
            let forward = other.forward
            let leeward = -forward.rightPerp
            let relative = b.velocity - other.velocity
            let offset = b.position - other.position + relative * timing(other)
            let toLeeward = offset.dot(leeward)
            let closing = -relative.dot(leeward)
            guard closing > 0.1, toLeeward >= length * FleetTactics.leeBowLeeward.min,
                  toLeeward <= length * FleetTactics.leeBowLeeward.max else { return false }
            let crossing = offset.dot(forward) + relative.dot(forward) * (toLeeward / closing)
            guard crossing > 0, crossing <= length * FleetTactics.leeBowCrossing else { return false }
            // Clear of her sailing on, as she keeps clear (`isAboutToHit`), centre to centre: she can cross.
            return abs(offset.cross(relative.normalized)) >= length * Self.keepClearDistance
        }
    }

    /// The boat she tacks on the wind of (`Tactics.tacksOnWind`): the nearest one beating on the other tack within
    /// `tackOnWindRange`, whose bow she has crossed (she is to windward of it), that her tack now would leave in her wind shadow (`tackOnWindShadow(_:_:on:)`) at a factor under
    /// `FleetTactics.tackOnWindShadow` on average.
    func tackOnWindTarget(_ b: SeatView.OwnBoat, _ view: SeatView) -> Int? {
        let length = view.boatClass.hull.length
        return nearest(view, within: length * FleetTactics.tackOnWindRange, of: b) { other, offset in
            // She has crossed her: to windward of her.
            let windward = other.tack == .starboard ? other.forward.rightPerp : -other.forward.rightPerp
            guard other.tack != b.tack, -offset.dot(windward) > 0,
                  let factor = tackOnWindShadow(b, view, on: other) else { return false }
            return factor < FleetTactics.tackOnWindShadow
        }
    }

    /// The wind her shadow would leave `other` were she to tack now, as she reckons her tack (`tackCarry`,
    /// `tackPickUp`) and it sailing on: its factor at `tackOnWindSeconds` on average, as she reads `other`
    /// (`timing`); nil unless it is clear astern of her by `tackOnWindAstern` or more at every one of them.
    func tackOnWindShadow(_ b: SeatView.OwnBoat, _ view: SeatView, on other: SeatView.OtherBoat) -> Double? {
        guard let cone = view.shadowCones.first(where: { $0.apex == b.position }) else { return nil }
        let length = view.boatClass.hull.length
        let w = b.windDirection
        let heading = 2 * w - b.heading
        let apparent = 2 * w - (-cone.axis).bearing
        let forward = Vec2.heading(heading)
        let carry = FleetTactics.tackCarry
        let read = timing(other)
        var factor = 0.0
        for t in FleetTactics.tackOnWindSeconds {
            var her = b.position + b.forward * (b.speed * carry.share * min(t, carry.seconds))
            for phase in FleetTactics.tackPickUp where t > phase.from {
                her += forward * (b.speed * phase.share * (min(t, phase.to) - phase.from))
            }
            let them = other.position + other.velocity * (t + read)
            guard (her - them).dot(forward) >= length * FleetTactics.tackOnWindAstern else { return nil }
            let after = ShadowCone(apex: her, apparentWindDirection: apparent, heading: heading,
                                   windwardSide: b.tack.other, shadow: view.boatClass.windShadow)
            factor += after.factor(at: them)
        }
        return factor / Double(FleetTactics.tackOnWindSeconds.count)
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
