import RegattaCore
import SwiftUI

/// The briefing's tide graph (#130, ADR 0003): the channel current at the deepest water from the start sequence to
/// the time limit, flood above the middle and ebb below, with the gun, each slack (a ring on the middle line) and each
/// peak (a dot), and when the tide turns first (a dashed line).
struct BriefingTideGraph: View {
    let tide: BriefingModel.TideSummary

    var body: some View {
        Canvas { context, size in
            let window = tide.window
            let span = Double(max(1, window.upperBound - window.lowerBound))
            let scale = max(tide.peakKnots, 0.1)
            let inset: CGFloat = 14
            let plot = CGRect(x: 4, y: inset, width: size.width - 8, height: size.height - 2 * inset)
            func x(_ tick: Int) -> CGFloat { plot.minX + plot.width * CGFloat(Double(tick - window.lowerBound) / span) }
            func y(_ knots: Double) -> CGFloat { plot.midY - plot.height / 2 * CGFloat(knots / scale) }

            let line = ChromePalette.text
            var axis = Path()
            axis.move(to: CGPoint(x: plot.minX, y: plot.midY))
            axis.addLine(to: CGPoint(x: plot.maxX, y: plot.midY))
            context.stroke(axis, with: .color(line.opacity(0.4)), lineWidth: 1)

            if window.contains(0) {
                var gun = Path()
                gun.move(to: CGPoint(x: x(0), y: plot.minY - 6))
                gun.addLine(to: CGPoint(x: x(0), y: plot.maxY + 6))
                context.stroke(gun, with: .color(line.opacity(0.6)), lineWidth: 1)
                context.draw(Text("Gun").font(MenuFont.body(.caption2)), at: CGPoint(x: x(0) + 3, y: 2), anchor: .topLeading)
            }
            if let tick = tide.turnsFirstTick {
                var first = Path()
                first.move(to: CGPoint(x: x(tick), y: plot.minY))
                first.addLine(to: CGPoint(x: x(tick), y: plot.maxY))
                context.stroke(first, with: .color(ChromePalette.tint), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }

            var area = Path()
            area.move(to: CGPoint(x: plot.minX, y: plot.midY))
            for sample in tide.samples { area.addLine(to: CGPoint(x: x(sample.tick), y: y(sample.knots))) }
            area.addLine(to: CGPoint(x: plot.maxX, y: plot.midY))
            area.closeSubpath()
            context.fill(area, with: .color(ChromePalette.tint.opacity(0.25)))

            var curve = Path()
            for (index, sample) in tide.samples.enumerated() {
                let p = CGPoint(x: x(sample.tick), y: y(sample.knots))
                if index == 0 { curve.move(to: p) } else { curve.addLine(to: p) }
            }
            context.stroke(curve, with: .color(ChromePalette.tint), lineWidth: 2)

            for event in tide.events {
                switch event.turn {
                case .slackBeforeFlood, .slackBeforeEbb:
                    let p = CGPoint(x: x(event.tick), y: plot.midY)
                    let ring = Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
                    context.fill(ring, with: .color(ChromePalette.background))
                    context.stroke(ring, with: .color(line), lineWidth: 1.5)
                case .peakFlood, .peakEbb:
                    let p = CGPoint(x: x(event.tick), y: y(event.turn == .peakFlood ? tide.peakKnots : -tide.peakKnots))
                    context.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(line))
                }
            }

            context.draw(Text("Flood").font(MenuFont.body(.caption2)), at: CGPoint(x: plot.maxX, y: plot.minY),
                         anchor: .topTrailing)
            context.draw(Text("Ebb").font(MenuFont.body(.caption2)), at: CGPoint(x: plot.maxX, y: plot.maxY),
                         anchor: .bottomTrailing)
        }
        .accessibilityElement()
        .accessibilityLabel("Tide forecast graph")
        .accessibilityIdentifier("briefing-tide-graph")
    }
}
