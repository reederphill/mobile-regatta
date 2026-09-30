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
        var isOn = false
        let haptics = GatedHaptics(generator: generator) { isOn }
        haptics.impact(intensity: 1)
        haptics.notify(.error)
        #expect(generator.calls.isEmpty)
        // Switching Haptics on takes effect at once.
        isOn = true
        haptics.impact(intensity: 0.5)
        haptics.notify(.success)
        #expect(generator.calls == ["impact 0.5", "notify success"])

        // A race's haptics all go through the gate: a tap with Haptics off reaches no generator.
        let silent = RecordingGenerator()
        let session = GameSession(config: Self.config, haptics: GatedHaptics(generator: silent) { false })
        session.tackOrGybe()
        session.consume([])
        #expect(silent.calls.isEmpty)
        let heard = RecordingGenerator()
        GameSession(config: Self.config, haptics: GatedHaptics(generator: heard) { true }).tackOrGybe()
        #expect(heard.calls == ["impact 0.4"])
    }
}
