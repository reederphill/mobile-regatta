// TEMP (#445 investigation, not committed): per-seed dump of the results-seed race.
import Foundation
import RegattaBots
import RegattaCore

enum ResultsDump {
    static func main(arguments: [String]) -> Int32 {
        let seeds = arguments.compactMap { UInt64($0) }
        print("seed first close gap allGone demoFin demoPlace finishers dnf dsq calls161 calls finishTicks")
        for seed in seeds {
            let setup = try! RaceSetup(raceSeed: RaceSeed(seed), seats: [.human] + Array(repeating: .bot, count: 7),
                                       laps: 1, startSequenceTicks: 60 * Race.tickRate)
            var wind = SplitMix64(seed: seed ^ 0x5749_4E44_5345_4544)
            let race = Race(setup: setup, windSeed: WindSeed(wind.next()))
            var controllers = SeatControllers(setup: setup)
            controllers[0] = .bot(BotDriver(seat: 0, raceSeed: setup.raceSeed))
            var fin = [Int: (tick: Int, place: Int)]()
            var calls = [String]()
            var c161 = 0
            var started = [Int: Int]()
            let trace = ProcessInfo.processInfo.environment["TRACE"].flatMap(Int.init)
            while !race.isOver {
                controllers.drive(race)
                race.step()
                if let t = trace, race.tick % 150 == 0 { let b = race.boats[t]; print(String(format: "  t%d %@ leg%d r%d pos(%.0f,%.0f) hdg%.0f spd%.2f twa%.0f owed%d tacking%d", race.tick, "\(b.status)", b.legIndex, b.roundingStage, b.position.x, b.position.y, b.heading * 180 / .pi, b.speed, b.twa * 180 / .pi, b.penaltyTurnsOwed, b.isTacking ? 1 : 0)) }
                for e in race.drainEvents() {
                    switch e.kind {
                    case let .finished(seat, place): fin[seat] = (e.tick, place)
                    case let .started(seat): started[seat] = e.tick
                    case let .ruleCall(c) where trace != nil: calls.append("\(c.rule)@\(c.offender)v\(c.victim)t\(c.tick)"); if "\(c.rule)".contains("16") { c161 += 1 }
                    case let .ruleCall(c):
                        calls.append("\(c.rule)@\(c.offender)")
                        if "\(c.rule)".contains("16") { c161 += 1 }
                    default: break
                    }
                }
            }
            let first = race.firstFinishTick ?? -1
            let close = race.tick
            let allGone = race.boats.allSatisfy(\.isGhost)
            let demo = fin[0]
            let dnf = race.boats.filter { $0.status != .finished && $0.status != .dsq }.count
            let dsq = race.boats.filter { $0.status == .dsq }.count
            let ticks = (0..<race.boats.count).map { s in fin[s].map { "\(s):\($0.tick)" } ?? "\(s):-" }.joined(separator: ",")
            let left = race.boats.indices.filter { race.boats[$0].status != .finished }.map { i -> String in let b = race.boats[i]; return String(format: "s%d:%@ leg%d pos(%.0f,%.0f) spd%.2f owed%d start%d", i, "\(b.status)", b.legIndex, b.position.x, b.position.y, b.speed, b.penaltyTurnsOwed, started[i] ?? -1) }.joined(separator: "; ")
            print("\(seed) \(first) \(close) \(demo.map { close - $0.tick } ?? -1) \(allGone) \(demo?.tick ?? -1) \(demo?.place ?? -1) \(fin.count) \(dnf) \(dsq) \(c161) \(calls.count) \(ticks) [\(calls.joined(separator: " "))] LEFT{\(left)} STARTS{\(started.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ","))}")
        }
        return 0
    }
}
