import UIKit

/// The kinds of notification haptic a race plays.
enum HapticNotification: Equatable {
    case success, warning, error
}

/// What plays the race's haptics (#110): the device's feedback generators, `GatedHaptics` in front of them (every
/// call site goes through it, and nothing reaches the device while Settings' Haptics is off), silence, or a
/// recorder in tests.
protocol Haptics: AnyObject {
    func impact(intensity: Double)
    func notify(_ kind: HapticNotification)
}

/// No haptics: what a race has unless it's given the app's (`AppModel.haptics`), so tests and fixtures never buzz
/// the device (#314). Like `SilentSoundOutput`.
final class SilentHaptics: Haptics {
    func impact(intensity: Double) {}
    func notify(_ kind: HapticNotification) {}
}

/// UIKit's feedback generators.
final class SystemHapticGenerator: Haptics {
    private let impactGenerator = UIImpactFeedbackGenerator(style: .medium)
    private let notificationGenerator = UINotificationFeedbackGenerator()

    func impact(intensity: Double) {
        impactGenerator.impactOccurred(intensity: CGFloat(intensity))
    }

    func notify(_ kind: HapticNotification) {
        switch kind {
        case .success: notificationGenerator.notificationOccurred(.success)
        case .warning: notificationGenerator.notificationOccurred(.warning)
        case .error: notificationGenerator.notificationOccurred(.error)
        }
    }
}

/// Haptics gated by Settings: `isOn` follows Settings' Haptics, set once per change by whoever owns the setting
/// (`AppModel`), so switching Haptics off takes effect mid-race without reading the settings on every haptic.
final class GatedHaptics: Haptics {
    private let generator: any Haptics
    var isOn: Bool

    /// By default the device's generators: `AppModel.haptics` is one, `isOn` following the setting.
    init(generator: any Haptics = SystemHapticGenerator(), isOn: Bool) {
        self.generator = generator
        self.isOn = isOn
    }

    func impact(intensity: Double) {
        guard isOn else { return }
        generator.impact(intensity: intensity)
    }

    func notify(_ kind: HapticNotification) {
        guard isOn else { return }
        generator.notify(kind)
    }
}
