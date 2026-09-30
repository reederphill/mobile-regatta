import RegattaServices

/// What `IdentityService` promises (#16, #34).
public struct IdentityServiceContract: ContractSuite {
    public enum Situation: Hashable, Sendable {
        /// Game Center has no player. Signing in may or may not succeed.
        case signedOut
        /// A signed-in player with no restrictions.
        case signedIn
        /// A signed-in player with `isMultiplayerGamingRestricted`.
        case multiplayerRestricted
    }

    public let name = "IdentityService"

    public init() {}

    public func run(_ makeService: (Situation) async throws -> any IdentityService) async throws {
        try await signedOut(makeService(.signedOut))
        try await signedIn(makeService(.signedIn))
        try await restricted(makeService(.multiplayerRestricted))
    }

    private func signedOut(_ service: any IdentityService) async throws {
        try await require(await service.state() == .signedOut, "a signed-out player's state isn't .signedOut")
        try await require(await service.gamePlayerID() == nil, "a signed-out player has a gamePlayerID")
        try await requireThrows(IdentityError.notSignedIn, "identitySignature() while signed out") {
            try await service.identitySignature()
        }
        // Whatever signing in comes to, the service agrees with itself about it.
        let after = await service.signIn()
        try await require(await service.state() == after, "state() after signIn() isn't what signIn() returned")
        try await require(await service.gamePlayerID() == after.player?.gamePlayerID, "gamePlayerID() doesn't follow the state after signIn()")
        if after.player == nil {
            try await requireThrows(IdentityError.notSignedIn, "identitySignature() after a declined sign-in") {
                try await service.identitySignature()
            }
        } else {
            try await checkSignature(service, after)
        }
    }

    private func signedIn(_ service: any IdentityService) async throws {
        let state = await service.state()
        guard let player = state.player else { try fail("a signed-in player's state has no player") }
        try await require(!player.gamePlayerID.rawValue.isEmpty, "the gamePlayerID is empty")
        try await require(await service.gamePlayerID() == player.gamePlayerID, "gamePlayerID() isn't the state's player's")
        try await require(player.canRaceOnline, "an unrestricted player can't race online")
        try await checkSignature(service, state)
        // Signing in when already signed in changes nothing.
        try await require(await service.signIn() == state, "signIn() changed a signed-in player's state")
    }

    private func restricted(_ service: any IdentityService) async throws {
        guard let player = await service.state().player else { try fail("a restricted player's state has no player") }
        try await require(player.isMultiplayerGamingRestricted && !player.canRaceOnline, "the restricted player can race online")
        // Restricted players still have an identity: practice races and Settings show it.
        try await require(await service.gamePlayerID() == player.gamePlayerID, "gamePlayerID() isn't the restricted player's")
    }

    private func checkSignature(_ service: any IdentityService, _ state: GameCenterState) async throws {
        let signature = try await service.identitySignature()
        try await require(signature.gamePlayerID == state.player?.gamePlayerID, "the signature is for another player")
        try await require(!signature.signature.isEmpty && !signature.salt.isEmpty, "the signature or its salt is empty")
        try await require(!signature.publicKeyURL.isEmpty, "the signature has no public key URL")
    }
}
