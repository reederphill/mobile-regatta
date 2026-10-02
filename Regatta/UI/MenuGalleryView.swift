import SwiftUI

/// The practice setup page and the pause menu as render fixtures (#62, #131): `{ "gallery": "practiceSetup" }` shows
/// the setup page on a fresh install's choices (UI tests keep the setup in a suite of their own, emptied at launch),
/// and `{ "gallery": "pauseMenu" }` the pause menu, its toggles at the device defaults, over the race's dark chrome.
///
/// Like the race fixture (`RaceView`), it's one `render-fixture` element whose value is the bottom safe-area inset in
/// points: the home-indicator band the diffs leave out.
struct MenuGalleryView: View {
    let gallery: RenderFixture.Gallery
    let model: AppModel

    var body: some View {
        GeometryReader { proxy in
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement()
                .accessibilityLabel("Render fixture")
                .accessibilityValue(String(Double(proxy.safeAreaInsets.bottom)))
                .accessibilityIdentifier("render-fixture")
        }
        .persistentSystemOverlays(.hidden)
    }

    @ViewBuilder private var content: some View {
        switch gallery {
        case .pauseMenu:
            PauseMenu(settings: .constant(DeviceSettings()), onResume: {}, onRestart: {}, onLeave: {}, onHelp: {})
                .background(ChromePalette.background.ignoresSafeArea())
                .environment(\.colorScheme, .dark)
        case .results(let stage):
            ResultsGalleryView(stage: stage)
        default:
            NavigationStack {
                PracticeSetupView(model: model)
            }
            .tint(ChromePalette.tint)
        }
    }
}
