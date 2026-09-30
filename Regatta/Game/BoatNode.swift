import SpriteKit
import RegattaCore

/// Draws one boat (#117) from her pose (`BoatPose`): her drop shadow, hull, outline and sail, your boat's glow
/// under her hull, plus a wake and a wind-shadow cone that live in the world layer beneath the fleet. No name and
/// no badge: boat names are never shown on the water (#15), and penalties are #123's and #124's.
final class BoatNode: SKNode {
    let wake = SKShapeNode()
    let shadowCone: SKSpriteNode

    private let body = SKNode()
    /// What heel narrows: the drop shadow, glow, hull and outline, never the sail (`xScale` would warp it).
    private let hullGroup = SKNode()
    private let heelShadow: SKSpriteNode
    private let glow: SKSpriteNode?
    private let sail: SKSpriteNode
    private let ppm: CGFloat
    private let beam: CGFloat
    /// Each boat's flutter swings on its own phase, so a flapping fleet doesn't flap in step. Presentation only:
    /// the pose itself is the same for every boat.
    private let flutterPhase: Double
    private var sailAngle: CGFloat = 0
    /// When the current roll miss's flog began (race seconds), while she has one (`BoatPose.RollCue.flog`).
    private var flogStart: Double?
    private var wakePoints: [CGPoint] = []
    private var wakeTimer = 0.0

    /// The z's a boat's parts draw at, each boat a `DrawOrder` slot above the last by seat: in the effects layer
    /// every shadow cone under every wake, and in the fleet's every drop shadow under your glow, the glow under
    /// every hull, every hull under its outline and every outline under every sail. Your boat draws over all of
    /// the fleet's.
    private enum Layer {
        static let cone: CGFloat = 0, wake: CGFloat = 0.5
        static let fleet: CGFloat = 5, mine: CGFloat = 10
        static let heelShadow: CGFloat = 0, glow: CGFloat = 0.1, hull: CGFloat = 0.2, outline: CGFloat = 0.3, sail: CGFloat = 1
    }

    /// `isMine` marks your boat (the driver's `myBoatIndex`): a soft white glow under her hull, and drawn on top.
    /// Every hull is the same size and every hull has the same outline.
    init(boat: Boat, isMine: Bool, color: UIColor, boatClass: BoatClass, pointsPerMeter ppm: CGFloat) {
        self.ppm = ppm
        beam = CGFloat(boatClass.hull.beam) * ppm
        flutterPhase = Double(boat.id) * 2.39
        let length = CGFloat(boatClass.hull.length) * ppm

        // Hulls, sails and shadow cones are sprites sharing a few textures, per class and scale, so SpriteKit
        // can batch the whole fleet into a handful of draw calls.
        let art = BoatArt.shared(boatClass: boatClass, pointsPerMeter: ppm)
        heelShadow = SKSpriteNode(texture: art.hull)
        heelShadow.color = .black
        heelShadow.colorBlendFactor = 1
        heelShadow.alpha = 0
        heelShadow.zPosition = Layer.heelShadow
        let hull = SKSpriteNode(texture: art.hull)
        hull.color = color
        hull.colorBlendFactor = 1
        hull.zPosition = Layer.hull
        // Its own sprite, tinted the outline token: in the hull's texture the tint would turn it her colour.
        let outline = SKSpriteNode(texture: art.outline)
        outline.color = CuePalette.hullOutline.uiColor
        outline.colorBlendFactor = 1
        outline.zPosition = Layer.outline
        glow = isMine ? SKSpriteNode(texture: art.glow) : nil
        glow?.zPosition = Layer.glow

        sail = SKSpriteNode(texture: art.sail)
        sail.anchorPoint = art.sailAnchor
        sail.position = CGPoint(x: 0, y: length * 0.16)
        sail.zPosition = Layer.sail

        shadowCone = SKSpriteNode(texture: art.cone)
        shadowCone.anchorPoint = CGPoint(x: 0.5, y: 0)
        shadowCone.color = .black
        shadowCone.colorBlendFactor = 1
        shadowCone.alpha = 0.05

        super.init()

        hullGroup.addChild(heelShadow)
        if let glow { hullGroup.addChild(glow) }
        hullGroup.addChild(hull)
        hullGroup.addChild(outline)
        body.addChild(hullGroup)
        body.addChild(sail)
        addChild(body)

        wake.strokeColor = UIColor.white.withAlphaComponent(0.22)
        wake.lineWidth = 1.5
        wake.lineCap = .round
        wake.lineJoin = .round

        // A z each, from the seat (`DrawOrder`): the start row (#85) puts the fleet's cones, wakes, hulls and
        // sails over each other.
        let seat = DrawOrder.z(boat.id)
        shadowCone.zPosition = Layer.cone + seat
        wake.zPosition = Layer.wake + seat
        zPosition = (isMine ? Layer.mine : Layer.fleet) + seat
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Draws `boat` in `pose` at race time `time` (seconds; every flutter swings on it, never the wall clock).
    /// `settled` trims the sail straight to its target rather than easing it there (a frozen render fixture).
    func update(with boat: Boat, pose: BoatPose, style: BoatStyle, time: Double, dt: Double, settled: Bool = false) {
        let point = CGPoint(x: boat.position.x * ppm, y: boat.position.y * ppm)
        position = point
        body.zRotation = CGFloat(-boat.heading)

        updateHeel(pose, style: style)
        updateSail(pose, style: style, time: time, dt: dt, settled: settled)
        updateWake(point, dt: dt, active: !pose.isGhost)

        shadowCone.isHidden = pose.isGhost
        shadowCone.position = point
        shadowCone.zRotation = CGFloat(-(boat.apparentWind.direction + .pi)) // the cone follows her apparent wind (#10)

        glow?.alpha = CGFloat(style.glowAlpha)
        alpha = pose.isGhost ? CGFloat(style.ghostAlpha) : 1
    }

    /// Heel (#22): the hull drawn narrower and a drop shadow offset to leeward, the boom's side.
    private func updateHeel(_ pose: BoatPose, style: BoatStyle) {
        let heel = CGFloat(pose.heel)
        let leeward: CGFloat = pose.sailSide == .port ? -1 : 1
        hullGroup.xScale = 1 - CGFloat(style.heelNarrowing) * heel
        heelShadow.position = CGPoint(x: leeward * heel * CGFloat(style.heelShadowOffset) * beam, y: 0)
        heelShadow.alpha = heel * CGFloat(style.heelShadowAlpha)
    }

    private func updateSail(_ pose: BoatPose, style: BoatStyle, time: Double, dt: Double, settled: Bool) {
        // The sail sits on the boom side, to leeward except by the lee, eased out as far as the pose says.
        let side: CGFloat = pose.sailSide == .port ? -1 : 1
        let target = CGFloat(pose.sailTrim) * side

        if pose.roll == .flog {
            if flogStart == nil { flogStart = time }
        } else {
            flogStart = nil
        }
        let isFlogging = flogStart.map { time - $0 < style.flogSeconds } ?? false

        // A roll hit snaps the sail full at once; otherwise it eases there.
        let snaps = settled || pose.roll == .snap
        sailAngle += (target - sailAngle) * (snaps ? 1 : min(1, CGFloat(dt) * 8))

        let swing = sin(time * 22 + flutterPhase)
        var amplitude = deg2rad(style.flutterDegrees) * pose.flutter
        var flap = pose.flutter
        if isFlogging {
            amplitude = max(amplitude, deg2rad(style.flogDegrees))
            flap = 1
        }
        sail.zRotation = sailAngle + CGFloat(swing * amplitude)
        // A flapping sail loses its belly; a ghost's hangs limp.
        let belly = pose.isGhost ? 0.35 : 1 - 0.55 * flap * (0.5 + 0.5 * sin(time * 31 + flutterPhase))
        sail.xScale = side * CGFloat(belly)
    }

    private func updateWake(_ point: CGPoint, dt: Double, active: Bool) {
        wakeTimer -= dt
        guard wakeTimer <= 0 else { return }
        wakeTimer = 0.12
        if active {
            wakePoints.append(point)
            if wakePoints.count > 28 { wakePoints.removeFirst() }
        } else if !wakePoints.isEmpty {
            wakePoints.removeFirst()
        }
        let path = CGMutablePath()
        if let first = wakePoints.first {
            path.move(to: first)
            for p in wakePoints.dropFirst() { path.addLine(to: p) }
            path.addLine(to: point)
        }
        wake.path = path
    }

}

/// Pre-rendered boat textures, drawn in white so each sprite can be tinted.
private struct BoatArt {
    /// The hull, from the class's outline; the drop shadow draws it too, tinted black.
    let hull: SKTexture
    /// Every hull's thin outline, drawn over it in `CuePalette.hullOutline`.
    let outline: SKTexture
    /// Your boat's soft glow, drawn under her hull.
    let glow: SKTexture
    let sail: SKTexture
    let sailAnchor: CGPoint
    let cone: SKTexture

    /// What the art is drawn from: the class's hull and wind shadow, and the scale.
    private struct Key: Hashable {
        var outline: [Double]
        var length: Double
        var beam: Double
        var cone: [Double]
        var ppm: CGFloat
    }

    private static var cache: [Key: BoatArt] = [:]

    /// Built once per class and scale: a boat never rebuilds a texture as she sails, and the tuning panel can
    /// swap the class in one process.
    static func shared(boatClass: BoatClass, pointsPerMeter ppm: CGFloat) -> BoatArt {
        let hull = boatClass.hull, shadow = boatClass.windShadow
        let key = Key(outline: hull.outline.flatMap { [$0.x, $0.y] }, length: hull.length, beam: hull.beam,
                      cone: [shadow.coneLength, shadow.coneWidthAtBoat, shadow.coneWidthAtEnd], ppm: ppm)
        if let art = cache[key] { return art }
        let art = BoatArt(boatClass: boatClass, ppm: ppm)
        cache[key] = art
        return art
    }

    /// Your glow's blur, points: soft, with no hard edge that would read as a ring (#15).
    private static let glowBlur: CGFloat = 5

    private init(boatClass: BoatClass, ppm: CGFloat) {
        let length = CGFloat(boatClass.hull.length) * ppm
        let beam = CGFloat(boatClass.hull.beam) * ppm
        let path = BoatArt.hullPath(boatClass.hull, ppm: ppm)
        // Centred on the hull's origin, as every sprite is anchored, so hull, outline and glow line up on the boat.
        let box = path.boundingBoxOfPath
        let halfWidth = max(abs(box.minX), abs(box.maxX)) + 2, halfHeight = max(abs(box.minY), abs(box.maxY)) + 2
        let bounds = CGRect(x: -halfWidth, y: -halfHeight, width: halfWidth * 2, height: halfHeight * 2)
        hull = BoatArt.hullTexture(path, bounds: bounds, length: length, beam: beam)
        outline = BoatArt.texture(bounds: bounds) { cg in
            BoatArt.strokeInside(path, width: 1, color: .white, in: cg)
        }
        glow = BoatArt.glowTexture(path, bounds: bounds)
        (sail, sailAnchor) = BoatArt.sailTexture(length: length * 0.62, bulge: beam * 0.45, mastRadius: max(1.5, beam * 0.1))
        cone = BoatArt.coneTexture(boatClass.windShadow, ppm: ppm)
    }

    /// Renders `draw` into a texture whose coordinate space is y-up with `bounds`
    /// mapped onto the image, matching SpriteKit.
    private static func texture(bounds: CGRect, scale: CGFloat = 3, draw: (CGContext) -> Void) -> SKTexture {
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

    /// The class's hull outline (`BoatClass.Hull.outline`: metres, x to starboard, y to the bow) in points, bow
    /// up, its corners rounded: the shoulders into long curves, the bow and transom only a little.
    static func hullPath(_ hull: BoatClass.Hull, ppm: CGFloat) -> CGPath {
        let points = hull.outline.map { CGPoint(x: CGFloat($0.x) * ppm, y: CGFloat($0.y) * ppm) }
        let path = CGMutablePath()
        guard points.count >= 3 else {
            let l = CGFloat(hull.length) * ppm, b = CGFloat(hull.beam) * ppm
            path.addEllipse(in: CGRect(x: -b / 2, y: -l / 2, width: b, height: l))
            return path
        }
        let beam = CGFloat(hull.beam) * ppm
        let n = points.count
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
        path.move(to: mid(points[n - 1], points[0]))
        for i in 0..<n {
            let corner = points[i], previous = points[(i + n - 1) % n], next = points[(i + 1) % n]
            let u = CGVector(dx: previous.x - corner.x, dy: previous.y - corner.y)
            let v = CGVector(dx: next.x - corner.x, dy: next.y - corner.y)
            let cosine = (u.dx * v.dx + u.dy * v.dy) / max(distance(previous, corner) * distance(next, corner), 1e-6)
            let angle = acos(cosine.clamped(to: -1...1))
            // The arc meets each side at most this far from the corner: half the shorter side, so arcs never cross.
            let reach = 0.45 * min(distance(previous, corner), distance(next, corner))
            let fits = reach * tan(angle / 2)
            let radius = angle > .pi * 0.75 ? fits : min(beam * 0.08, fits)
            path.addArc(tangent1End: corner, tangent2End: mid(corner, next), radius: radius)
        }
        path.closeSubpath()
        return path
    }

    /// Strokes `path`'s rim `width` wide inside its edge, never outside it: the path is the silhouette.
    private static func strokeInside(_ path: CGPath, width: CGFloat, color: UIColor, in cg: CGContext) {
        cg.saveGState()
        cg.addPath(path)
        cg.clip()
        cg.addPath(path)
        cg.setStrokeColor(color.cgColor)
        cg.setLineWidth(width * 2)
        cg.strokePath()
        cg.restoreGState()
    }

    private static func hullTexture(_ path: CGPath, bounds: CGRect, length l: CGFloat, beam b: CGFloat) -> SKTexture {
        texture(bounds: bounds) { cg in
            cg.addPath(path)
            cg.setFillColor(UIColor.white.cgColor)
            cg.fillPath()
            // Cockpit, tinted darker than the deck by the sprite colour.
            let cockpit = CGPath(roundedRect: CGRect(x: -b * 0.26, y: -l * 0.42, width: b * 0.52, height: l * 0.36),
                                 cornerWidth: b * 0.2, cornerHeight: b * 0.2, transform: nil)
            cg.addPath(cockpit)
            cg.setFillColor(UIColor(white: 0.7, alpha: 1).cgColor)
            cg.fillPath()
        }
    }

    /// A soft white blur of the hull's silhouette, wider than it: under the hull only its halo shows.
    private static func glowTexture(_ path: CGPath, bounds: CGRect) -> SKTexture {
        // Same centre as the hull's bounds, so the two sprites line up.
        texture(bounds: bounds.insetBy(dx: -glowBlur * 2, dy: -glowBlur * 2)) { cg in
            cg.setShadow(offset: .zero, blur: glowBlur * 2, color: UIColor.white.cgColor)
            cg.addPath(path)
            cg.setFillColor(UIColor.white.cgColor)
            cg.fillPath()
            cg.setShadow(offset: .zero, blur: glowBlur, color: UIColor.white.cgColor)
            cg.addPath(path)
            cg.fillPath()
        }
    }

    /// A sail running aft from the mast along -y and bellied toward +x, with the
    /// mast drawn on top. Returns the anchor that puts the mast at the pivot.
    private static func sailTexture(length: CGFloat, bulge: CGFloat, mastRadius: CGFloat) -> (SKTexture, CGPoint) {
        let bounds = CGRect(x: -mastRadius - 1, y: -length - 2, width: bulge + mastRadius + 4, height: length + mastRadius + 3)
        let sail = CGMutablePath()
        sail.move(to: .zero)
        sail.addQuadCurve(to: CGPoint(x: 0, y: -length), control: CGPoint(x: bulge * 2, y: -length * 0.45))
        sail.closeSubpath()
        let texture = texture(bounds: bounds) { cg in
            cg.addPath(sail)
            cg.setFillColor(UIColor.white.withAlphaComponent(0.88).cgColor)
            cg.fillPath()
            cg.addPath(sail)
            cg.setStrokeColor(UIColor.white.cgColor)
            cg.setLineWidth(1)
            cg.strokePath()
            cg.setFillColor(UIColor(white: 0.2, alpha: 1).cgColor)
            cg.fillEllipse(in: CGRect(x: -mastRadius, y: -mastRadius, width: mastRadius * 2, height: mastRadius * 2))
        }
        let anchor = CGPoint(x: -bounds.minX / bounds.width, y: -bounds.minY / bounds.height)
        return (texture, anchor)
    }

    /// The wind-shadow cone, starting at the boat and widening downwind along +y.
    private static func coneTexture(_ shadow: BoatClass.WindShadow, ppm: CGFloat) -> SKTexture {
        let length = CGFloat(shadow.coneLength) * ppm
        let halfStart = CGFloat(shadow.coneWidthAtBoat / 2) * ppm
        let halfEnd = CGFloat(shadow.coneWidthAtEnd / 2) * ppm
        let bounds = CGRect(x: -halfEnd, y: 0, width: halfEnd * 2, height: length)
        return texture(bounds: bounds, scale: 1) { cg in
            cg.move(to: CGPoint(x: -halfStart, y: 0))
            cg.addLine(to: CGPoint(x: halfStart, y: 0))
            cg.addLine(to: CGPoint(x: halfEnd, y: length))
            cg.addLine(to: CGPoint(x: -halfEnd, y: length))
            cg.closePath()
            cg.setFillColor(UIColor.white.cgColor)
            cg.fillPath()
        }
    }
}
