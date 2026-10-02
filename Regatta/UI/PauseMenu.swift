import SwiftUI

/// The pause menu over a paused practice race (#25): Resume; the steering scheme, camera, laylines and ladder lines,
/// which change the device's settings (so they're kept, and reach the race at once through `ControlSettings`); Help;
/// Restart race; the debug tuning panel (Debug builds); Leave race, with no warning in practice. Sound settings stay in
/// Settings. It scrolls when it doesn't fit.
struct PauseMenu: View {
    /// The device's settings the toggles change, or nil to leave them out.
    var settings: Binding<DeviceSettings>?
    var onResume: () -> Void
    var onRestart: () -> Void
    var onLeave: () -> Void
    /// Opens the Help page over the race.
    var onHelp: (() -> Void)?
    /// The debug tuning panel (#232), when the race offers it.
    var onTuning: (() -> Void)?

    var body: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            ViewThatFits(in: .vertical) {
                card
                ScrollView { card }
                    .scrollIndicators(.hidden)
            }
            .padding(.vertical, 12)
        }
    }

    private var card: some View {
        VStack(spacing: 14) {
            Text("Paused").font(.title.bold())
            Button(action: onResume) { label("Resume") }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("pause-resume")
            if let settings {
                toggles(settings)
            }
            if let onHelp {
                Button(action: onHelp) { label("Help") }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("pause-help")
            }
            Button(action: onRestart) { label("Restart race") }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("pause-restart")
            if let onTuning {
                Button(action: onTuning) { label("Tuning") }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("pause-tuning")
            }
            Button(role: .destructive, action: onLeave) { label("Leave race") }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("pause-leave")
        }
        .controlSize(.large)
        .padding(24)
        .frame(maxWidth: 360)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 24))
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pause-menu")
    }

    private func label(_ title: String) -> some View {
        Text(title).frame(maxWidth: .infinity)
    }

    private func toggles(_ settings: Binding<DeviceSettings>) -> some View {
        VStack(spacing: 12) {
            pickerRow("Steering", selection: settings.steering, id: "pause-steering") { scheme in
                switch scheme {
                case .halves: "Halves"
                case .tiller: "Tiller"
                }
            }
            pickerRow("Camera", selection: settings.camera, id: "pause-camera") { camera in
                switch camera {
                case .courseUp: "Course up"
                case .boatUp: "Boat up"
                }
            }
            Toggle("Laylines", isOn: settings.laylines)
                .accessibilityIdentifier("pause-laylines")
            Toggle("Ladder lines", isOn: settings.ladderLines)
                .accessibilityIdentifier("pause-ladderLines")
        }
        .font(.body)
        .controlSize(.regular)
        .padding(14)
        .background(Color.white.opacity(0.08), in: .rect(cornerRadius: 14))
    }

    private func pickerRow<Value: Hashable & CaseIterable>(
        _ title: String, selection: Binding<Value>, id: String, label: @escaping (Value) -> String
    ) -> some View where Value.AllCases: RandomAccessCollection {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            Picker(title, selection: selection) {
                ForEach(Array(Value.allCases), id: \.self) { Text(label($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .accessibilityIdentifier(id)
        }
    }
}
