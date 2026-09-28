import Testing
import RegattaCore
@testable import RegattaBots

/// #102: what a full fleet of bots costs the device each frame. Fifteen brains of a Mixed fleet, each deciding at
/// 10 Hz (a third of them each tick, `BotDriver.decisionInterval`), through the pre-start and the first beat: the
/// time the seat controllers take per tick (building the deciding seats' views and deciding), the race's own step
/// aside. Printed for the host; the device measurement is #172's.
@Suite struct BotBenchmarkTests {
    @Test func fifteenBrainsAt10HzUnder2msPerFrame() {
        let race = botRace(seats: Array(repeating: .bot, count: 15), prestartSeconds: 60, seed: 172)
        var controllers = SeatControllers(setup: race.setup)
        let clock = ContinuousClock()
        var total = Duration.zero
        var worst = Duration.zero
        var ticks = 0
        for _ in 0..<(Race.tickRate * 240) where !race.isOver {
            let start = clock.now
            controllers.drive(race)
            let spent = start.duration(to: clock.now)
            total += spent
            worst = max(worst, spent)
            ticks += 1
            race.step()
        }
        let ms = { (d: Duration) in Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1e15 }
        let perFrame = ms(total) / Double(ticks)
        print("BotBenchmarkTests: 15 brains at 10 Hz, \(perFrame) ms per frame on the host (worst \(ms(worst)) ms, \(ticks) ticks)")
        #expect(perFrame < 2, "\(perFrame) ms per frame")
    }
}
