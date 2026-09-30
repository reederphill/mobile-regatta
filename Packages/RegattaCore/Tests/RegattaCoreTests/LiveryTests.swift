import Foundation
import Testing
@testable import RegattaCore

/// The livery catalogue's fixtures (#118).
enum LiveryFixtures {
    /// SHA-256 of `Resources/liveries/livery-catalogue@1.json`, pinned like every released file (ADR 0004).
    static let catalogueHash = "6153c8caa56a6e20c12b6300c0fb477f018b495f240e99ddaef68d49ca657273"

    static func file() throws -> LiveryCatalogueFile { try LiveryCatalogueFile.bundled(id: "livery-catalogue", version: 1) }
    static func catalogue() throws -> LiveryCatalogue { try file().content }

    /// The bundled file's text with `of` replaced by `with`.
    static func edited(_ of: String, _ with: String) throws -> Data {
        let text = String(decoding: try #require(try LiveryCatalogueFile.bundledData(id: "livery-catalogue", version: 1)), as: UTF8.self)
        #expect(text.contains(of), "\(of)")
        return Data(text.replacingOccurrences(of: of, with: with).utf8)
    }
}

/// Liveries (#21, #29, #118): the model, the safe palette and its rule, the catalogue, new-player and bot liveries,
/// and duplicate sail numbers.
@Suite struct LiveryTests {
    /// The catalogue loads, pinned, with #21's launch shape for the skiff (4 free, 3 earned at 10/50/200, 12 paid
    /// across the three tiers) and a free starter for every boat class.
    @Test func catalogueLoadsWithTheLaunchDesigns() throws {
        let file = try LiveryFixtures.file()
        #expect(file.ref.hash.hex == LiveryFixtures.catalogueHash)
        let catalogue = file.content
        let skiff = catalogue.designs(for: "skiff")
        #expect(skiff.filter { $0.acquisition == .free }.count == 4)
        let earned = skiff.compactMap { if case .earned(let races) = $0.acquisition { races } else { nil } }
        #expect(earned == [10, 50, 200])
        let tiers = skiff.compactMap { if case .paid(_, let tier) = $0.acquisition { tier } else { nil } }
        #expect(tiers.count == 12 && Set(tiers) == [1, 2, 3])
        for boatClass in BoatClassFile.bundledKeys().map(\.id) {
            #expect(!catalogue.designs(for: boatClass).filter { $0.acquisition.isFree }.isEmpty, "\(boatClass) has a free design")
        }
        #expect(catalogue.swatches.count == 9)
        #expect(catalogue.swatch(SwatchID("off-white"))?.slots == [.sail])
    }

    /// Every swatch passes the rule: no reserved hue, clear of the chevron's blue, readable on the water (charcoal
    /// excepted), and the palette doc's sky blue measures ΔE 0.26 from the chevron.
    @Test func everySwatchPassesTheRule() throws {
        let catalogue = try LiveryFixtures.catalogue()
        for swatch in catalogue.swatches {
            #expect(catalogue.rule.problems(swatch).isEmpty, "\(swatch.id): \(catalogue.rule.problems(swatch))")
        }
        let sky = try #require(catalogue.swatch(SwatchID("sky-blue"))).oklab
        #expect(abs(sky.distance(to: OKLab(rgb: catalogue.rule.chevron)) - 0.26) < 0.01)
    }

    /// Banned hues are refused: a swatch at each reserved cue's hue fails the rule, the rejected palette-doc colours
    /// fail on contrast, and a catalogue carrying any of them won't load.
    @Test func bannedHuesAreRejected() throws {
        let rule = try LiveryFixtures.catalogue().rule
        for cue in rule.reserved {
            let problems = rule.problems(LiverySwatch(id: SwatchID(cue.name), rgb: cue.rgb, slots: [.deck]))
            #expect(problems.contains { $0.contains("of hue from \(cue.name)") }, "\(cue.name): \(problems)")
        }
        // Truer oranges sit within 20° of vermillion (docs/palette.md).
        #expect(!rule.problems(LiverySwatch(id: SwatchID("true-orange"), rgb: 0xF28C28, slots: [.deck])).isEmpty)
        // Rejected in #53 on contrast against puff and lull.
        for rgb: UInt32 in [0x009E73, 0xCC79A7] {
            #expect(rule.problems(LiverySwatch(id: SwatchID("rejected"), rgb: rgb, slots: [.deck])).contains { $0.contains("|ΔL|") })
        }
        // A blue too close to the chevron's.
        #expect(rule.problems(LiverySwatch(id: SwatchID("near-chevron"), rgb: 0x5566E8, slots: [.deck])).contains { $0.contains("chevron") })

        #expect(throws: DataFileError.self) {
            try LiveryCatalogueFile(data: try LiveryFixtures.edited(##""hex": "#56B4E9""##, ##""hex": "#D55E00""##))
        }
    }

    /// Sail numbers: 1…9999, digits only; 0, 10000 and anything not digits are refused.
    @Test func sailNumbersAreDigitsOneTo9999() throws {
        for good in ["1", "7", "207", "9999", "0042"] { #expect(Livery.sailNumber(parsing: good) != nil, "\(good)") }
        #expect(Livery.sailNumber(parsing: "0042") == 42)
        for bad in ["0", "10000", "", "-5", "+5", "12a", "GBR", "1 2", "٣", "4.5", "00000"] {
            #expect(Livery.sailNumber(parsing: bad) == nil, "\(bad)")
        }
        let catalogue = try LiveryFixtures.catalogue()
        let livery = Livery(design: DesignID("skiff-stripe"), colours: [SwatchID("sky-blue"), SwatchID("white"), SwatchID("off-white")], sailNumber: 12)
        try catalogue.validate(livery, boatClass: "skiff")
        for number in [0, 10000, -1] {
            var bad = livery
            bad.sailNumber = number
            #expect(throws: LiveryError.sailNumber(number)) { try catalogue.validate(bad, boatClass: "skiff") }
        }
    }

    /// A livery names a design for its boat class, fills its slots with swatches allowed there.
    @Test func liveryValidation() throws {
        let catalogue = try LiveryFixtures.catalogue()
        let livery = Livery(design: DesignID("skiff-plain"), colours: [SwatchID("charcoal"), SwatchID("off-white")], sailNumber: 4127)
        try catalogue.validate(livery, boatClass: "skiff")
        #expect(throws: LiveryError.wrongBoatClass(livery.design, boatClass: "ilca-dinghy")) { try catalogue.validate(livery, boatClass: "ilca-dinghy") }
        var edit = livery
        edit.design = DesignID("no-such-design")
        #expect(throws: LiveryError.unknownDesign(edit.design)) { try catalogue.validate(edit, boatClass: "skiff") }
        edit = livery
        edit.colours.append(SwatchID("white"))
        #expect(throws: LiveryError.slotCount(expected: 2, found: 3)) { try catalogue.validate(edit, boatClass: "skiff") }
        edit = livery
        edit.colours[0] = SwatchID("off-white")
        #expect(throws: LiveryError.swatchNotAllowed(SwatchID("off-white"), .deck)) { try catalogue.validate(edit, boatClass: "skiff") }
        edit = livery
        edit.colours[1] = SwatchID("mid-blue")
        #expect(throws: LiveryError.unknownSwatch(SwatchID("mid-blue"))) { try catalogue.validate(edit, boatClass: "skiff") }
        #expect(livery.colour(.sail, in: try #require(catalogue.design(livery.design))) == SwatchID("off-white"))
        #expect(livery.colour(.accent, in: try #require(catalogue.design(livery.design))) == nil)
    }

    /// A bot's livery is a free starter, valid, the same for the same seed, and varied across seeds: never earned or
    /// paid.
    @Test func botLiveryIsNeverEarnedOrPaid() throws {
        let catalogue = try LiveryFixtures.catalogue()
        var designs: Set<DesignID> = []
        for seed in UInt64(0)..<500 {
            let livery = try #require(catalogue.botLivery(boatClass: "skiff", seed: seed))
            #expect(catalogue.design(livery.design)?.acquisition == .free, "seed \(seed): \(livery.design)")
            try catalogue.validate(livery, boatClass: "skiff")
            #expect(catalogue.botLivery(boatClass: "skiff", seed: seed) == livery)
            designs.insert(livery.design)
        }
        #expect(designs.count == 4, "every free starter turns up")
        #expect(catalogue.botLivery(boatClass: "no-such-class", seed: 1) == nil)
    }

    /// A new player's livery is a free starter in palette colours with a sail number, from the caller's random seed,
    /// always valid.
    @Test func newPlayerLiveryIsARandomFreeStarter() throws {
        let catalogue = try LiveryFixtures.catalogue()
        var numbers: Set<Int> = []
        for seed in UInt64(1)...200 {
            let livery = try #require(catalogue.newPlayerLivery(boatClass: "skiff", seed: seed &* 0x9E37_79B9_7F4A_7C15))
            #expect(catalogue.design(livery.design)?.acquisition == .free)
            try catalogue.validate(livery, boatClass: "skiff")
            numbers.insert(livery.sailNumber)
        }
        #expect(numbers.count > 190, "sail numbers vary with the seed")
        #expect(catalogue.newPlayerLivery(boatClass: "skiff", seed: 7) != catalogue.botLivery(boatClass: "skiff", seed: 7),
                "a new player's stream isn't a bot's")
    }

    /// Duplicate sail numbers: the later joiner shows another, unique in the fleet, the same for the same roster.
    @Test func duplicateSailNumbersResolveUniquely() {
        #expect(LiveryCatalogue.raceSailNumbers([7, 12, 99]) == [7, 12, 99])
        #expect(LiveryCatalogue.raceSailNumbers([7, 7]) == [7, 8])
        // The replacement skips every number any boat has, including later joiners'.
        #expect(LiveryCatalogue.raceSailNumbers([7, 7, 8, 9]) == [7, 10, 8, 9])
        // Wrapping past 9999 to 1, which a later boat has, so 2.
        let wrapped = LiveryCatalogue.raceSailNumbers([9999, 9999, 1])
        #expect(wrapped == [9999, 2, 1])
        let roster = [42, 42, 42, 43, 42, 1, 9999, 9999]
        let shown = LiveryCatalogue.raceSailNumbers(roster)
        #expect(Set(shown).count == roster.count, "every boat shows its own number: \(shown)")
        #expect(shown.allSatisfy(Livery.sailNumbers.contains))
        #expect(LiveryCatalogue.raceSailNumbers(roster) == shown)
        // A boat keeps its own number unless an earlier joiner has it.
        for (i, own) in roster.enumerated() where !roster[..<i].contains(own) {
            #expect(shown[i] == own, "boat \(i)")
        }
    }

    /// The catalogue refuses a file that breaks its rules.
    @Test func catalogueRefusesBrokenFiles() throws {
        for (of, with) in [
            (#""tier": 1"#, #""tier": 4"#),
            (#""completedRaces": 10"#, #""completedRaces": 0"#),
            (#""acquisition": "earned""#, #""acquisition": "won""#),
        ] {
            #expect(throws: DataFileError.self, "\(with)") { try LiveryCatalogueFile(data: try LiveryFixtures.edited(of, with)) }
        }
    }
}
