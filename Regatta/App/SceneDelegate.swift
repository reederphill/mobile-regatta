import RegattaServices
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
        // `-fakeServices <scenario>` plays a scenario's scripted fakes (#242); otherwise the device's connectivity,
        // signed out, until the real services arrive.
        let services = LaunchOptions.current.fakeServices.map(ServiceSet.fake)
            ?? ServiceSet.unconnected(connectivity: PathConnectivityService())
        window.rootViewController = RootHostingController(sceneState: sceneState, screenSize: windowScene.screen.bounds.size,
                                                          onlineStatus: OnlineStatus(services: services))
        if let appearance = LaunchOptions.current.appearance {
            window.overrideUserInterfaceStyle = appearance == .dark ? .dark : .light
        }
        window.makeKeyAndVisible()
        self.window = window
    }

    func sceneDidBecomeActive(_ scene: UIScene) { sceneState.phase = .active }
    func sceneWillResignActive(_ scene: UIScene) { sceneState.phase = .inactive }
    func sceneWillEnterForeground(_ scene: UIScene) { sceneState.phase = .inactive }
    func sceneDidEnterBackground(_ scene: UIScene) { sceneState.phase = .background }
}

/// The root view with the app-wide environment. Menus follow the system appearance; the race cover sets its own.
struct AppRoot: View {
    let model: AppModel
    let sceneState: SceneState
    let screenSize: CGSize
    let onlineStatus: OnlineStatus

    var body: some View {
        RootView(model: model)
            .environment(\.sceneState, sceneState)
            .environment(\.screenSize, screenSize)
            .environment(\.isOnline, onlineStatus.isOnline)
            .environment(\.lobbyStatus, onlineStatus.lobbyStatus)
    }
}

final class RootHostingController: UIHostingController<AppRoot> {
    /// Locks the interface orientation while the window fills the screen. Follows
    /// `SceneState.isRaceSequenceShowing`, which `AppModel.phase` sets. It's a preference only: the system drops
    /// it in a resized or shared window, where the race letterboxes instead. While the race cover is up UIKit can ask
    /// the cover (`RaceCoverController`) instead, which prefers the lock too.
    var isOrientationLocked = false {
        didSet {
            guard isOrientationLocked != oldValue else { return }
            if #available(iOS 26.0, *) { setNeedsUpdateOfPrefersInterfaceOrientationLocked() }
        }
    }

    /// With no `onlineStatus`, online and signed out, as the placeholders were: for tests.
    init(sceneState: SceneState, screenSize: CGSize, onlineStatus: OnlineStatus? = nil) {
        let model = AppModel(sceneState: sceneState)
        let onlineStatus = onlineStatus ?? OnlineStatus(services: .fake(.signedOut))
        super.init(rootView: AppRoot(model: model, sceneState: sceneState, screenSize: screenSize, onlineStatus: onlineStatus))
        isOrientationLocked = sceneState.isRaceSequenceShowing
        sceneState.onRaceSequenceShowingChange = { [weak self] showing in self?.isOrientationLocked = showing }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @available(iOS 26.0, *)
    override var prefersInterfaceOrientationLocked: Bool { isOrientationLocked }
}
