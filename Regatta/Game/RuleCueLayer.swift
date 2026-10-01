import RegattaCore
import SpriteKit
import UIKit

/// The rule cues over the fleet (#123, #15): the right-of-way glyphs (an orange ⚠ over a boat you must keep clear of,
/// a blue chevron over one that must keep clear of you), the rule-call lines with their rule-number badges, and your
/// penalty arc. Every hint pairs its colour with a shape or line style (colour-blind safety). Sizes and widths are
/// screen points at any zoom, and the glyphs and badges stay upright as the camera turns. Every node has a z of its
/// own (`DrawOrder`), hidden or not.
final class RuleCueLayer: SKNode {
    static let layerName = "rules"
    static let glyphName = "rightOfWayGlyph"
    static let lineName = "ruleCallLine"
    static let badgeName = "ruleCallBadge"
    static let arcName = "penaltyArc"

    private var glyphs: [SKSpriteNode] = []
    private var lines: [SKShapeNode] = []
    private var badges: [(plate: SKShapeNode, label: SKLabelNode)] = []
    private let arc = SKShapeNode()
    private let ppm: CGFloat

    private static let giveWayTexture = SKTexture(image: RuleGlyphArt.image(.giveWay))
    private static let hasRightTexture = SKTexture(image: RuleGlyphArt.image(.hasRight))

    init(seats: Int, pointsPerMeter: CGFloat) {
        ppm = pointsPerMeter
        super.init()
        name = Self.layerName
        var slot = 0
        func next() -> CGFloat {
            defer { slot += 1 }
            return DrawOrder.z(slot)
        }
        arc.name = Self.arcName
        arc.strokeColor = CuePalette.orange.uiColor
        arc.lineCap = .round
        arc.isHidden = true
        arc.zPosition = next()
        addChild(arc)
        for _ in 0..<RuleCallLines.maxLines {
            let line = SKShapeNode()
            line.name = Self.lineName
            line.strokeColor = CuePalette.orange.uiColor
            line.lineCap = .round
            line.isHidden = true
            line.zPosition = next()
            addChild(line)
            lines.append(line)
        }
        for _ in 0..<RuleCallLines.maxLines {
            let plate = SKShapeNode(rectOf: CGSize(width: 30, height: 16), cornerRadius: 4)
            plate.name = Self.badgeName
            plate.fillColor = CuePalette.orange.uiColor
            plate.strokeColor = UIColor.black.withAlphaComponent(0.35)
            plate.lineWidth = 1
            plate.isHidden = true
            plate.zPosition = next()
            let label = SKLabelNode(fontNamed: "HelveticaNeue-Bold")
            label.name = Self.badgeName
            label.fontSize = 11
            label.fontColor = .black
            label.verticalAlignmentMode = .center
            label.horizontalAlignmentMode = .center
            label.isHidden = true
            label.zPosition = next()
            addChild(plate)
            addChild(label)
            badges.append((plate, label))
        }
        for _ in 0..<seats {
            let glyph = SKSpriteNode(texture: Self.giveWayTexture)
            glyph.name = Self.glyphName
            glyph.isHidden = true
            glyph.zPosition = next()
            addChild(glyph)
            glyphs.append(glyph)
        }
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func point(_ v: Vec2) -> CGPoint {
        CGPoint(x: CGFloat(v.x) * ppm, y: CGFloat(v.y) * ppm)
    }

    /// Draws the cues over `world` for a camera at scale `px` (scene points per screen point) turned `rotation`.
    func update(_ world: RenderWorld, calls: RuleCallLines, style: BoatStyle, px: CGFloat, rotation: CGFloat) {
        let me = world.myBoatIndex
        let ghost = world.isGhost(ofSeat: me)
        updateGlyphs(world, style: style, px: px, rotation: rotation, ghost: ghost)
        let active = ghost ? [] : calls.active(at: world.time, seconds: style.ruleCallLineSeconds,
                                               fadeSeconds: style.ruleCallFadeSeconds)
        updateLines(world, active: active, px: px, rotation: rotation)
        updateArc(world, style: style, px: px, rotation: rotation, ghost: ghost)
    }

    private func updateGlyphs(_ world: RenderWorld, style: BoatStyle, px: CGFloat, rotation: CGFloat, ghost: Bool) {
        let shown = GlyphSelection.glyphs(keepClear: world.frame.keepClear, positions: world.boats.map(\.position),
                                          me: world.myBoatIndex, isGhost: ghost, rangeHulls: style.glyphRangeHulls,
                                          hullLength: world.boatClass.hull.length)
        // Screen up, in the world: the glyph sits that far above its boat whatever way the camera faces.
        let up = CGPoint(x: -sin(rotation), y: cos(rotation))
        let offset = CGFloat(style.glyphOffset) * px
        let size = CGFloat(style.glyphSize) * px
        for (seat, node) in glyphs.enumerated() {
            guard seat < shown.count, let glyph = shown[seat] else {
                node.isHidden = true
                continue
            }
            node.isHidden = false
            node.texture = glyph == .giveWay ? Self.giveWayTexture : Self.hasRightTexture
            node.size = CGSize(width: size, height: size)
            let at = point(world.boats[seat].position)
            node.position = CGPoint(x: at.x + up.x * offset, y: at.y + up.y * offset)
            node.zRotation = rotation
        }
    }

    private func updateLines(_ world: RenderWorld, active: [RuleCallLines.Line], px: CGFloat, rotation: CGFloat) {
        for (i, line) in lines.enumerated() {
            let badge = badges[i]
            guard i < active.count, world.boats.indices.contains(active[i].offender),
                  world.boats.indices.contains(active[i].victim) else {
                line.isHidden = true
                badge.plate.isHidden = true
                badge.label.isHidden = true
                continue
            }
            let call = active[i]
            let a = point(world.boats[call.offender].position)
            let b = point(world.boats[call.victim].position)
            let path = CGMutablePath()
            path.move(to: a)
            path.addLine(to: b)
            line.path = path.copy(dashingWithPhase: 0, lengths: [6 * px, 5 * px])
            line.lineWidth = 2 * px
            line.alpha = CGFloat(call.alpha)
            line.isHidden = false

            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let width = CGFloat(max(22, 8 + 7 * call.badge.count))
            badge.plate.path = CGPath(roundedRect: CGRect(x: -width / 2, y: -8, width: width, height: 16),
                                      cornerWidth: 4, cornerHeight: 4, transform: nil)
            badge.label.text = call.badge
            for node in [badge.plate, badge.label] as [SKNode] {
                node.position = mid
                node.zRotation = rotation
                node.setScale(px)
                node.alpha = CGFloat(call.alpha)
                node.isHidden = false
            }
        }
    }

    /// Your penalty arc: a ring segment round your boat from screen up, clockwise, sweeping what's left of the
    /// current deadline's window (`PenaltyReadout.arcFraction`).
    private func updateArc(_ world: RenderWorld, style: BoatStyle, px: CGFloat, rotation: CGFloat, ghost: Bool) {
        guard !ghost, let readout = PenaltyReadout(frame: world.frame, seat: world.myBoatIndex),
              readout.arcFraction > 0 else {
            arc.isHidden = true
            return
        }
        let radius = CGFloat(world.boatClass.hull.length * style.penaltyArcRadiusHulls) * ppm
        let start = CGFloat.pi / 2
        let end = start - CGFloat(readout.arcFraction) * 2 * .pi
        let path = CGMutablePath()
        path.addArc(center: .zero, radius: radius, startAngle: start, endAngle: end, clockwise: true)
        arc.path = path
        arc.lineWidth = CGFloat(style.penaltyArcWidth) * px
        arc.position = point(world.me.position)
        arc.zRotation = rotation
        arc.isHidden = false
    }

    /// How many glyphs, lines and arcs show, for tests: e.g. `glyphs=2 lines=1 arc=1`.
    var summary: String {
        let g = glyphs.filter { !$0.isHidden }.count
        let l = lines.filter { !$0.isHidden }.count
        return "glyphs=\(g) lines=\(l) arc=\(arc.isHidden ? 0 : 1)"
    }

    /// The glyph each seat shows now, nil where none, for tests.
    var shownGlyphs: [RightOfWayGlyph?] {
        glyphs.map { node in
            node.isHidden ? nil : (node.texture === Self.giveWayTexture ? .giveWay : .hasRight)
        }
    }
}

/// The glyphs' art, drawn once (#123): shape carries the meaning, colour backs it. The ⚠ is an orange triangle with
/// a black exclamation mark; the chevron a blue downward chevron. The ⚠ has a dark outline to lift it off the water;
/// the chevron, whose blue is close to the water's lightness, a pale tint of its own blue (docs/palette.md). Not white:
/// white is your boat's (#22).
enum RuleGlyphArt {
    static let side: CGFloat = 32
    /// The chevron's edge: its blue, lightened (the hue stays the reserved chevron blue's; not white, #22).
    static let chevronEdge = UIColor(red: 0.78, green: 0.81, blue: 1.0, alpha: 1)

    static func image(_ glyph: RightOfWayGlyph) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            let cg = context.cgContext
            let outline = UIColor.black.withAlphaComponent(0.6)
            cg.setLineJoin(.round)
            cg.setLineCap(.round)
            switch glyph {
            case .giveWay:
                let triangle = UIBezierPath()
                triangle.move(to: CGPoint(x: side / 2, y: 3))
                triangle.addLine(to: CGPoint(x: side - 2.5, y: side - 4))
                triangle.addLine(to: CGPoint(x: 2.5, y: side - 4))
                triangle.close()
                CuePalette.orange.uiColor.setFill()
                triangle.fill()
                outline.setStroke()
                triangle.lineWidth = 2
                triangle.stroke()
                UIColor.black.setFill()
                UIBezierPath(roundedRect: CGRect(x: side / 2 - 1.75, y: 11, width: 3.5, height: 10), cornerRadius: 1.75)
                    .fill()
                UIBezierPath(ovalIn: CGRect(x: side / 2 - 2, y: 22.5, width: 4, height: 4)).fill()
            case .hasRight:
                let chevron = UIBezierPath()
                chevron.move(to: CGPoint(x: 3, y: 7))
                chevron.addLine(to: CGPoint(x: side / 2, y: 18))
                chevron.addLine(to: CGPoint(x: side - 3, y: 7))
                chevron.addLine(to: CGPoint(x: side - 3, y: 15))
                chevron.addLine(to: CGPoint(x: side / 2, y: 27))
                chevron.addLine(to: CGPoint(x: 3, y: 15))
                chevron.close()
                // A pale tint of the chevron's own blue edges it: dark on dark water (and in greyscale) it vanished
                // with the dark outline alone.
                chevronEdge.setStroke()
                chevron.lineWidth = 3
                chevron.stroke()
                CuePalette.chevronBlue.uiColor.setFill()
                chevron.fill()
            }
        }
    }
}
