import RegattaServices
import SwiftUI

struct ResultsView: View {
    let rows: [ResultRow]
    /// A new race (#25): through its briefing, for practice.
    var onSailAgain: () -> Void
    /// Back to the practice setup (#25), or nil to leave it out.
    var onChangeSetup: (() -> Void)? = nil
    /// Home.
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
                                LiveryChipView(chip: LiveryChip(row.livery), diameter: 14)
                                Text(String(row.livery.sailNumber))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 36, alignment: .leading)
                                    .accessibilityLabel("Sail number \(row.livery.sailNumber)")
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
                            // UI tests count the rows.
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("results-row")
                        }
                    }
                }
                .frame(maxHeight: 420)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { buttons }
                    VStack(spacing: 10) { buttons }
                }
                .controlSize(.large)
            }
            .padding(24)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 24))
            .padding(20)
        }
    }

    @ViewBuilder private var buttons: some View {
        Button("Menu", action: onExit)
            .buttonStyle(.bordered)
            .accessibilityIdentifier("results-menu")
        if let onChangeSetup {
            Button("Change setup", action: onChangeSetup)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("results-changeSetup")
        }
        Button("Sail again", action: onSailAgain)
            .buttonStyle(.borderedProminent)
            .tint(ChromePalette.tint)
            .accessibilityIdentifier("results-sailAgain")
    }
}
