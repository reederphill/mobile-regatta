import RegattaCore
import SwiftUI

/// A page of Help (#135, #23), each one short screen. The protest picker (#125) adds its own when it lands: Help
/// never describes what the game doesn't have yet.
enum HelpTopic: String, CaseIterable, Identifiable, Codable, Sendable {
    case symbols
    case steering
    case rules
    case current
    /// What the committee's and your boat's sounds mean (#126).
    case sounds

    var id: String { rawValue }

    // TODO-COPY (#171): every topic title.
    var title: String {
        switch self {
        case .symbols: "On the water"
        case .steering: "Steering"
        case .rules: "Rules"
        case .current: "Current"
        case .sounds: "Sounds"
        }
    }

    var systemImage: String {
        switch self {
        case .symbols: "water.waves"
        case .steering: "hand.draw"
        case .rules: "flag"
        case .current: "arrow.right.circle"
        case .sounds: "speaker.wave.2"
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
                case .sounds: SoundsHelp()
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

/// Both steering schemes, with a small picture each, then letting go and steering by hand (the groove tick, pinch and
/// foot and the vane's arc, #219, #436: hand steering is the way the game is played, the Auto tiller tuning never
/// mentioned) and the two buttons, in a few short lines.
private struct SteeringHelp: View {
    var body: some View {
        // TODO-COPY (#171): every line on this page.
        HStack(alignment: .top, spacing: 16) {
            SchemeCard(title: "Halves", line: "Hold a side to turn that way.") { HalvesDiagram() }
            SchemeCard(title: "Tiller", line: "Touch and slide sideways.") { TillerDiagram() }
        }
        HelpSection(heading: "Let go", lines: [
            "Let go and she sails straight on.",
            "Steer to the tick on the vane, the groove, the best angle.",
            "Pinch above it or foot below it: the arc shows how far.",
        ])
        HelpSection(heading: "Buttons", lines: [
            "Ease: hold to slow down. Tack: tap to turn; you come out on the groove.",
        ])
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

/// The rules on one page (#23), one line each in the words the race's own notices use (`RuleWords`): 10 to 13,
/// mark-room, touching a mark, starts and the penalty turn.
private struct RulesHelp: View {
    static let rules: [RacingRule] = [.portStarboard, .windwardLeeward, .clearAstern, .whileTacking, .givingMarkRoom,
                                      .touchingMark]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Self.rules, id: \.self) { rule in
                RuleLine(number: rule.rawValue, line: RuleWords.plain(rule) + ".")
            }
        }
        HelpSection(heading: "Starts", lines: [RuleWords.ocs])
        HelpSection(heading: "Penalty turns", lines: [RuleWords.penaltyLine])
    }
}

/// A rule's number, as its badge shows it, and its line.
private struct RuleLine: View {
    let number: String
    let line: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(number)
                .font(MenuFont.heading(.headline))
                .frame(minWidth: 40, alignment: .leading)
            Text(line)
                .font(MenuFont.body())
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            "The current carries every boat.",
            "Sail where it helps you, and out of it where it doesn't.",
        ])
    }
}

// MARK: - Sounds

/// What the sounds mean (#126), text only and number-free: the committee's start, then your own boat's. Every sound
/// has something on screen too, so the page is short.
private struct SoundsHelp: View {
    var body: some View {
        // TODO-COPY (#171): every line on this page.
        HelpSection(heading: "The start", lines: [
            "Horns: the start is coming.",
            "Beeps: the last seconds.",
            "The gun: go.",
        ])
        HelpSection(heading: "Your boat", lines: [
            "A horn just after the gun: you were over the line. Dip back below it, then start.",
            "A whistle: a rule call with you in it.",
            "A soft bell: you rounded a mark.",
            "A horn at the end: you finished.",
        ])
        HelpSection(heading: "On the water", lines: [
            "Wind and water follow the breeze and your speed. Hold Ease and the sail flaps.",
        ])
    }
}
