import Foundation
import RegattaCore
import Testing
@testable import Regatta

/// Your roll ring (#222): when to tap after the boom crosses, and how the tap went.
@MainActor @Suite struct RollRingTests {
    static let window = 0.5
    static let seconds = 0.7

    static func tacking(crossedAtTick tick: Int? = 90, roll: RollTack? = nil) -> Boat {
        var boat = WakeTests.boat(speed: 3)
        boat.isTacking = true
        boat.tackCrossingTick = tick
        boat.roll = roll
        return boat
    }

    /// After the crossing the ring closes over the window, then is gone; before it, and when not tacking, nothing.
    @Test func windowRingClosesOverTheWindow() throws {
        var timer = RollRingTimer()
        let crossing = 90.0 / Double(Race.tickRate)
        let boat = Self.tacking()
        let before = timer.ring(for: boat, window: Self.window, time: crossing - 0.1, seconds: Self.seconds)
        #expect(before == nil)
        let startRing = timer.ring(for: boat, window: Self.window, time: crossing, seconds: Self.seconds)
        let start = try #require(startRing)
        let lateRing = timer.ring(for: boat, window: Self.window, time: crossing + 0.4, seconds: Self.seconds)
        let late = try #require(lateRing)
        #expect(start.kind == .window && late.kind == .window)
        #expect(start.progress == 0 && late.progress > 0.7)
        #expect(late.radiusShare < start.radiusShare)
        let after = timer.ring(for: boat, window: Self.window, time: crossing + 0.6, seconds: Self.seconds)
        #expect(after == nil)

        var upright = boat
        upright.isTacking = false
        upright.tackCrossingTick = nil
        let notTacking = timer.ring(for: upright, window: Self.window, time: crossing, seconds: Self.seconds)
        let noRoll = timer.ring(for: boat, window: nil, time: crossing, seconds: Self.seconds)
        #expect(notTacking == nil)
        #expect(noRoll == nil, "a class with no roll tack")
    }

    /// A tap waiting on the crossing shows a steady ring; a hit bursts out and a miss collapses in, each fading over
    /// `seconds` from when first drawn, however long the race holds it.
    @Test func hitAndMissShowForTheirSecondsOnly() throws {
        var timer = RollRingTimer()
        let pending = Self.tacking(crossedAtTick: nil, roll: .pending(tapTick: 80))
        let waiting = timer.ring(for: pending, window: Self.window, time: 2, seconds: Self.seconds)
        #expect(waiting?.kind == .pending)

        for (roll, kind) in [(RollTack.hit, RollRing.Kind.hit), (.missed, .miss)] {
            var timer = RollRingTimer()
            let boat = Self.tacking(roll: roll)
            let firstRing = timer.ring(for: boat, window: Self.window, time: 5, seconds: Self.seconds)
            let first = try #require(firstRing)
            let midRing = timer.ring(for: boat, window: Self.window, time: 5.35, seconds: Self.seconds)
            let mid = try #require(midRing)
            #expect(first.kind == kind && first.progress == 0 && mid.progress > 0.4 && mid.alphaShare < first.alphaShare)
            #expect(first.isBroken == (kind == .miss))
            #expect((mid.radiusShare > first.radiusShare) == (kind == .hit))
            let over = timer.ring(for: boat, window: Self.window, time: 5.8, seconds: Self.seconds)
            #expect(over == nil)
            // Drawn again from an earlier time (an online re-prediction): it starts over.
            let again = timer.ring(for: boat, window: Self.window, time: 4, seconds: Self.seconds)
            #expect(again?.progress == 0)
        }
    }
}
