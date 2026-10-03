import SwiftUI

/// The practice setup page and the pause menu as render fixtures (#62, #131): `{ "gallery": "practiceSetup" }` shows
/// the setup page on a fresh install's choices (UI tests keep the setup in a suite of their own, emptied at launch),
/// and `{ "gallery": "pauseMenu" }` the pause menu, its toggles at the device defaults, over the race's dark chrome;
/// `{ "gallery": "myBoat", … }` My boat on the fixture's livery (#136).
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
        case .myBoat(let fixture):
            MyBoatGallery(fixture: fixture)
        default:
            NavigationStack {
                PracticeSetupView(model: model)
            }
            .tint(ChromePalette.tint)
        }
    }
}

/// My boat on a fixture's livery (#136), pushed as from home. The model is made once, so the page keeps its draft.
private struct MyBoatGallery: View {
    @State private var model: MyBoatModel

    init(fixture: RenderFixture.MyBoatFixture) {
        _model = State(initialValue: fixture.model())
    }

    var body: some View {
        NavigationStack {
            MyBoatView(model: model)
        }
        .tint(ChromePalette.tint)
    }
}
