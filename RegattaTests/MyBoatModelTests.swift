import Foundation
import Testing
import RegattaCore
import RegattaServices
@testable import Regatta

/// A fresh defaults suite of its own, emptied.
private func emptySuite(_ name: String = "MyBoatTests-\(UUID().uuidString)") -> UserDefaults {
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

private let stripe = Livery(design: DesignID("skiff-stripe"),
                            colours: [SwatchID("sky-blue"), SwatchID("white"), SwatchID("charcoal")], sailNumber: 42)

/// Your livery on the device (#136).
@MainActor @Suite struct LiveryStoreTests {
    @Test func keepsTheSavedLivery() {
        let store = LiveryStore(defaults: emptySuite())
        store.save(stripe)
        #expect(store.load(boatClass: "skiff") == stripe)
    }

    /// #21: a new player's livery is a random free starter design in palette colours with a random number, saved at
    /// once so the next launch draws the same boat.
    @Test func aNewPlayerGetsARandomFreeStarterSavedAtOnce() throws {
        let store = LiveryStore(defaults: emptySuite())
        let livery = store.load(boatClass: "skiff", seed: 99)
        let expected = try #require(LiveryCatalogue.bundled.newPlayerLivery(boatClass: "skiff", seed: 99))
        #expect(livery == expected)
        #expect(LiveryCatalogue.bundled.design(livery.design)?.acquisition.isFree == true)
        #expect(store.load(boatClass: "skiff", seed: 1) == expected)
    }

    /// A stored livery that's no longer valid for the class (an unknown design, a bad number) gives way to a new one.
    @Test func anInvalidStoredLiveryIsReplaced() {
        let store = LiveryStore(defaults: emptySuite())
        store.save(Livery(design: DesignID("skiff-gone"), colours: [], sailNumber: 7))
        #expect(store.load(boatClass: "skiff", fallback: FleetLiveries.yours) == FleetLiveries.yours)
        store.save(Livery(design: DesignID("ilca-dinghy-plain"), colours: [SwatchID("white"), SwatchID("white")], sailNumber: 7))
        #expect(store.load(boatClass: "skiff", fallback: stripe) == stripe)
    }

    @Test func completedRacesStartAtZero() {
        let races = CompletedRacesStore(defaults: emptySuite())
        #expect(races.count == 0)
        races.count = 12
        #expect(races.count == 12)
    }
}

/// My boat's editor and shop (#136, #21).
@MainActor @Suite struct MyBoatModelTests {
    /// Paid and earned designs the tests treat as drawn: none has art until #169, and an undrawn design can't be
    /// tried on, so the shop and the earned lock are checked here rather than in the UI tests.
    private static let drawnForTests: Set<DesignID> = [DesignID("skiff-stars"), DesignID("skiff-band"),
                                                       DesignID("skiff-earned-10")]

    private func model(_ saved: Livery = stripe, owned: Set<DesignID> = [], completed: Int = 0,
                       store: (any StoreService)? = nil, canBuy: Bool = true) -> MyBoatModel {
        MyBoatModel(saved: saved, owned: owned, completedRaces: completed, store: store, canBuy: canBuy,
                    isDrawn: { MyBoatModel.hasArt($0) || Self.drawnForTests.contains($0.id) })
    }

    @Test func opensOnTheSavedLiveryWithNothingToSave() {
        let model = model()
        #expect(model.draft == stripe)
        #expect(model.action == .saved)
        #expect(!model.action.isEnabled)
        #expect(model.numberText == "42")
    }

    @Test func colourAndNumberChangesSave() {
        let model = model()
        var saved: [Livery] = []
        model.onSave = { saved.append($0) }
        model.setColour(SwatchID("lavender"), for: .deck)
        model.numberText = "7"
        #expect(model.action == .save)
        model.save()
        let expected = Livery(design: stripe.design, colours: [SwatchID("lavender"), SwatchID("white"), SwatchID("charcoal")],
                              sailNumber: 7)
        #expect(saved == [expected])
        #expect(model.saved == expected)
        #expect(model.action == .saved)
        model.save()
        #expect(saved.count == 1, "nothing to save saves nothing")
    }

    /// The safe palette only: off-white fills a sail, never a deck.
    @Test func coloursComeFromTheSafePalette() {
        let model = model()
        model.setColour(SwatchID("off-white"), for: .deck)
        model.setColour(SwatchID("magenta"), for: .sail)
        #expect(model.draft == stripe)
        #expect(model.swatches(for: .sail).map(\.id).contains(SwatchID("off-white")))
        #expect(!model.swatches(for: .deck).map(\.id).contains(SwatchID("off-white")))
        model.setColour(SwatchID("off-white"), for: .sail)
        #expect(model.draft.colours.last == SwatchID("off-white"))
    }

    /// Colours carry across designs by slot, never by position: a 2-slot design drops the accent but keeps it for
    /// the next 3-slot one.
    @Test func coloursCarryAcrossDesignsBySlot() {
        let model = model()
        model.select(DesignID("skiff-plain"))
        #expect(model.draft.colours == [SwatchID("sky-blue"), SwatchID("charcoal")])
        model.select(DesignID("skiff-sheer"))
        #expect(model.draft.colours == [SwatchID("sky-blue"), SwatchID("white"), SwatchID("charcoal")])
    }

    /// With no accent yet, the first accent swatch that isn't the deck colour.
    @Test func aFirstAccentIsntTheDeckColour() {
        let model = model(Livery(design: DesignID("skiff-plain"), colours: [SwatchID("white"), SwatchID("sky-blue")],
                                 sailNumber: 5))
        model.select(DesignID("skiff-stripe"))
        #expect(model.draft.colours == [SwatchID("white"), SwatchID("charcoal"), SwatchID("sky-blue")])
    }

    /// #21: any paid design can be tried on in your colours; you can't save one you don't own.
    @Test func aPaidUnownedDesignShowsBuyAndCannotBeSaved() {
        let model = model()
        var saves = 0
        model.onSave = { _ in saves += 1 }
        model.select(DesignID("skiff-stars"))
        #expect(model.draft.design == DesignID("skiff-stars"))
        #expect(model.draft.colours == stripe.colours, "tried on in your colours")
        #expect(model.action == .buy(price: "$2.99"))
        #expect(model.action.title == "Buy $2.99")
        model.setColour(SwatchID("lavender"), for: .deck)
        #expect(model.action == .buy(price: "$2.99"), "a colour change is still Buy, not Save")
        model.save()
        #expect(saves == 0)
        #expect(model.saved == stripe)
        model.discardDraft()
        #expect(model.draft == stripe, "leaving keeps your livery")
        let band = LiveryCatalogue.bundled.design(DesignID("skiff-band"))!
        #expect(model.mark(for: band) == .price)
        #expect(model.price(of: band) == "$0.99")
        #expect(model.caption(for: band) == nil, "a paid design's price is on Buy, not under it")

        let owned = self.model(owned: [DesignID("skiff-stars")])
        owned.select(DesignID("skiff-stars"))
        #expect(owned.action == .save)
        #expect(owned.mark(for: owned.selectedDesign!) == nil)
        #expect(owned.price(of: owned.selectedDesign!) == nil)
    }

    /// A build that can't buy yet (Release until #137) shows the price and a disabled Soon.
    @Test func aBuildThatCantBuyShowsSoon() {
        let model = model(canBuy: false)
        model.select(DesignID("skiff-band"))
        #expect(model.action == .soon(price: "$0.99"))
        #expect(!model.action.isEnabled)
        model.buy()
        #expect(!model.isBuying)
    }

    /// Earned designs: tried on, but Save stays off until enough online races, shown as "3 / 10 races".
    @Test func anEarnedDesignIsLockedUntilEnoughRaces() {
        let model = model(completed: 3)
        model.select(DesignID("skiff-earned-10"))
        #expect(model.action == .locked(completed: 3, needed: 10))
        #expect(model.action.title == "3 / 10 races")
        #expect(!model.action.isEnabled)
        #expect(model.caption(for: model.selectedDesign!) == "3 / 10 races")
        #expect(model.mark(for: model.selectedDesign!) == .lock)
        let fifty = LiveryCatalogue.bundled.design(DesignID("skiff-earned-50"))!
        #expect(model.mark(for: fifty) == .lock)
        #expect(model.caption(for: fifty) == nil, "races show only on the selected design")
        model.save()
        #expect(model.saved == stripe)

        let earned = self.model(completed: 10)
        earned.select(DesignID("skiff-earned-10"))
        #expect(earned.action == .save)
        #expect(earned.caption(for: earned.selectedDesign!) == nil)
        #expect(earned.mark(for: earned.selectedDesign!) == nil)
    }

    /// Decal lists one plain list: owned first, then earned, then paid, in catalogue order within each (owner review
    /// of #382).
    @Test func designsListOwnedThenEarnedThenPaid() {
        let model = MyBoatModel(saved: stripe, owned: [DesignID("skiff-tiger")], completedRaces: 10, canBuy: true,
                                isDrawn: { _ in true })
        let ids = model.listedDesigns.map(\.id.rawValue)
        #expect(ids == ["skiff-plain", "skiff-stripe", "skiff-sheer", "skiff-split", "skiff-earned-10", "skiff-tiger",
                        "skiff-earned-50", "skiff-earned-200",
                        "skiff-band", "skiff-pinstripe", "skiff-checker-bow", "skiff-dash", "skiff-wave-hull",
                        "skiff-arrow", "skiff-chevron-sail", "skiff-diagonal", "skiff-race-stripes", "skiff-stars",
                        "skiff-swirl"])
    }

    /// A design with neither its pattern nor its graphic drawn yet would look plain, so it's never listed or tried on
    /// (#169 draws them); Try it on one opens the saved design.
    @Test func designsWithNoArtAreNeverShown() {
        let model = MyBoatModel(saved: stripe, canBuy: true)
        #expect(model.listedDesigns.map(\.id.rawValue) == ["skiff-plain", "skiff-stripe", "skiff-sheer", "skiff-split"])
        model.select(DesignID("skiff-stars"))
        #expect(model.design == stripe.design, "an undrawn design isn't tried on")
        model.open(trying: DesignID("skiff-stars"))
        #expect(model.design == stripe.design, "Try it on an undrawn design opens the saved one")
        #expect(!model.listedDesigns.contains { $0.id == DesignID("skiff-stars") })
        #expect(MyBoatModel.hasArt(LiveryCatalogue.bundled.design(DesignID("skiff-sheer"))!))
        #expect(MyBoatModel.hasArt(LiveryCatalogue.bundled.design(DesignID("skiff-plain"))!))
        #expect(!MyBoatModel.hasArt(LiveryCatalogue.bundled.design(DesignID("skiff-stars"))!))
        #expect(!MyBoatModel.hasArt(LiveryCatalogue.bundled.design(DesignID("skiff-band"))!), "an undrawn pattern on a plain sail")
    }

    /// The page opens on Decal, and leaving it goes back there.
    @Test func sectionsOpenOnDecal() {
        let model = model()
        #expect(model.section == .decal)
        model.section = .number
        model.discardDraft()
        #expect(model.section == .decal)
        #expect(MyBoatModel.Section.allCases.map(\.title) == ["Decal", "Colours", "Sail", "Number"])
    }

    /// After fleet lock every control is inert (#25).
    @Test func fleetLockMakesEveryControlInert() {
        let model = model()
        model.isFleetLocked = true
        #expect(model.action == .fleetLocked)
        model.select(DesignID("skiff-plain"))
        model.setColour(SwatchID("lavender"), for: .deck)
        model.numberText = "8"
        model.save()
        #expect(model.draft == stripe)
        #expect(model.numberText == "42")
        #expect(model.saved == stripe)
    }

    /// The sail number is digits only, 1 to 9999: 0, 10000, letters and empty are refused, typed text is kept as is,
    /// and the render keeps the saved number meanwhile.
    @Test func sailNumberRejectsZeroTenThousandLettersAndEmpty() {
        let model = model()
        var saves = 0
        model.onSave = { _ in saves += 1 }
        for text in ["0", "10000", "ab", "12a", "", " 12", "-5", "1.5"] {
            model.numberText = text
            #expect(model.numberText == text, "typed text isn't filtered")
            #expect(model.sailNumber == nil, "\(text) is a sail number")
            #expect(model.action == .invalidNumber, "\(text)")
            #expect(!model.action.isEnabled)
            #expect(model.draft.sailNumber == 42)
            model.save()
        }
        #expect(saves == 0)
        model.numberText = "9999"
        #expect(model.action == .save)
        model.numberText = "1"
        #expect(model.action == .save)
    }

    /// A number typed with leading zeros reads as saved after Save: "0042" shows 42.
    @Test func savingShowsTheNumberAsSaved() {
        let model = model()
        model.numberText = "0007"
        #expect(model.action == .save)
        model.save()
        #expect(model.saved.sailNumber == 7)
        #expect(model.numberText == "7")
        #expect(model.action == .saved)
    }

    @Test func leavingDiscardsTheDraftAndTryItSelects() {
        let model = model()
        model.select(DesignID("skiff-plain"))
        model.numberText = "x"
        model.discardDraft()
        #expect(model.draft == stripe)
        #expect(model.numberText == "42")
        model.open(trying: DesignID("skiff-sheer"))
        #expect(model.design == DesignID("skiff-sheer"))
        model.open(trying: DesignID("ilca-dinghy-plain"))
        #expect(model.design == stripe.design, "another class's design isn't tried on")
    }

    /// Buy with the store stub: the design is owned and the button returns to Save, with no auto-save; it stays owned.
    @Test func buyingOwnsTheDesignAndReturnsToSave() async {
        let defaults = emptySuite()
        let model = model(store: StubStoreService(boatClass: "skiff", defaults: .init(defaults)))
        var saves = 0
        model.onSave = { _ in saves += 1 }
        model.select(DesignID("skiff-stars"))
        model.buy()
        #expect(model.isBuying)
        await model.purchaseFinished()
        #expect(!model.isBuying)
        #expect(model.owned.contains(DesignID("skiff-stars")))
        #expect(model.action == .save)
        #expect(saves == 0)
        let again = StubStoreService(boatClass: "skiff", defaults: .init(defaults))
        #expect(await again.ownedDesigns() == [DesignID("skiff-stars")])
    }

    @Test func aPendingCancelledOrOfflinePurchaseSaysSo() async {
        let products = StubStoreService.products(boatClass: "skiff")
        #expect(products.count == 12)
        for (checkout, online, note) in [(StoreScenario.Checkout.askToBuy(approved: false), true, "Waiting for approval"),
                                         (.cancels, true, nil), (.completes, false, "Offline")] as [(StoreScenario.Checkout, Bool, String?)] {
            let store = ScriptedStoreService(StoreScenario(products: products, isOnline: online, checkout: checkout))
            let model = model(store: store)
            model.select(DesignID("skiff-stars"))
            model.buy()
            await model.purchaseFinished()
            #expect(model.purchaseNote == note)
            #expect(!model.owned.contains(DesignID("skiff-stars")))
            #expect(model.action == .buy(price: "$2.99"))
        }
    }

    /// A refund or revocation on the ownership stream drops the design.
    @Test func ownershipUpdatesFollowTheStore() async {
        let store = ScriptedStoreService(StoreScenario(products: StubStoreService.products(boatClass: "skiff"),
                                                       owned: [DesignID("skiff-stars")], background: [[]]))
        let model = model(owned: [DesignID("skiff-stars")], store: store)
        // The scripted stream gives the owned set, then the refund, then ends.
        for _ in 0..<1000 where !model.owned.isEmpty { await Task.yield() }
        #expect(model.owned.isEmpty)
        model.select(DesignID("skiff-stars"))
        #expect(model.action == .buy(price: "$2.99"))
    }
}

/// My boat's state at launch (#136).
@MainActor @Suite struct MyBoatLaunchTests {
    private func options(_ arguments: String...) -> LaunchOptions {
        LaunchOptions(arguments: ["/path/to/Regatta"] + arguments)
    }

    /// `-completedRaces` is the UI tests': without `-uitesting` it neither counts nor reaches the app's defaults.
    @Test func completedRacesOnlyUnderUITesting() {
        let defaults = emptySuite()
        let app = AppModel(launchOptions: options("-completedRaces", "5"), defaults: defaults)
        #expect(app.myBoat.completedRaces == 0)
        #expect(defaults.object(forKey: CompletedRacesStore.key) == nil)
        let testing = AppModel(launchOptions: options("-uitesting", "-completedRaces", "5"), defaults: defaults)
        #expect(testing.myBoat.completedRaces == 5)
        #expect(defaults.object(forKey: CompletedRacesStore.key) == nil, "kept in the UI tests' own suite")
    }

    /// A design bought before launch is owned from the first frame, not once the ownership stream yields.
    @Test func ownedDesignsAreSeededAtLaunch() {
        let defaults = emptySuite()
        defaults.set(["skiff-stars"], forKey: StubStoreService.ownedKey)
        let app = AppModel(launchOptions: options(), defaults: defaults)
        #expect(app.myBoat.owned == [DesignID("skiff-stars")])
    }
}

/// The render cache is bounded (#136): typing a sail number renders a new image per keystroke.
@MainActor @Suite struct LiveryRendererCacheTests {
    @Test func theCacheDoesNotKeepEveryRender() {
        LiveryRenderer.removeAllCached()
        defer { LiveryRenderer.removeAllCached() }
        let size = LiveryRenderView.defaultSize
        let hull = RaceFiles.defaults.boatClass.content.hull
        let fits = LiveryRenderer.cacheCostLimit / LiveryRenderer.cost(of: size)
        let looks = (1...(fits * 2 + 2)).map { number -> LiveryArt.Look in
            var livery = stripe
            livery.sailNumber = number
            return LiveryArt.Look(livery)
        }
        for look in looks { _ = LiveryRenderer.image(look, hull: hull, size: size) }
        let kept = looks.filter { LiveryRenderer.cachedImage($0, hull: hull, size: size) != nil }.count
        #expect(kept < looks.count)
    }
}
