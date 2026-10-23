import Foundation
import RegattaCore
import RegattaServices
import Testing
@testable import Regatta

/// The boat card's boat (#142, T9): a spinner while the card is read, the card's render and sail number, and a plain
/// stand-in in the line's chip colours, with no number, when the lobby gives no card.
@MainActor struct BoatCardModelTests {
    static let chip = LiveryChip(deck: SwatchID("charcoal"), sail: SwatchID("white"))
    static let wren = BoatCard(gamePlayerID: GamePlayerID("G:fake-2"), nickname: "Wren", rating: Rating(value: 1610, isProvisional: false),
                               livery: Livery(design: DesignID("skiff-plain"), colours: [SwatchID("charcoal"), SwatchID("white")],
                                              sailNumber: 112))

    @Test func aSpinnerUntilTheCardAnswers() {
        let boat = BoatCardBoat(card: nil, isLoading: true, chip: Self.chip)
        #expect(boat == .loading)
        #expect(boat.sailNumber == nil)
    }

    @Test func theCardsRenderAndSailNumber() {
        let boat = BoatCardBoat(card: Self.wren, isLoading: false, chip: Self.chip)
        #expect(boat == .render(Self.wren.livery))
        #expect(boat.sailNumber == 112)
    }

    /// No card (her own chip opens none, a blocked or unknown player, a failed read): her chip's colours on the plain
    /// design, and no number on the sail or under it.
    @Test func noCardDrawsThePlainStandIn() {
        let boat = BoatCardBoat(card: nil, isLoading: false, chip: Self.chip)
        guard case .standIn(let livery) = boat else { Issue.record("no stand-in: \(boat)"); return }
        #expect(boat.sailNumber == nil)
        let look = LiveryArt.Look(livery)
        #expect(look.pattern == .plain && look.sailNumber == 0)
        #expect(look.deck == LiveryArt.rgb(Self.chip.deck) && look.sail == LiveryArt.rgb(Self.chip.sail))
    }

    /// The model's read on the fakes: Wren's card; a refusal is no card, so the sheet draws the stand-in.
    @Test func theReadGivesTheCardOrNone() async {
        let model = LobbyModel(lobby: ServiceSet.fake(.joinable).lobby)
        let card = await model.boatCard(GamePlayerID("G:fake-2"))
        #expect(card?.livery.sailNumber == 112)
        #expect(BoatCardBoat(card: card, isLoading: false, chip: Self.chip).sailNumber == 112)
        let none = await model.boatCard(GamePlayerID("G:nobody"))
        #expect(none == nil)
        #expect(BoatCardBoat(card: none, isLoading: false, chip: Self.chip) == .standIn(BoatCardBoat.plain(Self.chip)))
    }
}
