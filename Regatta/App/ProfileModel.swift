import Foundation
import Observation
import RegattaCore
import RegattaServices

/// The profile page's read of the server's profile (#139): read each time the page appears, and again after Sign
/// in, Try again or the terms (the page's `.task(id:)`), never while the profile may not be asked
/// (`OnlineStatus.mayAskService`). Nothing is kept across launches.
@MainActor @Observable
final class ProfileModel {
    /// Where the read stands.
    enum Read: Equatable {
        /// Not read yet, or not to be asked yet: the session is still opening.
        case pending
        case loaded(Profile)
        /// The read failed: no session (`ProfileError.notSignedIn` with Game Center signed in, a build with no
        /// server) or no answer.
        case failed
    }

    private(set) var read = Read.pending
    private let profile: (any ProfileService)?
    /// `OnlineStatus.mayAskService`: with a session the server closes the connection on a profile call from a player
    /// short of the terms or the multiplayer restriction.
    private let mayAskService: () -> Bool
    /// Told the server's count of her completed races at each read (`AppModel.adoptServerCount`), so My boat's
    /// "n / N races" matches the page's.
    private let adoptCount: (Int) -> Void

    /// With no service (previews, a page with no `OnlineStatus`) nothing is ever read.
    init(profile: (any ProfileService)?, mayAskService: @escaping () -> Bool = { true },
         adoptCount: @escaping (Int) -> Void = { _ in }) {
        self.profile = profile
        self.mayAskService = mayAskService
        self.adoptCount = adoptCount
    }

    /// Reads the profile, when it may be asked; otherwise it waits as pending.
    func refresh() async {
        guard let profile, mayAskService() else {
            read = .pending
            return
        }
        // A failed read gives way to the spinner; a loaded one stays up until the new one is in.
        if read == .failed { read = .pending }
        let result: Read
        do {
            result = .loaded(try await profile.profile())
        } catch {
            result = .failed
        }
        // A newer read (the gate moved meanwhile) replaces this one.
        guard !Task.isCancelled else { return }
        read = result
        if case .loaded(let loaded) = result { adoptCount(loaded.completedRaces) }
    }

    /// The page's state now, from the services' state and this read.
    func state(isOnline: Bool, status: LobbyStatus, retryLine: RestrictionLine?) -> ProfilePageState {
        ProfilePageState(isOnline: isOnline, status: status, retryLine: retryLine, read: read)
    }

    /// The progress row's "32 / 50 races" (#25); nil once every earned design is earned.
    static func progressText(_ profile: Profile) -> String? {
        guard let next = profile.progress.next else { return nil }
        // TODO-COPY (#171)
        return "\(min(profile.completedRaces, next.completedRaces)) / \(next.completedRaces) races"
    }

    /// The suspension notice (#26), in Race online's own words: "Racing paused until Wed 14 Oct", the day only, or
    /// "Racing closed" for a ban; nil with none.
    static func suspensionText(_ profile: Profile, calendar: Calendar = .current, locale: Locale = .current) -> String? {
        guard let suspension = profile.suspension else { return nil }
        let line = RestrictionLine.suspended(until: suspension.until.map { Date(timeIntervalSince1970: TimeInterval($0)) })
        return line.text(now: .now, calendar: calendar, locale: locale)
    }
}

/// What the profile page shows (#139). First match wins, in the lobby area's order (`LobbyPanelState`): offline, the
/// server not answering, signed out, practice only, terms due, then the read. Rows 1 to 5 come from the services'
/// state alone, before any read.
enum ProfilePageState: Equatable {
    /// "You're offline"; with her header when signed in, and no sign-in offered offline.
    case offline(signedIn: Bool)
    /// Game Center has her but there is no session, or the read failed: the line, with Try again.
    case retry(RestrictionLine)
    /// Only the sign-in prompt (#25): no name, no rating.
    case signIn
    /// Game Center's multiplayer restriction (#34).
    case practiceOnly
    /// The terms are due (#138): Review terms.
    case termsDue
    /// Through the gate, the read not in yet.
    case loading
    case loaded(Profile)

    init(isOnline: Bool, status: LobbyStatus, retryLine: RestrictionLine?, read: ProfileModel.Read) {
        if !isOnline {
            self = .offline(signedIn: status.isSignedIn)
        } else if let retryLine {
            self = .retry(retryLine)
        } else if !status.isSignedIn {
            self = .signIn
        } else if !status.canRaceOnline {
            self = .practiceOnly
        } else if !status.hasAcceptedTerms {
            self = .termsDue
        } else {
            switch read {
            case .pending: self = .loading
            case .loaded(let profile): self = .loaded(profile)
            // A signed-in player with no profile to show: the server isn't there to give one.
            case .failed: self = .retry(.unreachable)
            }
        }
    }

    /// Whether the page shows her avatar and name over the rest.
    var showsHeader: Bool {
        switch self {
        case .offline(let signedIn): signedIn
        case .signIn: false
        case .retry, .practiceOnly, .termsDue, .loading, .loaded: true
        }
    }
}
