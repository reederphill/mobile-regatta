import SwiftUI

struct ResultsView: View {
    let rows: [ResultRow]
    var onRestart: () -> Void
    var onExit: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 16) {
                Text("Results").font(.title.bold())
                    // UI tests wait for it: the race reached its finish state.
                    .accessibilityIdentifier("race-results")
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(rows) { row in
                            HStack(spacing: 12) {
                                Text(row.place)
                                    .font(.headline.monospacedDigit())
                                    .frame(width: 40, alignment: .leading)
                                Circle()
                                    .fill(Palette.boatColor(row.colorIndex))
                                    .frame(width: 10, height: 10)
                                if row.isBot {
                                    Image(systemName: BotGlyph.symbolName)
                                        .foregroundStyle(.secondary)
                                        .accessibilityLabel("Bot")
                                }
                                Text(row.name).font(.body.weight(row.isPlayer ? .bold : .regular))
                                Spacer()
                                Text(row.detail)
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 12)
                            .background(row.isPlayer ? Color.white.opacity(0.12) : .clear, in: .rect(cornerRadius: 8))
                        }
                    }
                }
                .frame(maxHeight: 420)
                HStack(spacing: 12) {
                    Button("Menu", action: onExit).buttonStyle(.bordered)
                    Button("Race again", action: onRestart)
                        .buttonStyle(.borderedProminent)
                        .tint(Color(uiColor: Palette.mark))
                }
                .controlSize(.large)
            }
            .padding(24)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 24))
            .padding(20)
        }
    }
}
