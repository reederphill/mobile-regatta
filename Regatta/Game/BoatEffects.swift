import SpriteKit
import RegattaCore

/// What one boat draws on the water beneath the fleet (#15, #10, #298, #121): her wind-shadow cone and backwind
/// zone, faint black hatches, and her wake, a V from her stern with a centre streak. Every one a sprite sharing a
/// few textures per class and scale (`EffectArt`), sized and turned each frame: nothing rebuilds a path or a
/// texture as she sails, so 16 boats' effects batch into a handful of draw calls.
///
/// The nodes live in the scene's effects layer, in world space (`nodes`), not under the boat's node, so they turn
/// with the water and the boat's ghost fade doesn't reach them: a ghost's wake fades by her own alpha here, and
/// her cone and backwind are hidden (#30: she casts neither).
final class BoatEffects {
    /// The cone, apex at the boat, down her apparent wind (#10).
    let cone: SKSpriteNode
    /// The backwind trapezoid on her windward quarter (#298); hidden for a class with #79's band.
    let backwind: SKSpriteNode
    /// The wake, at her stern and turned to her heading: its V (`wedge`) and centre streak.
    let wake = SKNode()
    let wedge: SKSpriteNode
    let streak: SKSpriteNode

    /// The nodes the scene adds to its effects layer.
    var nodes: [SKNode] { [cone, backwind, wake] }

    /// The z's within a boat's effects, each boat a `DrawOrder` slot above the last by seat: every cone under
    /// every backwind under every wake; the streak over its V.
    enum Layer {
        static let cone: CGFloat = 0, backwind: CGFloat = 0.1, wake: CGFloat = 0.5
        static let wedge: CGFloat = 0, streak: CGFloat = 0.05
    }

    private let ppm: CGFloat
    private let boatClass: BoatClass
    private let hasBackwind: Bool
    /// The wake drawn last frame, eased towards each frame's (`BoatStyle.wakeEaseRate`).
    private(set) var shape: WakeShape?
    private var flare = FlareTimer()

    init(seat: Int, boatClass: BoatClass, pointsPerMeter ppm: CGFloat, style: BoatStyle) {
        self.ppm = ppm
        self.boatClass = boatClass
        let art = EffectArt.shared(shadow: boatClass.windShadow, pointsPerMeter: ppm, style: style)

        cone = SKSpriteNode(texture: art.cone)
        cone.anchorPoint = art.coneAnchor
        backwind = SKSpriteNode(texture: art.backwind)
        backwind.anchorPoint = art.backwindAnchor
        hasBackwind = art.backwind != nil
        for hatch in [cone, backwind] {
            hatch.color = .black
            hatch.colorBlendFactor = 1
        }
        backwind.isHidden = !hasBackwind

        let white = CuePalette.cueWhite.uiColor
        wedge = SKSpriteNode(texture: art.wedge)
        streak = SKSpriteNode(texture: art.streak)
        for sprite in [wedge, streak] {
            sprite.anchorPoint = CGPoint(x: 0.5, y: 1) // at the stern, reaching astern
            sprite.color = white
            sprite.colorBlendFactor = 1
            sprite.size = .zero
            wake.addChild(sprite)
        }
        wedge.zPosition = Layer.wedge
        streak.zPosition = Layer.streak

        let slot = DrawOrder.z(seat)
        cone.zPosition = Layer.cone + slot
        backwind.zPosition = Layer.backwind + slot
        wake.zPosition = Layer.wake + slot
    }

    /// Draws `boat`'s effects in `pose` at race time `time`. `isFlogging` is her sail's roll-miss flog this frame
    /// (`FlogTimer`): her wake dies while it lasts and comes back with it (#222). `settled` draws the wake straight
    /// at its target, with no easing (a frozen render fixture).
    func update(with boat: Boat, pose: BoatPose, style: BoatStyle, quality: WakeQuality, time: Double, dt: Double,
                settled: Bool, isFlogging: Bool) {
        let point = CGPoint(x: boat.position.x * ppm, y: boat.position.y * ppm)

        cone.isHidden = pose.isGhost
        cone.position = point
        cone.zRotation = CGFloat(-(boat.apparentWind.direction + .pi)) // the cone follows her apparent wind (#10)
        cone.alpha = CGFloat(style.coneAlpha)

        // Her windward side is starboard on starboard tack (`ShadowCone.windward`); it flips at the boom crossing.
        backwind.isHidden = pose.isGhost || !hasBackwind
        backwind.position = point
        backwind.zRotation = CGFloat(-boat.heading)
        backwind.xScale = boat.tack == .starboard ? 1 : -1
        backwind.alpha = CGFloat(style.coneAlpha * style.backwindShare)

        // A roll miss kills the wake; a hit flares it, fading (#222).
        let flare = flare.flare(roll: pose.roll, time: time, seconds: style.wakeFlareSeconds)
        let level = isFlogging ? 0 : 1 + style.wakeFlareGain * flare
        let target = WakeShape(boat, boatClass: boatClass, style: style, quality: quality).scaled(by: level)
        let shape = settled ? target : (shape ?? target).eased(towards: target, dt: dt, rate: style.wakeEaseRate)
        self.shape = shape

        // A rigid V from her stern, turned to her heading: it trails no history, so the current can't bend it.
        let stern = boat.position + boat.forward * boatClass.windShadow.sternCorner.y
        wake.position = CGPoint(x: stern.x * ppm, y: stern.y * ppm)
        wake.zRotation = CGFloat(-boat.heading)
        wake.alpha = pose.isGhost ? CGFloat(style.ghostAlpha) : 1

        let length = CGFloat(shape.length) * ppm
        wedge.size = CGSize(width: 2 * length * CGFloat(tan(shape.halfAngle)), height: length)
        wedge.alpha = CGFloat(shape.alpha)
        wedge.isHidden = length < 0.5 || shape.alpha < 0.005
        let streakLength = CGFloat(shape.streakLength) * ppm
        // The streak's texture is half soft margin, so it draws twice its width.
        streak.size = CGSize(width: 2 * CGFloat(style.wakeStreakWidth) * ppm, height: streakLength)
        streak.alpha = CGFloat(shape.streakAlpha)
        streak.isHidden = streakLength < 0.5 || shape.streakAlpha < 0.005
    }
}

/// The effects' shared textures, per class's wind shadow, scale and hatch: drawn in white so each sprite is tinted.
private struct EffectArt {
    /// The cone's hatched trapezoid (`ShadowShapes.coneLocal`), apex at its anchor, widening along +y.
    let cone: SKTexture
    let coneAnchor: CGPoint
    /// The backwind's hatched trapezoid (`ShadowShapes.backwindLocal`) in the boat's frame on starboard tack, the
    /// boat's centre at its anchor; nil for a class with #79's band.
    let backwind: SKTexture?
    let backwindAnchor: CGPoint
    /// Unit gradients the wake's sprites stretch: the V, apex at the top centre, and the streak.
    let wedge: SKTexture
    let streak: SKTexture

    /// Everything the art is drawn from: every wind-shadow size baked in, the scale and the hatch, so a tuned class
    /// never shows a stale shape.
    private struct Key: Hashable {
        var shadow: [Double]
        var ppm: CGFloat
        var hatch: [Double]
    }

    private static var cache: [Key: EffectArt] = [:]

    static func shared(shadow: BoatClass.WindShadow, pointsPerMeter ppm: CGFloat, style: BoatStyle) -> EffectArt {
        let key = Key(shadow: [shadow.coneLength, shadow.coneWidthAtBoat, shadow.coneWidthAtEnd,
                               shadow.backwindLength, shadow.backwindWidth, shadow.backwindInnerLength ?? -1,
                               shadow.sternCorner.x, shadow.sternCorner.y],
                      ppm: ppm, hatch: [style.hatchSpacing, style.hatchLineWidth])
        if let art = cache[key] { return art }
        let art = EffectArt(shadow: shadow, ppm: ppm, style: style)
        cache[key] = art
        return art
    }

    private init(shadow: BoatClass.WindShadow, ppm: CGFloat, style: BoatStyle) {
        let spacing = CGFloat(max(style.hatchSpacing, 1)), width = CGFloat(max(style.hatchLineWidth, 0.25))
        func points(_ corners: [Vec2]) -> [CGPoint] { corners.map { CGPoint(x: $0.x * ppm, y: $0.y * ppm) } }

        let conePoints = points(ShadowShapes.coneLocal(shadow))
        let coneBounds = Self.bounds(of: conePoints)
        cone = Self.hatch(conePoints, bounds: coneBounds, spacing: spacing, width: width)
        coneAnchor = Self.anchor(coneBounds)

        if let corners = ShadowShapes.backwindLocal(shadow) {
            let backwindPoints = points(corners)
            // Taking in the boat's centre, so the anchor is inside the texture.
            let bounds = Self.bounds(of: backwindPoints + [.zero])
            backwind = Self.hatch(backwindPoints, bounds: bounds, spacing: spacing, width: width)
            backwindAnchor = Self.anchor(bounds)
        } else {
            backwind = nil
            backwindAnchor = CGPoint(x: 0.5, y: 0.5)
        }

        wedge = Self.wedgeTexture()
        streak = Self.streakTexture()
    }

    private static func bounds(of points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        let minX = xs.min() ?? 0, minY = ys.min() ?? 0
        return CGRect(x: minX, y: minY, width: max((xs.max() ?? 0) - minX, 1), height: max((ys.max() ?? 0) - minY, 1))
    }

    /// The anchor that puts the art's origin at the sprite's position.
    private static func anchor(_ bounds: CGRect) -> CGPoint {
        CGPoint(x: -bounds.minX / bounds.width, y: -bounds.minY / bounds.height)
    }

    /// Diagonal lines `spacing` apart and `width` wide, clipped to `outline`: the cones' hatch (#15).
    private static func hatch(_ outline: [CGPoint], bounds: CGRect, spacing: CGFloat, width: CGFloat) -> SKTexture {
        SpriteArt.texture(bounds: bounds) { cg in
            let path = CGMutablePath()
            path.addLines(between: outline)
            path.closeSubpath()
            cg.addPath(path)
            cg.clip()
            let lines = CGMutablePath()
            var offset = -bounds.height
            while offset < bounds.width {
                lines.move(to: CGPoint(x: bounds.minX + offset, y: bounds.minY))
                lines.addLine(to: CGPoint(x: bounds.minX + offset + bounds.height, y: bounds.maxY))
                offset += spacing * 2.squareRoot()
            }
            cg.addPath(lines)
            cg.setStrokeColor(UIColor.white.cgColor)
            cg.setLineWidth(width)
            cg.strokePath()
        }
    }

    /// The wake's V on a 64 × 128 point unit: its two arms from the apex at the top centre, fading astern, over a
    /// fainter translucent fill between them (#220's ribbon).
    private static func wedgeTexture() -> SKTexture {
        let bounds = CGRect(x: -32, y: -128, width: 64, height: 128)
        return SpriteArt.texture(bounds: bounds, scale: 2) { cg in
            let apex = CGPoint(x: 0, y: 0), port = CGPoint(x: -31, y: -128), starboard = CGPoint(x: 31, y: -128)
            let space = CGColorSpaceCreateDeviceRGB()
            func fade(_ alpha: CGFloat) -> CGGradient? {
                CGGradient(colorsSpace: space, colors: [UIColor(white: 1, alpha: alpha).cgColor,
                                                        UIColor(white: 1, alpha: 0).cgColor] as CFArray,
                           locations: [0, 1])
            }
            let fill = CGMutablePath()
            fill.addLines(between: [apex, starboard, port])
            fill.closeSubpath()
            if let gradient = fade(0.35) {
                cg.saveGState()
                cg.addPath(fill)
                cg.clip()
                cg.drawLinearGradient(gradient, start: apex, end: CGPoint(x: 0, y: -128), options: [])
                cg.restoreGState()
            }
            let arms = CGMutablePath()
            arms.addLines(between: [port, apex, starboard])
            if let gradient = fade(1) {
                cg.saveGState()
                cg.addPath(arms)
                cg.setLineWidth(2)
                cg.setLineJoin(.round)
                cg.replacePathWithStrokedPath()
                cg.clip()
                cg.drawLinearGradient(gradient, start: apex, end: CGPoint(x: 0, y: -128), options: [])
                cg.restoreGState()
            }
        }
    }

    /// The centre streak on an 8 × 128 point unit: a soft line down its middle, half its width, fading astern.
    private static func streakTexture() -> SKTexture {
        let bounds = CGRect(x: -4, y: -128, width: 8, height: 128)
        return SpriteArt.texture(bounds: bounds, scale: 2) { cg in
            let space = CGColorSpaceCreateDeviceRGB()
            guard let gradient = CGGradient(colorsSpace: space,
                                            colors: [UIColor.white.cgColor, UIColor(white: 1, alpha: 0).cgColor] as CFArray,
                                            locations: [0, 1]) else { return }
            cg.addPath(CGPath(roundedRect: CGRect(x: -2, y: -128, width: 4, height: 128), cornerWidth: 2,
                              cornerHeight: 2, transform: nil))
            cg.clip()
            cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: -128), options: [])
        }
    }
}

/// Renders boat and effect art into textures.
enum SpriteArt {
    /// Renders `draw` into a texture whose coordinate space is y-up with `bounds` mapped onto the image, matching
    /// SpriteKit.
    static func texture(bounds: CGRect, scale: CGFloat = 3, draw: (CGContext) -> Void) -> SKTexture {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let image = UIGraphicsImageRenderer(size: bounds.size, format: format).image { context in
            let cg = context.cgContext
            cg.translateBy(x: -bounds.minX, y: bounds.maxY)
            cg.scaleBy(x: 1, y: -1)
            draw(cg)
        }
        return SKTexture(image: image)
    }
}
