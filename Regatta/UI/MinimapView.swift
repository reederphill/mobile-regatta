import SwiftUI
import RegattaCore

/// Whole-course overview: the pressure, marks, start line and every boat. It is a small chart of the water, on the
/// water's own colour, the pressure over it in the water's tones (#289: sampled from the model's own field, as the
/// water draws it), so more pressure reads darker and less lighter just as on the water: the wind off screen shows
/// here, not at the view's edges (#224).
struct MinimapView: View {
    let hud: HUDState

    var body: some View {
        Canvas { context, size in
            guard let course = hud.course else { return }
            let chart = MinimapChart(course: course)
            func map(_ p: Vec2) -> CGPoint { chart.point(p, in: size) }

            // Under everything else: a pixel a sample, stretched smoothly over the chart.
            if let image = hud.pressure?.image(style: .standard) {
                context.draw(Image(decorative: image, scale: 1).interpolation(.high), in: chart.rect(in: size))
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
