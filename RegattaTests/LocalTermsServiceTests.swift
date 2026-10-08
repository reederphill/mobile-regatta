import Foundation
import RegattaServices
import Testing
@testable import Regatta

/// The terms kept on the device until the server's (#138): per Game Center player, asked again on a version bump; the
/// server's word beats the device's, and the device answers when the server can't.
@Suite struct LocalTermsServiceTests {
    private static let player = GameCenterPlayer(gamePlayerID: GamePlayerID("G:local-1"), alias: "Sailor")

    private static func defaults() -> UserDefaults {
        let name = "LocalTermsServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private static func identity(_ state: GameCenterState = .signedIn(player)) -> ScriptedIdentityService {
        ScriptedIdentityService(IdentityScenario(initial: state))
    }

    /// A server that can't be reached.
    private nonisolated struct Unreachable: TermsService {
        struct Down: Error {}
        func status() async throws -> TermsStatus { throw Down() }
        func accept(_ version: TermsVersion) async throws -> TermsStatus { throw Down() }
    }

    @Test func anAcceptanceIsKeptPerPlayer() async throws {
        let defaults = Self.defaults()
        let terms = LocalTermsService(identity: Self.identity(), current: TermsVersion(1), defaults: defaults)
        #expect(try await terms.status() == .needsAcceptance(current: TermsVersion(1), lastAccepted: nil))
        #expect(try await terms.accept(TermsVersion(1)) == .accepted(TermsVersion(1)))

        let relaunched = LocalTermsService(identity: Self.identity(), current: TermsVersion(1), defaults: defaults)
        #expect(try await relaunched.status() == .accepted(TermsVersion(1)), "kept across launches")

        let other = GameCenterPlayer(gamePlayerID: GamePlayerID("G:local-2"), alias: "Wren")
        let otherPlayer = LocalTermsService(identity: Self.identity(.signedIn(other)), current: TermsVersion(1), defaults: defaults)
        #expect(try await otherPlayer.status() == .needsAcceptance(current: TermsVersion(1), lastAccepted: nil), "per player")
    }

    @Test func aVersionBumpAsksAgain() async throws {
        let defaults = Self.defaults()
        _ = try await LocalTermsService(identity: Self.identity(), current: TermsVersion(1), defaults: defaults).accept(TermsVersion(1))
        let bumped = LocalTermsService(identity: Self.identity(), current: TermsVersion(2), defaults: defaults)
        #expect(try await bumped.status() == .needsAcceptance(current: TermsVersion(2), lastAccepted: TermsVersion(1)))
        await #expect(throws: TermsError.staleVersion(current: TermsVersion(2))) { try await bumped.accept(TermsVersion(1)) }
        #expect(try await bumped.accept(TermsVersion(2)) == .accepted(TermsVersion(2)))
    }

    @Test func theServerBeatsTheDeviceAndTheDeviceAnswersWhenItCant() async throws {
        let defaults = Self.defaults()
        _ = try await LocalTermsService(identity: Self.identity(), current: TermsVersion(1), defaults: defaults).accept(TermsVersion(1))

        let server = ScriptedTermsService(TermsScenario(current: TermsVersion(1), accepted: nil))
        let withServer = LocalTermsService(identity: Self.identity(), current: TermsVersion(1), server: server, defaults: defaults)
        #expect(try await withServer.status() == .needsAcceptance(current: TermsVersion(1), lastAccepted: nil),
                "the server's needsAcceptance beats the device's accept")

        let offline = LocalTermsService(identity: Self.identity(), current: TermsVersion(1), server: Unreachable(), defaults: defaults)
        #expect(try await offline.status() == .accepted(TermsVersion(1)), "the device answers when the server throws")
    }

    @Test func signedOutNeedsTheTermsAndCantAccept() async throws {
        let terms = LocalTermsService(identity: Self.identity(.signedOut), current: TermsVersion(1), defaults: Self.defaults())
        #expect(try await terms.status() == .needsAcceptance(current: TermsVersion(1), lastAccepted: nil))
        await #expect(throws: IdentityError.notSignedIn) { try await terms.accept(TermsVersion(1)) }
    }
}
