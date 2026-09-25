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

    /// `-demo` attaches a bot controller to your seat, and it sails the whole race through the input API.
    @Test func demoSailsAFullRace() throws {
        let options = LaunchOptions(arguments: ["/path/to/Regatta", "-demo", "-seed", "1"])
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

    /// Under `-demo` the tack button doesn't reach the bot-sailed seat; in a normal race it does.
    @Test func tackButtonOnlyReachesAHumanSeat() throws {
        let demo = GameSession(config: RaceConfig(opponents: 3, seed: 1, windSeed: 2, botSailsYourBoat: true))
        let normal = GameSession(config: Self.config)
        for session in [demo, normal] {
            session.tackOrGybe()
            session.driver.tick(Race.dt)
        }
        let (demoLog, normalLog) = (try #require(demo.driver as? PracticeDriver).log, try #require(normal.driver as? PracticeDriver).log)
        #expect(!demoLog.inputs.contains { $0.seat == 0 && $0.kind == .tap(.tackGybe) })
        #expect(normalLog.inputs.contains { $0.seat == 0 && $0.kind == .tap(.tackGybe) })
    }

    @Test func hudClockCarriesTheTick() {
        let session = GameSession(config: Self.config)
        session.driver.tick(45 * Race.dt + 1e-9)
        session.refreshHUD()
        #expect(session.hud.tick == -1800 + 45)
        #expect(session.hud.clock == session.driver.currentFrame.time)
    }

    @Test func pausesOnlyAPausableDriver() {
        let session = GameSession(config: Self.config)
        session.setPaused(true)
        #expect(session.isPaused)
        session.setPaused(false)
        #expect(!session.isPaused)
    }
}
