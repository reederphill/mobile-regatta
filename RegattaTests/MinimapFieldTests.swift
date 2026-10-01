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

    /// A sample the race can't take (online, no key yet) isn't kept: it is tried again at the 2 s cadence, not at
    /// every refresh, and a failed sample later on keeps the last good image.
    @Test func aMissingSampleIsRetried() throws {
        let world = try WaterTests.pressureWorld()
        let t0 = world.frame.tick
        var calls = 0
        var holdsKey = false
        let field = MinimapField { world, chart in
            calls += 1
            return holdsKey ? world.windSampler.map(chart.pressure) : nil
        }
        field.refresh(world)
        field.refresh(Self.world(world, tick: t0 + 1))
        #expect(calls == 1 && field.image == nil, "a failed sample waits for the cadence")
        holdsKey = true
        field.refresh(Self.world(world, tick: t0 + MinimapField.interval))
        field.refresh(Self.world(world, tick: t0 + MinimapField.interval + 1))
        #expect(calls == 2 && field.image != nil)
        let good = try #require(field.image)
        holdsKey = false
        let image = field.refresh(Self.world(world, tick: t0 + 2 * MinimapField.interval))
        #expect(calls == 3 && image === good && field.image === good, "a failed sample keeps the last good image")
    }

    /// A key replaced in its window (same count of keys) resamples at once.
    @Test func aReplacedKeyResamples() throws {
        let world = try WaterTests.pressureWorld()
        var calls = 0
        let field = MinimapField { world, chart in
            calls += 1
            return world.windSampler.map(chart.pressure)
        }
        field.refresh(world)
        #expect(calls == 1)
        let key = try #require(world.frame.wind.keys.keys.last)
        var wind = world.frame.wind
        wind.add(WindKey(window: key.window, shift: key.shift, strength: key.strength, wobble: key.wobble,
                         puffSeed: key.puffSeed &+ 1))
        #expect(wind.keys.keys.count == world.frame.wind.keys.keys.count)
        field.refresh(Self.world(world, tick: world.frame.tick, wind: wind))
        #expect(calls == 2)
    }

    /// `world` with its latest frame moved to `tick`, the fleet unchanged and the wind `wind` or unchanged.
    private static func world(_ world: RenderWorld, tick: Int, wind: WindField? = nil) -> RenderWorld {
        let f = world.frame
        let frame = TickFrame(tick: tick, boats: f.boats, standings: f.standings, wind: wind ?? f.wind, isOver: f.isOver)
        return RenderWorld(course: world.course, boatClass: world.boatClass, myBoatIndex: world.myBoatIndex,
                           previous: frame, current: frame, alpha: 1)
    }
}
