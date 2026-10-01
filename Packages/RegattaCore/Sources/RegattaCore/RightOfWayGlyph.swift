/// The right-of-way cue a player sees on another boat (#15, #123): a red glow on a boat she must keep clear of,
/// a green glow on a boat that must keep clear of her (the app draws the glow; the name predates it, when these
/// were a ⚠ and a chevron). No words.
/// Mark-room is never a glow (it is a notice): only who keeps clear (`Race.keepClearRelations(of:)`) decides.
public enum RightOfWayGlyph: Sendable, Equatable {
    /// I must keep clear of her: the red glow.
    case giveWay
    /// She must keep clear of me: the green glow.
    case hasRight

    /// How far away, in hull lengths centre to centre, a boat's glow starts to show: a placeholder the app's
    /// `BoatStyle.glowRangeHulls` slider defaults to, and the server's in-range pairs can reuse (#96).
    public static let defaultRangeHulls = 6.0

    /// The glyph `me` sees on the other boat of `relation`, or nil when there is none (a ghost in the pair).
    public static func glyph(for relation: RightOfWay?, me: Int) -> RightOfWayGlyph? {
        guard let relation else { return nil }
        return relation.keepClear == me ? .giveWay : .hasRight
    }

    /// Whether a boat at `other` is close enough to `me` for its glyph to show: centres at most
    /// `rangeHulls` × `hullLength` apart.
    public static func isInRange(_ me: Vec2, _ other: Vec2, rangeHulls: Double, hullLength: Double) -> Bool {
        (other - me).length <= rangeHulls * hullLength
    }
}
