// What the player may do online, from Game Center, the terms and the connection (#16, #25, #34): the one gating
// matrix Home's Race online, the lobby area and Race online's gate all read (#138).

/// Whether the player can chat and race online, why not, and what Race online does next.
public struct OnlineAccess: Equatable, Sendable {
    /// What a Race online tap does next.
    public enum Next: Equatable, Sendable {
        /// Signed out: Game Center's sign-in (#23, #25).
        case signIn
        /// Signed in, terms due: the Terms of Use sheet (#34).
        case terms
        /// Through the gate: the queue.
        case proceed
        /// Offline, or Game Center restricts multiplayer: Race online is disabled.
        case blocked
    }

    /// The lobby's chat can show (Settings' Hide lobby chat aside, a device setting): signed in, terms accepted,
    /// and neither `isUnderage` nor `isPersonalizedCommunicationRestricted` (#17, #34).
    public var chatVisible: Bool
    /// Race online can be tapped. Signed out it can: the tap signs in (#25).
    public var onlineAllowed: Bool
    /// The one line under a disabled Race online.
    public var reason: String?
    public var next: Next
    /// The terms are due: signed in, not accepted, and the player could chat or race online with them. A player
    /// who can do neither is never asked (#138, question 1).
    public var termsDue: Bool

    public init(chatVisible: Bool, onlineAllowed: Bool, reason: String?, next: Next, termsDue: Bool) {
        self.chatVisible = chatVisible
        self.onlineAllowed = onlineAllowed
        self.reason = reason
        self.next = next
        self.termsDue = termsDue
    }

    /// The matrix over the flags. `canChat` and `canRaceOnline` are Game Center's restrictions, read only when
    /// signed in; `termsAccepted` is whether the current terms are accepted (false when unknown).
    public init(isOnline: Bool, isSignedIn: Bool, canChat: Bool, canRaceOnline: Bool, termsAccepted: Bool) {
        guard isOnline else {
            self.init(chatVisible: false, onlineAllowed: false, reason: "Offline", next: .blocked, termsDue: false)
            return
        }
        guard isSignedIn else {
            self.init(chatVisible: false, onlineAllowed: true, reason: nil, next: .signIn, termsDue: false)
            return
        }
        let termsDue = !termsAccepted && (canChat || canRaceOnline)
        let next: Next = !canRaceOnline ? .blocked : termsDue ? .terms : .proceed
        self.init(chatVisible: canChat && termsAccepted, onlineAllowed: canRaceOnline,
                  reason: canRaceOnline ? nil : "Practice races only", next: next, termsDue: termsDue)
    }

    /// The matrix for Game Center's state and the terms' status (nil when unknown: not accepted).
    public init(gameCenter: GameCenterState, terms: TermsStatus?, isOnline: Bool) {
        let player = gameCenter.player
        self.init(isOnline: isOnline, isSignedIn: player != nil, canChat: player?.canChat ?? true,
                  canRaceOnline: player?.canRaceOnline ?? true, termsAccepted: terms?.isAccepted ?? false)
    }
}
