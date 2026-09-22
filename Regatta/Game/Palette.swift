import SwiftUI
import UIKit

enum Palette {
    static let water = UIColor(red: 0.09, green: 0.30, blue: 0.44, alpha: 1)
    static let gust = UIColor(red: 0.02, green: 0.11, blue: 0.24, alpha: 1)
    static let mark = UIColor(red: 1.0, green: 0.48, blue: 0.1, alpha: 1)
    static let startLine = UIColor(red: 1.0, green: 0.86, blue: 0.3, alpha: 1)

    /// Index 0 is the player.
    static let boats: [UIColor] = [
        UIColor(red: 1.00, green: 0.84, blue: 0.20, alpha: 1),
        UIColor(red: 0.93, green: 0.30, blue: 0.30, alpha: 1),
        UIColor(red: 0.35, green: 0.78, blue: 0.95, alpha: 1),
        UIColor(red: 0.55, green: 0.88, blue: 0.45, alpha: 1),
        UIColor(red: 0.82, green: 0.52, blue: 0.95, alpha: 1),
        UIColor(red: 1.00, green: 0.60, blue: 0.35, alpha: 1),
        UIColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1),
        UIColor(red: 0.40, green: 0.55, blue: 1.00, alpha: 1),
        UIColor(red: 0.95, green: 0.45, blue: 0.70, alpha: 1),
        UIColor(red: 0.30, green: 0.85, blue: 0.75, alpha: 1),
        UIColor(red: 0.75, green: 0.70, blue: 0.45, alpha: 1),
        UIColor(red: 0.60, green: 0.60, blue: 0.65, alpha: 1),
        UIColor(red: 0.95, green: 0.75, blue: 0.75, alpha: 1),
        UIColor(red: 0.50, green: 0.35, blue: 0.85, alpha: 1),
        UIColor(red: 0.85, green: 0.95, blue: 0.40, alpha: 1),
        UIColor(red: 0.25, green: 0.60, blue: 0.40, alpha: 1),
    ]

    static func boat(_ index: Int) -> UIColor { boats[index % boats.count] }
    static func boatColor(_ index: Int) -> Color { Color(uiColor: boat(index)) }
}
