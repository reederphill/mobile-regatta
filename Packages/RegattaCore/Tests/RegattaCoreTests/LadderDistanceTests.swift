import Foundation
import Testing
@testable import RegattaCore

/// #267 acceptance: standings, places and the gap to the leader by ladder distance (`Race.ladderDistanceToFinish`,
/// `Race.gapToLeader`): across the course axis's ladder lines on the beats and runs, along the leg on the reach.
@Suite struct LadderDistanceTests {
    /// Default laps (2): W, O, gate, W, O, finish.
    static func race(seats: Int, seed: UInt64 = 21) -> Race {
        testRace(seats: Array(repeating: .human, count: seats), prestartSeconds: 1, seed: seed)
    }

    static func targets(_ course: CourseLayout) -> (w: Vec2, o: Vec2, gate: Vec2) {
        (course.targetPosition(for: .round(CourseLayout.windwardIndex)),
         course.targetPosition(for: .round(CourseLayout.offsetIndex)),
         course.targetPosition(for: .round(CourseLayout.gateIndex)))
    }

    @Test func twoBoatsOnOneLadderLineAreLevel() throws {
        let race = Self.race(seats: 3)
        let course = race.course
        let (w, _, _) = Self.targets(course)
        let line = w - course.upwind * 100
        // Seat 2 nearer the rhumb line, seat 1 further out: level up the axis on the first beat.
        try jump(race, to: 600) { snapshot in
            placeRacing(&snapshot.seats[1].boat, leg: 0, at: line + course.right * 30)
            placeRacing(&snapshot.seats[2].boat, leg: 0, at: line - course.right * 20)
        }
        let one = race.ladderDistanceToFinish(of: race.boats[1])
        let two = race.ladderDistanceToFinish(of: race.boats[2])
        #expect(abs(one - two) < 1e-9, "same ladder line, same ladder distance")
        #expect(race.distanceToFinish(of: race.boats[2]) < race.distanceToFinish(of: race.boats[1]),
                "the path length would have ranked seat 2 ahead")
        #expect(Array(race.standings().prefix(2)) == [1, 2], "adjacent, the seat breaks the tie")
        #expect(race.place(of: 1) == 1 && race.place(of: 2) == 2 && race.place(of: 0) == 3)
        #expect(try abs(#require(race.gapToLeader(of: 1))) < 1e-9)
        #expect(try abs(#require(race.gapToLeader(of: 2))) < 1e-9)
    }

    @Test func boatWideOnTheBeatIsNotPenalised() throws {
        let race = Self.race(seats: 2)
        let course = race.course
        let (w, _, _) = Self.targets(course)
        let line = w - course.upwind * (course.beat / 2)
        // Seat 0 far out to the side, seat 1 near the rhumb line, level up the axis.
        try jump(race, to: 600) { snapshot in
            placeRacing(&snapshot.seats[0].boat, leg: 0, at: line + course.right * 200)
            placeRacing(&snapshot.seats[1].boat, leg: 0, at: line + course.right * 2)
        }
        let wide = race.boats[0], near = race.boats[1]
        #expect(abs(race.ladderDistanceToFinish(of: wide) - race.ladderDistanceToFinish(of: near)) < 1e-9)
        #expect(race.distanceToFinish(of: wide) > race.distanceToFinish(of: near) + 20,
                "the path length would have put her well behind")
        #expect(race.standings() == [0, 1], "level: she keeps her place on the seat")

        // A metre further up the axis, the wide boat leads outright, and seat 1 is a metre behind.
        try jump(race, to: 601) { snapshot in
            placeRacing(&snapshot.seats[0].boat, leg: 0, at: line + course.upwind * 1 + course.right * 200)
            placeRacing(&snapshot.seats[1].boat, leg: 0, at: line + course.right * 2)
        }
        #expect(race.standings() == [0, 1])
        #expect(try abs(#require(race.gapToLeader(of: 1)) - 1) < 1e-9)
    }

    @Test func gapToLeaderSpansLegs() throws {
        let race = Self.race(seats: 2)
        let course = race.course
        #expect(course.legs.count == 6)
        let (w, o, gate) = Self.targets(course)
        let up = course.upwind
        let me = w - up * 40 + course.right * 15
        // The leader one leg ahead: she has sailed the reach and just rounded O onto the run to the gate.
        try jump(race, to: 600) { snapshot in
            placeRacing(&snapshot.seats[0].boat, leg: 0, at: me)
            placeRacing(&snapshot.seats[1].boat, leg: 2, at: o)
        }
        let myLeg = abs((w - me).dot(up))
        #expect(abs(myLeg - 40) < 1e-9)
        #expect(try abs(#require(race.gapToLeader(of: 0)) - (myLeg + (o - w).length)) < 1e-9,
                "the ladder remainder of my beat plus the whole reach")
        #expect(race.gapToLeader(of: 1) == 0)
        #expect(race.standings() == [1, 0])

        // Two legs ahead: the run to the gate as well, down the axis.
        try jump(race, to: 601) { snapshot in
            placeRacing(&snapshot.seats[0].boat, leg: 0, at: me)
            placeRacing(&snapshot.seats[1].boat, leg: 3, at: gate)
        }
        let run = abs((gate - o).dot(up))
        #expect(try abs(#require(race.gapToLeader(of: 0)) - (myLeg + (o - w).length + run)) < 1e-9)
    }

    @Test func finishedLeaderGapIsRemainingDistance() throws {
        let race = Self.race(seats: 6)
        let course = race.course
        let (w, _, gate) = Self.targets(course)
        for seat in race.boats.indices { race.record(.joined(.human), seat: seat) }
        try jump(race, to: 600) { snapshot in
            snapshot.seats[0].boat.status = .finished
            snapshot.seats[0].boat.place = 1
            snapshot.seats[0].boat.finishTime = 5
            snapshot.firstFinishTime = 5
            placeRacing(&snapshot.seats[1].boat, leg: 3, at: gate + (w - gate) * 0.5 + course.right * 25)
            snapshot.seats[3].boat.status = .ocs
            snapshot.seats[4].boat.status = .dsq
            placeRacing(&snapshot.seats[5].boat, leg: 3, at: w - course.upwind * 10)
        }
        race.record(.dropped, seat: 5)
        #expect(race.boats[2].status == .prestart)

        let ladder = race.ladderDistanceToFinish(of: race.boats[1])
        #expect(ladder > 0)
        #expect(race.gapToLeader(of: 1) == ladder, "the finished leader counts as 0: the gap is all she has left")
        #expect(race.gapToLeader(of: 0) == 0, "the leader's own gap")
        #expect(race.gapToLeader(of: 2) == nil, "prestart")
        #expect(race.gapToLeader(of: 3) == nil, "OCS")
        #expect(race.gapToLeader(of: 4) == nil, "DSQ")
        #expect(race.gapToLeader(of: 5) == nil, "gone")
        // Gone, she still stands in the order, ahead of seat 1 (until the close makes her RET).
        #expect(Array(race.standings().prefix(3)) == [0, 5, 1])
    }

    /// The owner's ruling (#267): the reach, which the course axis can't measure, ranks along the leg.
    @Test func reachLegRanksByProgress() throws {
        let race = Self.race(seats: 2)
        let course = race.course
        let (w, o, _) = Self.targets(course)
        let reach = o - w
        // Both on the reach, seat 0 a third of the way along it and a little above, seat 1 two thirds along.
        try jump(race, to: 600) { snapshot in
            placeRacing(&snapshot.seats[0].boat, leg: 1, at: w + reach / 3 + course.upwind * 3)
            placeRacing(&snapshot.seats[1].boat, leg: 1, at: w + reach * 2 / 3)
        }
        #expect(race.standings() == [1, 0])
        let gap = try #require(race.gapToLeader(of: 0))
        #expect(abs(gap - reach.length / 3) < 0.5, "about a third of the reach behind")
    }

    /// The total runs on across each rounding with no jump: a boat at a leg's target has the same ladder
    /// distance on that leg as on the next.
    @Test func ladderDistanceIsContinuousAcrossRoundings() {
        let race = Self.race(seats: 2)
        let course = race.course
        var boat = race.boats[0]
        boat.status = .racing
        for leg in 0..<(course.legs.count - 1) {
            boat.position = course.targetPosition(for: course.legs[leg])
            boat.legIndex = leg
            let before = race.ladderDistanceToFinish(of: boat)
            boat.legIndex = leg + 1
            let after = race.ladderDistanceToFinish(of: boat)
            #expect(abs(before - after) < 1e-9, "rounding leg \(leg)'s target")
        }
        boat.legIndex = course.legs.count - 1
        boat.position = Collision.closestPoint(on: course.finishLine.segment, to: boat.position)
        #expect(abs(race.ladderDistanceToFinish(of: boat)) < 1e-9, "on the finish line")
    }

    // MARK: #268: the whole fleet's gaps once per tick, and #267's review

    /// `gapToLeader(of:)` as #267 worked it, one seat at a time, for checking `gapsToLeader()` against.
    /// `gone`: the seats whose player has gone.
    static func reference(_ race: Race, _ seat: Int, gone: Set<Int> = []) -> Double? {
        let boat = race.boats[seat]
        switch boat.status {
        case .prestart, .ocs, .dsq: return nil
        case .finished, .racing: break
        }
        if gone.contains(seat), !boat.isGhost { return nil }
        if boat.status == .finished { return 0 }
        let mine = race.ladderDistanceToFinish(of: boat)
        guard mine.isFinite else { return nil }
        if race.boats.contains(where: { $0.status == .finished }) { return mine }
        let leader = race.boats.lazy.filter { $0.status == .racing }.map(race.ladderDistanceToFinish(of:))
            .filter(\.isFinite).min() ?? mine
        return mine - leader
    }

    static func expectGapsAgree(_ race: Race, gone: Set<Int> = [], sourceLocation: SourceLocation = #_sourceLocation) {
        let gaps = race.gapsToLeader()
        #expect(gaps.count == race.boats.count, sourceLocation: sourceLocation)
        for seat in race.boats.indices {
            let expected = reference(race, seat, gone: gone)
            #expect(gaps[seat] == expected, "seat \(seat)", sourceLocation: sourceLocation)
            #expect(race.gapToLeader(of: seat) == gaps[seat], "seat \(seat)", sourceLocation: sourceLocation)
        }
    }

    /// `gapsToLeader()` gives, bit for bit, the gaps #267's one-seat `gapToLeader(of:)` gave, over the
    /// scenarios above: level, wide, legs apart, on the reach, a finished leader with OCS, DSQ and gone.
    @Test func gapsToLeaderMatchesOneSeatAtATime() throws {
        let race = Self.race(seats: 6)
        let course = race.course
        let (w, o, gate) = Self.targets(course)
        for seat in race.boats.indices { race.record(.joined(.human), seat: seat) }
        Self.expectGapsAgree(race)
        try jump(race, to: 600) { snapshot in
            placeRacing(&snapshot.seats[0].boat, leg: 0, at: w - course.upwind * 40 + course.right * 15)
            placeRacing(&snapshot.seats[1].boat, leg: 2, at: o)
            placeRacing(&snapshot.seats[2].boat, leg: 1, at: w + (o - w) / 3 + course.upwind * 3)
            placeRacing(&snapshot.seats[3].boat, leg: 3, at: gate)
            snapshot.seats[4].boat.status = .dsq
            placeRacing(&snapshot.seats[5].boat, leg: 0, at: w - course.upwind * 40 - course.right * 200)
        }
        Self.expectGapsAgree(race)
        #expect(race.gapsToLeader()[3] == 0, "the leader")
        race.record(.dropped, seat: 3)
        Self.expectGapsAgree(race, gone: [3])
        #expect(race.gapsToLeader()[3] == nil, "gone, but still the leader the others are measured from")
        #expect(try #require(race.gapsToLeader()[0]) > 0)

        try jump(race, to: 601) { snapshot in
            snapshot.seats[1].boat.status = .finished
            snapshot.seats[1].boat.place = 1
            snapshot.seats[1].boat.finishTime = 5
            snapshot.firstFinishTime = 5
            snapshot.seats[2].boat.status = .ocs
        }
        Self.expectGapsAgree(race, gone: [3])
    }

    /// #267's review: a boat that finished and whose player then left keeps her gap of 0 (she isn't RET:
    /// her finish stands), while a racing boat whose player dropped has none.
    @Test func finishedThenGoneKeepsGapZero() throws {
        let race = Self.race(seats: 3)
        let course = race.course
        let (w, _, gate) = Self.targets(course)
        for seat in race.boats.indices { race.record(.joined(.human), seat: seat) }
        try jump(race, to: 600) { snapshot in
            snapshot.seats[0].boat.status = .finished
            snapshot.seats[0].boat.place = 1
            snapshot.seats[0].boat.finishTime = 5
            snapshot.firstFinishTime = 5
            placeRacing(&snapshot.seats[1].boat, leg: 3, at: gate + (w - gate) * 0.5)
            placeRacing(&snapshot.seats[2].boat, leg: 3, at: gate)
        }
        race.record(.left, seat: 0)
        race.record(.dropped, seat: 2)
        #expect(race.gapToLeader(of: 0) == 0, "finished, then left: the finish stands")
        #expect(race.gapsToLeader()[0] == 0)
        #expect(race.gapToLeader(of: 1) == race.ladderDistanceToFinish(of: race.boats[1]))
        #expect(race.gapToLeader(of: 2) == nil, "racing, then dropped")
    }

    /// `isReachLeg`'s boundary is strict: a leg exactly as far across the axis as along it is a beat or a
    /// run, measured along the axis; a hair further across is a reach, measured along the leg. Either way the
    /// total runs on across the rounding.
    @Test func reachLegBoundaryIsStrict() throws {
        let base = Self.race(seats: 2).course
        func mark(_ name: String, _ x: Double, _ y: Double) -> CourseLayout.Mark {
            CourseLayout.Mark(name: name, position: Vec2(x, y), radius: 1)
        }
        // Axis 0: up the course is +y and right is +x exactly, so the dot products are exact.
        let line = CourseLayout.Line(pin: mark("pin", -50, 0), committee: mark("committee", 50, 0))
        let course = CourseLayout(
            axis: 0, beat: base.beat, startLine: line, finishLine: line, elements: base.elements,
            legs: [.round(0), .round(1), .finish], raceArea: base.raceArea, land: [],
            edgeSpeedRetention: base.edgeSpeedRetention, placement: base.placement, zoneRadius: base.zoneRadius)
        #expect(course.upwind == Vec2(0, 1) && course.right == Vec2(1, 0))

        for (across, isReach) in [(40.0, false), (40.0.nextUp, true)] {
            let first = Vec2(across, 40)
            let second = first + Vec2(0, 100)
            let targets = [first, second, Vec2(across, 0)]
            let ladder = Race.ladderLegs(targets, course: course)
            #expect(ladder.isReach == [isReach, false, false], "across \(across)")
            // At the first target: leg 0's total (nothing left of it) equals leg 1's from the same point.
            let onLeg1 = abs((second - first).dot(course.upwind)) + ladder.after[1]
            #expect(abs(ladder.after[0] - onLeg1) < 1e-9)
            #expect(abs(ladder.after[1] - second.y) < 1e-9, "the finish leg, down the axis to the line")
        }
    }
}
