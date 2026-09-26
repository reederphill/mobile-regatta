import Testing
@testable import RegattaCore

/// A racing boat at `p` (metres) on compass `heading` in a wind from `wind`, degrees, with her boom
/// to leeward unless `boom` says otherwise.
private func boat(_ id: Int, at p: Vec2, heading degrees: Double, wind: Double = 0, boom: BoomSide? = nil) -> Boat {
    var b = Boat(id: id, isPlayer: false, colorIndex: id, position: p, heading: deg2rad(degrees), speed: 3)
    b.windDirection = deg2rad(wind)
    b.boomSide = boom ?? .leeward(ofRelativeWind: b.relativeWind)
    b.status = .racing
    return b
}

private let hull = Race.defaultBoatClass.hull

/// #87 acceptance: rules 10–13 from the world state (`Rules.rightOfWay`).
@Suite struct RightOfWayTests {
    /// #3 bug 1: two starboard boats close-hauled (heading 315°, wind 0°); the leeward boat 3 m forward
    /// and 1 m to leeward is further upwind, but she is on the other's leeward side, so the other keeps clear.
    @Test func windwardIsDecidedBySideOfBoatNotDistanceUpwind() {
        let windward = boat(1, at: .zero, heading: 315)
        let forward = windward.forward
        let toLeeward = -forward.rightPerp // her boom is to port, so port is her leeward side
        let leeward = boat(2, at: forward * 3 + toLeeward * 1, heading: 315)
        #expect(windward.tack == .starboard && leeward.tack == .starboard)
        #expect(leeward.position.y > windward.position.y, "the leeward boat is further upwind")
        #expect(Rules.geometricOverlaps([windward, leeward], hull: hull) == [true])

        let expected = RightOfWay(keepClear: 1, rule: .windwardLeeward)
        #expect(Rules.rightOfWay(windward, leeward, overlapped: true, hull: hull) == expected)
        #expect(Rules.rightOfWay(leeward, windward, overlapped: true, hull: hull) == expected)
    }

    /// #3 bug 2: 10° by the lee with the boom unchanged she is still on starboard tack, so a port boat
    /// keeps clear of her (rule 10), though the wind is over her port side.
    @Test func byTheLeeKeepsHerTackAndRule10() {
        let dinghy = Race.defaultBoatClass
        var state = BoatDynamics.State(heading: deg2rad(170), speed: 2.5, boomSide: .port)
        let env = BoatDynamics.Environment.constant(windDirection: 0, windSpeed: metresPerSecond(knots: 8))
        for _ in 0..<(5 * Race.tickRate) {
            state = BoatDynamics.advance(state, control: .init(rudder: 0), env: env, boatClass: dinghy, dt: Race.dt)
        }
        #expect(state.boomSide == .port)

        var running = boat(1, at: .zero, heading: 0, boom: state.boomSide)
        running.heading = state.heading
        #expect(running.isByTheLee)
        #expect(BoomSide.leeward(ofRelativeWind: running.relativeWind) == .starboard, "the wind is over her port side")
        #expect(running.tack == .starboard)

        let port = boat(2, at: Vec2(3, -2), heading: 45)
        #expect(port.tack == .port)
        let expected = RightOfWay(keepClear: 2, rule: .portStarboard)
        for overlapped in [false, true] {
            #expect(Rules.rightOfWay(running, port, overlapped: overlapped, hull: hull) == expected)
            #expect(Rules.rightOfWay(port, running, overlapped: overlapped, hull: hull) == expected)
        }
    }

    /// Rule 13 with both boats tacking: the one on the other's port side keeps clear, whether they are on
    /// the same tack or the booms have crossed at different moments; the one astern keeps clear if one is.
    @Test func bothTackingPortSideBoatKeepsClear() {
        // Head to wind, abeam: seat 2 is on seat 1's port side (west, heading north).
        var starboardSide = boat(1, at: .zero, heading: 0, boom: .port)
        var portSide = boat(2, at: Vec2(-2, 0), heading: 0, boom: .port)
        starboardSide.isTacking = true
        portSide.isTacking = true
        let expected = RightOfWay(keepClear: 2, rule: .whileTacking)
        #expect(Rules.rightOfWay(starboardSide, portSide, overlapped: true, hull: hull) == expected)
        #expect(Rules.rightOfWay(portSide, starboardSide, overlapped: true, hull: hull) == expected)

        // Opposite booms: the overlap terms don't apply, and neither is astern.
        portSide.boomSide = .starboard
        #expect(!Rules.overlapTermsApply(starboardSide, portSide))
        #expect(Rules.rightOfWay(starboardSide, portSide, overlapped: false, hull: hull) == expected)

        // The one astern keeps clear, even on the starboard side.
        var astern = boat(3, at: Vec2(2, -6), heading: 0, boom: .port)
        astern.isTacking = true
        portSide.boomSide = .port
        #expect(Rules.rightOfWay(portSide, astern, overlapped: false, hull: hull) == RightOfWay(keepClear: 3, rule: .whileTacking))
    }

    /// A ghost has no rights or obligations: no answer for any pair with one, and her overlaps are forgotten.
    @Test func ghostInAPairHasNoRightOfWay() {
        let starboard = boat(1, at: .zero, heading: -45)
        var ghost = boat(2, at: Vec2(1, 0), heading: 45)
        #expect(Rules.rightOfWay(starboard, ghost, overlapped: true, hull: hull) != nil)
        for status in [BoatStatus.finished, .dsq, .dnf] {
            ghost.status = status
            #expect(ghost.isGhost)
            #expect(Rules.rightOfWay(starboard, ghost, overlapped: true, hull: hull) == nil)
            #expect(Rules.rightOfWay(ghost, starboard, overlapped: false, hull: hull) == nil)
        }
        for status in [BoatStatus.prestart, .ocs, .racing] {
            ghost.status = status
            #expect(!ghost.isGhost)
        }

        let leeward = boat(0, at: .zero, heading: 90)
        var windward = boat(1, at: Vec2(0, 1.4), heading: 90)
        var tracker = OverlapTracker(seats: 2)
        for _ in 0..<20 { tracker.update([leeward, windward], hull: hull, margin: 15) }
        #expect(tracker.isOverlapped(0, 1))
        windward.status = .finished
        tracker.update([leeward, windward], hull: hull, margin: 15)
        #expect(!tracker.isOverlapped(0, 1))
    }

    /// In a race, the overlap counts once it has held for the last point of certainty, the snapshot
    /// carries the count, and `Race.rightOfWay` reads the certain overlap.
    @Test func raceCountsAnOverlapOnceItHasHeldAndCarriesTheCount() throws {
        let race = testRace(seats: [.human, .human], seed: 5)
        for _ in 0..<10 { race.step() }
        var snapshot = race.exportSnapshot()
        let lead = snapshot.seats[0].boat
        // Both on a beam reach on starboard tack; seat 1 3 m to windward and 3 m back: overlapped.
        let heading = wrapAngle(lead.windDirection - .pi / 2)
        for seat in 0..<2 {
            var b = snapshot.seats[seat].boat
            b.heading = heading
            b.speed = 3
            b.boomSide = .port
            b.position = seat == 0 ? lead.position : lead.position - Vec2.heading(heading) * 3 + Vec2.heading(heading).rightPerp * 3
            snapshot.seats[seat].boat = b
        }
        snapshot.overlaps = [] // whatever the boats' old places were counting towards
        try race.importSnapshot(snapshot)
        #expect(!race.isOverlapped(0, 1))
        #expect(race.rightOfWay(0, 1) == RightOfWay(keepClear: 1, rule: .clearAstern))

        for _ in 0..<7 { race.step() }
        let copy = testRace(seats: [.human, .human], seed: 5)
        try copy.importSnapshot(race.exportSnapshot())
        for step in 8...15 {
            race.step()
            copy.step()
            #expect(race.isOverlapped(0, 1) == (step == 15), "step \(step)")
            #expect(copy.digest() == race.digest())
        }
        #expect(race.rightOfWay(0, 1) == RightOfWay(keepClear: 1, rule: .windwardLeeward))
    }
}

@Suite struct OverlapTrackerTests {
    let margin = RulesConfig.ticks(Race.defaultRulesConfiguration.content.incidents.lastPointOfCertainty)

    /// Seat 0 sailing east; seat 1 on the same tack to windward, `behind` metres back.
    func pair(behind: Double) -> [Boat] {
        [boat(0, at: .zero, heading: 90), boat(1, at: Vec2(-behind, 3), heading: 90)]
    }

    /// An overlap of 0.4 s (12 ticks) never counts; one of 0.5 s (15 ticks) counts on its 15th tick,
    /// and breaking it takes as long.
    @Test func overlapShorterThanLastPointOfCertaintyIsNotCounted() {
        #expect(margin == 15)
        let clear = pair(behind: 5)
        let overlapping = pair(behind: 3)
        #expect(Rules.geometricOverlaps(clear, hull: hull) == [false])
        #expect(Rules.geometricOverlaps(overlapping, hull: hull) == [true])

        var tracker = OverlapTracker(seats: 2)
        tracker.update(clear, hull: hull, margin: margin)
        for _ in 0..<12 {
            tracker.update(overlapping, hull: hull, margin: margin)
            #expect(!tracker.isOverlapped(0, 1))
        }
        tracker.update(clear, hull: hull, margin: margin)
        #expect(!tracker.isOverlapped(0, 1) && tracker.changeTicks(0, 1) == 0)

        for tick in 1...margin {
            tracker.update(overlapping, hull: hull, margin: margin)
            #expect(tracker.isOverlapped(1, 0) == (tick == margin), "tick \(tick)")
        }

        for _ in 0..<12 { tracker.update(clear, hull: hull, margin: margin) }
        #expect(tracker.isOverlapped(0, 1) && tracker.changeTicks(0, 1) == 12)
        tracker.update(overlapping, hull: hull, margin: margin)
        #expect(tracker.isOverlapped(0, 1) && tracker.changeTicks(0, 1) == 0)
    }

    /// On opposite tacks boats overlap only when both are more than 90° from the true wind.
    @Test func oppositeTacksOverlapOnlyBothMoreThanNinetyDegreesFromTheWind() {
        let running = [boat(0, at: .zero, heading: 170), boat(1, at: Vec2(3, 0), heading: 190)]
        #expect(running[0].tack != running[1].tack)
        #expect(Rules.geometricOverlaps(running, hull: hull) == [true])
        let beating = [boat(0, at: .zero, heading: 315), boat(1, at: Vec2(3, 0), heading: 45)]
        #expect(beating[0].tack != beating[1].tack)
        #expect(Rules.geometricOverlaps(beating, hull: hull) == [false])
    }

    /// A boat between two others that overlaps both makes them overlap, through a chain of such boats too.
    @Test func boatBetweenThatOverlapsBothMakesThemOverlap() {
        // Heading north in a line of echelon: each 3 m ahead of and 1.5 m to starboard of the last.
        let line = (0..<4).map { boat($0, at: Vec2(1.5 * Double($0), 3 * Double($0)), heading: 0, wind: 90) }
        let overlaps = Rules.geometricOverlaps(line, hull: hull)
        for a in 0..<4 {
            for b in (a + 1)..<4 {
                #expect(overlaps[OverlapTracker.index(a, b, seats: 4)], "\(a), \(b)")
                #expect(Rules.isClearAstern(line[a], of: line[b], hull: hull) == (b - a > 1))
            }
        }
        // Without the boats between, 0 and 3 are clear astern and ahead.
        #expect(Rules.geometricOverlaps([line[0], line[3]], hull: hull) == [false])
    }
}
