import SwiftUI
import RegattaCore

/// Whole-course overview: marks, start line and every boat.
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

            var line = Path()
            line.move(to: map(course.startLine.pin.position))
            line.addLine(to: map(course.startLine.committee.position))
            context.stroke(line, with: .color(.white.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))

            for mark in course.elements.flatMap(\.marks) {
                let p = map(mark.position)
                context.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(Color(uiColor: Palette.mark)))
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
        .background(.black.opacity(0.3), in: .rect(cornerRadius: 12))
    }
}
