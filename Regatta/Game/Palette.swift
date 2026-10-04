import SwiftUI
import UIKit

/// The race scene's and HUD's cue colours (#22, `docs/palette.md` "CuePalette"). Each hue belongs to one cue,
/// and nothing else on the water or in the HUD may come near it (`HueRule`). One fixed daylight look, no dark
/// mode. Menus take `ChromePalette` instead (G7), except where they depict on-water elements.
nonisolated enum CuePalette {
    /// The wind vane.
    static let vermillion = PaletteToken("vermillion", 0xD55E00)
    /// The active leg: current marks, zone, rounding arrow, next-mark edge arrow, rule-call line, penalty arc.
    /// It reads amber: truer oranges come within 20° of vermillion.
    static let orange = PaletteToken("orange", 0xE69F00)
    /// The chevron blue: no cue draws it since the right-of-way glyphs became glows, so it stays reserved only to
    /// keep the boat colours clear of it.
    // placeholder: docs/palette.md's working value, until #169 applies #53's final chevron blue.
    static let chevronBlue = PaletteToken("chevronBlue", 0x3F51E0)
    /// Laylines, and the HUD's start clock (#30 reuses it).
    static let yellow = PaletteToken("yellow", 0xF0E442)
    /// Inactive marks.
    static let inactiveGrey = PaletteToken("inactiveGrey", 0x9AA0A6)
    /// The right-of-way glow round a boat you must keep clear of. Not in `reserved`: it isn't held to the hue rule,
    /// so a red livery can sit in a red glow (the hull's outline keeps it readable).
    static let giveWayRed = PaletteToken("giveWayRed", 0xFF4D4D)
    /// The right-of-way glow round a boat that must keep clear of you.
    static let hasRightGreen = PaletteToken("hasRightGreen", 0x3DDC84)
    /// The player's glow, wakes and ladder lines (#122); the alpha is set where it's drawn.
    static let cueWhite = PaletteToken("cueWhite", 0xFFFFFF)
    /// Every hull's thin outline, 1 pt inside her edge (#117, #21): what keeps a dark hull readable on the water.
    /// #169 restyles it.
    static let hullOutline = PaletteToken("hullOutline", 0xF5F5F2)

    /// The hues nothing else may come near. Grey and white have no hue to reserve.
    /// The sailors' buoyancy aids (#120): a neutral mid grey until #372's on-water livery may take the livery's accent.
    static let crewAid = PaletteToken("crewAid", 0x7E848C)
    /// The sailors' helmets (#120): a pale grey, not the reserved white of your glow and the wakes.
    static let crewHelmet = PaletteToken("crewHelmet", 0xD9DCDF)
    static let reserved = [vermillion, orange, yellow, chevronBlue]
    static let all = reserved + [giveWayRed, hasRightGreen, inactiveGrey, cueWhite, hullOutline, crewAid, crewHelmet]
}

/// Water and land (#22, `docs/palette.md` "ChartPalette"), held to the hue rule: blue-teal water and sage land,
/// clear of every cue hue.
nonisolated enum ChartPalette {
    /// Puffs are this much OKLCH lightness darker than the water, lulls this much lighter. tuning: 0.12.
    static let toneDelta = 0.12

    /// One base for every venue.
    static let water = PaletteToken("water", 0x174D70)
    /// A puff: water darkened by `toneDelta` (the delta is the spec; the hex is derived from it).
    static let puff = PaletteToken("puff", 0x002D4D)
    /// A lull: water lightened by `toneDelta`.
    static let lull = PaletteToken("lull", 0x3C6F94)
    /// Sage: tan came within 20° of orange and yellow.
    static let land = PaletteToken("land", 0x9DB08E)
    /// Low-chroma sand.
    static let shallows = PaletteToken("shallows", 0xCDC8B4)
    /// Whitecaps (#116): a cool near-white, too grey for the hue rule, drawn part-transparent over the water.
    static let foam = PaletteToken("foam", 0xE3EEF2)
    /// The race scene's shallows (#11, #15, #115): a tan at the water's lightness, so the tint changes hue, not
    /// lightness, and can't read as a puff or lull. Blended over the water by depth (`ShallowsTint`). Under the chroma
    /// floor, so the hue rule exempts it although its hue is near orange's.
    static let shallowsTint = PaletteToken("shallowsTint", 0x574628)
    /// The land's relief (#115): its coasts facing away from the light.
    static let landShade = PaletteToken("landShade", 0x889979)
    /// The land's relief: its coasts facing the light.
    static let landLit = PaletteToken("landLit", 0xAFC2A0)
    /// Landmark silhouettes on the land (#22, #115).
    static let landmark = PaletteToken("landmark", 0x606F53)
    /// The race area's boundary line and its hatched band outside (#15, #115): a pale blue-grey.
    static let boundary = PaletteToken("boundary", 0xB6C7D3)
    /// The dark hairline round each buoy and the committee boat (#115): white is the player's (#22).
    static let markEdge = PaletteToken("markEdge", 0x2B3238)

    static let all = [water, puff, lull, land, shallows, foam, shallowsTint, landShade, landLit, landmark, boundary,
                      markEdge]
}

/// The prototype's boat colours, until liveries (#119) delete them.
nonisolated enum Palette {
    /// Index 0 is the player. The prototype's sixteen less the five the hue rule rejects (#111): its two
    /// yellows, the yellow-green, the pale orange (by vermillion) and the blue by the chevron's.
    static let boats: [PaletteToken] = [
        PaletteToken("boat red", 0xED4D4D),
        PaletteToken("boat sky blue", 0x59C7F2),
        PaletteToken("boat green", 0x8CE073),
        PaletteToken("boat lilac", 0xD185F2),
        PaletteToken("boat white", 0xF2F2F2),
        PaletteToken("boat pink", 0xF273B3),
        PaletteToken("boat teal", 0x4DD9BF),
        PaletteToken("boat grey", 0x9999A6),
        PaletteToken("boat pale pink", 0xF2BFBF),
        PaletteToken("boat violet", 0x8059D9),
        PaletteToken("boat dark green", 0x409966),
    ]

    static func boat(_ index: Int) -> UIColor { boats[index % boats.count].uiColor }
    static func boatColor(_ index: Int) -> Color { Color(uiColor: boat(index)) }
}

/// The colours the hue rule holds the app to. G7: the race scene and HUD only; the menus (`ChromePalette`)
/// aren't validated. The cues are the rule's reference set, not part of it.
nonisolated enum PaletteValidation {
    static let raceSceneAndHUD: [PaletteToken] = ChartPalette.all + Palette.boats
}

nonisolated extension PaletteToken {
    var uiColor: UIColor { UIColor(rgb: rgb) }
    var color: Color { Color(uiColor: uiColor) }
}

extension UIColor {
    /// Nonisolated: `ChromePalette`'s dynamic colours call it from trait closures, off the main actor.
    nonisolated convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
