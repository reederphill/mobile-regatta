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
        interpreter.touchMoved(1, to: CGPoint(x: 190, y: 620))
        #expect(interpreter.tillerKnob == .init(origin: origin, knob: CGPoint(x: 190, y: 500)), "vertical ignored")
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
