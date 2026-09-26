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
                            message: "Steering, camera, sound and lobby settings arrive here.") {
                #if DEBUG
                DevRaceServerField()
                #endif
            }
        }
    }
}

/// A practice race's setup, then Start. The setup is kept for the next race.
///
/// A scroll view and a column, like the other pages, rather than a `Form`: an identifier on a `Form` doesn't
/// reach the accessibility tree, and UI tests find the page by its column's `page-practiceSetup`.
private struct PracticeSetupView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 0) {
                    Stepper(value: $model.settings.opponents, in: 1...15) {
                        HStack {
                            Text("Opponents").font(MenuFont.body())
                            Spacer(minLength: 12)
                            Text("\(model.settings.opponents)").font(MenuFont.number(.body))
                        }
                    }
                    .padding(16)
                    Divider()
                    row("Laps") {
                        Picker("Laps", selection: $model.settings.laps) {
                            ForEach(1...3, id: \.self) { Text("\($0)").tag($0) }
                        }
                    }
                    Divider()
                    row("Start sequence") {
                        Picker("Start sequence", selection: $model.settings.prestartSeconds) {
                            Text("30s").tag(30.0)
                            Text("60s").tag(60.0)
                            Text("90s").tag(90.0)
                        }
                    }
                }
                .background(ChromePalette.surface, in: .rect(cornerRadius: 16))

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
            .padding(.vertical, 20)
            .readableColumn()
            // UI tests check the page was pushed.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("page-practiceSetup")
        }
        .menuBackground()
        .navigationTitle("Practice")
    }

    /// A setup row: its label, then a segmented picker.
    private func row(_ label: String, @ViewBuilder picker: () -> some View) -> some View {
        HStack {
            Text(label).font(MenuFont.body())
            Spacer(minLength: 12)
            picker()
                .pickerStyle(.segmented)
                .fixedSize()
        }
        .padding(16)
    }
}

/// A page whose content a later ticket builds.
private struct PlaceholderPage<Extra: View>: View {
    let title: String
    let systemImage: String
    let id: String
    let message: String
    let extra: Extra

    init(title: String, systemImage: String, id: String, message: String, @ViewBuilder extra: () -> Extra = { EmptyView() }) {
        self.title = title
        self.systemImage = systemImage
        self.id = id
        self.message = message
        self.extra = extra()
    }

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
                extra
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

#if DEBUG
/// The dev race server Race online joins in a Debug build (#68), `host:port`. `-onlineHost` overrides it.
private struct DevRaceServerField: View {
    @AppStorage(RaceServer.addressDefaultsKey) private var host = RaceServer.defaultAddress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Race server (dev)").font(MenuFont.heading(.headline))
            TextField("host:port", text: $host)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textFieldStyle(.roundedBorder)
        }
        .padding(.top, 24)
    }
}
#endif

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
