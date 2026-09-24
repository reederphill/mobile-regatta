import SwiftUI
import UIKit

/// Hosts `RootView` in the app's window scene.
///
/// UIKit owns the window so the root view controller can prefer a locked interface orientation (#107): the
/// iOS 27 SDK ignores `UIRequiresFullScreen`, so on iPad the app runs in any window and the race letterboxes
/// (`RaceViewportPolicy`). iPhone is portrait only through Info.plist.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = RootHostingController(rootView: AppRoot(screenSize: windowScene.screen.bounds.size))
        window.makeKeyAndVisible()
        self.window = window
    }
}

/// The root view with the app-wide environment and appearance.
struct AppRoot: View {
    let screenSize: CGSize

    var body: some View {
        RootView()
            .environment(\.screenSize, screenSize)
            .preferredColorScheme(.dark)
            .statusBarHidden()
    }
}

final class RootHostingController: UIHostingController<AppRoot> {
    /// Keeps the interface orientation while the window fills the screen. A preference only: the system
    /// drops it in a resized or shared window, where the race letterboxes instead.
    @available(iOS 26.0, *)
    override var prefersInterfaceOrientationLocked: Bool { true }
}
