import SwiftUI

/// Help (#135, #23): pushed from home, and a sheet over the race from the pause menu and the first race's results
/// (#25, #24). A short list of topics, each one short screen (`HelpTopic`). It needs no `AppModel`: the race's sheet
/// builds it too. Destination links, not values, so it pushes inside home's typed path as well as the sheet's stack.
struct HelpPage: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(HelpTopic.allCases) { topic in
                    if topic != HelpTopic.allCases.first { Divider() }
                    NavigationLink {
                        HelpTopicView(topic: topic)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: topic.systemImage)
                                .foregroundStyle(ChromePalette.tint)
                                .frame(width: 28)
                                .accessibilityHidden(true)
                            Text(topic.title).font(MenuFont.body())
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .padding(16)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("help-topic-\(topic.rawValue)")
                }
            }
            .background(ChromePalette.surface, in: .rect(cornerRadius: 16))
            .padding(.vertical, 20)
            .readableColumn()
            // UI tests check the page was pushed.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("page-help")
        }
        .menuBackground()
        .navigationTitle("Help")
    }
}
