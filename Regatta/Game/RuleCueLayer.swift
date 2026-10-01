import RegattaCore
import SpriteKit
import UIKit

/// The rule cues over the fleet (#123, #15): the right-of-way glows (red round a boat you must keep clear of, green
/// round one that must keep clear of you, fading in as she nears), the rule-call lines with their rule-number badges,
/// and your penalty arc. The glows are the boats' own: this layer works out which boats glow and how strongly
/// (`glows`), and the scene sets each `BoatNode`'s halo from them. The lines and arc pair their colour with a line
/// style. Their sizes and widths are screen points at any zoom, and the badges stay upright as the camera turns.
/// Every node has a z of its own (`DrawOrder`), hidden or not.
final class RuleCueLayer: SKNode {
    static let layerName = "rules"
    static let lineName = "ruleCallLine"
    static let badgeName = "ruleCallBadge"
    static let arcName = "penaltyArc"

    private var lines: [SKShapeNode] = []
    private var badges: [(plate: SKShapeNode, label: SKLabelNode)] = []
    private let arc = SKShapeNode()
    private let ppm: CGFloat

    /// The glow each seat has now, nil where none. Empty until the cues are first drawn, and after `reset`.
    private(set) var glows: [RightOfWayGlow?] = []

    init(pointsPerMeter: CGFloat) {
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
        glows = GlowSelection.glows(keepClear: world.frame.keepClear, positions: world.boats.map(\.position),
                                    me: me, isGhost: ghost, rangeHulls: style.glowRangeHulls,
                                    fullHulls: style.glowFullHulls, hullLength: world.boatClass.hull.length)
        let active = ghost ? [] : calls.active(at: world.time, seconds: style.ruleCallLineSeconds,
                                               fadeSeconds: style.ruleCallFadeSeconds)
        updateLines(world, active: active, px: px, rotation: rotation)
        updateArc(world, style: style, px: px, rotation: rotation, ghost: ghost)
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

    /// Puts every boat's glow out, for while the cues are off (the layer's own nodes are hidden with it).
    func reset() {
        glows = []
    }

    /// How many glows, lines and arcs show, for tests: e.g. `glows=2 lines=1 arc=1`.
    var summary: String {
        let g = glows.compactMap { $0 }.count
        let l = lines.filter { !$0.isHidden }.count
        return "glows=\(g) lines=\(l) arc=\(arc.isHidden ? 0 : 1)"
    }
}
