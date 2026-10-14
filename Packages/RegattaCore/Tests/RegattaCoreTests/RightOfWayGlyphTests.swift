import Testing
@testable import RegattaCore

/// #123 acceptance: which right-of-way glyph each boat shows the other (`Race.keepClearRelations(of:)`,
/// `RightOfWayGlyph`): an orange ⚠ on a boat I must keep clear of, a chevron on one that must keep clear of me.
@Suite struct RightOfWayGlyphTests {
    typealias F = IncidentFixture

    /// Seat 0 and seat 1 placed side by side on starboard mid-beat (seat 1 to windward, overlapped), `edit`
    /// applied; returns (what seat 0 sees on seat 1, what seat 1 sees on seat 0, the rule).
    static func glyphs(edit: (Race, inout WorldSnapshot) -> Void = { _, _ in }) throws
        -> (RightOfWayGlyph?, RightOfWayGlyph?, RacingRule?) {
        let race = try F.race()
        let hull = race.boatClass.hull
        try F.place(race, tick: 2 * Race.tickRate, at: F.midBeat(race), heading: F.starboard(race, offWind: .pi / 4),
                    abeam: hull.beam + 1.5) { edit(race, &$0) }
        let mine = race.keepClearRelations(of: 0)
        let theirs = race.keepClearRelations(of: 1)
        #expect(mine[0] == nil && theirs[1] == nil)
        #expect(mine[1] == theirs[0], "both boats agree who keeps clear")
        return (RightOfWayGlyph.glyph(for: mine[1], me: 0), RightOfWayGlyph.glyph(for: theirs[0], me: 1), mine[1]?.rule)
    }

    @Test func portStarboard() throws {
        let (onOne, onZero, rule) = try Self.glyphs { race, snapshot in
            snapshot.seats[1].boat.heading = wrapAngle(race.course.axis + .pi / 4)
            snapshot.seats[1].boat.boomSide = .starboard
            #expect(snapshot.seats[1].boat.tack == .port)
        }
        #expect(rule == .portStarboard)
        #expect(onOne == .hasRight, "the port boat must keep clear of me: chevron")
        #expect(onZero == .giveWay, "I am on port: ⚠ on the starboard boat")
    }

    @Test func windwardLeeward() throws {
        let (onOne, onZero, rule) = try Self.glyphs()
        #expect(rule == .windwardLeeward)
        #expect(onOne == .hasRight && onZero == .giveWay)
    }

    @Test func clearAstern() throws {
        let (onOne, onZero, rule) = try Self.glyphs { race, snapshot in
            let zero = snapshot.seats[0].boat
            snapshot.seats[1].boat.position = zero.position - zero.forward * (race.boatClass.hull.length * 3)
            snapshot.overlaps = [.init(pair: .init(0, 1), isOverlapped: false, changeTicks: 0)]
        }
        #expect(rule == .clearAstern)
        #expect(onOne == .hasRight && onZero == .giveWay)
    }

    /// The leeward boat tacking keeps clear (rule 13), though rule 11 would give her right of way.
    @Test func tacking13() throws {
        let (onOne, onZero, rule) = try Self.glyphs { _, snapshot in snapshot.seats[0].boat.isTacking = true }
        #expect(rule == .whileTacking)
        #expect(onOne == .giveWay && onZero == .hasRight)
    }

    /// Seat 0, the leeward boat, `degrees` into her penalty turn.
    static func penalised(_ degrees: Double) -> (Race, inout WorldSnapshot) -> Void {
        { _, snapshot in
            snapshot.seats[0].boat.penaltyTurnsOwed = 1
            snapshot.seats[0].boat.penaltyProgress = deg2rad(degrees)
            snapshot.seats[0].boat.penaltyClockTick = snapshot.tick
        }
    }

    /// The leeward boat 45° into her penalty turn keeps clear (21.2); at 20° she still has her rights.
    @Test func penalised21() throws {
        let starting = try Self.glyphs(edit: Self.penalised(20))
        #expect(starting.2 == .windwardLeeward && starting.0 == .hasRight)
        let (onOne, onZero, rule) = try Self.glyphs(edit: Self.penalised(45))
        #expect(rule == .takingAPenalty)
        #expect(onOne == .giveWay && onZero == .takingAPenalty)
    }

    /// #517: a boat taking a penalty (21.2) shows every other boat the penalty kind, the orange glow, in place of
    /// green; her own view keeps the other boat red.
    @Test func boatTakingAPenaltyShowsThePenaltyKindToOtherBoats() throws {
        let (onOne, onZero, rule) = try Self.glyphs(edit: Self.penalised(45))
        #expect(rule == .takingAPenalty)
        #expect(onZero == .takingAPenalty, "seat 1 sees the boat taking a penalty")
        #expect(onOne == .giveWay, "her own view: she must keep clear")
    }

    /// An OCS boat sailing back to the line keeps clear (21.1).
    @Test func returning21() throws {
        let (onOne, onZero, rule) = try Self.glyphs { race, snapshot in
            let at = race.course.startLine.centre + race.course.upwind * 6
            let heading = F.starboard(race, offWind: 3 * .pi / 4)
            snapshot.seats[0].boat.position = at
            snapshot.seats[0].boat.heading = heading
            snapshot.seats[1].boat.heading = heading
            snapshot.seats[1].boat.position = at + Vec2.heading(heading).rightPerp * (race.boatClass.hull.beam + 1.5)
            snapshot.seats[0].boat.status = .ocs
            #expect(race.course.isReturning(snapshot.seats[0].boat))
        }
        #expect(rule == .returningToStart)
        #expect(onOne == .giveWay && onZero == .hasRight)
    }

    /// #517: a boat returning to start (21.1) keeps clear as a boat taking a penalty does, but stays green.
    @Test func returningBoatStaysGreen() throws {
        let (onOne, onZero, rule) = try Self.glyphs { race, snapshot in
            let at = race.course.startLine.centre + race.course.upwind * 6
            let heading = F.starboard(race, offWind: 3 * .pi / 4)
            snapshot.seats[0].boat.position = at
            snapshot.seats[0].boat.heading = heading
            snapshot.seats[1].boat.heading = heading
            snapshot.seats[1].boat.position = at + Vec2.heading(heading).rightPerp * (race.boatClass.hull.beam + 1.5)
            snapshot.seats[0].boat.status = .ocs
        }
        #expect(rule == .returningToStart)
        #expect(onZero == .hasRight, "the green glow, not the orange")
        #expect(onOne == .giveWay)
        let returning = RightOfWay(keepClear: 0, rule: .returningToStart)
        #expect(RightOfWayGlyph.glyph(for: returning, me: 1) == .hasRight)
    }

    @Test func ghostHasNoGlyph() throws {
        let (onOne, onZero, rule) = try Self.glyphs { _, snapshot in snapshot.seats[1].boat.status = .finished }
        #expect(onOne == nil && onZero == nil && rule == nil)
    }

    @Test func rangeCutOff() {
        let hull = Race.defaultBoatClass.hull.length
        let range = RightOfWayGlyph.defaultRangeHulls
        #expect(RightOfWayGlyph.isInRange(.zero, Vec2(0, range * hull), rangeHulls: range, hullLength: hull))
        #expect(!RightOfWayGlyph.isInRange(.zero, Vec2(0, range * hull + 0.01), rangeHulls: range, hullLength: hull))
        #expect(RightOfWayGlyph.isInRange(.zero, Vec2(3, 4), rangeHulls: 1, hullLength: 5))
    }

    @Test func glyphSelectionIsFromMySide() {
        let relation = RightOfWay(keepClear: 2, rule: .portStarboard)
        #expect(RightOfWayGlyph.glyph(for: relation, me: 2) == .giveWay)
        #expect(RightOfWayGlyph.glyph(for: relation, me: 5) == .hasRight)
        let penalised = RightOfWay(keepClear: 2, rule: .takingAPenalty)
        #expect(RightOfWayGlyph.glyph(for: penalised, me: 2) == .giveWay)
        #expect(RightOfWayGlyph.glyph(for: penalised, me: 5) == .takingAPenalty)
        #expect(RightOfWayGlyph.glyph(for: nil, me: 2) == nil)
    }
}
