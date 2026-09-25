import SwiftUI

/// A page pushed on the home screen.
struct MenuPageView: View {
    let page: AppModel.Page
    @Bindable var model: AppModel

    var body: some View {
        switch page {
        case .practiceSetup:
            PracticeSetupView(model: model)
        case .myBoat:
            PlaceholderPage(title: "My boat", systemImage: "sailboat", id: "page-myboat",
                            message: "Your boat's livery and the shop arrive here.")
        case .profile:
            PlaceholderPage(title: "Profile", systemImage: "person.crop.circle", id: "page-profile",
                            message: "Your rating, races and badges arrive here.")
        case .help:
            PlaceholderPage(title: "Help", systemImage: "questionmark.circle", id: "page-help",
                            message: "How to steer, start and keep clear arrives here.")
        case .settings:
            PlaceholderPage(title: "Settings", systemImage: "gearshape", id: "page-settings",
                            message: "Steering, camera, sound and lobby settings arrive here.")
        }
    }
}

/// A practice race's setup, then Start. The setup is kept for the next race.
private struct PracticeSetupView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                Stepper(value: $model.settings.opponents, in: 1...15) {
                    LabeledContent {
                        Text("\(model.settings.opponents)").font(MenuFont.number(.body))
                    } label: {
                        Text("Opponents").font(MenuFont.body())
                    }
                }
                LabeledContent("Laps") {
                    Picker("Laps", selection: $model.settings.laps) {
                        ForEach(1...3, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                LabeledContent("Start sequence") {
                    Picker("Start sequence", selection: $model.settings.prestartSeconds) {
                        Text("30s").tag(30.0)
                        Text("60s").tag(60.0)
                        Text("90s").tag(90.0)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }
            .listRowBackground(ChromePalette.surface)

            Section {
                Button(action: model.startPractice) {
                    Text("Start race")
                        .font(MenuFont.heading(.title3))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("practice-start")
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
        // UI tests check the page was pushed.
        .accessibilityIdentifier("page-practiceSetup")
        .menuBackground()
        .navigationTitle("Practice")
    }
}

/// A page whose content a later ticket builds.
private struct PlaceholderPage: View {
    let title: String
    let systemImage: String
    let id: String
    let message: String

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.largeTitle)
                    .foregroundStyle(ChromePalette.tint)
                    .accessibilityHidden(true)
                Text(message)
                    .font(MenuFont.body())
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 40)
            .readableColumn()
            // UI tests check the page was pushed.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(id)
        }
        .menuBackground()
        .navigationTitle(title)
    }
}

/// A brief sheet over the home screen (#25). Placeholders until sign-in (#109) and the lobby's boat card.
struct MenuSheetView: View {
    let sheet: AppModel.Sheet
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Text(message)
                .font(MenuFont.body())
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .menuBackground()
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .tint(ChromePalette.tint)
        .presentationDetents([.medium])
        .accessibilityIdentifier("sheet-\(sheet.rawValue)")
    }

    private var title: String {
        switch sheet {
        case .signIn: "Sign in"
        case .boatCard: "Boat card"
        }
    }

    private var message: String {
        switch sheet {
        case .signIn: "Game Center sign-in arrives here."
        case .boatCard: "A sailor's boat card arrives here."
        }
    }
}
