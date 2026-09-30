import Foundation

/// The livery catalogue (#118): every design per boat class, the safe palette and the rule each swatch passes. An
/// immutable, versioned data file (ADR 0004); new designs arrive only with app updates (#21). The final swatch values
/// (#53, `docs/palette.md`) ship in the first version; #169 revises them as a new version.
///
/// The file is JSON, schema version 1:
///
/// ```json
/// {
///   "schemaVersion": 1, "id": "livery-catalogue", "version": 1,
///   "rule": {
///     "reserved": [{ "name": "vermillion", "hex": "#D55E00" }],
///     "minimumHueDistanceDegrees": 20, "chromaFloor": 0.06,
///     "chevronHex": "#3F51E0", "minimumChevronDistance": 0.15,
///     "waterHex": ["#174D70", "#002D4D", "#3C6F94"], "minimumLightnessContrast": 0.2,
///     "contrastExceptions": ["charcoal"]
///   },
///   "swatches": [{ "id": "white", "hex": "#F5F5F2", "slots": ["deck", "accent", "sail"] }],
///   "designs": [{
///     "id": "skiff-stripe", "boatClass": "skiff", "pattern": "stripe", "sailGraphic": "plain",
///     "slots": ["deck", "accent", "sail"],
///     "acquisition": "free" | "earned" | "paid", "completedRaces": 10, "productId": "…", "tier": 1
///   }]
/// }
/// ```
///
/// `completedRaces` goes with `earned`, and `productId` and `tier` (1–3: $0.99, $1.99, $2.99) with `paid`. Every swatch
/// must pass the rule, or the file is refused.
public struct LiveryCatalogue: DataFileContent, Hashable {
    public static let kind = "livery catalogue"
    public static let bundleDirectory = "liveries"
    public static let supportedSchemaVersions = [1]

    public let rule: SwatchRule
    public let swatches: [LiverySwatch]
    public let designs: [LiveryDesign]

    /// Stream tags for bots' and new players' liveries: ASCII "livrybot" and "livrynew".
    static let botStream: UInt64 = 0x6C69_7672_7962_6F74
    static let newPlayerStream: UInt64 = 0x6C69_7672_796E_6577

    public init(rule: SwatchRule, swatches: [LiverySwatch], designs: [LiveryDesign]) throws {
        self.rule = rule
        self.swatches = swatches
        self.designs = designs
        try validate()
    }

    public init(fileData: Data, header: DataFileHeader) throws {
        let file = try JSONDecoder().decode(Schema.self, from: fileData)
        func fail(_ reason: String) -> DataFileError { .invalidContent(kind: Self.kind, id: header.id, reason: reason) }
        func colour(_ hex: String) throws -> UInt32 {
            let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
            guard digits.count == 6, let value = UInt32(digits, radix: 16) else { throw fail("\(hex) isn't a #RRGGBB colour") }
            return value
        }
        let rule = SwatchRule(
            reserved: try file.rule.reserved.map { SwatchRule.Reserved(name: $0.name, rgb: try colour($0.hex)) },
            minimumHueDistance: file.rule.minimumHueDistanceDegrees, chromaFloor: file.rule.chromaFloor,
            chevron: try colour(file.rule.chevronHex), minimumChevronDistance: file.rule.minimumChevronDistance,
            water: try file.rule.waterHex.map(colour), minimumLightnessContrast: file.rule.minimumLightnessContrast,
            contrastExceptions: file.rule.contrastExceptions.map(SwatchID.init))
        let swatches = try file.swatches.map { LiverySwatch(id: SwatchID($0.id), rgb: try colour($0.hex), slots: $0.slots) }
        let designs = try file.designs.map { design -> LiveryDesign in
            let acquisition: DesignAcquisition
            switch design.acquisition {
            case "free":
                acquisition = .free
            case "earned":
                guard let races = design.completedRaces else { throw fail("earned design \(design.id) has no completedRaces") }
                acquisition = .earned(completedRaces: races)
            case "paid":
                guard let product = design.productId, let tier = design.tier else { throw fail("paid design \(design.id) needs productId and tier") }
                acquisition = .paid(productID: product, tier: tier)
            default:
                throw fail("design \(design.id)'s acquisition \(design.acquisition) isn't free, earned or paid")
            }
            return LiveryDesign(id: DesignID(design.id), boatClass: design.boatClass, pattern: design.pattern,
                                sailGraphic: design.sailGraphic, slots: design.slots, acquisition: acquisition)
        }
        do {
            try self.init(rule: rule, swatches: swatches, designs: designs)
        } catch let error as LiveryCatalogueError {
            throw fail(error.reason)
        }
    }

    /// The catalogue's own rules: unique ids, every swatch passing the swatch rule, designs of 2–3 distinct slots each
    /// fillable from the palette, earned thresholds positive, tiers 1–3 with a product each, and a free design for every
    /// boat class.
    private func validate() throws {
        func require(_ condition: Bool, _ reason: @autoclosure () -> String) throws {
            if !condition { throw LiveryCatalogueError(reason: reason()) }
        }
        try require(!swatches.isEmpty && !designs.isEmpty, "a catalogue needs swatches and designs")
        try require(Set(swatches.map(\.id)).count == swatches.count, "a swatch id repeats")
        try require(Set(designs.map(\.id)).count == designs.count, "a design id repeats")
        for swatch in swatches {
            try require(!swatch.slots.isEmpty, "\(swatch.id) fills no slot")
            try require(Set(swatch.slots).count == swatch.slots.count, "\(swatch.id) repeats a slot")
            let problems = rule.problems(swatch)
            try require(problems.isEmpty, problems.joined(separator: "; "))
        }
        var products: Set<String> = []
        for design in designs {
            try require(LiveryDesign.slotCounts.contains(design.slots.count), "\(design.id) has \(design.slots.count) slots, not 2–3")
            try require(Set(design.slots).count == design.slots.count, "\(design.id) repeats a slot")
            for slot in design.slots {
                try require(swatches.contains { $0.slots.contains(slot) }, "no swatch fills \(design.id)'s \(slot.rawValue)")
            }
            switch design.acquisition {
            case .free: break
            case .earned(let races): try require(races > 0, "\(design.id) is earned after \(races) races")
            case .paid(let product, let tier):
                try require((1...3).contains(tier), "\(design.id)'s tier \(tier) isn't 1–3")
                try require(products.insert(product).inserted, "product \(product) sells two designs")
            }
        }
        // In catalogue order, so a broken file always names the same class.
        var classes: [String] = []
        for design in designs where !classes.contains(design.boatClass) { classes.append(design.boatClass) }
        for boatClass in classes {
            try require(designs.contains { $0.boatClass == boatClass && $0.acquisition.isFree }, "\(boatClass) has no free design")
        }
    }

    public func design(_ id: DesignID) -> LiveryDesign? { designs.first { $0.id == id } }
    public func swatch(_ id: SwatchID) -> LiverySwatch? { swatches.first { $0.id == id } }
    /// The designs for `boatClass`, in catalogue order.
    public func designs(for boatClass: String) -> [LiveryDesign] { designs.filter { $0.boatClass == boatClass } }

    /// Throws what's wrong with `livery` for a boat of `boatClass`. It says nothing of ownership: the server checks a
    /// paid design against the player's App Store transactions (#21).
    public func validate(_ livery: Livery, boatClass: String) throws(LiveryError) {
        guard Livery.sailNumbers.contains(livery.sailNumber) else { throw .sailNumber(livery.sailNumber) }
        guard let design = design(livery.design) else { throw .unknownDesign(livery.design) }
        guard design.boatClass == boatClass else { throw .wrongBoatClass(livery.design, boatClass: boatClass) }
        guard livery.colours.count == design.slots.count else {
            throw .slotCount(expected: design.slots.count, found: livery.colours.count)
        }
        for (slot, id) in zip(design.slots, livery.colours) {
            guard let swatch = swatch(id) else { throw .unknownSwatch(id) }
            guard swatch.slots.contains(slot) else { throw .swatchNotAllowed(id, slot) }
        }
    }

    /// A new player's livery (#21): a free starter design for `boatClass`, palette colours for its slots and a sail
    /// number, drawn from `seed`, which the caller draws at random (RegattaCore reads no randomness of its own). Nil if
    /// the class has no design.
    public func newPlayerLivery(boatClass: String, seed: UInt64) -> Livery? {
        var rng = SplitMix64(seed: seed, stream: Self.newPlayerStream)
        return randomFreeLivery(boatClass: boatClass) { rng.next() }
    }

    /// A bot's livery (#19, #21): a free starter design, palette colours and a sail number, all from `seed`, so the
    /// same seed gives the same livery everywhere. Never an earned or paid design. Nil if the class has no design.
    public func botLivery(boatClass: String, seed: UInt64) -> Livery? {
        var rng = SplitMix64(seed: seed, stream: Self.botStream)
        return randomFreeLivery(boatClass: boatClass) { rng.next() }
    }

    /// Picks with `next() % count`: its own arithmetic, not the standard library's, so a seed gives the same pick on
    /// every platform. The bias is below 10⁻¹⁵ for these counts.
    private func randomFreeLivery(boatClass: String, next: () -> UInt64) -> Livery? {
        func pick<T>(_ items: [T]) -> T? { items.isEmpty ? nil : items[Int(next() % UInt64(items.count))] }
        guard let design = pick(designs(for: boatClass).filter { $0.acquisition.isFree }) else { return nil }
        var colours: [SwatchID] = []
        for slot in design.slots {
            guard let swatch = pick(swatches.filter { $0.slots.contains(slot) }) else { return nil }
            colours.append(swatch.id)
        }
        let sailNumber = Livery.sailNumbers.lowerBound + Int(next() % UInt64(Livery.sailNumbers.count))
        return Livery(design: design.id, colours: colours, sailNumber: sailNumber)
    }

    /// The sail numbers a fleet shows (#21), given each boat's own in the order they joined: where two share a number,
    /// the one that joined later shows another for that race only, the first number after it (wrapping 9999 to 1)
    /// that no boat in the fleet has or shows. The same roster gives the same numbers everywhere; online the server
    /// puts them in the roster.
    public static func raceSailNumbers(_ numbers: [Int]) -> [Int] {
        var taken = Set(numbers)
        var shown: Set<Int> = []
        return numbers.map { number in
            guard shown.contains(number) else {
                shown.insert(number)
                return number
            }
            var candidate = number
            repeat {
                candidate = candidate == Livery.sailNumbers.upperBound ? Livery.sailNumbers.lowerBound : candidate + 1
            } while taken.contains(candidate) || shown.contains(candidate)
            taken.insert(candidate)
            shown.insert(candidate)
            return candidate
        }
    }
}

public typealias LiveryCatalogueFile = DataFile<LiveryCatalogue>

/// A catalogue that breaks its own rules.
struct LiveryCatalogueError: Error, Hashable, Sendable {
    let reason: String
}

// MARK: - Schema 1

private struct Schema: Decodable {
    struct Rule: Decodable {
        struct Reserved: Decodable {
            let name: String
            let hex: String
        }

        let reserved: [Reserved]
        let minimumHueDistanceDegrees: Double
        let chromaFloor: Double
        let chevronHex: String
        let minimumChevronDistance: Double
        let waterHex: [String]
        let minimumLightnessContrast: Double
        let contrastExceptions: [String]
    }

    struct Swatch: Decodable {
        let id: String
        let hex: String
        let slots: [LiverySlot]
    }

    struct Design: Decodable {
        let id: String
        let boatClass: String
        let pattern: String
        let sailGraphic: String
        let slots: [LiverySlot]
        let acquisition: String
        let completedRaces: Int?
        let productId: String?
        let tier: Int?
    }

    let rule: Rule
    let swatches: [Swatch]
    let designs: [Design]
}
