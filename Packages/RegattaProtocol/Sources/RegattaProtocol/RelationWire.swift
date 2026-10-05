import RegattaCore

/// The server umpire's word on one pair, as a snapshot carries it to one of the pair's clients (#96, ADR 0005):
/// who keeps clear between the recipient and that seat, and under which rule (`Race.keepClearRelations(of:)`:
/// rule 21 over rules 10–13, or the boat owing mark-room under 18.2/18.3, #386), and whether the recipient is held
/// to her proper course against that seat (rule 17, `Race.properCourseRestrictions(of:)`). The client never works
/// these out from its own world: the umpire's records (rule 18, rule 17, incident memory) stay on the server (#18),
/// so its right-of-way glows are the server's.
///
/// Six bits a seat, least significant first: bit 0 a keep-clear relation is present; bit 1 who keeps clear (0 the
/// recipient, 1 the other seat); bits 2–4 the rule, an index into `wireRules`; bit 5 the recipient is restricted by
/// rule 17 against the seat. Bits 1–4 are 0 with no relation. The recipient's own entry is always 0.
public struct WireRelation: Hashable, Sendable {
    /// Who keeps clear between the recipient and the seat, and under which rule.
    public struct KeepClear: Hashable, Sendable {
        /// The recipient keeps clear (the red glow); otherwise the seat does (green).
        public var recipientKeepsClear: Bool
        public var rule: RacingRule

        public init(recipientKeepsClear: Bool, rule: RacingRule) {
            self.recipientKeepsClear = recipientKeepsClear
            self.rule = rule
        }
    }

    /// Who keeps clear, or nil for no relation (out of range, a ghost in the pair).
    public var keepClear: KeepClear?
    /// The recipient is held to her proper course against the seat (rule 17, #345).
    public var isRestricted: Bool

    /// No relation.
    public static let none = WireRelation(keepClear: nil, isRestricted: false)

    public init(keepClear: KeepClear?, isRestricted: Bool) {
        self.keepClear = keepClear
        self.isRestricted = isRestricted
    }

    /// The rules a keep-clear relation can carry (`Rules.obligation`), by their wire index. Fixed for good: never
    /// reorder, and a new rule takes the next free index. 18.2 and 18.3 are the mark-room relations (#386).
    public static let wireRules: [RacingRule] = [
        .portStarboard, .windwardLeeward, .clearAstern, .whileTacking, .returningToStart, .takingAPenalty,
        .givingMarkRoom, .tackingInTheZone,
    ]

    /// How far apart, in hull lengths centre to centre, a pair's relation is sent: the app's glow range
    /// (`RightOfWayGlyph.defaultRangeHulls`, 6) with slack, so a pair crossing the app's edge between a server
    /// tick and the client's doesn't pop. The app still fades by its own range.
    public static let rangeHulls = 8.0

    /// Bytes the relations of a fleet of `seats` take on the wire.
    public static func byteCount(seats: Int) -> Int { (6 * seats + 7) / 8 }

    /// Its six bits. Throws `WireError.outOfRange` for a rule `wireRules` doesn't hold.
    func bits() throws -> UInt8 {
        var bits: UInt8 = isRestricted ? 1 << 5 : 0
        if let keepClear {
            guard let rule = Self.wireRules.firstIndex(of: keepClear.rule) else { throw WireError.outOfRange("relation.rule") }
            bits |= 1 | (keepClear.recipientKeepsClear ? 0 : 1 << 1) | UInt8(rule) << 2
        }
        return bits
    }

    /// From its six bits; throws for bits no relation encodes to.
    init(bits: UInt8) throws {
        guard bits < 1 << 6 else { throw WireError.invalidValue("relation") }
        isRestricted = bits & 1 << 5 != 0
        if bits & 1 != 0 {
            let rule = Int(bits >> 2 & 0b111)
            guard Self.wireRules.indices.contains(rule) else { throw WireError.invalidValue("relation.rule") }
            keepClear = KeepClear(recipientKeepsClear: bits & 1 << 1 == 0, rule: Self.wireRules[rule])
        } else {
            guard bits & 0b11110 == 0 else { throw WireError.invalidValue("relation") }
            keepClear = nil
        }
    }

    /// `seat`'s relations to the fleet in the authoritative `race`, by seat, as its snapshot carries them: from the
    /// umpire (`keepClearRelation(of:to:)`, `isHeldToProperCourse(_:against:)`), for the seats within `rangeHulls`
    /// of her; none at her own seat, out of range, or with a ghost (`keepClearRelation` has none). The range comes
    /// first, so a pair out of range costs the server nothing more.
    public static func relations(of seat: Int, in race: Race) -> [WireRelation] {
        let hull = race.boatClass.hull.length
        let me = race.boats[seat].position
        return race.boats.indices.map { other in
            guard other != seat,
                  RightOfWayGlyph.isInRange(me, race.boats[other].position, rangeHulls: rangeHulls, hullLength: hull)
            else { return .none }
            let keepClear = race.keepClearRelation(of: seat, to: other)
            return WireRelation(keepClear: keepClear.map { KeepClear(recipientKeepsClear: $0.keepClear == seat, rule: $0.rule) },
                                isRestricted: race.isHeldToProperCourse(seat, against: other))
        }
    }

    /// The relations `relations` stand for, for the recipient `seat`, as a prediction holds them
    /// (`Race.UmpireRelations`).
    public static func umpireRelations(_ relations: [WireRelation], seat: Int) -> Race.UmpireRelations {
        Race.UmpireRelations(
            seat: seat,
            keepClear: relations.indices.map { other in
                relations[other].keepClear.map { RightOfWay(keepClear: $0.recipientKeepsClear ? seat : other, rule: $0.rule) }
            },
            restrictedBy: relations.indices.filter { relations[$0].isRestricted })
    }
}

func encodeRelations(_ relations: [WireRelation], to w: inout WireWriter) throws {
    var bytes = [UInt8](repeating: 0, count: WireRelation.byteCount(seats: relations.count))
    for (k, relation) in relations.enumerated() {
        let bits = UInt16(try relation.bits()) << (6 * k % 8)
        bytes[6 * k / 8] |= UInt8(truncatingIfNeeded: bits)
        if bits > 0xFF { bytes[6 * k / 8 + 1] |= UInt8(bits >> 8) }
    }
    w.raw(bytes)
}

func decodeRelations(seats: Int, from r: inout WireReader) throws -> [WireRelation] {
    let bytes = try r.raw(WireRelation.byteCount(seats: seats))
    let relations = try (0..<seats).map { k in
        let low = UInt16(bytes[6 * k / 8]), high = 6 * k / 8 + 1 < bytes.count ? UInt16(bytes[6 * k / 8 + 1]) : 0
        return try WireRelation(bits: UInt8((low | high << 8) >> (6 * k % 8) & 0b11_1111))
    }
    // The padding bits after the last seat are 0, so each fleet's relations have one encoding.
    let used = 6 * seats % 8
    if used != 0, let last = bytes.last, last >> used != 0 { throw WireError.invalidValue("relations padding") }
    return relations
}
