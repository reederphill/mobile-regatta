import Foundation
import Testing
import RegattaCore
@testable import RegattaBots

/// #355: the bot suite's hunter (`BotProfile.hunter`), the tactician sailing to the edge of the rules. Two-boat scenes
/// (`BotConductTests`' water and placements), the hunter in seat 0 against a live bot at skill 1 in seat 1: she turns
/// at a boat that must keep clear of her, luffs a windward boat, holds starboard, and never turns faster than rule
/// 16.1's course-change test, so she draws no 16.1 call.
@Suite struct BotProfileTests {
    /// What one scene sailed: its events, and seat 0's headings and seat 1's distance from her, tick by tick, with
    /// whether seat 1 was keeping clear of her then.
    struct Sailed {
        var kinds: [RaceEvent.Kind] = []
        var headings: [Double] = []
        var rudders: [Double] = []
        var gaps: [Double] = []
        /// Whether seat 1 was to her starboard.
        var otherToStarboard: [Bool] = []
        var keepingClear: [Bool] = []
        /// Her tack or gybe on the autohelm's tap (or tacking): a tack is rule 13's, not a course change she steers.
        var tapping: [Bool] = []
        /// Whether she owed seat 1 mark-room (rule 18): she gives it as she would keep clear, at any rate.
        var owesMarkRoom: [Bool] = []
        var sailingAngles: [Double] = []
        var properCourseEdges: [Double?] = []
        var otherSailingAngles: [Double] = []
        var calls: [String] { BotConductTests.calls(kinds) }
    }

    /// Sails `encounter` for its seconds: seat 0 the `profile` (the hunter unless given), seat 1 a live bot.
    static func sail(_ encounter: BotConductTests.Encounter, profile: BotProfile? = .hunter) throws -> Sailed {
        let race = try encounter.race()
        var pilots = [
            BotConductTests.Pilot(seat: 0, plannedTack: encounter.planned[0], race: race, profile: profile),
            BotConductTests.Pilot(seat: 1, plannedTack: encounter.planned[1], race: race),
        ]
        var sailed = Sailed()
        for _ in 0..<Int(encounter.seconds * Double(Race.tickRate)) where !race.isOver {
            for i in pilots.indices { _ = pilots[i].drive(race) }
            race.step()
            sailed.kinds += race.drainEvents().map(\.kind)
            let a = race.boats[0], b = race.boats[1]
            sailed.headings.append(a.heading)
            sailed.rudders.append(a.rudder)
            sailed.gaps.append((b.position - a.position).length)
            sailed.otherToStarboard.append((b.position - a.position).dot(Vec2.heading(a.heading).rightPerp) > 0)
            sailed.keepingClear.append(race.rightOfWay(0, 1)?.keepClear == 1)
            sailed.tapping.append(a.autohelm?.isTapping == true || a.isTacking)
            sailed.owesMarkRoom.append(race.seatView(for: 0).own.markRoom.contains { $0.owing == 0 })
            sailed.sailingAngles.append(a.sailingAngle)
            sailed.otherSailingAngles.append(b.sailingAngle)
            sailed.properCourseEdges.append(race.seatView(for: 0).own.properCourse?.edgeSailingAngle)
        }
        return sailed
    }

    /// Her turn rate never passes rule 16.1's course-change test on any tick she steers with a boat keeping clear of her
    /// (`EscapeSimulation`'s own reading: |Δheading| × tick rate; her tacks on the tap aside), and no 16.1 call is on her.
    static func checkWithinRule16(_ sailed: Sailed, _ name: String) throws {
        let race = try BotConductTests.Water(seed: 1).race
        let changesCourse = try #require(race.rules.incidents.escape.changesCourse)
        // The mirror the brain keeps of it (`BotBrain.Hunter.courseChangeRate`) is the rules file's.
        #expect(abs(BotBrain.Hunter.courseChangeRate - changesCourse) < 1e-9, "\(name)")
        // The tap's full rudder unwinds at the slew rate for a few ticks after it.
        let afterTap = Int((1 / race.boatClass.steering.rudderSlew) * Double(Race.tickRate)) + 1
        // And the right-of-way boat for as long before, so a rudder she held keeping clear herself (rule 12 astern, say)
        // has unwound too.
        let settled = afterTap + 2 * BotDriver.decisionInterval
        for tick in 1..<sailed.headings.count where sailed.keepingClear[tick] && !sailed.owesMarkRoom[tick]
            && !sailed.tapping[max(0, tick - afterTap)...tick].contains(true)
            && !sailed.keepingClear[max(0, tick - settled)...tick].contains(false)
            && sailed.gaps[tick] <= race.boatClass.hull.length * BotBrain.Hunter.rangeLengths {
            let rate = abs(wrapAngle(sailed.headings[tick] - sailed.headings[tick - 1])) * Double(Race.tickRate)
            #expect(rate <= changesCourse, "\(name): turned \(rate * 180 / .pi)°/s at tick \(tick)")
        }
        #expect(!sailed.calls.contains("16.1 on 0"), "\(name): \(sailed.calls)")
    }

    /// Ticks seat 0's rudder turned her towards seat 1 while seat 1 kept clear of her within her hunting range.
    static func huntingTicks(_ sailed: Sailed, length: Double) -> Int {
        sailed.rudders.indices.filter { tick in
            sailed.keepingClear[tick] && abs(sailed.rudders[tick]) > Autohelm.deadBand && !sailed.tapping[tick]
                && (sailed.rudders[tick] > 0) == sailed.otherToStarboard[tick]
                && sailed.gaps[tick] <= length * BotBrain.Hunter.rangeLengths
        }.count
    }

    @Test func hunterAltersCourseTowardsAGiveWayBoatWithinRule16() throws {
        // Running on starboard, overlapped, the live bot to windward and keeping clear (rule 11): holding her course the
        // hunter would leave her be; she turns at her gently instead, and the gap closes, with no 16.1 call on her.
        // Scenes whose tactician gybes away at once leave nothing to hunt, so each scene sails on the first seed whose
        // tactician holds her tack (#404: 3 today), the last on a second wind, the next such seed (6 today). That one
        // starts half a length ahead, overlapped (#377): from a length ahead, on the edge of clear astern, the windward
        // boat's ribbons drifting downwind ahead of her slow the leeward one back clear astern, where rule 12 has her
        // keep clear.
        func scene(_ seed: UInt64, _ abeam: Double, _ ahead: Double) -> BotConductTests.Encounter {
            BotConductTests.windwardLeeward(seed: seed, running: true, abeam: abeam, ahead: ahead, converging: 0)
        }
        func holdsHerTack(_ abeam: Double, _ ahead: Double, after: UInt64 = 0) throws -> UInt64 {
            try firstSeed(in: after + 1...after + 12) { seed in
                try !Self.sail(scene(seed, abeam, ahead), profile: .tactician).tapping[0]
            }
        }
        let first = try holdsHerTack(2.5, 0.5)
        let scenes = [(first, 2.5, 0.5), (try holdsHerTack(3.0, 1.0), 3.0, 1.0),
                      (try holdsHerTack(3.0, 0.5, after: first), 3.0, 0.5)]
        var closer = 0
        for (seed, abeam, ahead) in scenes {
            let encounter = scene(seed, abeam, ahead)
            let hunted = try Self.sail(encounter)
            let held = try Self.sail(encounter, profile: .tactician)
            try Self.checkWithinRule16(hunted, encounter.name)
            let length = try BotConductTests.Water(seed: seed).length
            let ticks = Self.huntingTicks(hunted, length: length), heldTicks = Self.huntingTicks(held, length: length)
            #expect(ticks >= Race.tickRate && ticks > heldTicks, "\(encounter.name): turned at her \(ticks) ticks, held \(heldTicks)")
            // While the windward boat keeps clear of her, she came closer to it than holding her course did.
            let near = Self.nearWhileKeepingClear(hunted), heldNear = Self.nearWhileKeepingClear(held)
            if near < heldNear - 0.5 { closer += 1 }
            #expect(near >= length * BotBrain.Hunter.noCloserLengths * 0.75, "\(encounter.name): she rammed her (\(near) m)")
        }
        // The windward boat answers her (it keeps clear, luffing away), so the gap needn't close every time.
        #expect(closer >= 2, "she came closer than holding her course in \(closer) scenes")
    }

    /// The closest seat 1 came to her while keeping clear of her, before her first tack or gybe.
    static func nearWhileKeepingClear(_ sailed: Sailed) -> Double {
        let end = sailed.tapping.firstIndex(of: true) ?? sailed.tapping.count
        return sailed.gaps.indices.prefix(end).filter { sailed.keepingClear[$0] }.map { sailed.gaps[$0] }.min() ?? .infinity
    }

    @Test func hunterLuffsAWindwardBoat() throws {
        for seed: UInt64 in [1, 2, 3] {
            let encounter = BotConductTests.windwardLeeward(seed: seed, running: false, abeam: 2, ahead: 0, converging: 0)
            let hunted = try Self.sail(encounter)
            try Self.checkWithinRule16(hunted, encounter.name)
            // She luffed: her sailing angle fell below where she started, the windward boat's with it.
            let start = hunted.sailingAngles[0], otherStart = hunted.otherSailingAngles[0]
            let lowest = try #require(hunted.sailingAngles.min())
            #expect(lowest < start - deg2rad(4), "\(encounter.name): she luffed only to \((start - lowest) * 180 / .pi)°")
            #expect(try #require(hunted.otherSailingAngles.min()) < otherStart - deg2rad(2),
                    "\(encounter.name): the windward boat never luffed")
            #expect(!hunted.calls.contains { $0.hasSuffix("on 0") }, "\(encounter.name): \(hunted.calls)")
        }
    }

    @Test func hunterLuffsWithinHerProperCourseFromAstern() throws {
        // Rule 17: overlapped to leeward from clear astern, she luffs no higher than her proper course's edge. She comes up
        // from 1.5 lengths astern, 1.8 to leeward (#377): from 2.5 astern, 1.5 to leeward, she sails in the windward
        // boat's ribbons, which drift to leeward and astern of it, slows to about half her speed and never reaches the
        // overlap. 1.8 is still inside rule 17's two lengths.
        var restricted = 0
        for seed: UInt64 in [1, 2, 3] {
            let encounter = BotConductTests.windwardLeeward(seed: seed, running: false, abeam: 1.8, ahead: 1.5,
                                                            converging: 0, fromAstern: true)
            // Seat 1 comes from astern here: make the hunter that boat, seat 0 the windward live bot.
            let race = try encounter.race()
            var pilots = [
                BotConductTests.Pilot(seat: 0, plannedTack: .starboard, race: race),
                BotConductTests.Pilot(seat: 1, plannedTack: .starboard, race: race, profile: .hunter),
            ]
            var kinds: [RaceEvent.Kind] = []
            for _ in 0..<Int(encounter.seconds * Double(Race.tickRate)) where !race.isOver {
                for i in pilots.indices { _ = pilots[i].drive(race) }
                race.step()
                kinds += race.drainEvents().map(\.kind)
                guard let notice = race.seatView(for: 1).own.properCourse else { continue }
                restricted += 1
                #expect(race.boats[1].sailingAngle >= notice.edgeSailingAngle - deg2rad(0.5),
                        "\(encounter.name): \((notice.edgeSailingAngle - race.boats[1].sailingAngle) * 180 / .pi)° above her edge")
            }
            let calls = BotConductTests.calls(kinds)
            #expect(!calls.contains("17 on 1") && !calls.contains("16.1 on 1"), "\(encounter.name): \(calls)")
        }
        #expect(restricted > 0, "never restricted under rule 17: the scene tests nothing")
    }

    @Test func hunterHoldsStarboardAndForcesTheDuck() throws {
        // On a collision course: the port boat must duck; the hunter never turns away from her, and draws no call.
        var met = 0
        for seed: UInt64 in [1, 2, 3] {
            let encounter = BotConductTests.portStarboard(seed: seed, early: 0, running: false)
            let hunted = try Self.sail(encounter)
            try Self.checkWithinRule16(hunted, encounter.name)
            #expect(!hunted.calls.contains { $0.hasSuffix("on 0") }, "\(encounter.name): \(hunted.calls)")
            let race = try encounter.race()
            let a = race.boats[0], b = race.boats[1]
            // The way away from the port boat: the side she is not on.
            let away: Double = (b.position - a.position).dot(Vec2.heading(a.heading).rightPerp) > 0 ? -1 : 1
            // While the port boat keeps clear of her, before either tacks away.
            let end = hunted.tapping.firstIndex(of: true) ?? hunted.tapping.count
            let turnedAway = hunted.headings.indices.prefix(end).filter { hunted.keepingClear[$0] }
                .map { away * wrapAngle(hunted.headings[$0] - a.heading) }.max() ?? 0
            #expect(turnedAway < deg2rad(3), "\(encounter.name): she turned away \(turnedAway * 180 / .pi)°")
            // Where they met, the port boat ducked: she passed astern of the hunter, not ahead. (One of them may tack
            // away first: then they never meet.)
            let closest = try Self.closest(encounter)
            if closest.gap < 3 * (try BotConductTests.Water(seed: seed).length) {
                met += 1
                #expect(closest.along < 0, "\(encounter.name): the port boat crossed ahead")
            }
        }
        #expect(met >= 2, "they met in \(met) scenes")
    }

    /// How close, in `encounter` with the hunter in seat 0, seat 1 came to her, and how far ahead of her (negative:
    /// astern) seat 1 was then.
    static func closest(_ encounter: BotConductTests.Encounter) throws -> (gap: Double, along: Double) {
        let race = try encounter.race()
        var pilots = [
            BotConductTests.Pilot(seat: 0, plannedTack: encounter.planned[0], race: race, profile: .hunter),
            BotConductTests.Pilot(seat: 1, plannedTack: encounter.planned[1], race: race),
        ]
        var closest = (gap: Double.infinity, along: 0.0)
        for _ in 0..<Int(encounter.seconds * Double(Race.tickRate)) where !race.isOver {
            for i in pilots.indices { _ = pilots[i].drive(race) }
            race.step()
            _ = race.drainEvents()
            let offset = race.boats[1].position - race.boats[0].position
            if offset.length < closest.gap { closest = (offset.length, offset.dot(Vec2.heading(race.boats[0].heading))) }
        }
        return closest
    }

    /// What seat 0 did at the mark in a mark-room scene (`BotConductTests.markRoom`), sailing `profile` against a live
    /// bot outside her: her decisions in the zone with mark-room that hunting made something of (`BotDecision.hunt`),
    /// when she rounded (her leg changed), how near the mark she came before it, and the calls.
    struct Rounding {
        var huntedInZone = 0
        var decisionsInZone = 0
        var roundedTick: Int?
        var nearest = Double.infinity
        var calls: [String] = []
    }

    static func round(_ encounter: BotConductTests.Encounter, mark: Vec2, profile: BotProfile) throws -> Rounding {
        let race = try encounter.race()
        var pilots = [
            BotConductTests.Pilot(seat: 0, plannedTack: encounter.planned[0], race: race, profile: profile),
            BotConductTests.Pilot(seat: 1, plannedTack: encounter.planned[1], race: race),
        ]
        let leg = race.boats[0].legIndex
        var rounding = Rounding()
        var kinds: [RaceEvent.Kind] = []
        for tick in 0..<Int(encounter.seconds * Double(Race.tickRate)) where !race.isOver {
            let own = race.seatView(for: 0).own
            let entitled = own.zone?.isIn == true && own.markRoom.contains { $0.entitled == 0 }
            if let decision = pilots[0].drive(race), entitled {
                rounding.decisionsInZone += 1
                if decision.hunt != nil { rounding.huntedInZone += 1 }
            }
            _ = pilots[1].drive(race)
            race.step()
            kinds += race.drainEvents().map(\.kind)
            let a = race.boats[0]
            if rounding.roundedTick == nil {
                rounding.nearest = min(rounding.nearest, (a.position - mark).length)
                if a.legIndex != leg { rounding.roundedTick = tick }
            }
        }
        rounding.calls = BotConductTests.calls(kinds)
        return rounding
    }

    /// Rule 18: with mark-room she takes all of it. A live bot already does: holding her course against the boat
    /// outside (`holdingCourse`) gives none of it up at the mark, and the hunter rounding with a hold no faster than she
    /// hunts, or hunting the outside boat there, rounded wider and later (#355's findings round: 1.2 to 5.2 m wider). So
    /// in the zone she rounds as the live bot does, and hunts no one: as near the mark as the tactician, no call on her.
    @Test func hunterTakesAllHerMarkRoom() throws {
        let scenes: [(BotConductTests.Encounter, offset: Bool)] = [(1.2, 0.0), (1.2, 0.6), (1.5, -0.6)].map {
            (BotConductTests.markRoom(seed: 19, abeam: $0.0, ahead: $0.1), false)
        } + [1.2, -1.2].map { (BotConductTests.markRoom(seed: 20, abeam: $0, ahead: 0, offsetMark: true), true) }
        var inZone = 0
        for (encounter, offset) in scenes {
            let race = try encounter.race()
            let mark = race.course.elements[offset ? CourseLayout.offsetIndex : CourseLayout.windwardIndex].marks[0].position
            let hunted = try Self.round(encounter, mark: mark, profile: .hunter)
            let held = try Self.round(encounter, mark: mark, profile: .tactician)
            inZone += hunted.decisionsInZone
            #expect(hunted.huntedInZone == 0, "\(encounter.name): hunted \(hunted.huntedInZone) times with mark-room")
            #expect(hunted.roundedTick != nil, "\(encounter.name): never rounded")
            #expect(hunted.nearest <= held.nearest + race.boatClass.hull.length * 0.25,
                    "\(encounter.name): rounded \(hunted.nearest) m off the mark, the tactician \(held.nearest) m")
            #expect(!hunted.calls.contains { $0.hasSuffix("on 0") }, "\(encounter.name): \(hunted.calls)")
        }
        #expect(inZone > 0, "she was never in a zone with mark-room: the scenes test nothing")
    }

    @Test func theHunterIsTheTacticianHunting() {
        for skill in [0.0, 0.5, 1.0] {
            var hunter = Tactics(profile: .hunter, skill: skill)
            #expect(hunter.hunts)
            hunter.hunts = false
            // #355's tactician: #105's run and line tactics are the tactician's alone, not the hunter's.
            var tactician = Tactics(profile: .tactician, skill: skill)
            #expect(tactician.runsToPressure && tactician.gybesOutOfShadow && tactician.startsAtFavouredEnd)
            tactician.runsToPressure = false
            tactician.gybesOutOfShadow = false
            tactician.startsAtFavouredEnd = false
            #expect(hunter == tactician)
        }
        for profile in [nil, BotProfile.baseline, .tactician, .blipTacker] {
            #expect(!Tactics(profile: profile, skill: 1).hunts)
        }
    }

    /// #105 (#222): the executor is the baseline's tactics executed perfectly, rolling every tack and hitting every roll;
    /// the tactician at Club-level execution is the tactician whose rolls hit half the time (rolls only, the ruling).
    @Test func executorAndClubTacticianDifferInExecutionOnly() {
        var executor = Tactics(profile: .executor, skill: 0.9)
        #expect(executor.rollsTacks)
        executor.rollsTacks = false
        #expect(executor == Tactics(profile: .baseline, skill: 0.9))
        #expect(Tactics(profile: .tacticianClubExecution, skill: 0.9) == Tactics(profile: .tactician, skill: 0.9))
        let perfect = BotProfile.executor.weaknesses(skill: 0.9)
        #expect(perfect == BotWeaknesses.none(skill: 0.9))
        #expect(perfect.rollHitRate == 1 && perfect.angleMissRate == 0)
        var club = BotProfile.tacticianClubExecution.weaknesses(skill: 0.9)
        #expect(club.rollHitRate == 0.5)
        club.rollHitRate = 1
        #expect(club == perfect, "only her rolls differ")
    }

    /// #105: the tactician's downwind and start tactics are hers (and the Club-execution tactician's) alone; no other
    /// profile plays them, and a live bot only high in the National band (#366,
    /// `BotTacticsTests.liveTacticsRampMonotonicThroughNational`). Not the hunter: she stays #355's tactician, hunting
    /// (#105 fix round 1).
    @Test func onlyTheTacticianPlaysTheRunAndTheLine() {
        for profile in [BotProfile.tactician, .tacticianClubExecution] {
            let tactics = Tactics(profile: profile, skill: 0.9)
            #expect(tactics.runsToPressure && tactics.gybesOutOfShadow && tactics.startsAtFavouredEnd, "\(profile)")
        }
        for skill in [0.0, 0.5, BotTier.national.skillBand.lowerBound] {
            let tactics = Tactics(profile: nil, skill: skill)
            #expect(!tactics.runsToPressure && !tactics.gybesOutOfShadow && !tactics.startsAtFavouredEnd)
        }
        for profile in [BotProfile.baseline, .blipTacker, .executor, .hunter] {
            for skill in [0.0, 0.5, 1.0] {
                let tactics = Tactics(profile: profile, skill: skill)
                #expect(!tactics.runsToPressure && !tactics.gybesOutOfShadow && !tactics.startsAtFavouredEnd)
            }
        }
    }

    @Test func noBotPlayersRaceHunts() throws {
        // The app's bots: `BotDriver(seat:raceSeed:)` sails no profile.
        for seat in 0..<16 {
            #expect(BotDriver(seat: seat, raceSeed: RaceSeed(7)).profile == nil)
        }
        // And no source outside RegattaBots and the suite names a profile: not the core's other modules, the client's,
        // the server's or the services', nor the app's (`Regatta/`, where the checkout has it: Linux CI mounts only
        // `Packages/`).
        let fm = FileManager.default
        let packages = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let core = packages.appendingPathComponent("RegattaCore/Sources")
        var dirs = try fm.contentsOfDirectory(atPath: core.path).filter { $0 != "RegattaBots" && $0 != "BotSuite" }
            .map { core.appendingPathComponent($0) }
        for package in ["RegattaClient", "RegattaServer", "RegattaServices"] {
            let sources = packages.appendingPathComponent("\(package)/Sources")
            #expect(fm.fileExists(atPath: sources.path), "\(package)'s sources")
            dirs.append(sources)
        }
        let app = packages.deletingLastPathComponent().appendingPathComponent("Regatta")
        if fm.fileExists(atPath: app.path) { dirs.append(app) }
        var scanned = 0
        for path in dirs {
            let dir = path.path
            for name in (try? fm.subpathsOfDirectory(atPath: path.path)) ?? [] where name.hasSuffix(".swift") {
                let text = try String(contentsOf: path.appendingPathComponent(name), encoding: .utf8)
                scanned += 1
                #expect(!text.contains("BotProfile"), "\(dir)/\(name) names BotProfile")
            }
        }
        #expect(scanned > 50, "scanned \(scanned) sources")
    }

    /// #367: a suite profile's weaknesses override (`BotDriver(seat:raceSeed:skill:profile:weaknesses:)`) is what she
    /// sails with, in place of her skill's and profile's; nil is the driver she always was. Sailed: the tactician with
    /// her own weaknesses given as the override logs the same race as with none, and Club-level weaknesses another.
    @Test func weaknessesOverrideApplies() throws {
        let raceSeed = RaceSeed(11)
        let novice = BotWeaknesses(skill: 0.35)
        let overridden = BotDriver(seat: 0, raceSeed: raceSeed, skill: 1, profile: .tactician, weaknesses: novice)
        #expect(overridden.weaknesses == novice)
        #expect(overridden.style == BotDriver(seat: 0, raceSeed: raceSeed, skill: 1, profile: .tactician).style,
                "only her weaknesses change")
        let plain = BotDriver(seat: 0, raceSeed: raceSeed, skill: 1, profile: .tactician, weaknesses: nil)
        #expect(plain.weaknesses == BotProfile.tactician.weaknesses(skill: 1))
        #expect(BotDriver(seat: 0, raceSeed: raceSeed, skill: 0.5, weaknesses: nil).weaknesses == BotWeaknesses(skill: 0.5))

        func sail(seat0 weaknesses: BotWeaknesses?) -> RaceLog? {
            let setup = try! RaceSetup(raceSeed: raceSeed, seats: Array(repeating: .bot, count: 4), laps: 1,
                                       startSequenceTicks: 20 * Race.tickRate)
            let race = Race(setup: setup, windSeed: WindSeed(5))
            var controllers = SeatControllers(setup: setup)
            controllers[0] = .bot(BotDriver(seat: 0, raceSeed: raceSeed, skill: 1, profile: .tactician, weaknesses: weaknesses))
            for _ in 0..<(80 * Race.tickRate) {
                controllers.drive(race)
                race.step()
            }
            return race.log
        }
        let none = sail(seat0: nil)
        #expect(sail(seat0: BotProfile.tactician.weaknesses(skill: 1)) == none, "her own weaknesses as the override: the same race")
        #expect(sail(seat0: novice) != none, "a novice's weaknesses sail another race")
    }
}
