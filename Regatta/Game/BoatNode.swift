import SpriteKit
import RegattaCore

/// Draws one boat: hull, trimmed sail, name, penalty badge, plus a wake and a
/// wind-shadow cone that live in the world layer beneath the fleet.
final class BoatNode: SKNode {
    let wake = SKShapeNode()
    let shadowCone: SKSpriteNode

    private let body = SKNode()
    private let sail: SKSpriteNode
    private let label = SKLabelNode(fontNamed: "AvenirNext-DemiBold")
    private let badge = SKLabelNode(fontNamed: "AvenirNext-Heavy")
    private let ppm: CGFloat
    private var sailAngle: CGFloat = 0
    private var wakePoints: [CGPoint] = []
    private var wakeTimer = 0.0

    /// The z's a boat's parts draw at, each boat a `DrawOrder` slot above the last by seat: in the effects layer
    /// every shadow cone under every wake, and in the fleet's every hull under every name, every name under every
    /// badge and every badge under every sail. Your boat draws over all of the fleet's.
    private enum Layer {
        static let cone: CGFloat = 0, wake: CGFloat = 0.5
        static let fleet: CGFloat = 5, mine: CGFloat = 10
        static let hull: CGFloat = 0, outline: CGFloat = 0.1, name: CGFloat = 0.25, badge: CGFloat = 0.5, sail: CGFloat = 1
    }

    /// `isMine` marks your boat (the driver's `myBoatIndex`): outlined in white inside her hull's edge, named larger
    /// and drawn on top. Every hull is the same size.
    init(boat: Boat, name: String, isMine: Bool, color: UIColor, boatClass: BoatClass, pointsPerMeter ppm: CGFloat) {
        self.ppm = ppm
        let length = CGFloat(boatClass.hull.length) * ppm

        // Hulls, sails and shadow cones are sprites sharing a few textures so
        // SpriteKit can batch the whole fleet into a handful of draw calls.
        let art = BoatArt.shared(boatClass: boatClass, pointsPerMeter: ppm)
        let hull = SKSpriteNode(texture: art.hull)
        hull.color = color
        hull.colorBlendFactor = 1
        hull.zPosition = Layer.hull
        // Its own sprite, untinted: in the hull's texture the tint turned the white to her colour.
        let outline = isMine ? SKSpriteNode(texture: art.outline) : nil
        outline?.zPosition = Layer.outline

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

        body.addChild(hull)
        if let outline { body.addChild(outline) }
        body.addChild(sail)
        addChild(body)

        label.text = name
        label.fontSize = isMine ? 12 : 10
        label.fontColor = UIColor.white.withAlphaComponent(isMine ? 1 : 0.75)
        label.position = CGPoint(x: 0, y: length * 0.75)
        label.verticalAlignmentMode = .center
        label.zPosition = Layer.name
        addChild(label)

        badge.fontSize = 11
        // White, not red: nothing may depend on red and green (#5, #15). #117 replaces the badge.
        badge.fontColor = .white
        badge.position = CGPoint(x: 0, y: -length * 0.8)
        badge.verticalAlignmentMode = .center
        badge.isHidden = true
        badge.zPosition = Layer.badge
        addChild(badge)

        wake.strokeColor = UIColor.white.withAlphaComponent(0.22)
        wake.lineWidth = 1.5
        wake.lineCap = .round
        wake.lineJoin = .round

        // A z each, from the seat (`DrawOrder`): the start row (#85) puts the fleet's cones, wakes, hulls, names
        // and sails over each other.
        let seat = DrawOrder.z(boat.id)
        shadowCone.zPosition = Layer.cone + seat
        wake.zPosition = Layer.wake + seat
        zPosition = (isMine ? Layer.mine : Layer.fleet) + seat
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// `settled` trims the sail straight to its target rather than easing it there (a frozen render fixture).
    func update(with boat: Boat, time: Double, dt: Double, settled: Bool = false) {
        let point = CGPoint(x: boat.position.x * ppm, y: boat.position.y * ppm)
        position = point
        body.zRotation = CGFloat(-boat.heading)

        updateSail(boat, time: time, dt: dt, settled: settled)
        updateBadge(boat)
        updateWake(point, dt: dt, active: boat.isOnCourse)

        shadowCone.isHidden = !boat.isOnCourse
        shadowCone.position = point
        shadowCone.zRotation = CGFloat(-(boat.apparentWind.direction + .pi)) // the cone follows her apparent wind (#10)

        alpha = boat.isOnCourse ? 1 : 0.45
    }

    private func updateSail(_ boat: Boat, time: Double, dt: Double, settled: Bool) {
        // Sail sits on the boom side, to leeward except by the lee, eased further the further off the wind.
        let twa = boat.twa
        let side: CGFloat = boat.boomSide == .port ? -1 : 1
        var target: CGFloat
        if twa < deg2rad(32) {
            target = CGFloat(deg2rad(3) + sin(time * 22) * deg2rad(6)) // luffing
        } else {
            target = CGFloat(((twa - deg2rad(25)) * 0.6).clamped(to: deg2rad(4)...deg2rad(85)))
        }
        target *= side
        sailAngle += (target - sailAngle) * (settled ? 1 : min(1, CGFloat(dt) * 8))
        sail.zRotation = sailAngle
        sail.xScale = sailAngle < 0 ? -1 : 1
    }

    private func updateBadge(_ boat: Boat) {
        let text: String?
        switch boat.status {
        case .ocs: text = "OCS"
        case .dsq: text = "DSQ"
        default: text = boat.penaltyTurnsOwed > 0 ? "\(boat.penaltyTurnsOwed * 360)°" : nil
        }
        badge.isHidden = text == nil
        if let text, badge.text != text { badge.text = text }
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
    let hull: SKTexture
    /// Your boat's white outline, drawn over her hull.
    let outline: SKTexture
    let sail: SKTexture
    let sailAnchor: CGPoint
    let cone: SKTexture

    private static var cache: [CGFloat: BoatArt] = [:]

    /// One class sails a race, so the art is cached by scale alone.
    static func shared(boatClass: BoatClass, pointsPerMeter ppm: CGFloat) -> BoatArt {
        if let art = cache[ppm] { return art }
        let art = BoatArt(boatClass: boatClass, ppm: ppm)
        cache[ppm] = art
        return art
    }

    private init(boatClass: BoatClass, ppm: CGFloat) {
        let length = CGFloat(boatClass.hull.length) * ppm
        let beam = CGFloat(boatClass.hull.beam) * ppm
        hull = BoatArt.hullTexture(length: length, beam: beam)
        outline = BoatArt.outlineTexture(length: length, beam: beam)
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

    /// The hull's outline, `length` × `beam`, bow up.
    private static func hullPath(length l: CGFloat, beam b: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: l / 2))
        path.addQuadCurve(to: CGPoint(x: b / 2, y: -l * 0.1), control: CGPoint(x: b / 2, y: l * 0.32))
        path.addLine(to: CGPoint(x: b * 0.42, y: -l / 2))
        path.addLine(to: CGPoint(x: -b * 0.42, y: -l / 2))
        path.addLine(to: CGPoint(x: -b / 2, y: -l * 0.1))
        path.addQuadCurve(to: CGPoint(x: 0, y: l / 2), control: CGPoint(x: -b / 2, y: l * 0.32))
        path.closeSubpath()
        return path
    }

    /// The hull's texture and her outline's share these bounds, so the two sprites line up.
    private static func hullBounds(length l: CGFloat, beam b: CGFloat) -> CGRect {
        CGRect(x: -b / 2 - 2, y: -l / 2 - 2, width: b + 4, height: l + 4)
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

    private static func hullTexture(length l: CGFloat, beam b: CGFloat) -> SKTexture {
        let path = hullPath(length: l, beam: b)
        return texture(bounds: hullBounds(length: l, beam: b)) { cg in
            cg.addPath(path)
            cg.setFillColor(UIColor.white.cgColor)
            cg.fillPath()
            // Cockpit, tinted darker than the deck by the sprite colour.
            let cockpit = CGPath(roundedRect: CGRect(x: -b * 0.26, y: -l * 0.42, width: b * 0.52, height: l * 0.36),
                                 cornerWidth: b * 0.2, cornerHeight: b * 0.2, transform: nil)
            cg.addPath(cockpit)
            cg.setFillColor(UIColor(white: 0.7, alpha: 1).cgColor)
            cg.fillPath()
            strokeInside(path, width: 1, color: UIColor(white: 0.55, alpha: 1), in: cg)
        }
    }

    private static func outlineTexture(length l: CGFloat, beam b: CGFloat) -> SKTexture {
        let path = hullPath(length: l, beam: b)
        return texture(bounds: hullBounds(length: l, beam: b)) { cg in
            strokeInside(path, width: 1.5, color: .white, in: cg)
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
