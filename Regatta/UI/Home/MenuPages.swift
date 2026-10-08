import RegattaBots
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
            MyBoatView(model: model.myBoat)
        case .profile:
            PlaceholderPage(title: "Profile", systemImage: "person.crop.circle", id: "page-profile",
                            message: "Your rating, races and badges arrive here.")
        case .help:
            HelpPage()
        case .settings:
            SettingsView(model: model)
        #if DEBUG
        case .tuning:
            TuningView(model: model.tuning)
        #endif
        }
    }
}

/// A practice race's setup (#25, #131): the venue, its conditions or Random, the bot tier or a Mixed fleet, and the
/// fleet size, then Start, which goes to the briefing. Laps and the start sequence are fixed. The choices are kept on
/// the device for the next race (`AppModel.practiceSetup`).
///
/// A scroll view and a column, like the other pages, rather than a `Form`: an identifier on a `Form` doesn't
/// reach the accessibility tree, and UI tests find the page by its column's `page-practiceSetup`.
struct PracticeSetupView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 0) {
                    menuRow("Venue") {
                        Picker("Venue", selection: $model.practiceSetup.venue) {
                            ForEach(PracticeVenue.all) { Text($0.name).tag($0.id) }
                        }
                        .accessibilityIdentifier("practice-venue")
                    }
                    Divider()
                    menuRow("Conditions") {
                        Picker("Conditions", selection: $model.practiceSetup.conditions) {
                            Text("Random").tag(PracticeSetup.ConditionsChoice.random)
                            ForEach(model.practiceSetup.practiceVenue.conditions) { option in
                                Text(option.name).tag(PracticeSetup.ConditionsChoice.named(option.id))
                            }
                        }
                        .accessibilityIdentifier("practice-conditions")
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Bots").font(MenuFont.body())
                        Picker("Bots", selection: $model.practiceSetup.botTier) {
                            Text("Mixed").tag(BotTier?.none)
                            Text("Club").tag(BotTier?.some(.club))
                            Text("Regional").tag(BotTier?.some(.regional))
                            Text("National").tag(BotTier?.some(.national))
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("practice-tier")
                    }
                    .padding(16)
                    Divider()
                    Stepper(value: $model.practiceSetup.fleetSize, in: PracticeSetup.fleetSizes) {
                        HStack {
                            Text("Fleet").font(MenuFont.body())
                            Spacer(minLength: 12)
                            Text("\(model.practiceSetup.fleetSize) boats")
                                .font(MenuFont.number(.body))
                        }
                    }
                    // UI tests read the fleet off the stepper itself: SwiftUI folds the label's texts into it.
                    .accessibilityValue("\(model.practiceSetup.fleetSize) boats")
                    .accessibilityIdentifier("practice-fleet")
                    .padding(16)
                }
                .background(ChromePalette.surface, in: .rect(cornerRadius: 16))

                Text(PracticeSetup.fixedNote)
                    .font(MenuFont.body(.footnote))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: model.beginPractice) {
                    Text("Start race")
                        .font(MenuFont.heading(.title3))
                        // The page's `menuBackground` text colour would otherwise reach the label: navy on the navy fill.
                        .foregroundStyle(ChromePalette.onTint)
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

    /// A setup row: its label, then a menu picker, which fits a long name at 402 pt where a segmented one can't.
    private func menuRow(_ label: String, @ViewBuilder picker: () -> some View) -> some View {
        HStack {
            Text(label).font(MenuFont.body())
            Spacer(minLength: 12)
            picker()
                .pickerStyle(.menu)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
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
/// The dev race server Race online joins in a Debug build (#68), `host:port`. `-onlineHost` overrides it. On the
/// Settings page.
struct DevRaceServerField: View {
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

/// A brief sheet over the home screen (#25). A placeholder until the lobby's boat card.
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
        case .terms: "Terms of Use"
        case .boatCard: "Boat card"
        case .lastRace: "Last race"
        }
    }

    private var message: String {
        switch sheet {
        // `HomeView` always shows `TermsSheet` for the terms.
        case .terms: ""
        case .boatCard: "A sailor's boat card arrives here."
        // `HomeView` shows the results themselves; this only when there are none to show.
        case .lastRace: "No last race yet."
        }
    }
}
