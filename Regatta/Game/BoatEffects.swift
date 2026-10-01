import SpriteKit
import RegattaCore

/// What one boat draws on the water beneath the fleet (#15, #10, #298, #121): her wind-shadow cone and backwind
/// zone, faint black hatches, and her wake, a V from her stern with a centre streak. Every one a sprite sharing a
/// few textures per class and scale (`EffectArt`), sized and turned each frame: nothing rebuilds a path or a
/// texture as she sails, so 16 boats' effects batch into a handful of draw calls.
///
/// The nodes live in the scene's effects layer, in world space (`nodes`), not under the boat's node, so they turn
/// with the water and the boat's ghost fade doesn't reach them: a ghost's wake fades by her own alpha here, and
/// her cone and backwind are hidden (#30: she casts neither). Her cone goes into the fleet's one `ConeLayer`
/// instead, so the fleet's overlapping cones don't darken into a mat.
final class BoatEffects {
    /// The cone, apex at the boat, down her apparent wind (#10): an opaque hatch, a mask in the fleet's
    /// `ConeLayer`, which draws it at `BoatStyle.coneAlpha`.
    let cone: SKSpriteNode
    /// The backwind trapezoid on her windward quarter (#298), its hatch fading from her stern to its far edge as
    /// its loss does; hidden for a class with #79's band.
    let backwind: SKSpriteNode
    /// The wake, at her stern and turned to her heading: its V (`wedge`) and centre streak. An effect node so a
    /// ghost's wake fades as one flat image, as her hull does (#30); its effect is on for ghosts only.
    let wake = SKEffectNode()
    let wedge: SKSpriteNode
    let streak: SKSpriteNode

    /// The nodes the scene adds to its effects layer; the cone goes into its `ConeLayer`.
    var nodes: [SKNode] { [backwind, wake] }

    /// How many nodes she draws on the water: her cone, `nodes` and their children (the `-perf` log).
    var nodeCount: Int { nodes.reduce(1) { $0 + 1 + $1.children.count } }

    /// The z's within a boat's effects, each boat a `DrawOrder` slot above the last by seat: every cone under
    /// every backwind under every wake; the streak over its V.
    enum Layer {
        /// The fleet's `ConeLayer`, under every boat's slot.
        static let cones: CGFloat = -0.5
        static let backwind: CGFloat = 0.1, wake: CGFloat = 0.5
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
        wake.shouldEnableEffects = false
        wake.shouldRasterize = false

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
        cone.zPosition = slot
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
        if wake.shouldEnableEffects != pose.isGhost { wake.shouldEnableEffects = pose.isGhost }
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

/// The fleet's wind-shadow cones as one faint layer (#15: very faint hatched cones). Each boat's cone hatch is a
/// mask here, and one black sheet shows through their union at `BoatStyle.coneAlpha`: so a cone's lines are
/// just readable on the water, and where ten cones overlap no line is darker than one cone's, only the hatch
/// denser. The mask and the sheet sit at the layer's origin, so each cone lands where its own transform puts it.
final class ConeLayer: SKCropNode {
    /// The sheet the cones show: big enough to cover any course.
    let sheet = SKSpriteNode(color: .black, size: CGSize(width: 400_000, height: 400_000))
    private let masks = SKNode()

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override init() {
        super.init()
        zPosition = BoatEffects.Layer.cones
        maskNode = masks
        addChild(sheet)
    }

    /// The cones it shows.
    var cones: [SKNode] { masks.children }

    /// Shows `effects`' cone.
    func add(_ effects: BoatEffects) {
        masks.addChild(effects.cone)
    }

    /// Draws the cones at `style`'s alpha.
    func update(style: BoatStyle) {
        sheet.alpha = CGFloat(style.coneAlpha)
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

        if let corners = ShadowShapes.backwindLocal(shadow), let inner = shadow.backwindInnerLength {
            let backwindPoints = points(corners)
            // Taking in the boat's centre, so the anchor is inside the texture.
            let bounds = Self.bounds(of: backwindPoints + [.zero])
            backwind = Self.hatch(backwindPoints, bounds: bounds, spacing: spacing, width: width) { cg in
                Self.fadeBackwind(cg, shadow: shadow, inner: inner, ppm: ppm)
            }
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

    /// Diagonal lines `spacing` apart and `width` wide, clipped to `outline`: the cones' hatch (#15). `fade`, if
    /// any, then fades it (drawing with `.destinationIn`).
    private static func hatch(_ outline: [CGPoint], bounds: CGRect, spacing: CGFloat, width: CGFloat,
                              fade: ((CGContext) -> Void)? = nil) -> SKTexture {
        SpriteArt.texture(bounds: bounds) { cg in
            cg.saveGState()
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
            cg.restoreGState()
            if let fade {
                cg.setBlendMode(.destinationIn)
                fade(cg)
            }
        }
    }

    /// Fades the backwind's hatch as core's loss fades (`ShadowCone`'s backwind factor, #298): full along her
    /// stern edge, straight down to nothing at the far edge, which reaches `inner` astern on the inside and
    /// `backwindLength` on the outside. Column by column, a texel wide, in the art's frame (starboard tack).
    private static func fadeBackwind(_ cg: CGContext, shadow: BoatClass.WindShadow, inner: Double, ppm: CGFloat) {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let gradient = CGGradient(colorsSpace: space, colors: [UIColor.white.cgColor,
                                                                     UIColor(white: 1, alpha: 0).cgColor] as CFArray,
                                        locations: [0, 1]) else { return }
        let stern = CGFloat(shadow.sternCorner.y) * ppm, x0 = CGFloat(shadow.sternCorner.x) * ppm
        let width = CGFloat(shadow.backwindWidth) * ppm
        let step: CGFloat = 1.0 / 3
        // Unblended strip edges, so the strips share each texel out exactly once.
        cg.setShouldAntialias(false)
        var x: CGFloat = -step
        while x < width + step {
            let out = Double((x + step / 2) / width).clamped(to: 0...1)
            let reach = CGFloat(inner + (shadow.backwindLength - inner) * out) * ppm
            cg.saveGState()
            cg.clip(to: CGRect(x: x0 + x, y: stern - reach - 2, width: step, height: reach + 4))
            cg.drawLinearGradient(gradient, start: CGPoint(x: 0, y: stern), end: CGPoint(x: 0, y: stern - reach),
                                  options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            cg.restoreGState()
            x += step
        }
    }

    /// The wake's V on a 64 × 128 point unit (#220): two soft arms from the apex at the top centre over a fainter
    /// translucent fill between them, the whole of it fading astern (`tailFade`), so it reads as a wake spreading
    /// behind her, not as rays.
    private static func wedgeTexture() -> SKTexture {
        let bounds = CGRect(x: -32, y: -128, width: 64, height: 128)
        return SpriteArt.texture(bounds: bounds, scale: 2) { cg in
            let apex = CGPoint(x: 0, y: 0), port = CGPoint(x: -30, y: -128), starboard = CGPoint(x: 30, y: -128)
            let fill = CGMutablePath()
            fill.addLines(between: [apex, starboard, port])
            fill.closeSubpath()
            cg.addPath(fill)
            cg.setFillColor(UIColor(white: 1, alpha: 0.18).cgColor)
            cg.fillPath()
            // Each arm a soft line: wide and faint outside, narrower and brighter at its core.
            let arms = CGMutablePath()
            arms.addLines(between: [port, apex, starboard])
            cg.setLineJoin(.round)
            for (width, alpha) in [(5.0, 0.1), (3.0, 0.18), (1.25, 0.35)] as [(CGFloat, CGFloat)] {
                cg.addPath(arms)
                cg.setLineWidth(width)
                cg.setStrokeColor(UIColor(white: 1, alpha: alpha).cgColor)
                cg.strokePath()
            }
            tailFade(cg, from: apex, to: CGPoint(x: 0, y: -128))
        }
    }

    /// The centre streak on an 8 × 128 point unit: a soft line, brightest down its middle and gone at its edges
    /// (it draws twice the streak's width), fading astern.
    private static func streakTexture() -> SKTexture {
        let bounds = CGRect(x: -4, y: -128, width: 8, height: 128)
        return SpriteArt.texture(bounds: bounds, scale: 2) { cg in
            let space = CGColorSpaceCreateDeviceRGB()
            let clear = UIColor(white: 1, alpha: 0).cgColor, soft = UIColor(white: 1, alpha: 0.35).cgColor
            guard let across = CGGradient(colorsSpace: space, colors: [clear, soft, UIColor.white.cgColor, soft, clear] as CFArray,
                                          locations: [0, 0.25, 0.5, 0.75, 1]) else { return }
            cg.drawLinearGradient(across, start: CGPoint(x: -4, y: 0), end: CGPoint(x: 4, y: 0), options: [])
            tailFade(cg, from: .zero, to: CGPoint(x: 0, y: -128))
        }
    }

    /// Fades what's drawn from full at `start` to nothing at `end`, easing out (alpha (1 - t)²): most of a wake's
    /// brightness is close under her stern, its tail dies away.
    private static func tailFade(_ cg: CGContext, from start: CGPoint, to end: CGPoint) {
        let stops: [CGFloat] = [0, 0.25, 0.5, 0.75, 1]
        let colors = stops.map { UIColor(white: 1, alpha: (1 - $0) * (1 - $0)).cgColor }
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
                                        locations: stops) else { return }
        cg.saveGState()
        cg.setBlendMode(.destinationIn)
        cg.drawLinearGradient(gradient, start: start, end: end,
                              options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        cg.restoreGState()
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
