import Foundation
import Testing
import RegattaCore
@testable import Regatta

/// The minimap's pressure is sampled at most every 2 s of race time and on a wind key change, not at every 15 Hz HUD
/// refresh (#289, #310, #114).
@MainActor @Suite struct MinimapFieldTests {
    @Test func samplesEveryTwoSecondsNotEveryRefresh() throws {
        let world = try WaterTests.pressureWorld()
        var calls = 0
        let field = MinimapField { world, chart in
            calls += 1
            return world.windSampler.map(chart.pressure)
        }
        // A second of HUD refreshes at 15 Hz, on one tick and on ticks under 2 s on: one sample.
        for _ in 0..<15 { field.refresh(world) }
        #expect(calls == 1)
        #expect(field.image != nil)
        let later = Self.world(world, tick: world.frame.tick + MinimapField.interval - 1)
        field.refresh(later)
        #expect(calls == 1)
        // Two seconds on: sampled again.
        field.refresh(Self.world(world, tick: world.frame.tick + MinimapField.interval))
        #expect(calls == 2)
    }

    /// A sample the race can't take (online, no key yet) isn't kept: the next refresh tries again.
    @Test func aMissingSampleIsRetried() throws {
        let world = try WaterTests.pressureWorld()
        var calls = 0
        var holdsKey = false
        let field = MinimapField { world, chart in
            calls += 1
            return holdsKey ? world.windSampler.map(chart.pressure) : nil
        }
        field.refresh(world)
        field.refresh(world)
        #expect(calls == 2 && field.image == nil)
        holdsKey = true
        field.refresh(world)
        field.refresh(world)
        #expect(calls == 3 && field.image != nil)
    }

    /// `world` with its latest frame moved to `tick`, the fleet and wind unchanged.
    private static func world(_ world: RenderWorld, tick: Int) -> RenderWorld {
        let f = world.frame
        let frame = TickFrame(tick: tick, boats: f.boats, standings: f.standings, wind: f.wind, isOver: f.isOver)
        return RenderWorld(course: world.course, boatClass: world.boatClass, myBoatIndex: world.myBoatIndex,
                           previous: frame, current: frame, alpha: 1)
    }
}
