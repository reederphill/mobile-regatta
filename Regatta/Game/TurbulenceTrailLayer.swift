import SpriteKit
import UIKit
import RegattaCore

/// How the wind shadow is drawn (#376 follow-on A): the cones and backwinds of today (`BoatEffects`), the
/// turbulence-trail prototype (`TurbulenceTrails`, `TurbulenceTrailLayer`), or both over each other. A Debug look
/// (the tuning panel's, and `-shadowDrawing`); Release always draws the cones.
enum ShadowDrawing: String, Codable, CaseIterable {
    case cones, trails, both

    var drawsCones: Bool { self != .trails }
    var drawsTrails: Bool { self != .cones }
}

/// The turbulence trails drawn (#376 follow-on A): one soft ribbon a caster and kind (cone or backwind), along her live
/// samples' drifted centres from oldest to newest. Each pair of neighbours draws one segment between them, as wide as
/// the wider has grown, white along its middle and clear at its edges (as a sample's loss falls from its centre), and
/// faded by the two ends' losses now. Neighbouring segments abut instead of overlapping, so a caster's ribbon shows the
/// strongest of her samples, as the model's loss takes it, rather than a sum. The newest end is capped with a soft disc
/// at half its alpha so the ribbon doesn't start square at the boat; a lone sample draws as the disc. Different casters
/// overlap and blend, as they stack in the model. Cone ribbons draw at the cone's hatch alpha (`BoatStyle.coneAlpha`)
/// and z, backwind ones at the backwind's share of it (`BoatStyle.backwindShare`) and z, both in the cues' white, as
/// `BoatEffects` draws them. The sprites are pooled: grown on demand, the unused ones hidden. Drawn only; the race
/// never reads the trails.
final class TurbulenceTrailLayer: SKNode {
    /// The disc a lone sample, or a ribbon's newest end, draws with, made once.
    static let disc: SKTexture = {
        let side: CGFloat = 64
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            let colors = [UIColor.white.cgColor, UIColor.white.withAlphaComponent(0).cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors,
                                            locations: [0, 1]) else { return }
            let centre = CGPoint(x: side / 2, y: side / 2)
            context.cgContext.drawRadialGradient(gradient, startCenter: centre, startRadius: 0, endCenter: centre,
                                                 endRadius: side / 2, options: [])
        }
        return SKTexture(image: image)
    }()

    /// The band a ribbon's segments draw with, made once: flat along its length (x), clear to white to clear across
    /// its width (y), falling linearly to the edges as a sample's loss does.
    static let band: SKTexture = {
        let size = CGSize(width: 4, height: 64)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            let clear = UIColor.white.withAlphaComponent(0).cgColor
            let colors = [clear, UIColor.white.cgColor, clear] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors,
                                            locations: [0, 0.5, 1]) else { return }
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height),
                                                 options: [])
        }
        return SKTexture(image: image)
    }()

    /// Points each segment runs past its ends. Abutting rotated quads leave hairline seams either way: at 0 thin dark
    /// lines of water, at 0.5 thin bright doubled lines (iPhone 17 simulator). 0 reads quieter; a ribbon drawn as one
    /// strip would have none.
    static let seam: CGFloat = 0

    private let ppm: CGFloat
    private(set) var sprites: [SKSpriteNode] = []

    /// The sprites drawing now.
    var visibleCount: Int { sprites.filter { !$0.isHidden }.count }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    init(pointsPerMeter ppm: CGFloat) {
        self.ppm = ppm
        super.init()
        name = "turbulenceTrails"
    }

    /// A live sample where it is now: its drifted centre and grown radius (metres) and its alpha.
    private struct Point {
        var centre: Vec2
        var radius: Double
        var alpha: Double
    }

    /// Draws `samples` at race time `time` (seconds; between ticks, so they drift smoothly), in `shadow`'s class and
    /// `style`'s alphas: a ribbon a caster and kind, segment by segment, and its cap. A sample past its life, or not
    /// yet born, draws nothing.
    func update(samples: [TurbulenceTrails.Sample], time: Double, shadow: BoatClass.WindShadow, style: BoatStyle) {
        struct Key: Hashable, Comparable {
            var caster: Int
            var isBackwind: Bool
            static func < (a: Key, b: Key) -> Bool {
                (a.caster, a.isBackwind ? 1 : 0) < (b.caster, b.isBackwind ? 1 : 0)
            }
        }
        var ribbons: [Key: [(born: Int, point: Point)]] = [:]
        for sample in samples {
            let age = max(0, time - Double(sample.born) * Race.dt)
            guard age < sample.life else { continue }
            let point = Point(centre: sample.position + sample.drift * age, radius: sample.radius + sample.growth * age,
                              alpha: Self.alpha(of: sample, age: age, shadow: shadow, style: style))
            ribbons[Key(caster: sample.caster, isBackwind: sample.isBackwind), default: []].append((sample.born, point))
        }
        var used = 0
        func next(_ texture: SKTexture, z: CGFloat) -> SKSpriteNode {
            if used == sprites.count { grow() }
            let sprite = sprites[used]
            used += 1
            if sprite.texture !== texture { sprite.texture = texture }
            sprite.zPosition = z
            sprite.isHidden = false
            return sprite
        }
        for key in ribbons.keys.sorted() {
            // Oldest to newest; samples born on one tick keep their order.
            let points = ribbons[key]!.enumerated().sorted { ($0.element.born, $0.offset) < ($1.element.born, $1.offset) }
                .map(\.element.point)
            let z = key.isBackwind ? BoatEffects.Layer.backwind : BoatEffects.Layer.cones
            for (a, b) in zip(points, points.dropFirst()) {
                let alpha = (a.alpha + b.alpha) / 2
                guard alpha > 0 else { continue }
                let sprite = next(Self.band, z: z)
                let along = b.centre - a.centre
                let mid = (a.centre + b.centre) * 0.5
                sprite.position = CGPoint(x: mid.x * ppm, y: mid.y * ppm)
                sprite.zRotation = CGFloat(atan2(along.y, along.x))
                sprite.size = CGSize(width: CGFloat(along.length) * ppm + Self.seam, height: CGFloat(2 * max(a.radius, b.radius)) * ppm)
                sprite.alpha = CGFloat(alpha)
            }
            guard let newest = points.last else { continue }
            let alpha = points.count == 1 ? newest.alpha : newest.alpha / 2
            guard alpha > 0 else { continue }
            let sprite = next(Self.disc, z: z)
            let diameter = CGFloat(2 * newest.radius) * ppm
            sprite.position = CGPoint(x: newest.centre.x * ppm, y: newest.centre.y * ppm)
            sprite.zRotation = 0
            sprite.size = CGSize(width: diameter, height: diameter)
            sprite.alpha = CGFloat(alpha)
        }
        for sprite in sprites[used...] where !sprite.isHidden { sprite.isHidden = true }
    }

    /// Hides every sprite.
    func clear() {
        for sprite in sprites where !sprite.isHidden { sprite.isHidden = true }
    }

    /// A sample's alpha at `age`: its loss now as a share of its kind's strongest (the class's `lossCloseIn` for a cone
    /// sample, `backwindLoss` for a backwind one), at the cone's hatch alpha, and the backwind's share of it, as
    /// `BoatEffects` draws them.
    static func alpha(of sample: TurbulenceTrails.Sample, age: Double, shadow: BoatClass.WindShadow,
                      style: BoatStyle) -> Double {
        let strongest = sample.isBackwind ? shadow.backwindLoss : shadow.lossCloseIn
        guard strongest > 0, sample.life > 0 else { return 0 }
        let share = (sample.peak / strongest) * max(0, 1 - age / sample.life)
        let base = sample.isBackwind ? style.coneAlpha * style.backwindShare : style.coneAlpha
        return min(1, base * share)
    }

    private func grow() {
        let sprite = SKSpriteNode(texture: Self.disc)
        sprite.color = CuePalette.cueWhite.uiColor
        sprite.colorBlendFactor = 1
        sprite.isHidden = true
        sprites.append(sprite)
        addChild(sprite)
    }
}
