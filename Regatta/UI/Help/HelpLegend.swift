import SwiftUI

/// One on-water symbol the Help legend shows (#135, #23): its name and one plain line, as data, apart from its
/// picture (`LegendArt`), so the tutorial (1.2) can reuse the list. Words are the glossary's (CONTEXT.md): the
/// right-of-way glow, not a ⚠ or a chevron; the wind shadow, not a cone.
enum LegendItem: String, CaseIterable, Identifiable, Sendable {
    case vane
    case pinchFoot
    case wake
    case puff
    case lull
    case windShadow
    case layline
    case ladderLine
    case keepClear
    case keepsClearOfYou
    case nextMark
    case otherMark
    case ruleCall
    case penaltyArc

    var id: String { rawValue }

    // TODO-COPY (#171): every legend title.
    var title: String {
        switch self {
        case .vane: "Wind vane"
        case .pinchFoot: "Pinch or foot"
        case .wake: "Wake"
        case .puff: "Puff"
        case .lull: "Lull"
        case .windShadow: "Wind shadow"
        case .layline: "Layline"
        case .ladderLine: "Ladder line"
        case .keepClear: "Red glow"
        case .keepsClearOfYou: "Green glow"
        case .nextMark: "Next mark"
        case .otherMark: "Other marks"
        case .ruleCall: "Rule call"
        case .penaltyArc: "Penalty arc"
        }
    }

    // TODO-COPY (#171): every legend line.
    var line: String {
        switch self {
        case .vane: "Points to the wind. The tick is the groove."
        case .pinchFoot: "You sail above or below the groove."
        case .wake: "Longer wake, faster boat."
        case .puff: "Dark water, more wind."
        case .lull: "Pale water, less wind."
        case .windShadow: "Less wind behind a boat."
        case .layline: "Tack here to reach the mark."
        case .ladderLine: "Boats on one line are level."
        case .keepClear: "You keep clear of her."
        case .keepsClearOfYou: "She keeps clear of you."
        case .nextMark: "Round it on the arrow's side. The ring is its zone."
        case .otherMark: "Not yet."
        case .ruleCall: "A boat broke a rule. The badge is its number."
        case .penaltyArc: "Time left to do your penalty turn."
        }
    }
}

/// The legend: every item's picture, name and line, one row each.
struct HelpLegendView: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach(LegendItem.allCases) { item in
                if item != LegendItem.allCases.first { Divider() }
                LegendRow(item: item)
            }
        }
        .background(ChromePalette.surface, in: .rect(cornerRadius: 16))
    }
}

private struct LegendRow: View {
    let item: LegendItem
    @State private var image: UIImage?

    init(item: LegendItem) {
        self.item = item
        _image = State(initialValue: LegendArt.cached(item))
    }

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.high)
                } else {
                    Color(uiColor: ChartPalette.water.uiColor)
                }
            }
            .frame(width: LegendArt.size.width, height: LegendArt.size.height)
            .clipShape(.rect(cornerRadius: 8))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(MenuFont.heading(.headline))
                Text(item.line)
                    .font(MenuFont.body(.subheadline))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("legend-\(item.rawValue)")
        // Drawn once per item by the race's own renderer, then kept (`LegendArt`).
        .task { if image == nil { image = LegendArt.image(for: item) } }
    }
}
