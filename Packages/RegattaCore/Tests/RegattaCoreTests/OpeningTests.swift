import Foundation
import Testing
@testable import RegattaCore

/// What the opening's tests sail (#477): fleet-rules@8, a class, a conditions file on the dev venue, every seat human.
enum OpeningRig {
    static let conditionsIDs = ["classic-oscillating", "sea-breeze", "gusty-offshore", "light-and-patchy"]
    /// The classes Q4 asks for: skiff@9 (steered by hand, the autohelm off a centred rudder) and skiff@6 (whose autohelm
    /// holds the wind angle, so shifts steer her).
    static let classes = [9, 6]
    static let rules8 = try! RulesConfigFile.bundled(id: "fleet-rules", version: 8)
    /// The dev venue whose pairings name the four conditions files at version 7, the newest.
    static let venue = try! VenueFile.bundled(id: "dev-venue", version: 7)

    /// fleet-rules@8 with its opening angle at `degrees` (Step 0's sweep), or as bundled.
    static func rules(angle degrees: Int? = nil) throws -> RulesConfigFile {
        guard let degrees else { return rules8 }
        let data = try #require(try RulesConfigFile.bundledData(id: "fleet-rules", version: 8))
        let text = try #require(String(data: data, encoding: .utf8))
        let field = #""trueWindAngleDegrees": 80"#
        #expect(text.components(separatedBy: field).count == 2)
        return try RulesConfigFile(data: Data(text.replacingOccurrences(of: field, with: #""trueWindAngleDegrees": \#(degrees)"#).utf8))
    }

    /// A race of `fleet` human seats on skiff@`skiff` in `conditions`@7, with a `sequenceSeconds` start sequence.
    static func race(fleet: Int, seed: UInt64, skiff: Int = 9, conditions: String = "classic-oscillating",
                     sequenceSeconds: Int = 60, rules: RulesConfigFile = rules8) throws -> Race {
        let boatClass = try BoatClassFile.bundled(id: "skiff", version: skiff)
        let conditionsFile = try ConditionsFile.bundled(id: conditions, version: 7)
        let setup = try RaceSetup(raceSeed: RaceSeed(seed), seats: Array(repeating: .human, count: fleet), laps: 1,
                                  startSequenceTicks: sequenceSeconds * Race.tickRate, boatClass: boatClass.ref,
                                  venue: venue.ref, conditions: conditionsFile.ref, rulesConfiguration: rules.ref)
        let files = try RaceFiles(boatClass: boatClass, venue: venue, conditions: conditionsFile, rulesConfiguration: rules)
        return try Race(setup: setup, files: files, mode: .authoritative(windSeed: WindSeed(seed &* 7919)))
    }

    /// Hull lengths below the start line or its extensions of the point of `boat`'s hull furthest over it: negative once
    /// any of it is over (OCS by hull, rule 29.1).
    static func depth(_ boat: Boat, in race: Race) -> Double {
        let over = boat.hull(outline: race.boatClass.hull.outline).map(race.course.startLine.side).max()!
        return -over / race.boatClass.hull.length
    }

    /// Whether all of `boat`'s hull is in the race area.
    static func isInside(_ boat: Boat, in race: Race) -> Bool {
        boat.hull(outline: race.boatClass.hull.outline).allSatisfy(race.course.isInRaceArea)
    }

    /// One hands-off race (Q4, Q6): nobody sends anything from seating.
    struct HandsOff {
        var callsIn20s = 0
        /// The least depth (L) any hull had through 30 s from seating, and the first second from seating any was over.
        var leastDepthTo30s = Double.infinity
        var firstOverSeconds: Double?
        var leastDepthAt15s = Double.infinity
        var leastDepthAt30s = Double.infinity
        var allInsideAt15s = true
    }

    static func sailHandsOff(_ race: Race, seconds: Int = 30) -> HandsOff {
        var result = HandsOff()
        let first = race.tick
        while race.tick - first < seconds * Race.tickRate {
            race.step()
            let elapsed = race.tick - first
            let calls = race.drainEvents().filter { if case .ruleCall = $0.kind { true } else { false } }
            if elapsed <= 20 * Race.tickRate { result.callsIn20s += calls.count }
            let least = race.boats.map { depth($0, in: race) }.min()!
            result.leastDepthTo30s = min(result.leastDepthTo30s, least)
            if least < 0, result.firstOverSeconds == nil { result.firstOverSeconds = Double(elapsed) / Double(Race.tickRate) }
            if elapsed == 15 * Race.tickRate {
                result.leastDepthAt15s = least
                result.allInsideAt15s = race.boats.allSatisfy { isInside($0, in: race) }
            }
            if elapsed == 30 * Race.tickRate { result.leastDepthAt30s = least }
        }
        return result
    }
}

/// #477 acceptance, the opening (fleet-rules@8, schema 8): two rows, alternating tacks, the 3 L floor, eased at the trim.
@Suite struct OpeningTests {
    static let rules = OpeningRig.rules8.content
    static let hull = Race.defaultBoatClass.hull.length

    static func course(fleetSize: Int, seed: UInt64, rules: RulesConfig = rules) throws -> CourseLayout {
        CourseLayout.derive(windSetup: try CourseLayoutTests.windSetup(seed: seed), land: [], fleetSize: fleetSize, laps: 2,
                            boatClass: Race.defaultBoatClass, rules: rules)
    }

    @Test func fleetRules8IsTheOpening() {
        let opening = Self.rules.raceFormat.opening
        #expect(opening == .init(rowDepths: [HullLengths(5.5), HullLengths(8.5)], spreadLineLengths: 1.5,
                                 trueWindAngle: deg2rad(80), easeSpeedFraction: 0.5, minimumSpacing: HullLengths(3),
                                 jitter: HullLengths(0.5)))
        #expect(Self.rules.raceFormat.startRow == nil)
        #expect(Self.rules.raceFormat.raceArea.belowLineMinimum == HullLengths(15))
    }

    /// Fleets 2–16 × race seeds 1–200: no two slots closer than 3 L, centre to centre; every depth in [5, 9] L; the tacks
    /// half each (the odd boat on starboard), every port slot deeper than every starboard one; every slot a hull length
    /// inside the race area.
    @Test(arguments: RaceSetup.fleetSizes) func slotsKeepTheFloorAndTheRows(fleetSize n: Int) throws {
        var closest = Double.infinity
        for seed in UInt64(1)...200 {
            let course = try Self.course(fleetSize: n, seed: seed)
            let slots = course.openingSlots(fleetSize: n, raceSeed: RaceSeed(seed), hullLength: Self.hull)
            #expect(slots.count == n)
            for i in slots.indices {
                for j in slots.indices where j > i {
                    closest = min(closest, (slots[i].position - slots[j].position).length / Self.hull)
                }
            }
            let depths = slots.map { -course.startLine.side($0.position) / Self.hull }
            #expect(depths.allSatisfy { (5...9).contains($0) }, "n \(n) seed \(seed): \(depths)")
            let starboard = slots.indices.filter { slots[$0].tack == .starboard }
            let port = slots.indices.filter { slots[$0].tack == .port }
            #expect(starboard.count == (n + 1) / 2 && port.count == n / 2)
            if let deepestStarboard = starboard.map({ depths[$0] }).max(), let shallowestPort = port.map({ depths[$0] }).min() {
                #expect(shallowestPort > deepestStarboard)
            }
            let area = course.raceArea
            for slot in slots {
                let local = slot.position - area.centre
                #expect(abs(local.dot(course.right)) <= area.halfWidth - Self.hull)
                #expect(abs(local.dot(course.upwind)) <= area.halfLength - Self.hull)
            }
            // The tacks alternate along the line, port's half a slot towards the committee end of starboard's.
            let along = slots.map { ($0.position - course.startLine.centre).dot(course.right) }
            let pitch = 1.5 * course.startLine.length / Double((n + 1) / 2)
            for k in port { #expect(abs(along[k] - along[k - 1] - pitch / 2) <= 2 * 0.5 * Self.hull) }
        }
        #expect(closest >= 3 - 1e-9, "fleet \(n): closest pair \(closest) L")
    }

    /// The jitter's radius is the lesser of the cap and half what the grid's closest centres leave over the floor: 0.27 L
    /// at 16 boats (a 3.75 L pitch and 3 L between the rows), the 0.5 L cap at 2.
    @Test func jitterKeepsTheFloorByConstruction() throws {
        func largestJitter(_ n: Int) throws -> Double {
            var largest = 0.0
            for seed in UInt64(1)...200 {
                let course = try Self.course(fleetSize: n, seed: seed)
                let slots = course.openingSlots(fleetSize: n, raceSeed: RaceSeed(seed), hullLength: Self.hull)
                let line = course.startLine
                let span = 1.5 * line.length, pitch = span / Double((n + 1) / 2)
                for (k, slot) in slots.enumerated() {
                    let nominal = line.centre - course.upwind * ((k % 2 == 0 ? 5.5 : 8.5) * Self.hull)
                        + course.right * (pitch * (Double(k / 2) + 0.5 + (k % 2 == 1 ? 0.5 : 0)) - span / 2)
                    largest = max(largest, (slot.position - nominal).length / Self.hull)
                }
            }
            return largest
        }
        let sixteen = try largestJitter(16)
        let expected = (min(3.75, (3.75 * 3.75 / 4 + 9).squareRoot()) - 3) / 2
        #expect(sixteen <= expected + 1e-9 && sixteen > expected * 0.9, "\(sixteen) against \(expected)")
        #expect(abs(expected - 0.27) < 0.005)
        let two = try largestJitter(2)
        #expect(two <= 0.5 + 1e-9 && two > 0.45)
    }

    /// Every seat in her slot, on its heading and tack (boom to port on starboard, to starboard on port), at the trim of
    /// her off-the-plane target there in the base strength, her ease held; the order is the start row's.
    @Test func seatsAreInTheirSlotsEased() throws {
        let race = try OpeningRig.race(fleet: 10, seed: 7)
        let course = race.course
        let opening = try #require(course.opening)
        let slots = course.openingSlots(fleetSize: 10, raceSeed: RaceSeed(7), hullLength: race.boatClass.hull.length)
        let order = CourseLayout.startRowOrder(fleetSize: 10, raceSeed: RaceSeed(7))
        for (seat, boat) in race.boats.enumerated() {
            let slot = slots[order[seat]]
            #expect(boat.position == slot.position && boat.heading == slot.heading)
            #expect(boat.tack == slot.tack)
            #expect(boat.boomSide == (slot.tack == .starboard ? .port : .starboard))
            let towards = slot.tack == .starboard ? race.course.axis - opening.trueWindAngle : race.course.axis + opening.trueWindAngle
            #expect(abs(wrapAngle(boat.heading - towards)) < 1e-12)
            let relative = slot.tack == .starboard ? opening.trueWindAngle : -opening.trueWindAngle
            let target = BoatDynamics.polarTarget(relativeWind: relative, boomSide: boat.boomSide, tws: race.windSetup.baseStrength,
                                                  isPlaning: false, spinnaker: .down, boatClass: race.boatClass)
            #expect(abs(boat.speed - 0.5 * target) < 1e-12)
            #expect(race.heldInputs[seat] == BoatInput(rudder: 0 as Int8, ease: true))
        }
        // Starboard reaches towards the pin, port towards the committee end.
        let pinward = race.course.startLine.pin.position - race.course.startLine.committee.position
        for boat in race.boats {
            let towardsPin = Vec2.heading(boat.heading).dot(pinward) > 0
            #expect(towardsPin == (boat.tack == .starboard))
        }
    }

    /// The trim: before the gun an ease sails the opening's fraction of her target, from the gun the class's (0.3). On
    /// fleet-rules@7 it is the class's all race.
    @Test func theTrimIsTheOpeningsBeforeTheGunOnly() throws {
        let boatClass = Race.defaultBoatClass
        #expect(Self.rules.easeSpeedFraction(boatClass: boatClass, beforeGun: true) == 0.5)
        #expect(Self.rules.easeSpeedFraction(boatClass: boatClass, beforeGun: false) == boatClass.ease.speedFraction)
        #expect(boatClass.ease.speedFraction == 0.3)
        let seven = Race.defaultRulesConfiguration.content
        #expect(seven.raceFormat.opening == nil)
        #expect(seven.easeSpeedFraction(boatClass: boatClass, beforeGun: true) == boatClass.ease.speedFraction)

        let race = try OpeningRig.race(fleet: 2, seed: 3)
        #expect(race.easeSpeedFraction(sailingTick: -1) == 0.5)
        #expect(race.easeSpeedFraction(sailingTick: 0) == 0.3)

        // The dynamics settle an eased boat to the fraction they are given: 0.5 × the target before the gun, 0.3 after.
        let tws = 10 * 0.514444
        let relative = deg2rad(80)
        let target = BoatDynamics.polarTarget(relativeWind: relative, boomSide: .port, tws: tws, isPlaning: false,
                                              spinnaker: .down, boatClass: boatClass)
        for (fraction, expected) in [(Optional(0.5), 0.5), (nil, 0.3)] {
            var state = BoatDynamics.State(heading: -relative, speed: 0.5 * target, boomSide: .port)
            for _ in 0..<(30 * Race.tickRate) {
                state = BoatDynamics.advance(state, control: .init(rudder: 0, ease: true, easeSpeedFraction: fraction),
                                             env: .constant(windDirection: 0, windSpeed: tws), boatClass: boatClass, dt: Race.dt)
                state.heading = -relative
            }
            #expect(abs(state.speed - expected * target) < 1e-3, "\(String(describing: fraction)): \(state.speed / target)")
        }
    }

    /// Hands-off (Q4, Q6, correction 3): every seat human sending nothing, fleets {2, 4, 6, 10, 16} × seeds 1–8, the four
    /// conditions, the 60 s and 75 s sequences. No rule call in the first 20 s; every boat inside the race area at 15 s and
    /// below the line at 15 s and at 30 s from seating; on the 60 s sequence nobody over the line or its extensions before
    /// T−30 (30 s from seating). Online's first-over time is reported, not gated (G4).
    ///
    /// Gated on skiff@9 (the player class) in all four conditions and on skiff@6 in three. skiff@6 in gusty-offshore is
    /// printed, not asserted (Step 0 judged, #477): its autohelm holds the wind angle (ADR 0007), so the ±12° oscillation
    /// and the 8° fan steer her up at the line and the rows into each other; at 80° her shallowest boat is 1.53 L over at
    /// 30 s with 7 rule calls in the first 20 s, and 85° fails the same way, so the angle is not the lever. Making the
    /// autohelm class hands-off-safe there is a class-side change of its own.
    @Test(arguments: OpeningRig.classes, OpeningRig.conditionsIDs)
    func handsOffIsSafe(skiff: Int, conditions: String) throws {
        let gated = !(skiff == 6 && conditions == "gusty-offshore")
        var worst15 = Double.infinity, worst30 = Double.infinity, worstTo30 = Double.infinity
        var calls = 0, outside = 0, overBy30 = 0
        var online: [Double] = []
        for sequence in [60, 75] {
            for fleet in [2, 4, 6, 10, 16] {
                for seed in UInt64(1)...8 {
                    let race = try OpeningRig.race(fleet: fleet, seed: seed, skiff: skiff, conditions: conditions,
                                                   sequenceSeconds: sequence)
                    let run = OpeningRig.sailHandsOff(race)
                    calls += run.callsIn20s
                    if !run.allInsideAt15s { outside += 1 }
                    if sequence == 60, run.firstOverSeconds != nil { overBy30 += 1 }
                    worst15 = min(worst15, run.leastDepthAt15s)
                    worst30 = min(worst30, run.leastDepthAt30s)
                    worstTo30 = min(worstTo30, run.leastDepthTo30s)
                    if sequence == 75, let over = run.firstOverSeconds { online.append(over) }
                    guard gated else { continue }
                    let name = "skiff@\(skiff) \(conditions) \(sequence) s fleet \(fleet) seed \(seed)"
                    #expect(run.callsIn20s == 0, "\(name): \(run.callsIn20s) rule calls in the first 20 s")
                    #expect(run.allInsideAt15s, "\(name): a boat outside the race area at 15 s")
                    #expect(run.leastDepthAt15s > 0, "\(name): over at 15 s (\(run.leastDepthAt15s) L)")
                    #expect(run.leastDepthAt30s > 0, "\(name): over at 30 s (\(run.leastDepthAt30s) L)")
                    if sequence == 60 { #expect(run.firstOverSeconds == nil, "\(name): over before T-30") }
                }
            }
        }
        print("OPENING skiff@\(skiff) \(conditions)\(gated ? "" : " (reported, not gated)"): least depth \(worst15) L at "
              + "15 s, \(worst30) L at 30 s, \(worstTo30) L through 30 s; calls in 20 s \(calls); outside at 15 s \(outside); "
              + "60 s races over by T-30 \(overBy30); online first over "
              + "\(online.isEmpty ? "none by 30 s" : "\(online.min()!) s (\(online.count) races)")")
    }
}

/// #477 Step 0 (observation, not a gate; `OPENING_STEP0=1`): the opening angle against Q4, and a hand tack from the
/// eased wait.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["OPENING_STEP0"] != nil)) struct OpeningStepZero {
    /// The shallowest boat's depth (L) at 15 s and 30 s from seating, hands-off and eased, over fleets {2, 4, 6, 10, 16}
    /// × seeds 1–8 and both sequences, per class, conditions and angle; whether all are inside at 15 s.
    @Test(arguments: [70, 75, 80, 85], OpeningRig.classes) func angleSweep(degrees: Int, skiff: Int) throws {
        let rules = try OpeningRig.rules(angle: degrees)
        do {
            for conditions in OpeningRig.conditionsIDs {
                var at15 = Double.infinity, at30 = Double.infinity, inside = true, calls = 0, overBefore30 = 0
                var strongest = 0.0
                for sequence in [60, 75] {
                    for fleet in [2, 4, 6, 10, 16] {
                        for seed in UInt64(1)...8 {
                            let race = try OpeningRig.race(fleet: fleet, seed: seed, skiff: skiff, conditions: conditions,
                                                           sequenceSeconds: sequence, rules: rules)
                            strongest = max(strongest, race.windSetup.baseStrength / 0.514444)
                            let run = OpeningRig.sailHandsOff(race)
                            at15 = min(at15, run.leastDepthAt15s)
                            at30 = min(at30, run.leastDepthAt30s)
                            inside = inside && run.allInsideAt15s
                            calls += run.callsIn20s
                            if run.firstOverSeconds != nil { overBefore30 += 1 }
                        }
                    }
                }
                print(String(format: "STEP0 angle %d skiff@%d %@ (to %.1f kn): least depth %.2f L at 15 s, %.2f L at 30 s; "
                             + "inside at 15 s %@; calls in 20 s %d; races over by 30 s %d",
                             degrees, skiff, conditions, strongest, at15, at30, inside ? "yes" : "NO", calls, overBefore30))
            }
        }
    }

    /// skiff@9 off the plane at 6 / 10 / 14 / 20 kn: the eased speed at 80° at trims 0.45, 0.5 and 0.6 against the
    /// `canTap` floor (0.75 of close-hauled speed) and the lowered 0.45; then a hand tack from it: sheets in, the rudder
    /// held over at 60 % and 100 % until she is close-hauled on port, centred after. Whether the boom crosses, the
    /// seconds to it, and to 0.9 of close-hauled speed.
    @Test func handTackFromTheEasedWait() throws {
        let boatClass = try BoatClassFile.bundled(id: "skiff", version: 9).content
        let polar = boatClass.polar
        let reach = deg2rad(80)
        for knots in [6.0, 10, 14, 20] {
            let tws = knots * 0.514444
            let closeHauled = polar.bestUpwind(tws: tws)
            let target = BoatDynamics.polarTarget(relativeWind: reach, boomSide: .port, tws: tws, isPlaning: false,
                                                  spinnaker: .down, boatClass: boatClass)
            // Trim 1 is the baseline: the same tack from the reach sheeted in, at her full off-the-plane speed there.
            for trim in [0.45, 0.5, 0.6, 1] {
                // Settle on the eased reach.
                var state = BoatDynamics.State(heading: -reach, speed: trim * target, boomSide: .port)
                for _ in 0..<(20 * Race.tickRate) {
                    state = BoatDynamics.advance(state, control: .init(rudder: 0, ease: trim < 1, easeSpeedFraction: trim),
                                                 env: .constant(windDirection: 0, windSpeed: tws), boatClass: boatClass, dt: Race.dt)
                    state.heading = -reach
                }
                let eased = state.speed
                for rudder in [0.6, 1.0] {
                    var s = state
                    var crossed: Double?, fast: Double?
                    var t = 0.0
                    var holding = true
                    while t < 30, fast == nil {
                        let relative = wrapAngle(0 - s.heading)
                        if holding, s.boomSide == .starboard, -relative >= closeHauled.twa { holding = false }
                        s = BoatDynamics.advance(s, control: .init(rudder: holding ? rudder : 0),
                                                 env: .constant(windDirection: 0, windSpeed: tws), boatClass: boatClass, dt: Race.dt)
                        t += Race.dt
                        if crossed == nil, s.boomSide == .starboard { crossed = t }
                        if crossed != nil, !holding, s.speed >= 0.9 * closeHauled.speed { fast = t }
                    }
                    print(String(format: "STEP0 tack %.0f kn trim %.2f: eased %.2f m/s (floor 0.75 %.2f, 0.45 %.2f, 0.55 %.2f); "
                                 + "rudder %.0f%%: boom crosses %@, 0.9 speed at %@",
                                 knots, trim, eased, 0.75 * closeHauled.speed, 0.45 * closeHauled.speed,
                                 0.55 * closeHauled.speed, rudder * 100,
                                 crossed.map { String(format: "%.1f s", $0) } ?? "never",
                                 fast.map { String(format: "%.1f s", $0) } ?? "not in 30 s"))
                }
            }
        }
    }
}
