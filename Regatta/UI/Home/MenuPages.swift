import RegattaBots
import SwiftUI

/// A page pushed on the home screen.
struct MenuPageView: View {
    let page: AppModel.Page
    @Bindable var model: AppModel
    /// Home's online actions: the profile's Sign in and Try again are the lobby area's (#139).
    var online = HomeOnlineActions()
    @Environment(\.onlineStatus) private var onlineStatus

    var body: some View {
        switch page {
        case .practiceSetup:
            PracticeSetupView(model: model)
        case .myBoat:
            MyBoatView(model: model.myBoat)
        case .profile:
            ProfileView(model: model, status: onlineStatus, online: online)
        case .help:
            HelpPage()
        case .settings:
            SettingsView(model: model, deleter: onlineStatus.map { .app(status: $0, model: model) } ?? .unconnected)
        case .blockedPlayers:
            BlockedPlayersPage()
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

#if DEBUG
/// The dev race server Race online joins in a Debug build (#68), `host:port`, and the dev player it signs in as there
/// in place of Game Center (#162: a number; empty for Game Center, or the dev instant race). `-onlineHost` and
/// `-devIdentity` override them. Both are read at launch. On the Settings page.
struct DevRaceServerField: View {
    @AppStorage(RaceServer.addressDefaultsKey) private var host = RaceServer.defaultAddress
    @AppStorage(DevIdentity.defaultsKey) private var player = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Race server (dev)").font(MenuFont.heading(.headline))
            TextField("host:port", text: $host)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textFieldStyle(.roundedBorder)
            Text("Dev player").font(MenuFont.heading(.headline)).padding(.top, 8)
            TextField("number", text: $player)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("settings-dev-player")
            Text("Both apply at the next launch.").font(MenuFont.body(.footnote)).foregroundStyle(.secondary)
        }
        .padding(.top, 24)
    }
}
#endif

/// A brief sheet over the home screen (#25): what `HomeView` has no view of its own for.
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
        .accessibilityIdentifier("sheet-\(sheet.name)")
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
        // `HomeView` always shows `BoatCardSheet` for a card.
        case .boatCard: ""
        // `HomeView` shows the results themselves; this only when there are none to show.
        case .lastRace: "No last race yet."
        }
    }
}
