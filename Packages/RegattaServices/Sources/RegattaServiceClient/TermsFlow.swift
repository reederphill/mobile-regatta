import RegattaServices

// What the app does about the Terms of Use once the server decides them (#161). The text is bundled with the app
// under a version; the server says which version is current.

public enum TermsPrompt: Equatable, Sendable {
    /// Nothing to ask: accepted, or not known yet.
    case none
    /// The sheet is due, for this version: the one I agree accepts, whatever the server says by then.
    case sheet(TermsVersion)
    /// The server's current terms are newer than the text this build carries. No sheet: the player would accept
    /// text she hasn't seen. Race online asks for an update instead.
    case updateRequired

    public init(status: TermsStatus?, bundled: TermsVersion) {
        guard let status, case .needsAcceptance(let current, _) = status else {
            self = .none
            return
        }
        self = current > bundled ? .updateRequired : .sheet(current)
    }
}
