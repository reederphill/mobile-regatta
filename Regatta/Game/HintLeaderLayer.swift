import RegattaCore
import SpriteKit
import UIKit

/// A hint's thin leader line (#23): from under the notice pill down to the thing the hint is about. Faint white, a
/// point wide, never a cue colour; shown only while a hint with a leader shows and its target is in the clear part of
/// the view.
nonisolated enum HintLeader {
    /// The line stops this far short of its target, screen points, so it never covers the boat or mark it points at.
    static let targetGap: CGFloat = 14
    /// A one-line notice pill's height, points: the line starts under it (a two-line pill covers its first stretch).
    static let pillHeight: CGFloat = 30
    static let alpha: CGFloat = 0.55
    static let width: CGFloat = 1

    /// The line from `anchor` towards `target` (scene points, from the bottom-left, y up), stopped `gap` short of it;
    /// nil when the target isn't inside `visible` or is too close to the anchor to draw a line to.
    static func segment(anchor: CGPoint, target: CGPoint, visible: CGRect,
                        gap: CGFloat = targetGap) -> (from: CGPoint, to: CGPoint)? {
        guard ViewInsets.contains(visible, target) else { return nil }
        let dx = target.x - anchor.x, dy = target.y - anchor.y
        let length = hypot(dx, dy)
        guard length > 2 * gap else { return nil }
        let k = (length - gap) / length
        return (anchor, CGPoint(x: anchor.x + dx * k, y: anchor.y + dy * k))
    }

    /// Where `target` is on the water in `world`, metres.
    @MainActor static func position(of target: HintTarget, in world: RenderWorld) -> Vec2? {
        switch target {
        case .myBoat, .vane: world.me.position
        case .boat(let seat): world.boats.indices.contains(seat) ? world.boats[seat].position : nil
        case .point(let p): p
        }
    }

    /// A render fixture's hint's leader target (#129): what its hint points at in the frozen world (the fixture runs
    /// no engine, so no trigger says).
    @MainActor static func fixtureTarget(_ id: HintID, world: RenderWorld) -> HintTarget? {
        let me = world.me.position
        switch id {
        case .redGlow, .greenGlow:
            // The boat with the strongest glow of the hint's kind, as the scene draws them.
            let seat = world.myBoatIndex
            let glows = GlowSelection.glows(keepClear: world.frame.keepClear, positions: world.boats.map(\.position),
                                            me: seat, isGhost: world.isGhost(ofSeat: seat),
                                            rangeHulls: BoatStyle.standard.glowRangeHulls,
                                            fullHulls: BoatStyle.standard.glowFullHulls,
                                            hullLength: world.boatClass.hull.length)
            return HintSnapshot.strongest(id == .redGlow ? .giveWay : .hasRight, in: glows, atLeast: 0).map { .boat($0) }
        case .windShadow:
            let others = world.boats.indices.filter { $0 != world.myBoatIndex }
            return others.min { (world.boats[$0].position - me).length < (world.boats[$1].position - me).length }
                .map { .boat($0) }
        case .markZone:
            let leg = world.course.legSailed(status: world.me.status, legIndex: world.me.legIndex)
            return world.course.marksOfLeg(leg).map(\.position)
                .min { ($0 - me).length < ($1 - me).length }.map { .point($0) }
        case .puff:
            return world.puffs.filter { $0.intensity > 0 }.map(\.center)
                .min { ($0 - me).length < ($1 - me).length }.map { .point($0) }
        case .noGo, .lettingGo, .grooveTick, .windShift:
            return .vane
        case .raceStart, .startSequence, .ocs, .ruleCall, .layline:
            return nil
        }
    }
}

/// The leader line's node, a child of the camera like the edge arrow: placed in screen points from the view's centre.
final class HintLeaderLayer {
    let node = SKShapeNode()
    /// The line the path was last built for, camera points: rebuilt only once an end moves more than `rebuildPoints`.
    private var drawn: (from: CGPoint, to: CGPoint)?
    static let rebuildPoints: CGFloat = 0.5

    init() {
        node.name = "hintLeader"
        node.strokeColor = UIColor.white.withAlphaComponent(HintLeader.alpha)
        node.lineWidth = HintLeader.width
        node.lineCap = .round
        node.zPosition = 19
        node.isHidden = true
    }

    /// Draws the line for `notice` over `world` in a scene of `sceneSize`: from the pill's bottom (`anchorFromTop`
    /// points below the view's top) to its target, projected by `project`, if it shows in `visible`.
    func update(notice: Notice?, world: RenderWorld, sceneSize: CGSize, anchorFromTop: CGFloat, visible: CGRect,
                project: (Vec2) -> CGPoint) {
        guard let notice, notice.kind == .hint, let leader = notice.leader,
              let p = HintLeader.position(of: leader, in: world),
              let line = HintLeader.segment(anchor: CGPoint(x: sceneSize.width / 2, y: sceneSize.height - anchorFromTop),
                                            target: project(p), visible: visible) else {
            node.isHidden = true
            return
        }
        let centre = CGPoint(x: sceneSize.width / 2, y: sceneSize.height / 2)
        let from = CGPoint(x: line.from.x - centre.x, y: line.from.y - centre.y)
        let to = CGPoint(x: line.to.x - centre.x, y: line.to.y - centre.y)
        node.isHidden = false
        if let drawn, !Self.moved(drawn.from, from), !Self.moved(drawn.to, to) { return }
        let path = CGMutablePath()
        path.move(to: from)
        path.addLine(to: to)
        node.path = path
        drawn = (from, to)
    }

    /// Whether `b` is more than `rebuildPoints` from `a`.
    static func moved(_ a: CGPoint, _ b: CGPoint) -> Bool {
        hypot(b.x - a.x, b.y - a.y) > rebuildPoints
    }

    /// Whether the line shows, for tests.
    var isShowing: Bool { !node.isHidden }
}
