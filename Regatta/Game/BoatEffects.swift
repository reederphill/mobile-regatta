import CoreImage
import SpriteKit
import RegattaCore

/// What one boat draws on the water beneath the fleet (#15, #10, #298, #121): her wind-shadow cone and backwind
/// zone, hatches in white, and her wake, a string of her recent track from her stern. The cone and backwind are
/// sprites sharing a few textures per class and scale (`EffectArt`), sized and turned each frame; the wake is one
/// stroked path a boat, rebuilt each frame from a short history.
///
/// The nodes live in the scene's effects layer, in world space (`nodes`), not under the boat's node, so they turn
/// with the water and the boat's ghost fade doesn't reach them: a ghost's wake drains away, and her cone and
/// backwind are hidden (#30: she casts neither). Her cone goes into the fleet's one `ConeLayer`
/// instead, so the fleet's overlapping cones don't darken into a mat.
final class BoatEffects {
    /// The cone, apex at the boat, down her apparent wind (#10): a hatch, faded as core's loss fades, drawn by a shader
    /// (`ConeShader`) from the corners core cuts the shadow from, since its near edge follows her heading. A mask in the
    /// fleet's `ConeLayer`, which draws it at `BoatStyle.coneAlpha`.
    let cone: SKSpriteNode
    let coneShader: ConeShader
    /// The backwind trapezoid on her windward quarter (#298), its hatch fading from her stern to its far edge as
    /// its loss does; hidden for a class with #79's band.
    let backwind: SKSpriteNode
    /// The wake: a string of the track her stern has sailed over the last `BoatStyle.wakeTrailSeconds`, in world
    /// space, so it bends with her turns and the current carries it (the string of #15). Its alpha is the
    /// pressure's (`WakeShape`): a roll miss kills it, a hit flares it.
    let trail = SKShapeNode()

    /// The nodes the scene adds to its effects layer; the cone goes into its `ConeLayer`.
    var nodes: [SKNode] { [backwind, trail] }

    /// How many nodes she draws on the water: her cone, `nodes` and their children (the `-perf` log).
    var nodeCount: Int { nodes.reduce(1) { $0 + 1 + $1.children.count } }

    /// The z's within a boat's effects, each boat a `DrawOrder` slot above the last by seat: every cone under
    /// every backwind under every wake; the streak over its V.
    enum Layer {
        /// The fleet's `ConeLayer`, under every boat's slot.
        static let cones: CGFloat = -0.5
        static let backwind: CGFloat = 0.1, wake: CGFloat = 0.5
    }

    private let ppm: CGFloat
    private let boatClass: BoatClass
    private let hasBackwind: Bool
    /// The heading and apparent wind her cone and backwind were drawn along last frame, trailing hers (`follow`).
    private var followed: (heading: Double, wind: Double)?
    /// The wake drawn last frame, eased towards each frame's (`BoatStyle.wakeEaseRate`).
    private(set) var shape: WakeShape?
    private var flare = FlareTimer()
    /// Where her stern has been, world points, oldest first, each with the race time it was there.
    private var history: [(point: CGPoint, time: Double)] = []
    /// The race time the history last took a sample.
    private var lastSample = -Double.infinity
    private static let sampleInterval = 0.1

    init(seat: Int, boatClass: BoatClass, pointsPerMeter ppm: CGFloat, style: BoatStyle) {
        self.ppm = ppm
        self.boatClass = boatClass
        let art = EffectArt.shared(shadow: boatClass.windShadow, pointsPerMeter: ppm, style: style)

        coneShader = ConeShader(shadow: boatClass.windShadow, pointsPerMeter: ppm, style: style)
        cone = SKSpriteNode(color: .white, size: coneShader.size)
        cone.anchorPoint = coneShader.anchor
        cone.shader = coneShader.shader
        backwind = SKSpriteNode(texture: art.backwind)
        backwind.anchorPoint = art.backwindAnchor
        hasBackwind = art.backwind != nil
        backwind.color = CuePalette.cueWhite.uiColor
        backwind.colorBlendFactor = 1
        backwind.isHidden = !hasBackwind
        trail.strokeColor = CuePalette.cueWhite.uiColor
        trail.lineWidth = CGFloat(style.wakeTrailWidth)
        trail.lineCap = .round
        trail.lineJoin = .round
        trail.alpha = 0

        let slot = DrawOrder.z(seat)
        cone.zPosition = slot
        backwind.zPosition = Layer.backwind + slot
        trail.zPosition = Layer.wake + slot
    }

    /// Draws `boat`'s effects in `pose` at race time `time`. `isFlogging` is her sail's roll-miss flog this frame
    /// (`FlogTimer`): her wake dies while it lasts and comes back with it (#222). `settled` draws the wake straight
    /// at its target, with no easing (a frozen render fixture).
    func update(with boat: Boat, pose: BoatPose, style: BoatStyle, quality: WakeQuality, time: Double, dt: Double,
                settled: Bool, isFlogging: Bool) {
        let point = CGPoint(x: boat.position.x * ppm, y: boat.position.y * ppm)

        // Her shadow and backwind trail her: they turn after her heading and her apparent wind, not with them, as the air
        // she disturbed does (`BoatStyle.shadowFollowSeconds`). Drawn only; core's cone and backwind are cast at once.
        let followed = follow(heading: boat.heading, wind: boat.apparentWind.direction, dt: dt,
                              seconds: style.shadowFollowSeconds, settled: settled)
        let core = ShadowCone(apex: boat.position, apparentWindDirection: followed.wind, heading: followed.heading,
                              windwardSide: boat.tack, shadow: boatClass.windShadow, trueWindAngle: boat.twa,
                              speed: boat.speedThroughWater)

        cone.isHidden = pose.isGhost
        cone.position = point
        cone.zRotation = CGFloat(-(followed.wind + .pi)) // the cone follows her apparent wind (#10)
        coneShader.update(nearA: core.nearA, nearB: core.nearB, ppm: ppm)

        // Her windward side is starboard on starboard tack (`ShadowCone.windward`); it flips at the boom crossing.
        // She casts less of it across a reach, and none while running (`ShadowCone.backwindPresence`).
        let presence = core.backwindPresence
        backwind.isHidden = pose.isGhost || !hasBackwind || presence <= 0
        // Anchored on her stern line, so her speed lengthens and shortens it from there (`backwindScale(speed:)`).
        let stern = boat.position + boat.forward * boatClass.windShadow.sternCorner.y
        backwind.position = CGPoint(x: stern.x * ppm, y: stern.y * ppm)
        backwind.zRotation = CGFloat(-followed.heading)
        backwind.xScale = boat.tack == .starboard ? 1 : -1
        backwind.yScale = CGFloat(boatClass.windShadow.backwindScale(speed: boat.speedThroughWater))
        backwind.alpha = CGFloat(style.coneAlpha * style.backwindShare * presence)

        // A roll miss kills the wake; a hit flares it, fading (#222).
        let flare = flare.flare(roll: pose.roll, time: time, seconds: style.wakeFlareSeconds)
        let level = isFlogging ? 0 : 1 + style.wakeFlareGain * flare
        let target = WakeShape(boat, boatClass: boatClass, style: style, quality: quality).scaled(by: level)
        let shape = settled ? target : (shape ?? target).eased(towards: target, dt: dt, rate: style.wakeEaseRate)
        self.shape = shape

        // Her stern's track, in world space: the current bends it, as it bends the water.
        let sternPoint = CGPoint(x: stern.x * ppm, y: stern.y * ppm)
        let seconds = quality == .short ? style.wakeTrailSeconds * max(style.wakeShortShare, 0) : style.wakeTrailSeconds
        record(sternPoint, boat: boat, time: time, seconds: seconds, ghost: pose.isGhost, settled: settled)

        let path = CGMutablePath()
        if let first = history.first {
            path.move(to: first.point)
            for sample in history.dropFirst() { path.addLine(to: sample.point) }
            path.addLine(to: sternPoint)
        }
        trail.path = path
        trail.lineWidth = CGFloat(style.wakeTrailWidth)
        trail.alpha = CGFloat(shape.alpha) * (pose.isGhost ? CGFloat(style.ghostAlpha) : 1)
        trail.isHidden = history.isEmpty || trail.alpha < 0.005
    }

    /// Moves the heading and apparent wind her shadow is drawn along `dt` race seconds towards hers (exponential, over
    /// `seconds`), the short way round; straight to hers when `settled` (a frozen fixture), with no time constant, or
    /// the first time.
    private func follow(heading: Double, wind: Double, dt: Double, seconds: Double, settled: Bool) -> (heading: Double, wind: Double) {
        guard !settled, seconds > 0, let from = followed else {
            followed = (heading, wind)
            return (heading, wind)
        }
        let k = 1 - exp(-max(dt, 0) / seconds)
        let next = (heading: wrapAngle(from.heading + wrapAngle(heading - from.heading) * k),
                    wind: wrapAngle(from.wind + wrapAngle(wind - from.wind) * k))
        followed = next
        return next
    }

    /// Keeps `history`: a point every `sampleInterval` race seconds while she sails, the old ones dropped after
    /// `seconds`, and a ghost's string drawn in as she stops casting one. Time that runs backwards (an online
    /// re-prediction) starts it over. `settled` (a frozen fixture) lays it straight astern at her speed over the
    /// ground, as if she had always sailed that way.
    private func record(_ point: CGPoint, boat: Boat, time: Double, seconds: Double, ghost: Bool, settled: Bool) {
        if settled {
            let astern = boat.velocityOverGround * -1
            let steps = max(Int(seconds / Self.sampleInterval), 0)
            history = (1...max(steps, 1)).reversed().map { step in
                let back = Double(step) * Self.sampleInterval
                return (point: CGPoint(x: point.x + CGFloat(astern.x * back) * ppm,
                                       y: point.y + CGFloat(astern.y * back) * ppm), time: time - back)
            }
            lastSample = time
            return
        }
        if let newest = history.last?.time, newest > time { history.removeAll() }
        if lastSample > time { lastSample = -.infinity }
        if time - lastSample >= Self.sampleInterval {
            lastSample = time
            if ghost {
                if !history.isEmpty { history.removeFirst() }
            } else {
                history.append((point: point, time: time))
            }
        }
        history.removeAll { time - $0.time > seconds }
    }
}

/// The fleet's wind-shadow cones as one layer (#15: hatched cones, white to read on dark water). Each boat's cone hatch is a
/// mask here, and one white sheet shows through their union at `BoatStyle.coneAlpha`: so a cone's lines are
/// just readable on the water, and where ten cones overlap no line is darker than one cone's, only the hatch
/// denser. The mask and the sheet sit at the layer's origin, so each cone lands where its own transform puts it.
final class ConeLayer: SKCropNode {
    /// The sheet the cones show: big enough to cover any course.
    let sheet = SKSpriteNode(color: CuePalette.cueWhite.uiColor, size: CGSize(width: 400_000, height: 400_000))
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
    /// The backwind's hatched trapezoid (`ShadowShapes.backwindLocal`) in the boat's frame on starboard tack, the
    /// centre of her stern line at its anchor (it scales with her speed from there); nil for a class with #79's band.
    let backwind: SKTexture?
    let backwindAnchor: CGPoint
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
                               shadow.sternCorner.x, shadow.sternCorner.y, shadow.backwindSternSlant ? 1 : 0],
                      ppm: ppm, hatch: [style.hatchSpacing, style.hatchLineWidth, style.backwindFeather])
        if let art = cache[key] { return art }
        let art = EffectArt(shadow: shadow, ppm: ppm, style: style)
        cache[key] = art
        return art
    }

    private init(shadow: BoatClass.WindShadow, ppm: CGFloat, style: BoatStyle) {
        let spacing = CGFloat(max(style.hatchSpacing, 1)), width = CGFloat(max(style.hatchLineWidth, 0.25))
        func points(_ corners: [Vec2]) -> [CGPoint] { corners.map { CGPoint(x: $0.x * ppm, y: $0.y * ppm) } }

        if let corners = ShadowShapes.backwindLocal(shadow) {
            let backwindPoints = points(corners)
            // Taking in the centre of her stern line, so the anchor is inside the texture.
            let sternCentre = CGPoint(x: 0, y: shadow.sternCorner.y * ppm)
            // Room round it for the soft edge, which reaches that far out.
            let feather = CGFloat(max(style.backwindFeather, 0)), margin = (feather * 3).rounded(.up)
            let bounds = Self.bounds(of: backwindPoints + [sternCentre]).insetBy(dx: -margin, dy: -margin)
            // A light fill under the hatch makes the trapezoid read as a shape, not a patch of lines: the fade only
            // thins it (`backwindFadeFloor`), so its far edge stays seen.
            backwind = Self.hatch(backwindPoints, bounds: bounds, spacing: spacing, width: width, fill: 0.22,
                                  feather: feather) { cg in
                Self.fadeBackwind(cg, shadow: shadow, ppm: ppm, margin: margin)
            }
            backwindAnchor = CGPoint(x: -bounds.minX / bounds.width, y: (sternCentre.y - bounds.minY) / bounds.height)
        } else {
            backwind = nil
            backwindAnchor = CGPoint(x: 0.5, y: 0.5)
        }
    }

    private static func bounds(of points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        let minX = xs.min() ?? 0, minY = ys.min() ?? 0
        return CGRect(x: minX, y: minY, width: max((xs.max() ?? 0) - minX, 1), height: max((ys.max() ?? 0) - minY, 1))
    }


    /// Diagonal lines `spacing` apart and `width` wide over `outline` (#15), with a light `fill` under them. With no
    /// `feather` the hatch is clipped to `outline`, hard edged; with one it is not, and a copy of the outline blurred by
    /// `feather` points multiplies it (`featherMask`), so the zone's edge fades out over a few points either side of
    /// where core's zone ends. `fade`, if any, then fades it (drawing with `.destinationIn`).
    private static func hatch(_ outline: [CGPoint], bounds: CGRect, spacing: CGFloat, width: CGFloat,
                              fill: CGFloat = 0, feather: CGFloat = 0, fade: ((CGContext) -> Void)? = nil) -> SKTexture {
        let mask = feather > 0 ? featherMask(outline, bounds: bounds, radius: feather) : nil
        return SpriteArt.texture(bounds: bounds) { cg in
            cg.saveGState()
            if mask == nil {
                let path = CGMutablePath()
                path.addLines(between: outline)
                path.closeSubpath()
                cg.addPath(path)
                cg.clip()
            }
            if fill > 0 {
                cg.setFillColor(UIColor(white: 1, alpha: fill).cgColor)
                cg.fill(bounds)
            }
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
            if let mask {
                cg.setBlendMode(.destinationIn)
                cg.draw(mask, in: bounds)
            }
            if let fade {
                cg.setBlendMode(.destinationIn)
                fade(cg)
            }
        }
    }

    /// `outline` filled white on clear and blurred (Gaussian, `radius` points), over `bounds`, in the frame
    /// `SpriteArt.texture` draws in: the soft-edged alpha a hatch is multiplied by. Nil if the blur can't be made.
    private static func featherMask(_ outline: [CGPoint], bounds: CGRect, radius: CGFloat) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: bounds.size, format: format).image { context in
            let cg = context.cgContext
            cg.translateBy(x: -bounds.minX, y: bounds.maxY)
            cg.scaleBy(x: 1, y: -1)
            let path = CGMutablePath()
            path.addLines(between: outline)
            path.closeSubpath()
            cg.addPath(path)
            cg.setFillColor(UIColor.white.cgColor)
            cg.fillPath()
        }
        guard let input = CIImage(image: image),
              let blur = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputImageKey: input.clampedToExtent(),
                                                                       kCIInputRadiusKey: radius * format.scale]),
              let output = blur.outputImage?.cropped(to: input.extent) else { return nil }
        return CIContext().createCGImage(output, from: input.extent)
    }

    /// How much of the backwind's hatch is left at its far edge: core's loss fades to nothing there, but drawn it
    /// stops at a share, so the zone's whole shape stays readable on the water.
    private static let backwindFadeFloor: CGFloat = 0.35

    /// Fades the backwind's hatch as core's loss fades (`ShadowCone`'s backwind factor, #298): full along its stern
    /// edge, straight down to `backwindFadeFloor` at its far edge, each at the span `BoatClass.WindShadow.backwindSpan(out:)`
    /// gives where it is (one edge slants, the far one or the stern one). Column by column, a texel wide, in the art's
    /// frame (starboard tack).
    private static func fadeBackwind(_ cg: CGContext, shadow: BoatClass.WindShadow, ppm: CGFloat, margin: CGFloat) {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let gradient = CGGradient(colorsSpace: space, colors: [UIColor.white.cgColor,
                                                                     UIColor(white: 1, alpha: Self.backwindFadeFloor).cgColor] as CFArray,
                                        locations: [0, 1]) else { return }
        let stern = CGFloat(shadow.sternCorner.y) * ppm, x0 = CGFloat(shadow.sternCorner.x) * ppm
        let width = CGFloat(shadow.backwindWidth) * ppm
        let step: CGFloat = 1.0 / 3
        // Unblended strip edges, so the strips share each texel out exactly once.
        cg.setShouldAntialias(false)
        var x: CGFloat = -step - margin
        while x < width + step + margin {
            let out = Double((x + step / 2) / width).clamped(to: 0...1) * shadow.backwindWidth
            guard let span = shadow.backwindSpan(out: out) else { break }
            let top = stern - CGFloat(span.start) * ppm, bottom = stern - CGFloat(span.end) * ppm
            cg.saveGState()
            cg.clip(to: CGRect(x: x0 + x, y: bottom - margin - 2, width: step, height: top - bottom + 2 * margin + 4))
            cg.drawLinearGradient(gradient, start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: bottom),
                                  options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            cg.restoreGState()
            x += step
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
