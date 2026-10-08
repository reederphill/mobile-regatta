import RegattaServices
import Testing

/// The gating matrix (#138): every combination of connection, sign-in, Game Center's restrictions and the terms.
@Suite struct OnlineAccessTests {
    typealias Row = (online: Bool, signedIn: Bool, canChat: Bool, canRace: Bool, accepted: Bool)

    /// Every one of the 32 combinations of the five flags.
    static let everyRow: [Row] = (0..<32).map { bits in
        (bits & 1 != 0, bits & 2 != 0, bits & 4 != 0, bits & 8 != 0, bits & 16 != 0)
    }

    static func access(_ row: Row) -> OnlineAccess {
        OnlineAccess(isOnline: row.online, isSignedIn: row.signedIn, canChat: row.canChat, canRaceOnline: row.canRace,
                     termsAccepted: row.accepted)
    }

    /// Offline beats everything: Race online disabled "Offline", no chat, no terms.
    @Test func offlineBlocksEverything() {
        for row in Self.everyRow where !row.online {
            #expect(Self.access(row) == OnlineAccess(chatVisible: false, onlineAllowed: false, reason: "Offline", next: .blocked,
                                                     termsDue: false), "\(row)")
        }
    }

    /// Signed out: Race online enabled and signs in (#25); no chat; Game Center's flags and the terms don't count.
    @Test func signedOutSignsIn() {
        for row in Self.everyRow where row.online && !row.signedIn {
            #expect(Self.access(row) == OnlineAccess(chatVisible: false, onlineAllowed: true, reason: nil, next: .signIn,
                                                     termsDue: false), "\(row)")
        }
    }

    /// Signed in and online: the eight combinations of the two restrictions and the terms, spelled out.
    @Test func signedInFollowsTheRestrictionsAndTheTerms() {
        let expected: [(canChat: Bool, canRace: Bool, accepted: Bool, OnlineAccess)] = [
            // Unrestricted.
            (true, true, false, OnlineAccess(chatVisible: false, onlineAllowed: true, reason: nil, next: .terms, termsDue: true)),
            (true, true, true, OnlineAccess(chatVisible: true, onlineAllowed: true, reason: nil, next: .proceed, termsDue: false)),
            // Underage or communication-restricted: racing still needs the terms; chat never shows.
            (false, true, false, OnlineAccess(chatVisible: false, onlineAllowed: true, reason: nil, next: .terms, termsDue: true)),
            (false, true, true, OnlineAccess(chatVisible: false, onlineAllowed: true, reason: nil, next: .proceed, termsDue: false)),
            // Multiplayer-restricted: practice only; the lobby follows the chat rules, so chat still needs the terms.
            (true, false, false, OnlineAccess(chatVisible: false, onlineAllowed: false, reason: "Practice races only",
                                              next: .blocked, termsDue: true)),
            (true, false, true, OnlineAccess(chatVisible: true, onlineAllowed: false, reason: "Practice races only",
                                             next: .blocked, termsDue: false)),
            // Fully restricted: never asked for the terms (question 1).
            (false, false, false, OnlineAccess(chatVisible: false, onlineAllowed: false, reason: "Practice races only",
                                               next: .blocked, termsDue: false)),
            (false, false, true, OnlineAccess(chatVisible: false, onlineAllowed: false, reason: "Practice races only",
                                              next: .blocked, termsDue: false)),
        ]
        #expect(expected.count == Self.everyRow.filter { $0.online && $0.signedIn }.count)
        for (canChat, canRace, accepted, access) in expected {
            let row: Row = (true, true, canChat, canRace, accepted)
            #expect(Self.access(row) == access, "\(row)")
        }
    }

    /// Game Center's state and the terms' status read into the same flags; unknown terms are not accepted.
    @Test func gameCenterStateAndTermsStatusReadIntoTheFlags() {
        let player = GameCenterPlayer(gamePlayerID: GamePlayerID("G:1"), alias: "Sailor")
        var restricted = player
        restricted.isMultiplayerGamingRestricted = true
        var underage = player
        underage.isUnderage = true
        let v1 = TermsVersion(1), v2 = TermsVersion(2)

        #expect(OnlineAccess(gameCenter: .signedOut, terms: nil, isOnline: true).next == .signIn)
        #expect(OnlineAccess(gameCenter: .signedIn(player), terms: nil, isOnline: true).next == .terms)
        #expect(OnlineAccess(gameCenter: .signedIn(player), terms: .accepted(v1), isOnline: true).next == .proceed)
        #expect(OnlineAccess(gameCenter: .signedIn(player), terms: .needsAcceptance(current: v2, lastAccepted: v1),
                             isOnline: true).next == .terms, "a version bump asks again")
        #expect(OnlineAccess(gameCenter: .signedIn(restricted), terms: .accepted(v1), isOnline: true).reason == "Practice races only")
        #expect(!OnlineAccess(gameCenter: .signedIn(underage), terms: .accepted(v1), isOnline: true).chatVisible)
        #expect(OnlineAccess(gameCenter: .signedIn(player), terms: .accepted(v1), isOnline: false).reason == "Offline")
    }
}
