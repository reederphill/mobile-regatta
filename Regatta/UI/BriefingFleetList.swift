import RegattaCore
import SwiftUI

/// The briefing's fleet list (#130, #21, #19): each boat's large livery render, its name, and its rating or, for a bot,
/// the bot glyph. Yours is marked; a practice rival has the word "Rival" beside her name (#235, `RivalMark`).
struct BriefingFleetList: View {
    let rows: [BriefingModel.FleetRow]

    /// A row's render: the large render (`LiveryRenderView`) at a list's size.
    static let renderSize = CGSize(width: 128, height: 60)

    var body: some View {
        VStack(spacing: 8) {
            ForEach(rows) { row in
                HStack(spacing: 12) {
                    LiveryRenderView(livery: row.livery, size: Self.renderSize)
                        .clipShape(.rect(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            if row.isBot {
                                Image(systemName: BotGlyph.symbolName)
                                    .font(MenuFont.body(.subheadline))
                                    .accessibilityLabel("Bot")
                            }
                            Text(row.name)
                                .font(row.isMe ? MenuFont.heading(.headline) : MenuFont.body())
                                .lineLimit(1)
                                .layoutPriority(1)
                            if row.isRival {
                                Text(RivalMark.word)
                                    .font(MenuFont.body(.caption))
                                    .foregroundStyle(ChromePalette.text.opacity(0.7))
                                    .lineLimit(1)
                                    .accessibilityIdentifier("briefing-rival-\(row.seat)")
                            }
                        }
                        if let rating = row.rating {
                            Text(rating).font(MenuFont.number(.subheadline))
                        }
                    }
                    Spacer(minLength: 0)
                    Text(String(row.livery.sailNumber))
                        .font(MenuFont.number(.subheadline))
                        .foregroundStyle(ChromePalette.text.opacity(0.7))
                }
                .padding(8)
                .background(row.isMe ? ChromePalette.tint.opacity(0.18) : ChromePalette.surface,
                            in: .rect(cornerRadius: 12))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("briefing-fleet-\(row.seat)")
            }
        }
    }
}
