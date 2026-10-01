import Observation

/// The device's control settings every race reads (#112): owned by `AppModel`, which sets it from Settings once per
/// change (with `-scheme` over the stored scheme), and shared by every race like `GatedHaptics`. The scene reads the
/// scheme each frame, so a switch mid-race (#131) takes effect at once. The scheme never goes on the wire.
@Observable
final class ControlSettings {
    var steering: DeviceSettings.Steering

    init(steering: DeviceSettings.Steering = .halves) {
        self.steering = steering
    }

    /// The scheme a race steers with: `-scheme`'s when a test launch sets one, else Settings'.
    static func steering(_ stored: DeviceSettings.Steering, override: LaunchOptions.SteeringScheme?) -> DeviceSettings.Steering {
        switch override {
        case .halves?: .halves
        case .tiller?: .tiller
        case nil: stored
        }
    }
}
