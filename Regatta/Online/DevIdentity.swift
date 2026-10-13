#if DEBUG
import Foundation
import RegattaServiceClient
import RegattaServices

/// A stand-in for Game Center against a dev server (#161): `-devIdentity <n>` is signed in as `T:dev-<n>` /
/// `G:dev-<n>`, with `-devRestrictions underage,communication,multiplayer` as Game Center would report them. The
/// dev server's verifier takes any fresh, well-formed signature. Debug builds only: Release can't compile it.
nonisolated enum DevIdentity {
    enum Restriction: String, CaseIterable {
        case underage, communication, multiplayer
    }

    /// Settings' Dev player field (#162): the dev player a launch without `-devIdentity` signs in as, so a phone can
    /// race a dev server without launch arguments. Read at launch.
    static let defaultsKey = "devPlayer"

    /// The dev player this launch signs in as: `-devIdentity`, else the number in Settings' field, else none.
    static func number(launchOptions: LaunchOptions, defaults: UserDefaults) -> Int? {
        if let number = launchOptions.devIdentity { return number }
        guard !launchOptions.uiTesting, let text = defaults.string(forKey: defaultsKey), let number = Int(text), number >= 0 else { return nil }
        return number
    }

    static func player(_ number: Int, restrictions: Set<Restriction> = []) -> DevicePlayer {
        DevicePlayer(teamPlayerID: "T:dev-\(number)", player: GameCenterPlayer(
            gamePlayerID: GamePlayerID("G:dev-\(number)"), alias: "Dev \(number)", isUnderage: restrictions.contains(.underage),
            isPersonalizedCommunicationRestricted: restrictions.contains(.communication),
            isMultiplayerGamingRestricted: restrictions.contains(.multiplayer)))
    }

    static func device(_ number: Int, restrictions: Set<Restriction> = []) -> ScriptedDeviceIdentity {
        ScriptedDeviceIdentity(player: player(number, restrictions: restrictions)) { player in
            IdentitySignature(
                gamePlayerID: player.player.gamePlayerID, teamPlayerID: player.teamPlayerID, publicKeyURL: "https://dev.invalid/gc-dev.cer",
                signature: Array(UUID().uuidString.utf8), salt: [1, 2, 3, 4], timestamp: UInt64(Date().timeIntervalSince1970 * 1000))
        }
    }
}
#endif
