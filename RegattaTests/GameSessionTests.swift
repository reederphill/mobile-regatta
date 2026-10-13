import Foundation
import Testing
import RegattaBots
import RegattaCore
@testable import Regatta

@MainActor @Suite struct GameSessionTests {
    private static let config = RaceConfig(opponents: 3, prestartSeconds: 60, seed: 1, windSeed: RaceConfig.windSeed(pinnedTo: 1))

    /// The session hosts a practice driver on the launch options' timescale.
    @Test func hostsAPracticeDriver() throws {
        let session = GameSession(config: Self.config, timescale: 4)
        let driver = try #require(session.driver as? PracticeDriver)
        #expect(driver.isPausable)
        #expect(driver.tick(0.5).count == 60)
    }

    /// `-demo` attaches a bot controller to your seat, and it sails the whole race through the input API. Seed 3: on
    /// seeds 1 and 2 your bot is still racing when the 2 min finish window closes (#86), placed by distance (seed 2 on
    /// fleet-rules@6: a pre-start contact's turn, served after the gun, starts her 24 s late at the back). Not chosen
    /// with `firstSeed`: the condition is this 8-boat race sailed to its close, too slow to try seed by seed in a Debug
    /// build. A core probe of the same race finds the lowest seed from 2 on which she finishes.
    @Test func demoSailsAFullRace() throws {
        let options = LaunchOptions(arguments: ["/path/to/Regatta", "-demo", "-seed", "3"])
        let session = GameSession(config: try #require(options.launchRaceConfig()))
        let driver = try #require(session.driver as? PracticeDriver)
        var seconds = 0
        while !driver.currentFrame.isOver && seconds < 1_500 {
            driver.tick(1)
            session.consume(driver.drainEvents())
            seconds += 1
        }
        let me = driver.myBoatIndex
        #expect(driver.currentFrame.isOver)
        #expect(driver.currentFrame.boats[me].status == .finished, "your boat: \(driver.currentFrame.boats[me].status)")
        #expect(driver.log.inputs.contains { $0.seat == me }, "the bot's inputs went through the input API")
        #expect(session.roster[1].isBot && !session.roster[me].isBot)
        #expect(session.playerDone)
        let results = try #require(session.results)
        #expect(results.isFinal && session.showsResults)
        #expect(results.rows.count == RaceConfig.launchOpponents + 1)
        #expect(results.rows.filter(\.isPlayer).map(\.id) == [me])
    }

    /// Under `-demo` the driver's tack/gybe tap doesn't reach the bot-sailed seat; in a normal race it does (the
    /// app has no button for it, #460: old logs and tests tap through the driver). The bot taps that seat itself
    /// (#231), so under `-demo` the proof is the same race without the tap: the same log.
    @Test func theDriversTapOnlyReachesAHumanSeat() throws {
        let demoConfig = RaceConfig(opponents: 3, seed: 1, windSeed: 2, botSailsYourBoat: true)
        let (demo, unpressed) = (GameSession(config: demoConfig), GameSession(config: demoConfig))
        let normal = GameSession(config: Self.config)
        for session in [demo, normal] { session.driver.tap(.tackGybe) }
        for session in [demo, unpressed, normal] { session.driver.tick(Race.dt) }
        func log(_ session: GameSession) throws -> RaceLog { try #require(session.driver as? PracticeDriver).log }
        let (demoLog, unpressedLog, normalLog) = (try log(demo), try log(unpressed), try log(normal))
        #expect(demoLog.inputs.contains { $0.seat == 0 }, "the bot sails your seat")
        #expect(demoLog == unpressedLog)
        #expect(normalLog.inputs.contains { $0.seat == 0 && $0.kind == .tap(.tackGybe) })
    }

    @Test func hudClockCarriesTheTick() {
        let session = GameSession(config: Self.config)
        session.driver.tick(45 * Race.dt + 1e-9)
        session.refreshHUD()
        #expect(session.hud.tick == -1800 + 45)
        #expect(session.hud.clock == session.driver.currentFrame.time)
    }

    /// Only a rule call your boat is in takes the notice slot (#114): a call between two other boats posts nothing,
    /// so it never delays or drops your own call.
    @Test func anotherBoatsRuleCallNeverDelaysYours() {
        let session = GameSession(config: Self.config)
        let start = Date(timeIntervalSinceReferenceDate: 0)
        session.now = { start }
        let me = session.driver.myBoatIndex
        let others = (0..<4).filter { $0 != me }
        func call(_ offender: Int, _ victim: Int) -> RaceEvent {
            RaceEvent(tick: 0, kind: .ruleCall(RuleCall(incidentId: offender * 10 + victim, tick: 0, rule: .portStarboard,
                                                       offender: offender, victim: victim, leg: 0, turnsOwed: 1,
                                                       startDeadlineTick: nil, completeDeadlineTick: nil)))
        }
        session.consume([call(others[0], others[1])])
        #expect(session.notice?.kind != .ruleCall, "a call between two other boats posts nothing")
        session.consume([call(others[0], others[1]), call(others[2], me)])
        #expect(session.notice?.kind == .ruleCall && session.notice?.text.contains("fouled you") == true,
                "your call shows at once: \(String(describing: session.notice))")
        session.consume([call(others[1], others[2])])
        session.refreshHUD()
        #expect(session.notice?.text.contains("fouled you") == true, "and stays")
    }

    /// A roll tack's result posts no notice (#460): nothing in the app taps a roll, and a bot's or an old log's is
    /// not yours to read.
    @Test func aRollTackPostsNoNotice() {
        let session = GameSession(config: Self.config)
        session.now = { Date(timeIntervalSinceReferenceDate: 0) }
        let me = session.driver.myBoatIndex
        session.consume([RaceEvent(tick: 1, kind: .rollHit(seat: me)), RaceEvent(tick: 2, kind: .rollMissed(seat: me))])
        #expect(session.notice == nil, "\(String(describing: session.notice))")
    }

    /// A tap opens the live leaderboard to the whole fleet (#268); the next tap closes it, and so do 5 s of
    /// wall-clock time.
    @Test func leaderboardOpensOnATapAndClosesAfterFiveSeconds() {
        let session = GameSession(config: Self.config)
        var time = Date(timeIntervalSinceReferenceDate: 1000)
        session.now = { time }
        #expect(!session.isLeaderboardExpanded)
        session.toggleLeaderboard()
        #expect(session.isLeaderboardExpanded)
        session.toggleLeaderboard()
        #expect(!session.isLeaderboardExpanded, "a second tap closes it")

        session.toggleLeaderboard()
        time += 4.9
        session.refreshHUD()
        #expect(session.isLeaderboardExpanded)
        time += 0.1
        session.refreshHUD()
        #expect(!session.isLeaderboardExpanded, "closed after 5 s")
    }

    /// An online race has a menu and no pause (#141): pausing does nothing, and the race sails on under whatever is
    /// over it.
    @Test func onlineRaceHasAMenuAndStaysRunning() throws {
        let rig = try OnlineRig()
        rig.run(for: 1_000_000)
        #expect(!rig.session.driver.isPausable)
        rig.session.setPaused(true)
        #expect(!rig.session.isPaused)
        rig.session.pauseForBackground()
        #expect(!rig.session.isPaused, "the background pauses an online race")
        let tick = rig.driver.currentFrame.tick
        rig.run(for: 1_000_000)
        #expect(rig.driver.currentFrame.tick >= tick + Race.tickRate - 3, "the race stopped under its menu")
    }

    /// The session's roster is the server's as it stands (#141): the seat a leaver handed to a bot is named and
    /// marked so wherever the session labels a seat. A practice roster never changes.
    @Test func liveRosterLabelsFollowRosterChanges() throws {
        let rig = try OnlineRig(collisionCourse: true)
        rig.run(for: 500_000)
        let before = rig.session.roster
        #expect(before.label(of: 2, playerSeat: 0) == "Seat 3")
        rig.server.handOver(seat: 2, to: "Fulmar")
        rig.run(for: 500_000)
        #expect(rig.session.roster != before)
        #expect(rig.session.roster.label(of: 2, playerSeat: 0) == "\(BotGlyph.text) Fulmar")
        #expect(rig.session.roster.label(of: 1, playerSeat: 0) == before.label(of: 1, playerSeat: 0))

        let practice = GameSession(config: Self.config)
        let roster = practice.roster
        _ = practice.driver.tick(1)
        practice.refreshHUD()
        #expect(practice.roster == roster)
        #expect(practice.hud.leaderboard.rows.allSatisfy { $0.name == nil }, "a practice board is nameless")
    }

    /// Opening the race menu lets go of the helm (#141): the rudder centres and a finger still down steers nothing,
    /// while the race runs on.
    @Test func releaseControlsCentresTheRudderOnline() throws {
        let rig = try OnlineRig()
        rig.run(for: 1_000_000)
        let finger = 1
        rig.session.scene.steering.scheme = .tiller
        rig.session.scene.steering.touchBegan(finger, at: CGPoint(x: 100, y: 300), midX: 200)
        rig.session.scene.steering.touchMoved(finger, to: CGPoint(x: 200, y: 300))
        #expect(rig.session.scene.steering.rudder != 0)
        rig.session.releaseControls()
        #expect(rig.session.scene.steering.rudder == 0, "the rudder is centred")
        rig.session.scene.steering.touchMoved(finger, to: CGPoint(x: 0, y: 300))
        #expect(rig.session.scene.steering.rudder == 0, "the finger still down steers nothing")
        let tick = rig.driver.currentFrame.tick
        rig.run(for: 500_000)
        #expect(!rig.session.isPaused && rig.driver.currentFrame.tick > tick)
    }

    @Test func pausesOnlyAPausableDriver() {
        let session = GameSession(config: Self.config)
        session.setPaused(true)
        #expect(session.isPaused)
        session.setPaused(false)
        #expect(!session.isPaused)
    }
}
