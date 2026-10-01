import Foundation
import Testing
import RegattaCore
@testable import Regatta

/// The race HUD's words and tones (#114): place, OCS and the ground wind, the clock's colour in each phase, and the
/// countdown to the close after the first finish.
@MainActor @Suite struct HUDModelTests {
    private static func hud(tick: Int, status: BoatStatus = .racing, place: Int = 4, fleet: Int = 10,
                            closeTick: Int? = nil) -> HUDState {
        var hud = HUDState()
        hud.tick = tick
        hud.clock = Double(tick) / Double(Race.tickRate)
        hud.status = status
        hud.place = place
        hud.fleet = fleet
        hud.closeTick = closeTick
        return hud
    }

    @Test func formatsPlaceOCSAndWind() {
        #expect(HUDModel(Self.hud(tick: 600)).placeText == "4th/10")
        #expect(HUDModel(Self.hud(tick: 600, place: 1, fleet: 8)).placeText == "1st/8")
        #expect(HUDModel(Self.hud(tick: 600, place: 12)).placeText == "12th/10")
        #expect(HUDModel(Self.hud(tick: 60, status: .ocs)).placeText == "OCS")
        #expect(HUDModel(Self.hud(tick: 6000, status: .dsq)).placeText == "DSQ")
        #expect(HUDModel(Self.hud(tick: 6000, status: .finished, place: 2)).placeText == "2nd/10")
        // Before the gun the standings mean nothing: the place is hidden (its space kept).
        #expect(HUDModel(Self.hud(tick: -300, status: .prestart)).placeText == nil)
        // Late over the line after the gun: placed like anyone racing.
        #expect(HUDModel(Self.hud(tick: 90, status: .prestart)).placeText == "4th/10")

        var hud = Self.hud(tick: 600)
        hud.windKnots = 12.3
        hud.windDirection = deg2rad(352)
        #expect(HUDModel(hud).windText == "12 kn, from 352°")
        // From the compass, wrapped: −8° is 352°, and 359.6° rounds to 0°, never 360°.
        #expect(HUDModel.windText(knots: 11.6, direction: deg2rad(-8)) == "12 kn, from 352°")
        #expect(HUDModel.windText(knots: 7.4, direction: deg2rad(359.6)) == "7 kn, from 0°")
        #expect(HUDModel.windText(knots: 9, direction: deg2rad(45)) == "9 kn, from 45°")
    }

    @Test func clockColourPerPhaseInclAfterFirstFinish() {
        // The start sequence: yellow, counting down.
        let sequence = HUDModel(Self.hud(tick: -1500, status: .prestart))
        #expect(sequence.clockTone == .yellow && sequence.clockText == "-0:50")
        // Racing: white, counting up.
        let racing = HUDModel(Self.hud(tick: 1830))
        #expect(racing.clockTone == .white && racing.clockText == "1:01")
        // After the first finish: yellow again, counting down to the close.
        let closing = HUDModel(Self.hud(tick: 9000, closeTick: 9000 + 75 * Race.tickRate))
        #expect(closing.clockTone == .yellow && closing.clockText == "-1:15")
        // Whatever your own status: you've finished too, or not started.
        #expect(HUDModel(Self.hud(tick: 9000, status: .finished, closeTick: 9600)).clockTone == .yellow)
        #expect(HUDModel(Self.hud(tick: 9600, closeTick: 9600)).clockText == "0:00")
    }

    /// The close the countdown reads is the race's (`Race.closeTick` through `TickFrame.closeTick`): the earlier of
    /// the first finish plus the 120 s finish window and the gun plus the 960 s time limit; none before a finish.
    @Test func closeCountdownIsEarlierOfFirstFinishPlus120AndGunPlus960() throws {
        let race = Race(setup: RaceDriverTests.config.setup, windSeed: WindSeed(7))
        #expect(TickFrame(race: race).closeTick == nil, "no countdown before anyone has finished")
        #expect(HUDModel(HUDState()).closeCountdown == nil)

        func frame(firstFinish seconds: Double) throws -> TickFrame {
            var snapshot = race.exportSnapshot()
            snapshot.firstFinishTime = seconds
            try race.importSnapshot(snapshot)
            return TickFrame(race: race)
        }
        // A first finish at 5:00: the finish window closes first, at 7:00.
        let early = try frame(firstFinish: 300)
        #expect(early.closeTick == 420 * Race.tickRate)
        // A first finish at 15:00: the time limit, at 16:00, comes before 17:00.
        let late = try frame(firstFinish: 900)
        #expect(late.closeTick == 960 * Race.tickRate)

        // The HUD counts down to it from the frame's tick.
        var hud = Self.hud(tick: 400 * Race.tickRate, closeTick: early.closeTick)
        #expect(HUDModel(hud).closeCountdown == -20)
        #expect(HUDModel(hud).clockText == "-0:20")
        hud = Self.hud(tick: 930 * Race.tickRate + 15, closeTick: late.closeTick)
        #expect(HUDModel(hud).clockText == "-0:30")
    }

    /// The wind arrow turns by the live view heading, read when it draws, not a copy taken at the HUD's 15 Hz
    /// refresh (#317's review): the same HUD state reads differently as the view turns.
    @Test func windArrowUsesTheLiveHeading() {
        var heading = 0.0
        let read = { heading }
        let direction = deg2rad(90)
        #expect(abs(HUDModel.screenAngle(ofCompass: direction, viewHeading: read()) - deg2rad(90)) < 1e-12)
        heading = deg2rad(30)
        #expect(abs(HUDModel.screenAngle(ofCompass: direction, viewHeading: read()) - deg2rad(60)) < 1e-12)
        let fields = Mirror(reflecting: HUDState()).children.compactMap(\.label)
        #expect(!fields.contains("viewHeading"), "the HUD state holds no copied view heading")
    }
}
