import RegattaCore
import SwiftUI

/// A page of Help (#135, #23), each one short screen. The protest picker (#125) and the committee sounds (#126) add
/// their own when they land: Help never describes what the game doesn't have yet.
enum HelpTopic: String, CaseIterable, Identifiable, Codable, Sendable {
    case symbols
    case steering
    case rules
    case current

    var id: String { rawValue }

    // TODO-COPY (#171): every topic title.
    var title: String {
        switch self {
        case .symbols: "On the water"
        case .steering: "Steering"
        case .rules: "Rules"
        case .current: "Current"
        }
    }

    var systemImage: String {
        switch self {
        case .symbols: "water.waves"
        case .steering: "hand.draw"
        case .rules: "flag"
        case .current: "arrow.right.circle"
        }
    }
}

/// One topic's page.
struct HelpTopicView: View {
    let topic: HelpTopic

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                switch topic {
                case .symbols: HelpLegendView()
                case .steering: SteeringHelp()
                case .rules: RulesHelp()
                case .current: CurrentHelp()
                }
            }
            .padding(.vertical, 20)
            .readableColumn()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("help-\(topic.rawValue)")
        }
        .menuBackground()
        .navigationTitle(topic.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A heading and a few plain lines.
private struct HelpSection: View {
    let heading: String
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(heading).font(MenuFont.heading(.headline))
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(MenuFont.body())
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Steering

/// Both steering schemes, with a small picture each, then letting go: the autohelm, the groove, pinch and foot, and
/// the groove tick (#219), and the buttons.
private struct SteeringHelp: View {
    var body: some View {
        // TODO-COPY (#171): every line on this page.
        HStack(alignment: .top, spacing: 16) {
            SchemeCard(title: "Halves", line: "Hold the left or right side to turn that way.") { HalvesDiagram() }
            SchemeCard(title: "Tiller", line: "Touch anywhere and slide sideways.") { TillerDiagram() }
        }
        HelpSection(heading: "Pick one", lines: ["Settings, Steering."])
        HelpSection(heading: "Let go", lines: [
            "Let go and the autohelm sails on for you.",
            "Near the groove, the best angle to sail, it snaps to the groove.",
            "Anywhere else it holds the angle you let go at.",
        ])
        HelpSection(heading: "Pinch and foot", lines: [
            "Pinch: sail above the groove. Foot: sail below it.",
            "The autohelm holds either until you steer again.",
        ])
        HelpSection(heading: "The groove tick", lines: [
            "The tick on your wind vane marks the groove.",
            "On the groove, the vane sits on the tick.",
            "A pinch or foot shows as a short arc from the tick.",
        ])
        HelpSection(heading: "Buttons", lines: [
            "Ease: hold to let the sails out and slow down.",
            "Tack or Gybe: tap to turn through the wind. You come out on the groove.",
            "Steer at any time to take back the helm.",
        ])
        HelpSection(heading: "Zoom", lines: ["Pinch-zoom with two fingers. Double tap with two fingers to reset."])
    }
}

private struct SchemeCard<Diagram: View>: View {
    let title: String
    let line: String
    @ViewBuilder let diagram: () -> Diagram

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            diagram()
                .frame(height: 96)
                .frame(maxWidth: .infinity)
                .background(Color(uiColor: ChartPalette.water.uiColor), in: .rect(cornerRadius: 10))
                .accessibilityHidden(true)
            Text(title).font(MenuFont.heading(.headline))
            Text(line)
                .font(MenuFont.body(.subheadline))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The screen split down the middle, a finger on each half turning the bow that way.
private struct HalvesDiagram: View {
    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "arrow.turn.up.left")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle().fill(.white.opacity(0.5)).frame(width: 1)
            Image(systemName: "arrow.turn.up.right")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .font(.title2)
        .foregroundStyle(.white)
    }
}

/// The tiller's track and knob, a slide either way.
private struct TillerDiagram: View {
    var body: some View {
        ZStack {
            Capsule().fill(.white.opacity(0.25)).frame(width: 96, height: 6)
            Circle().fill(.white).frame(width: 26, height: 26).offset(x: 22)
            Image(systemName: "arrow.left.and.right")
                .foregroundStyle(.white)
                .offset(y: 26)
        }
    }
}

// MARK: - Rules

/// The rules on one page (#23): 10 to 13 in the words the rule calls use, mark-room, touching a mark, starts and the
/// penalty turn.
private struct RulesHelp: View {
    var body: some View {
        ForEach([RacingRule.portStarboard, .windwardLeeward, .clearAstern, .whileTacking], id: \.self) { rule in
            HelpSection(heading: "Rule \(rule.rawValue)", lines: [RuleWords.plain(rule) + "."])
        }
        // TODO-COPY (#171)
        HelpSection(heading: "Rule 18", lines: ["Near a mark, give the boat inside you room to round it."])
        HelpSection(heading: "Rule 31", lines: [RuleWords.plain(.touchingMark) + "."])
        // TODO-COPY (#171)
        HelpSection(heading: "Starts", lines: [
            "Be behind the line at the gun.",
            "Over early? Dip back behind the line, then start.",
        ])
        // TODO-COPY (#171)
        HelpSection(heading: "Penalty turns", lines: [
            "Break a rule and you owe a penalty turn. " + RuleWords.penaltyLine,
            "The orange arc round your boat shows the time left.",
        ])
    }
}

// MARK: - Current

/// How to read the briefing's one line on the current (#130), in its own words.
private struct CurrentHelp: View {
    static let example = BriefingModel.currentLine(.init(strength: .strong, turnsDuringRace: true,
                                                         turnsEarlierInShallows: true))

    var body: some View {
        // TODO-COPY (#171): every line on this page.
        HelpSection(heading: "In the briefing", lines: [
            "Some venues have a current. The briefing says how it runs, in one line:",
        ])
        Text(Self.example)
            .font(MenuFont.body())
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ChromePalette.surface, in: .rect(cornerRadius: 12))
        HelpSection(heading: "Reading it", lines: [
            "Light, moderate or strong: how hard it pushes.",
            "Steady, or it turns during the race.",
            "Earlier in the shallows: near the shore it turns first.",
        ])
        HelpSection(heading: "On the water", lines: [
            "The current carries every boat. Your wake bends with it.",
            "Sail where it helps you, and out of it where it doesn't.",
        ])
    }
}
