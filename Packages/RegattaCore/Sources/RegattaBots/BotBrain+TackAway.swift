import RegattaCore

extension BotBrain {
    /// "Tacks away from a squeeze" (#342): racing, the windward boat keeping clear under rule 11, in this order.
    /// 1. She luffs (`racingKeepClear`'s heading), unless, beating, even that still takes her inside her keep-clear
    ///    distance of the leeward boat over `lookahead` (`hasNoEscape`): no way clear on her own tack. Off the wind she
    ///    only ever luffs: a gybe is no tack away.
    /// 2. Otherwise she tacks away, when the tack is a clean one (`tacksAwayClear`). A tack costs her about a hull length
    ///    (`CONTEXT.md` **Tack cost**), so she tacks only when her own tack has no way clear, never as a tactic.
    /// 3. Otherwise she steers that heading, the one that passes furthest off, as before: the last resort. She doesn't
    ///    ease to drop astern as well (#342 fix round 1): in a fleet, easing in a squeeze hands it to the boats behind
    ///    her, and the bot matrix called more fouls (rules 10, 13 and 11) with it than without.
    /// A squeeze she misjudges (#103) she never reaches here: she sails on, leaving out her give-way manoeuvre, the tack
    /// with it.
    func windwardEvasion(_ b: SeatView.OwnBoat, _ view: SeatView, from other: SeatView.OtherBoat, desired: Double,
                         lookahead: Double) -> Evasion {
        let luff = racingKeepClear(b, view, from: other, rule: .windwardLeeward, desired: desired, lookahead: lookahead)
        guard isBeating(b), hasNoEscape(b, view, from: other, heading: luff, lookahead: lookahead),
              tacksAwayClear(b, view, from: other) else { return Evasion(heading: luff) }
        return Evasion(heading: b.heading, tacks: true)
    }

    /// Whether sailing `heading` at her speed still takes her inside `keepClearLengths` hull lengths of `other` over
    /// `lookahead` seconds (`closestApproach`), as her desired heading did (`isAboutToHit`): no way clear of her on her
    /// own tack.
    func hasNoEscape(_ b: SeatView.OwnBoat, _ view: SeatView, from other: SeatView.OtherBoat, heading: Double,
                     lookahead: Double) -> Bool {
        Self.closestApproach(of: other, to: b, heading: heading, lookahead: lookahead)
            < view.boatClass.hull.length * keepClearLengths
    }

    /// Whether a tack away from `squeezer` now is a clean one: one she could tap now (`canTap`: the tap interval, marks,
    /// speed and `tapIsClear`, rules 13, 15 and 10), and more.
    /// - Not the cautious bot (#104): she always gives way the surest way, and her own tack is surer than a tack.
    /// - Out in the leg where her course keeps her on the new tack (`tackAwayOpen`, noted by `navigate`): not inside
    ///   `tacticalRange` of her mark, nor onto a board past its layline or the corridor, which would only tack her
    ///   straight back, slow, among the boats there.
    /// - At `tackingSpeed` of her close-hauled speed in clear air, not of her shadowed speed: a slow tack stays under
    ///   rule 13 the longer.
    /// - Every other boat near her passes `keepClearMargin` beyond her tap clearance on the new tack, alongside or not:
    ///   only the squeezer, whose gap the tack opens, keeps #263's allowance (`tapIsClear`).
    func tacksAwayClear(_ b: SeatView.OwnBoat, _ view: SeatView, from squeezer: SeatView.OtherBoat) -> Bool {
        guard caution == nil, tackAwayOpen, canTap(b, view) else { return false }
        let closeHauled = view.boatClass.polar.bestUpwind(tws: b.polarWindSpeed).speed
        guard b.speed >= closeHauled * Self.tackingSpeed else { return false }
        let heading = 2 * b.windDirection - b.heading
        let speed = b.speed * Self.tapSpeedShare
        let clear = view.boatClass.hull.length * tapClearanceLengths * Self.keepClearMargin
        let ontoPort = b.tack == .starboard
        return view.others.allSatisfy { other in
            guard !other.isGhost, other.seat != squeezer.seat,
                  (other.position - b.position).length <= Self.tapRange else { return true }
            let lookahead = (ontoPort && other.tack == .starboard ? Self.tapOntoPortLookahead : Self.tapLookahead)
                * tapLookaheadScale
            return Self.closestApproach(of: other, to: b, heading: heading, speed: speed, lookahead: lookahead) >= clear
        }
    }
}
