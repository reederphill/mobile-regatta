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

    /// The HUD fixtures (#114) are what their names say: before the gun, racing, OCS, and after the first
    /// finish with the countdown to the close. Each draws the HUD over the scene; every older fixture
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

    /// The rule-cue fixtures (#123) through every filter, each on its own scene's log (#466; #377: your port-starboard
    /// call; #474: at a framing short of close quarters, their rows' `zoom`, which before the gun is the pre-start
    /// shot's): `rules-call` draws two rule-call lines (yours under rule 10 and one more, whichever rule, their boats
    /// apart), the arc counting your started turn's complete deadline and glows;
    /// `rules-penalty` your unstarted turn's arc, both glows and the HUD's live Turn notice. Both show a backwind wedge
    /// (#377). `rules-penalty-glow` (#517, unfiltered) draws another boat taking a penalty: her halo shown
    /// (orange, `RuleCueTests`), no arc of yours. Every older fixture draws no rule cue, so its reference doesn't move.
    @Test func ruleFixturesShowTheRuleCues() throws {
        func session(_ name: String) throws -> GameSession {
            let (fixture, log) = try RenderFixture.load(named: name, in: Self.fixtures)
            let session = try GameSession(fixture: fixture, log: log)
            SKView(frame: CGRect(x: 0, y: 0, width: 402, height: 874)).presentScene(session.scene)
            session.scene.update(0)
            return session
        }
        // Each twin is its fixture's frame (#404: the tick is the one `scripts/record-fixtures.sh`'s condition picks).
        let (callTick, penaltyTick) = try (RenderFixture.load(named: "rules-call", in: Self.fixtures).0.freezeTick,
                                           RenderFixture.load(named: "rules-penalty", in: Self.fixtures).0.freezeTick)
        for vision in VisionFilter.allCases {
            let suffix = vision == .none ? "" : "-\(vision.rawValue)"
            let (call, _) = try RenderFixture.load(named: "rules-call" + suffix, in: Self.fixtures)
            let (penalty, _) = try RenderFixture.load(named: "rules-penalty" + suffix, in: Self.fixtures)
            #expect(call.vision == vision && penalty.vision == vision && call.ruleCues == true && penalty.ruleCues == true)
            #expect(call.freezeTick == callTick && penalty.freezeTick == penaltyTick)
        }

        let call = try session("rules-call")
        #expect(call.scene.ruleCueSummary.hasSuffix("lines=2 arc=1"), "\(call.scene.ruleCueSummary)")
        #expect(call.scene.shownGlows.contains { $0?.kind == .giveWay })
        #expect(!call.showsFixtureHUD, "no HUD in this fixture")
        let calls = call.ruleCalls.active(at: call.driver.currentFrame.time, seconds: 8, fadeSeconds: 1.5)
        // Two lines at full strength, one of them your rule 10 call; the other is whichever rule the scene drew (#474).
        #expect(calls.count == 2 && calls.allSatisfy { $0.alpha == 1 }, "\(calls)")
        #expect(calls.contains { $0.badge == "10" && $0.offender == call.driver.renderWorld.myBoatIndex }, "\(calls)")
        #expect(Self.wedgesOnScreen(call.scene) >= 1, "no backwind wedge in view")

        let penalty = try session("rules-penalty")
        #expect(penalty.scene.ruleCueSummary.hasSuffix("lines=1 arc=1"), "\(penalty.scene.ruleCueSummary)")
        #expect(penalty.scene.shownGlows.contains { $0?.kind == .giveWay })
        #expect(penalty.scene.shownGlows.contains { $0?.kind == .hasRight })
        #expect(penalty.showsFixtureHUD)
        // Unstarted: both clocks, to start and to complete (`PenaltyReadout.noticeText`), counting from the scene's call.
        let turn = try #require(penalty.notice?.kind == .penalty ? penalty.notice?.text : nil)
        #expect(turn.hasPrefix("Turn · ") && turn.contains(" / "), "\(turn)")
        #expect(Self.wedgesOnScreen(penalty.scene) >= 1, "no backwind wedge in view")

        let glow = try session("rules-penalty-glow")
        let orange = glow.scene.shownGlows.indices.filter { glow.scene.shownGlows[$0]?.kind == .takingAPenalty }
        #expect(!orange.isEmpty, "no boat taking a penalty in glow range")
        #expect(orange.allSatisfy { glow.scene.shownHalos[$0] != nil }, "her halo is hidden")
        #expect(glow.scene.ruleCueSummary.hasSuffix("arc=0"), "\(glow.scene.ruleCueSummary)")

        for name in ["prestart", "fleet", "cues", "hud-prestart", "hud-racing"] {
            let older = try session(name)
            #expect(older.scene.ruleCueSummary == "glows=0 lines=0 arc=0", "\(name)")
            #expect(older.notice?.kind != .penalty, "\(name)")
        }
    }

    /// The fleet-rules@6 penalty arc (#489) on its own scenes' logs (`scripts/fixture-scenes.json`: your turn luffed
    /// at once, or borne away): `rules-turn` just called, neither crossing made, both marks grey; `rules-turn-tack` the
    /// tack made, its half lit with its barb; `rules-turn-gybe` the gybe made first. Each with the arc and the HUD's
    /// one-countdown Turn notice. Every fleet-rules@5-or-older fixture draws no marks, so its reference doesn't move.
    @Test func tackAndGybeFixturesShowTheTurnMarks() throws {
        func session(_ name: String) throws -> GameSession {
            let (fixture, log) = try RenderFixture.load(named: name, in: Self.fixtures)
            #expect(log.header.setup.rulesConfiguration.id == "fleet-rules" && log.header.setup.rulesConfiguration.version == 6,
                    "\(name)")
            #expect(fixture.ruleCues == true, "\(name)")
            let session = try GameSession(fixture: fixture, log: log)
            SKView(frame: CGRect(x: 0, y: 0, width: 402, height: 874)).presentScene(session.scene)
            session.scene.update(0)
            return session
        }
        for (name, marks) in [("rules-turn", "tack=grey gybe=grey barbs=0"), ("rules-turn-tack", "tack=lit gybe=grey barbs=1"),
                              ("rules-turn-gybe", "tack=grey gybe=lit barbs=1")] {
            let turn = try session(name)
            #expect(turn.scene.ruleCueSummary.hasSuffix("arc=1"), "\(name): \(turn.scene.ruleCueSummary)")
            #expect(turn.scene.penaltyMarksSummary == marks, "\(name)")
            let notice = try #require(turn.notice?.kind == .penalty ? turn.notice?.text : nil, "\(name)")
            #expect(notice.hasPrefix("Turn · ") && !notice.contains(" / "), "\(name): \(notice)")
        }
        for name in ["rules-call", "rules-penalty", "prestart", "fleet", "cues"] {
            let (fixture, log) = try RenderFixture.load(named: name, in: Self.fixtures)
            let older = try GameSession(fixture: fixture, log: log)
            SKView(frame: CGRect(x: 0, y: 0, width: 402, height: 874)).presentScene(older.scene)
            older.scene.update(0)
            #expect(older.scene.penaltyMarksSummary == "none", "\(name)")
        }
    }

    /// The instruments fixture (#457) is `hud-racing` with the bottom row's speed and apparent wind; every older HUD
    /// fixture draws without them, so its reference doesn't move. A frozen fixture shows the raw reading (its first).
    @Test func instrumentsFixtureShowsTheInstruments() throws {
        let (fixture, log) = try RenderFixture.load(named: "hud-instruments", in: Self.fixtures)
        let (racing, _) = try RenderFixture.load(named: "hud-racing", in: Self.fixtures)
        var expected = racing
        expected.hud?.instruments = true
        #expect(fixture == expected)
        let session = try GameSession(fixture: fixture, log: log)
        #expect(session.showsFixtureInstruments)
        let model = HUDModel(session.hud)
        #expect(model.showsInstruments)
        #expect(session.hud.shownInstruments == session.hud.instruments)
        #expect(session.hud.instruments.speedKnots > 1 && session.hud.instruments.apparentKnots > 1)
        #expect(model.apparentAngleText.hasSuffix("port") || model.apparentAngleText.hasSuffix("starboard"))

        for name in ["hud-prestart", "hud-racing", "hud-ocs", "hud-afterfirstfinish", "hud-leaderboard", "hud-hint-leader"] {
            let (older, log) = try RenderFixture.load(named: name, in: Self.fixtures)
            #expect(try !GameSession(fixture: older, log: log).showsFixtureInstruments, "\(name)")
        }
    }

    /// The live leaderboard fixtures (#268): compact through every filter, and tapped open, on `hud-racing`'s tick (its
    /// row in scripts/fixture-freeze-ticks.json: racing on the first beat among the fleet, you 3rd to 6th, #467).
    /// The board is opt-in, so #114's HUD fixtures draw without it and keep their references.
    @Test func leaderboardFixturesShowTheBoard() throws {
        let (compact, log) = try RenderFixture.load(named: "hud-leaderboard", in: Self.fixtures)
        let session = try GameSession(fixture: compact, log: log)
        #expect(session.controls.showsLeaderboard && !session.isLeaderboardExpanded)
        let board = session.hud.leaderboard
        #expect(board.isVisible)
        // The board's shape, not its numbers, so a re-record (`scripts/record-fixtures.sh`) needs no edit here: the whole
        // fleet ranked, and compact lines of the leader first, the boat ahead of you, you (starred, not leading, so the
        // board shows a gap) and the boat behind, in place order, with a separator wherever the places skip.
        #expect(board.rows.count == session.driver.renderWorld.boats.count)
        let me = try #require(board.me, "you're in the standings")
        #expect(me.place > 1, "you lead at the fixture's tick, so the board shows no gap to the leader")
        let entries = board.entries(expanded: false)
        let rows = entries.compactMap { entry -> LeaderboardState.Row? in
            if case .row(let row) = entry { row } else { nil }
        }
        let lines = entries.map { entry -> String in
            switch entry {
            case .row(let row): "\(row.place):\(row.gap.text)\(row.isMe ? "*" : "")"
            case .separator: "sep"
            }
        }
        let wanted = Set([1, me.place - 1, me.place, me.place + 1].filter { (1...board.rows.count).contains($0) })
        #expect(rows.map(\.place) == wanted.sorted(), "\(lines)")
        #expect(rows.first?.place == 1 && rows.first?.gap == .leader && rows.filter(\.isMe).map(\.place) == [me.place], "\(lines)")
        let gaps = rows.dropFirst().map { row -> Int? in if case .metres(let metres) = row.gap { metres } else { nil } }
        #expect(gaps.allSatisfy { $0 != nil } && gaps.map { $0 ?? 0 } == gaps.map { $0 ?? 0 }.sorted(), "\(lines)")
        let separators = entries.indices.filter { if case .separator = entries[$0] { true } else { false } }.count
        #expect(separators == zip(rows, rows.dropFirst()).filter { $1.place > $0.place + 1 }.count, "\(lines)")

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

        for name in ["hud-prestart", "hud-racing", "hud-ocs", "hud-afterfirstfinish"] {
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

    /// The fleet fixture (#117) is its own scene's bot race (#466, `scripts/fixture-scenes.json`: recorded by
    /// `scripts/record-fixtures.sh --record` on the default class), frozen in open water on the first beat (#474: its
    /// own row again, no longer `hud-afterfirstfinish`'s moment at the finish): you racing among at least four boats
    /// with the windward mark in the boat camera's view, sails working; its five twins are the same frame through each
    /// other filter.
    @Test func fleetFixtureShowsTheFleetInOpenWater() throws {
        let (fixture, log) = try RenderFixture.load(named: "fleet", in: Self.fixtures)
        #expect(fixture.camera == .boat && fixture.view == nil && fixture.vision == VisionFilter.none)
        // Every scene log sails the default class (#466): after a default switch `scripts/record-fixtures.sh --record`
        // re-records them all, and CI's renders of the new framing are the owner's to adopt (#354).
        #expect(log.header.setup.boatClass == RaceFiles.defaults.boatClass.ref)
        for scene in ["rules-call", "rules-penalty", "cues", "rules-penalty-glow", "rules-turn", "rules-turn-gybe", "planing"] {
            let (_, sceneLog) = try RenderFixture.load(named: scene, in: Self.fixtures)
            #expect(sceneLog.header.setup.boatClass == RaceFiles.defaults.boatClass.ref, "\(scene)")
        }
        let world = try FixtureDriver(log: log, freezeTick: fixture.freezeTick).renderWorld
        let me = world.me
        #expect(me.status == .racing && me.legIndex == 0)
        #expect(!world.boats.indices.contains { world.isGhost(ofSeat: $0) }, "nobody has finished yet")
        // The boat camera at the default zoom on iPhone 17 (402 x 874 points, scale 1/0.8), in metres.
        let center = me.position + me.velocity * 2
        let half = Vec2(402, 874) * 1.25 / 2 / Double(GameScene.pointsPerMeter)
        func inView(_ p: Vec2) -> Bool { abs(p.x - center.x) < half.x && abs(p.y - center.y) < half.y }
        let racing = world.boats.indices.filter { world.boats[$0].status == .racing && inView(world.boats[$0].position) }
        #expect(racing.count >= 4, "\(racing)")
        #expect(inView(world.course.targetPosition(for: world.course.legs[me.legIndex])), "the mark you sail for isn't in view")
        let (scene, _) = try DrawOrderTests.scene(fixture: "fleet")
        #expect(Self.wedgesOnScreen(scene) >= 2, "the fleet's sails aren't working in view")
        // Not the HUD fixture's moment after the first finish, which draws the ghost (`hudFixturesShowWhatTheyAreFor`).
        let (finish, _) = try RenderFixture.load(named: "hud-afterfirstfinish", in: Self.fixtures)
        #expect(finish.log == fixture.log && finish.freezeTick > fixture.freezeTick)
        for vision in VisionFilter.allCases where vision != .none {
            let (twin, _) = try RenderFixture.load(named: "fleet-\(vision.rawValue)", in: Self.fixtures)
            var expected = fixture
            expected.vision = vision
            #expect(twin == expected, "\(vision)")
        }
    }

    /// The planing cue fixtures (#492) on their own scene's log (`scripts/fixture-scenes.json`: the first run, where
    /// once you have planed a while you run deeper until you fall off, `runDeeper`), each with the HUD and its
    /// instruments: `planing` comfortably on the plane, your margin full, your stern-corner wakes at their longest
    /// and another planing boat's in the picture; `planing-edge` later on the same run at the edge of it, your margin
    /// nearly gone and the wakes near their shortest, still drawn. In both your speed tile is yellow under dark
    /// figures and VoiceOver says so. Their twins are the same frames through each other filter.
    @Test func planingFixturesShowThePlaningCue() throws {
        let style = BoatStyle.standard
        #expect(PlaneMargin.ranges(style) == BoatClass.PlaningTuning.MarginRanges.standard,
                "the fixtures' rows read the margin at core's standard ranges (regatta-replay's planeMargin)")
        var drawn: [String: (share: Double, reach: CGFloat, tick: Int)] = [:]
        for (name, margins, others) in [("planing", 1.0...1.0, 1), ("planing-edge", 0.03...0.2, 0)] {
            let (fixture, log) = try RenderFixture.load(named: name, in: Self.fixtures)
            #expect(fixture.log == "planing.racelog.json" && fixture.cameraMode == .courseUp && fixture.hud?.instruments == true)
            let session = try GameSession(fixture: fixture, log: log)
            let world = session.driver.renderWorld
            let me = world.me
            #expect(me.isPlaning && me.status == .racing && me.legIndex == 2 && !world.frame.isJustSeated, "\(name)")
            let margin = PlaneMargin.of(me, boatClass: world.boatClass, style: style)
            #expect(margins.contains(margin), "\(name): margin \(margin)")

            #expect(session.showsFixtureInstruments && session.hud.isPlaning, "\(name)")
            let model = HUDModel(session.hud)
            #expect(model.speedTileYellow == style.planingTileAlpha && model.speedTileHasDarkFigures, "\(name)")
            #expect(model.speedAccessibilityValue.hasSuffix("knots, planing"), "\(name)")

            let (scene, _) = try DrawOrderTests.scene(fixture: name)
            let wakes = Self.cornerWakes(scene)
            let planing = world.boats.indices.filter { world.boats[$0].isPlaning && !world.isGhost(ofSeat: $0) }
            #expect(wakes.count == planing.count && wakes.count >= 1 + others, "\(name): \(wakes.count) of \(planing)")
            // Yours: the pair that ends at your stern.
            let ppm = CGFloat(GameScene.pointsPerMeter)
            let mine = try #require(wakes.min { Self.gap($0, me, ppm) < Self.gap($1, me, ppm) })
            #expect(Self.gap(mine, me, ppm) < CGFloat(world.boatClass.hull.length) * ppm, "\(name)")
            let share = CornerWakes.target(margin: margin, level: 1, style: style)
            let box = try #require(mine.path?.boundingBox)
            drawn[name] = (share, hypot(box.width, box.height) / CGFloat(me.velocityOverGround.length), fixture.freezeTick)
            #expect(abs(mine.alpha - CGFloat(style.cornerWakeAlpha)) < 1e-6, "\(name): at their full alpha")

            for vision in VisionFilter.allCases where vision != .none {
                let (twin, _) = try RenderFixture.load(named: "\(name)-\(vision.rawValue)", in: Self.fixtures)
                var expected = fixture
                expected.vision = vision
                #expect(twin == expected, "\(name) \(vision)")
            }
        }
        let full = try #require(drawn["planing"]), edge = try #require(drawn["planing-edge"])
        #expect(full.share == 1 && edge.share < 0.45 && edge.share >= style.cornerWakeMinShare)
        #expect(edge.tick > full.tick)
        // A second of her track is drawn shorter at the edge, by about the shares.
        #expect(edge.reach < full.reach * 0.6 && edge.reach > full.reach * 0.2, "\(edge.reach) against \(full.reach)")
    }

    /// The spinnaker fixtures (#311), each a state of your kite on the default class: hoisting mid-way, its pole part
    /// out (`spinnaker-hoist`); dropping mid-way (`spinnaker-drop`); collapsed by the lee with another boat's kite up
    /// beside it (`spinnaker-lee`). And `planing-edge` is the soft kite: up, its depth short of full. Each drawn by your
    /// boat's node, and each with its five filter twins.
    @Test func spinnakerFixturesShowEachState() throws {
        let style = BoatStyle.standard
        for (name, phase, progress) in [("spinnaker-hoist", SpinnakerPose.Phase.hoisting, 0.3...0.7),
                                         ("spinnaker-drop", .dropping, 0.3...0.7), ("spinnaker-lee", .collapsed, 1...1),
                                         ("planing-edge", .up, 1...1)] {
            let (fixture, log) = try RenderFixture.load(named: name, in: Self.fixtures)
            let session = try GameSession(fixture: fixture, log: log)
            let world = session.driver.renderWorld
            #expect(world.boatClass == Race.defaultBoatClass, "\(name): on the default class")
            let pose = SpinnakerPose(world.me, isGhost: false, boatClass: world.boatClass, style: style)
            #expect(pose.phase == phase && progress.contains(pose.hoisted), "\(name): \(pose.phase) \(pose.hoisted)")

            // Drawn by the standing fleet (#597), in seat order.
            let (scene, _) = try GameSceneTests.scene(fixture: name)
            let fleet = try #require(scene.standingFleet).fleet
            let mine = try #require(fleet.indices.contains(world.myBoatIndex) ? fleet[world.myBoatIndex] : nil)
            let kite = try #require(mine.kiteLook, "\(name): your kite drawn")
            #expect(abs(kite.size - Float(pose.hoisted)) < 1e-6, "\(name)")
            #expect(mine.poleLook != nil, "\(name): its pole out")
            switch name {
            case "spinnaker-lee":
                let others = world.boats.indices.filter { seat in
                    seat != world.myBoatIndex && !world.isGhost(ofSeat: seat)
                        && SpinnakerPose(world.boats[seat], isGhost: false, boatClass: world.boatClass, style: style).phase == .up
                }
                #expect(!others.isEmpty, "\(name): another boat's kite up")
                #expect(others.allSatisfy { fleet[$0].kiteLook != nil }, "\(name)")
            case "planing-edge":
                // Against the same kite with no soft kite: its depth at her wind angle, at a full margin.
                var unsoftened = style
                unsoftened.kiteSoftFill = 1
                let full = SpinnakerPose(world.me, isGhost: false, boatClass: world.boatClass, style: unsoftened).fill
                #expect(pose.fill < full * 0.85 && pose.fill >= style.kiteDepthFloor, "\(name): soft, \(pose.fill) of \(full)")
            default: break
            }

            if name.hasPrefix("spinnaker-") {
                #expect(fixture.cameraMode == .courseUp && fixture.hud?.instruments == true, "\(name)")
                for vision in VisionFilter.allCases where vision != .none {
                    let (twin, _) = try RenderFixture.load(named: "\(name)-\(vision.rawValue)", in: Self.fixtures)
                    var expected = fixture
                    expected.vision = vision
                    #expect(twin == expected, "\(name) \(vision)")
                }
            }
        }
    }

    /// The stern-corner wakes (#492) `scene` draws: every boat's that isn't hidden.
    static func cornerWakes(_ scene: GameScene) -> [SKShapeNode] {
        guard let effects = scene.childNode(withName: "//effects") else { return [] }
        return effects.children.compactMap { $0 as? SKShapeNode }.filter { $0.name == "cornerWake" && !$0.isHidden }
    }

    /// How far `wake`'s box is from `boat`, points: nothing when she is in or on it.
    private static func gap(_ wake: SKShapeNode, _ boat: Boat, _ ppm: CGFloat) -> CGFloat {
        guard let box = wake.path?.boundingBox, !box.isNull else { return .infinity }
        let p = CGPoint(x: CGFloat(boat.position.x) * ppm, y: CGFloat(boat.position.y) * ppm)
        return hypot(max(box.minX - p.x, 0, p.x - box.maxX), max(box.minY - p.y, 0, p.y - box.maxY))
    }

    /// A row of `scripts/fixture-freeze-ticks.json`, as far as the app's camera can check it.
    private struct FreezeRow: Decodable {
        var fixtures: [String]
        var camera: String?
        var clear: [Double]?
        var zoom: [Double]?
        var racingInView: Int?
        var ghostsInView: Int?
        var markInView: Bool?
    }

    /// The freeze-tick rows count what the renders show (#474). A row's boats "in view" were once a north-up box of
    /// water round your boat whatever camera drew its fixtures, so `hud-racing`'s five were two on the race camera's
    /// close-quarters screen. Now a row whose fixtures draw the race camera (`"view": "courseUp"`) says so
    /// (`"camera": "race"`: `regatta-replay`'s `RaceCameraFrame`, the settled rig again in the core tool), and here
    /// the app's own rig agrees with each such row on its first fixture's frame: the zoom inside the row's bounds, and
    /// at least the boats racing and ghosts it asks for drawn on the iPhone's screen, clear of what the row says the
    /// HUD covers. The HUD row asks for five (the owner's floor is three, PR #467).
    @Test func freezeRowsCountTheBoatsTheirCameraShows() throws {
        let table = Self.fixtures.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/fixture-freeze-ticks.json")
        let rows = try JSONDecoder().decode([FreezeRow].self, from: Data(contentsOf: table))
        let hud = try #require(rows.first { $0.fixtures.contains("hud-racing") })
        #expect(hud.camera == "race" && (hud.racingInView ?? 0) >= 3 && hud.clear != nil)
        for row in rows {
            for name in row.fixtures {
                let (fixture, _) = try RenderFixture.load(named: name, in: Self.fixtures)
                #expect(fixture.cameraMode == (row.camera == "race" ? .courseUp : .northUpFollow), "\(name)")
            }
            guard row.camera == "race", let name = row.fixtures.first else { continue }
            let (scene, _) = try DrawOrderTests.scene(fixture: name)
            // The phone's screen, as `RaceView` sizes the scene on iPhone 17 (`RaceViewportPolicy`): a scene of its
            // own is a 390 x 844 placeholder.
            scene.size = CGSize(width: 402, height: 874)
            scene.update(0)
            let world = scene.driver.renderWorld
            if let zoom = row.zoom {
                #expect((zoom[0] - 1e-9...zoom[1] + 1e-9).contains(scene.rig.zoom), "\(name): zoom \(scene.rig.zoom)")
            }
            let clear = row.clear ?? [0, 0, 0]
            func shows(_ p: Vec2) -> Bool {
                let q = scene.rig.project(p, sceneSize: scene.size)
                return q.x > clear[2] && q.x < scene.size.width - clear[2] && q.y > clear[1] && q.y < scene.size.height - clear[0]
            }
            let shown = world.boats.indices.filter { shows(world.boats[$0].position) }
            let racing = shown.filter { !world.isGhost(ofSeat: $0) && world.boats[$0].status == .racing }
            #expect(racing.count >= row.racingInView ?? 0, "\(name): racing on screen \(racing)")
            #expect(shown.filter { world.isGhost(ofSeat: $0) }.count >= row.ghostsInView ?? 0, "\(name): on screen \(shown)")
            if let markInView = row.markInView {
                let me = world.me
                #expect(shows(world.course.targetPosition(for: world.course.legs[me.legIndex])) == markInView, "\(name)")
            }
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
    /// which check a filtered render's edges against the unfiltered one (`RenderFixtureFilterUITests`'
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
            // The camera stays at the origin and zooms (#597); the world moves under it, to −centre.
            #expect(session.scene.camera.map { $0.xScale != 1 } == true, "\(vision): the camera isn't scaled")
            #expect(session.scene.childNode(withName: "//water")?.parent.map { $0.position != .zero } == true,
                    "\(vision): the world isn't moved")
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
