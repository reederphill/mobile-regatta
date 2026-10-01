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

    /// `-demo` attaches a bot controller to your seat, and it sails the whole race through the input API. Seed 2:
    /// on seed 1 your bot is still racing when the 2 min finish window closes (#86), placed by distance.
    @Test func demoSailsAFullRace() throws {
        let options = LaunchOptions(arguments: ["/path/to/Regatta", "-demo", "-seed", "2"])
        let session = GameSession(config: try #require(options.launchRaceConfig(from: RaceSettings())))
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
        #expect(session.results.count == RaceSettings().opponents + 1)
        #expect(session.results.filter(\.isPlayer).map(\.id) == [me])
    }

    /// Under `-demo` the tack button doesn't reach the bot-sailed seat; in a normal race it does. The bot taps
    /// that seat itself (#231), so under `-demo` the proof is the same race without the press: the same log.
    @Test func tackButtonOnlyReachesAHumanSeat() throws {
        let demoConfig = RaceConfig(opponents: 3, seed: 1, windSeed: 2, botSailsYourBoat: true)
        let (demo, unpressed) = (GameSession(config: demoConfig), GameSession(config: demoConfig))
        let normal = GameSession(config: Self.config)
        for session in [demo, normal] { session.tackOrGybe() }
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

    @Test func pausesOnlyAPausableDriver() {
        let session = GameSession(config: Self.config)
        session.setPaused(true)
        #expect(session.isPaused)
        session.setPaused(false)
        #expect(!session.isPaused)
    }
}
