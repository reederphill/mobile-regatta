import Foundation
import Testing
import RegattaCore
@testable import RegattaBots

/// PROTOTYPE (#525, never merged): what the gate planner (variant P) costs on the host. A 16-bot race is sailed to the
/// tick when most of the fleet is inside the gate pick's 80 m (the worst case for a tick: every boat in range plans),
/// then frozen. Printed: (1) `gatePlanChoice` per call, p50/p99 over every boat in range, 200 calls each; (2) one whole
/// tick of `SeatControllers.drive` on the frozen race (the deciding third of the fleet), p50/p99/max over 3 phases x 100.
/// Run it with `REGATTA_BOT_VARIANT=Pm` for (2) with the planner in, and without for the tick without it; the planner's
/// step, horizon and candidate count come from `REGATTA_PLAN_DT`, `REGATTA_PLAN_H_TOP`, `REGATTA_PLAN_N_TOP`,
/// `REGATTA_PLAN_NOTIERS` (everyone at the top tier), `REGATTA_PLAN_EVERY`. Only `ContinuousClock`s live here.
@Suite struct PlannerCostTests {
    private func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1e15 }

    /// Boats of `race` racing on a gate leg and inside the pick's range.
    private func inRange(_ race: Race, gates: [Int: Vec2]) -> [Int] {
        let up = race.course.upwind
        return race.boats.indices.filter { seat in
            let boat = race.boats[seat]
            guard boat.status == .racing, boat.roundingStage == 0, let centre = gates[boat.legIndex] else { return false }
            let above = up.dot(boat.position - centre)
            return above > 3 && above < BotBrain.gatePickRange
        }
    }

    private func gateCentres(_ race: Race) -> [Int: Vec2] {
        var gates: [Int: Vec2] = [:]
        for (leg, l) in race.course.legs.enumerated() {
            guard case .round(let index) = l, case .gate = race.course.elements[index] else { continue }
            gates[leg] = race.course.targetPosition(for: l)
        }
        return gates
    }

    private func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(p * Double(sorted.count - 1) + 0.5))]
    }

    @Test func gatePlannerCostOnAFrozenSixteenBoatPack() throws {
        let seed: UInt64 = 525
        let seats = Array(repeating: SeatKind.bot, count: 16)
        // Pass 1: the tick with the most boats in range.
        var best = (tick: 0, count: 0)
        do {
            let race = botRace(seats: seats, prestartSeconds: 45, seed: seed)
            var controllers = SeatControllers(setup: race.setup)
            let gates = gateCentres(race)
            for _ in 0..<(Race.tickRate * 600) where !race.isOver {
                let count = inRange(race, gates: gates).count
                if count > best.count { best = (race.tick, count) }
                controllers.drive(race)
                race.step()
            }
        }
        try #require(best.count >= 4, "no pack in range")
        // Pass 2: sail to it and freeze.
        let race = botRace(seats: seats, prestartSeconds: 45, seed: seed)
        var controllers = SeatControllers(setup: race.setup)
        let gates = gateCentres(race)
        while race.tick < best.tick {
            controllers.drive(race)
            race.step()
        }
        let clock = ContinuousClock()
        let planning = inRange(race, gates: gates)

        // (1) The planner alone, per call.
        var calls: [Double] = []
        var perBoat: [String] = []
        for seat in planning {
            guard case .bot(let driver) = controllers.seats[seat] else { continue }
            let view = race.seatView(for: seat)
            let b = view.own
            guard let gate = BotBrain.gate(of: b, view) else { continue }
            var times: [Double] = []
            for _ in 0..<200 {
                var brain = driver.brain
                let l = brain.gateOption(left: true, gate, b, view), r = brain.gateOption(left: false, gate, b, view)
                let start = clock.now
                _ = brain.gatePlanChoice(b, view, gate: gate, l: l, r: r)
                times.append(ms(start.duration(to: clock.now)))
            }
            calls += times
            perBoat.append(String(format: "seat %d skill %.2f p50 %.3f", seat, driver.brain.style.skill, percentile(times, 0.5)))
        }
        print("PlannerCostTests: frozen at tick \(best.tick) with \(planning.count) of 16 boats in range; dt \(BotVariant.planDt) s, horizon \(BotVariant.planHorizonTop) s top / \(BotVariant.planHorizonClub) s club, candidates \(BotVariant.planCandTop)/\(BotVariant.planCandClub), tiers \(BotVariant.planNoTiers ? "off" : "on"), variant \(BotVariant.flags.sorted())")
        print("PlannerCostTests: gatePlanChoice per call: p50 \(String(format: "%.3f", percentile(calls, 0.5))) ms, p99 \(String(format: "%.3f", percentile(calls, 0.99))) ms, max \(String(format: "%.3f", calls.max() ?? 0)) ms over \(calls.count) calls")
        print("PlannerCostTests: " + perBoat.joined(separator: "; "))

        // (2) One whole tick, the deciding third, on the frozen race: three phases.
        var ticks: [Double] = []
        var deciding: [Int] = []
        for _ in 0..<3 {
            deciding.append(controllers.seats.indices.filter { controllers.seats[$0].driver?.decides(atTick: race.tick) ?? false }.count)
            for _ in 0..<100 {
                var copy = controllers
                let start = clock.now
                copy.drive(race)
                ticks.append(ms(start.duration(to: clock.now)))
            }
            controllers.drive(race)
            race.step()
        }
        print("PlannerCostTests: whole tick of SeatControllers.drive (deciding seats \(deciding)): p50 \(String(format: "%.3f", percentile(ticks, 0.5))) ms, p99 \(String(format: "%.3f", percentile(ticks, 0.99))) ms, max \(String(format: "%.3f", ticks.max() ?? 0)) ms")
        #expect(!calls.isEmpty)
    }
}
