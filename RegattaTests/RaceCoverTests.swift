import SwiftUI
import Testing
import UIKit
import RegattaCore
@testable import Regatta

/// The race cover is the controller UIKit asks for the orientation lock while the race sequence shows (G5).
@MainActor @Suite(.serialized) struct RaceCoverTests {
    private static let config = RaceConfig(opponents: 1, prestartSeconds: 30, seed: 1, windSeed: RaceConfig.windSeed(pinnedTo: 1))

    @Test func coverPrefersTheLockAndItsFixedLook() {
        let cover = RaceCoverController(content: AnyView(Color.clear))
        #expect(cover.modalPresentationStyle == .overFullScreen)
        #expect(cover.modalPresentationCapturesStatusBarAppearance)
        #expect(cover.isModalInPresentation)
        #expect(cover.prefersStatusBarHidden)
        #expect(cover.overrideUserInterfaceStyle == .dark)
        if #available(iOS 26.0, *) { #expect(cover.prefersInterfaceOrientationLocked) }
    }

    /// Entering the race sequence presents the locking cover over the root; a restart keeps it; back on Home it's
    /// gone and nothing prefers the lock, so the menus adapt again.
    @Test func raceSequencePresentsTheLockingCover() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let controller = RootHostingController(sceneState: SceneState(), screenSize: CGSize(width: 402, height: 874))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let model = controller.rootView.model
        _ = settle(window) { false }

        // Without the slide, as the launch-argument path presents it, so each step completes promptly.
        withoutAnimation { model.startRaceSequence(GameSession(config: Self.config)) }
        #expect(settle(window) { controller.presentedViewController is RaceCoverController }, "no race cover")
        let cover = try #require(controller.presentedViewController as? RaceCoverController)
        if #available(iOS 26.0, *) {
            #expect(cover.prefersInterfaceOrientationLocked)
            #expect(controller.prefersInterfaceOrientationLocked)
        }

        withoutAnimation { model.startPractice() }
        _ = settle(window) { false }
        #expect(controller.presentedViewController === cover, "a restart replaced the cover")

        withoutAnimation { model.endRaceSequence() }
        #expect(settle(window) { controller.presentedViewController == nil }, "the race cover stayed up")
        if #available(iOS 26.0, *) { #expect(!controller.prefersInterfaceOrientationLocked) }
    }

    /// A race started before the host joins a window (the launch-argument path) is presented once it has.
    @Test func coverWaitsForTheHostsWindow() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let presentation = RaceCoverPresentation()
        let host = RaceCoverPresentation.Host()
        host.presentation = presentation
        presentation.update(from: host, content: AnyView(Color.clear), animated: false)
        #expect(presentation.cover == nil)

        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        #expect(settle(window) { host.presentedViewController is RaceCoverController }, "the pending cover never showed")
        #expect(presentation.cover === host.presentedViewController)

        presentation.update(from: host, content: nil, animated: false)
        #expect(settle(window) { host.presentedViewController == nil }, "the race cover stayed up")
    }

    private func withoutAnimation(_ body: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, body)
    }

    /// Spins the main run loop, for up to about two seconds, until `done`. False if it never was. Synchronous, like
    /// `MenuPagesTests`, so other suites' main-actor tests don't run in the middle of it.
    private func settle(_ window: UIWindow, until done: () -> Bool) -> Bool {
        for _ in 0..<40 {
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            if done() { return true }
        }
        return done()
    }
}
