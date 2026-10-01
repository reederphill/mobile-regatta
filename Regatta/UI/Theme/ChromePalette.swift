import SwiftUI
import UIKit

/// Menu colours: home, pushed pages, sheets and the results screen. The race scene and HUD use `CuePalette`
/// and `ChartPalette`, held to the reserved-colour hue rule (`HueRule`); menus aren't (G7), and take every colour
/// from here except depictions of on-water elements (`docs/palette.md` "ChromePalette"). Each token follows the
/// system light or dark appearance.
enum ChromePalette {
    // placeholder: the hexes in docs/palette.md, until #169 applies the #53 design.
    static let background = dynamic(light: 0xDCEBF5, dark: 0x0B1F33)
    // placeholder: docs/palette.md.
    static let text = dynamic(light: 0x0E2A47, dark: 0xE8F1F8)
    /// Buttons and controls.
    // placeholder: docs/palette.md.
    static let tint = dynamic(light: 0x1B4F82, dark: 0x7FB3E0)
    /// Panels and rows on `background`.
    // placeholder: not in docs/palette.md yet; white on the pale chart blue, a lighter navy in dark mode.
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x13304D)
    /// Decorative accent only (headers, the burgee motif, the icon), never a button: red reads destructive on iOS.
    // placeholder: docs/palette.md.
    static let flagRed = Color(uiColor: UIColor(rgb: 0xC8102E))
    /// Decorative accent only, like `flagRed`.
    // placeholder: docs/palette.md.
    static let flagYellow = Color(uiColor: UIColor(rgb: 0xFFC72C))

    /// UIKit resolves a dynamic colour on whatever thread asks for it, not only the main one. The trait closure
    /// is `@Sendable` so it's nonisolated: under the app's default main-actor isolation a plain closure here is
    /// main-actor isolated, and Swift 6 traps (`dispatch_assert_queue`) when it's called off the main thread.
    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { @Sendable traits in UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light) })
    }
}

/// Menu type (`docs/palette.md` "Typography"): one display face for headings and numbers, SF for body. Every
/// style scales with Dynamic Type. The HUD's numbers use the same display face at fixed sizes (`HUDFont`, #114).
enum MenuFont {
    /// A heading in the display face.
    static func heading(_ style: Font.TextStyle = .title2) -> Font {
        // placeholder: the system font until #169 bundles Barlow Semi Condensed SemiBold (#53), as
        // `Font.custom(_:size:relativeTo: style)`.
        .system(style, weight: .semibold)
    }

    /// A number in the display face, with tabular figures so counts don't jitter.
    static func number(_ style: Font.TextStyle = .title3) -> Font {
        // placeholder: the system font until #169 bundles Barlow Semi Condensed Bold (#53).
        .system(style, weight: .bold).monospacedDigit()
    }

    /// Body text: SF.
    static func body(_ style: Font.TextStyle = .body) -> Font {
        .system(style)
    }
}

/// HUD type (#22, #114): the clock, place and wind numbers in the display face, at fixed sizes so the race view's
/// layout holds (the HUD sits in a fixed-aspect race rect, #107). A notice's words are SF.
enum HUDFont {
    /// A HUD number in the display face, tabular figures so the clock doesn't jitter.
    /// `weight` heavy marks your row on the live leaderboard (#268).
    static func number(size: CGFloat, weight: Font.Weight = .bold) -> Font {
        // placeholder: the system font until #169 bundles Barlow Semi Condensed Bold (#53), as
        // `Font.custom(_:fixedSize:)` with `.monospacedDigit()`.
        .system(size: size, weight: weight).monospacedDigit()
    }

    /// `number(size:)` as a UIKit font, for measuring the HUD's layout (`HUDLayout`). #169 swaps both together.
    static func uiNumber(size: CGFloat, weight: UIFont.Weight = .bold) -> UIFont {
        .monospacedDigitSystemFont(ofSize: size, weight: weight)
    }
}
