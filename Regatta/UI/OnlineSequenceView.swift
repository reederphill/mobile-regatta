import RegattaCore
import SwiftUI

/// What an online race draws over the water for the race sequence (#141): the race menu, the leave confirm and the
/// connection line, as `OnlineRaceController` has them, and what their buttons do.
struct OnlineRaceChrome {
    var isMenuOpen = false
    var isConfirmingLeave = false
    var isReconnecting = false
    /// The leave confirm's wording: before the gun a bot takes the seat, after it she is scored RET.
    var isBeforeGun = true
    var openMenu: () -> Void = {}
    var closeMenu: () -> Void = {}
    var askToLeave: () -> Void = {}
    var leave: () -> Void = {}
    var stay: () -> Void = {}
}

/// The online race in the race sequence's cover (#141): the race once the link is up, the water's colour and
/// "Joining" until then. Dumb: everything it shows is the controller's.
struct OnlineSequenceView: View {
    let launch: OnlineLaunch
    let race: OnlineRaceController
    var deviceSettings: Binding<DeviceSettings>
    var onTryIt: (DesignID) -> Void

    var body: some View {
        if let session = launch.session {
            RaceView(session: session, onRestart: {}, onExit: race.home, deviceSettings: deviceSettings,
                     onRaceAgain: { Task { await race.raceAgain() } }, onTryIt: onTryIt,
                     online: OnlineRaceChrome(isMenuOpen: race.isMenuOpen, isConfirmingLeave: race.isConfirmingLeave,
                                              isReconnecting: race.isReconnecting, isBeforeGun: race.isBeforeGun,
                                              openMenu: race.openMenu, closeMenu: race.closeMenu,
                                              askToLeave: race.askToLeave, leave: race.leaveRace, stay: race.stay))
                .id(ObjectIdentifier(session))
        } else {
            joining
        }
    }

    /// The link isn't up yet: no failure and no address, only the way out.
    private var joining: some View {
        ZStack {
            ChartPalette.water.color.ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView().tint(.white)
                // TODO-COPY (#171)
                Text("Joining").font(.title2.bold())
                Button(action: race.askToLeave) { Text("Leave race").frame(maxWidth: 200) }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityIdentifier("pause-leave")
            }
            .foregroundStyle(.white)
            .padding(28)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 24))
            .padding(24)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("race-joining")
            if race.isConfirmingLeave {
                LeaveConfirm(isBeforeGun: race.isBeforeGun, leave: race.leaveRace, stay: race.stay)
            }
        }
    }
}

/// "Leave the race?" over the race (#141, #140's card on the race's chrome): Stay prominent, Leave plain. The race
/// runs on behind it.
struct LeaveConfirm: View {
    var isBeforeGun: Bool
    var leave: () -> Void
    var stay: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            VStack(spacing: 14) {
                // TODO-COPY (#171)
                Text("Leave the race?").font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(isBeforeGun ? "A bot takes your seat." : "You'll be scored RET.")
                    .foregroundStyle(.white.opacity(0.75))
                HStack(spacing: 12) {
                    Button(action: leave) { Text("Leave").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("race-leave-confirm-leave")
                    Button(action: stay) { Text("Stay").bold().frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("race-leave-confirm-stay")
                }
                .controlSize(.large)
            }
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .padding(24)
            .frame(maxWidth: 360)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 24))
            .padding(.horizontal, 16)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
            .accessibilityIdentifier("race-leave-confirm")
        }
    }
}

/// The connection has been gone 2 s (#141): the briefing's word, in the race's notice slot. Her boat sails on.
struct ReconnectingLine: View {
    var body: some View {
        // TODO-COPY (#171)
        Label("Reconnecting", systemImage: "wifi.exclamationmark")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.black.opacity(0.55), in: .capsule)
            .accessibilityIdentifier("race-reconnecting")
    }
}

extension RaceResultViewModel {
    /// Home's Last race badge (#141): the rating change only, "+12" or "−8"; nil unrated, pending or offline.
    var ratingBadge: (text: String, spoken: String)? {
        guard case .rated(let change, _, _) = online?.rating else { return nil }
        // TODO-COPY (#171)
        return change >= 0 ? ("+\(change)", "Rating plus \(change)") : ("\u{2212}\(-change)", "Rating minus \(-change)")
    }
}
