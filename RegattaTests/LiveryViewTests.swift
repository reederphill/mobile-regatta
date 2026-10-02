import Foundation
import RegattaBots
import RegattaCore
import RegattaServices
import Testing
import UIKit
@testable import Regatta

/// The off-water livery pieces (#119): fleet liveries, the art's fallbacks, the chip and the large render.
@MainActor @Suite struct LiveryViewTests {
    static let catalogue = LiveryCatalogue.bundled

    /// A practice fleet of 16: you in seat 0 and 15 bots.
    static func setup(seed: UInt64 = 42) -> RaceSetup {
        RaceConfig(opponents: 15, laps: 1, prestartSeconds: 60, seed: seed, windSeed: 1).setup
    }

    // MARK: Fleet liveries

    @Test func yoursIsAValidSkiffLivery() throws {
        try Self.catalogue.validate(FleetLiveries.yours, boatClass: "skiff")
    }

    @Test func aFleetWearsYoursInYourSeatAndFreeStartersElsewhere() throws {
        let setup = Self.setup()
        let me = try #require(setup.seats.firstIndex(of: .human))
        let fleet = FleetLiveries(setup: setup, mySeat: me)
        #expect(fleet.liveries.count == setup.seats.count)
        #expect(fleet[me] == FleetLiveries.yours)
        for (seat, livery) in fleet.liveries.enumerated() {
            try Self.catalogue.validate(livery, boatClass: setup.boatClass.id)
            let design = try #require(Self.catalogue.design(livery.design))
            #expect(design.acquisition.isFree, "seat \(seat) wears \(design.id)")
        }
        let bot = try #require(setup.seats.indices.first { $0 != me })
        let seeded = try #require(Self.catalogue.botLivery(boatClass: setup.boatClass.id,
                                                           seed: botSeed(raceSeed: setup.raceSeed, seat: bot)))
        #expect(fleet[bot].design == seeded.design && fleet[bot].colours == seeded.colours)
    }

    @Test func aFleetsSailNumbersAreUnique() {
        for seed in UInt64(0)..<40 {
            let setup = Self.setup(seed: seed)
            let numbers = FleetLiveries(setup: setup, mySeat: 0).liveries.map(\.sailNumber)
            #expect(Set(numbers).count == numbers.count, "seed \(seed): \(numbers)")
        }
    }

    @Test func theSameSetupGivesTheSameFleet() {
        let setup = Self.setup(seed: 7)
        #expect(FleetLiveries(setup: setup, mySeat: 1) == FleetLiveries(setup: setup, mySeat: 1))
        #expect(FleetLiveries(setup: setup, mySeat: 1) != FleetLiveries(setup: Self.setup(seed: 8), mySeat: 1))
    }

    @Test func aSeatOutOfRangeWearsYours() {
        #expect(FleetLiveries(liveries: [])[3] == FleetLiveries.yours)
    }

    // MARK: Art

    @Test func theFreeSkiffStartersAreDrawnAndOtherNamesFallBackToPlain() {
        let starters = Self.catalogue.designs(for: "skiff").filter(\.acquisition.isFree)
        #expect(starters.count == 4)
        for design in starters {
            #expect(LiveryArt.drawnPatterns.contains(design.pattern), "\(design.id)")
            #expect(LiveryArt.drawnSailGraphics.contains(design.sailGraphic), "\(design.id)")
        }
        #expect(LiveryArt.Pattern(named: "chevron-bow") == .plain)
        #expect(LiveryArt.SailGraphic(named: "compass-rose") == .plain)
        #expect(LiveryArt.Pattern(named: "split-deck") == .splitDeck)
    }

    @Test func aLookTakesItsColoursFromTheDesignsSlots() throws {
        let stripe = Livery(design: DesignID("skiff-stripe"),
                            colours: [SwatchID("charcoal"), SwatchID("pale-bluish-green"), SwatchID("white")], sailNumber: 31)
        let look = LiveryArt.Look(stripe)
        #expect(look.pattern == .stripe && look.sailGraphic == .plain)
        #expect(look.deck == 0x33383D && look.accent == 0x5FD3A8 && look.sail == 0xF5F5F2)
        #expect(look.numberInk == LiveryArt.numberInks.dark, "white sail, charcoal digits")
        let plain = LiveryArt.Look(FleetLiveries.yours)
        #expect(plain.accent == nil && plain.deck == 0x56B4E9 && plain.sail == 0xF5F5F2)
        let unknown = LiveryArt.Look(Livery(design: DesignID("no-such"), colours: [SwatchID("lavender"), SwatchID("nope")],
                                            sailNumber: 5))
        #expect(unknown.pattern == .plain && unknown.deck == 0xC3B5F0 && unknown.sail == LiveryArt.fallbackRGB)
    }

    @Test func aDarkNumbersPanelTakesWhiteDigits() {
        let look = LiveryArt.Look(pattern: .plain, sailGraphic: .numbersPanel, deck: 0xF5F5F2, accent: 0x33383D,
                                  sail: 0xF5F5F2, sailNumber: 1)
        #expect(look.numberGround == 0x33383D)
        #expect(look.numberInk == LiveryArt.numberInks.light)
    }

    // MARK: Chip

    @Test func aChipIsTheDeckAndSailColours() {
        #expect(LiveryChip(FleetLiveries.yours) == LiveryChip(deck: SwatchID("sky-blue"), sail: SwatchID("white")))
        let split = Livery(design: DesignID("skiff-split"),
                           colours: [SwatchID("pale-reddish-purple"), SwatchID("charcoal"), SwatchID("off-white")],
                           sailNumber: 88)
        #expect(LiveryChip(split) == LiveryChip(deck: SwatchID("pale-reddish-purple"), sail: SwatchID("off-white")))
    }

    // MARK: Large render

    @Test func theLargeRenderDrawsTheBoatOnTheWater() throws {
        let size = LiveryRenderView.defaultSize
        let image = LiveryRenderer.draw(LiveryArt.Look(FleetLiveries.yours), hull: RaceFiles.defaults.boatClass.content.hull,
                                        size: size)
        #expect(image.size == size)
        #expect(image.scale == LiveryRenderer.scale)
        let pixels = try #require(Self.pixels(image))
        // The corner is water; the deck's sky blue is drawn somewhere.
        #expect(Self.near(pixels[0], ChartPalette.water.rgb))
        #expect(pixels.contains { Self.near($0, 0x56B4E9) })
    }

    @Test func theLargeRenderIsTheSameEveryTime() throws {
        let hull = RaceFiles.defaults.boatClass.content.hull
        for livery in LiveryGalleryView.liveries {
            try Self.catalogue.validate(livery, boatClass: "skiff")
            let a = try #require(Self.pixels(LiveryRenderer.draw(LiveryArt.Look(livery), hull: hull, size: LiveryRenderView.defaultSize)))
            let b = try #require(Self.pixels(LiveryRenderer.draw(LiveryArt.Look(livery), hull: hull, size: LiveryRenderView.defaultSize)))
            #expect(a == b, "\(livery.design)")
        }
    }

    @Test func theGalleryShowsEachFreeSkiffStarter() {
        let starters = Self.catalogue.designs(for: "skiff").filter(\.acquisition.isFree).map(\.id)
        #expect(LiveryGalleryView.liveries.map(\.design) == starters)
    }

    @Test func theLiveryFixtureIsAGallery() throws {
        #expect(try RenderFixture.gallery(named: "livery-large", in: RenderFixtureTests.fixtures) == .livery)
        #expect(try RenderFixture.gallery(named: "prestart", in: RenderFixtureTests.fixtures) == nil)
    }

    /// Within 2 of `b` in every channel.
    static func near(_ a: UInt32, _ b: UInt32) -> Bool {
        [16, 8, 0].allSatisfy { abs(Int((a >> $0) & 0xFF) - Int((b >> $0) & 0xFF)) <= 2 }
    }

    /// `image`'s pixels as `0xRRGGBB`, row by row from the top left.
    static func pixels(_ image: UIImage) -> [UInt32]? {
        guard let cg = image.cgImage else { return nil }
        let (width, height) = (cg.width, cg.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 0, to: bytes.count, by: 4).map {
            UInt32(bytes[$0]) << 16 | UInt32(bytes[$0 + 1]) << 8 | UInt32(bytes[$0 + 2])
        }
    }
}
