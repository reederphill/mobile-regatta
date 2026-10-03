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

/// The turbulence trails drawn (#376 follow-on A): one sprite a live sample, a soft white disc (white centre to a
/// clear edge, as a sample's loss falls from its centre) at the sample's drifted centre, as wide as it has grown, and
/// faded as its loss fades with age. Cone samples draw at the cone's hatch alpha (`BoatStyle.coneAlpha`) and z,
/// backwind samples at the backwind's share of it (`BoatStyle.backwindShare`) and z, both in the cues' white, as
/// `BoatEffects` draws them. The sprites are pooled: grown on demand, the unused ones hidden. Drawn only; the race
/// never reads the trails.
final class TurbulenceTrailLayer: SKNode {
    /// The one disc every sample draws with, made once.
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

    private let ppm: CGFloat
    private(set) var sprites: [SKSpriteNode] = []

    /// The sprites showing a sample now.
    var visibleCount: Int { sprites.filter { !$0.isHidden }.count }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    init(pointsPerMeter ppm: CGFloat) {
        self.ppm = ppm
        super.init()
        name = "turbulenceTrails"
    }

    /// Draws `samples` at race time `time` (seconds; between ticks, so they drift smoothly), in `shadow`'s class and
    /// `style`'s alphas. A sample past its life, or not yet born, draws nothing.
    func update(samples: [TurbulenceTrails.Sample], time: Double, shadow: BoatClass.WindShadow, style: BoatStyle) {
        var used = 0
        for sample in samples {
            let age = max(0, time - Double(sample.born) * Race.dt)
            guard age < sample.life else { continue }
            let alpha = Self.alpha(of: sample, age: age, shadow: shadow, style: style)
            guard alpha > 0 else { continue }
            if used == sprites.count { grow() }
            let sprite = sprites[used]
            used += 1
            let centre = sample.position + sample.drift * age
            let diameter = CGFloat(2 * (sample.radius + sample.growth * age)) * ppm
            sprite.position = CGPoint(x: centre.x * ppm, y: centre.y * ppm)
            sprite.size = CGSize(width: diameter, height: diameter)
            sprite.alpha = CGFloat(alpha)
            sprite.zPosition = sample.isBackwind ? BoatEffects.Layer.backwind : BoatEffects.Layer.cones
            sprite.isHidden = false
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
