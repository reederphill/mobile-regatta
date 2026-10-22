import Foundation
import RegattaCore
import RegattaServices
import Testing
@testable import Regatta

/// The profile page's state (#139): first match wins, in the lobby area's order, rows 1 to 5 from the services'
/// state before any read.
@MainActor @Suite struct ProfilePageStateTests {
    static func status(signedIn: Bool = true, terms: Bool = true, canRace: Bool = true) -> LobbyStatus {
        var status = LobbyStatus()
        status.isSignedIn = signedIn
        status.hasAcceptedTerms = terms
        status.canRaceOnline = canRace
        return status
    }

    static let profile = Profile(
        gamePlayerID: GamePlayerID("G:wren"), nickname: "Wren", rating: Rating(value: 1500, isProvisional: true), completedRaces: 0,
        wins: 0, suspension: nil, progress: EarnedProgress(earned: [], next: nil), livery: FleetLiveries.yours)

    private func state(online: Bool = true, _ status: LobbyStatus = status(), retry: RestrictionLine? = nil,
                       read: ProfileModel.Read = .loaded(profile)) -> ProfilePageState {
        ProfilePageState(isOnline: online, status: status, retryLine: retry, read: read)
    }

    @Test func thePrecedenceRunsOfflineRetrySignInPracticeTermsLoadingLoaded() {
        // 1: offline beats everything; her header only when signed in.
        #expect(state(online: false, Self.status(signedIn: false), retry: .unreachable) == .offline(signedIn: false))
        #expect(state(online: false, Self.status(terms: false)) == .offline(signedIn: true))
        #expect(state(online: false).showsHeader && !state(online: false, Self.status(signedIn: false)).showsHeader)
        // 2: Game Center has her but no session: the line wins over signed out.
        #expect(state(Self.status(signedIn: false), retry: .couldNotSignIn) == .retry(.couldNotSignIn))
        #expect(state(Self.status(signedIn: false), retry: .unreachable) == .retry(.unreachable))
        // 3: signed out: the prompt alone, no header.
        let signIn = state(Self.status(signedIn: false, terms: false))
        #expect(signIn == .signIn && !signIn.showsHeader)
        // 4: practice only beats the terms.
        #expect(state(Self.status(terms: false, canRace: false)) == .practiceOnly)
        // 5: terms due.
        #expect(state(Self.status(terms: false)) == .termsDue)
        // 6 and 7: the read.
        #expect(state(read: .pending) == .loading)
        #expect(state() == .loaded(Self.profile))
        for shown in [state(read: .pending), state(), state(Self.status(terms: false)), state(Self.status(canRace: false))] {
            #expect(shown.showsHeader, "\(shown)")
        }
    }

    /// `ProfileError.notSignedIn` with Game Center signed in (a build with no server) is the no-session line with
    /// Try again, not the sign-in prompt; so is any other failure.
    @Test func aFailedReadWhileSignedInIsTheNoServerLine() {
        #expect(state(read: .failed) == .retry(.unreachable))
        #expect(state(Self.status(signedIn: false), read: .failed) == .signIn)
    }
}

/// The profile's read and its rows (#139), on the scripted profile.
@MainActor @Suite struct ProfileModelTests {
    /// Counts the reads (as `LiverySyncTests.Profiles` does).
    nonisolated final class Counting: ProfileService, @unchecked Sendable {
        var result: Profile?
        private(set) var asked = 0

        init(_ result: Profile?) { self.result = result }

        func profile() throws -> Profile {
            asked += 1
            guard let result else { throw ProfileError.notSignedIn }
            return result
        }

        func saveLivery(_ livery: Livery) throws -> Livery { livery }
    }

    static func profile(races: Int, next: Int?, suspension: RacingSuspension? = nil, provisional: Bool = true) -> Profile {
        var profile = ProfilePageStateTests.profile
        profile.completedRaces = races
        profile.rating.isProvisional = provisional
        profile.suspension = suspension
        profile.progress.next = next.map { EarnedMilestone(design: DesignID("skiff-earned-\($0)"), completedRaces: $0) }
        return profile
    }

    @Test func theProgressIsRacesOverTheNextThreshold() {
        #expect(ProfileModel.progressText(Self.profile(races: 0, next: 10)) == "0 / 10 races")
        #expect(ProfileModel.progressText(Self.profile(races: 32, next: 50)) == "32 / 50 races")
        // Never past the threshold, even if the count runs ahead of the server's milestones.
        #expect(ProfileModel.progressText(Self.profile(races: 55, next: 50)) == "50 / 50 races")
        #expect(ProfileModel.progressText(Self.profile(races: 240, next: nil)) == nil, "every design earned: no row")
    }

    @Test func theProvisionalFlagPassesThrough() async {
        for provisional in [true, false] {
            let model = ProfileModel(profile: Counting(Self.profile(races: 32, next: 50, provisional: provisional)))
            await model.refresh()
            guard case .loaded(let loaded) = model.state(isOnline: true, status: ProfilePageStateTests.status(), retryLine: nil) else {
                Issue.record("not loaded: \(model.read)")
                continue
            }
            #expect(loaded.rating.isProvisional == provisional)
        }
    }

    /// Race online's words and day-only date; "Racing closed" for a ban.
    @Test func theSuspensionIsRaceOnlinesLine() {
        var london = Calendar(identifier: .gregorian)
        london.timeZone = TimeZone(identifier: "Europe/London")!
        let locale = Locale(identifier: "en_GB")
        let until = Self.profile(races: 0, next: 10, suspension: RacingSuspension(until: FakeServiceScenario.suspendedUntil))
        #expect(ProfileModel.suspensionText(until, calendar: london, locale: locale) == "Racing paused until Wed 14 Oct")
        let ban = Self.profile(races: 0, next: 10, suspension: RacingSuspension(until: nil))
        #expect(ProfileModel.suspensionText(ban, calendar: london, locale: locale) == "Racing closed")
        #expect(ProfileModel.suspensionText(Self.profile(races: 0, next: 10)) == nil)
    }

    /// With a session, the profile isn't asked of a player short of the gate: the server would close the connection.
    @Test func nothingIsReadWhileTheServiceMayNotBeAsked() async {
        let service = Counting(Self.profile(races: 0, next: 10))
        var mayAsk = false
        let model = ProfileModel(profile: service, mayAskService: { mayAsk })
        await model.refresh()
        await model.refresh()
        #expect(service.asked == 0)
        #expect(model.read == .pending)
        #expect(model.state(isOnline: true, status: ProfilePageStateTests.status(), retryLine: nil) == .loading)
        mayAsk = true
        await model.refresh()
        #expect(service.asked == 1)
        #expect(model.read == .loaded(Self.profile(races: 0, next: 10)))
    }

    /// Read on each appear, and again after Sign in and the terms: `signed-out`'s scripted profile comes in with the
    /// sign-in.
    @Test func theProfileIsReadAgainOnAppearAndAfterSignIn() async throws {
        let service = Counting(Self.profile(races: 0, next: 10))
        let model = ProfileModel(profile: service)
        await model.refresh()
        await model.refresh()
        #expect(service.asked == 2, "each appear reads")

        let status = OnlineStatus(services: .fake(.signedOut))
        await status.refreshAccount()
        let signedOut = ProfileModel(profile: status.services.profile, mayAskService: { status.mayAskService })
        await signedOut.refresh()
        #expect(signedOut.read == .failed)
        #expect(signedOut.state(isOnline: true, status: status.lobbyStatus, retryLine: status.lobbyRetryLine) == .signIn)
        #expect(await status.signIn(analytics: .discarding()))
        #expect(status.signedInAlias == "Sailor")
        // Signed in, the terms come first, as the lobby area's Sign in has it; then the read.
        #expect(signedOut.state(isOnline: true, status: status.lobbyStatus, retryLine: status.lobbyRetryLine) == .termsDue)
        #expect(await status.acceptTerms(analytics: .discarding()))
        await signedOut.refresh()
        guard case .loaded(let loaded) = signedOut.state(isOnline: true, status: status.lobbyStatus, retryLine: status.lobbyRetryLine) else {
            Issue.record("no profile after the sign-in: \(signedOut.read)")
            return
        }
        #expect(loaded.rating == Rating(value: 1500, isProvisional: true))
        #expect(ProfileModel.progressText(loaded) == "0 / 10 races")
    }

    /// The fakes' leaderboard only counts its taps (T4); the fakes have no photo.
    @Test func theFakesRecordTheLeaderboardAndHaveNoPhoto() async throws {
        let leaderboard = RecordingLeaderboardPresenter()
        let status = OnlineStatus(services: .fake(.profileEstablished), leaderboard: leaderboard)
        await status.refreshAccount()
        status.leaderboard.showLeaderboard()
        #expect(leaderboard.taps == 1)
        #expect(status.playerPhoto == nil)
        #expect(status.signedInAlias == "Sailor")
    }
}
