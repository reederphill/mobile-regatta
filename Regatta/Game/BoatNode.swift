import SpriteKit
import RegattaCore

/// Draws what lies flat on the water under one boat (#117) from her pose (`BoatPose`): her heel's drop shadow, your
/// boat's glow and her right-of-way glow, plus her wake and backwind (`BoatEffects`, #121) that live in the world's
/// effects layer beneath the fleet. Her hull, rig and sail stand up in `Fleet3D` (#597), over these. No name and no badge: boat names are never shown on the water (#15), and
/// penalties are #123's and #124's.
final class BoatNode: SKNode {
    /// Her wake and backwind: the scene adds `effects.nodes` to its effects layer.
    let effects: BoatEffects

    /// A ghost fades as one flat image (#30): her shadow and glows composited first, then faded together, so where
    /// they overlap she reads no darker than anywhere else. Its effect is on for ghosts only; a live boat draws
    /// straight through it.
    let fade = SKEffectNode()
    private let body = SKNode()
    /// What heel narrows: the drop shadow and the glows.
    private let hullGroup = SKNode()
    private let heelShadow: SKSpriteNode
    private let glow: SKSpriteNode?
    /// The right-of-way glow (#123): a white halo tinted red, green or orange and faded by `setRightOfWayGlow`,
    /// under the hull. Your own boat never has one.
    private let rightOfWayGlow: SKSpriteNode
    private let ppm: CGFloat
    private let beam: CGFloat
    /// Hides her wake, what the thermal tiers change, for `-cuesOnly`'s UI test (#127); `Fleet3D` hides her sail. Her
    /// heel, glows, cone and backwind still draw.
    var hidesDecoration = false

    /// The z's a boat's parts draw at, each boat a `DrawOrder` slot above the last by seat: in the fleet's layer
    /// every drop shadow under the glows. Your boat's draw over all of the fleet's. (The effects layer's are
    /// `BoatEffects`'.) `Fleet3D`'s hulls and sails stand over the whole layer.
    private enum Layer {
        static let fleet: CGFloat = 5, mine: CGFloat = 10
        static let heelShadow: CGFloat = 0, rightOfWayGlow: CGFloat = 0.05, glow: CGFloat = 0.1
    }

    /// `isMine` marks your boat (the driver's `myBoatIndex`): a soft white glow under her hull, and drawn on top.
    /// `style`'s baked-in art values (the glows' blur) are drawn into the textures here.
    init(boat: Boat, isMine: Bool, color: UIColor, boatClass: BoatClass, pointsPerMeter ppm: CGFloat,
         style: BoatStyle = .standard) {
        self.ppm = ppm
        beam = CGFloat(boatClass.hull.beam) * ppm

        // Shadows and glows are sprites sharing a few textures, per class and scale, so SpriteKit can batch the
        // whole fleet into a handful of draw calls; so are the effects.
        let art = BoatArt.shared(boatClass: boatClass, pointsPerMeter: ppm, style: style)
        heelShadow = SKSpriteNode(texture: art.shadow)
        heelShadow.color = .black
        heelShadow.colorBlendFactor = 1
        heelShadow.alpha = 0
        heelShadow.zPosition = Layer.heelShadow
        glow = isMine ? SKSpriteNode(texture: art.glow) : nil
        glow?.zPosition = Layer.glow
        rightOfWayGlow = SKSpriteNode(texture: art.rightOfWayGlow)
        rightOfWayGlow.colorBlendFactor = 1
        rightOfWayGlow.isHidden = true
        rightOfWayGlow.zPosition = Layer.rightOfWayGlow

        effects = BoatEffects(seat: boat.id, boatClass: boatClass, pointsPerMeter: ppm, style: style)
        fade.shouldEnableEffects = false
        fade.shouldRasterize = false

        super.init()

        hullGroup.addChild(heelShadow)
        hullGroup.addChild(rightOfWayGlow)
        if let glow { hullGroup.addChild(glow) }
        body.addChild(hullGroup)
        fade.addChild(body)
        addChild(fade)

        // A z each, from the seat (`DrawOrder`): the start row (#85) puts the fleet's glows over each other.
        let seat = DrawOrder.z(boat.id)
        zPosition = (isMine ? Layer.mine : Layer.fleet) + seat
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Draws `boat` in `pose` at race time `time` (seconds; the effects run on it, never the wall clock).
    /// `settled` draws her effects as if standing still forever (a frozen render fixture). `wakeQuality` is the
    /// wake's tier (#127). `backwindSail` scales her backwind stripes and `backwindSide` (nil: her windward side now)
    /// places them (`RenderWorld.backwind(ofSeat:)`, #377). `justSeated` (`TickFrame.isJustSeated`) draws her no
    /// planing cue (#492).
    func update(with boat: Boat, pose: BoatPose, style: BoatStyle, wakeQuality: WakeQuality = .full, time: Double,
                dt: Double, settled: Bool = false, backwindSail: Double = 1, backwindSide: Tack? = nil,
                justSeated: Bool = false) {
        position = CGPoint(x: boat.position.x * ppm, y: boat.position.y * ppm)
        body.zRotation = CGFloat(-boat.heading)

        updateHeel(pose, style: style)
        effects.update(with: boat, pose: pose, style: style, quality: wakeQuality, time: time, dt: dt,
                       settled: settled, backwindSail: backwindSail, backwindSide: backwindSide, justSeated: justSeated)
        if hidesDecoration {
            effects.trail.isHidden = true
            effects.cornerTrail.isHidden = true
        }

        glow?.alpha = CGFloat(style.glowAlpha)
        fade.shouldEnableEffects = pose.isGhost
        fade.alpha = pose.isGhost ? CGFloat(style.ghostAlpha) : 1
    }

    /// Lights or puts out her right-of-way glow (#123): red where you keep clear of her, green where she keeps clear
    /// of you, orange where she is taking a penalty (#517), `glow.intensity` of `style.glowMaxAlpha`. Nil hides it.
    func setRightOfWayGlow(_ glow: RightOfWayGlow?, style: BoatStyle) {
        guard let glow else {
            rightOfWayGlow.isHidden = true
            return
        }
        switch glow.kind {
        case .giveWay: rightOfWayGlow.color = CuePalette.giveWayRed.uiColor
        case .hasRight: rightOfWayGlow.color = CuePalette.hasRightGreen.uiColor
        case .takingAPenalty: rightOfWayGlow.color = CuePalette.orange.uiColor
        }
        rightOfWayGlow.alpha = CGFloat(glow.intensity * style.glowMaxAlpha)
        rightOfWayGlow.isHidden = false
    }

    /// Her right-of-way halo's colour and alpha as drawn, nil while hidden, for tests.
    var shownRightOfWayHalo: (colour: UIColor, alpha: CGFloat)? {
        rightOfWayGlow.isHidden ? nil : (rightOfWayGlow.color, rightOfWayGlow.alpha)
    }

    /// Heel (#22): the hull drawn narrower and a drop shadow offset to leeward (the boom's side, except by the lee).
    private func updateHeel(_ pose: BoatPose, style: BoatStyle) {
        let heel = CGFloat(pose.heel)
        let leeward: CGFloat = pose.leeSide == .port ? -1 : 1
        hullGroup.xScale = 1 - CGFloat(style.heelNarrowing) * heel
        heelShadow.position = CGPoint(x: leeward * heel * CGFloat(style.heelShadowOffset) * beam, y: 0)
        heelShadow.alpha = heel * CGFloat(style.heelShadowAlpha)
    }
}

/// Pre-rendered textures for what lies flat under a boat, drawn in white so each sprite can be tinted. Her hull and
/// sail are `Fleet3D`'s (#597).
struct BoatArt {
    /// The hull's silhouette, from the class's outline: the heel's drop shadow draws it, tinted black.
    let shadow: SKTexture
    /// Your boat's soft glow, drawn under her hull.
    let glow: SKTexture
    /// The right-of-way glow's halo (#123): a wider white blur, tinted at use.
    let rightOfWayGlow: SKTexture

    /// What the art is drawn from: the class's hull, the scale, and the glows' blur.
    private struct Key: Hashable {
        var outline: [Double]
        var length: Double
        var beam: Double
        var ppm: CGFloat
        var glowBlur: Double
        var rightOfWayGlowBlur: Double
    }

    private static var cache: [Key: BoatArt] = [:]

    /// Built once per class and scale: a boat never rebuilds a texture as she sails, and the tuning panel can
    /// swap the class in one process.
    static func shared(boatClass: BoatClass, pointsPerMeter ppm: CGFloat, style: BoatStyle) -> BoatArt {
        let hull = boatClass.hull
        let key = Key(outline: hull.outline.flatMap { [$0.x, $0.y] }, length: hull.length, beam: hull.beam, ppm: ppm,
                      glowBlur: style.glowBlur, rightOfWayGlowBlur: style.rightOfWayGlowBlur)
        if let art = cache[key] { return art }
        let art = BoatArt(boatClass: boatClass, ppm: ppm, glowBlur: CGFloat(style.glowBlur),
                          rightOfWayGlowBlur: CGFloat(style.rightOfWayGlowBlur))
        cache[key] = art
        return art
    }

    private init(boatClass: BoatClass, ppm: CGFloat, glowBlur: CGFloat, rightOfWayGlowBlur: CGFloat) {
        let path = BoatArt.hullPath(boatClass.hull, ppm: ppm)
        // Centred on the hull's origin, as every sprite is anchored, so the shadow and glows line up on the boat.
        let box = path.boundingBoxOfPath
        let halfWidth = max(abs(box.minX), abs(box.maxX)) + 2, halfHeight = max(abs(box.minY), abs(box.maxY)) + 2
        let bounds = CGRect(x: -halfWidth, y: -halfHeight, width: halfWidth * 2, height: halfHeight * 2)
        shadow = BoatArt.texture(bounds: bounds) { cg in
            cg.addPath(path)
            cg.setFillColor(UIColor.white.cgColor)
            cg.fillPath()
        }
        glow = BoatArt.glowTexture(path, bounds: bounds, blur: glowBlur)
        rightOfWayGlow = BoatArt.glowTexture(path, bounds: bounds, blur: rightOfWayGlowBlur)
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

    /// A soft white blur of the hull's silhouette, wider than it: under the hull only its halo shows. `glowBlur`,
    /// points: soft, with no hard edge that would read as a ring (#15). Your glow draws it as it is, the
    /// right-of-way glow tinted and wider.
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
}

