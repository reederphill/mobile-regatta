import Foundation
import Testing
import RegattaBots
import RegattaCore
import SpriteKit
import SwiftUI
import UIKit
@testable import Regatta

/// Render fixtures (#62): the committed fixtures load and replay, and a fixture race stands still.
@MainActor @Suite struct RenderFixtureTests {
    /// The UI tests' fixtures folder, read from the host as the app reads it.
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("RegattaUITests/Fixtures")

    @Test func fixtureDriverReplaysEachTruncatedLogOnce() throws {
        let (_, log) = try RenderFixture.load(named: "prestart", in: Self.fixtures)
        _ = try FixtureDriver(log: log, freezeTick: -1500)
        let afterFirst = FixtureDriver.replayCount
        _ = try FixtureDriver(log: log, freezeTick: -1500)
        #expect(FixtureDriver.replayCount == afterFirst)
    }

    @Test func committedFixturesLoadAndReplayToTheirFreezeTick() throws {
        let (fixture, log) = try RenderFixture.load(named: "prestart", in: Self.fixtures)
        #expect(fixture == RenderFixture(log: "prestart.racelog.json", freezeTick: -1500, camera: .boat, vision: .none))
        let driver = try FixtureDriver(log: log, freezeTick: fixture.freezeTick)
        #expect(driver.currentFrame.tick == -1500)
        #expect(driver.currentFrame.boats.count == 8)

        let (moved, _) = try RenderFixture.load(named: "prestart-moved", in: Self.fixtures)
        let later = try FixtureDriver(log: log, freezeTick: moved.freezeTick)
        #expect(later.currentFrame.tick == moved.freezeTick)
        #expect(later.currentFrame.tick > driver.currentFrame.tick)
        // The fleet, your boat included, has moved on: the moved fixture draws a different picture.
        let moves = zip(driver.currentFrame.boats, later.currentFrame.boats).map { ($0.position - $1.position).length }
        #expect(moves[driver.myBoatIndex] > 1, "your boat moved \(moves[driver.myBoatIndex]) m")
        #expect(moves.filter { $0 > 1 }.count >= moves.count / 2, "boats moved \(moves) m")
    }

    /// Freezing at a tick is the same race as replaying the log cut off there.
    @Test func theFreezeTickIsTheLogReplayedToIt() throws {
        let (_, log) = try RenderFixture.load(named: "prestart", in: Self.fixtures)
        var cut = log
        cut.inputs.removeAll { $0.tick > -1600 }
        cut.finalTick = -1600
        let replayed = try Replayer.replay(cut, requireMatchingVersion: false)
        let frozen = try FixtureDriver(log: log, freezeTick: -1600)
        #expect(frozen.currentFrame.boats.map(\.position) == replayed.boats.map(\.position))
    }

    @Test func aFixtureRaceStandsStill() throws {
        let (_, log) = try RenderFixture.load(named: "prestart", in: Self.fixtures)
        let driver = try FixtureDriver(log: log, freezeTick: -1500)
        let before = driver.renderWorld
        #expect(driver.isFrozen)
        #expect(!driver.isPausable)
        #expect(driver.tick(5).isEmpty)
        driver.submit(BoatInput(rudder: 1.0))
        #expect(!driver.tap(.tackGybe))
        #expect(driver.drainEvents().isEmpty)
        let after = driver.renderWorld
        #expect(after.frame.tick == -1500)
        #expect(after.time == before.time)
        #expect(after.boats.map(\.position) == driver.currentFrame.boats.map(\.position))
        #expect(!PracticeDriver(config: RaceDriverTests.config).isFrozen)
    }

    @Test func aFreezeTickOutsideTheLogIsRefused() throws {
        let (_, log) = try RenderFixture.load(named: "prestart", in: Self.fixtures)
        #expect(throws: FixtureDriver.FixtureError.self) { try FixtureDriver(log: log, freezeTick: log.finalTick + 1) }
        #expect(throws: FixtureDriver.FixtureError.self) { try FixtureDriver(log: log, freezeTick: -1801) }
    }

    @Test func loadingNeedsTheFixturesDirectory() {
        #expect(throws: RenderFixture.LoadError.self) { try RenderFixture.load(named: "prestart", environment: [:]) }
        #expect(throws: RenderFixture.LoadError.self) {
            try RenderFixture.load(named: "no-such-fixture", environment: [RenderFixture.directoryVariable: Self.fixtures.path])
        }
        #expect(throws: Never.self) {
            try RenderFixture.load(named: "prestart", environment: [RenderFixture.directoryVariable: Self.fixtures.path])
        }
    }

    @Test func aFixtureSessionSetsTheSceneUp() throws {
        let loaded = try RenderFixture.load(named: "prestart", in: Self.fixtures)
        var fixture = loaded.fixture
        fixture.camera = .course
        fixture.vision = .deuteranopia
        let session = try GameSession(fixture: fixture, log: loaded.log)
        #expect(session.driver.isFrozen)
        #expect(session.scene.cameraOverride == .northUpCourse)
        #expect(session.vision == .deuteranopia)
        // The race view draws the filter, not the scene (`RaceViewVisionTests`).
        #expect(session.scene.filter == nil && !session.scene.shouldEnableEffects)
    }

    /// The HUD fixtures (#114) are what their names say: before the gun, racing, OCS, a mark-room notice, and after
    /// the first finish with the countdown to the close. Each draws the HUD over the scene; every older fixture
    /// draws the scene alone, so its reference doesn't move.
    @Test func hudFixturesShowWhatTheyAreFor() throws {
        func hud(_ name: String) throws -> (fixture: RenderFixture, session: GameSession) {
            let (fixture, log) = try RenderFixture.load(named: name, in: Self.fixtures)
            #expect(fixture.hud != nil, "\(name)")
            let session = try GameSession(fixture: fixture, log: log)
            #expect(session.showsFixtureHUD, "\(name)")
            return (fixture, session)
        }
        let prestart = try hud("hud-prestart").session
        #expect(prestart.hud.clock < 0 && prestart.hud.status == .prestart && prestart.notice == nil)
        #expect(HUDModel(prestart.hud).clockTone == .yellow && HUDModel(prestart.hud).placeText == nil)

        let racing = try hud("hud-racing").session
        #expect(racing.hud.status == .racing && racing.hud.closeTick == nil && racing.notice == nil)
        #expect(HUDModel(racing.hud).clockTone == .white)

        let ocs = try hud("hud-ocs").session
        #expect(ocs.hud.status == .ocs, "the fixture's seat is OCS at its tick: \(ocs.hud.status)")
        #expect(HUDModel(ocs.hud).placeText == "OCS" && ocs.notice?.kind == .ocs)

        let markRoom = try hud("hud-markroom").session
        #expect(markRoom.notice?.kind == .markRoom && markRoom.notice?.expires == .distantFuture)

        let finish = try hud("hud-afterfirstfinish").session
        let close = try #require(finish.hud.closeTick, "a boat has finished at the fixture's tick")
        #expect(finish.hud.tick < close)
        #expect(HUDModel(finish.hud).clockTone == .yellow && HUDModel(finish.hud).clockText.hasPrefix("-"))
        #expect(finish.hud.boats.contains(where: \.isGhost) && finish.hud.boats.contains(where: \.isBot))

        for name in ["prestart", "fleet", "water-light-and-patchy", "course-up", "boat-up"] {
            let (fixture, log) = try RenderFixture.load(named: name, in: Self.fixtures)
            #expect(fixture.hud == nil, "\(name)")
            #expect(try !GameSession(fixture: fixture, log: log).showsFixtureHUD, "\(name)")
        }
    }

    /// `hud-hint-leader` (#129) shows the red-glow hint for good, with the rule cues on: its leader goes to the boat
    /// with the strongest red glow (one you must keep clear of), close by and inside the clear part of the view, so
    /// the reference shows the glow the hint names.
    @Test func hintFixtureShowsAHintWithItsLeader() throws {
        let (fixture, log) = try RenderFixture.load(named: "hud-hint-leader", in: Self.fixtures)
        #expect(fixture.ruleCues == true && fixture.hud?.hint == .redGlow)
        let session = try GameSession(fixture: fixture, log: log)
        SKView(frame: CGRect(x: 0, y: 0, width: 402, height: 874)).presentScene(session.scene)
        session.scene.update(0)
        let notice = try #require(session.notice)
        #expect(notice.kind == .hint && notice.expires == .distantFuture)
        #expect(notice.text == HintCatalogue.hint(.redGlow).text.halves)
        guard case .boat(let seat)? = notice.leader else {
            Issue.record("no boat leader: \(String(describing: notice.leader))")
            return
        }
        let world = session.driver.renderWorld
        #expect(seat != world.myBoatIndex)
        let glows = session.scene.shownGlows
        let glow = try #require(glows.indices.contains(seat) ? glows[seat] : nil)
        #expect(glow.kind == .giveWay && glow.intensity >= HintTuning.standard.glowIntensity, "\(glow)")
        let hulls = (world.boats[seat].position - world.me.position).length / world.boatClass.hull.length
        #expect(hulls < 10, "the leader's boat is \(hulls) hulls away")
        // The line shows only when its target projects inside the visible rect (`HintLeader.segment`).
        #expect(session.scene.showsHintLeader)
    }

    /// The rule-cue fixtures (#123) through every filter, on the fleet's log (#377: your port-starboard call on the first
    /// beat): `rules-call` draws two rule-call lines, the arc counting your started turn's complete deadline and glows;
    /// `rules-penalty` your unstarted turn's arc, both glows and the HUD's live Turn notice. Both show a backwind wedge
    /// (#377). Every older fixture draws no rule cue, so its reference doesn't move.
    @Test func ruleFixturesShowTheRuleCues() throws {
        func session(_ name: String) throws -> GameSession {
            let (fixture, log) = try RenderFixture.load(named: name, in: Self.fixtures)
            let session = try GameSession(fixture: fixture, log: log)
            SKView(frame: CGRect(x: 0, y: 0, width: 402, height: 874)).presentScene(session.scene)
            session.scene.update(0)
            return session
        }
        for vision in VisionFilter.allCases {
            let suffix = vision == .none ? "" : "-\(vision.rawValue)"
            let (call, _) = try RenderFixture.load(named: "rules-call" + suffix, in: Self.fixtures)
            let (penalty, _) = try RenderFixture.load(named: "rules-penalty" + suffix, in: Self.fixtures)
            #expect(call.vision == vision && penalty.vision == vision && call.ruleCues == true && penalty.ruleCues == true)
            #expect(call.freezeTick == 4880 && penalty.freezeTick == 4690)
        }

        let call = try session("rules-call")
        #expect(call.scene.ruleCueSummary.hasSuffix("lines=2 arc=1"), "\(call.scene.ruleCueSummary)")
        #expect(call.scene.shownGlows.contains { $0?.kind == .giveWay })
        #expect(!call.showsFixtureHUD, "no HUD in this fixture")
        let calls = call.ruleCalls.active(at: call.driver.currentFrame.time, seconds: 8, fadeSeconds: 1.5)
        #expect(calls.map(\.badge) == ["21.2", "10"])
        #expect(Self.wedgesOnScreen(call.scene) >= 1, "no backwind wedge in view")

        let penalty = try session("rules-penalty")
        #expect(penalty.scene.ruleCueSummary.hasSuffix("lines=1 arc=1"), "\(penalty.scene.ruleCueSummary)")
        #expect(penalty.scene.shownGlows.contains { $0?.kind == .giveWay })
        #expect(penalty.scene.shownGlows.contains { $0?.kind == .hasRight })
        #expect(penalty.showsFixtureHUD)
        #expect(penalty.notice?.kind == .penalty && penalty.notice?.text == "Turn · 20s / 40s")
        #expect(Self.wedgesOnScreen(penalty.scene) >= 1, "no backwind wedge in view")

        for name in ["prestart", "fleet", "cues", "hud-prestart", "hud-racing"] {
            let older = try session(name)
            #expect(older.scene.ruleCueSummary == "glows=0 lines=0 arc=0", "\(name)")
            #expect(older.notice?.kind != .penalty, "\(name)")
        }
    }

    /// The live leaderboard fixtures (#268): compact through every filter, and tapped open, on `hud-racing`'s tick.
    /// The board is opt-in, so #114's HUD fixtures draw without it and keep their references.
    @Test func leaderboardFixturesShowTheBoard() throws {
        let (compact, log) = try RenderFixture.load(named: "hud-leaderboard", in: Self.fixtures)
        let session = try GameSession(fixture: compact, log: log)
        #expect(session.controls.showsLeaderboard && !session.isLeaderboardExpanded)
        let board = session.hud.leaderboard
        #expect(board.isVisible)
        let lines = board.entries(expanded: false).map { entry -> String in
            switch entry {
            case .row(let row): "\(row.place):\(row.gap.text)\(row.isMe ? "*" : "")"
            case .separator: "sep"
            }
        }
        // The log's own seat, 4th of 6 at the tick: the leader, a skip, the boat ahead, you and the boat behind.
        #expect(lines == ["1:Leader", "sep", "3:+32 m", "4:+72 m*", "5:+84 m"])

        for vision in VisionFilter.allCases where vision != .none {
            let (fixture, _) = try RenderFixture.load(named: "hud-leaderboard-\(vision.rawValue)", in: Self.fixtures)
            var expected = compact
            expected.vision = vision
            #expect(fixture == expected, "\(vision)")
        }
        let (expanded, _) = try RenderFixture.load(named: "hud-leaderboard-expanded", in: Self.fixtures)
        var expected = compact
        expected.hud?.leaderboard = .expanded
        #expect(expanded == expected)
        let open = try GameSession(fixture: expanded, log: log)
        #expect(open.isLeaderboardExpanded)
        open.refreshHUD()
        #expect(open.isLeaderboardExpanded, "a frozen fixture's board stays open")

        for name in ["hud-prestart", "hud-racing", "hud-ocs", "hud-markroom", "hud-afterfirstfinish"] {
            let (fixture, log) = try RenderFixture.load(named: name, in: Self.fixtures)
            #expect(try !GameSession(fixture: fixture, log: log).controls.showsLeaderboard, "\(name)")
        }
    }

    /// The reference diffs cover every filter (#111): each has a fixture, the prestart one seen through it.
    @Test func everyVisionFilterHasAPrestartFixture() throws {
        let (prestart, _) = try RenderFixture.load(named: "prestart", in: Self.fixtures)
        for vision in VisionFilter.allCases {
            let name = vision == .none ? "prestart" : "prestart-\(vision.rawValue)"
            let (fixture, _) = try RenderFixture.load(named: name, in: Self.fixtures)
            var expected = prestart
            expected.vision = vision
            #expect(fixture == expected, "\(name)")
        }
    }

    /// The water fixtures (#116) sail the fun-pass files (#233: dev-venue@3 and the conditions' @3) and freeze
    /// where the water has something to show from the boat camera: a puff and a lull in view. Each greyscale twin
    /// is the same frame.
    @Test func waterFixturesShowWhatTheyAreFor() throws {
        let venue = try VenueFile.bundled(id: "dev-venue", version: 3).ref
        for (name, conditions) in [("water-light-and-patchy", "light-and-patchy"), ("water-gusty-offshore", "gusty-offshore")] {
            let (fixture, log) = try RenderFixture.load(named: name, in: Self.fixtures)
            #expect(fixture.camera == .boat && fixture.vision == VisionFilter.none, "\(name)")
            let setup = log.header.setup
            let file = try ConditionsFile.bundled(id: conditions, version: 3)
            #expect(setup.venue == venue, "\(name)")
            #expect(setup.conditions == file.ref, "\(name)")
            let world = try FixtureDriver(log: log, freezeTick: fixture.freezeTick).renderWorld
            // The boat camera at the default zoom on iPhone 17 (402 x 874 points, scale 1/0.8), in metres.
            let me = world.me
            let center = me.position + me.velocity * 2
            let half = Vec2(402, 874) * 1.25 / 2 / Double(GameScene.pointsPerMeter)
            let inView = world.puffs.filter { puff in
                let outside = Vec2(max(abs(puff.center.x - center.x) - half.x, 0), max(abs(puff.center.y - center.y) - half.y, 0))
                return outside.length < puff.radius && abs(puff.intensity) > 0.1
            }
            #expect(inView.contains { $0.intensity > 0 } && inView.contains { $0.intensity < 0 },
                    "\(name): \(inView.map(\.intensity))")
            let (grey, _) = try RenderFixture.load(named: "\(name)-greyscale", in: Self.fixtures)
            var expected = fixture
            expected.vision = .greyscale
            #expect(grey == expected)
        }
    }

    /// The fleet fixture (#117) is a bot race recorded on skiff@6, the default class (re-recorded on seed 19 for #377, so
    /// the references draw its backwind wedge; a log replays on the class it names, so it stays skiff@6 when the default
    /// moves on), frozen after the first finish and before the close, with a ghost, at least three racing boats and a
    /// backwind wedge in the boat camera's view; its five twins are the same frame through each other filter.
    @Test func fleetFixtureShowsAGhostAmongTheFleet() throws {
        let (fixture, log) = try RenderFixture.load(named: "fleet", in: Self.fixtures)
        #expect(fixture.camera == .boat && fixture.vision == VisionFilter.none)
        // Its recorded class, the default when it was recorded (#377). Re-recording it on a later default moves every
        // fleet, cues, hud and rules reference that shares it, which is the owner's call (#354).
        #expect(log.header.setup.boatClass.id == "skiff" && log.header.setup.boatClass.version == 6)
        let world = try FixtureDriver(log: log, freezeTick: fixture.freezeTick).renderWorld
        #expect(!world.frame.isOver)
        #expect(!world.isGhost(ofSeat: world.myBoatIndex))
        let me = world.me
        let center = me.position + me.velocity * 2
        let half = Vec2(402, 874) * 1.25 / 2 / Double(GameScene.pointsPerMeter)
        let inView = world.boats.indices.filter { seat in
            let p = world.boats[seat].position
            return abs(p.x - center.x) < half.x && abs(p.y - center.y) < half.y
        }
        #expect(inView.filter { world.isGhost(ofSeat: $0) }.count >= 1, "\(inView)")
        #expect(inView.filter { !world.isGhost(ofSeat: $0) }.count >= 3, "\(inView)")
        let (scene, _) = try DrawOrderTests.scene(fixture: "fleet")
        #expect(Self.wedgesOnScreen(scene) >= 1, "no backwind wedge in view")
        for vision in VisionFilter.allCases where vision != .none {
            let (twin, _) = try RenderFixture.load(named: "fleet-\(vision.rawValue)", in: Self.fixtures)
            var expected = fixture
            expected.vision = vision
            #expect(twin == expected, "\(vision)")
        }
    }

    /// The pressure fixture (#289) sails the latest files with a pressure field (dev-venue@6, gusty-offshore@6)
    /// on the course camera, so the whole field shows, water and minimap, after the gun with lanes alive.
    @Test func pressureFixtureShowsThePressure() throws {
        let (fixture, log) = try RenderFixture.load(named: "water-pressure", in: Self.fixtures)
        #expect(fixture == RenderFixture(log: "water-pressure.racelog.json", freezeTick: 60, camera: .course, vision: .none))
        let setup = log.header.setup
        #expect(setup.venue == (try VenueFile.bundled(id: "dev-venue", version: 6)).ref)
        #expect(setup.conditions == (try ConditionsFile.bundled(id: "gusty-offshore", version: 6)).ref)
        let world = try FixtureDriver(log: log, freezeTick: fixture.freezeTick).renderWorld
        let reading = try #require(world.windSampler?.pressureReading)
        #expect(!reading.lanes.isEmpty && reading.side != 0)
    }

    /// The camera fixtures (#113) draw the race camera, auto zoom on: course-up over the prestart log, whose course
    /// axis is 9° off north (as far off as a shipped venue's gets), and boat-up over the light and patchy log, your
    /// boat heading 57° west of north. Every other fixture keeps its
    /// north-up camera from before #113, and its reference.
    @Test func cameraFixturesDrawTheRaceCamera() throws {
        let (courseUp, log) = try RenderFixture.load(named: "course-up", in: Self.fixtures)
        #expect(courseUp == RenderFixture(log: "prestart.racelog.json", freezeTick: -1500, camera: .boat, vision: .none,
                                          view: .courseUp))
        #expect(courseUp.cameraMode == .courseUp)
        let world = try FixtureDriver(log: log, freezeTick: courseUp.freezeTick).renderWorld
        // Every shipped venue's mean wind is within 10° of north, so 9° is about as far off as a real course gets:
        // a turn the wrong way would tilt the start line and course by twice that in the reference.
        #expect(abs(world.course.axis) > 8 * .pi / 180, "axis \(world.course.axis * 180 / .pi)°")
        let session = try GameSession(fixture: courseUp, log: log)
        #expect(session.scene.cameraOverride == .courseUp)

        let (boatUp, _) = try RenderFixture.load(named: "boat-up", in: Self.fixtures)
        #expect(boatUp == RenderFixture(log: "water-light-and-patchy.racelog.json", freezeTick: 30, camera: .boat,
                                        vision: .none, view: .boatUp))
        #expect(boatUp.cameraMode == .boatUp)
        let (_, boatLog) = try RenderFixture.load(named: "boat-up", in: Self.fixtures)
        let sailing = try FixtureDriver(log: boatLog, freezeTick: boatUp.freezeTick).renderWorld
        // Her heading is far enough off the axis that boat-up and course-up draw different pictures.
        #expect(abs(wrapAngle(sailing.me.heading - sailing.course.axis)) > 30 * .pi / 180)

        for name in ["prestart", "prestart-moved", "water-light-and-patchy", "water-gusty-offshore", "water-pressure"] {
            let (fixture, _) = try RenderFixture.load(named: name, in: Self.fixtures)
            #expect(fixture.view == nil, "\(name)")
            #expect([.northUpFollow, .northUpCourse].contains(fixture.cameraMode), "\(name)")
        }
    }

    /// The chart fixtures (#115): each new venue's first pairing (conditions@7), eight boats frozen in the sequence
    /// (the windward mark and line orange, the rest grey), drawn north up over the whole course and race area, plain
    /// and through tritanopia. Each frame holds what it's for: the race-area boundary; land for Hollin Bay and
    /// Fellmere; tinted shallows for Saltings Reach, the only venue with a current; and every landmark.
    @Test func chartFixturesShowWhatTheyAreFor() throws {
        for venueID in ["hollin-bay", "saltings-reach", "fellmere"] {
            let name = "chart-\(venueID)"
            let (fixture, log) = try RenderFixture.load(named: name, in: Self.fixtures)
            #expect(fixture == RenderFixture(log: "\(name).racelog.json", freezeTick: -1500, camera: .course,
                                             vision: .none, view: .area), "\(name)")
            #expect(fixture.cameraMode == .northUpArea)
            let venue = try VenueFile.bundled(id: venueID, version: 1)
            let setup = log.header.setup
            #expect(setup.venue == venue.ref, "\(name)")
            #expect(setup.conditions.key == venue.content.pairings[0].conditions, "\(name)")
            #expect(setup.seats.count == 8, "\(name)")
            let (tritanopia, _) = try RenderFixture.load(named: "\(name)-tritanopia", in: Self.fixtures)
            var expected = fixture
            expected.vision = .tritanopia
            #expect(tritanopia == expected, "\(name)")

            let (scene, _) = try DrawOrderTests.scene(fixture: name)
            #expect(scene.driver.renderWorld.me.status == .prestart)
            func inView(_ p: Vec2) -> Bool {
                let q = scene.rig.project(p, sceneSize: scene.size)
                return (0...scene.size.width).contains(q.x) && (0...scene.size.height).contains(q.y)
            }
            let course = scene.driver.course
            #expect(course.raceArea.corners.allSatisfy(inView), "\(name): the boundary isn't all in view")
            #expect(venue.content.landmarks.map(\.position).allSatisfy(inView), "\(name): a landmark is out of view")
            // Points across the view (north up), every 10 m.
            let ppm = Double(GameScene.pointsPerMeter), scale = Double(scene.rig.cameraScale)
            let centre = Vec2(Double(scene.rig.center.x), Double(scene.rig.center.y)) / ppm
            let half = Vec2(Double(scene.size.width), Double(scene.size.height)) * scale / 2 / ppm
            let samples = stride(from: centre.x - half.x, through: centre.x + half.x, by: 10).flatMap { x in
                stride(from: centre.y - half.y, through: centre.y + half.y, by: 10).map { Vec2(x, $0) }
            }.filter(inView)
            #expect(samples.count > 1000, "\(name)")
            if venueID != "saltings-reach" {
                #expect(samples.contains(where: venue.content.isLand), "\(name): no land in view")
            } else {
                let current = try #require(venue.content.current)
                let grid = current.grid
                let shallow = (0..<grid.columns).flatMap { c in (0..<grid.rows).map { (c, $0) } }.filter { c, r in
                    ChartGeometry.shallowsWeight(depth: current.depth(column: c, row: r), maxDepth: current.maxDepth,
                                                 fraction: ChartStyle.standard.shallowFraction) > 0.5
                        && inView(grid.position(column: c, row: r)) && !venue.content.isLand(grid.position(column: c, row: r))
                }
                #expect(!shallow.isEmpty, "\(name): no shallows in view")
            }
        }
    }

    /// How many backwind wedges (#377) `scene` draws at half strength or more with their stern corner on screen: a boat
    /// sailing upwind with her sail working.
    static func wedgesOnScreen(_ scene: GameScene) -> Int {
        guard let effects = scene.childNode(withName: "//effects") else { return 0 }
        let full = CGFloat(scene.boatStyle.coneAlpha * scene.boatStyle.backwindShare)
        let ppm = Double(GameScene.pointsPerMeter)
        return effects.children.compactMap { $0 as? SKSpriteNode }.filter { wedge in
            guard !wedge.isHidden, wedge.alpha >= full / 2 else { return false }
            let p = scene.rig.project(Vec2(Double(wedge.position.x), Double(wedge.position.y)) / ppm, sceneSize: scene.size)
            return (0...scene.size.width).contains(p.x) && (0...scene.size.height).contains(p.y)
        }.count
    }

    @Test func fixtureFieldsDecodeEveryCameraAndVision() throws {
        for camera in LaunchOptions.CameraMode.allCases {
            for vision in VisionFilter.allCases {
                let json = #"{"log":"x.json","freezeTick":3,"camera":"\#(camera.rawValue)","vision":"\#(vision.rawValue)"}"#
                let fixture = try JSONDecoder().decode(RenderFixture.self, from: Data(json.utf8))
                #expect(fixture == RenderFixture(log: "x.json", freezeTick: 3, camera: camera, vision: vision))
            }
        }
    }
}

@MainActor @Suite struct VisionFilterTests {
    static func close(_ a: [Double], _ b: [Double], within tolerance: Double = 0.002) -> Bool {
        zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
    }

    @Test func noneIsTheIdentity() {
        #expect(VisionFilter.none.apply([0.2, 0.5, 0.9]) == [0.2, 0.5, 0.9])
    }

    /// The dichromacy and greyscale matrices keep white white and black black, so only hue is lost.
    @Test func colourVisionFiltersKeepWhiteAndBlack() {
        for filter in [VisionFilter.deuteranopia, .protanopia, .tritanopia, .greyscale] {
            #expect(Self.close(filter.apply([1, 1, 1]), [1, 1, 1]), "\(filter) moves white")
            #expect(filter.apply([0, 0, 0]) == [0, 0, 0], "\(filter) moves black")
        }
    }

    /// Red and green lose what tells them apart without red or green cones: the red-green opponent signal
    /// (r - g) between them collapses. (Protanopia also darkens red, so lightness still differs.)
    @Test func redAndGreenConvergeForRedGreenDichromacy() {
        let red = [0.8, 0.2, 0.2], green = [0.3, 0.6, 0.2]
        func opponent(_ c: [Double]) -> Double { c[0] - c[1] }
        let before = abs(opponent(red) - opponent(green))
        for filter in [VisionFilter.deuteranopia, .protanopia] {
            let after = abs(opponent(filter.apply(red)) - opponent(filter.apply(green)))
            #expect(after < before / 4, "\(filter): \(after) vs \(before)")
        }
    }

    @Test func greyscaleIsLumaInEveryChannel() {
        let out = VisionFilter.greyscale.apply([1, 0, 0])
        #expect(Self.close(out, [0.2126, 0.2126, 0.2126]))
    }

    /// The race view's SwiftUI matrix (`View.vision`) is the filter's own: the same rows and bias, alpha kept.
    @Test func swiftUIMatrixIsTheFiltersMatrix() {
        for filter in VisionFilter.allCases {
            let m = filter.colorMatrix, b = Float(filter.bias)
            let rows: [[Float]] = [[m.m11, m.m12, m.m13, m.m14, m.m15], [m.m21, m.m22, m.m23, m.m24, m.m25],
                                   [m.m31, m.m32, m.m33, m.m34, m.m35], [m.m41, m.m42, m.m43, m.m44, m.m45]]
            let expected = filter.matrix.map { $0.map(Float.init) + [0, b] } + [[0, 0, 0, 1, 0]]
            #expect(rows == expected, "\(filter)")
        }
    }

    /// Every filter moves the water tones well past `FilterCoverage.minimumShift`, so the vision fixtures' UI tests,
    /// which check a filtered render's edges against the unfiltered one (`RenderFixtureUITests`'
    /// `assertFilterReachesEveryEdge`), see each filter wherever it reaches.
    @Test func everyFilterMovesTheWaterPastTheCoverageThreshold() {
        for filter in VisionFilter.allCases where filter != .none {
            for tone in [ChartPalette.water, ChartPalette.puff, ChartPalette.lull] {
                let shift = zip(filter.apply(tone.components), tone.components).map { abs($0 - $1) * 255 }.max() ?? 0
                #expect(shift >= 2 * FilterCoverage.minimumShift, "\(filter) moves \(tone) only \(shift)")
            }
        }
    }

    @Test func washoutHalvesContrastTowardsWhite() {
        #expect(Self.close(VisionFilter.washout.apply([0, 0, 0]), [0.45, 0.45, 0.45]))
        #expect(Self.close(VisionFilter.washout.apply([1, 1, 1]), [0.95, 0.95, 0.95]))
    }
}

/// The colour-vision filter covers everything the race view draws (#111). It was the scene's own `SKScene.filter`,
/// which SpriteKit applies over the scene's frame; the camera is scaled and moved, so the render's right and bottom
/// bands went unfiltered. Now it is SwiftUI's colour matrix over the whole race view, and the scene has none.
@MainActor @Suite(.serialized) struct RaceViewVisionTests {
    /// The race view hosted in a landscape window, so the portrait race is letterboxed, on the prestart fixture's
    /// scaled and offset boat camera. Through a filter, the SpriteKit view's layer sits under a layer carrying it
    /// (Core Animation filters a layer and everything under it, so the whole scene is filtered whatever its
    /// camera), and no layer outside a filtered one shows the unfiltered water (SwiftUI filters the letterbox's
    /// plain colour itself). Without a filter, no layer carries one and the letterbox is the water.
    @Test func theFilterCoversTheSceneAndTheLetterbox() throws {
        for vision in VisionFilter.allCases {
            let loaded = try RenderFixture.load(named: "prestart", in: RenderFixtureTests.fixtures)
            var fixture = loaded.fixture
            fixture.vision = vision
            let session = try GameSession(fixture: fixture, log: loaded.log)

            let windowScene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: windowScene)
            window.frame = CGRect(x: 0, y: 0, width: 874, height: 402)
            window.rootViewController = UIHostingController(
                rootView: RaceView(session: session, onRestart: {}, onExit: {})
                    .environment(\.screenSize, CGSize(width: 402, height: 874))
            )
            window.makeKeyAndVisible()
            defer { window.isHidden = true }

            let skView = try #require(settle(window) { Self.subviews(of: SKView.self, in: window).first { $0.scene != nil } },
                                      "\(vision): no SpriteKit view showing the scene")
            // A few more frames, for SwiftUI to commit whatever follows the scene's first.
            for _ in 0..<4 {
                window.layoutIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            let sceneRect = skView.convert(skView.bounds, to: window)
            #expect(sceneRect.width < window.bounds.width - 100, "\(vision): not letterboxed: \(sceneRect)")
            #expect(session.scene.camera.map { $0.xScale != 1 && $0.position != .zero } == true,
                    "\(vision): the camera isn't scaled and moved")
            #expect(session.scene.filter == nil && !session.scene.shouldEnableEffects, "\(vision): the scene filters itself")

            let tree = Self.tree(window.layer, in: window.layer)
            let filtering = Self.layers(from: skView.layer, upTo: window.layer).filter(Self.filters)
            #expect(filtering.count == (vision == .none ? 0 : 1), "\(vision): layers over the scene filtering it: \(tree)")

            let water = Self.layers(outsideFiltersIn: window.layer).filter { layer in
                layer.convert(layer.bounds, to: window.layer).insetBy(dx: -0.5, dy: -0.5).contains(window.bounds)
                    && layer.backgroundColor.map(Self.isUnfilteredWater) == true
            }
            if vision == .none {
                #expect(!water.isEmpty, "the letterbox's water isn't a layer's background: \(tree)")
            } else {
                #expect(water.isEmpty, "\(vision): the letterbox shows the unfiltered water: \(tree)")
            }
        }
    }

    private static func filters(_ layer: CALayer) -> Bool { !(layer.filters ?? []).isEmpty }

    /// Whether `colour` is `ChartPalette.water`, in sRGB to within a level.
    private static func isUnfilteredWater(_ colour: CGColor) -> Bool {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let components = colour.converted(to: srgb, intent: .defaultIntent, options: nil)?.components,
              components.count >= 3 else { return false }
        return zip(components, ChartPalette.water.components).allSatisfy { abs(Double($0) - $1) <= 1.5 / 255 }
    }

    /// `layer` and its superlayers, up to and including `top`.
    private static func layers(from layer: CALayer, upTo top: CALayer) -> [CALayer] {
        var chain = [layer]
        while let last = chain.last, last !== top, let parent = last.superlayer { chain.append(parent) }
        return chain
    }

    /// `layer` and every layer under it that no filter reaches: a filtering layer's subtree is left out.
    private static func layers(outsideFiltersIn layer: CALayer) -> [CALayer] {
        guard !filters(layer), !layer.isHidden else { return [] }
        return [layer] + (layer.sublayers ?? []).flatMap { layers(outsideFiltersIn: $0) }
    }

    /// The layer tree under `layer`, one per line, for a failure message.
    private static func tree(_ layer: CALayer, in top: CALayer, depth: Int = 0) -> String {
        var line = "\n" + String(repeating: "  ", count: depth) + "\(type(of: layer)) \(layer.convert(layer.bounds, to: top).integral)"
        if filters(layer) { line += " filters \(layer.filters ?? [])" }
        if layer.masksToBounds { line += " masks" }
        if layer.contents != nil { line += " contents" }
        if let colour = layer.backgroundColor, colour.alpha > 0 { line += " background \(colour.components ?? [])" }
        if layer.isHidden { line += " hidden" }
        return line + (layer.sublayers ?? []).map { tree($0, in: top, depth: depth + 1) }.joined()
    }

    private static func subviews<V: UIView>(of type: V.Type, in view: UIView) -> [V] {
        view.subviews.flatMap { ($0 as? V).map { [$0] } ?? [] + subviews(of: type, in: $0) }
    }

    /// Lays the window out and spins the main run loop, for up to about two seconds, until `found` finds something.
    private func settle<T>(_ window: UIWindow, until found: () -> T?) -> T? {
        for _ in 0..<40 {
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            if let value = found() { return value }
        }
        return found()
    }
}
