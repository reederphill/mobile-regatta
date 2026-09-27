import SwiftUI
import RegattaCore

/// The race HUD. Its colours are held to the reserved-colour rule (#22, G7): the start clock is the cue yellow,
/// and everything else is white on translucent black. Nothing reads by red or green (#5, #15): a notice's tone
/// shows as a symbol.
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
                    .foregroundStyle(CuePalette.yellow.color)
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
                .foregroundStyle(hud.clock < 0 ? CuePalette.yellow.color : .white)
                // UI tests read the tick to see the race advance at sub-second resolution.
                .accessibilityIdentifier("race-clock")
                .accessibilityValue(String(hud.tick))
            Text(statusLine)
                .font(.caption.weight(hud.status == .ocs ? .heavy : .semibold))
                .foregroundStyle(.white.opacity(hud.status == .ocs ? 1 : 0.8))
                // UI tests read the leg (label) to see a rounding, and how far the race has run (value, whole
                // seconds from the gun) to tell a slow simulator from a race that never rounded, in one snapshot.
                .accessibilityIdentifier("race-status")
                .accessibilityValue(String(Int(hud.clock.rounded(.down))))
        }
    }

    private var statusLine: String {
        switch hud.status {
        case .prestart: hud.clock < 0 ? "Start sequence" : "Not started"
        case .ocs: "OCS — go back"
        case .racing: "\(ordinal(hud.place)) of \(hud.fleet) · leg \(hud.legNumber)/\(hud.legCount)"
        case .finished: "Finished \(ordinal(hud.place))"
        case .dsq: "Disqualified"
        }
    }

    private var targetIndicator: some View {
        HStack(spacing: 6) {
            Image(systemName: "location.north.fill")
                .rotationEffect(.radians(hud.targetBearing))
                .foregroundStyle(.white)
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
                // Dimmed in dirty air: less wind reaches you. Orange is the active leg's alone (#22).
                .foregroundStyle(.white.opacity(inShadow ? 0.45 : 1))
            VStack(alignment: .leading, spacing: 1) {
                Text(String(format: "%.0f kn", knots))
                    .font(.system(.subheadline, design: .rounded).weight(.bold).monospacedDigit())
                Text(shiftText)
                    .font(.caption2.weight(inShadow ? .bold : .regular))
                    .foregroundStyle(.white.opacity(inShadow ? 1 : 0.6))
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
        .background(.black.opacity(0.6), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.7), lineWidth: 1.5))
    }
}

private struct MessageBubble: View {
    let message: RaceMessage

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .accessibilityHidden(true)
            }
            Text(message.text)
                .multilineTextAlignment(.center)
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(background, in: .rect(cornerRadius: 10))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// The tone, by shape rather than red or green (#5, #15).
    private var symbol: String? {
        switch message.tone {
        case .info: nil
        case .good: "checkmark.circle.fill"
        case .alert: "exclamationmark.triangle.fill"
        }
    }

    private var background: Color {
        .black.opacity(message.tone == .alert ? 0.7 : 0.45)
    }
}
