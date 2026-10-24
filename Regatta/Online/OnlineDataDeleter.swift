import Foundation
import RegattaServiceClient
import RegattaServices

/// Settings → Delete my online data (#166, #28): the plan is fetched on the row's tap (T4), the confirmation dialog
/// shows only with one, and its Delete deletes with the plan's confirmation. A delete that went through, or a server
/// with nothing left for her, wipes what the device kept of her online racing (`AppModel.forgetOnlineData`, her terms
/// record) and reads the account again once the session is idle. Signed out, unreachable or too slow leaves everything.
///
/// With a session the deletion is the session's (`ServiceSet.adopt`), which holds her offline afterwards until she
/// signs in herself (O1); without one (no endpoint, `-fakeServices`) it is the fakes' scripted answers.
struct OnlineDataDeleter {
    /// What the row's tap leads to.
    enum Step: Equatable {
        /// The confirmation dialog, for this plan.
        case confirm(DeletionPlan)
        /// No dialog: the notice alone.
        case notice(String)
    }

    /// The notices (O4).
    enum Notice {
        // TODO-COPY (#171): O4's drafts.
        static let deleted = "Your online data is deleted."
        static let nothingToDelete = "You have no online data to delete."
        static let notSignedIn = "Sign in to Game Center first."
        static let unreachable = "Can't reach the server. Try again later."
        static let expired = "That took too long. Try again."
    }

    let deletion: any DataDeletionService
    /// Her Game Center id now, for the terms record kept under it; read before the delete, while she is signed in.
    let player: () async -> GamePlayerID?
    /// Clears the device's online caches for her.
    let wipe: (GamePlayerID?) -> Void
    /// After a wipe, with the session idle: the account is read again (`OnlineStatus.refreshAccount`).
    let settled: () async -> Void

    /// The row's tap: a plan to confirm, or why there is none.
    func prepare() async -> Step {
        let player = await player()
        do {
            return .confirm(try await deletion.plan())
        } catch {
            return .notice(await notice(for: error, player: player))
        }
    }

    /// The dialog's Delete: the notice it leaves.
    func confirm(_ plan: DeletionPlan) async -> String {
        let player = await player()
        do {
            try await deletion.delete(confirmedBy: plan.confirmation)
        } catch {
            return await notice(for: error, player: player)
        }
        wipe(player)
        await settled()
        return Notice.deleted
    }

    private func notice(for error: any Error, player: GamePlayerID?) async -> String {
        switch error as? DataDeletionError {
        case .nothingToDelete:
            // Deleted from another device, or already here: the device's copy goes too.
            wipe(player)
            await settled()
            return Notice.nothingToDelete
        case .notSignedIn: return Notice.notSignedIn
        case .invalidConfirmation: return Notice.expired
        case nil: return Notice.unreachable
        }
    }
}

extension OnlineDataDeleter {
    /// The app's: `status`'s deletion service, wiping `model` and the terms record in `defaults` (the device's own,
    /// `LocalTermsService`).
    @MainActor static func app(status: OnlineStatus, model: AppModel, defaults: UserDefaults = .standard) -> OnlineDataDeleter {
        OnlineDataDeleter(
            deletion: status.services.deletion,
            player: { [weak status] in
                if let player = status?.devicePlayer?.player.gamePlayerID { return player }
                return await status?.services.identity.gamePlayerID()
            },
            wipe: { [weak model] player in
                model?.forgetOnlineData()
                if let player { defaults.removeObject(forKey: LocalTermsService.key(for: player)) }
            },
            settled: { [weak status] in await status?.refreshAccount() })
    }

    /// With no services (previews, tests of the page): a signed-out player's answers, wiping nothing.
    static let unconnected = OnlineDataDeleter(deletion: ServiceSet.fake(.signedOut).deletion, player: { nil }, wipe: { _ in },
                                               settled: {})
}

/// The players held after a deletion (#166, O1), in the app's defaults: a relaunch holds them still.
/// `@unchecked Sendable` as `LocalTermsService`: UserDefaults is thread-safe, though not marked `Sendable`.
nonisolated final class DefaultsHeldPlayerStore: HeldPlayerStore, @unchecked Sendable {
    static let key = "online.heldPlayers"
    private let defaults: UserDefaults

    init(defaults: UserDefaults) { self.defaults = defaults }

    private var held: Set<String> { Set(defaults.stringArray(forKey: Self.key) ?? []) }

    func isHeld(_ teamPlayerID: String) -> Bool { held.contains(teamPlayerID) }

    func hold(_ teamPlayerID: String) { defaults.set(held.union([teamPlayerID]).sorted(), forKey: Self.key) }

    func release(_ teamPlayerID: String) {
        let rest = held.subtracting([teamPlayerID])
        if rest.isEmpty { defaults.removeObject(forKey: Self.key) } else { defaults.set(rest.sorted(), forKey: Self.key) }
    }
}
