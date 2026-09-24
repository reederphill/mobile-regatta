import Testing
import RegattaBots
import RegattaCore
@testable import Regatta

@MainActor @Suite struct GameSessionTests {
    private static let config = RaceConfig(opponents: 3, prestartSeconds: 60, seed: 1, windSeed: RaceConfig.windSeed(pinnedTo: 1))

    /// Ticks run for `seconds` of real time in 60 Hz frames.
    private func ticks(timescale: Double, seconds: Double) -> Int {
        let session = GameSession(config: Self.config, timescale: timescale)
        let start = session.race.tick
        for _ in 0..<Int(seconds * 60) { session.scene.advanceSimulation(by: 1.0 / 60) }
        return session.race.tick - start
    }

    @Test func realTimeRunsThirtyTicksASecond() {
        #expect((59...60).contains(ticks(timescale: 1, seconds: 2)))
    }

    @Test func timescaleRunsTheSimulationFaster() {
        #expect((239...240).contains(ticks(timescale: 4, seconds: 2)))
    }

    /// `-demo` attaches a bot controller to your seat, and it sails the whole race through the input API.
    @Test func demoSailsAFullRace() throws {
        let options = LaunchOptions(arguments: ["/path/to/Regatta", "-demo", "-seed", "1"])
        let session = GameSession(config: try #require(options.launchRaceConfig(from: RaceSettings())))
        let race = session.race
        var seconds = 0
        while !race.isOver && seconds < 1_500 {
            session.scene.advanceSimulation(by: 1)
            seconds += 1
        }
        #expect(race.isOver)
        #expect(race.boats[race.playerIndex].status == .finished, "your boat: \(race.boats[race.playerIndex].status)")
        #expect(race.log.inputs.contains { $0.seat == race.playerIndex }, "the bot's inputs went through the input API")
        #expect(session.roster[1].isBot && !session.roster[race.playerIndex].isBot)
    }

    /// Under `-demo` the tack button doesn't reach the bot-sailed seat; in a normal race it does.
    @Test func tackButtonOnlyReachesAHumanSeat() {
        let demo = GameSession(config: RaceConfig(opponents: 3, seed: 1, windSeed: 2, botSailsYourBoat: true))
        let normal = GameSession(config: Self.config)
        for session in [demo, normal] {
            session.tackOrGybe()
            session.race.step()
        }
        #expect(!demo.race.log.inputs.contains { $0.seat == 0 && $0.kind == .tap(.tackGybe) })
        #expect(normal.race.log.inputs.contains { $0.seat == 0 && $0.kind == .tap(.tackGybe) })
    }

    @Test func hudClockCarriesTheTick() {
        let session = GameSession(config: Self.config)
        for _ in 0..<45 { session.race.step() }
        session.refreshHUD()
        #expect(session.hud.tick == -1800 + 45)
        #expect(session.hud.clock == session.race.time)
    }
}
