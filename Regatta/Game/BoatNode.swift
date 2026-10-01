import SpriteKit
import RegattaCore

/// Draws one boat (#117) from her pose (`BoatPose`): her drop shadow, hull, outline and sail, your boat's glow
/// under her hull, plus her wake, wind-shadow cone and backwind (`BoatEffects`, #121) that live in the world's
/// effects layer beneath the fleet. No name and no badge: boat names are never shown on the water (#15), and
/// penalties are #123's and #124's.
final class BoatNode: SKNode {
    /// Her wake, cone and backwind: the scene adds `effects.nodes` to its effects layer and her cone to its
    /// `ConeLayer`.
    let effects: BoatEffects

    /// A ghost fades as one flat image (#30): her hull, outline and sail composited first, then faded together,
    /// so where they overlap she reads no darker than anywhere else. Its effect is on for ghosts only; a live boat
    /// draws straight through it.
    let fade = SKEffectNode()
    private let body = SKNode()
    /// What heel narrows: the drop shadow, glow, hull and outline, never the sail (`xScale` would warp it).
    private let hullGroup = SKNode()
    private let heelShadow: SKSpriteNode
    private let glow: SKSpriteNode?
    private let sail: SKSpriteNode
    private let ppm: CGFloat
    private let beam: CGFloat
    /// Her seat: each boat's flutter swings on its own phase (`BoatStyle.flutterPhaseStep`), so a flapping fleet
    /// doesn't flap in step. Presentation only: the pose itself is the same for every boat.
    private let seat: Int
    private var sailAngle: CGFloat = 0
    /// The current roll miss's flog (`BoatPose.RollCue.flog`), timed in race seconds.
    private var flog = FlogTimer()
    /// Your roll ring (#222): a sprite on your boat only, nil for the rest of the fleet.
    private let ring: SKSpriteNode?
    private let brokenRing: SKTexture
    private let solidRing: SKTexture
    private var ringTimer = RollRingTimer()
    private let rollWindow: Double?
    private let length: CGFloat

    /// The z's a boat's parts draw at, each boat a `DrawOrder` slot above the last by seat: in the fleet's layer
    /// every drop shadow under your glow, the glow under every hull, every hull under its outline and every
    /// outline under every sail. Your boat draws over all of the fleet's. (The effects layer's are `BoatEffects`'.)
    private enum Layer {
        static let fleet: CGFloat = 5, mine: CGFloat = 10
        static let heelShadow: CGFloat = 0, glow: CGFloat = 0.1, hull: CGFloat = 0.2, outline: CGFloat = 0.3, sail: CGFloat = 1
        static let ring: CGFloat = 2
    }

    /// `isMine` marks your boat (the driver's `myBoatIndex`): a soft white glow under her hull, and drawn on top.
    /// Every hull is the same size and every hull has the same outline. `style`'s baked-in art values (glow blur,
    /// outline width, hatch) are drawn into the textures here.
    init(boat: Boat, isMine: Bool, color: UIColor, boatClass: BoatClass, pointsPerMeter ppm: CGFloat,
         style: BoatStyle = .standard) {
        self.ppm = ppm
        beam = CGFloat(boatClass.hull.beam) * ppm
        seat = boat.id
        let length = CGFloat(boatClass.hull.length) * ppm
        self.length = length
        rollWindow = boatClass.rollTack?.window

        // Hulls and sails are sprites sharing a few textures, per class and scale, so SpriteKit can batch the
        // whole fleet into a handful of draw calls; so are the effects.
        let art = BoatArt.shared(boatClass: boatClass, pointsPerMeter: ppm, style: style)
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

        solidRing = RollRingArt.texture(broken: false)
        brokenRing = RollRingArt.texture(broken: true)
        let rollRing = isMine && boatClass.rollTack != nil ? SKSpriteNode(texture: solidRing) : nil
        rollRing?.color = CuePalette.cueWhite.uiColor
        rollRing?.colorBlendFactor = 1
        rollRing?.zPosition = Layer.ring
        rollRing?.isHidden = true
        ring = rollRing

        effects = BoatEffects(seat: boat.id, boatClass: boatClass, pointsPerMeter: ppm, style: style)
        fade.shouldEnableEffects = false
        fade.shouldRasterize = false

        super.init()

        hullGroup.addChild(heelShadow)
        if let glow { hullGroup.addChild(glow) }
        hullGroup.addChild(hull)
        hullGroup.addChild(outline)
        body.addChild(hullGroup)
        body.addChild(sail)
        fade.addChild(body)
        addChild(fade)
        if let ring { addChild(ring) }

        // A z each, from the seat (`DrawOrder`): the start row (#85) puts the fleet's hulls and sails over each
        // other.
        let seat = DrawOrder.z(boat.id)
        zPosition = (isMine ? Layer.mine : Layer.fleet) + seat
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Draws `boat` in `pose` at race time `time` (seconds; every flutter swings on it, never the wall clock).
    /// `settled` trims the sail straight to its target rather than easing it there (a frozen render fixture).
    /// `wakeQuality` is the wake's tier (#127).
    func update(with boat: Boat, pose: BoatPose, style: BoatStyle, wakeQuality: WakeQuality = .full, time: Double,
                dt: Double, settled: Bool = false) {
        position = CGPoint(x: boat.position.x * ppm, y: boat.position.y * ppm)
        body.zRotation = CGFloat(-boat.heading)

        updateHeel(pose, style: style)
        let isFlogging = updateSail(pose, style: style, time: time, dt: dt, settled: settled)
        effects.update(with: boat, pose: pose, style: style, quality: wakeQuality, time: time, dt: dt,
                       settled: settled, isFlogging: isFlogging)

        updateRing(boat, style: style, time: time)

        glow?.alpha = CGFloat(style.glowAlpha)
        fade.shouldEnableEffects = pose.isGhost
        fade.alpha = pose.isGhost ? CGFloat(style.ghostAlpha) : 1
    }

    /// Your roll ring (#222): none on the rest of the fleet. It stays upright and unscaled by heel, centred on the boat.
    private func updateRing(_ boat: Boat, style: BoatStyle, time: Double) {
        guard let ring else { return }
        guard let state = ringTimer.ring(for: boat, window: rollWindow, time: time, seconds: style.rollRingSeconds) else {
            ring.isHidden = true
            return
        }
        let texture = state.isBroken ? brokenRing : solidRing
        if ring.texture !== texture { ring.texture = texture }
        let diameter = 2 * length * CGFloat(style.rollRingHulls * state.radiusShare)
        ring.size = CGSize(width: diameter, height: diameter)
        ring.alpha = CGFloat(style.rollRingAlpha * state.alphaShare)
        ring.isHidden = false
    }

    /// Heel (#22): the hull drawn narrower and a drop shadow offset to leeward (the boom's side, except by the lee).
    private func updateHeel(_ pose: BoatPose, style: BoatStyle) {
        let heel = CGFloat(pose.heel)
        let leeward: CGFloat = pose.leeSide == .port ? -1 : 1
        hullGroup.xScale = 1 - CGFloat(style.heelNarrowing) * heel
        heelShadow.position = CGPoint(x: leeward * heel * CGFloat(style.heelShadowOffset) * beam, y: 0)
        heelShadow.alpha = heel * CGFloat(style.heelShadowAlpha)
    }

    /// Returns whether a roll miss's flog is on (the wake dies with it, #222).
    @discardableResult
    private func updateSail(_ pose: BoatPose, style: BoatStyle, time: Double, dt: Double, settled: Bool) -> Bool {
        // The sail sits on the boom side, to leeward except by the lee, eased out as far as the pose says.
        let side: CGFloat = pose.sailSide == .port ? -1 : 1
        let target = CGFloat(pose.sailTrim) * side

        let isFlogging = flog.isFlogging(roll: pose.roll, time: time, seconds: style.flogSeconds)

        // A roll hit snaps the sail full at once; otherwise it eases there.
        let snaps = settled || pose.roll == .snap
        sailAngle += (target - sailAngle) * (snaps ? 1 : min(1, CGFloat(dt) * 8))

        let flutterPhase = Double(seat) * style.flutterPhaseStep
        let swing = sin(time * style.flutterSwingRate + flutterPhase)
        var amplitude = deg2rad(style.flutterDegrees) * pose.flutter
        var flap = pose.flutter
        if isFlogging {
            amplitude = max(amplitude, deg2rad(style.flogDegrees))
            flap = 1
        }
        // Pinched (#219): the leading edge lifts, a small quick shiver at the luff on top of any flutter.
        let luff = sin(time * 37 + flutterPhase) * deg2rad(style.pinchLuffDegrees) * pose.luffLift
        sail.zRotation = sailAngle + CGFloat(swing * amplitude + luff)
        // A flapping sail loses its belly; a ghost's hangs limp. Pinched it flattens, footed it fills (#219).
        let belly = pose.isGhost
            ? style.ghostSailBelly
            : pose.sailFullness
                * (1 - style.flapBellyLoss * flap * (0.5 + 0.5 * sin(time * style.flapBellyRate + flutterPhase)))
        sail.xScale = side * CGFloat(belly)
        return isFlogging
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

    /// What the art is drawn from: the class's hull, the scale, and the glow's blur and outline's width.
    private struct Key: Hashable {
        var outline: [Double]
        var length: Double
        var beam: Double
        var ppm: CGFloat
        var glowBlur: Double
        var outlineWidth: Double
    }

    private static var cache: [Key: BoatArt] = [:]

    /// Built once per class and scale: a boat never rebuilds a texture as she sails, and the tuning panel can
    /// swap the class in one process.
    static func shared(boatClass: BoatClass, pointsPerMeter ppm: CGFloat, style: BoatStyle) -> BoatArt {
        let hull = boatClass.hull
        let key = Key(outline: hull.outline.flatMap { [$0.x, $0.y] }, length: hull.length, beam: hull.beam, ppm: ppm,
                      glowBlur: style.glowBlur, outlineWidth: style.outlineWidth)
        if let art = cache[key] { return art }
        let art = BoatArt(boatClass: boatClass, ppm: ppm, glowBlur: CGFloat(style.glowBlur),
                          outlineWidth: CGFloat(style.outlineWidth))
        cache[key] = art
        return art
    }

    private init(boatClass: BoatClass, ppm: CGFloat, glowBlur: CGFloat, outlineWidth: CGFloat) {
        let length = CGFloat(boatClass.hull.length) * ppm
        let beam = CGFloat(boatClass.hull.beam) * ppm
        let path = BoatArt.hullPath(boatClass.hull, ppm: ppm)
        // Centred on the hull's origin, as every sprite is anchored, so hull, outline and glow line up on the boat.
        let box = path.boundingBoxOfPath
        let halfWidth = max(abs(box.minX), abs(box.maxX)) + 2, halfHeight = max(abs(box.minY), abs(box.maxY)) + 2
        let bounds = CGRect(x: -halfWidth, y: -halfHeight, width: halfWidth * 2, height: halfHeight * 2)
        hull = BoatArt.hullTexture(path, bounds: bounds, length: length, beam: beam)
        outline = BoatArt.texture(bounds: bounds) { cg in
            BoatArt.strokeInside(path, width: outlineWidth, color: .white, in: cg)
        }
        glow = BoatArt.glowTexture(path, bounds: bounds, blur: glowBlur)
        (sail, sailAnchor) = BoatArt.sailTexture(length: length * 0.62, bulge: beam * 0.45, mastRadius: max(1.5, beam * 0.1))
    }

    private static func texture(bounds: CGRect, scale: CGFloat = 3, draw: (CGContext) -> Void) -> SKTexture {
        SpriteArt.texture(bounds: bounds, scale: scale, draw: draw)
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

    /// A soft white blur of the hull's silhouette, wider than it: under the hull only its halo shows. `glowBlur`,
    /// points: soft, with no hard edge that would read as a ring (#15).
    private static func glowTexture(_ path: CGPath, bounds: CGRect, blur glowBlur: CGFloat) -> SKTexture {
        // The player glow's token (docs/palette.md).
        let white = CuePalette.cueWhite.uiColor.cgColor
        // Same centre as the hull's bounds, so the two sprites line up.
        return texture(bounds: bounds.insetBy(dx: -glowBlur * 2, dy: -glowBlur * 2)) { cg in
            cg.setShadow(offset: .zero, blur: glowBlur * 2, color: white)
            cg.addPath(path)
            cg.setFillColor(white)
            cg.fillPath()
            cg.setShadow(offset: .zero, blur: glowBlur, color: white)
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
}

/// The roll ring's two textures (#222), drawn in white on a 128 point square and sized per frame: a solid ring,
/// and the same ring broken into dashes.
private enum RollRingArt {
    static func texture(broken: Bool) -> SKTexture {
        let bounds = CGRect(x: -64, y: -64, width: 128, height: 128)
        return SpriteArt.texture(bounds: bounds, scale: 2) { cg in
            cg.setStrokeColor(UIColor.white.cgColor)
            cg.setLineWidth(5)
            cg.setLineCap(.round)
            if broken { cg.setLineDash(phase: 0, lengths: [14, 12]) }
            cg.strokeEllipse(in: bounds.insetBy(dx: 6, dy: 6))
        }
    }
}
