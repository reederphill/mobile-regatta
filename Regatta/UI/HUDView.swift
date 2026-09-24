import SwiftUI
import RegattaCore

struct HUDView: View {
    let hud: HUDState
    let messages: [RaceMessage]

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    clock
                    targetIndicator
                }
                .padding(.leading, 60)
                Spacer()
                MinimapView(hud: hud)
                    .frame(width: 96, height: 132)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)

            if hud.penaltyTurns > 0 {
                PenaltyBanner(turns: hud.penaltyTurns, progress: hud.penaltyProgress)
            }

            VStack(spacing: 6) {
                ForEach(messages) { message in
                    MessageBubble(message: message)
                }
            }
            .padding(.horizontal, 16)
            .animation(.easeOut(duration: 0.2), value: messages.map(\.id))

            if hud.clock < 0 && hud.clock > -10 {
                Text("\(Int(ceil(-hud.clock)))")
                    .font(.system(size: 64, weight: .black, design: .rounded))
                    .foregroundStyle(Color(uiColor: Palette.startLine))
                    .shadow(radius: 8)
                    .contentTransition(.numericText(countsDown: true))
            }

            Spacer()

            instruments
                .padding(.bottom, 92)
        }
    }

    private var clock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(formatClock(hud.clock))
                .font(.system(size: 30, weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundStyle(hud.clock < 0 ? Color(uiColor: Palette.startLine) : .white)
                // UI tests read the tick to see the race advance at sub-second resolution.
                .accessibilityIdentifier("race-clock")
                .accessibilityValue(String(hud.tick))
            Text(statusLine)
                .font(.caption.weight(.semibold))
                .foregroundStyle(hud.status == .ocs ? .red : .white.opacity(0.8))
        }
    }

    private var statusLine: String {
        switch hud.status {
        case .prestart: hud.clock < 0 ? "Start sequence" : "Not started"
        case .ocs: "OCS — go back"
        case .racing: "\(ordinal(hud.place)) of \(hud.fleet) · leg \(hud.legNumber)/\(hud.legCount)"
        case .finished: "Finished \(ordinal(hud.place))"
        case .dsq: "Disqualified"
        case .dnf: "Did not finish"
        }
    }

    private var targetIndicator: some View {
        HStack(spacing: 6) {
            Image(systemName: "location.north.fill")
                .rotationEffect(.radians(hud.targetBearing))
                .foregroundStyle(Color(uiColor: Palette.mark))
            Text("\(hud.targetName) · \(Int(hud.targetDistance)) m")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.black.opacity(0.3), in: .capsule)
    }

    private var instruments: some View {
        HStack(spacing: 0) {
            Instrument(value: String(format: "%.1f", hud.speedKnots), unit: "kn", label: "Speed")
            Instrument(value: "\(Int(hud.twaDegrees.rounded()))°", unit: hud.tack == .starboard ? "STBD" : "PORT", label: "Wind angle")
            WindGauge(direction: hud.windDirection, shift: hud.windShiftDegrees, knots: hud.windKnots, inShadow: hud.inShadow)
        }
        .padding(.vertical, 8)
        .background(.black.opacity(0.3), in: .rect(cornerRadius: 16))
        .padding(.horizontal, 16)
    }
}

private struct Instrument: View {
    let value: String
    let unit: String
    let label: String

    var body: some View {
        VStack(spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(.title3, design: .rounded).weight(.bold).monospacedDigit())
                Text(unit).font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.6))
            }
            Text(label).font(.caption2).foregroundStyle(.white.opacity(0.6))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
    }
}

private struct WindGauge: View {
    let direction: Double
    let shift: Double
    let knots: Double
    let inShadow: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down")
                .font(.title3.weight(.bold))
                .rotationEffect(.radians(direction))
                .foregroundStyle(inShadow ? .orange : .white)
            VStack(alignment: .leading, spacing: 1) {
                Text(String(format: "%.0f kn", knots))
                    .font(.system(.subheadline, design: .rounded).weight(.bold).monospacedDigit())
                Text(shiftText)
                    .font(.caption2)
                    .foregroundStyle(inShadow ? .orange : .white.opacity(0.6))
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
    }

    private var shiftText: String {
        if inShadow { return "Dirty air" }
        let degrees = Int(shift.rounded())
        if degrees == 0 { return "Mean" }
        return degrees > 0 ? "\(degrees)° right" : "\(-degrees)° left"
    }
}

private struct PenaltyBanner: View {
    let turns: Int
    let progress: Double

    var body: some View {
        VStack(spacing: 6) {
            Text("PENALTY — spin \(turns * 360)°")
                .font(.subheadline.weight(.heavy))
            ProgressView(value: progress)
                .tint(.white)
                .frame(width: 180)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.red.opacity(0.8), in: .rect(cornerRadius: 12))
    }
}

private struct MessageBubble: View {
    let message: RaceMessage

    var body: some View {
        Text(message.text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(background, in: .rect(cornerRadius: 10))
            .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var background: Color {
        switch message.tone {
        case .info: .black.opacity(0.45)
        case .good: Color(red: 0.1, green: 0.5, blue: 0.3).opacity(0.85)
        case .alert: Color(red: 0.75, green: 0.15, blue: 0.15).opacity(0.9)
        }
    }
}
