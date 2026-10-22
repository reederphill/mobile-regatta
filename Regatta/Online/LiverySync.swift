import Foundation
import RegattaCore
import RegattaServices

/// What the livery sync reads and sets: `AppModel`.
protocol LiveryHost: AnyObject {
    var myLivery: Livery { get set }
    /// After fleet lock the server keeps the livery the fleet locked with: nothing is synced until the race is over.
    var isLiveryLocked: Bool { get }
    /// Where My boat keeps its state (`MyBoatDefaults`): the sync's one flag lives beside the livery.
    var myBoatDefaults: UserDefaults { get }
    /// The server's count of her completed online races, read with its livery (#139): My boat's count follows it.
    func adoptServerCount(_ count: Int)
}

extension AppModel: LiveryHost {}

/// Your livery between My boat and the server (#162, #21). A livery saved in My boat is sent when the player is
/// through the gate, and kept to send at the next session when she isn't or the server didn't answer; with nothing
/// waiting, the server's copy replaces the device's each time a session opens (another device saved it). So a boat
/// customised before the first sign-in is uploaded first, and the server wins after that (owner 2026-10-12).
///
/// Nothing rides on the queue's join: the server locks the livery it has stored at fleet lock.
@MainActor
final class LiverySync {
    /// A livery saved on this device that the server hasn't stored yet.
    static let pendingKey = "liveryAwaitsUpload"

    private let profile: any ProfileService
    /// `OnlineStatus.mayAskService`: the profile is gated, and never asked of a player who isn't through it.
    var mayAskService: () -> Bool = { true }
    /// There is a session to sync over. Without one a save only waits.
    var isLive = false
    private weak var host: (any LiveryHost)?

    init(profile: any ProfileService) {
        self.profile = profile
    }

    /// The app model whose livery is synced; My boat's saves come through here from now on.
    func attach(_ model: AppModel) {
        attach(host: model)
        let keep = model.myBoat.onSave
        model.myBoat.onSave = { [weak self] livery in
            keep(livery)
            self?.saved(livery)
        }
    }

    func attach(host: any LiveryHost) { self.host = host }

    private(set) var awaitsUpload: Bool {
        get { host?.myBoatDefaults.bool(forKey: Self.pendingKey) ?? false }
        set { host?.myBoatDefaults.set(newValue, forKey: Self.pendingKey) }
    }

    /// My boat saved `livery`: stored on the server now if it can be, else at the next session.
    func saved(_ livery: Livery) {
        awaitsUpload = true
        guard isLive, mayAskService() else { return }
        Task { await upload(livery) }
    }

    /// A session opened for a player through the gate: a save that is waiting goes up; otherwise the server's copy
    /// comes down, with no save echoed back, and its count of her completed races with it (#139).
    func sessionOpened() async {
        guard isLive, let host, mayAskService(), !host.isLiveryLocked else { return }
        if awaitsUpload { return await upload(host.myLivery) }
        guard let read = try? await profile.profile() else { return }
        host.adoptServerCount(read.completedRaces)
        // A save, or a fleet lock, while the server was answering: that one stands.
        guard !awaitsUpload, !host.isLiveryLocked, read.livery != host.myLivery else { return }
        host.myLivery = read.livery
    }

    private func upload(_ livery: Livery) async {
        do {
            let stored = try await profile.saveLivery(livery)
            // Saved again meanwhile: the newer save's own upload follows.
            guard let host, host.myLivery == livery else { return }
            awaitsUpload = false
            if stored != livery { host.myLivery = stored }
        } catch ProfileError.invalidLivery {
            // The server won't store it (a design it doesn't count as hers): the device keeps it, and nothing is retried.
            awaitsUpload = false
        } catch {
            // Locked in a fleet, or no answer: again at the next session.
        }
    }
}
