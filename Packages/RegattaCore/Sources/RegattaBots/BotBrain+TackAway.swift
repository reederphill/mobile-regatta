import RegattaCore

extension BotBrain {
    /// "Tacks away from a squeeze" (#342): racing, the windward boat keeping clear under rule 11, in this order.
    /// 1. She luffs (`racingKeepClear`), when the heading it finds passes every boat near her `keepClearLengths` times
    ///    `keepClearMargin` hull lengths off over `lookahead` (`luffClears`).
    /// 2. Otherwise, beating, she tacks away, when she can tap now (`canTap`: `tapIsClear` holds her to rules 13 and 15,
    ///    and rule 10 once she is on the new tack). A tack costs her about a hull length (`CONTEXT.md` **Tack cost**), so
    ///    she tacks only when her own tack has no clear way out, never as a tactic.
    /// 3. Otherwise she eases and drops astern on the heading that passes furthest off: the last resort.
    /// A squeeze she misjudges (#103) she never reaches here: she sails on, leaving out her give-way manoeuvre, the tack
    /// with it.
    func windwardEvasion(_ b: SeatView.OwnBoat, _ view: SeatView, from other: SeatView.OtherBoat, desired: Double,
                         lookahead: Double) -> Evasion {
        let luff = racingKeepClear(b, view, from: other, rule: .windwardLeeward, desired: desired, lookahead: lookahead)
        if luffClears(b, view, heading: luff, lookahead: lookahead) { return Evasion(heading: luff) }
        if isBeating(b), canTap(b, view) { return Evasion(heading: b.heading, tacks: true) }
        return Evasion(heading: luff, dropsAstern: true)
    }

    /// Whether sailing `heading` at her speed passes every boat within `keepClearRange` of her at least
    /// `keepClearLengths` times `keepClearMargin` hull lengths off over `lookahead` seconds (`closestApproach`): what
    /// `clearingHeading` looks for on her own tack.
    func luffClears(_ b: SeatView.OwnBoat, _ view: SeatView, heading: Double, lookahead: Double) -> Bool {
        let clear = view.boatClass.hull.length * keepClearLengths * Self.keepClearMargin
        for other in view.others where !other.isGhost && (other.position - b.position).length < Self.keepClearRange {
            if Self.closestApproach(of: other, to: b, heading: heading, lookahead: lookahead) < clear { return false }
        }
        return true
    }
}
