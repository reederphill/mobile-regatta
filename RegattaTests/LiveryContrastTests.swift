import Foundation
import RegattaCore
import Testing
@testable import Regatta

/// The safe palette against the race's water (#29, #119): every livery swatch keeps its OKLCH lightness from the
/// water, puff and lull tones the scene draws (`ChartPalette`), except those the hull outline carries (charcoal).
@MainActor @Suite struct LiveryContrastTests {
    @Test func everySwatchContrastsWithWaterPuffAndLull() {
        let catalogue = LiveryCatalogue.bundled
        let rule = catalogue.rule
        let tones = [ChartPalette.water, ChartPalette.puff, ChartPalette.lull]
        // The catalogue's copy of the tones is the app's, so the check can't drift from what the scene draws.
        #expect(rule.water == tones.map(\.rgb))
        #expect(rule.minimumLightnessContrast == 0.2)
        #expect(rule.contrastExceptions == [SwatchID("charcoal")])
        #expect(catalogue.swatches.count == 9)

        for swatch in catalogue.swatches where !rule.contrastExceptions.contains(swatch.id) {
            let colour = PaletteToken(swatch.id.rawValue, swatch.rgb)
            for tone in tones {
                let contrast = abs(colour.oklch.L - tone.oklch.L)
                #expect(contrast >= rule.minimumLightnessContrast,
                        "\(colour) is |ΔL| \(String(format: "%.3f", contrast)) from \(tone)")
            }
        }
    }
}
