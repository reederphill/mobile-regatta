// PROTOTYPE for "Steering and boat-handling controls" (issue #13). Throwaway: lives only on the
// prototype/steering-controls branch. Five steering schemes, three camera modes and two zoom modes,
// switched from the yellow pill at the bottom of the race screen or by launch argument, e.g.
// `-autostart -steer tilt -camera boatUp -zoom auto`.

import Foundation
import Observation

enum SteerScheme: String, CaseIterable {
    case halves, tiller, dial, tilt, windLock

    var label: String {
        switch self {
        case .halves: "A Halves"
        case .tiller: "B Tiller"
        case .dial: "C Dial"
        case .tilt: "D Tilt"
        case .windLock: "E Wind lock"
        }
    }

    var hint: String {
        switch self {
        case .halves: "Hold the left or right half of the screen to steer."
        case .tiller: "Touch anywhere and slide left or right. The further you slide, the harder you steer. Let go to centre."
        case .dial: "Drag on the dial to point the boat. It steers there and holds that heading."
        case .tilt: "Tilt the phone to steer. Tap the water to re-centre. (Needs a device, not the simulator.)"
        case .windLock: "The boat holds its angle to the wind through shifts. Slide left or right to change the angle."
        }
    }
}

enum CameraMode: String, CaseIterable {
    case courseUp, windUp, boatUp

    var label: String {
        switch self {
        case .courseUp: "Course-up"
        case .windUp: "Wind-up"
        case .boatUp: "Boat-up"
        }
    }
}

enum ZoomMode: String, CaseIterable {
    case pinch, auto

    var label: String {
        switch self {
        case .pinch: "Pinch zoom"
        case .auto: "Auto zoom"
        }
    }
}

@Observable
final class ControlLab {
    static let shared = ControlLab()

    var steer: SteerScheme
    var camera: CameraMode
    var zoom: ZoomMode

    /// Dial: compass heading the boat steers to.
    var dialHeading: Double?
    /// Wind lock: signed angle to the wind to hold, in `Boat.relativeWind` terms.
    var lockedWindAngle: Double?
    var isEased = false
    var isSpinning = false

    /// Compass heading at the top of the screen.
    var viewHeading = 0.0
    /// Rudder the controls are asking for, -1…1, for the on-screen gauge.
    var rudder = 0.0
    /// Tiller: touch-down and current finger points in view coordinates.
    var dragOrigin: CGPoint?
    var dragPoint: CGPoint?

    private init() {
        let defaults = UserDefaults.standard
        steer = defaults.string(forKey: "steer").flatMap(SteerScheme.init) ?? .halves
        camera = defaults.string(forKey: "camera").flatMap(CameraMode.init) ?? .courseUp
        zoom = defaults.string(forKey: "zoom").flatMap(ZoomMode.init) ?? .pinch
    }
}

extension CaseIterable where Self: Equatable, AllCases.Index == Int {
    func cycled(by step: Int) -> Self {
        let all = Self.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[((index + step) % all.count + all.count) % all.count]
    }
}
