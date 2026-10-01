import Foundation
import RegattaCore
import Testing
@testable import Regatta

/// Your roll ring (#222): it closes from the start of the tack to nothing at the boom crossing, and shows how the tap went.
@MainActor @Suite struct RollRingTests {
    static let window = 0.25
    static let seconds = 1.3

    /// A boat `degrees` off the wind (north) on port tack, at `heading`, her autohelm sailing the tap if `tapping`.
    static func boat(twaDegrees degrees: Double, tapping: Bool, roll: RollTack? = nil, isTacking: Bool = false) -> Boat {
        var boat = Boat(id: 0, isPlayer: true, colorIndex: 0, position: .zero, heading: deg2rad(degrees), speed: 3,
                        boomSide: .port)
        boat.sailingWind = Wind(direction: 0, speed: 6)
        boat.autohelm = tapping ? Autohelm(target: .groove(.upwind), isTapping: true) : nil
        boat.isTacking = isTacking
        boat.roll = roll
        return boat
    }

    /// From the start of the tack the ring closes as she comes up to the wind, reaching nothing at head to wind (where the
    /// boom crosses); it never grows back, and a tap in shows as a dot.
    @Test func approachClosesToNothingAtHeadToWind() throws {
        var timer = RollRingTimer()
        let start = timer.ring(for: Self.boat(twaDegrees: 45, tapping: true), window: Self.window, time: 0, seconds: Self.seconds)
        let half = timer.ring(for: Self.boat(twaDegrees: 22.5, tapping: true), window: Self.window, time: 1, seconds: Self.seconds)
        let tapped = timer.ring(for: Self.boat(twaDegrees: 11.25, tapping: true, roll: .pending(tapTick: 3)), window: Self.window,
                                time: 1.5, seconds: Self.seconds)
        let end = timer.ring(for: Self.boat(twaDegrees: 0, tapping: true), window: Self.window, time: 2, seconds: Self.seconds)
        let first = try #require(start), mid = try #require(half), late = try #require(tapped), last = try #require(end)
        #expect(first.kind == .approach && first.progress == 0 && first.radiusShare == 1 && !first.isTapped)
        #expect(abs(mid.progress - 0.5) < 1e-9 && abs(mid.radiusShare - 0.5) < 1e-9)
        #expect(late.isTapped && abs(late.progress - 0.75) < 1e-9)
        #expect(last.progress == 1 && last.radiusShare == 0)
        #expect(first.alphaShare < mid.alphaShare && mid.alphaShare < last.alphaShare, "brighter as it closes")
    }

    /// A ring that begins from a different angle closes from there; turning away never makes it grow past its start.
    @Test func approachClosesFromWhereTheTackStarted() throws {
        var timer = RollRingTimer()
        _ = timer.ring(for: Self.boat(twaDegrees: 40, tapping: true), window: Self.window, time: 0, seconds: Self.seconds)
        let turnedAway = timer.ring(for: Self.boat(twaDegrees: 50, tapping: true), window: Self.window, time: 0.1, seconds: Self.seconds)
        #expect(turnedAway?.progress == 0, "a new widest angle restarts it there")
        let closing = timer.ring(for: Self.boat(twaDegrees: 25, tapping: true), window: Self.window, time: 0.2, seconds: Self.seconds)
        #expect(abs((closing?.progress ?? 0) - 0.5) < 1e-9)
        // The next tack starts afresh.
        _ = timer.ring(for: Self.boat(twaDegrees: 60, tapping: false), window: Self.window, time: 5, seconds: Self.seconds)
        let next = timer.ring(for: Self.boat(twaDegrees: 30, tapping: true), window: Self.window, time: 6, seconds: Self.seconds)
        #expect(next?.progress == 0)
    }

    /// Nothing without a roll tack, on a gybe (it has no roll yet), or once the boom has crossed with no result yet.
    @Test func noRingWhereThereIsNoRoll() {
        var timer = RollRingTimer()
        let none = timer.ring(for: Self.boat(twaDegrees: 30, tapping: true), window: nil, time: 0, seconds: Self.seconds)
        let gybe = timer.ring(for: Self.boat(twaDegrees: 150, tapping: true), window: Self.window, time: 1, seconds: Self.seconds)
        let crossed = timer.ring(for: Self.boat(twaDegrees: 5, tapping: false, isTacking: true), window: Self.window, time: 2,
                                 seconds: Self.seconds)
        let idle = timer.ring(for: Self.boat(twaDegrees: 45, tapping: false), window: Self.window, time: 3, seconds: Self.seconds)
        #expect(none == nil && gybe == nil && crossed == nil && idle == nil)
    }

    /// A hit bursts out and a miss collapses in, each fading over `seconds` from when first drawn, however long the race
    /// holds it; time drawn again from an earlier moment starts it over.
    @Test func hitAndMissShowForTheirSecondsOnly() throws {
        for (roll, kind) in [(RollTack.hit, RollRing.Kind.hit), (.missed, .miss)] {
            var timer = RollRingTimer()
            let boat = Self.boat(twaDegrees: 20, tapping: false, roll: roll, isTacking: true)
            let firstRing = timer.ring(for: boat, window: Self.window, time: 5, seconds: Self.seconds)
            let midRing = timer.ring(for: boat, window: Self.window, time: 5.65, seconds: Self.seconds)
            let first = try #require(firstRing), mid = try #require(midRing)
            #expect(first.kind == kind && first.progress == 0 && abs(mid.progress - 0.5) < 1e-9)
            #expect(first.alphaShare == 1 && mid.alphaShare > 0.999 && first.isBroken == (kind == .miss), "holds bright, then fades")
            #expect((mid.radiusShare > first.radiusShare) == (kind == .hit))
            let fading = timer.ring(for: boat, window: Self.window, time: 6.1, seconds: Self.seconds)
            #expect((fading?.alphaShare ?? 1) < 0.5)
            let over = timer.ring(for: boat, window: Self.window, time: 6.4, seconds: Self.seconds)
            #expect(over == nil)
            let again = timer.ring(for: boat, window: Self.window, time: 4, seconds: Self.seconds)
            #expect(again?.progress == 0)
        }
    }
}
