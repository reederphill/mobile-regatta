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
}
