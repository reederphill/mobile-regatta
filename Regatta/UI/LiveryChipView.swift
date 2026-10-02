import RegattaCore
import RegattaServices
import SwiftUI

/// The round livery chip (#21, #119): the deck colour with a sail-colour ring. Beside each lobby line (#142) and each
/// results row; the same for free and paid players.
struct LiveryChipView: View {
    let chip: LiveryChip
    var diameter: CGFloat = 16
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Circle()
            .fill(Color(uiColor: UIColor(rgb: LiveryArt.rgb(chip.deck))))
            .overlay {
                Circle().strokeBorder(Color(uiColor: UIColor(rgb: LiveryArt.rgb(chip.sail))), lineWidth: diameter * 0.2)
            }
            // An edge outside the ring that contrasts with the background: a dark hairline in light mode, so a white or
            // pale ring still reads; a thin light ring in dark mode, so a charcoal deck and ring still read.
            .overlay {
                if colorScheme == .dark {
                    Circle().strokeBorder(Color.white.opacity(0.7), lineWidth: max(1, diameter * 0.07))
                } else {
                    Circle().strokeBorder(ChartPalette.markEdge.color, lineWidth: max(0.5, diameter * 0.04))
                }
            }
            .frame(width: diameter, height: diameter)
            .accessibilityHidden(true)
    }
}

extension LiveryChip {
    /// A livery's chip: its deck and sail colours, from its design's slots. A livery whose design the catalogue
    /// doesn't know reads its first two colours as deck and sail.
    init(_ livery: Livery, catalogue: LiveryCatalogue = .bundled) {
        let design = catalogue.design(livery.design)
        func colour(_ slot: LiverySlot, index: Int) -> SwatchID {
            if let design { return livery.colour(slot, in: design) ?? SwatchID("pale-grey") }
            return livery.colours.indices.contains(index) ? livery.colours[index] : SwatchID("pale-grey")
        }
        self.init(deck: colour(.deck, index: 0), sail: colour(.sail, index: 1))
    }
}
