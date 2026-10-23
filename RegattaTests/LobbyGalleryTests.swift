import RegattaServices
import Testing
@testable import Regatta

/// The lobby gallery (#142, G15): `{ "gallery": "lobby" }` is Home with the lobby open on every kind of line, asking
/// no service.
@MainActor struct LobbyGalleryTests {
    @Test func theGalleryShowsEveryKindOfLine() throws {
        #expect(try RenderFixture.gallery(named: "lobby", in: RenderFixtureTests.fixtures) == .lobby)
        let model = try #require(HomeFixture.lobby.lobby)
        #expect(model.phase == .open && model.composer.canPostFreeText)
        let lines = model.feed.lines.map(\.message)
        #expect(lines.count == LobbyFixture.lines.count)
        #expect(lines.contains { if case .system(.gun) = $0.kind { true } else { false } })
        #expect(lines.contains { if case .system(.winner) = $0.kind { true } else { false } })
        let posts = lines.compactMap(\.post)
        #expect(posts.contains { $0.author.gamePlayerID != model.me && !$0.author.rating.isProvisional })
        #expect(posts.contains { $0.author.gamePlayerID != model.me && $0.author.rating.isProvisional })
        #expect(posts.contains { $0.author.gamePlayerID == model.me && $0.delivery == .sent })
        #expect(posts.contains { $0.author.gamePlayerID == model.me && $0.delivery == .notSent })
    }

    /// The Rejoin race gallery (#141): she is mid-race, so the lobby is in its silence window (G11), not an empty feed.
    @Test func theRejoinGalleryIsSilent() throws {
        let fixture = HomeFixture.rejoin
        #expect(fixture.rejoin != nil)
        let model = try #require(fixture.lobby)
        #expect(model.phase == .silent && model.feed.lines.isEmpty && !model.composer.canPostFreeText)
        let status = LobbyStatus(isSignedIn: true, hasAcceptedTerms: true)
        #expect(LobbyPanelState(isOnline: true, status: status, lobby: model.phase) == .silent)
    }

    /// The Last race gallery (#141): the lobby open on a short feed with the composer, fewer lines than the lobby
    /// gallery's so the Last race row and the feed fit unscrolled.
    @Test func theLastRaceGalleryShowsAShortFeed() throws {
        let fixture = HomeFixture.lastRaceRating
        #expect(fixture.lastRace != nil)
        let model = try #require(fixture.lobby)
        #expect(model.phase == .open && model.composer.canPostFreeText)
        #expect(!model.feed.lines.isEmpty && model.feed.lines.count < LobbyFixture.lines.count)
        let status = LobbyStatus(isSignedIn: true, hasAcceptedTerms: true)
        #expect(LobbyPanelState(isOnline: true, status: status, lobby: model.phase) == .lobby)
    }
}
