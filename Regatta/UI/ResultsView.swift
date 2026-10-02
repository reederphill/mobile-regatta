import RegattaServices
import SwiftUI

/// The results (#24, #132): a row per boat, then the Your race card, then the buttons. Over a race it is a sheet
/// anchored to the bottom, about 60% of the height, with no dim: the race keeps running and drawing above it, and
/// touches above it still steer your boat. Reopened from home's Last race it fills its own sheet (`.page`).
struct ResultsView: View {
    let model: RaceResultViewModel
    let buttons: Buttons
    var presentation: Presentation = .overRace

    /// The buttons under the results (#24, #25).
    enum Buttons {
        /// A practice race: Home, Change setup (nil leaves it out, as online today) and Sail again.
        case practice(home: () -> Void, changeSetup: (() -> Void)?, sailAgain: () -> Void)
        /// The first race (#134 sets it): Race online, the primary, and Help.
        case firstRace(raceOnline: () -> Void, help: () -> Void)
        /// The last race reopened from home: Close only (ruling 3, #132).
        case reopened(close: () -> Void)
    }

    enum Presentation {
        case overRace
        case page
    }

    /// The share of the race's height the sheet takes.
    static let heightFraction = 0.6

    var body: some View {
        switch presentation {
        case .overRace:
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    panel
                        .frame(maxWidth: 640)
                        .frame(height: proxy.size.height * Self.heightFraction)
                        .background(.ultraThinMaterial,
                                    in: UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24))
                }
                .frame(maxWidth: .infinity)
            }
            .transition(.move(edge: .bottom))
        case .page:
            panel
                .background(ChromePalette.background.ignoresSafeArea())
        }
    }

    private var panel: some View {
        VStack(spacing: 12) {
            // TODO-COPY (#171)
            Text("Results").font(.title2.bold())
                // UI tests wait for it: the results are up.
                .accessibilityIdentifier("race-results")
                .padding(.top, 16)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.rows) { row in
                        ResultRowView(row: row)
                    }
                    if let card = model.card {
                        YourRaceCardView(card: card)
                            .padding(.top, 16)
                    }
                }
                .padding(.horizontal, 12)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { buttonRow }
                VStack(spacing: 10) { buttonRow }
            }
            .controlSize(.large)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    // TODO-COPY (#171): every button title.
    @ViewBuilder private var buttonRow: some View {
        switch buttons {
        case .practice(let home, let changeSetup, let sailAgain):
            Button("Home", action: home)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("results-menu")
            if let changeSetup {
                Button("Change setup", action: changeSetup)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("results-changeSetup")
            }
            Button("Sail again", action: sailAgain)
                .buttonStyle(.borderedProminent)
                .tint(ChromePalette.tint)
                .accessibilityIdentifier("results-sailAgain")
        case .firstRace(let raceOnline, let help):
            Button("Help", action: help)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("results-help")
            Button("Race online", action: raceOnline)
                .buttonStyle(.borderedProminent)
                .tint(ChromePalette.tint)
                .accessibilityIdentifier("results-raceOnline")
        case .reopened(let close):
            Button("Close", action: close)
                .buttonStyle(.borderedProminent)
                .tint(ChromePalette.tint)
                .accessibilityIdentifier("results-close")
        }
    }
}

/// One boat's row (#24): place, livery chip and sail number, the bot glyph and name, ⚑, the result.
private struct ResultRowView: View {
    let row: RaceResultViewModel.Row

    var body: some View {
        HStack(spacing: 10) {
            Text(String(row.place))
                .font(.headline.monospacedDigit())
                .frame(width: 32, alignment: .leading)
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
            Text(row.name)
                .font(.body.weight(row.isPlayer ? .bold : .regular))
                .lineLimit(1)
            if row.flagged {
                Text("⚑")
                    .foregroundStyle(ChromePalette.flagYellow)
                    // TODO-COPY (#171)
                    .accessibilityLabel("Rule call against")
                    .accessibilityIdentifier("results-flag")
            }
            Spacer(minLength: 8)
            Text(row.result.text)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(row.isPlayer ? Color.white.opacity(0.12) : .clear, in: .rect(cornerRadius: 8))
        // UI tests count the rows.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("results-row")
    }
}

/// The Your race card (#24): one short phrase per call against you, call in your favour, and protest of yours. The
/// model leaves the card out when nothing involved you.
private struct YourRaceCardView: View {
    let card: YourRaceCard

    private var phrases: [String] {
        card.against.map(\.phrase) + card.inFavour.map(\.phrase) + card.protests.map(\.phrase)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // TODO-COPY (#171)
            Text("Your race").font(.headline)
            ForEach(Array(phrases.enumerated()), id: \.offset) { _, phrase in
                Text(phrase).font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white.opacity(0.08), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("results-yourRace")
    }
}
