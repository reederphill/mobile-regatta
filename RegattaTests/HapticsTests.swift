import Foundation
import Testing
import RegattaCore
@testable import Regatta

/// Haptics go through one gate (#110): with Settings' Haptics off, no call reaches a generator.
@MainActor @Suite struct HapticsTests {
    private static let config = RaceConfig(opponents: 1, prestartSeconds: 30, seed: 1, windSeed: RaceConfig.windSeed(pinnedTo: 1))

    /// Records what reaches it.
    final class RecordingGenerator: HapticGenerator {
        var calls: [String] = []
        func impact(intensity: Double) { calls.append("impact \(intensity)") }
        func notify(_ kind: HapticNotification) { calls.append("notify \(kind)") }
    }

    @Test func hapticsOffMakesNoGeneratorCalls() {
        let generator = RecordingGenerator()
        let haptics = GatedHaptics(generator: generator, isOn: false)
        haptics.impact(intensity: 1)
        haptics.notify(.error)
        #expect(generator.calls.isEmpty)
        // Switching Haptics on takes effect at once.
        haptics.isOn = true
        haptics.impact(intensity: 0.5)
        haptics.notify(.success)
        #expect(generator.calls == ["impact 0.5", "notify success"])

        // A race's haptics all go through the gate: the gun with Haptics off reaches no generator.
        let gun = RaceEvent(tick: 0, kind: .gun)
        let silent = RecordingGenerator()
        GameSession(config: Self.config, haptics: GatedHaptics(generator: silent, isOn: false)).consume([gun])
        #expect(silent.calls.isEmpty)
        let heard = RecordingGenerator()
        GameSession(config: Self.config, haptics: GatedHaptics(generator: heard, isOn: true)).consume([gun])
        #expect(heard.calls.contains("impact 1.0"), "the gun")
    }

    /// The tack tap has no haptic (#112, #124).
    @Test func aTackTapPlaysNoHaptic() {
        let heard = RecordingGenerator()
        let session = GameSession(config: Self.config, haptics: GatedHaptics(generator: heard, isOn: true))
        session.tackOrGybe()
        session.pressTack(at: 10)
        session.releaseTack(at: 11)
        #expect(heard.calls.isEmpty)
    }

    /// The app's gate follows the model's settings, in the model's own defaults: it starts as they say, and Settings'
    /// Haptics switches it once per change.
    @Test func theModelsGateFollowsItsSettings() throws {
        let name = "HapticsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var stored = DeviceSettings()
        stored.haptics = false
        stored.save(to: defaults)

        let model = AppModel(sceneState: SceneState(), defaults: defaults)
        #expect(!model.haptics.isOn)
        model.deviceSettings.haptics = true
        #expect(model.haptics.isOn)
        #expect(DeviceSettings(defaults: defaults).haptics)
        model.deviceSettings.haptics = false
        #expect(!model.haptics.isOn)
    }
}
