import SwiftUI
import RegattaCore

/// UI tests only (#114): your standing and leg as an accessibility label (`race-status`, "5th of 8 · leg 1/6" while
/// racing), and whole seconds from the gun as its value, since the HUD shows neither the leg nor a status line.
/// One snapshot reads both, so a failure tells a slow simulator from a race that never rounded.
struct RaceStatusProbe: View {
    let hud: HUDState

    var body: some View {
        Text(Self.statusLine(hud))
            .font(.system(size: 1))
            .foregroundStyle(.clear)
            .accessibilityLabel(Self.statusLine(hud))
            .accessibilityValue(String(Int(hud.clock.rounded(.down))))
            .accessibilityIdentifier("race-status")
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
    }

    static func statusLine(_ hud: HUDState) -> String {
        switch hud.status {
        case .prestart: hud.clock < 0 ? "Start sequence" : "Not started"
        case .ocs: "OCS"
        case .racing: "\(ordinal(hud.place)) of \(hud.fleet) · leg \(hud.legNumber)/\(hud.legCount)"
        case .finished: "Finished \(ordinal(hud.place))"
        case .dsq: "Disqualified"
        }
    }
}
