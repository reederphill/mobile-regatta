import Observation

/// The device's control settings every race reads (#112, #113): owned by `AppModel`, which sets it from Settings once
/// per change (with `-scheme` over the stored scheme and `-camera` over the stored camera), and shared by every race
/// like `GatedHaptics`. The scene reads the scheme, camera and auto framing each frame, so a switch mid-race (#131)
/// takes effect at once (a camera change eases). None of them goes on the wire.
@Observable
final class ControlSettings {
    var steering: DeviceSettings.Steering
    /// Course-up or boat-up (#13).
    var camera: DeviceSettings.Camera
    /// Whether the camera frames the boats that matter (#224).
    var autoFraming: Bool

    init(steering: DeviceSettings.Steering = .halves, camera: DeviceSettings.Camera = .courseUp, autoFraming: Bool = true) {
        self.steering = steering
        self.camera = camera
        self.autoFraming = autoFraming
    }

    /// The device's controls from `settings`, with a test launch's `-scheme` and `-camera` over them.
    convenience init(_ settings: DeviceSettings, launchOptions: LaunchOptions) {
        self.init(steering: Self.steering(settings.steering, override: launchOptions.steeringScheme),
                  camera: Self.camera(settings.camera, override: launchOptions.camera),
                  autoFraming: settings.autoFraming)
    }

    /// Takes `settings`, with a test launch's `-scheme` and `-camera` over them: once per Settings change.
    func update(_ settings: DeviceSettings, launchOptions: LaunchOptions) {
        steering = Self.steering(settings.steering, override: launchOptions.steeringScheme)
        camera = Self.camera(settings.camera, override: launchOptions.camera)
        autoFraming = settings.autoFraming
    }

    /// The camera a race draws with: `-camera`'s when a test launch sets one (`course` is course-up, `boat`
    /// boat-up), else Settings'.
    static func camera(_ stored: DeviceSettings.Camera, override: LaunchOptions.CameraMode?) -> DeviceSettings.Camera {
        switch override {
        case .course?: .courseUp
        case .boat?: .boatUp
        case nil: stored
        }
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
