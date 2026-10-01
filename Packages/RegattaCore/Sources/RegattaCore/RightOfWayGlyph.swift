/// The right-of-way glyph a player sees on another boat (#15, #123): an orange ⚠ on a boat she must keep
/// clear of, a blue chevron on a boat that must keep clear of her. No words: shape and colour carry it.
/// Mark-room is never a glyph (it is a notice): only who keeps clear (`Race.keepClearRelations(of:)`) decides.
public enum RightOfWayGlyph: Sendable, Equatable {
    /// I must keep clear of her: the ⚠ triangle.
    case giveWay
    /// She must keep clear of me: the chevron.
    case hasRight

    /// How far away, in hull lengths centre to centre, a boat's glyph shows: a placeholder the app's
    /// `BoatStyle.glyphRangeHulls` slider defaults to, and the server's in-range pairs can reuse (#96).
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
