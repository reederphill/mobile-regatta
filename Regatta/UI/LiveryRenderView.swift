import RegattaCore
import SwiftUI
import UIKit

/// A livery's large render (#21, #119): the boat seen from above, bow to the right, her sail swung out to show its
/// colour, graphic and number, on the water's tone (menu depictions of on-water elements keep `ChartPalette`, G7).
/// For the editor, the shop, the pre-race briefing's fleet list, the results card and the boat card. Drawn with
/// Core Graphics into a cached image from `LiveryArt`'s shapes, so a list of sixteen costs no SpriteKit view.
struct LiveryRenderView: View {
    let livery: Livery
    var boatClass: BoatClass = RaceFiles.defaults.boatClass.content
    /// The render's size in points.
    var size = LiveryRenderView.defaultSize

    static let defaultSize = CGSize(width: 320, height: 150)

    var body: some View {
        Image(uiImage: LiveryRenderer.image(LiveryArt.Look(livery), hull: boatClass.hull, size: size))
            .resizable()
            .interpolation(.high)
            .frame(width: size.width, height: size.height)
            .clipShape(.rect(cornerRadius: min(size.width, size.height) * 0.08))
            .accessibilityElement()
            .accessibilityLabel("Boat, sail number \(livery.sailNumber)")
    }
}

/// Draws and caches livery renders, one image per look, hull and size.
enum LiveryRenderer {
    /// The sail's swing from the centreline, to starboard (25°).
    static let sailAngle: CGFloat = 25 * .pi / 180
    /// Rendered at 3×, whatever the screen, so a render is the same everywhere.
    static let scale: CGFloat = 3

    private struct Key: Hashable {
        var look: LiveryArt.Look
        var outline: [Double]
        var length: Double
        var beam: Double
        var width: CGFloat
        var height: CGFloat
    }

    private static var cache: [Key: UIImage] = [:]

    static func image(_ look: LiveryArt.Look, hull: BoatClass.Hull, size: CGSize) -> UIImage {
        let key = Key(look: look, outline: hull.outline.flatMap { [$0.x, $0.y] }, length: hull.length, beam: hull.beam,
                      width: size.width, height: size.height)
        if let image = cache[key] { return image }
        let image = draw(look, hull: hull, size: size)
        cache[key] = image
        return image
    }

    /// The water, and the boat fitted inside it with a margin: bow right, starboard down.
    static func draw(_ look: LiveryArt.Look, hull: BoatClass.Hull, size: CGSize) -> UIImage {
        // Measure at one point per metre, then scale the geometry itself, so strokes and text stay crisp.
        let unit = LiveryArt.Geometry(hull: hull, pointsPerMeter: 1)
        let unitBounds = bounds(unit)
        let margin = min(size.width, size.height) * 0.1
        // Boat y runs across the screen, boat x down it.
        let ppm = min((size.width - margin * 2) / unitBounds.height, (size.height - margin * 2) / unitBounds.width)
        let g = LiveryArt.Geometry(hull: hull, pointsPerMeter: ppm)
        let box = bounds(g)

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            cg.setFillColor(ChartPalette.water.uiColor.cgColor)
            cg.fill(CGRect(origin: .zero, size: size))
            cg.translateBy(x: size.width / 2, y: size.height / 2)
            cg.concatenate(CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0))
            cg.translateBy(x: -box.midX, y: -box.midY)
            LiveryArt.draw(look, g, sailAngle: sailAngle, outlineWidth: max(1, g.beam * 0.03), in: cg)
        }
    }

    /// The hull and the swung sail's bounds in boat space.
    private static func bounds(_ g: LiveryArt.Geometry) -> CGRect {
        var swing = CGAffineTransform(translationX: g.mast.x, y: g.mast.y).rotated(by: sailAngle)
        let sail = g.sail.copy(using: &swing) ?? g.sail
        return g.hull.boundingBoxOfPath.union(sail.boundingBoxOfPath)
    }
}
