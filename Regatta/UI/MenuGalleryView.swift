import SwiftUI

/// The practice setup page and the pause menu as render fixtures (#62, #131): `{ "gallery": "practiceSetup" }` shows
/// the setup page on a fresh install's choices (UI tests keep the setup in a suite of their own, emptied at launch),
/// and `{ "gallery": "pauseMenu" }` the pause menu, its toggles at the device defaults, over the race's dark chrome;
/// `{ "gallery": "myBoat", … }` My boat on the fixture's livery (#136); `{ "gallery": "help", … }` Help or one of its
/// topics (#135).
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
        case .results(let stage, let rivalSkill):
            ResultsGalleryView(stage: stage, rivalSkill: rivalSkill)
        case .myBoat(let fixture):
            MyBoatGallery(fixture: fixture)
        case .help(let topic):
            HelpGallery(topic: topic)
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

/// Help as pushed from home, or one of its topics (#135). The legend's pictures are drawn before it shows, so the
/// render never catches a row still drawing.
private struct HelpGallery: View {
    let topic: HelpTopic?

    init(topic: HelpTopic?) {
        self.topic = topic
        if topic == .symbols { LegendItem.allCases.forEach { _ = LegendArt.image(for: $0) } }
    }

    var body: some View {
        NavigationStack {
            if let topic { HelpTopicView(topic: topic) } else { HelpPage() }
        }
        .tint(ChromePalette.tint)
    }
}
