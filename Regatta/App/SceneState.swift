import Observation
import SwiftUI
import UIKit

/// Scene state that UIKit owns and the SwiftUI tree reads, from `\.sceneState`.
///
/// Because `SceneDelegate` owns the window, `@Environment(\.scenePhase)` isn't reliable. Read `phase` instead:
/// sending the app to the background pauses a practice race (#131), leaves the queue (#140), and counts as a
/// disconnect in an online race (#141).
@Observable
final class SceneState {
    /// Follows the scene's activation state, forwarded by `SceneDelegate`.
    var phase: ScenePhase = .inactive {
        didSet {
            guard phase != oldValue else { return }
            onPhaseChange?(isActive)
        }
    }

    /// The scene is in the foreground and active.
    var isActive: Bool { phase == .active }

    /// Told each change of `phase`, with `isActive`: `AppModel` silences the ambience while the scene isn't active
    /// (#126).
    @ObservationIgnored var onPhaseChange: ((Bool) -> Void)?

    /// Whether the race sequence (briefing, race, results) is on screen, set by `AppModel.phase`. The root view
    /// controller prefers a locked interface orientation only while it is. Menus adapt to any window, so they
    /// don't lock (G5).
    var isRaceSequenceShowing = false {
        didSet {
            guard isRaceSequenceShowing != oldValue else { return }
            onRaceSequenceShowingChange?(isRaceSequenceShowing)
        }
    }

    @ObservationIgnored var onRaceSequenceShowingChange: ((Bool) -> Void)?

    /// The SwiftUI phase for a UIKit activation state.
    static func phase(for state: UIScene.ActivationState) -> ScenePhase {
        switch state {
        case .foregroundActive: .active
        case .background, .unattached: .background
        case .foregroundInactive: .inactive
        @unknown default: .inactive
        }
    }
}

extension EnvironmentValues {
    /// The window scene's state, set by `SceneDelegate`. Previews and tests get a fresh one.
    @Entry var sceneState = SceneState()
}
