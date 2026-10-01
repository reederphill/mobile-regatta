import RegattaCore
import SpriteKit
import UIKit

/// The race scene's chart (#115): the static layer under the fleet, in world space under `GameScene`'s world node,
/// so the camera's rotation (#113) turns it with everything else. Built once from the course and the venue.
///
/// - Decoration, each node named and a direct child of the world: the shallows tint from the venue's depth grid
///   (`chart-shallows`, under the water, so puffs and ripples read over it), the land with its relief
///   (`chart-land`) and landmark silhouettes (`chart-landmarks`). The current itself is never drawn (ADR 0003): only
///   `Venue.Current.depths` is read.
/// - Cues, apart from the decoration so the thermal ladder (#127) can leave them alone: the race area's boundary
///   and its hatched band (`chart-boundary`, under the land, which hides it where land trims the area), and the
///   marks, zones, rounding arrows, gate connector, line ends and start line in the scene's `course` layer.
///
/// Every node has a z of its own (`DrawOrder`). Nothing animates, so a frozen render fixture draws the same twice.
final class ChartLayer {
    static let shallowsName = "chart-shallows"
    static let boundaryName = "chart-boundary"
    static let landName = "chart-land"
    static let landmarksName = "chart-landmarks"

    /// The layers' z's in the world: the shallows under the water (−10), the boundary, land and landmarks over the
    /// water's own nodes (−11…−4) and under the effects (0).
    static let shallowsZ: CGFloat = -20
    static let boundaryZ: CGFloat = -3
    static let landZ: CGFloat = -2
    static let landmarksZ: CGFloat = -1

    let style: ChartStyle
    private let course: CourseLayout
    private let venue: Venue
    private let ppm: CGFloat

    /// The world's chart nodes, by layer.
    private(set) var shallows: [SKNode] = []
    private(set) var boundary: [SKNode] = []
    private(set) var land: [SKNode] = []
    private(set) var landmarks: [SKNode] = []

    /// The course layer's nodes for each buoy, in `ChartMarks.buoys` order.
    private struct BuoyNodes {
        var buoy: ChartMarks.Buoy
        var zone: SKShapeNode
        var arrow: SKShapeNode
        var body: SKShapeNode
    }
    private var buoys: [BuoyNodes] = []
    private var gateConnector = SKShapeNode()
    private var lineEnds: [SKShapeNode] = []
    private var startLine = SKShapeNode()
    /// Each stroke and the width it draws at on screen, in points: scaled by the camera's scale (`rescale`).
    private var strokes: [(node: SKShapeNode, width: CGFloat)] = []
    private var strokeScale: CGFloat?
    /// The dashed strokes and their undashed paths, re-dashed at each rescale so a dash keeps its screen length.
    private var dashed: [(node: SKShapeNode, path: CGPath)] = []
    /// The dash pattern the dashed strokes are drawn with now, world points.
    private(set) var dashPattern: [CGFloat]

    /// What the marks were last styled for: the leg drawn active and whether the line is.
    private struct StyleKey: Equatable {
        var leg: CourseLayout.Leg
        var lineActive: Bool
    }
    private var styled: StyleKey?

    init(course: CourseLayout, venue: Venue, pointsPerMeter: CGFloat, style: ChartStyle = .standard) {
        self.course = course
        self.venue = venue
        self.style = style
        ppm = pointsPerMeter
        dashPattern = style.dashes(atCameraScale: 1)
    }

    private func point(_ v: Vec2) -> CGPoint {
        CGPoint(x: CGFloat(v.x) * ppm, y: CGFloat(v.y) * ppm)
    }

    // MARK: - Build

    /// Adds the chart to `world`, and the marks and line to `courseLayer`, whose children each take a z of their
    /// own in the order built.
    func install(in world: SKNode, courseLayer: SKNode) {
        shallows = buildShallows()
        boundary = buildBoundary()
        land = buildLand()
        landmarks = buildLandmarks()
        for (layer, base, name) in [(shallows, Self.shallowsZ, Self.shallowsName),
                                    (boundary, Self.boundaryZ, Self.boundaryName),
                                    (land, Self.landZ, Self.landName),
                                    (landmarks, Self.landmarksZ, Self.landmarksName)] {
            for (slot, node) in layer.enumerated() {
                node.name = name
                node.zPosition = base + DrawOrder.z(slot)
                world.addChild(node)
            }
        }
        buildMarks(in: courseLayer)
        rescale(1)
    }

    /// The shallows (only a venue with a current): one sprite over the depth grid, a texel per node, linearly
    /// filtered, over a full-tint ground (the sim takes depth 0 beyond the grid).
    private func buildShallows() -> [SKNode] {
        guard let current = venue.current else { return [] }
        let grid = current.grid
        let ground = SKSpriteNode(color: ShallowsTint.colour(weight: 1).uiColor,
                                  size: CGSize(width: 20_000 * ppm, height: 20_000 * ppm))
        let centre = grid.origin + grid.columnAxis * (Double(grid.columns - 1) * grid.cellSize / 2)
            + grid.rowAxis * (Double(grid.rows - 1) * grid.cellSize / 2)
        let rotation = CGFloat(atan2(grid.columnAxis.y, grid.columnAxis.x))
        ground.position = point(centre)
        ground.zRotation = rotation

        let texture = SKTexture(cgImage: Self.shallowsImage(current, style: style))
        texture.filteringMode = .linear
        let sprite = SKSpriteNode(texture: texture, size: CGSize(width: CGFloat(Double(grid.columns) * grid.cellSize) * ppm,
                                                                 height: CGFloat(Double(grid.rows) * grid.cellSize) * ppm))
        sprite.position = point(centre)
        sprite.zRotation = rotation
        return [ground, sprite]
    }

    /// The shallows' texels, RGBA, image rows top-down: texel (column, row) is node (column, row), so the grid's
    /// row 0 is the image's bottom row.
    static func shallowsPixels(_ current: Venue.Current, style: ChartStyle = .standard) -> [UInt8] {
        let grid = current.grid
        var pixels: [UInt8] = []
        pixels.reserveCapacity(grid.nodeCount * 4)
        for imageRow in 0..<grid.rows {
            let row = grid.rows - 1 - imageRow
            for column in 0..<grid.columns {
                let weight = ChartGeometry.shallowsWeight(depth: current.depth(column: column, row: row),
                                                          maxDepth: current.maxDepth, fraction: style.shallowFraction)
                pixels += ShallowsTint.colour(weight: weight).rgb8 + [255]
            }
        }
        return pixels
    }

    private static func shallowsImage(_ current: Venue.Current, style: ChartStyle) -> CGImage {
        let grid = current.grid
        let data = Data(shallowsPixels(current, style: style)) as CFData
        guard let provider = CGDataProvider(data: data),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: grid.columns, height: grid.rows, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: grid.columns * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { preconditionFailure("the shallows' \(grid.columns) × \(grid.rows) image") }
        return image
    }

    /// The hatched band, then the solid line over it.
    private func buildBoundary() -> [SKNode] {
        let area = course.raceArea
        let hatch = CGMutablePath()
        for segment in ChartGeometry.hatch(around: area, width: style.hatchWidth, spacing: style.hatchSpacing) {
            hatch.move(to: point(segment.a))
            hatch.addLine(to: point(segment.b))
        }
        let band = SKShapeNode(path: hatch)
        band.strokeColor = ChartPalette.boundary.uiColor.withAlphaComponent(style.hatchAlpha)
        band.lineCap = .butt
        strokes.append((band, style.hatchLineWidth))

        let outline = CGMutablePath()
        outline.addLines(between: area.corners.map(point))
        outline.closeSubpath()
        let line = SKShapeNode(path: outline)
        line.strokeColor = ChartPalette.boundary.uiColor
        line.lineJoin = .miter
        strokes.append((line, style.boundaryLineWidth))
        return [band, line]
    }

    /// Every land polygon in one fill, so pieces that share an edge (Fellmere) show no seam, then the relief bands,
    /// grouped by tone and strength.
    private func buildLand() -> [SKNode] {
        let polygons = venue.land.map(\.points)
        guard !polygons.isEmpty else { return [] }
        let fill = CGMutablePath()
        for points in polygons {
            fill.addLines(between: points.map(point))
            fill.closeSubpath()
        }
        let ground = SKShapeNode(path: fill)
        ground.fillColor = ChartPalette.land.uiColor
        ground.strokeColor = .clear
        ground.lineWidth = 0

        let strips = ChartGeometry.relief(of: polygons, depth: style.reliefDepth, steps: style.reliefSteps,
                                          light: style.lightBearing)
        // Six levels of strength each way: a handful of nodes, however long the coast.
        let levels = 6
        var buckets: [Int: CGMutablePath] = [:]
        for strip in strips {
            let level = Int((strip.weight * Double(levels)).rounded())
            guard level > 0 else { continue }
            let key = (strip.isLit ? 1 : -1) * level
            let path = buckets[key] ?? CGMutablePath()
            path.addLines(between: strip.corners.map(point))
            path.closeSubpath()
            buckets[key] = path
        }
        let relief = buckets.keys.sorted().map { key -> SKNode in
            let node = SKShapeNode(path: buckets[key]!)
            let tone = key > 0 ? ChartPalette.landLit : ChartPalette.landShade
            node.fillColor = tone.uiColor.withAlphaComponent(CGFloat(style.reliefAlpha * Double(abs(key)) / Double(levels)))
            node.strokeColor = .clear
            node.lineWidth = 0
            return node
        }
        return [ground] + relief
    }

    private func buildLandmarks() -> [SKNode] {
        venue.landmarks.map { landmark in
            let node = SKShapeNode(path: LandmarkSilhouette.named(landmark.asset).path(size: CGFloat(style.landmarkSize) * ppm))
            node.fillColor = ChartPalette.landmark.uiColor
            node.strokeColor = .clear
            node.lineWidth = 0
            node.position = point(landmark.position)
            return node
        }
    }

    /// Each buoy's zone, arrow and body; the gate's connector; the pin, committee boat and its flag; the start line
    /// last, over the line's ends.
    private func buildMarks(in courseLayer: SKNode) {
        let zoneRadius = CGFloat(course.zoneRadius) * ppm
        for buoy in ChartMarks.buoys(of: course) {
            let zone = SKShapeNode(circleOfRadius: zoneRadius)
            if let circle = zone.path { dash(zone, circle) }
            zone.position = point(buoy.mark.position)
            strokes.append((zone, style.cueLineWidth))

            let arrow = SKShapeNode(path: arrowPath(for: buoy))
            arrow.lineCap = .round
            arrow.lineJoin = .round
            strokes.append((arrow, style.cueLineWidth))

            let body = markBody(buoy.mark)
            buoys.append(BuoyNodes(buoy: buoy, zone: zone, arrow: arrow, body: body))
            [zone, arrow, body].forEach(courseLayer.addChild)
        }

        let gates = buoys.filter { if case .gate = course.elements[$0.buoy.element] { true } else { false } }
        if gates.count == 2 {
            let connector = CGMutablePath()
            connector.move(to: point(gates[0].buoy.mark.position))
            connector.addLine(to: point(gates[1].buoy.mark.position))
            dash(gateConnector, connector)
            strokes.append((gateConnector, style.cueLineWidth))
            courseLayer.addChild(gateConnector)
        }

        let pin = markBody(course.startLine.pin)
        let committee = SKShapeNode(ellipseOf: CGSize(width: style.committeeHull.width * ppm,
                                                      height: style.committeeHull.height * ppm))
        committee.position = point(course.startLine.committee.position)
        // The flag is the course layer's own node, not the committee boat's child, so it takes a z of its own.
        let flag = SKShapeNode(rect: CGRect(x: -3, y: -3, width: 10, height: 7))
        flag.position = committee.position
        for node in [committee, flag] {
            strokes.append((node, style.markEdgeWidth))
            node.strokeColor = ChartPalette.markEdge.uiColor
        }
        lineEnds = [pin, committee, flag]
        lineEnds.forEach(courseLayer.addChild)

        let line = CGMutablePath()
        line.move(to: point(course.startLine.pin.position))
        line.addLine(to: point(course.startLine.committee.position))
        dash(startLine, line)
        strokes.append((startLine, style.cueLineWidth))
        courseLayer.addChild(startLine)

        // A z each (`DrawOrder`), in the order built: the start line crosses the pin and the committee boat, and
        // draws over them.
        for (slot, node) in courseLayer.children.enumerated() {
            node.zPosition = DrawOrder.z(slot)
        }
    }

    private func markBody(_ mark: CourseLayout.Mark) -> SKShapeNode {
        let node = SKShapeNode(circleOfRadius: max(CGFloat(mark.radius) * ppm, style.minimumBuoyRadius))
        node.strokeColor = ChartPalette.markEdge.uiColor
        node.position = point(mark.position)
        strokes.append((node, style.markEdgeWidth))
        return node
    }

    private func arrowPath(for buoy: ChartMarks.Buoy) -> CGPath {
        let arrow = RoundingArrow(around: buoy.mark.position, approach: buoy.approach, side: buoy.side,
                                  radius: course.zoneRadius * style.arrowRadiusFraction, sweep: style.arrowSweep)
        let path = CGMutablePath()
        path.addLines(between: arrow.arc().map(point))
        let tip = point(arrow.point(at: arrow.endAngle))
        for barb in arrow.barbs(length: style.arrowHead) {
            path.move(to: tip)
            path.addLine(to: point(barb))
        }
        return path
    }

    // MARK: - Frame

    /// What the chart fixtures' area camera frames beside the course (`CameraRig.Mode.northUpArea`): the race area's
    /// corners and the venue's landmarks, so the boundary and the land show.
    var framing: [Vec2] {
        course.raceArea.corners + venue.landmarks.map(\.position)
    }

    /// Styles the marks for your boat's `status` and leg (only when the active set changes), and keeps the strokes'
    /// widths steady on screen at the camera's `cameraScale`.
    func update(status: BoatStatus, legIndex: Int, cameraScale: CGFloat) {
        let leg = ChartMarks.leg(in: course, status: status, legIndex: legIndex)
        let key = StyleKey(leg: leg, lineActive: ChartMarks.isLineActive(status: status, leg: leg))
        if key != styled {
            styled = key
            restyle(status: status, legIndex: legIndex, lineActive: key.lineActive)
        }
        if let strokeScale, abs(cameraScale - strokeScale) <= style.rescaleThreshold * strokeScale { return }
        rescale(cameraScale)
    }

    private func restyle(status: BoatStatus, legIndex: Int, lineActive: Bool) {
        for nodes in buoys {
            let active = ChartMarks.isActive(nodes.buoy.mark, in: course, status: status, legIndex: legIndex)
            let tone = ChartMarks.tone(isActive: active).uiColor
            nodes.body.fillColor = tone
            nodes.zone.strokeColor = tone
            nodes.arrow.strokeColor = tone
            // Inactive marks have no zone and no arrow (#15).
            nodes.zone.isHidden = !active
            nodes.arrow.isHidden = !active
        }
        let gateActive = buoys.contains {
            if case .gate = course.elements[$0.buoy.element] {
                ChartMarks.isActive($0.buoy.mark, in: course, status: status, legIndex: legIndex)
            } else { false }
        }
        gateConnector.strokeColor = ChartMarks.tone(isActive: gateActive).uiColor
        let lineTone = ChartMarks.tone(isActive: lineActive).uiColor
        for node in lineEnds { node.fillColor = lineTone }
        startLine.strokeColor = lineTone
    }

    private func rescale(_ scale: CGFloat) {
        strokeScale = scale
        for (node, width) in strokes { node.lineWidth = width * scale }
        dashPattern = style.dashes(atCameraScale: scale)
        for (node, path) in dashed { node.path = path.copy(dashingWithPhase: 0, lengths: dashPattern) }
    }

    /// Draws `node` as `path` dashed, now and at every rescale.
    private func dash(_ node: SKShapeNode, _ path: CGPath) {
        dashed.append((node, path))
        node.path = path.copy(dashingWithPhase: 0, lengths: dashPattern)
    }

    // MARK: - Tests

    /// Whether the marks drawn active (their zones showing) are exactly `marks`, for a test.
    var activeBuoys: [CourseLayout.Mark] {
        buoys.filter { !$0.zone.isHidden }.map(\.buoy.mark)
    }

    var lineIsActive: Bool { styled?.lineActive ?? false }
}

private extension OKLab {
    var uiColor: UIColor {
        let c = srgb
        return UIColor(red: CGFloat(c[0]), green: CGFloat(c[1]), blue: CGFloat(c[2]), alpha: 1)
    }
}
