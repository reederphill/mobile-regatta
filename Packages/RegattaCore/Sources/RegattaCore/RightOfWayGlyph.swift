/// The right-of-way cue a player sees on another boat (#15, #123): a red glow on a boat she must keep clear of,
/// a green glow on a boat that must keep clear of her (the app draws the glow; the name predates it, when these
/// were a ⚠ and a chevron). No words.
/// Mark-room has no words of its own (#386): within the glow range a boat owing it glows red and the boat owed it
/// green, as a keep-clear boat and a right-of-way boat do (`Race.keepClearRelation(of:to:)` decides, and online the
/// server's relations carry it). Display only: the umpire's calls are unchanged (Case 25).
/// A boat taking a penalty (rule 21.2) shows every other boat a plain orange ring in place of the green glow (#517);
/// her own view keeps every boat red, and a boat returning to start (21.1) keeps green.
public enum RightOfWayGlyph: Sendable, Equatable {
    /// I must keep clear of her: the red glow.
    case giveWay
    /// She must keep clear of me: the green glow.
    case hasRight
    /// She is taking a penalty (21.2): the orange ring, no halo.
    case takingAPenalty

    /// How far away, in hull lengths centre to centre, a boat's glow starts to show: a placeholder the app's
    /// `BoatStyle.glowRangeHulls` slider defaults to. The server sends relations a little further out
    /// (`WireRelation.rangeHulls`, #96).
    public static let defaultRangeHulls = 6.0

    /// The glyph `me` sees on the other boat of `relation`, or nil when there is none (a ghost in the pair).
    public static func glyph(for relation: RightOfWay?, me: Int) -> RightOfWayGlyph? {
        guard let relation else { return nil }
        if relation.keepClear == me { return .giveWay }
        return relation.rule == .takingAPenalty ? .takingAPenalty : .hasRight
    }

    /// Whether a boat at `other` is close enough to `me` for its glyph to show: centres at most
    /// `rangeHulls` × `hullLength` apart.
    public static func isInRange(_ me: Vec2, _ other: Vec2, rangeHulls: Double, hullLength: Double) -> Bool {
        (other - me).length <= rangeHulls * hullLength
    }
}
