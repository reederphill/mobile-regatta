import CoreGraphics
import Foundation
import RegattaCore
import Testing
@testable import Regatta

/// Touches to rudder in both steering schemes (#13, #112).
@Suite struct SteeringInterpreterTests {
    private static let midX: CGFloat = 200
    private static let left = CGPoint(x: 50, y: 400)
    private static let right = CGPoint(x: 350, y: 400)

    /// Advances `interpreter` in 60 Hz frames until the rudder is full, and returns the seconds that took.
    private func secondsToFull(_ interpreter: inout SteeringInterpreter, dt: Double = 1.0 / 60) -> Double {
        var t = 0.0
        while abs(interpreter.advance(by: dt)) < 1, t < 2 { t += dt }
        return t + dt
    }

    @Test func halvesReachesFullAt0_29s() {
        var port = SteeringInterpreter(scheme: .halves)
        port.touchBegan(1, at: Self.left, midX: Self.midX)
        let portSeconds = secondsToFull(&port)
        #expect(abs(portSeconds - 0.29) <= 0.03, "port full after \(portSeconds) s")
        #expect(port.rudder == -1)

        var starboard = SteeringInterpreter(scheme: .halves)
        starboard.touchBegan(1, at: Self.right, midX: Self.midX)
        let starboardSeconds = secondsToFull(&starboard)
        #expect(abs(starboardSeconds - 0.29) <= 0.03, "starboard full after \(starboardSeconds) s")
        #expect(starboard.rudder == 1)

        // Half way there after half the time: short taps make small corrections.
        var tap = SteeringInterpreter(scheme: .halves)
        tap.touchBegan(1, at: Self.right, midX: Self.midX)
        #expect(abs(tap.advance(by: 0.1) - 0.35) < 1e-9)
    }

    @Test func bothHalvesGiveZero() {
        var interpreter = SteeringInterpreter(scheme: .halves)
        interpreter.touchBegan(1, at: Self.right, midX: Self.midX)
        #expect(interpreter.advance(by: 0.1) > 0)
        interpreter.touchBegan(2, at: Self.left, midX: Self.midX)
        #expect(interpreter.advance(by: 1.0 / 60) == 0)
        #expect(interpreter.advance(by: 0.5) == 0)
        // Lifting one side steers to the other.
        interpreter.touchEnded(2)
        #expect(interpreter.advance(by: 0.1) > 0)
    }

    @Test func releaseCentresImmediately() {
        var halves = SteeringInterpreter(scheme: .halves)
        halves.touchBegan(1, at: Self.left, midX: Self.midX)
        #expect(halves.advance(by: 0.5) == -1)
        halves.touchEnded(1)
        #expect(halves.rudder == 0, "centred on release, before the next frame")
        #expect(halves.advance(by: 1.0 / 60) == 0)

        // Moving a finger across the middle doesn't change the side it landed on.
        halves.touchBegan(2, at: Self.left, midX: Self.midX)
        halves.touchMoved(2, to: Self.right)
        #expect(halves.advance(by: 0.5) == -1)

        var tiller = SteeringInterpreter(scheme: .tiller)
        tiller.touchBegan(1, at: CGPoint(x: 100, y: 300), midX: Self.midX)
        tiller.touchMoved(1, to: CGPoint(x: 180, y: 300))
        #expect(tiller.advance(by: 1.0 / 60) == 1)
        tiller.touchEnded(1)
        #expect(tiller.rudder == 0)
        #expect(tiller.advance(by: 1.0 / 60) == 0)
    }

    @Test func tillerMapsHorizontalOffset() {
        let origin = CGPoint(x: 150, y: 500)
        func rudder(movedBy dx: CGFloat, _ dy: CGFloat = 0) -> Double {
            var interpreter = SteeringInterpreter(scheme: .tiller)
            interpreter.touchBegan(1, at: origin, midX: Self.midX)
            interpreter.touchMoved(1, to: CGPoint(x: origin.x + dx, y: origin.y + dy))
            return interpreter.advance(by: 1.0 / 60)
        }
        #expect(rudder(movedBy: 40) == 0.5)
        #expect(rudder(movedBy: 120) == 1.0)
        #expect(rudder(movedBy: -40) == -0.5)
        #expect(rudder(movedBy: -120) == -1.0)
        #expect(rudder(movedBy: 0, 100) == 0, "vertical is ignored")
        #expect(rudder(movedBy: 40, -100) == 0.5)
        // Touch-down alone is a centred rudder: the autohelm sails on (#230).
        #expect(rudder(movedBy: 0) == 0)

        // The first finger down steers; a second is ignored.
        var interpreter = SteeringInterpreter(scheme: .tiller)
        interpreter.touchBegan(1, at: origin, midX: Self.midX)
        interpreter.touchBegan(2, at: CGPoint(x: 300, y: 200), midX: Self.midX)
        interpreter.touchMoved(2, to: CGPoint(x: 380, y: 200))
        #expect(interpreter.advance(by: 1.0 / 60) == 0)
        interpreter.touchMoved(1, to: CGPoint(x: origin.x - 20, y: origin.y))
        #expect(interpreter.advance(by: 1.0 / 60) == -0.25)
    }

    @Test func pinchZoomBeginClearsHeldSteering() {
        var halves = SteeringInterpreter(scheme: .halves)
        halves.touchBegan(1, at: Self.right, midX: Self.midX)
        #expect(halves.advance(by: 0.1) > 0)
        halves.pinchBegan()
        #expect(halves.rudder == 0)
        // Its fingers, and one landing during the pinch-zoom, don't steer while it lasts, or after, until they lift.
        halves.touchBegan(2, at: Self.left, midX: Self.midX)
        #expect(halves.advance(by: 0.5) == 0)
        halves.pinchEnded()
        #expect(halves.advance(by: 0.5) == 0)
        halves.touchEnded(1)
        halves.touchEnded(2)
        // A new touch after it steers again.
        halves.touchBegan(3, at: Self.left, midX: Self.midX)
        #expect(halves.advance(by: 0.5) == -1)

        var tiller = SteeringInterpreter(scheme: .tiller)
        tiller.touchBegan(1, at: Self.left, midX: Self.midX)
        tiller.touchMoved(1, to: CGPoint(x: Self.left.x + 60, y: Self.left.y))
        tiller.pinchBegan()
        #expect(tiller.rudder == 0)
        #expect(tiller.tillerKnob == nil)
        tiller.touchMoved(1, to: CGPoint(x: Self.left.x + 80, y: Self.left.y))
        #expect(tiller.advance(by: 1.0 / 60) == 0)
    }

    @Test func tillerKnobFollowsClampedOffset() throws {
        let origin = CGPoint(x: 150, y: 500)
        var interpreter = SteeringInterpreter(scheme: .tiller)
        #expect(interpreter.tillerKnob == nil, "nothing while not held")
        interpreter.touchBegan(1, at: origin, midX: Self.midX)
        #expect(interpreter.tillerKnob == .init(origin: origin, knob: origin))
        interpreter.touchMoved(1, to: CGPoint(x: 190, y: 520))
        #expect(interpreter.tillerKnob == .init(origin: origin, knob: CGPoint(x: 190, y: 520)), "follows a pull down")
        interpreter.touchMoved(1, to: CGPoint(x: 190, y: 620))
        #expect(interpreter.tillerKnob == .init(origin: origin, knob: CGPoint(x: 190, y: 544), isEasing: true),
                "down as far as the ease line (#453)")
        interpreter.touchMoved(1, to: CGPoint(x: 190, y: 400))
        #expect(interpreter.tillerKnob == .init(origin: origin, knob: CGPoint(x: 190, y: 500)), "up is ignored")
        interpreter.touchMoved(1, to: CGPoint(x: 400, y: 500))
        #expect(interpreter.tillerKnob?.knob == CGPoint(x: 230, y: 500), "clamped to +80 pt")
        interpreter.touchMoved(1, to: CGPoint(x: -100, y: 300))
        #expect(interpreter.tillerKnob?.knob == CGPoint(x: 70, y: 500), "clamped to -80 pt")
        interpreter.touchEnded(1)
        #expect(interpreter.tillerKnob == nil, "gone on release")

        var halves = SteeringInterpreter(scheme: .halves)
        halves.touchBegan(1, at: origin, midX: Self.midX)
        halves.touchMoved(1, to: CGPoint(x: 190, y: 500))
        #expect(halves.tillerKnob == nil, "never in halves")
    }

    // MARK: - Ease gesture (#453)

    private static let frame = 1.0 / 60

    /// Advances `interpreter` by `seconds` in 60 Hz frames.
    private func advance(_ interpreter: inout SteeringInterpreter, _ seconds: Double) {
        for _ in 0..<Int((seconds / Self.frame).rounded()) { _ = interpreter.advance(by: Self.frame) }
    }

    private func bothHalves() -> SteeringInterpreter {
        var interpreter = SteeringInterpreter(scheme: .halves)
        interpreter.touchBegan(1, at: Self.left, midX: Self.midX)
        interpreter.touchBegan(2, at: Self.right, midX: Self.midX)
        return interpreter
    }

    /// 1: both halves held the hold delay ease, the rudder centred.
    @Test func bothHalvesHeldEaseAfterTheHoldDelay() {
        var interpreter = bothHalves()
        advance(&interpreter, 0.15)
        #expect(!interpreter.isEasing, "not before 0.2 s")
        #expect(interpreter.rudder == 0)
        advance(&interpreter, 0.05)
        #expect(interpreter.isEasing, "eased at 0.2 s")
        #expect(interpreter.rudder == 0)
        advance(&interpreter, 1)
        #expect(interpreter.isEasing && interpreter.rudder == 0, "held")
    }

    /// 2: both halves held under the hold delay, then lifted, never ease.
    @Test func aShortBothHalvesHoldNeverEases() {
        var interpreter = bothHalves()
        advance(&interpreter, 0.15)
        interpreter.touchEnded(1)
        interpreter.touchEnded(2)
        advance(&interpreter, 0.5)
        #expect(!interpreter.isEasing)
        // Nor does a fresh pair's hold carry the old one's time.
        interpreter.touchBegan(3, at: Self.left, midX: Self.midX)
        advance(&interpreter, 0.1)
        interpreter.touchBegan(4, at: Self.right, midX: Self.midX)
        advance(&interpreter, 0.15)
        #expect(!interpreter.isEasing, "the hold starts when both sides are held")
        advance(&interpreter, 0.05)
        #expect(interpreter.isEasing)
    }

    /// 3: lifting one finger ends the ease, and the rudder ramps to the side still held.
    @Test func liftingOneFingerEndsTheEase() {
        var interpreter = bothHalves()
        advance(&interpreter, 0.3)
        #expect(interpreter.isEasing)
        interpreter.touchEnded(1)
        #expect(!interpreter.isEasing, "ended on the lift, before the next frame")
        #expect(abs(interpreter.advance(by: 0.1) - 0.35) < 1e-9, "ramps to starboard")
        advance(&interpreter, 1)
        #expect(!interpreter.isEasing && interpreter.rudder == 1)
    }

    /// 4: two fingers on one half are no ease.
    @Test func twoFingersOnOneHalfDontEase() {
        var interpreter = SteeringInterpreter(scheme: .halves)
        interpreter.touchBegan(1, at: Self.left, midX: Self.midX)
        interpreter.touchBegan(2, at: CGPoint(x: 120, y: 600), midX: Self.midX)
        advance(&interpreter, 1)
        #expect(!interpreter.isEasing)
        #expect(interpreter.rudder == -1)
    }

    /// 5: a pinch-zoom recognised before the hold delay is no ease: rudder centred, its fingers ignored.
    @Test func pinchZoomBeforeTheHoldDelayIsNoEase() {
        var interpreter = bothHalves()
        advance(&interpreter, 0.1)
        interpreter.pinchBegan()
        #expect(!interpreter.isEasing && interpreter.rudder == 0)
        advance(&interpreter, 1)
        #expect(!interpreter.isEasing && interpreter.rudder == 0, "its fingers neither ease nor steer")
        interpreter.pinchEnded()
        advance(&interpreter, 1)
        #expect(!interpreter.isEasing && interpreter.rudder == 0, "not after it either, until they lift")
        // One of the pinch's fingers lifts and lands again: with the other still the pinch's, no ease.
        interpreter.touchEnded(1)
        interpreter.touchBegan(3, at: Self.left, midX: Self.midX)
        advance(&interpreter, 0.5)
        #expect(!interpreter.isEasing, "both fingers must be fresh")
        #expect(interpreter.rudder == -1, "the fresh finger steers")
        interpreter.touchEnded(2)
        interpreter.touchBegan(4, at: Self.right, midX: Self.midX)
        advance(&interpreter, 0.2)
        #expect(interpreter.isEasing, "two fresh fingers ease")
    }

    /// 6: a finger moving past the slop before the hold delay is a pinch-zoom's, no ease; within it, an ease.
    @Test func aFingerMovingPastTheSlopIsNoEase() {
        var moved = bothHalves()
        advance(&moved, 0.1)
        moved.touchMoved(2, to: CGPoint(x: Self.right.x + 8, y: Self.right.y + 8))
        advance(&moved, 0.5)
        #expect(!moved.isEasing, "11.3 pt from where it landed")
        #expect(moved.rudder == 0, "both halves held still centre the rudder")

        var still = bothHalves()
        advance(&still, 0.1)
        still.touchMoved(2, to: CGPoint(x: Self.right.x + 6, y: Self.right.y + 7))
        advance(&still, 0.1)
        #expect(still.isEasing, "9.2 pt: a held thumb's wobble")
        // Once eased, a wobble past the slop doesn't end it.
        still.touchMoved(1, to: CGPoint(x: Self.left.x + 30, y: Self.left.y))
        advance(&still, 0.5)
        #expect(still.isEasing)
    }

    /// 7: a pinch-zoom recognised while eased ends the ease.
    @Test func pinchZoomWhileEasedEndsTheEase() {
        var interpreter = bothHalves()
        advance(&interpreter, 0.3)
        #expect(interpreter.isEasing)
        interpreter.pinchBegan()
        #expect(!interpreter.isEasing && interpreter.rudder == 0)
        advance(&interpreter, 0.5)
        #expect(!interpreter.isEasing)

        var tiller = SteeringInterpreter(scheme: .tiller)
        tiller.touchBegan(1, at: CGPoint(x: 150, y: 500), midX: Self.midX)
        tiller.touchMoved(1, to: CGPoint(x: 150, y: 560))
        #expect(tiller.isEasing)
        tiller.pinchBegan()
        #expect(!tiller.isEasing)
    }

    /// 8: the tiller eases pulled down 44 pt and lets go back above 32 pt, steering sideways all the while.
    @Test func tillerPullDownEasesWithHysteresis() {
        let origin = CGPoint(x: 150, y: 500)
        var interpreter = SteeringInterpreter(scheme: .tiller)
        interpreter.touchBegan(1, at: origin, midX: Self.midX)
        interpreter.touchMoved(1, to: CGPoint(x: 150, y: 543))
        #expect(!interpreter.isEasing, "43 pt")
        interpreter.touchMoved(1, to: CGPoint(x: 150, y: 544))
        #expect(interpreter.isEasing, "44 pt")
        interpreter.touchMoved(1, to: CGPoint(x: 150, y: 533))
        #expect(interpreter.isEasing, "holds at 33 pt")
        interpreter.touchMoved(1, to: CGPoint(x: 150, y: 531))
        #expect(!interpreter.isEasing, "falls back at 31 pt")
        interpreter.touchMoved(1, to: CGPoint(x: 150, y: 540))
        #expect(!interpreter.isEasing, "not again until the engage line")

        // Eased and steering at once.
        interpreter.touchMoved(1, to: CGPoint(x: 150, y: 560))
        interpreter.touchMoved(1, to: CGPoint(x: 190, y: 560))
        #expect(interpreter.isEasing)
        #expect(interpreter.advance(by: Self.frame) == 0.5)
        #expect(interpreter.isEasing, "advancing keeps it")
        interpreter.touchEnded(1)
        #expect(!interpreter.isEasing, "lifting ends it")
        #expect(interpreter.rudder == 0)
    }

    /// 9: a full-lock diagonal slide, and any pull up, don't ease.
    @Test func tillerDiagonalOrUpwardPullDoesntEase() {
        let origin = CGPoint(x: 150, y: 500)
        func eases(movedBy dx: CGFloat, _ dy: CGFloat) -> Bool {
            var interpreter = SteeringInterpreter(scheme: .tiller)
            interpreter.touchBegan(1, at: origin, midX: Self.midX)
            interpreter.touchMoved(1, to: CGPoint(x: origin.x + dx, y: origin.y + dy))
            _ = interpreter.advance(by: Self.frame)
            return interpreter.isEasing
        }
        #expect(!eases(movedBy: 80, 40), "full lock, a thumb's arc")
        #expect(!eases(movedBy: 120, 50), "past full lock: more sideways than down")
        #expect(!eases(movedBy: -100, 48))
        #expect(eases(movedBy: 80, 48), "down more than half the sideways")
        #expect(!eases(movedBy: 0, -100), "up is ignored")
        #expect(!eases(movedBy: 40, -60))
    }

    /// 10: a reset (an overlay, a pause) or a scheme change lets go of the ease.
    @Test func resetAndSchemeChangeClearTheEase() {
        var halves = bothHalves()
        advance(&halves, 0.3)
        #expect(halves.isEasing)
        halves.reset()
        #expect(!halves.isEasing)
        advance(&halves, 0.3)
        #expect(!halves.isEasing)

        var switched = bothHalves()
        advance(&switched, 0.3)
        switched.scheme = .tiller
        #expect(!switched.isEasing)

        var tiller = SteeringInterpreter(scheme: .tiller)
        tiller.touchBegan(1, at: CGPoint(x: 150, y: 500), midX: Self.midX)
        tiller.touchMoved(1, to: CGPoint(x: 150, y: 560))
        #expect(tiller.isEasing)
        tiller.reset()
        #expect(!tiller.isEasing && tiller.tillerKnob == nil)
    }

    /// The thresholds are tuning values (fun before realism): the interpreter reads them live.
    @Test func easeThresholdsFollowTheTuning() {
        var interpreter = bothHalves()
        interpreter.easeTuning.holdDelaySeconds = 0.5
        advance(&interpreter, 0.3)
        #expect(!interpreter.isEasing)
        advance(&interpreter, 0.2)
        #expect(interpreter.isEasing)

        var tiller = SteeringInterpreter(scheme: .tiller)
        tiller.easeTuning.tillerEngagePoints = 60
        tiller.touchBegan(1, at: CGPoint(x: 150, y: 500), midX: Self.midX)
        tiller.touchMoved(1, to: CGPoint(x: 150, y: 550))
        #expect(!tiller.isEasing)
        #expect(tiller.tillerKnob?.easeLine == 60)
        tiller.touchMoved(1, to: CGPoint(x: 150, y: 560))
        #expect(tiller.isEasing)
    }

    /// A scheme switch mid-race (#131) lets go of every touch.
    @Test func changingSchemeLetsGo() {
        var interpreter = SteeringInterpreter(scheme: .halves)
        interpreter.touchBegan(1, at: Self.right, midX: Self.midX)
        #expect(interpreter.advance(by: 0.1) > 0)
        interpreter.scheme = .tiller
        #expect(interpreter.rudder == 0)
        interpreter.touchMoved(1, to: CGPoint(x: 400, y: 400))
        #expect(interpreter.advance(by: 0.1) == 0)
        #expect(interpreter.tillerKnob == nil)
    }
}

/// The scheme is Settings', with `-scheme` over it; the edge labels show only in a first race with halves (#23).
@MainActor @Suite struct SteeringSchemeTests {
    @Test func launchOverrideWinsOverTheStoredScheme() {
        #expect(ControlSettings.steering(.halves, override: nil) == .halves)
        #expect(ControlSettings.steering(.tiller, override: nil) == .tiller)
        #expect(ControlSettings.steering(.halves, override: .tiller) == .tiller)
        #expect(ControlSettings.steering(.tiller, override: .halves) == .halves)
    }

    /// The model's scheme follows Settings once per change, under `-scheme` when a test launch sets one.
    @Test func theModelsSchemeFollowsItsSettings() throws {
        let name = "SteeringSchemeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var stored = DeviceSettings()
        stored.steering = .tiller
        stored.save(to: defaults)

        let model = AppModel(sceneState: SceneState(), launchOptions: LaunchOptions(arguments: ["/path/to/Regatta"]), defaults: defaults)
        #expect(model.controls.steering == .tiller)
        model.deviceSettings.steering = .halves
        #expect(model.controls.steering == .halves)
        #expect(model.practiceSession(config: RaceConfig(opponents: 1, seed: 1, windSeed: RaceConfig.windSeed(pinnedTo: 1))).controls === model.controls)

        let overridden = AppModel(sceneState: SceneState(),
                                  launchOptions: LaunchOptions(arguments: ["/path/to/Regatta", "-scheme", "halves"]),
                                  defaults: defaults)
        overridden.deviceSettings.steering = .tiller
        #expect(overridden.controls.steering == .halves)
    }

    @Test func edgeLabelsOnlyInFirstRaceWithHalves() {
        #expect(GameSession.showsEdgeLabels(isFirstRace: true, steering: .halves))
        #expect(!GameSession.showsEdgeLabels(isFirstRace: true, steering: .tiller))
        #expect(!GameSession.showsEdgeLabels(isFirstRace: false, steering: .halves))
        #expect(!GameSession.showsEdgeLabels(isFirstRace: false, steering: .tiller))
    }
}
