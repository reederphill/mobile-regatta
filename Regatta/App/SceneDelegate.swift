import SwiftUI
import UIKit

/// Hosts `RootView` in the app's window scene and forwards the scene's activation state to `SceneState`.
///
/// UIKit owns the window so the root view controller can prefer a locked interface orientation during the race
/// sequence (#107). The iOS 27 SDK ignores `UIRequiresFullScreen`, so on iPad the app runs in any window and the
/// race letterboxes (`RaceViewportPolicy`). iPhone is portrait only through Info.plist.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private let sceneState = SceneState()

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        sceneState.phase = SceneState.phase(for: windowScene.activationState)
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = RootHostingController(sceneState: sceneState, screenSize: windowScene.screen.bounds.size)
        window.makeKeyAndVisible()
        self.window = window
    }

    func sceneDidBecomeActive(_ scene: UIScene) { sceneState.phase = .active }
    func sceneWillResignActive(_ scene: UIScene) { sceneState.phase = .inactive }
    func sceneWillEnterForeground(_ scene: UIScene) { sceneState.phase = .inactive }
    func sceneDidEnterBackground(_ scene: UIScene) { sceneState.phase = .background }
}

/// The root view with the app-wide environment and appearance.
struct AppRoot: View {
    let sceneState: SceneState
    let screenSize: CGSize

    var body: some View {
        RootView()
            .environment(\.sceneState, sceneState)
            .environment(\.screenSize, screenSize)
            .preferredColorScheme(.dark)
            .statusBarHidden()
    }
}

final class RootHostingController: UIHostingController<AppRoot> {
    /// Locks the interface orientation while the window fills the screen. Follows
    /// `SceneState.isRaceSequenceShowing`. It's a preference only: the system drops it in a resized or shared
    /// window, where the race letterboxes instead.
    var isOrientationLocked = false {
        didSet {
            guard isOrientationLocked != oldValue else { return }
            if #available(iOS 26.0, *) { setNeedsUpdateOfPrefersInterfaceOrientationLocked() }
        }
    }

    init(sceneState: SceneState, screenSize: CGSize) {
        super.init(rootView: AppRoot(sceneState: sceneState, screenSize: screenSize))
        isOrientationLocked = sceneState.isRaceSequenceShowing
        sceneState.onRaceSequenceShowingChange = { [weak self] showing in self?.isOrientationLocked = showing }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @available(iOS 26.0, *)
    override var prefersInterfaceOrientationLocked: Bool { isOrientationLocked }
}
