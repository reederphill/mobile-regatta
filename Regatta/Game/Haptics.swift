import UIKit

/// The kinds of notification haptic a race plays.
enum HapticNotification: Equatable {
    case success, warning, error
}

/// What plays haptics: the device's feedback generators, or a recorder in tests.
protocol HapticGenerator: AnyObject {
    func impact(intensity: Double)
    func notify(_ kind: HapticNotification)
}

/// The race's haptics (#110): every call site goes through here, and nothing reaches a generator while Settings'
/// Haptics is off.
protocol Haptics: AnyObject {
    func impact(intensity: Double)
    func notify(_ kind: HapticNotification)
}

/// UIKit's feedback generators.
final class SystemHapticGenerator: HapticGenerator {
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

/// Haptics gated by Settings: `isOn` is asked at each call, so switching Haptics off takes effect mid-race.
final class GatedHaptics: Haptics {
    private let generator: any HapticGenerator
    private let isOn: () -> Bool

    /// By default the device's generators, on while the device settings in `UserDefaults.standard` say so.
    init(generator: any HapticGenerator = SystemHapticGenerator(),
         isOn: @escaping () -> Bool = { DeviceSettings(defaults: .standard).haptics }) {
        self.generator = generator
        self.isOn = isOn
    }

    func impact(intensity: Double) {
        guard isOn() else { return }
        generator.impact(intensity: intensity)
    }

    func notify(_ kind: HapticNotification) {
        guard isOn() else { return }
        generator.notify(kind)
    }
}
