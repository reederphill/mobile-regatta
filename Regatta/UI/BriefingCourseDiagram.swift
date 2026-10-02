import RegattaCore
import SwiftUI

/// The briefing's course diagram (#130): the race area course-up, wind from the top, on the chart's own tones
/// (`ChartPalette`): water, land, the race area's edge, the buoys grey and the start line orange, as the race draws the
/// line before the start (`ChartMarks.isLineActive`). No other cue colours. At a venue with current, a ring marks where
/// the tide turns first.
struct BriefingCourseDiagram: View {
    let course: CourseLayout
    var turnsFirst: Vec2?

    var body: some View {
        Canvas { context, size in
            let chart = MinimapChart(course: course)
            let rect = chart.rect(in: size)
            let scale = rect.width / (chart.maxU - chart.minU)
            func map(_ p: Vec2) -> CGPoint {
                let (u, v) = chart.courseCoordinates(p)
                return CGPoint(x: rect.minX + (u - chart.minU) * scale, y: rect.maxY - (v - chart.minV) * scale)
            }

            func mark(_ position: Vec2, tone: Color, radius: CGFloat) {
                let p = map(position)
                let circle = Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: 2 * radius, height: 2 * radius))
                context.fill(circle, with: .color(tone))
                context.stroke(circle, with: .color(ChartPalette.markEdge.color), lineWidth: 1)
            }

            context.clip(to: Path(rect))
            context.fill(Path(rect), with: .color(ChartPalette.water.color))
            for polygon in course.land {
                var land = Path()
                land.addLines(polygon.points.map(map))
                land.closeSubpath()
                context.fill(land, with: .color(ChartPalette.land.color))
            }

            var edge = Path()
            edge.addLines(course.raceArea.corners.map(map))
            edge.closeSubpath()
            context.stroke(edge, with: .color(ChartPalette.boundary.color), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

            let lineTone = ChartMarks.tone(isActive: true).color
            var line = Path()
            line.move(to: map(course.startLine.pin.position))
            line.addLine(to: map(course.startLine.committee.position))
            context.stroke(line, with: .color(lineTone), lineWidth: 2)
            for end in [course.startLine.pin, course.startLine.committee] {
                mark(end.position, tone: lineTone, radius: end == course.startLine.committee ? 4.5 : 3.5)
            }

            for element in course.elements {
                for buoy in element.marks {
                    mark(buoy.position, tone: ChartMarks.tone(isActive: false).color, radius: 4)
                }
            }

            if let turnsFirst {
                let p = map(turnsFirst)
                let ring = Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12))
                context.stroke(ring, with: .color(ChartPalette.foam.color), lineWidth: 2)
                context.fill(Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)),
                             with: .color(ChartPalette.foam.color))
            }

            // The wind, down the course from the top.
            let top = CGPoint(x: rect.midX, y: rect.minY + 8)
            var arrow = Path()
            arrow.move(to: top)
            arrow.addLine(to: CGPoint(x: top.x, y: top.y + 22))
            arrow.move(to: CGPoint(x: top.x - 5, y: top.y + 15))
            arrow.addLine(to: CGPoint(x: top.x, y: top.y + 22))
            arrow.addLine(to: CGPoint(x: top.x + 5, y: top.y + 15))
            context.stroke(arrow, with: .color(ChartPalette.foam.color), lineWidth: 2)
        }
        .clipShape(.rect(cornerRadius: 12))
        .accessibilityElement()
        .accessibilityLabel("Course diagram")
        .accessibilityIdentifier("briefing-course")
    }
}
