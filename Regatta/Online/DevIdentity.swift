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
