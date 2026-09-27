import Foundation
import Testing
@testable import RegattaCore

/// A two-human race with a 1 s start sequence, stepped to `tick` (by default the tick before the gun),
/// then with seat 0 edited by `place` and let go there: her autohelm engages on the next step, on the angle
/// she sails then (ADR 0007). Seat 1 stays in her slot in the start row, sailing on.
func raceEdited(atTick tick: Int = -1, seed: UInt64 = 5, _ place: (inout Boat, Race) -> Void) throws -> Race {
    let race = testRace(seats: [.human, .human], prestartSeconds: 1, seed: seed)
    while race.tick < tick { race.step() }
    var snapshot = race.exportSnapshot()
    snapshot.seats[0].boat.autohelm = nil
    place(&snapshot.seats[0].boat, race)
    try race.importSnapshot(snapshot)
    return race
}

/// The furthest any point of `seat`'s hull reaches over the start line (its side, `CourseLayout.Line.side`):
/// positive when some of her hull is on the course side of the line or its extensions.
func furthestOver(_ race: Race, seat: Int = 0) -> Double {
    race.boats[seat].hull(outline: race.boatClass.hull.outline).map(race.course.startLine.side).max()!
}

/// Moves `boat` straight up or down the course so the furthest point of her hull is `over` metres over
/// the start line (negative: below it).
func placeOverLine(_ boat: inout Boat, by over: Double, in race: Race) {
    let furthest = boat.hull(outline: race.boatClass.hull.outline).map(race.course.startLine.side).max()!
    boat.position += race.course.upwind * (over - furthest)
}

/// #85 acceptance, the start row (#35): one row parallel to the line, half a line length below it, over
/// 1.5 line lengths, in an order the race seed shuffles, on starboard reaching towards the pin at polar
/// speed; her rudder centred, so the autohelm holds the reach (#219).
@Suite struct StartRowTests {
    /// `boat`'s slot in the start row, 0 at the pin end, from how far along the line she is.
    static func rowSlot(_ boat: Boat, in race: Race) -> Int {
        let span = race.course.placement.spreadLineLengths * race.course.startLine.length
        let along = (boat.position - race.course.startLine.centre).dot(race.course.right) + span / 2
        return Int((along / span * Double(race.boats.count) - 0.5).rounded())
    }

    @Test func rowPlacementMatchesFormula() {
        let race = testRace(opponents: 9, seed: 7)
        let n = race.boats.count, line = race.course.startLine, row = race.course.placement
        #expect(n == 10)
        #expect(race.time == -60)
        #expect(row.depthLineLengths == 0.5 && row.spreadLineLengths == 1.5)
        #expect(row.trueWindAngle == deg2rad(90) && row.polarSpeedFraction == 1)
        let span = 1.5 * line.length
        let polarSpeed = race.boatClass.polar.speed(twa: deg2rad(90), tws: race.windSetup.baseStrength)
        var along: [Double] = []
        for b in race.boats {
            #expect(abs(line.side(b.position) - (-0.5 * line.length)) < 1e-9)
            along.append((b.position - line.centre).dot(race.course.right))
            #expect(b.tack == .starboard)
            #expect(b.boomSide == .port)
            // Reaching towards the pin: 90° off the mean wind, the axis less a right angle.
            #expect(abs(wrapAngle(b.heading - (race.course.axis - .pi / 2))) < 1e-9)
            #expect(abs(wrapAngle(race.windSetup.meanDirection - b.heading) - deg2rad(90)) < 1e-9)
            #expect(abs(b.speed - polarSpeed) < 1e-9)
            #expect(b.rudder == 0 && b.desiredRudder == 0 && b.autohelm == nil)
        }
        let slots = (0..<n).map { -span / 2 + span * (Double($0) + 0.5) / Double(n) }
        for (a, s) in zip(along.sorted(), slots) { #expect(abs(a - s) < 1e-9) }
    }

    @Test func orderIsSeeded() {
        func order(_ seed: UInt64) -> [Int] {
            let race = testRace(opponents: 9, seed: seed)
            return race.boats.map { Self.rowSlot($0, in: race) }
        }
        #expect(order(11) == order(11))
        #expect(order(11) != order(12))
        #expect(order(11).sorted() == Array(0..<10))
        // Our own Fisher–Yates on the race seed's start-row stream, seat s in slot order[s] (ADR 0002).
        var expected = Array(0..<10)
        var rng = SplitMix64(seed: 11, stream: CourseLayout.startRowStream)
        rng.shuffle(&expected)
        #expect(order(11) == expected)
        #expect(CourseLayout.startRowOrder(fleetSize: 10, raceSeed: RaceSeed(11)) == expected)
    }

    /// #35 "clear ahead and clear astern": every pair in the row is clear of the other, at every fleet
    /// size, and every boat is a hull length inside the race area (#82), which reaches only a line length
    /// below the line: the row fits by construction, for the skiff and the dinghy.
    @Test func rowBoatsNeverOverlap() throws {
        let dinghy = try BoatClassFile.bundled(id: Fixtures.classID, version: Fixtures.version).ref
        for boatClass in [RaceFiles.defaults.boatClass.ref, dinghy] {
            for n in RaceSetup.fleetSizes {
                let race = testRace(opponents: n - 1, seed: UInt64(n), boatClass: boatClass)
                #expect(race.time == -60)
                let hull = race.boatClass.hull
                for a in 0..<n {
                    let p = race.boats[a]
                    #expect(race.course.raceArea.inset(p.position) >= hull.length - 1e-9, "\(n) boats: seat \(a)")
                    #expect(p.hull(outline: hull.outline).allSatisfy(race.course.isInRaceArea))
                    for b in (a + 1)..<n {
                        let q = race.boats[b]
                        #expect(Collision.penetration(p.hull(outline: hull.outline), q.hull(outline: hull.outline)) == nil)
                        #expect(Rules.isClearAstern(p, of: q, hull: hull) || Rules.isClearAstern(q, of: p, hull: hull),
                                "\(n) boats: seats \(a) and \(b) overlap")
                    }
                }
                // Unsqueezed: the row as the formula lays it.
                let depths = race.boats.map { -race.course.startLine.side($0.position) }
                #expect(depths.allSatisfy { abs($0 - 0.5 * race.course.startLine.length) < 1e-9 })
            }
        }
    }

    /// A row squeezed off land (#82) keeps neighbours no closer than the rules file's spacing floor
    /// (`startRow.minimumSpacingHullLengths`: fleet-rules@2's 1.25 hull lengths, #85); a schema-1 file
    /// (fleet-rules@1) has none, so its row narrows with its depth. Land under the line's centre that no
    /// squeeze clears leaves every file the tightest row: a twentieth of the depth.
    @Test func squeezedRowKeepsTheRulesFilesSpacing() throws {
        let hull = CourseLayoutTests.hull, n = 16
        let windSetup = try CourseLayoutTests.windSetup()
        func squeezed(_ rules: RulesConfig) -> (spacing: Double, unsqueezed: Double) {
            let open = CourseLayout.derive(windSetup: windSetup, land: [], fleetSize: n, laps: 2,
                                           boatClass: CourseLayoutTests.boatClass, rules: rules)
            let length = open.startLine.length
            func at(_ across: Double, _ below: Double) -> Vec2 {
                CourseLayoutTests.at(open, across: across * length, up: -below * length)
            }
            let land = Venue.LandPolygon(points: [at(-0.05, 0.6), at(0.05, 0.6), at(0.05, 0.01), at(-0.05, 0.01)])
            let course = CourseLayout.derive(windSetup: windSetup, land: [land], fleetSize: n, laps: 2,
                                             boatClass: CourseLayoutTests.boatClass, rules: rules)
            #expect(course.land == [land] && course.startLine == open.startLine)
            let slots = course.startRowSlots(fleetSize: n, hullLength: hull)
            #expect(slots.allSatisfy { abs(-course.startLine.side($0) - 0.05 * 0.5 * length) < 1e-9 })
            let unsqueezed = open.startRowSlots(fleetSize: n, hullLength: hull)
            return ((slots[1] - slots[0]).length, (unsqueezed[1] - unsqueezed[0]).length)
        }

        let v2 = Race.defaultRulesConfiguration.content
        #expect(v2.raceFormat.startRow.minimumSpacing == HullLengths(1.25))
        let floored = squeezed(v2)
        #expect(floored.unsqueezed > 1.25 * hull)
        #expect(abs(floored.spacing - 1.25 * hull) < 1e-9)

        var wider = v2
        wider.raceFormat.startRow.minimumSpacing = HullLengths(1.5)
        #expect(abs(squeezed(wider).spacing - 1.5 * hull) < 1e-9)

        let v1 = try RulesConfigFile.bundled(id: "fleet-rules", version: 1).content
        let unfloored = squeezed(v1)
        #expect(abs(unfloored.unsqueezed - floored.unsqueezed) < 1e-9)
        #expect(abs(unfloored.spacing - 0.05 * unfloored.unsqueezed) < 1e-9)
        #expect(unfloored.spacing < hull)
    }

    /// #219 ruling: every boat starts with her rudder centred, so on the first step her autohelm engages at
    /// her placement wind angle and holds the reach, with nobody steering. In a steady wind from the mean
    /// direction and still water, that angle is exactly the row's.
    @Test func centredRudderHoldsThePlacementWindAngle() throws {
        let setup = try RaceSetup(raceSeed: RaceSeed(7), seats: [.human] + Array(repeating: .bot, count: 9))
        let files = try RaceFiles(resolving: setup)
        let drawn = WindSetup(conditions: files.conditions, pairing: files.pairing, raceSeed: setup.raceSeed)
        let steady = GroundWind(direction: drawn.meanDirection, speed: drawn.baseStrength)
        let race = try Race(setup: setup, files: files, mode: .authoritative(windSeed: WindSeed(7)),
                            current: CurrentField(current: nil, tideStateAtGun: 0), wind: { _ in steady })
        let placementAngle = race.course.placement.trueWindAngle
        let rowHeading = race.course.startRowHeading
        #expect(race.boats.allSatisfy { $0.autohelm == nil })

        race.step()
        let snaps = race.drainEvents().filter { if case .grooveSnap = $0.kind { true } else { false } }
        #expect(snaps.isEmpty, "a reach is no groove: nothing snaps")
        for b in race.boats {
            let held = try #require(b.autohelm?.target.angle, "seat \(b.id) is on the autohelm, holding an angle")
            #expect(abs(held - placementAngle) < 1e-9)
            #expect(b.autohelm?.isTapping == false)
        }

        // Nobody steers for five seconds: every boat holds the reach, on starboard, on the row's heading.
        for _ in 0..<(5 * Race.tickRate) { race.step() }
        for b in race.boats {
            #expect(b.autohelm?.target.angle.map { abs($0 - placementAngle) < 1e-9 } == true)
            #expect(abs(b.sailingAngle - placementAngle) < deg2rad(1), "seat \(b.id)")
            #expect(abs(wrapAngle(b.heading - rowHeading)) < deg2rad(1), "seat \(b.id)")
            #expect(b.tack == .starboard)
            #expect(b.status == .prestart)
        }
    }
}

/// #85 acceptance, OCS by hull (#9, rule 29.1): OCS if any point of her hull is on the course side of
/// the line or its extensions at the gun; cleared once all of it is back on the pre-start side; started
/// when any point crosses the line itself after the gun.
@Suite struct OCSTests {
    @Test func bowOverCentreBelowAtGunIsOCS() throws {
        let bow = Race.defaultBoatClass.hull.outline.map(\.y).max()!
        // Pointing up the course, her bow 0.3 m over (or 0.3 m short of) the line and her centre below:
        // at the line's centre, and off the committee boat's end, over its extension.
        for across in [0.0, 1.0] {
            for over in [0.3, -0.3] {
                let race = try raceEdited { boat, race in
                    let line = race.course.startLine
                    boat.heading = race.course.axis
                    boat.position = line.centre + race.course.right * (across * (line.length / 2 + 5))
                        + race.course.upwind * (over - bow)
                }
                #expect(abs(furthestOver(race) - over) < 1e-9)
                #expect(race.course.startLine.side(race.boats[0].position) < 0)
                race.step()
                #expect(race.tick == 0)
                let events = race.drainEvents().map(\.kind)
                #expect(events.contains(.gun))
                #expect(events.contains(.ocsNotice(recipient: 0)) == (over > 0), "across \(across), over \(over)")
                #expect(!events.contains(.ocsNotice(recipient: 1)))
                #expect(race.boats[0].status == (over > 0 ? .ocs : .prestart))
                #expect(race.boats[1].status == .prestart)
            }
        }
    }

    /// Stern over and centre below at the gun, sailing back: OCS, and returning (rule 21.1), until her
    /// whole hull is back on the pre-start side.
    @Test func sternStillOverStaysOCS() throws {
        // Broad-reaching back down the course on starboard at the line's centre, her stern 0.3 m over it.
        let race = try raceEdited { boat, race in
            boat.heading = race.course.axis + .pi + 0.3
            boat.boomSide = .port
            boat.speed = 3
            boat.position = race.course.startLine.centre
            placeOverLine(&boat, by: 0.3, in: race)
        }
        #expect(abs(furthestOver(race) - 0.3) < 1e-9)
        #expect(race.course.startLine.side(race.boats[0].position) < 0)
        race.step()
        #expect(race.drainEvents().map(\.kind).contains(.ocsNotice(recipient: 0)))
        #expect(race.boats[0].status == .ocs)

        var clearedAt: Int?
        var ticksOver = 0
        for _ in 0..<60 where clearedAt == nil {
            #expect(race.course.isReturning(race.boats[0]))
            race.step()
            let events = race.drainEvents().map(\.kind)
            #expect(race.course.startLine.side(race.boats[0].position) < 0)
            if furthestOver(race) > 0 {
                ticksOver += 1
                #expect(race.boats[0].status == .ocs, "centre below, stern still over at tick \(race.tick)")
                #expect(!events.contains(.cleared(seat: 0)))
            } else {
                #expect(events.contains(.cleared(seat: 0)))
                clearedAt = race.tick
            }
        }
        #expect(ticksOver > 0, "she stays OCS while her stern is over")
        #expect(clearedAt != nil)
        #expect(race.boats[0].status == .prestart)
        #expect(!race.course.isReturning(race.boats[0]))
    }

    @Test func bowCrossingAfterGunStartsThatTick() throws {
        let bow = Race.defaultBoatClass.hull.outline.map(\.y).max()!
        // After the gun, sailing up the course with her bow 1 cm below the line: at its centre, and off the
        // committee boat's end, where she crosses only the line's extension.
        for across in [0.0, 1.0] {
            let race = try raceEdited(atTick: 2) { boat, race in
                let line = race.course.startLine
                boat.heading = race.course.axis
                boat.speed = 3
                boat.position = line.centre + race.course.right * (across * (line.length / 2 + 5))
                    + race.course.upwind * (-0.01 - bow)
            }
            #expect(race.boats[0].status == .prestart)
            #expect(furthestOver(race) < 0)
            race.step()
            let events = race.drainEvents()
            #expect(furthestOver(race) > 0)
            #expect(race.course.startLine.side(race.boats[0].position) < 0, "her centre is still below")
            let started = events.filter { $0.kind == .started(seat: 0) }
            #expect(started.map(\.tick) == (across == 0 ? [race.tick] : []), "across \(across)")
            #expect(race.boats[0].status == (across == 0 ? .racing : .prestart))
        }
    }
}
