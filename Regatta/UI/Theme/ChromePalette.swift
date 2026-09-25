import SwiftUI
import UIKit

/// Menu colours: home, pushed pages, sheets and (later) the results screen. The race scene and HUD use
/// `Palette` and its reserved-colour table; menus never do, and take every colour from here (G7,
/// `docs/palette.md` "ChromePalette"). Each token follows the system light or dark appearance.
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

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light) })
    }
}

/// Menu type (`docs/palette.md` "Typography"): one display face for headings and numbers, SF for body. Every
/// style scales with Dynamic Type. The HUD keeps SF Rounded and doesn't use these.
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

private extension UIColor {
    /// Nonisolated: the dynamic colours' trait closures call it off the main actor.
    nonisolated convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
