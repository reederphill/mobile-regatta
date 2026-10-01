import CoreGraphics
import Foundation

/// The landmark silhouettes on a venue's land (#22, #115), looked up by the venue file's asset name
/// (`Venue.Landmark.asset`). Flat vectors in `ChartPalette.landmark`, drawn by code until the art lands.
// placeholder: vector stand-ins until #169 swaps in the assets-manifest silhouettes; replace `table` and `path`.
nonisolated enum LandmarkSilhouette: String, CaseIterable, Sendable {
    case lighthouse, clubhouse, treeClump, seaWall, boathouse, pineStand, churchSpire
    /// An asset name the table doesn't know: a plain marker, never a crash.
    case generic

    /// Every bundled venue's landmark asset names, each to its silhouette (`ChartVenueTests` checks none is
    /// missing).
    static let table: [String: LandmarkSilhouette] = [
        "dev-lighthouse": .lighthouse,
        "dev-clubhouse": .clubhouse,
        "landmark-hollin-bay-clubhouse": .clubhouse,
        "landmark-hollin-bay-lighthouse": .lighthouse,
        "landmark-hollin-bay-tree-clump": .treeClump,
        "landmark-saltings-reach-sea-wall": .seaWall,
        "landmark-saltings-reach-boathouse": .boathouse,
        "landmark-fellmere-boathouse": .boathouse,
        "landmark-fellmere-pine-stand": .pineStand,
        "landmark-fellmere-church-spire": .churchSpire,
    ]

    /// The silhouette for `asset`, or `.generic` for a name the table doesn't hold.
    static func named(_ asset: String) -> LandmarkSilhouette {
        table[asset] ?? .generic
    }

    /// The silhouette `size` points across, centred on the origin, seen from above, north up.
    func path(size: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let s = size
        func polygon(_ points: [(CGFloat, CGFloat)]) {
            path.addLines(between: points.map { CGPoint(x: $0.0 * s, y: $0.1 * s) })
            path.closeSubpath()
        }
        func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) {
            path.addEllipse(in: CGRect(x: (x - r) * s, y: (y - r) * s, width: 2 * r * s, height: 2 * r * s))
        }
        switch self {
        case .lighthouse:
            // A round tower and its gallery, with a beam each way.
            circle(0, 0, 0.18)
            polygon([(-0.5, -0.04), (-0.22, -0.04), (-0.22, 0.04), (-0.5, 0.04)])
            polygon([(0.22, -0.04), (0.5, -0.04), (0.5, 0.04), (0.22, 0.04)])
        case .clubhouse:
            // An L-shaped roof plan with a flagstaff's dot.
            polygon([(-0.45, -0.3), (0.45, -0.3), (0.45, 0.05), (-0.05, 0.05), (-0.05, 0.3), (-0.45, 0.3)])
            circle(0.3, 0.3, 0.08)
        case .treeClump:
            // Apart, not overlapping: one path's overlaps could cancel under its fill rule.
            circle(-0.25, -0.15, 0.18)
            circle(0.22, -0.18, 0.18)
            circle(0, 0.22, 0.2)
        case .seaWall:
            polygon([(-0.5, -0.06), (0.5, -0.06), (0.5, 0.06), (-0.5, 0.06)])
        case .boathouse:
            // A long shed with its slipway.
            polygon([(-0.25, -0.1), (0.25, -0.1), (0.25, 0.45), (-0.25, 0.45)])
            polygon([(-0.12, -0.5), (0.12, -0.5), (0.12, -0.1), (-0.12, -0.1)])
        case .pineStand:
            for (x, y) in [(-0.25, -0.2), (0.2, -0.25), (0, 0.15), (0.3, 0.25), (-0.3, 0.25)] as [(CGFloat, CGFloat)] {
                polygon([(x, y + 0.2), (x - 0.15, y - 0.12), (x + 0.15, y - 0.12)])
            }
        case .churchSpire:
            // A cross-shaped plan and its spire's point.
            polygon([(-0.1, -0.5), (0.1, -0.5), (0.1, 0.1), (0.35, 0.1), (0.35, 0.3), (0.1, 0.3), (0.1, 0.5),
                      (-0.1, 0.5), (-0.1, 0.3), (-0.35, 0.3), (-0.35, 0.1), (-0.1, 0.1)])
        case .generic:
            polygon([(0, 0.3), (0.3, 0), (0, -0.3), (-0.3, 0)])
        }
        return path
    }
}
