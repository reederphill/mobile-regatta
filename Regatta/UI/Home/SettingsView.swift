import SwiftUI

/// Settings (#110, #25): one page, in sections: Controls, On the water, Hints, Sound, Lobby, Purchases, Share usage
/// data, Delete my online data, About. Every row is a `DeviceSettings` value, kept on the device.
///
/// A scroll view and a column like the other pages, not a `Form`: an identifier on a `Form` doesn't reach the
/// accessibility tree, and UI tests find the page by `page-settings`.
struct SettingsView: View {
    /// What Delete my online data does once confirmed, and the notice it leaves: the seam the deletion service's plan
    /// and confirmation fill in #166.
    typealias OnlineDataDeletion = () async -> String
    /// Until #166: nothing is deleted, and the notice says so.
    static let deletionArrivesLater: OnlineDataDeletion = { "Deleting online data arrives with online accounts." }

    @Bindable var model: AppModel
    var deleteOnlineData: OnlineDataDeletion = Self.deletionArrivesLater
    @State private var confirmsDeletion = false
    @State private var shownNotice: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                section("Controls") {
                    pickerRow("Steering", selection: $model.deviceSettings.steering, id: "settings-steering") { scheme in
                        switch scheme {
                        case .halves: "Halves"
                        case .tiller: "Tiller"
                        }
                    }
                }
                section("On the water") {
                    pickerRow("Camera", selection: $model.deviceSettings.camera, id: "settings-camera") { camera in
                        switch camera {
                        case .courseUp: "Course up"
                        case .boatUp: "Boat up"
                        }
                    }
                    Divider()
                    toggleRow("Auto framing", isOn: $model.deviceSettings.autoFraming, id: "settings-autoFraming")
                    Divider()
                    toggleRow("Laylines", isOn: $model.deviceSettings.laylines, id: "settings-laylines")
                    Divider()
                    toggleRow("Ladder lines", isOn: $model.deviceSettings.ladderLines, id: "settings-ladderLines")
                }
                section("Hints") {
                    toggleRow("Hints", isOn: $model.deviceSettings.hints, id: "settings-hints")
                    Divider()
                    buttonRow("Reset hints", id: "settings-resetHints") {
                        model.resetHints()
                        shownNotice = "Hints will show again."
                    }
                }
                section("Sound") {
                    toggleRow("Music", isOn: $model.deviceSettings.music, id: "settings-music")
                    Divider()
                    toggleRow("Effects", isOn: $model.deviceSettings.effects, id: "settings-effects")
                    Divider()
                    toggleRow("Haptics", isOn: $model.deviceSettings.haptics, id: "settings-haptics")
                }
                section("Lobby") {
                    toggleRow("Hide lobby chat", isOn: $model.deviceSettings.hidesLobbyChat, id: "settings-hidesLobbyChat")
                    Divider()
                    NavigationLink {
                        BlockedPlayersPage()
                    } label: {
                        rowLabel("Blocked players")
                    }
                    .accessibilityIdentifier("settings-blockedPlayers")
                }
                section("Purchases") {
                    // Restores through the store service once purchases are wired (#166).
                    buttonRow("Restore purchases", id: "settings-restorePurchases") {
                        shownNotice = "Purchases are restored once the shop opens."
                    }
                }
                section("Usage data") {
                    toggleRow("Share usage data", isOn: $model.deviceSettings.sharesUsageData, id: "settings-sharesUsageData")
                    footnote("Anonymous, first-party only, and never used for tracking. Racing works the same either way.")
                }
                section("Online data") {
                    buttonRow("Delete my online data", role: .destructive, id: "settings-deleteOnlineData") {
                        confirmsDeletion = true
                    }
                    footnote("Deletes your profile, rating, chat and reports from the server. Purchases stay with your Apple ID.")
                }
                section("About") {
                    Link(destination: AboutLinks.support) { rowLabel("Support: \(AboutLinks.supportEmail)") }
                        .accessibilityIdentifier("settings-support")
                    Divider()
                    Link(destination: AboutLinks.privacyPolicy) { rowLabel("Privacy policy") }
                        .accessibilityIdentifier("settings-privacy")
                    Divider()
                    Link(destination: AboutLinks.terms) { rowLabel("Terms of Use") }
                        .accessibilityIdentifier("settings-terms")
                    Divider()
                    NavigationLink {
                        AcknowledgementsPage()
                    } label: {
                        rowLabel("Acknowledgements")
                    }
                    .accessibilityIdentifier("settings-acknowledgements")
                    Divider()
                    HStack {
                        Text("Version").font(MenuFont.body())
                        Spacer(minLength: 12)
                        Text(Self.version).font(MenuFont.number(.body)).foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("settings-version")
                }
                #if DEBUG
                DevRaceServerField()
                #endif
            }
            .padding(.vertical, 20)
            .readableColumn()
            // UI tests check the page was pushed.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("page-settings")
        }
        .menuBackground()
        .navigationTitle("Settings")
        .confirmationDialog("Delete your online data?", isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task { shownNotice = await deleteOnlineData() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your profile, rating, chat history and reports are deleted, and your name comes off the leaderboard. Race results keep a random name in your place.")
        }
        .alert(shownNotice ?? "", isPresented: Binding(get: { shownNotice != nil }, set: { if !$0 { shownNotice = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    /// "0.1 (1)": the marketing version and the build.
    static var version: String {
        let info = Bundle.main.infoDictionary
        let marketing = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(marketing) (\(build))"
    }

    private func section(_ title: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(MenuFont.heading(.headline))
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 0) {
                rows()
            }
            .background(ChromePalette.surface, in: .rect(cornerRadius: 16))
        }
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>, id: String) -> some View {
        Toggle(isOn: isOn) {
            Text(title).font(MenuFont.body())
        }
        .padding(16)
        .accessibilityIdentifier(id)
    }

    private func pickerRow<Value: Hashable & CaseIterable>(
        _ title: String, selection: Binding<Value>, id: String, label: @escaping (Value) -> String
    ) -> some View where Value.AllCases: RandomAccessCollection {
        HStack {
            Text(title).font(MenuFont.body())
            Spacer(minLength: 12)
            Picker(title, selection: selection) {
                ForEach(Array(Value.allCases), id: \.self) { Text(label($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .accessibilityIdentifier(id)
        }
        .padding(16)
    }

    private func buttonRow(_ title: String, role: ButtonRole? = nil, id: String, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            rowLabel(title)
        }
        .accessibilityIdentifier(id)
    }

    private func rowLabel(_ title: String) -> some View {
        Text(title)
            .font(MenuFont.body())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .contentShape(.rect)
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(MenuFont.body(.footnote))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding([.horizontal, .bottom], 16)
    }
}

/// Settings → About → Acknowledgements: each bundled third-party licence (`Acknowledgement.bundled()`).
private struct AcknowledgementsPage: View {
    private let acknowledgements = (try? Acknowledgement.bundled()) ?? []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(acknowledgements, id: \.name) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.version.map { "\(item.name) \($0)" } ?? item.name).font(MenuFont.heading(.headline))
                        Text(item.license).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 20)
            .readableColumn()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("page-acknowledgements")
        }
        .menuBackground()
        .navigationTitle("Acknowledgements")
    }
}
