import Foundation
import Testing
@testable import RegattaCore

/// Course derivation (#80): the windward–leeward course with an offset mark and a leeward gate.
@Suite struct CourseLayoutTests {
    static let rules = Race.defaultRulesConfiguration.content
    static let boatClass = Race.defaultBoatClass
    static let hull = boatClass.hull.length
    static let conditionsIDs = ["classic-oscillating", "sea-breeze", "gusty-offshore", "light-and-patchy"]

    static func windSetup(_ id: String = "classic-oscillating", seed: UInt64 = 7, meanDirection: Double = deg2rad(10),
                          startLineCentre: Vec2 = Vec2(120, -40)) throws -> WindSetup {
        let file = try ConditionsFile.bundled(id: id, version: 2)
        let pairing = Venue.Pairing(conditions: file.ref.key, meanDirection: meanDirection, trendDirection: .either,
                                    startLineCentre: startLineCentre, geographicGrid: Race.defaultPairing.geographicGrid)
        return WindSetup(conditions: file, pairing: pairing, raceSeed: RaceSeed(seed))
    }

    static func layout(fleetSize: Int = 10, laps: Int = 2, rules: RulesConfig = rules) throws -> CourseLayout {
        CourseLayout.derive(windSetup: try windSetup(), land: [], fleetSize: fleetSize, laps: laps, boatClass: boatClass,
                            rules: rules)
    }

    /// A point `across` metres to the right of the line centre (looking upwind) and `up` metres up the axis.
    static func at(_ course: CourseLayout, across: Double, up: Double) -> Vec2 {
        course.startLine.centre + course.right * across + course.upwind * up
    }

    static func isClose(_ a: Vec2, _ b: Vec2, _ tolerance: Double = 1e-9) -> Bool { (a - b).length <= tolerance }

    // MARK: Line

    @Test func lineLengthIsPerBoatHullLengthsWithAMinimum() throws {
        #expect(abs(try Self.layout(fleetSize: 10).startLine.length - 52.5) < 1e-9)
        #expect(abs(try Self.layout(fleetSize: 2).startLine.length - 42) < 1e-9)
        #expect(abs(try Self.layout(fleetSize: 16).startLine.length - 84) < 1e-9)
    }

    @Test func lineIsSquareToTheAxisWithCommitteeToStarboard() throws {
        let setup = try Self.windSetup()
        let course = try Self.layout()
        #expect(course.axis == setup.meanDirection)
        #expect(Self.isClose(course.startLine.centre, setup.pairing.startLineCentre))
        #expect(abs((course.startLine.committee.position - course.startLine.pin.position).normalized.dot(course.upwind)) < 1e-12)
        #expect((course.startLine.committee.position - course.startLine.centre).dot(course.right) > 0)
        #expect(course.finishLine == course.startLine)
    }

    // MARK: Marks

    @Test func offsetMarkAndGateAreWhereTheRulesPutThem() throws {
        let course = try Self.layout()
        let left = -course.right
        let windward = course.marksOfLeg(.round(CourseLayout.windwardIndex))[0].position
        let offset = course.marksOfLeg(.round(CourseLayout.offsetIndex))[0].position
        #expect(Self.isClose(windward, Self.at(course, across: 0, up: course.beat)))
        #expect(Self.isClose(offset, windward + left * (12 * Self.hull)))

        let gate = course.marksOfLeg(.round(CourseLayout.gateIndex))
        #expect(gate.count == 2)
        let midpoint = (gate[0].position + gate[1].position) / 2
        #expect(Self.isClose(midpoint, course.startLine.centre + course.upwind * (course.beat / 6)))
        #expect(abs((gate[0].position - gate[1].position).length - 42) < 1e-9)
        // Looking downwind, the gate's left mark is on the upwind right.
        #expect((gate[0].position - midpoint).dot(course.right) > 0)
        // The gate marks' rule 18 zones don't intersect.
        #expect((gate[0].position - gate[1].position).length > 2 * course.zoneRadius)
        #expect(course.zoneRadius == Self.rules.zoneRadius(hullLength: Self.hull))
    }

    @Test func finishLegsMarksAreTheFinishLineEnds() throws {
        let course = try Self.layout()
        #expect(course.marksOfLeg(.finish) == [course.finishLine.pin, course.finishLine.committee])
        #expect(course.obstacles.map(\.name)
            == ["windward mark", "offset mark", "gate left", "gate right", "pin", "committee boat"])
    }

    // MARK: Rounding order

    @Test func roundingOrderFollowsLaps() throws {
        let two = try Self.layout(laps: 2)
        #expect(two.legs == [.round(0), .round(1), .round(2), .round(0), .round(1), .finish])
        #expect(two.legs.map(two.name(of:))
            == ["windward mark", "offset mark", "leeward gate", "windward mark", "offset mark", "finish line"])
        let one = try Self.layout(laps: 1)
        #expect(one.legs == [.round(0), .round(1), .finish])
        #expect(one.legs.map(one.name(of:)) == ["windward mark", "offset mark", "finish line"])
    }

    // MARK: Race area

    @Test func raceAreaSpansTheCourseAsTheRulesSay() throws {
        let course = try Self.layout()
        let area = course.raceArea
        let line = course.startLine.length
        #expect(area.axis == course.axis)
        #expect(abs(area.halfWidth - 0.75 * course.beat) < 1e-9)
        #expect(abs((area.centre - course.startLine.centre).dot(course.right)) < 1e-9)
        let alongCentre = (area.centre - course.startLine.centre).dot(course.upwind)
        // One line length below the line …
        #expect(abs((alongCentre - area.halfLength) - -line) < 1e-9)
        // … and a quarter of the beat above the windward mark.
        #expect(abs((alongCentre + area.halfLength) - 1.25 * course.beat) < 1e-9)
        #expect(course.placement == Self.rules.raceFormat.startRow)
        #expect(course.edgeSpeedRetention == Self.rules.raceFormat.edgeSpeedRetention)
    }

    // MARK: Determinism and beat sizing

    @Test func sameInputsGiveAnIdenticalCourse() throws {
        for id in Self.conditionsIDs {
            for seed: UInt64 in [1, 2, 99] {
                let setup = try Self.windSetup(id, seed: seed)
                let a = CourseLayout.derive(windSetup: setup, land: [], fleetSize: 12, laps: 2, boatClass: Self.boatClass,
                                              rules: Self.rules)
                let b = CourseLayout.derive(windSetup: setup, land: [], fleetSize: 12, laps: 2, boatClass: Self.boatClass,
                                              rules: Self.rules)
                #expect(a == b)
            }
        }
    }

    /// #8, #14: across every conditions file's strength range, at its ends and across seeds, the default
    /// two-lap beat stays in [200, 360] m. One lap sizes a longer beat, capped at 360 m.
    @Test func beatStaysInRangeAcrossAllConditionsFiles() throws {
        for id in Self.conditionsIDs {
            let strength = try ConditionsFile.bundled(id: id, version: 2).content.strength
            let steps = 20
            for i in 0...steps {
                let tws = strength.lowerBound + (strength.upperBound - strength.lowerBound) * Double(i) / Double(steps)
                for laps in [1, 2] {
                    let beat = CourseLayout.beat(laps: laps, tws: tws, boatClass: Self.boatClass, rules: Self.rules)
                    #expect(beat >= 200 && beat <= 360, "\(id) at \(knots(metresPerSecond: tws)) kn, \(laps) laps: \(beat) m")
                }
            }
            for seed: UInt64 in 0..<50 {
                let setup = try Self.windSetup(id, seed: seed)
                let course = CourseLayout.derive(windSetup: setup, land: [], fleetSize: 10, laps: 2, boatClass: Self.boatClass,
                                                 rules: Self.rules)
                #expect(course.beat >= 200 && course.beat <= 360)
                #expect(Self.isClose(course.marksOfLeg(.round(0))[0].position,
                                     setup.pairing.startLineCentre + Vec2.heading(setup.meanDirection) * course.beat))
            }
        }
    }

    /// Tuning (#80, #105): the beat-sizing calibration factor stays a listed placeholder in the rules file,
    /// and scales the beat below the cap.
    @Test func calibrationFactorScalesTheBeat() throws {
        #expect(Race.defaultRulesConfiguration.header.placeholders.contains("/raceFormat/beatSizing/calibrationFactor"))
        let tws = metresPerSecond(knots: 6)
        let base = CourseLayout.beat(laps: 2, tws: tws, boatClass: Self.boatClass, rules: Self.rules)
        #expect(base < 360)
        var halved = Self.rules
        halved.raceFormat.beatSizing.calibrationFactor = 0.5
        #expect(abs(CourseLayout.beat(laps: 2, tws: tws, boatClass: Self.boatClass, rules: halved) - base / 2) < 1e-9)
        var tenfold = Self.rules
        tenfold.raceFormat.beatSizing.calibrationFactor = 10
        #expect(CourseLayout.beat(laps: 2, tws: tws, boatClass: Self.boatClass, rules: tenfold) == 360)
    }

    // MARK: Rounding (rule 28)

    @Test func passingThroughTheGateThenRoundingTheLeftMarkAdvances() throws {
        let course = try Self.layout()
        let g = course.beat / 6
        // Looking downwind, the left mark is 21 m to the upwind right: go round it, turning to port.
        let path = [(5.0, g + 30), (5, g - 10), (30, g - 10), (30, g + 30)].map { Self.at(course, across: $0.0, up: $0.1) }
        let after = course.progress(along: path, from: CourseLayout.Progress(legIndex: 2))
        #expect(after == CourseLayout.Progress(legIndex: 3))
    }

    @Test func passingThroughTheGateThenRoundingTheRightMarkAdvances() throws {
        let course = try Self.layout()
        let g = course.beat / 6
        let path = [(5.0, g + 30), (5, g - 10), (-30, g - 10), (-30, g + 30)].map { Self.at(course, across: $0.0, up: $0.1) }
        let after = course.progress(along: path, from: CourseLayout.Progress(legIndex: 2))
        #expect(after == CourseLayout.Progress(legIndex: 3))
    }

    @Test func passingOutsideTheGateDoesNotAdvance() throws {
        let course = try Self.layout()
        let g = course.beat / 6
        // Down outside the left mark, round it, and back up the middle.
        let outside = [(30.0, g + 30), (30, g - 10), (5, g - 10), (5, g + 30)].map { Self.at(course, across: $0.0, up: $0.1) }
        #expect(course.progress(along: outside, from: CourseLayout.Progress(legIndex: 2)).legIndex == 2)
        // Through the gate but not round either mark.
        let through = [(5.0, g + 30), (5, g - 10), (5, g - 60)].map { Self.at(course, across: $0.0, up: $0.1) }
        #expect(course.progress(along: through, from: CourseLayout.Progress(legIndex: 2)) == CourseLayout.Progress(legIndex: 2, stage: 1))
        // Through the gate and back up through it undoes the pass.
        let back = [(5.0, g + 30), (5, g - 10), (5, g + 30)].map { Self.at(course, across: $0.0, up: $0.1) }
        #expect(course.progress(along: back, from: CourseLayout.Progress(legIndex: 2)) == CourseLayout.Progress(legIndex: 2))
    }

    @Test func windwardAndOffsetMarksAreRoundedToPort() throws {
        let course = try Self.layout()
        let b = course.beat
        let o = -12 * Self.hull
        // Up the right of W, across above it to the left of O, down: both left to port.
        let lap = [(5.0, b - 30), (5, b + 10), (o / 2, b + 10), (o - 20, b + 10), (o - 20, b - 30)]
            .map { Self.at(course, across: $0.0, up: $0.1) }
        #expect(course.progress(along: lap, from: CourseLayout.Progress()) == CourseLayout.Progress(legIndex: 2))
        // Up the left of W (leaving it to starboard) doesn't round it.
        let wrongSide = [(-5.0, b - 30), (-5, b + 10), (o - 20, b + 10)].map { Self.at(course, across: $0.0, up: $0.1) }
        #expect(course.progress(along: wrongSide, from: CourseLayout.Progress()).legIndex == 0)
    }

    @Test func crossingTheFinishLineDownwindFinishes() throws {
        let course = try Self.layout(laps: 1)
        let path = [(0.0, 20), (0, -20)].map { Self.at(course, across: $0.0, up: $0.1) }
        #expect(course.progress(along: path, from: CourseLayout.Progress(legIndex: 2)).finished)
    }
}
