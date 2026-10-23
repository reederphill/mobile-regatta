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
