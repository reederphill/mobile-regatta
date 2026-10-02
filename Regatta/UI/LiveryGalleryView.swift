import RegattaCore
import RegattaServices
import SwiftUI

/// The `livery-large` render fixture (#62, #119): each free skiff starter design's large render and chip, in fixed
/// colours, so a reference pins the art. Shown in place of the menu by a `{ "gallery": "livery" }` fixture.
///
/// Like the race fixture (`RaceView`), it's one `render-fixture` element whose value is the bottom safe-area inset
/// in points: the home-indicator band the diffs leave out.
struct LiveryGalleryView: View {
    /// One livery per free skiff starter design, between them every slot count, pattern and sail graphic drawn, the
    /// white and charcoal decks (#29), off-white's sail and both number inks.
    static let liveries = [
        Livery(design: DesignID("skiff-plain"), colours: [SwatchID("sky-blue"), SwatchID("white")], sailNumber: 207),
        Livery(design: DesignID("skiff-stripe"),
               colours: [SwatchID("charcoal"), SwatchID("pale-bluish-green"), SwatchID("white")], sailNumber: 31),
        Livery(design: DesignID("skiff-sheer"),
               colours: [SwatchID("white"), SwatchID("lavender"), SwatchID("pale-sky-blue")], sailNumber: 4127),
        Livery(design: DesignID("skiff-split"),
               colours: [SwatchID("pale-reddish-purple"), SwatchID("charcoal"), SwatchID("off-white")], sailNumber: 88),
    ]

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 12) {
                ForEach(Array(Self.liveries.enumerated()), id: \.offset) { _, livery in
                    LiveryRenderView(livery: livery, size: CGSize(width: 320, height: 150))
                }
                HStack(spacing: 16) {
                    ForEach(Array(Self.liveries.enumerated()), id: \.offset) { _, livery in
                        LiveryChipView(chip: LiveryChip(livery), diameter: 24)
                    }
                }
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .accessibilityElement()
            .accessibilityLabel("Render fixture")
            .accessibilityValue(String(Double(proxy.safeAreaInsets.bottom)))
            .accessibilityIdentifier("render-fixture")
        }
        .background(Color.black.ignoresSafeArea())
        .persistentSystemOverlays(.hidden)
        .environment(\.colorScheme, .dark)
    }
}
