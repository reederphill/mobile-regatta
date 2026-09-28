import SwiftUI
import RegattaCore

/// Whole-course overview: the wind (`MinimapWind`), marks, start line and every boat. It is a small chart of the
/// water, on the water's own colour, so a puff reads darker and a lull lighter just as they do on the water (#224:
/// the wind off screen shows here, not at the view's edges).
struct MinimapView: View {
    let hud: HUDState

    var body: some View {
        Canvas { context, size in
            guard let course = hud.course else { return }
            let points = course.obstacles.map(\.position)
            let minX = (points.map(\.x).min() ?? 0) - 60, maxX = (points.map(\.x).max() ?? 0) + 60
            let minY = (points.map(\.y).min() ?? 0) - 110, maxY = (points.map(\.y).max() ?? 0) + 40
            let scale = min(size.width / (maxX - minX), size.height / (maxY - minY))
            let offsetX = (size.width - (maxX - minX) * scale) / 2
            let offsetY = (size.height - (maxY - minY) * scale) / 2

            func map(_ p: Vec2) -> CGPoint {
                CGPoint(x: offsetX + (p.x.clamped(to: minX...maxX) - minX) * scale,
                        y: size.height - offsetY - (p.y.clamped(to: minY...maxY) - minY) * scale)
            }

            // The wind, under everything else: one field over the whole chart, a pixel every two points, drawn
            // smoothly stretched. The chart's world rect, beyond the course's padded bounds where the aspect leaves
            // room, so a puff beyond the course lies partly or wholly off the chart.
            let world = CGRect(x: CGFloat(minX) - offsetX / scale, y: CGFloat(minY) - offsetY / scale,
                               width: size.width / scale, height: size.height / scale)
            if let wind = MinimapWind.image(puffs: hud.puffs, world: world, width: Int((size.width / 2).rounded(.up)),
                                            height: Int((size.height / 2).rounded(.up)), style: .standard) {
                context.draw(Image(decorative: wind, scale: 1).interpolation(.high), in: CGRect(origin: .zero, size: size))
            }

            var line = Path()
            line.move(to: map(course.startLine.pin.position))
            line.addLine(to: map(course.startLine.committee.position))
            context.stroke(line, with: .color(.white.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))

            for mark in course.elements.flatMap(\.marks) {
                let p = map(mark.position)
                context.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(CuePalette.orange.color))
            }

            for boat in hud.boats where !boat.isPlayer {
                let p = map(boat.position)
                context.fill(Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)),
                             with: .color(Palette.boatColor(boat.colorIndex).opacity(boat.isActive ? 1 : 0.35)))
            }
            if let me = hud.boats.first(where: \.isPlayer) {
                let p = map(me.position)
                let rect = CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)
                context.fill(Path(ellipseIn: rect), with: .color(Palette.boatColor(me.colorIndex)))
                context.stroke(Path(ellipseIn: rect), with: .color(.white), lineWidth: 1.5)
            }
        }
        .background(ChartPalette.water.color, in: .rect(cornerRadius: 12))
        .clipShape(.rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.3), lineWidth: 1))
    }
}
