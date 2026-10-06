import Foundation
import Observation
import SwiftUI

/// The device's thermal state and Low Power Mode, live, for `RenderQualityPolicy` (#127). It follows the system's
/// change notifications, which iOS already debounces; there is no hysteresis of our own (#172's device runs say if the
/// tiers flap). A render fixture or UI test run reads neither (`LaunchOptions.pinsRenderQuality`), and `-thermal` pins
/// the thermal state (Debug builds).
@MainActor @Observable final class RenderQualityMonitor {
    /// Where the monitor reads the system: the process's own, or a test's.
    struct System {
        var thermalState: @MainActor () -> ProcessInfo.ThermalState
        var lowPower: @MainActor () -> Bool

        static let live = System(thermalState: { ProcessInfo.processInfo.thermalState },
                                 lowPower: { ProcessInfo.processInfo.isLowPowerModeEnabled })

        /// A fixed state, ignoring the device: a render fixture's or a UI test's.
        static func pinned(_ state: ProcessInfo.ThermalState) -> System {
            System(thermalState: { state }, lowPower: { false })
        }
    }

    private(set) var thermalState: ProcessInfo.ThermalState
    private(set) var lowPower: Bool
    @ObservationIgnored private let system: System
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let center: NotificationCenter
    #if DEBUG
    /// `-fps120` (Debug builds): 120 on ProMotion while cool.
    @ObservationIgnored var fps120 = false
    #endif

    init(system: System, center: NotificationCenter = .default) {
        self.system = system
        self.center = center
        thermalState = system.thermalState()
        lowPower = system.lowPower()
        let names = [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange]
        // The system posts these on a thread of its own: refresh on the main actor.
        observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
    }

    /// The monitor `options` ask for: the device's own, or a fixed state for a fixture, a UI test or `-thermal`.
    convenience init(options: LaunchOptions) {
        if options.pinsRenderQuality {
            self.init(system: .pinned(options.renderThermalState ?? .nominal))
        } else if let state = options.renderThermalState {
            var system = System.live
            system.thermalState = { state }
            self.init(system: system)
        } else {
            self.init(system: .live)
        }
        #if DEBUG
        fps120 = options.fps120
        #endif
    }

    isolated deinit {
        for observer in observers { center.removeObserver(observer) }
    }

    /// Reads the system again.
    func refresh() {
        let state = system.thermalState()
        if state != thermalState { thermalState = state }
        let low = system.lowPower()
        if low != lowPower { lowPower = low }
    }

    /// The policy on a screen that draws at most `maxFPS` frames a second.
    func policy(maxFPS: Int) -> RenderQualityPolicy {
        #if DEBUG
        RenderQualityPolicy(thermalState: thermalState, lowPower: lowPower, maxFPS: maxFPS, fps120: fps120)
        #else
        RenderQualityPolicy(thermalState: thermalState, lowPower: lowPower, maxFPS: maxFPS)
        #endif
    }
}

extension EnvironmentValues {
    /// The window scene's screen's top frame rate (`UIScreen.maximumFramesPerSecond`): 120 on ProMotion, set by
    /// `SceneDelegate` (#127).
    @Entry var maximumFramesPerSecond = 60
}
