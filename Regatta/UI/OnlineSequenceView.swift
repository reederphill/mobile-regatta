import RegattaCore
import RegattaServices
import SwiftUI

/// What an online race draws over the water for the race sequence (#141): the race menu, the leave confirm and the
/// connection line, as `OnlineRaceController` has them, and what their buttons do.
struct OnlineRaceChrome {
    var isMenuOpen = false
    var isConfirmingLeave = false
    var isReconnecting = false
    /// The leave confirm's wording: before the gun a bot takes the seat, after it she is scored as retired.
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
                LeaveConfirm(place: .race, isBeforeGun: race.isBeforeGun, leave: race.leaveRace, stay: race.stay)
            }
        }
    }
}

/// "Leave the race?" (#140, #141): the one card over the locked fleet's briefing and over the race, Stay prominent,
/// Leave plain. Everything runs on behind it. Over the race it is drawn dark, as the race's chrome is.
struct LeaveConfirm: View {
    /// Where it stands: the briefing keeps #140's identifiers.
    enum Place {
        case briefing, race

        var identifiers: (card: String, leave: String, stay: String) {
            switch self {
            case .briefing: ("briefing-leave-question", "briefing-leave-confirm", "briefing-leave-stay")
            case .race: ("race-leave-confirm", "race-leave-confirm-leave", "race-leave-confirm-stay")
            }
        }
    }

    var place: Place
    var isBeforeGun: Bool
    var leave: () -> Void
    var stay: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    // TODO-COPY (#171)
    static func consequence(isBeforeGun: Bool) -> String {
        isBeforeGun ? "A bot takes your seat." : "You'll be scored as retired."
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            VStack(spacing: 14) {
                // TODO-COPY (#171)
                Text("Leave the race?").font(MenuFont.heading(.title3))
                    .accessibilityAddTraits(.isHeader)
                Text(Self.consequence(isBeforeGun: isBeforeGun)).font(MenuFont.body())
                    .foregroundStyle(ChromePalette.text.opacity(0.7))
                HStack(spacing: 12) {
                    Button(action: leave) {
                        Text("Leave").font(MenuFont.body()).frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier(place.identifiers.leave)
                    Button(action: stay) {
                        Text("Stay").font(MenuFont.heading(.headline)).frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(place.identifiers.stay)
                }
                .controlSize(.large)
            }
            .multilineTextAlignment(.center)
            .foregroundStyle(ChromePalette.text)
            .padding(24)
            .frame(maxWidth: 360)
            .background(ChromePalette.surface, in: .rect(cornerRadius: 20))
            .padding(.horizontal, 24)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
            .accessibilityIdentifier(place.identifiers.card)
        }
        .tint(ChromePalette.tint)
        .environment(\.colorScheme, place == .race ? .dark : colorScheme)
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
    /// The results of a race as the service remembers it (#141): one that closed while she was away. Its rating is
    /// pending until it is pushed, unless the race was unrated. She wears `livery`; the wire carries no other yet.
    init(lastRace: LastRace, livery: Livery) {
        let report = lastRace.report
        let entrants = report.roster.indices.map { seat in
            Entrant(name: seat == report.seat ? "You" : report.roster[seat].name, isBot: report.roster[seat].isBot,
                    livery: seat == report.seat ? livery : FleetLiveries.yours)
        }
        let cell: RatingCell = lastRace.rating.map { .init($0.outcome) }
            ?? (report.results.rated ? .pending : .unrated(.noOtherHumans))
        self.init(report: report, entrants: entrants, rating: cell, earned: nil)
    }

    /// Home's Last race badge (#141): the rating change only, "+12" or "−8"; nil unrated, pending or offline.
    var ratingBadge: (text: String, spoken: String)? {
        guard case .rated(let change, _, _) = online?.rating else { return nil }
        // TODO-COPY (#171)
        return change >= 0 ? ("+\(change)", "Rating plus \(change)") : ("\u{2212}\(-change)", "Rating minus \(-change)")
    }
}
