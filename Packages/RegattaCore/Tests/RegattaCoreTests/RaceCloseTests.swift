import Foundation
import Testing
@testable import RegattaCore

/// Jumps `race` to `tick` by a snapshot of itself, with the keys its own wind seed makes through the window
/// holding `tick`, and `edit` applied: for closes that come 16 minutes after the gun, without sailing there.
func jump(_ race: Race, to tick: Int, _ edit: (inout WorldSnapshot) -> Void = { _ in }) throws {
    let windows = race.wind.windows
    var generator = try WindKeyGenerator(windSeed: try #require(race.windSeed), setup: race.windSetup, windows: windows)
    var snapshot = race.exportSnapshot()
    snapshot.tick = tick
    snapshot.windKeys = WindKeyChain(generator.keys(through: windows.window(containing: tick)))
    edit(&snapshot)
    try race.importSnapshot(snapshot)
}

/// `boat` racing on the finish leg, owing `penaltyTurnsOwed` turns (the current one's clock started at
/// `penaltyClockTick`, none queued), her centre a few centimetres on the course side of the finish line's
/// centre and sailing straight down the course: she crosses the line on the next step.
func placeToFinish(_ boat: inout Boat, in race: Race, penaltyTurnsOwed: Int = 0, penaltyClockTick: Int? = nil) {
    boat.status = .racing
    boat.legIndex = race.course.legs.count - 1
    boat.roundingStage = 0
    boat.penaltyTurnsOwed = penaltyTurnsOwed
    boat.penaltyProgress = 0
    boat.penaltyClockTick = penaltyTurnsOwed > 0 ? penaltyClockTick : nil
    boat.queuedPenaltyCallTicks = []
    boat.position = race.course.finishLine.centre + race.course.upwind * 0.05
    boat.heading = wrapAngle(race.course.axis + .pi)
    boat.speed = 4
    boat.autohelm = nil
}

/// `boat` racing on `leg`, at `position`.
func placeRacing(_ boat: inout Boat, leg: Int, at position: Vec2) {
    boat.status = .racing
    boat.legIndex = leg
    boat.roundingStage = 0
    boat.position = position
}

/// #86 acceptance: the close (#8, #30), the order of the results, and the all-gone close (G3).
@Suite struct RaceCloseTests {
    static let limit = 960 * Race.tickRate
    static let window = 120 * Race.tickRate

    /// Each seat has exactly one row.
    static func expectOneRowEach(_ results: RaceResults, seats: Int, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(results.rows.map(\.seat).sorted() == Array(0..<seats), sourceLocation: sourceLocation)
    }

    @Test func closeTickIsFirstFinishPlusWindowCappedByTimeLimit() throws {
        // Nobody finishes: the race closes at the time limit, 960 s after the gun.
        let open = testRace(seats: [.human, .human], prestartSeconds: 1, seed: 7)
        #expect(open.closeTick == Self.limit)
        try jump(open, to: Self.limit - 2)
        open.step()
        #expect(!open.isOver)
        _ = open.drainEvents()
        open.step()
        #expect(open.isOver && open.tick == Self.limit)
        let closed = try #require(open.results)
        #expect(open.drainEvents().last == RaceEvent(tick: Self.limit, kind: .raceClosed(results: closed)))
        open.step()
        #expect(open.tick == Self.limit, "a closed race never steps")

        // A DSQ doesn't open the window: only a finisher does (#8). Here she crosses the line on the tick her
        // penalty turn's complete deadline passes (#89): owing it she doesn't finish, and she is disqualified.
        let dsq = testRace(seats: [.human, .human], prestartSeconds: 1, seed: 7)
        let clock = 3_000 - RulesConfig.ticks(dsq.rules.raceFormat.penalty.complete)
        try jump(dsq, to: 2_999) { placeToFinish(&$0.seats[0].boat, in: dsq, penaltyTurnsOwed: 1, penaltyClockTick: clock) }
        dsq.step()
        #expect(dsq.boats[0].status == .dsq && dsq.firstFinishTime == nil && dsq.closeTick == Self.limit)
        let kinds = dsq.drainEvents().map(\.kind)
        let disqualified = try #require(kinds.firstIndex(of: .disqualified(seat: 0, reason: Race.missedComplete)))
        #expect(kinds[disqualified + 1] == .becameGhost(seat: 0))
        #expect(!kinds.contains { if case .finished = $0 { true } else { false } })

        // The first finish at t closes the race at min(t + 120 s, 960 s), and a boat crossing on that tick
        // still finishes.
        for t in [3_000, Self.limit - Self.window / 2] {
            let race = testRace(seats: [.human, .human, .human], prestartSeconds: 1, seed: 7)
            try jump(race, to: t - 1) { placeToFinish(&$0.seats[0].boat, in: race) }
            race.step()
            let close = min(t + Self.window, Self.limit)
            #expect(race.boats[0].status == .finished && race.firstFinishTick == t)
            #expect(race.closeTick == close && race.expectedCloseTick == close)
            #expect(race.drainEvents().map(\.kind).contains(.firstFinish(closeTick: close)))

            try jump(race, to: close - 1) { placeToFinish(&$0.seats[1].boat, in: race) }
            #expect(race.firstFinishTick == t, "the window travels in the snapshot")
            race.step()
            #expect(race.isOver && race.tick == close)
            #expect(race.boats[1].status == .finished && race.boats[1].place == 2, "crossing on the close tick")
            let results = try #require(race.results)
            #expect(results.rows.map(\.code) == [.finished, .finished, .ocs])
            #expect(results.gapTicks(of: 1) == close - t)
        }
    }

    @Test func unfinishedBoatsRankByDistanceRoundRemainingMarks() throws {
        // By ladder distance round the remaining marks (#267); `distanceToFinish` is still the path length.
        let race = testRace(seats: [.human, .human, .human], laps: 1, prestartSeconds: 1, seed: 11)
        let course = race.course
        #expect(course.legs == [.round(CourseLayout.windwardIndex), .round(CourseLayout.offsetIndex), .finish])
        let w = course.targetPosition(for: .round(CourseLayout.windwardIndex))
        let o = course.targetPosition(for: .round(CourseLayout.offsetIndex))
        // Both on the first beat: seat 0 just above the line, seat 1 just below W.
        try jump(race, to: 600) { snapshot in
            placeRacing(&snapshot.seats[0].boat, leg: 0, at: course.startLine.centre + course.upwind * 5)
            placeRacing(&snapshot.seats[1].boat, leg: 0, at: w - course.upwind * 10 + course.right * 3)
        }
        let finish = course.finishLine.segment
        func straightToFinish(_ p: Vec2) -> Double { (p - Collision.closestPoint(on: finish, to: p)).length }
        let low = race.boats[0].position, high = race.boats[1].position
        #expect(straightToFinish(low) < straightToFinish(high), "seat 0 is nearer the finish line in a straight line")

        // The path round the remaining marks: up to W, across to O, then to the nearest point of the finish line.
        let lowPath = (low - w).length + (w - o).length + straightToFinish(o)
        let highPath = (high - w).length + (w - o).length + straightToFinish(o)
        #expect(abs(race.distanceToFinish(of: race.boats[0]) - lowPath) < 1e-9)
        #expect(abs(race.distanceToFinish(of: race.boats[1]) - highPath) < 1e-9)
        #expect(highPath < lowPath)
        // They rank by ladder distance (#267): up the course axis to W, the reach along it, then down the axis to
        // the finish line.
        let rest = (w - o).length + abs((Collision.closestPoint(on: finish, to: o) - o).dot(course.upwind))
        #expect(abs(race.ladderDistanceToFinish(of: race.boats[0]) - (course.beat - 5 + rest)) < 1e-6)
        #expect(abs(race.ladderDistanceToFinish(of: race.boats[1]) - (10 + rest)) < 1e-9)
        #expect(Array(race.standings().prefix(2)) == [1, 0])
        #expect(race.place(of: 1) == 1 && race.place(of: 0) == 2)
        #expect(race.distanceToFinish(of: race.boats[2]) > lowPath, "not started: the whole course still to sail")

        // At the close they are placed by it, ahead of the boat that never started.
        try jump(race, to: race.closeTick - 1)
        race.step()
        let results = try #require(race.results)
        #expect(results.rows.map(\.seat) == [1, 0, 2])
        #expect(results.rows.map(\.code) == [.byDistance, .byDistance, .ocs])
        #expect(results.rows.map(\.place) == [1, 2, 3])
        #expect(results.rows.allSatisfy { $0.finishTick == nil })
    }

    @Test func normalCloseOrdersResultCodes() throws {
        let race = testRace(seats: Array(repeating: .human, count: 8), laps: 1, prestartSeconds: 1, seed: 13)
        for seat in race.boats.indices { race.record(.joined(.human), seat: seat) }
        let course = race.course
        let w = course.targetPosition(for: .round(CourseLayout.windwardIndex))
        let o = course.targetPosition(for: .round(CourseLayout.offsetIndex))
        let reach = (o - w).normalized
        let firstFinish = Self.limit - 3_000
        try jump(race, to: Self.limit - 1) { snapshot in
            func finished(_ seat: Int, place: Int, tick: Int) {
                snapshot.seats[seat].boat.status = .finished
                snapshot.seats[seat].boat.place = place
                snapshot.seats[seat].boat.finishTime = Double(tick) / Double(Race.tickRate)
            }
            finished(5, place: 1, tick: firstFinish)
            finished(2, place: 2, tick: firstFinish + 1_000)
            snapshot.firstFinishTime = Double(firstFinish) / Double(Race.tickRate)
            placeRacing(&snapshot.seats[7].boat, leg: 1, at: o - reach * 30)
            placeRacing(&snapshot.seats[0].boat, leg: 0, at: course.startLine.centre + course.upwind * (course.beat / 2))
            snapshot.seats[1].boat.status = .dsq
            snapshot.seats[3].boat.status = .ocs
            snapshot.seats[3].boat.position = course.startLine.centre + course.upwind * 20
            // Nearest the finish of the boats still racing, but her player has gone.
            placeRacing(&snapshot.seats[4].boat, leg: 1, at: o - reach * 10)
            // Seat 6 never started, and her player has gone.
        }
        race.record(.dropped, seat: 4)
        race.record(.botTookOver(.cautious), seat: 4)
        race.record(.left, seat: 6)
        #expect(race.closeTick == Self.limit)
        _ = race.drainEvents()
        #expect(!race.isGhost(seat: 3) && !race.isGhost(seat: 6))
        race.step()

        #expect(race.isOver && race.tick == Self.limit)
        let results = try #require(race.results)
        Self.expectOneRowEach(results, seats: 8)
        #expect(results.rows.map(\.seat) == [5, 2, 7, 0, 1, 3, 4, 6])
        #expect(results.rows.map(\.code) == [.finished, .finished, .byDistance, .byDistance, .dsq, .ocs, .ret, .ret])
        #expect(results.rows.map(\.place) == [1, 2, 3, 4, 5, 6, 7, 7], "the two RETs tied last")
        #expect(results.rows.map(\.finishTick) == [firstFinish, firstFinish + 1_000, nil, nil, nil, nil, nil, nil])
        #expect(results.gapTicks(of: 5) == 0 && results.gapTicks(of: 2) == 1_000 && results.gapTicks(of: 7) == nil)
        #expect(results.rated, "8 humans at the gun")
        #expect(race.standings() == results.rows.map(\.seat))
        #expect(race.boats.indices.map(race.place(of:)) == [4, 5, 2, 6, 7, 1, 8, 3], "unique places in display order")

        // Still OCS or never started, a boat becomes a ghost at the close, just before it's announced.
        #expect(race.drainEvents().map(\.kind).suffix(3) == [.becameGhost(seat: 3), .becameGhost(seat: 6),
                                                             .raceClosed(results: results)])
        #expect(race.isGhost(seat: 3) && race.isGhost(seat: 6) && race.isGhost(seat: 5) && race.isGhost(seat: 1))
        #expect(!race.isGhost(seat: 0) && !race.isGhost(seat: 4))
        #expect(race.expectedCloseTick == race.tick)
        #expect(race.record(.rejoined, seat: 4) == nil, "the log ends at the close")

        // The results travel in the world snapshot, and only a closed race's are accepted.
        let copy = testRace(seats: Array(repeating: .human, count: 8), laps: 1, prestartSeconds: 1, seed: 13)
        try copy.importSnapshot(race.exportSnapshot())
        #expect(copy.results == results && copy.standings() == race.standings())
        var notOver = race.exportSnapshot()
        notOver.isOver = false
        #expect(throws: WorldSnapshotError.invalidResults) { try copy.importSnapshot(notOver) }
        var short = race.exportSnapshot()
        short.results?.rows.removeLast()
        #expect(throws: WorldSnapshotError.invalidResults) { try copy.importSnapshot(short) }
        var twice = race.exportSnapshot()
        twice.results?.rows[7].seat = 0
        #expect(throws: WorldSnapshotError.invalidResults) { try copy.importSnapshot(twice) }
    }

    @Test func closeAllGoneRanksHumansByLeaveTick() throws {
        let race = testRace(seats: [.human, .bot, .human, .human, .bot], prestartSeconds: 1, seed: 19)
        for seat in race.boats.indices { race.record(.joined(race.setup.seats[seat]), seat: seat) }
        func step(to tick: Int) { while race.tick < tick { race.step() } }
        step(to: 60)
        race.record(.left, seat: 2)
        step(to: 90)
        race.record(.dropped, seat: 0)
        race.record(.botTookOver(.cautious), seat: 0)
        step(to: 120)
        race.record(.left, seat: 3)
        let k = 150
        step(to: k)
        _ = race.drainEvents()

        #expect(!race.closeAllGone(atTick: k - 1, leaveOrder: [2, 0, 3]), "only at the tick it is")
        #expect(!race.closeAllGone(atTick: k, leaveOrder: [2, 0, 2]), "a seat twice")
        #expect(!race.closeAllGone(atTick: k, leaveOrder: [2, 1, 3]), "a bot's seat")
        #expect(!race.closeAllGone(atTick: k, leaveOrder: [2, 0, 5]), "no such seat")
        #expect(!race.isOver && race.results == nil)

        #expect(race.closeAllGone(atTick: k, leaveOrder: [2, 0, 3]))
        #expect(race.isOver && race.tick == k)
        let results = try #require(race.results)
        #expect(race.drainEvents().last == RaceEvent(tick: k, kind: .raceClosed(results: results)))
        Self.expectOneRowEach(results, seats: 5)
        #expect(results.rows.prefix(2).allSatisfy { [1, 4].contains($0.seat) && $0.code != .ret }, "the bots ahead")
        #expect(results.rows.suffix(3).map(\.seat) == [3, 0, 2], "the latest gone ranks highest")
        #expect(results.rows.suffix(3).map(\.code) == [.ret, .ret, .ret])
        #expect(results.rows.suffix(3).map(\.place) == [3, 4, 5], "each RET its own place")
        #expect(results.rated, "3 humans at the gun")

        #expect(!race.closeAllGone(atTick: k, leaveOrder: [2, 0, 3]), "already closed")
        race.step()
        #expect(race.tick == k)

        // The log keeps the close, and a replay closes the same way.
        let log = try #require(race.log)
        #expect(log.allGoneClose == RaceLog.AllGoneClose(tick: k, leaveOrder: [2, 0, 3]))
        #expect(try RaceLog(jsonData: log.jsonData()) == log)
        let replayed = try Replayer.replay(log)
        #expect(replayed.isOver && replayed.tick == k && replayed.results == results)
        #expect(replayed.digest() == race.digest())
        var early = log
        early.allGoneClose?.tick = k - 1
        #expect(throws: ReplayError.rejectedAllGoneClose(atTick: k - 1)) { try Replayer.replay(early) }
    }

    @Test func finishThenSeatLeavesKeepsTheFinish() throws {
        for allGone in [false, true] {
            let race = testRace(seats: [.human, .human, .bot], prestartSeconds: 1, seed: 17)
            for seat in race.boats.indices { race.record(.joined(race.setup.seats[seat]), seat: seat) }
            try jump(race, to: 899) { placeToFinish(&$0.seats[0].boat, in: race) }
            race.step()
            #expect(race.boats[0].status == .finished)
            race.record(.left, seat: 0)
            race.record(.left, seat: 1)
            if allGone {
                #expect(race.closeAllGone(atTick: race.tick, leaveOrder: [0, 1]))
            } else {
                try jump(race, to: race.closeTick - 1)
                race.step()
            }
            #expect(race.isOver)
            let results = try #require(race.results)
            Self.expectOneRowEach(results, seats: 3)
            #expect(results.row(of: 0) == SeatResult(seat: 0, place: 1, code: .finished, finishTick: 900), "not RET")
            #expect(results.row(of: 1)?.code == .ret && results.rows.last?.seat == 1)
            #expect(results.row(of: 2)?.code != .ret)
        }
    }

    /// The results replay (ADR 0002): a race closed at its time limit, with a human gone, from its log. No one
    /// steers, so the seed is one where the drifting boats draw no rule call (a DSQ would outrank the RET).
    @Test func aClosedRaceReplaysToTheSameResults() throws {
        let race = testRace(seats: [.human, .human, .bot], laps: 1, prestartSeconds: 1, seed: 29)
        for seat in race.boats.indices { race.record(.joined(race.setup.seats[seat]), seat: seat) }
        while race.tick < 300 { race.step() }
        race.record(.left, seat: 1)
        while !race.isOver { race.step() }
        #expect(race.tick == Self.limit)
        let results = try #require(race.results)
        #expect(results.rows.last == SeatResult(seat: 1, place: 3, code: .ret))
        #expect(results.rated)
        let log = try #require(race.log)
        #expect(log.allGoneClose == nil)
        let replayed = try Replayer.replay(log)
        #expect(replayed.isOver && replayed.results == results)
    }

    /// The matchmaker's estimate (#16, #147): the gun, the leader's design time and the window before anyone
    /// starts; the leader's remaining distance at the design pace once she's racing; the close tick after
    /// the first finish.
    @Test func expectedCloseTickProjectsTheLeaderUntilTheFirstFinish() throws {
        let race = testRace(seats: [.human, .human], laps: 1, prestartSeconds: 1, seed: 29)
        let leaderSeconds = race.rules.raceFormat.beatSizing.leaderSeconds
        #expect(race.expectedCloseTick == RulesConfig.ticks(leaderSeconds) + Self.window)
        let w = race.course.targetPosition(for: .round(CourseLayout.windwardIndex))
        try jump(race, to: 3_000) { placeRacing(&$0.seats[0].boat, leg: 0, at: w - race.course.upwind * 20) }
        let pace = race.courseLength / leaderSeconds
        let remaining = race.distanceToFinish(of: race.boats[0])
        #expect(race.expectedCloseTick == 3_000 + RulesConfig.ticks(remaining / pace) + Self.window)
        try jump(race, to: 27_000)
        #expect(race.expectedCloseTick == Self.limit, "capped by the time limit")
        try jump(race, to: 3_000) { placeToFinish(&$0.seats[0].boat, in: race) }
        race.step()
        #expect(race.expectedCloseTick == race.closeTick && race.closeTick == 3_001 + Self.window)
    }
}
