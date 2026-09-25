import SwiftUI

struct MenuView: View {
    @Binding var settings: RaceSettings
    var onStart: () -> Void
    /// "Race online (dev)" (#68): nil hides it, as a Release build does.
    var onRaceOnline: (() -> Void)?
    #if DEBUG
    /// The dev race server, `host:port`.
    @AppStorage(RaceServer.addressDefaultsKey) private var onlineHost = RaceServer.defaultAddress
    #endif

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.05, green: 0.18, blue: 0.3), Color(uiColor: Palette.water)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("REGATTA")
                            .font(.system(size: 48, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                        Text("Top-down dinghy racing. Win the start, work the shifts, stay out of dirty air — and don't foul anyone.")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .padding(.top, 40)

                    VStack(spacing: 18) {
                        Stepper(value: $settings.opponents, in: 1...15) {
                            LabeledContent("Opponents", value: "\(settings.opponents)")
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Laps").font(.subheadline).foregroundStyle(.secondary)
                            Picker("Laps", selection: $settings.laps) {
                                ForEach(1...3, id: \.self) { Text("\($0)").tag($0) }
                            }
                            .pickerStyle(.segmented)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Start sequence").font(.subheadline).foregroundStyle(.secondary)
                            Picker("Start sequence", selection: $settings.prestartSeconds) {
                                Text("30s").tag(30.0)
                                Text("60s").tag(60.0)
                                Text("90s").tag(90.0)
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                    .padding(20)
                    .background(.ultraThinMaterial, in: .rect(cornerRadius: 20))

                    Button(action: onStart) {
                        Text("Race")
                            .font(.title2.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(uiColor: Palette.mark))
                    .clipShape(.capsule)

                    #if DEBUG
                    if let onRaceOnline {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Race server host:port", text: $onlineHost)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .textFieldStyle(.roundedBorder)
                            Button("Race online (dev)", action: onRaceOnline)
                                .buttonStyle(.bordered)
                                .frame(maxWidth: .infinity)
                                .accessibilityIdentifier("race-online")
                        }
                        .padding(20)
                        .background(.ultraThinMaterial, in: .rect(cornerRadius: 20))
                    }
                    #endif

                    HowToPlay()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
        }
    }
}

private struct HowToPlay: View {
    private let items: [(String, String)] = [
        ("hand.tap", "Hold the left or right half of the screen to steer. Short taps make small corrections."),
        ("arrow.triangle.2.circlepath", "Tack / Gybe swings you through the wind onto the same angle on the other side."),
        ("flag.checkered", "Be below the line at the gun. Over early is OCS: dip back and restart."),
        ("wind", "Dark patches are puffs. Shifts come and go — tack when you're headed. The pale cone behind each boat is its wind shadow."),
        ("exclamationmark.triangle", "Port keeps clear of starboard, windward of leeward. Foul someone and you owe a 720°; hit a mark and it's a 360°. Turn in circles to serve it."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How to play").font(.headline)
            ForEach(items, id: \.1) { icon, text in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: icon)
                        .frame(width: 24)
                        .foregroundStyle(Color(uiColor: Palette.startLine))
                    Text(text).font(.footnote).foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 20))
    }
}
