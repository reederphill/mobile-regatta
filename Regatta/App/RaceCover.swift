import SwiftUI
import UIKit

/// The race sequence's full-screen cover (#25), presented by UIKit rather than SwiftUI's `fullScreenCover`.
///
/// While a full-screen modal is up, UIKit asks the presented controller, not the root, for its interface
/// orientation lock. SwiftUI's own cover presents a private hosting controller that never prefers the lock, so an
/// iPad rotated under it mid-race. This controller always prefers the lock, and it's only on screen during the
/// race sequence, so the lock lasts exactly as long as the race sequence (G5). The lock keeps the orientation the
/// race started in: a race started in landscape stays letterboxed (`RaceViewportPolicy`). It's a preference only:
/// in a resized or shared window the system drops it and the race letterboxes. It also keeps the cover's fixed
/// look (dark, no status bar) and can't be swiped down.
///
/// It covers the window over the root rather than replacing it (`.overFullScreen`): SwiftUI stops updating a
/// hosting controller whose view has left the window, and the root's view is what dismisses the cover when the
/// phase returns home. The root prefers the lock during the race sequence too, so the lock holds whichever of the
/// two UIKit asks.
final class RaceCoverController: UIHostingController<AnyView> {
    init(content: AnyView) {
        super.init(rootView: content)
        modalPresentationStyle = .overFullScreen
        modalPresentationCapturesStatusBarAppearance = true
        isModalInPresentation = true
        overrideUserInterfaceStyle = .dark
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Home stays in the window under the race: keep it out of accessibility (and UI tests) while it's covered.
        view.accessibilityViewIsModal = true
    }

    override var prefersStatusBarHidden: Bool { true }

    @available(iOS 26.0, *)
    override var prefersInterfaceOrientationLocked: Bool { true }
}

extension View {
    /// Presents `content` in a `RaceCoverController` while `isPresented` is true. A transaction that disables
    /// animations (the launch-argument path) presents and dismisses it without the slide.
    func raceCover(isPresented: Bool, @ViewBuilder content: () -> some View) -> some View {
        background(RaceCoverPresenter(content: isPresented ? AnyView(content()) : nil))
    }
}

/// Places an invisible controller in the view hierarchy to present the race cover from.
private struct RaceCoverPresenter: UIViewControllerRepresentable {
    let content: AnyView?

    func makeCoordinator() -> RaceCoverPresentation { RaceCoverPresentation() }

    func makeUIViewController(context: Context) -> RaceCoverPresentation.Host {
        let host = RaceCoverPresentation.Host()
        host.presentation = context.coordinator
        return host
    }

    func updateUIViewController(_ host: RaceCoverPresentation.Host, context: Context) {
        context.coordinator.update(from: host, content: content, animated: !context.transaction.disablesAnimations)
    }

    static func dismantleUIViewController(_ host: RaceCoverPresentation.Host, coordinator: RaceCoverPresentation) {
        coordinator.update(from: host, content: nil, animated: false)
    }
}

/// Presents, updates and dismisses the race cover from a host controller. `content` is the cover's view while it
/// should show, `nil` otherwise.
@MainActor final class RaceCoverPresentation {
    /// The presenting controller: it retries a presentation that had to wait for it to join a window.
    final class Host: UIViewController {
        weak var presentation: RaceCoverPresentation?

        override func loadView() {
            let view = WindowView()
            view.isUserInteractionEnabled = false
            view.onMoveToWindow = { [weak self] in
                // Present on the next turn of the run loop, once the move into the window is complete.
                RunLoop.main.perform { if let self { self.presentation?.retry(from: self) } }
            }
            self.view = view
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            presentation?.retry(from: self)
        }
    }

    private final class WindowView: UIView {
        var onMoveToWindow: (() -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { onMoveToWindow?() }
        }
    }

    private(set) weak var cover: RaceCoverController?
    private var pending: (content: AnyView, animated: Bool)?

    func update(from host: UIViewController, content: AnyView?, animated: Bool) {
        guard let content else {
            pending = nil
            if let cover, cover.presentingViewController != nil, !cover.isBeingDismissed {
                // UIKit ignores a dismissal while the cover is still sliding in: dismiss it once it's up.
                if cover.isBeingPresented, let transition = cover.transitionCoordinator {
                    transition.animate(alongsideTransition: nil) { _ in cover.dismiss(animated: animated) }
                } else {
                    cover.dismiss(animated: animated)
                }
            }
            cover = nil
            return
        }
        if let cover, cover.presentingViewController != nil {
            cover.rootView = content
            return
        }
        present(content, from: host, animated: animated)
    }

    private func present(_ content: AnyView, from host: UIViewController, animated: Bool) {
        // Not in a window yet (the launch-argument path starts the race as Home appears), or another presentation
        // is still moving: wait for it, as SwiftUI's own cover does.
        let transition = host.viewIfLoaded?.window?.rootViewController?.presentedViewController?.transitionCoordinator
        guard host.viewIfLoaded?.window != nil, transition == nil else {
            pending = (content, animated)
            transition?.animate(alongsideTransition: nil) { [weak self, weak host] _ in
                if let self, let host { self.retry(from: host) }
            }
            return
        }
        pending = nil
        let cover = RaceCoverController(content: content)
        self.cover = cover
        host.present(cover, animated: animated)
    }

    fileprivate func retry(from host: UIViewController) {
        guard let pending, cover == nil else { return }
        present(pending.content, from: host, animated: pending.animated)
    }
}
