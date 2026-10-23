import RegattaCore
import SpriteKit
import UIKit

/// The rule cues over the fleet (#123, #15): the right-of-way glows (red round a boat you must keep clear of, green
/// round one that must keep clear of you, fading in as she nears), the rule-call lines with their rule-number badges,
/// and your penalty arc (under a `tackAndGybe` penalty, fleet-rules@6, with its tack and gybe marks inside it, #489).
/// The glows are the boats' own: this layer works out which boats glow and how strongly
/// (`glows`), and the scene sets each `BoatNode`'s halo from them. The lines and arc pair their colour with a line
/// style. Their sizes and widths are screen points at any zoom, and the badges stay upright as the camera turns.
/// Every node has a z of its own (`DrawOrder`), hidden or not.
final class RuleCueLayer: SKNode {
    static let layerName = "rules"
    static let lineName = "ruleCallLine"
    static let badgeName = "ruleCallBadge"
    static let arcName = "penaltyArc"
    static let markName = "penaltyTurnMark"
    static let barbName = "penaltyTurnBarb"
    /// The gap between the two marks at 3 and 9 o'clock, each side, radians (the owner's sketch, #489: 14°).
    static let markGap = 14 * CGFloat.pi / 180
    /// The unlit marks' alpha: translucent grey.
    static let unlitMarkAlpha: CGFloat = 0.5

    private var lines: [SKShapeNode] = []
    private var badges: [(plate: SKShapeNode, label: SKLabelNode)] = []
    private let arc = SKShapeNode()
    /// The tack mark (the screen-up half) and the gybe mark (screen-down), each with its barb.
    private let tackMark = SKShapeNode()
    private let gybeMark = SKShapeNode()
    private let tackBarb = SKShapeNode()
    private let gybeBarb = SKShapeNode()
    /// The marks last drawn, nil while hidden: `marksSummary`'s.
    private var drawnMarks: PenaltyReadout.TurnMarks?
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
        // The turn's marks over the arc: added last, so every earlier node keeps its z.
        for mark in [tackMark, gybeMark] {
            mark.name = Self.markName
            mark.lineCap = .round
            mark.isHidden = true
            mark.zPosition = next()
            addChild(mark)
        }
        for barb in [tackBarb, gybeBarb] {
            barb.name = Self.barbName
            barb.strokeColor = CuePalette.orange.uiColor
            barb.lineCap = .round
            barb.lineJoin = .round
            barb.isHidden = true
            barb.zPosition = next()
            addChild(barb)
        }
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func point(_ v: Vec2) -> CGPoint {
        CGPoint(x: CGFloat(v.x) * ppm, y: CGFloat(v.y) * ppm)
    }

    /// Draws the cues over `world` for a camera at scale `px` (scene points per screen point) turned `rotation`, its
    /// screen-up squashed to `squash` by the tilt (#597): the badges stand upright and unsquashed on screen.
    /// `served`: your last served turn's flash (#489), lighting a `tackAndGybe` turn's marks for a moment.
    func update(_ world: RenderWorld, calls: RuleCallLines, served: ServedTurnFlash = ServedTurnFlash(), style: BoatStyle,
                px: CGFloat, rotation: CGFloat, squash: CGFloat = 1) {
        let me = world.myBoatIndex
        let ghost = world.isGhost(ofSeat: me)
        glows = GlowSelection.glows(keepClear: world.frame.keepClear, positions: world.boats.map(\.position),
                                    me: me, isGhost: ghost, rangeHulls: style.glowRangeHulls,
                                    fullHulls: style.glowFullHulls, hullLength: world.boatClass.hull.length)
        let active = ghost ? [] : calls.active(at: world.time, seconds: style.ruleCallLineSeconds,
                                               fadeSeconds: style.ruleCallFadeSeconds)
        updateLines(world, active: active, px: px, rotation: rotation, squash: squash)
        updateArc(world, served: served, style: style, px: px, rotation: rotation, ghost: ghost)
    }

    private func updateLines(_ world: RenderWorld, active: [RuleCallLines.Line], px: CGFloat, rotation: CGFloat,
                             squash: CGFloat) {
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
                // Turned with the camera, the squash meets the badge unturned: undone by its own height.
                node.xScale = px
                node.yScale = px / max(squash, 1e-3)
                node.alpha = CGFloat(call.alpha)
                node.isHidden = false
            }
        }
    }

    /// Your penalty arc: a ring segment round your boat from screen up, clockwise, sweeping what's left of the
    /// current deadline's window (`PenaltyReadout.arcFraction`). Under a `tackAndGybe` penalty its turn's marks too
    /// (`updateMarks`), while `served` flashes even with nothing owed.
    private func updateArc(_ world: RenderWorld, served: ServedTurnFlash, style: BoatStyle, px: CGFloat,
                           rotation: CGFloat, ghost: Bool) {
        let readout = ghost ? nil : PenaltyReadout(frame: world.frame, seat: world.myBoatIndex, served: served)
        let radius = CGFloat(world.boatClass.hull.length * style.penaltyArcRadiusHulls) * ppm
        updateMarks(readout?.marks, world: world, radius: radius, style: style, px: px, rotation: rotation)
        guard let readout, readout.arcFraction > 0 else {
            arc.isHidden = true
            return
        }
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

    /// A `tackAndGybe` turn's two marks (#489), just inside the arc (`penaltyMarkInset`): the tack the screen-up
    /// half, the gybe the screen-down half, apart at 3 and 9 o'clock. Each is translucent grey until its crossing
    /// is made, then orange, with a half arrow (one barb, on the inside) at the end the turn goes towards. In the
    /// nodes' own frame, turned with the camera like the arc, screen up is +y and angles run anticlockwise from +x.
    private func updateMarks(_ marks: PenaltyReadout.TurnMarks?, world: RenderWorld, radius: CGFloat,
                             style: BoatStyle, px: CGFloat, rotation: CGFloat) {
        drawnMarks = marks
        guard let marks else {
            for node in [tackMark, gybeMark, tackBarb, gybeBarb] { node.isHidden = true }
            return
        }
        let inner = max(0, radius - CGFloat(style.penaltyMarkInset) * px)
        let width = CGFloat(style.penaltyMarkWidth) * px
        let gap = Self.markGap
        // The tack half from 3 o'clock round over the top to 9; the gybe half from 9 round under the bottom to 3.
        let halves: [(mark: SKShapeNode, barb: SKShapeNode, lit: Bool, from: CGFloat, to: CGFloat)] = [
            (tackMark, tackBarb, marks.isTackLit, gap, .pi - gap),
            (gybeMark, gybeBarb, marks.isGybeLit, .pi + gap, 2 * .pi - gap),
        ]
        for half in halves {
            let path = CGMutablePath()
            path.addArc(center: .zero, radius: inner, startAngle: half.from, endAngle: half.to, clockwise: false)
            half.mark.path = path
            half.mark.lineWidth = width
            half.mark.strokeColor = half.lit ? CuePalette.orange.uiColor
                : CuePalette.inactiveGrey.uiColor.withAlphaComponent(Self.unlitMarkAlpha)
            for node in [half.mark, half.barb] {
                node.position = point(world.me.position)
                node.zRotation = rotation
            }
            half.mark.isHidden = false
            guard half.lit, marks.direction != 0 else {
                half.barb.isHidden = true
                continue
            }
            // Clockwise the angle falls, so the leading end is the half's lower angle; anticlockwise its higher.
            let clockwise = marks.direction > 0
            let end = clockwise ? half.from : half.to
            let at = CGPoint(x: inner * cos(end), y: inner * sin(end))
            // The way of travel there, and the way in towards the boat.
            let along = clockwise ? CGVector(dx: sin(end), dy: -cos(end)) : CGVector(dx: -sin(end), dy: cos(end))
            let inward = CGVector(dx: -cos(end), dy: -sin(end))
            // The sketch's proportions to its 6-wide marks: 11 long, its barb 7 in, drawn 4 wide.
            let length = width * 11 / 6, spread = width * 7 / 6
            let tip = CGPoint(x: at.x + along.dx * length * 0.35, y: at.y + along.dy * length * 0.35)
            let barbEnd = CGPoint(x: at.x - along.dx * length * 0.65 + inward.dx * spread,
                                  y: at.y - along.dy * length * 0.65 + inward.dy * spread)
            let barb = CGMutablePath()
            barb.move(to: barbEnd)
            barb.addLine(to: tip)
            half.barb.path = barb
            half.barb.lineWidth = width * 4 / 6
            half.barb.isHidden = false
        }
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

    /// The `tackAndGybe` turn's marks as drawn, for tests (#489): "none" when hidden, else e.g.
    /// `tack=lit gybe=grey barbs=1`, the barbs counted as shown.
    var marksSummary: String {
        guard let marks = drawnMarks, !tackMark.isHidden, !gybeMark.isHidden else { return "none" }
        func state(_ lit: Bool) -> String { lit ? "lit" : "grey" }
        let barbs = [tackBarb, gybeBarb].filter { !$0.isHidden }.count
        return "tack=\(state(marks.isTackLit)) gybe=\(state(marks.isGybeLit)) barbs=\(barbs)"
    }
}
