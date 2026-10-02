import RegattaCore
import SwiftUI

/// A briefing render fixture (#62, #130): the briefing a `{ "gallery": "briefing", "briefing": { … } }` fixture
/// describes, frozen at its start, shown in place of the menu.
///
/// Like the race fixture (`RaceView`), it's one `render-fixture` element whose value is the bottom safe-area inset in
/// points: the home-indicator band the diffs leave out.
struct BriefingGalleryView: View {
    let fixture: RenderFixture.BriefingFixture
    @State private var model: BriefingModel?
    @State private var failure: String?

    var body: some View {
        GeometryReader { proxy in
            Group {
                if let model {
                    BriefingView(model: model, onAdvance: {}, onBack: {})
                } else if let failure {
                    Text("Render fixture failed: \(failure)").padding()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement()
            .accessibilityLabel("Render fixture")
            .accessibilityValue(String(Double(proxy.safeAreaInsets.bottom)))
            .accessibilityIdentifier("render-fixture")
        }
        .background(ChromePalette.background.ignoresSafeArea())
        .persistentSystemOverlays(.hidden)
        .environment(\.colorScheme, .dark)
        .onAppear {
            guard model == nil, failure == nil else { return }
            do {
                model = try fixture.model()
            } catch {
                failure = String(describing: error)
            }
        }
    }
}
