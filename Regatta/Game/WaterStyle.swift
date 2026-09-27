import CoreGraphics
import Foundation
import RegattaCore

/// Every strength, threshold and distance the water is drawn with (#116), in one value: the debug tuning panel
/// (#232) puts a slider on each and saves its tuned copy as data (#229), and `WaterNode.style` takes a new one
/// live. App-side and never logged: nothing here reaches the simulation. Every default is a placeholder until
/// tuned there.
nonisolated struct WaterStyle: Codable, Equatable, Sendable {
    // MARK: Ripple

    /// Points across between ripple tiles at the default zoom; rows are 0.8 of it apart.
    var rippleSpacing = 96.0
    /// How strongly a ripple streak draws: the alpha of `ChartPalette.lull` over the water. At 0.4 it moves the
    /// water's OKLCH lightness by about 0.05, fainter than any visible puff or lull (#22, `docs/palette.md`).
    var rippleAlpha = 0.4
    /// How fast the ripple drifts downwind, as a fraction of the conditions' mean wind.
    var rippleDrift = 0.12

    // MARK: Puffs and lulls

    /// A puff this much stronger than the course average (a fraction of it) draws at full `ChartPalette.puff`;
    /// weaker ones are lighter in proportion, down to the water at zero.
    var fullTonePuffGain = 0.30
    /// A lull this much weaker than the course average draws at full `ChartPalette.lull`.
    var fullToneLullLoss = 0.20
    /// How much the catspaw texture varies a puff's tone about its mean, 0 (smooth) to 1.
    var catspaw = 0.3

    // MARK: Whitecaps

    /// Below this conditions mean wind, knots, there are no whitecaps.
    var whitecapOnsetKnots = 9.0
    /// At and above this conditions mean wind, knots, `whitecapMaxShare` of the ripple tiles carry one.
    var whitecapFullKnots = 20.0
    /// The most ripple tiles that carry a whitecap at once.
    var whitecapMaxShare = 0.5
    /// A whitecap's alpha as it breaks; it fades over `whitecapSeconds`.
    var whitecapAlpha = 0.85
    /// Seconds from a whitecap breaking to the next one in its tile.
    var whitecapSeconds = 3.5

    // MARK: Upwind edge tint (#224)

    /// The tint's alpha at the screen edge for a puff at full tone right at the edge. A race cue: it never
    /// drops on the degradation ladder (#27, #127).
    var edgeTintStrength = 0.75
    /// How far beyond the screen edge a puff still tints it, metres; the tint fades out towards it.
    var edgeTintReach = 60.0
    /// How far the tint reaches into the screen, points.
    var edgeTintDepth = 90.0

    // MARK: Cheap tier (#127)

    /// The share of the whitecaps the cheap tier keeps.
    var cheapWhitecapShare = 0.5

    /// The shipped placeholders.
    static let standard = WaterStyle()
}

/// How much the water spends per frame (#127 picks it from thermal state; the ladder is #27's). The cheap tier
/// freezes the ripple (no drift, every tile on the course wind, no per-tile sampling) and thins the whitecaps.
/// Puff shading and the upwind edge tint are race cues, drawn the same in every tier.
nonisolated enum WaterQuality: Sendable {
    case full, cheap
}

/// The water's tones (#22, #15): puffs darker and lulls lighter than the course average, and the ripple fainter
/// than either. Each is a `ChartPalette` token drawn at an alpha over `ChartPalette.water`, blended as SpriteKit
/// blends (source over, in gamma-encoded sRGB), and measured in OKLCH lightness as `docs/palette.md` is.
nonisolated enum WaterTone {
    /// `overlay` drawn at `alpha` over `base`, as sRGB components.
    static func blend(_ overlay: PaletteToken, alpha: Double, over base: PaletteToken = ChartPalette.water) -> [Double] {
        zip(base.components, overlay.components).map { $0 + ($1 - $0) * alpha }
    }

    /// How far `overlay` at `alpha` moves the water's OKLCH lightness: negative darker.
    static func lightnessDelta(_ overlay: PaletteToken, alpha: Double) -> Double {
        OKLCH(srgb: blend(overlay, alpha: alpha)).L - ChartPalette.water.oklch.L
    }

    /// What a puff or lull of `intensity` draws with at its centre: its token and alpha. Its intensity is its
    /// wind speed there as a fraction of the course average (`WindField.courseAverageSpeed`), so the tone is
    /// relative to the course average; and it fades in from 0 at spawn (`Puff.intensity`, ADR 0001), so a
    /// puff never pops in at full tone.
    static func puffOverlay(intensity: Double, style: WaterStyle) -> (token: PaletteToken, alpha: Double) {
        if intensity >= 0 {
            return (ChartPalette.puff, (intensity / style.fullTonePuffGain).clamped(to: 0...1))
        }
        return (ChartPalette.lull, (-intensity / style.fullToneLullLoss).clamped(to: 0...1))
    }

    /// The lightness change a puff or lull of `intensity` makes at its centre.
    static func puffDelta(intensity: Double, style: WaterStyle) -> Double {
        let overlay = puffOverlay(intensity: intensity, style: style)
        return lightnessDelta(overlay.token, alpha: overlay.alpha)
    }

    /// The lightness change a ripple streak makes on open water.
    static func rippleDelta(style: WaterStyle) -> Double {
        lightnessDelta(ChartPalette.lull, alpha: style.rippleAlpha)
    }

    /// The faintest a visible puff or lull of `conditions` gets: the weaker of its weakest puff and its weakest
    /// lull, each at its peak. Any puff draws fainter than this only while it fades in or out.
    static func faintestPeakDelta(of conditions: Conditions, style: WaterStyle) -> Double {
        let puff = abs(puffDelta(intensity: conditions.puffs.gain.lowerBound, style: style))
        guard conditions.puffs.lullShare > 0 else { return puff }
        return min(puff, abs(puffDelta(intensity: -conditions.puffs.lullLoss.lowerBound, style: style)))
    }
}

/// Whitecaps (#22): mood, not a second puff signal. How many there are comes from the conditions' mean wind
/// alone, the same everywhere on the water, never from the wind where they are.
nonisolated enum Whitecaps {
    /// The conditions' mean wind, m/s: the middle of the range the race's base strength is drawn from.
    static func meanWind(of conditions: Conditions) -> Double {
        (conditions.strength.lowerBound + conditions.strength.upperBound) / 2
    }

    /// The share of ripple tiles carrying a whitecap in `conditions`, thinned in the cheap tier.
    static func share(in conditions: Conditions, style: WaterStyle, quality: WaterQuality = .full) -> Double {
        let knots = RegattaCore.knots(metresPerSecond: meanWind(of: conditions))
        let span = style.whitecapFullKnots - style.whitecapOnsetKnots
        let wind = span > 0 ? ((knots - style.whitecapOnsetKnots) / span).clamped(to: 0...1) : (knots >= style.whitecapFullKnots ? 1 : 0)
        return style.whitecapMaxShare * wind * (quality == .cheap ? style.cheapWhitecapShare : 1)
    }

    /// Whether ripple tile `cell` carries a whitecap in whitecap cycle `cycle`, at `share`: a hash of the tile
    /// and cycle under the share, so any patch of water carries the same share.
    static func breaks(at cell: RippleLattice.Index, cycle: Int, share: Double) -> Bool {
        WaterHash.unit(cell.i, cell.j, cycle, salt: 0x57_4843) < share
    }
}

/// The ripple's tiles: a staggered lattice fixed to the water, drifted downwind, of which only the tiles
/// covering the view are drawn. Snapping to the lattice keeps the water endless while one screen's worth of
/// sprites draws it.
nonisolated struct RippleLattice: Sendable {
    struct Index: Hashable, Sendable {
        var i: Int
        var j: Int
    }

    /// Points across between tiles; rows are 0.8 of it apart, every other one staggered by half.
    var spacing: Double
    var rowHeight: Double { spacing * 0.8 }

    /// The camera scale past which the lattice spreads out: pinching out goes to 1/0.45. Past it (the whole
    /// course in view), `spacing` doubles as often as it takes, so the tile count stays about a screen's worth.
    static let finestScale = 2.25

    /// The lattice for `style` at camera scale `scale`, and the scale its tiles draw at.
    static func forView(style: WaterStyle, cameraScale scale: Double) -> (lattice: RippleLattice, tileScale: Double) {
        let step = scale > finestScale ? pow(2, (log2(scale / finestScale)).rounded(.up)) : 1
        return (RippleLattice(spacing: style.rippleSpacing * step), step)
    }

    /// Where tile `index` is on the water, in world points, with the lattice drifted by `drift`: its lattice
    /// point jittered by a quarter of the spacing, so the ripple doesn't read as a grid.
    func position(of index: Index, drift: CGPoint) -> CGPoint {
        let stagger = index.j & 1 == 0 ? 0 : spacing / 2
        let jx = (WaterHash.unit(index.i, index.j, 0, salt: 0x4A_5858) - 0.5) * spacing / 2
        let jy = (WaterHash.unit(index.i, index.j, 0, salt: 0x4A_5959) - 0.5) * rowHeight / 2
        return CGPoint(x: Double(index.i) * spacing + stagger + jx + drift.x,
                       y: Double(index.j) * rowHeight + jy + drift.y)
    }

    /// The tiles whose streaks can reach into `view` (world points), with a tile to spare all round.
    func indices(covering view: CGRect, drift: CGPoint) -> (columns: ClosedRange<Int>, rows: ClosedRange<Int>) {
        let columns = Int(((view.minX - drift.x) / spacing).rounded(.down)) - 1...Int(((view.maxX - drift.x) / spacing).rounded(.up)) + 1
        let rows = Int(((view.minY - drift.y) / rowHeight).rounded(.down)) - 1...Int(((view.maxY - drift.y) / rowHeight).rounded(.up)) + 1
        return (columns, rows)
    }
}

/// The upwind edge tint (#224): a soft, water-toned darker tint along the upwind edge of the view where a puff
/// lies beyond it and is drifting in. No icons and no times. A race cue, like puff shading: every tier draws
/// it (#27).
nonisolated enum EdgeTint {
    /// Which edge of the view a tint lies on.
    enum Edge: Sendable {
        case top, bottom, left, right

        /// Pointing out of the view.
        var outwardNormal: Vec2 {
            switch self {
            case .top: Vec2(0, 1)
            case .bottom: Vec2(0, -1)
            case .left: Vec2(-1, 0)
            case .right: Vec2(1, 0)
            }
        }
    }

    struct Mark: Equatable, Sendable {
        var edge: Edge
        /// Where on the edge, in the view's own frame: metres from the view's centre.
        var point: Vec2
        /// Metres along the edge: the puff's diameter.
        var width: Double
        /// 0…1: `WaterStyle.edgeTintStrength` at the puff's tone, fading with its distance beyond the edge.
        var alpha: Double
    }

    /// The tints for `puffs` around the view centred at `center` with half-size `half` (metres). A puff tints
    /// the upwind edge its drift carries it in across, at the point it crosses, while its centre is out of view
    /// and its edge within `style.edgeTintReach` of the view. Lulls, puffs drifting away or past, and puffs
    /// coming in across a side edge tint nothing.
    static func marks(for puffs: [Puff], center: Vec2, half: Vec2, style: WaterStyle) -> [Mark] {
        puffs.compactMap { mark(for: $0, center: center, half: half, style: style) }
    }

    static func mark(for puff: Puff, center: Vec2, half: Vec2, style: WaterStyle) -> Mark? {
        guard puff.intensity > 0, style.edgeTintReach > 0 else { return nil }
        let p = puff.center - center
        guard abs(p.x) > half.x || abs(p.y) > half.y else { return nil }
        let outside = Vec2(max(abs(p.x) - half.x, 0), max(abs(p.y) - half.y, 0))
        let gap = outside.length - puff.radius
        guard gap < style.edgeTintReach else { return nil }
        let direction = puff.velocity.normalized
        guard direction != .zero else { return nil }
        // Where its drift line enters the view grown by its radius: a slab test, axis by axis.
        let grown = half + Vec2(puff.radius, puff.radius)
        var enter = -Double.infinity, exit = Double.infinity
        var edge = Edge.top
        for axis in 0..<2 {
            let d = direction[axis], o = p[axis], h = grown[axis]
            if abs(d) < 1e-9 {
                guard abs(o) <= h else { return nil }
                continue
            }
            let t0 = (-h - o) / d, t1 = (h - o) / d
            let near = min(t0, t1), far = max(t0, t1)
            if near > enter {
                enter = near
                edge = axis == 0 ? (d > 0 ? .left : .right) : (d > 0 ? .bottom : .top)
            }
            exit = min(exit, far)
        }
        guard enter <= exit, exit > 0 else { return nil }
        // Only an upwind edge: one facing within 60° of where the puff comes from. A puff crossing a side edge
        // on a slant is coming from the side, not from upwind.
        guard edge.outwardNormal.dot(-direction) >= 0.5 else { return nil }
        let entry = p + direction * max(enter, 0)
        let point = Vec2(entry.x.clamped(to: -half.x...half.x), entry.y.clamped(to: -half.y...half.y))
        let tone = WaterTone.puffOverlay(intensity: puff.intensity, style: style).alpha
        let proximity = (1 - max(gap, 0) / style.edgeTintReach).clamped(to: 0...1)
        return Mark(edge: edge, point: point, width: puff.radius * 2, alpha: style.edgeTintStrength * tone * proximity)
    }
}

/// A fixed integer hash to 0..<1, for the water's scatter: the same on every run, so a frozen render fixture
/// draws the same pixels every time (#62).
nonisolated enum WaterHash {
    static func unit(_ a: Int, _ b: Int, _ c: Int, salt: UInt64) -> Double {
        var x = mix(salt)
        x = mix(x ^ UInt64(bitPattern: Int64(a)))
        x = mix(x ^ UInt64(bitPattern: Int64(b)))
        x = mix(x ^ UInt64(bitPattern: Int64(c)))
        return Double(x >> 11) / Double(UInt64(1) << 53)
    }

    /// SplitMix64's finaliser.
    private static func mix(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
