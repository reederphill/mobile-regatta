import GameKit
import UIKit

// What the profile (#139) shows of Game Center beyond the identity: the player's photo and the leaderboard. Each is a
// seam, chosen as `AppDelegate.makeServices` chooses Game Center: GameKit's on a device, a stand-in on the fakes, in
// UI tests and in unit tests, which never touch Game Center.

/// The signed-in player's Game Center photo (#25, #139). `OnlineStatus` loads it once a sign-in and keeps it in
/// memory only.
protocol PlayerPhotoSource {
    /// The photo, or nil with none (or none loaded): the page shows the symbol in its place.
    func photo() async -> UIImage?
}

/// No photo: the fakes, UI tests (so they always see the symbol) and unit tests.
struct NoPlayerPhoto: PlayerPhotoSource {
    func photo() async -> UIImage? { nil }
}

/// `GKLocalPlayer`'s small photo, when Game Center has her.
struct GameKitPlayerPhoto: PlayerPhotoSource {
    func photo() async -> UIImage? {
        let player = GKLocalPlayer.local
        guard player.isAuthenticated else { return nil }
        return try? await player.loadPhoto(for: .small)
    }
}

/// Opens Game Center's leaderboard (#16, #139). The server writes the scores (#151); the app only shows the board.
protocol LeaderboardPresenter: AnyObject {
    func showLeaderboard()
}

/// Game Center's own leaderboard UI, through the access point: `GKGameCenterViewController` is deprecated in the
/// iOS 26 SDK. With no leaderboard id until #165, `.leaderboards` opens the game's leaderboards.
final class GameKitLeaderboardPresenter: LeaderboardPresenter {
    func showLeaderboard() {
        GKAccessPoint.shared.trigger(state: .leaderboards) {}
    }
}

/// Counts the taps and opens nothing: the fakes and tests (#139, T4).
final class RecordingLeaderboardPresenter: LeaderboardPresenter {
    private(set) var taps = 0

    func showLeaderboard() { taps += 1 }
}

/// One row of the leaderboard's top (#142): what the hidden lobby panel lists.
struct LeaderboardEntry: Equatable, Sendable {
    var rank: Int
    var name: String
    var rating: Int
}

/// The top of Game Center's leaderboard (#25, #142, T10), for the lobby panel a restricted player, or one who hides
/// the chat, sees instead of the chat: read once each time the panel appears. Beside `LeaderboardPresenter`, which
/// opens the whole board.
protocol LeaderboardTopSource {
    /// The first `count` entries, best first; none when Game Center has no board or no player.
    func top(_ count: Int) async -> [LeaderboardEntry]
}

/// GameKit's: the game's first leaderboard (no id until #165), global, all time.
struct GameKitLeaderboardTop: LeaderboardTopSource {
    func top(_ count: Int) async -> [LeaderboardEntry] {
        guard GKLocalPlayer.local.isAuthenticated, count > 0,
              let board = try? await GKLeaderboard.loadLeaderboards(IDs: nil).first,
              let (_, entries, _) = try? await board.loadEntries(for: .global, timeScope: .allTime,
                                                                 range: NSRange(location: 1, length: count))
        else { return [] }
        return entries.map { LeaderboardEntry(rank: $0.rank, name: $0.player.displayName, rating: $0.score) }
    }
}

/// A fixed five: the fakes and tests (T10).
struct FixedLeaderboardTop: LeaderboardTopSource {
    var entries: [LeaderboardEntry] = FixedLeaderboardTop.five

    static let five = [("Wren", 1712), ("Kestrel", 1688), ("Tern", 1650), ("Skua", 1631), ("Petrel", 1604)]
        .enumerated().map { LeaderboardEntry(rank: $0.offset + 1, name: $0.element.0, rating: $0.element.1) }

    func top(_ count: Int) async -> [LeaderboardEntry] { Array(entries.prefix(count)) }
}
