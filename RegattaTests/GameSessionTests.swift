import Testing
import RegattaCore
@testable import Regatta

@MainActor @Suite struct GameSessionTests {
    private static let config = Race.Config(opponents: 3, prestartSeconds: 60, seed: 1)

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

    @Test func hudClockCarriesTheTick() {
        let session = GameSession(config: Self.config)
        for _ in 0..<45 { session.race.step() }
        session.refreshHUD()
        #expect(session.hud.tick == -1800 + 45)
        #expect(session.hud.clock == session.race.time)
    }
}
