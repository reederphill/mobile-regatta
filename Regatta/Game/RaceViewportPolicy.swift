import SwiftUI

/// How the race sequence (briefing, race, results) is sized in whatever window the app is given (G5 in #37).
///
/// Every race-view size comes from here: the SpriteKit scene's size, the rect the race is drawn in, and the
/// safe-area insets the HUD and controls keep clear of. Menus don't use it; they adapt to the window.
enum RaceViewportPolicy: Equatable {
    /// The race keeps the aspect and visible world area it has in a full-screen portrait window on this device,
    /// scaled to fit the window and letterboxed with plain water. A larger or landscape window never shows
    /// more of the course, which would be an information advantage online. The HUD sits inside the race rect.
    case letterboxedPortrait

    /// The policy v1.0 ships.
    static let shipping = RaceViewportPolicy.letterboxedPortrait

    struct Layout: Equatable {
        /// The race scene's size in points. It fixes the visible world area, whatever the window.
        var sceneSize: CGSize
        /// Where the race is drawn, in window coordinates. The rest of the window is letterbox.
        var raceRect: CGRect
        /// The part of the window's safe-area insets that falls inside `raceRect`.
        var safeAreaInsets: EdgeInsets
    }

    /// The race layout for a window of size `window` with `safeAreaInsets`, on a screen of size `screen` in
    /// any orientation. Without a screen (previews), the race fills the window.
    func layout(window: CGSize, safeAreaInsets insets: EdgeInsets = EdgeInsets(), screen: CGSize?) -> Layout {
        switch self {
        case .letterboxedPortrait:
            let fullScreen = screen.flatMap(Self.portrait) ?? window
            guard fullScreen.width > 0, fullScreen.height > 0, window.width > 0, window.height > 0 else {
                return Layout(sceneSize: fullScreen, raceRect: CGRect(origin: .zero, size: window), safeAreaInsets: insets)
            }
            let scale = min(window.width / fullScreen.width, window.height / fullScreen.height)
            let size = CGSize(width: fullScreen.width * scale, height: fullScreen.height * scale)
            let rect = CGRect(x: (window.width - size.width) / 2, y: (window.height - size.height) / 2,
                              width: size.width, height: size.height)
            let inside = EdgeInsets(
                top: max(0, insets.top - rect.minY),
                leading: max(0, insets.leading - rect.minX),
                bottom: max(0, insets.bottom - (window.height - rect.maxY)),
                trailing: max(0, insets.trailing - (window.width - rect.maxX))
            )
            return Layout(sceneSize: fullScreen, raceRect: rect, safeAreaInsets: inside)
        }
    }

    /// `size` turned portrait: the short side is the width.
    private static func portrait(_ size: CGSize) -> CGSize? {
        guard size.width > 0, size.height > 0 else { return nil }
        return CGSize(width: min(size.width, size.height), height: max(size.width, size.height))
    }
}

extension EnvironmentValues {
    /// The bounds of the screen showing this window, in any orientation. `RaceViewport` takes the race's
    /// full-screen portrait size from it. Set by `SceneDelegate`.
    @Entry var screenSize: CGSize?
}

/// Draws the race sequence inside the rect `RaceViewportPolicy` gives for the current window, letterboxed
/// with plain water. `content` gets the layout, fills the race rect, and sees only the safe-area insets
/// inside it.
struct RaceViewport<Content: View>: View {
    var policy = RaceViewportPolicy.shipping
    @ViewBuilder var content: (RaceViewportPolicy.Layout) -> Content

    @Environment(\.screenSize) private var screenSize

    var body: some View {
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            let window = CGSize(width: proxy.size.width + insets.leading + insets.trailing,
                                height: proxy.size.height + insets.top + insets.bottom)
            let layout = policy.layout(window: window, safeAreaInsets: insets, screen: screenSize)
            ZStack(alignment: .topLeading) {
                Color(uiColor: Palette.water)
                content(layout)
                    .safeAreaPadding(layout.safeAreaInsets)
                    .frame(width: layout.raceRect.width, height: layout.raceRect.height)
                    .clipped()
                    // UI tests check the race rect against the window.
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("race-viewport")
                    .position(x: layout.raceRect.midX, y: layout.raceRect.midY)
            }
            .ignoresSafeArea()
        }
    }
}
