import Foundation

/// A named sRGB colour from `docs/palette.md`, as its hex (`0xRRGGBB`). `Palette.swift` gives it a `UIColor`
/// and a SwiftUI `Color`; the hue rule reads its OKLCH.
nonisolated struct PaletteToken: Hashable, Sendable, CustomStringConvertible {
    let name: String
    let rgb: UInt32

    init(_ name: String, _ rgb: UInt32) {
        self.name = name
        self.rgb = rgb
    }

    /// Red, green and blue, 0…1.
    var components: [Double] {
        [Double((rgb >> 16) & 0xFF) / 255, Double((rgb >> 8) & 0xFF) / 255, Double(rgb & 0xFF) / 255]
    }

    var oklch: OKLCH { OKLCH(srgb: components) }

    var description: String { "\(name) #\(String(format: "%06X", rgb))" }
}

/// A colour in OKLCH (Björn Ottosson's OKLab in polar form), the space `docs/palette.md` measures hue in:
/// lightness `L` 0…1, chroma `C` (0 is grey) and hue `h` in degrees, 0..<360.
nonisolated struct OKLCH: Equatable, Sendable {
    var L: Double
    var C: Double
    var h: Double

    /// From gamma-encoded sRGB components, 0…1.
    init(srgb: [Double]) {
        let linear = srgb.map { c in c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let (r, g, b) = (linear[0], linear[1], linear[2])
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let labA = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let labB = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        C = (labA * labA + labB * labB).squareRoot()
        let degrees = atan2(labB, labA) * 180 / .pi
        h = degrees < 0 ? degrees + 360 : degrees
    }

    /// The angle between two hues, 0…180.
    static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }
}

/// The reserved-colour hue rule (#22, `docs/palette.md` "Validator config"): a validated colour stays at least
/// `minimumHueDistance` of OKLCH hue away from every reserved cue hue, so nothing on the water or in the HUD
/// reads as a cue. Colours under `chromaFloor` have no hue to speak of (white, greys, the land's sage) and
/// pass. Which colours it validates is the caller's: race scene and HUD only, not the menus (G7);
/// `PaletteValidation` holds the set the app is held to, and the livery swatches (#118) bring their own.
nonisolated struct HueRule: Sendable {
    /// A validated colour too close in hue to a reserved one.
    struct Violation: Equatable, Sendable, CustomStringConvertible {
        let token: PaletteToken
        let reserved: PaletteToken
        /// Degrees of OKLCH hue between them.
        let distance: Double

        var description: String {
            "\(token) is \(String(format: "%.1f", distance))° from \(reserved.name)"
        }
    }

    /// The cue colours nothing else may resemble.
    var reserved: [PaletteToken]
    /// tuning: 20° (#111 placeholder, `docs/palette.md`).
    var minimumHueDistance = 20.0
    /// tuning: C < 0.06 is exempt (`docs/palette.md`).
    var chromaFloor = 0.06

    /// The rule of `docs/palette.md`: its reserved hues (vermillion, orange, yellow, chevron blue) and tunings.
    static let reservedCues = HueRule(reserved: CuePalette.reserved)

    /// Whether `token` is too grey to have a hue the rule reads.
    func isExempt(_ token: PaletteToken) -> Bool {
        token.oklch.C < chromaFloor
    }

    /// Every pair of a token in `tokens` and a reserved hue it comes too close to; empty when all pass.
    func violations(in tokens: [PaletteToken]) -> [Violation] {
        tokens.filter { !isExempt($0) }.flatMap { token in
            reserved.compactMap { cue in
                let distance = OKLCH.hueDistance(token.oklch.h, cue.oklch.h)
                return distance < minimumHueDistance ? Violation(token: token, reserved: cue, distance: distance) : nil
            }
        }
    }
}
