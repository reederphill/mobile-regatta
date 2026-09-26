import SwiftUI
import Testing
import UIKit
@testable import Regatta

/// The home screen's pushed pages and the menu colours they draw with.
@MainActor @Suite struct MenuPagesTests {
    /// UIKit resolves a dynamic colour on whatever thread asks for it. A main-actor trait closure traps there
    /// (`dispatch_assert_queue`, Swift 6's isolation check) and takes the app down.
    @Test func menuColoursResolveOffTheMainThread() async {
        let colours: [(UIColor, light: UInt32, dark: UInt32)] = [
            (UIColor(ChromePalette.background), 0xDCEBF5, 0x0B1F33),
            (UIColor(ChromePalette.text), 0x0E2A47, 0xE8F1F8),
            (UIColor(ChromePalette.tint), 0x1B4F82, 0x7FB3E0),
            (UIColor(ChromePalette.surface), 0xFFFFFF, 0x13304D),
        ]
        for (colour, light, dark) in colours {
            let resolved = await Task.detached {
                (Self.rgb(colour.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))),
                 Self.rgb(colour.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))))
            }.value
            #expect(resolved.0 == light)
            #expect(resolved.1 == dark)
        }
    }

    /// Pushing Practice shows its setup (the opponents stepper and the two segmented pickers), and the main thread
    /// settles, after the push, after the setup changes and after popping back.
    @Test func practiceSetupPushesAndSettles() throws {
        let (window, model) = try host()
        defer { window.isHidden = true }

        model.path.append(.practiceSetup)
        #expect(settle(window), "the main thread didn't settle after pushing practice setup")
        #expect(subviews(of: UIStepper.self, in: window).count == 1, "no opponents stepper")
        #expect(subviews(of: UISegmentedControl.self, in: window).count == 2, "no laps and start sequence pickers")

        model.settings.opponents = 9
        model.settings.laps = 3
        model.settings.prestartSeconds = 90
        #expect(settle(window), "the main thread didn't settle after changing the setup")

        model.path.removeAll()
        #expect(settle(window), "the main thread didn't settle after popping practice setup")
        #expect(subviews(of: UIStepper.self, in: window).isEmpty)
    }

    /// The app's root controller in a new window on the app's scene, settled on the home screen.
    private func host() throws -> (UIWindow, AppModel) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let controller = RootHostingController(sceneState: SceneState(), screenSize: CGSize(width: 402, height: 874))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        #expect(settle(window), "the home screen didn't settle")
        return (window, controller.rootView.model)
    }

    /// Lays the window out and spins the main run loop for about a second, past a push's animation. False if a
    /// spin took far longer than it should, as it does when a view update loops.
    private func settle(_ window: UIWindow) -> Bool {
        for _ in 0..<20 {
            let start = Date()
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            if Date().timeIntervalSince(start) > 2 { return false }
        }
        return true
    }

    private func subviews<V: UIView>(of type: V.Type, in view: UIView) -> [V] {
        view.subviews.flatMap { ($0 as? V).map { [$0] } ?? [] + subviews(of: type, in: $0) }
    }

    private nonisolated static func rgb(_ colour: UIColor) -> UInt32 {
        var (red, green, blue, alpha) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
        colour.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let byte = { (value: CGFloat) in UInt32((value * 255).rounded()) }
        return byte(red) << 16 | byte(green) << 8 | byte(blue)
    }
}
