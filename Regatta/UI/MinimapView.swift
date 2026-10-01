import SwiftUI
import RegattaCore

/// The whole race area, always course-up (#15, #114): the pressure, the race area's edge, the marks and every boat.
/// It is a small chart of the water, on the water's own colour, the pressure over it in the water's tones (#289:
/// sampled from the model's own field, as the water draws it), so more pressure reads darker and less lighter just as
/// on the water: the wind off screen shows here, not at the view's edges (#224, ADR 0008).
///
/// The marks of the leg you're sailing are orange and the rest grey (#22, G7). Boats are in their livery colour
/// (`Palette.boatColor`, the hulls' own source): a person a dot, a bot a diamond (#19: marked by shape, not a new
/// hue), you larger with a white ring, and ghosts faded (#30).
struct MinimapView: View {
    let hud: HUDState

    var body: some View {
        Canvas { context, size in
            guard let course = hud.course else { return }
            let chart = MinimapChart(course: course)
            func map(_ p: Vec2) -> CGPoint { chart.point(p, in: size) }

            // Under everything else: a pixel a sample, stretched smoothly over the chart.
            if let image = hud.pressureImage {
                context.draw(Image(decorative: image, scale: 1).interpolation(.high), in: chart.rect(in: size))
            }

            var edge = Path()
            edge.addLines(course.raceArea.corners.map(map))
            edge.closeSubpath()
            context.stroke(edge, with: .color(.white.opacity(0.6)), lineWidth: 1)

            let active = CuePalette.orange.color, inactive = CuePalette.inactiveGrey.color
            var line = Path()
            line.move(to: map(course.startLine.pin.position))
            line.addLine(to: map(course.startLine.committee.position))
            context.stroke(line, with: .color(hud.lineIsActive ? active : inactive),
                           style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))

            for mark in course.elements.flatMap(\.marks) {
                let p = map(mark.position)
                let colour = hud.activeMarks.contains(mark.position) ? active : inactive
                context.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(colour))
            }

            for boat in hud.boats where !boat.isPlayer {
                let p = map(boat.position)
                let colour = Palette.boatColor(boat.colorIndex).opacity(boat.isGhost ? 0.35 : 1)
                context.fill(Self.marker(at: p, isBot: boat.isBot), with: .color(colour))
            }
            if let me = hud.boats.first(where: \.isPlayer) {
                let p = map(me.position)
                let rect = CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)
                context.fill(Path(ellipseIn: rect), with: .color(Palette.boatColor(me.colorIndex).opacity(me.isGhost ? 0.35 : 1)))
                context.stroke(Path(ellipseIn: rect), with: .color(.white), lineWidth: 1.5)
            }
        }
        .background(ChartPalette.water.color, in: .rect(cornerRadius: 12))
        .clipShape(.rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.3), lineWidth: 1))
    }

    /// A boat's marker at `p`: a dot for a person, a diamond for a bot (#19).
    static func marker(at p: CGPoint, isBot: Bool) -> Path {
        guard isBot else { return Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)) }
        var path = Path()
        path.addLines([CGPoint(x: p.x, y: p.y - 3), CGPoint(x: p.x + 3, y: p.y), CGPoint(x: p.x, y: p.y + 3),
                       CGPoint(x: p.x - 3, y: p.y)])
        path.closeSubpath()
        return path
    }
}
