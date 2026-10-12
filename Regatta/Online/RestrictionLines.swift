import Foundation
import RegattaServiceClient
import RegattaServices

/// Why the player can't race online now, as the one line under Race online says it (#161), beyond the gating
/// matrix's "Offline" and "Practice races only" (#138): the server's refusals from the queue's state stream, and
/// where the session stands.
nonisolated enum RestrictionLine: Equatable {
    /// An online racing suspension, to the end of that day; nil for good.
    case suspended(until: Date?)
    /// The briefing-leave cooldown (#26), counted down to this instant.
    case cooldown(until: Date)
    /// A refusal the player isn't told the reason of: a failed attestation (#147's ruling), or her Game Center id
    /// already belonging to another player (ADR 0010).
    case cannotRace
    /// This build is too old for the server, or for the terms now current.
    case updateRequired
    /// The server didn't answer the last Race online tap.
    case unreachable
    /// The server wouldn't sign her in.
    case couldNotSignIn

    /// The queue's refusal, received at `now`. A cooldown's seconds become the instant it ends, counted down on
    /// the device; the server's `.idle` ends it.
    init?(queue: QueueState, now: Date) {
        guard case .unavailable(let refusal) = queue else { return nil }
        switch refusal {
        case .suspended(let until): self = .suspended(until: until.map { Date(timeIntervalSince1970: TimeInterval($0)) })
        case .cooldown(let seconds): self = .cooldown(until: now.addingTimeInterval(TimeInterval(max(0, seconds))))
        case .attestationFailed: self = .cannotRace
        case .updateRequired: self = .updateRequired
        // The gating matrix's own: sign-in, the terms sheet, "Practice races only".
        case .notSignedIn, .termsNotAccepted, .multiplayerRestricted: return nil
        }
    }

    /// Where the session stands. `tapFailed`: the last Race online tap got no session; an unreachable server is
    /// only said then.
    init?(phase: SessionPhase, tapFailed: Bool) {
        switch phase {
        case .updateRequired: self = .updateRequired
        case .refused(.gamePlayerIDConflict): self = .cannotRace
        case .refused: self = .couldNotSignIn
        case .unreachable, .connecting:
            guard tapFailed else { return nil }
            self = .unreachable
        case .idle, .open: return nil
        }
    }

    /// Race online stays tappable under the line: the tap tries again.
    var allowsTap: Bool { self == .unreachable || self == .couldNotSignIn }

    /// The line at `now`.
    func text(now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        switch self {
        case .suspended(let until?):
            let format = DateFormatter()
            format.calendar = calendar
            format.timeZone = calendar.timeZone
            format.locale = locale
            // The day, never the time.
            format.setLocalizedDateFormatFromTemplate("EEEdMMM")
            // TODO-COPY (#171)
            return "Racing paused until \(format.string(from: until))"
        // TODO-COPY (#171)
        case .suspended(nil): return "Racing closed"
        case .cooldown(let until):
            let seconds = max(0, Int(until.timeIntervalSince(now).rounded(.up)))
            // TODO-COPY (#171)
            return "Cooling off \(seconds / 60):\(seconds % 60 < 10 ? "0" : "")\(seconds % 60)"
        // TODO-COPY (#171)
        case .cannotRace: return "Can't race online right now"
        // TODO-COPY (#171)
        case .updateRequired: return "Update to race online"
        // TODO-COPY (#171)
        case .unreachable: return "Can't reach the server"
        // TODO-COPY (#171)
        case .couldNotSignIn: return "Couldn't sign in"
        }
    }
}
