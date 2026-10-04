import RegattaServices
import SwiftUI

/// The results (#24, #132): a row per boat, then the Your race card, then the buttons. Over a race it is a sheet
/// anchored to the bottom, about 60% of the height with a solid button bar, with no dim: the race keeps running and drawing above it, and
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

    /// The share of the screen's height the sheet takes, measured with the bottom safe area, which the sheet fills.
    static let heightFraction = 0.62

    var body: some View {
        switch presentation {
        case .overRace:
            GeometryReader { proxy in
                let insets = proxy.safeAreaInsets
                let screenHeight = proxy.size.height + insets.top + insets.bottom
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    panel(bottomInset: insets.bottom)
                        .frame(maxWidth: 640)
                        .frame(height: min(screenHeight * Self.heightFraction, proxy.size.height + insets.bottom))
                        .background(.ultraThinMaterial,
                                    in: UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24))
                }
                .frame(maxWidth: .infinity)
                // The sheet runs to the screen's bottom edge; the button bar keeps its buttons above the home indicator.
                .ignoresSafeArea(edges: .bottom)
            }
            .transition(.move(edge: .bottom))
        case .page:
            panel(bottomInset: 0)
                .background(ChromePalette.background.ignoresSafeArea())
        }
    }

    /// The title, then the rows and the card scrolling between it and a solid button bar, which never covers them.
    private func panel(bottomInset: CGFloat) -> some View {
        VStack(spacing: 0) {
            // TODO-COPY (#171)
            Text("Results").font(.title2.bold())
                // UI tests wait for it: the results are up.
                .accessibilityIdentifier("race-results")
                .padding(.top, 14)
                .padding(.bottom, 8)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.rows) { row in
                        ResultRowView(row: row)
                    }
                    if let card = model.card {
                        YourRaceCardView(card: card)
                            .padding(.top, 12)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            VStack(spacing: 0) {
                Divider()
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { buttonRow }
                    VStack(spacing: 10) { buttonRow }
                }
                .controlSize(.large)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 10 + bottomInset)
            }
            .background(ChromePalette.surface.ignoresSafeArea(edges: .bottom))
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
            Button(action: sailAgain) { PrimaryLabel(title: "Sail again") }
                .buttonStyle(.borderedProminent)
                .tint(ChromePalette.tint)
                .accessibilityIdentifier("results-sailAgain")
        case .firstRace(let raceOnline, let help):
            Button("Help", action: help)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("results-help")
            Button(action: raceOnline) { PrimaryLabel(title: "Race online") }
                .buttonStyle(.borderedProminent)
                .tint(ChromePalette.tint)
                .accessibilityIdentifier("results-raceOnline")
        case .reopened(let close):
            Button(action: close) { PrimaryLabel(title: "Close") }
                .buttonStyle(.borderedProminent)
                .tint(ChromePalette.tint)
                .accessibilityIdentifier("results-close")
        }
    }
}

/// A prominent button's title in `onTint`: the inherited text colour (white in dark mode) is unreadable on the pale
/// dark-mode tint, and the menu's navy text on the light-mode navy.
private struct PrimaryLabel: View {
    let title: String

    var body: some View {
        Text(title).foregroundStyle(ChromePalette.onTint)
    }
}

/// One boat's row (#24): place, livery chip and sail number, the bot glyph and name, "Rival" for a practice rival
/// (#235), ⚑, the result. On a rival's row the name keeps priority over the word at 375 pt; other rows lay out as
/// they always have.
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
                .layoutPriority(row.isRival ? 1 : 0)
            if row.isRival {
                Text(RivalMark.word)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("results-rival")
            }
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
        .padding(.vertical, 4)
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
        VStack(alignment: .leading, spacing: 6) {
            // TODO-COPY (#171)
            Text("Your race").font(.headline)
            ForEach(Array(phrases.enumerated()), id: \.offset) { _, phrase in
                Text(phrase).font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.08), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("results-yourRace")
    }
}
