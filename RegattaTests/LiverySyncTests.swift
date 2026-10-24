import Foundation
import RegattaCore
import RegattaServiceClient
import RegattaServices
import Testing
@testable import Regatta

/// Your livery between My boat and the server (#162): the server's copy wins at sign-in, a save goes up when it can,
/// and one made before that is uploaded first (owner 2026-10-12).
@MainActor @Suite struct LiverySyncTests {
    @MainActor final class Host: LiveryHost {
        var myLivery: Livery
        var isLiveryLocked = false
        let myBoatDefaults: UserDefaults
        private(set) var adoptedCounts: [Int] = []

        func adoptServerCount(_ count: Int) { adoptedCounts.append(count) }

        /// On defaults of its own, emptied first.
        init(_ livery: Livery) {
            let suite = "LiverySyncTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            myLivery = livery
            myBoatDefaults = defaults
        }
    }

    /// The server's profile, as far as the livery goes.
    nonisolated final class Profiles: ProfileService, @unchecked Sendable {
        var stored: Livery
        var completedRaces = 0
        var failure: (any Error)?
        private(set) var asked = 0
        private(set) var saves: [Livery] = []

        init(_ stored: Livery) { self.stored = stored }

        func profile() throws -> Profile {
            asked += 1
            if let failure { throw failure }
            return Profile(gamePlayerID: GamePlayerID("G:wren"), nickname: "Wren", rating: Rating(value: 1500, isProvisional: true),
                           completedRaces: completedRaces, wins: 0, suspension: nil, progress: EarnedProgress(earned: [], next: nil), livery: stored)
        }

        func saveLivery(_ livery: Livery) throws -> Livery {
            saves.append(livery)
            if let failure { throw failure }
            stored = livery
            return livery
        }
    }

    static let local = FleetLiveries.yours
    static let servers: Livery = {
        var livery = FleetLiveries.yours
        livery.sailNumber = 4321
        return livery
    }()
    static let edited: Livery = {
        var livery = FleetLiveries.yours
        livery.sailNumber = 77
        return livery
    }()

    private func rig(server: Livery = LiverySyncTests.servers) -> (LiverySync, Host, Profiles) {
        let (host, profiles) = (Host(Self.local), Profiles(server))
        let sync = LiverySync(profile: profiles)
        sync.isLive = true
        sync.attach(host: host)
        return (sync, host, profiles)
    }

    private func settle() async {
        for _ in 0..<5 {
            try? await Task.sleep(for: .milliseconds(10))
            await Task.yield()
        }
    }

    @Test func theServerLiveryReplacesTheLocalOneAtSignIn() async {
        let (sync, host, profiles) = rig()
        await sync.sessionOpened()
        #expect(host.myLivery == Self.servers)
        // Nothing is echoed back.
        #expect(profiles.saves == [] && profiles.asked == 1 && !sync.awaitsUpload)

        // In a locked fleet the device's livery is left alone.
        profiles.stored = Self.edited
        host.isLiveryLocked = true
        await sync.sessionOpened()
        #expect(host.myLivery == Self.servers && profiles.asked == 1)
    }

    /// #163, T5: at a race's close the server's count comes down, while the livery is still locked (the cover may be
    /// up), and the livery never does: neither the server's copy nor a save.
    @Test func raceClosedReadsTheCountWhileLockedAndPullsNoLivery() async {
        let (sync, host, profiles) = rig()
        profiles.completedRaces = 7
        host.isLiveryLocked = true
        await sync.raceClosed()
        #expect(host.adoptedCounts == [7] && profiles.asked == 1)
        #expect(host.myLivery == Self.local && profiles.saves.isEmpty, "the server's livery isn't taken at a close")
        sync.mayAskService = { false }
        await sync.raceClosed()
        #expect(host.adoptedCounts == [7] && profiles.asked == 1, "nothing asked of a gated player")
    }

    /// The server's count of her completed races comes down with its livery (#139, T3), even when the livery is the
    /// device's already; never in a locked fleet or for a gated player, and not on a read that failed.
    @Test func theServerCountComesDownAtSignIn() async {
        let (sync, host, profiles) = rig(server: Self.local)
        profiles.completedRaces = 32
        await sync.sessionOpened()
        #expect(host.adoptedCounts == [32] && host.myLivery == Self.local)

        profiles.completedRaces = 33
        host.isLiveryLocked = true
        await sync.sessionOpened()
        host.isLiveryLocked = false
        sync.mayAskService = { false }
        await sync.sessionOpened()
        sync.mayAskService = { true }
        profiles.failure = OnlineSessionError.notConnected
        await sync.sessionOpened()
        #expect(host.adoptedCounts == [32])
    }

    @Test func aSaveWhileOnlineIsStored() async {
        let (sync, host, profiles) = rig()
        host.myLivery = Self.edited
        sync.saved(Self.edited)
        await settle()
        #expect(profiles.saves == [Self.edited] && profiles.stored == Self.edited)
        #expect(!sync.awaitsUpload)
        // The next session finds the two alike.
        await sync.sessionOpened()
        #expect(host.myLivery == Self.edited && profiles.saves.count == 1)
    }

    @Test func anOfflineSaveIsSentAtTheNextOpen() async {
        let (sync, host, profiles) = rig()
        // Saved with no session to send it on, or to a server that didn't answer.
        profiles.failure = OnlineSessionError.notConnected
        host.myLivery = Self.edited
        sync.saved(Self.edited)
        await settle()
        #expect(sync.awaitsUpload && profiles.stored == Self.servers)

        // The session opens: her boat goes up before the server's copy could come down.
        profiles.failure = nil
        await sync.sessionOpened()
        #expect(profiles.stored == Self.edited && host.myLivery == Self.edited)
        #expect(!sync.awaitsUpload && profiles.asked == 0)

        // Never online on this device (no session at all): the save only waits.
        let (offline, offlineHost, offlineProfiles) = rig()
        offline.isLive = false
        offlineHost.myLivery = Self.edited
        offline.saved(Self.edited)
        await settle()
        #expect(offline.awaitsUpload && offlineProfiles.saves == [])
    }

    @Test func aRejectedLiveryLeavesTheLocalOne() async {
        let (sync, host, profiles) = rig()
        profiles.failure = ProfileError.invalidLivery(.notOwned)
        host.myLivery = Self.edited
        sync.saved(Self.edited)
        await settle()
        #expect(host.myLivery == Self.edited && profiles.stored == Self.servers)
        #expect(!sync.awaitsUpload, "the server won't have it: nothing is retried")

        // Locked in a fleet: kept for the next session.
        let (locked, lockedHost, lockedProfiles) = rig()
        lockedProfiles.failure = ProfileError.liveryLocked
        lockedHost.myLivery = Self.edited
        locked.saved(Self.edited)
        await settle()
        #expect(lockedHost.myLivery == Self.edited && locked.awaitsUpload)
    }

    @Test func nothingIsAskedOfAGatedPlayer() async {
        let (sync, host, profiles) = rig()
        sync.mayAskService = { false }
        await sync.sessionOpened()
        host.myLivery = Self.edited
        sync.saved(Self.edited)
        await settle()
        #expect(profiles.asked == 0 && profiles.saves == [])
        #expect(sync.awaitsUpload && host.myLivery == Self.edited)
    }
}
