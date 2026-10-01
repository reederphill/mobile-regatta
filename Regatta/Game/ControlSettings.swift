import Observation

/// The device's control settings every race reads (#112, #113): owned by `AppModel`, which sets it from Settings once
/// per change (with `-scheme` over the stored scheme and `-camera` over the stored camera), and shared by every race
/// like `GatedHaptics`. The scene reads the scheme, camera, auto zoom and pinch multiplier each frame, so a switch mid-race (#131)
/// takes effect at once (a camera change eases). None of them goes on the wire.
@Observable
final class ControlSettings {
    var steering: DeviceSettings.Steering
    /// Course-up or boat-up (#13).
    var camera: DeviceSettings.Camera
    /// Whether the camera's shots set its zoom (#322).
    var autoZoom: Bool
    /// The pinch multiplier on every shot's zoom (#322): the scene sets it as you pinch and `savesZoomMultiplier`
    /// keeps it.
    var zoomMultiplier: Double
    /// Keeps a new pinch multiplier in the device's settings: `AppModel` sets it.
    @ObservationIgnored var savesZoomMultiplier: ((Double) -> Void)?

    init(steering: DeviceSettings.Steering = .halves, camera: DeviceSettings.Camera = .courseUp, autoZoom: Bool = true,
         zoomMultiplier: Double = 1) {
        self.steering = steering
        self.camera = camera
        self.autoZoom = autoZoom
        self.zoomMultiplier = zoomMultiplier
    }

    /// The device's controls from `settings`, with a test launch's `-scheme` and `-camera` over them.
    convenience init(_ settings: DeviceSettings, launchOptions: LaunchOptions) {
        self.init(steering: Self.steering(settings.steering, override: launchOptions.steeringScheme),
                  camera: Self.camera(settings.camera, override: launchOptions.camera),
                  autoZoom: settings.autoZoom, zoomMultiplier: settings.zoomMultiplier)
    }

    /// Takes `settings`, with a test launch's `-scheme` and `-camera` over them: once per Settings change.
    func update(_ settings: DeviceSettings, launchOptions: LaunchOptions) {
        steering = Self.steering(settings.steering, override: launchOptions.steeringScheme)
        camera = Self.camera(settings.camera, override: launchOptions.camera)
        autoZoom = settings.autoZoom
        zoomMultiplier = settings.zoomMultiplier
    }

    /// A pinch or a two-finger double tap set a new multiplier: it's kept across races.
    func keepZoomMultiplier(_ multiplier: Double) {
        zoomMultiplier = multiplier
        savesZoomMultiplier?(multiplier)
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
