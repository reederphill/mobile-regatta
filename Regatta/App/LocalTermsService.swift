import Foundation
import RegattaServices

/// The terms service on the device (#138) until the server records acceptances (#161): the version each Game Center
/// player accepted, kept in UserDefaults keyed by `gamePlayerID`. Given the server's service, the server decides:
/// its `needsAcceptance` beats an accept the device remembers, and only when it throws (offline, say) does the
/// device's record answer. `@unchecked Sendable` as `UserDefaultsAnalyticsStorage`: UserDefaults is thread-safe,
/// though not marked `Sendable`, and nothing else here changes.
nonisolated final class LocalTermsService: TermsService, @unchecked Sendable {
    /// The defaults key for a player's accepted version.
    static func key(for player: GamePlayerID) -> String { "terms.accepted.\(player.rawValue)" }

    private let identity: any IdentityService
    private let current: TermsVersion
    private let server: (any TermsService)?
    private let defaults: UserDefaults

    init(identity: any IdentityService, current: TermsVersion = TermsOfUse.version, server: (any TermsService)? = nil,
         defaults: UserDefaults) {
        self.identity = identity
        self.current = current
        self.server = server
        self.defaults = defaults
    }

    func status() async throws -> TermsStatus {
        guard let player = await identity.gamePlayerID() else {
            return .needsAcceptance(current: current, lastAccepted: nil)
        }
        if let server {
            do {
                let status = try await server.status()
                if case .accepted(let version) = status { record(version, for: player) }
                return status
            } catch {
                // The server can't say: what the device last recorded.
            }
        }
        return local(for: player)
    }

    func accept(_ version: TermsVersion) async throws -> TermsStatus {
        guard let player = await identity.gamePlayerID() else { throw IdentityError.notSignedIn }
        if let server {
            do {
                let status = try await server.accept(version)
                if status.isAccepted { record(status.current, for: player) }
                return status
            } catch let error as TermsError {
                throw error
            } catch {
                // Kept on the device; the server hears of it once #161 sends it.
            }
        }
        guard version == current else { throw TermsError.staleVersion(current: current) }
        record(version, for: player)
        return local(for: player)
    }

    private func local(for player: GamePlayerID) -> TermsStatus {
        let accepted = (defaults.object(forKey: Self.key(for: player)) as? Int).map(TermsVersion.init)
        return accepted == current ? .accepted(current) : .needsAcceptance(current: current, lastAccepted: accepted)
    }

    private func record(_ version: TermsVersion, for player: GamePlayerID) {
        defaults.set(version.rawValue, forKey: Self.key(for: player))
    }
}
