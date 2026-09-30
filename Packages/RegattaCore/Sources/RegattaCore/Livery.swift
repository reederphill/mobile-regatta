import Foundation

// Liveries (#21, #29, #118): a livery is a design from the catalogue, its colour slots filled from the safe palette,
// and a sail number. The editor only picks a design, fills its slots and sets a number: no uploads, no drawing, no
// text. Shared by the app and the race server, which checks a livery sent with a queue join against the catalogue.

/// A livery design, authored per boat class.
public struct DesignID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }

    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

/// A swatch of the safe palette, by its id (`docs/palette.md`).
public struct SwatchID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }

    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

/// Where a colour goes on the boat (#21).
public enum LiverySlot: String, Hashable, Sendable, Codable, CaseIterable {
    case deck
    case accent
    case sail
}

/// A livery as the device sends it with each queue join and the server stores per Game Center player (#21).
public struct Livery: Hashable, Sendable, Codable {
    public var design: DesignID
    /// The design's colour slots, filled in slot order (`LiveryDesign.slots`).
    public var colours: [SwatchID]
    public var sailNumber: Int

    /// The sail numbers a player may pick: numbers only, no letters or country codes (#21).
    public static let sailNumbers = 1...9999

    public init(design: DesignID, colours: [SwatchID], sailNumber: Int) {
        self.design = design
        self.colours = colours
        self.sailNumber = sailNumber
    }

    /// A sail number typed as text: digits only, in `sailNumbers`, else nil. No signs, spaces or letters.
    public static func sailNumber(parsing text: String) -> Int? {
        guard !text.isEmpty, text.count <= 4, text.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(text),
              sailNumbers.contains(n) else { return nil }
        return n
    }

    /// The colour in `slot`, or nil when the design has no such slot.
    public func colour(_ slot: LiverySlot, in design: LiveryDesign) -> SwatchID? {
        design.slots.firstIndex(of: slot).flatMap { colours.indices.contains($0) ? colours[$0] : nil }
    }
}

/// How a player comes to own a design (#21).
public enum DesignAcquisition: Hashable, Sendable {
    /// One of the free starter designs: every player owns it, and bots and new players wear one.
    case free
    /// Earned by completing this many online races (finished, by distance, DSQ or OCS; never RET, G6).
    case earned(completedRaces: Int)
    /// Bought on the App Store, per boat class.
    case paid(productID: String, tier: Int)

    public var isFree: Bool { self == .free }
}

/// A livery design: a pattern plus a sail graphic, with 2–3 colour slots filled from the safe palette.
public struct LiveryDesign: Hashable, Sendable {
    public let id: DesignID
    /// The boat class it's authored for (a boat class file's id).
    public let boatClass: String
    /// Names of the pattern and the sail graphic, as the renderer (#119) knows them.
    public let pattern: String
    public let sailGraphic: String
    /// Its colour slots, in the order a livery fills them.
    public let slots: [LiverySlot]
    public let acquisition: DesignAcquisition

    /// How many colour slots a design has.
    public static let slotCounts = 2...3

    public init(id: DesignID, boatClass: String, pattern: String, sailGraphic: String, slots: [LiverySlot], acquisition: DesignAcquisition) {
        self.id = id
        self.boatClass = boatClass
        self.pattern = pattern
        self.sailGraphic = sailGraphic
        self.slots = slots
        self.acquisition = acquisition
    }
}

/// A safe-palette swatch: its sRGB colour and the slots it may fill (off-white is sail only).
public struct LiverySwatch: Hashable, Sendable {
    public let id: SwatchID
    /// `0xRRGGBB`.
    public let rgb: UInt32
    /// The slots it may fill, in the file's order.
    public let slots: [LiverySlot]

    public init(id: SwatchID, rgb: UInt32, slots: [LiverySlot]) {
        self.id = id
        self.rgb = rgb
        self.slots = slots
    }

    public var oklab: OKLab { OKLab(rgb: rgb) }
}

/// What's wrong with a livery (#118).
public enum LiveryError: Error, Hashable, Sendable {
    /// Outside `Livery.sailNumbers`.
    case sailNumber(Int)
    case unknownDesign(DesignID)
    /// The design is authored for another boat class.
    case wrongBoatClass(DesignID, boatClass: String)
    /// Not the design's number of colour slots.
    case slotCount(expected: Int, found: Int)
    case unknownSwatch(SwatchID)
    /// A swatch that may not fill that slot (off-white on a deck, say).
    case swatchNotAllowed(SwatchID, LiverySlot)
}

// MARK: - Colour

/// A colour in OKLab (Björn Ottosson), the space `docs/palette.md` measures in: lightness `L` 0…1 and the `a`, `b`
/// axes, with OKLCH's chroma and hue derived from them.
public struct OKLab: Hashable, Sendable {
    public let L: Double
    public let a: Double
    public let b: Double

    public init(L: Double, a: Double, b: Double) {
        self.L = L
        self.a = a
        self.b = b
    }

    /// From an sRGB `0xRRGGBB`.
    public init(rgb: UInt32) {
        let linear = [(rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF].map { byte -> Double in
            let c = Double(byte) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let (r, g, bl) = (linear[0], linear[1], linear[2])
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * bl)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * bl)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * bl)
        L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    }

    /// OKLCH chroma: 0 is grey.
    public var chroma: Double { (a * a + b * b).squareRoot() }

    /// OKLCH hue, degrees in 0..<360.
    public var hue: Double {
        let degrees = atan2(b, a) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    /// Euclidean distance in OKLab (ΔE_OK).
    public func distance(to other: OKLab) -> Double {
        let (dL, da, db) = (L - other.L, a - other.a, b - other.b)
        return (dL * dL + da * da + db * db).squareRoot()
    }

    /// The angle between two hues, 0…180.
    public static func hueDistance(_ x: Double, _ y: Double) -> Double {
        let d = abs(x - y).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }
}

/// The checks every safe-palette swatch passes (`docs/palette.md`, "Validator config"; #29, #118): no reserved cue
/// hue, far enough from the give-way chevron's blue, and readable against the water, puffs and lulls.
public struct SwatchRule: Hashable, Sendable {
    /// A reserved cue colour: nothing on the water may resemble its hue.
    public struct Reserved: Hashable, Sendable {
        public let name: String
        public let rgb: UInt32

        public init(name: String, rgb: UInt32) {
            self.name = name
            self.rgb = rgb
        }
    }

    /// Vermillion, orange, yellow and chevron blue.
    public let reserved: [Reserved]
    /// OKLCH hue a swatch keeps from every reserved hue (tuning: 20°).
    public let minimumHueDistance: Double
    /// Below this OKLCH chroma a swatch has no hue the rule reads (tuning: 0.06).
    public let chromaFloor: Double
    /// The give-way chevron's colour, and the OKLab ΔE every swatch keeps from it (tuning: 0.15).
    public let chevron: UInt32
    public let minimumChevronDistance: Double
    /// Water, puff and lull, and the OKLCH lightness a swatch keeps from each (tuning: 0.20).
    public let water: [UInt32]
    public let minimumLightnessContrast: Double
    /// Swatches read by the hull outline instead of lightness (charcoal, #29).
    public let contrastExceptions: [SwatchID]

    public init(
        reserved: [Reserved], minimumHueDistance: Double, chromaFloor: Double, chevron: UInt32, minimumChevronDistance: Double,
        water: [UInt32], minimumLightnessContrast: Double, contrastExceptions: [SwatchID]
    ) {
        self.reserved = reserved
        self.minimumHueDistance = minimumHueDistance
        self.chromaFloor = chromaFloor
        self.chevron = chevron
        self.minimumChevronDistance = minimumChevronDistance
        self.water = water
        self.minimumLightnessContrast = minimumLightnessContrast
        self.contrastExceptions = contrastExceptions
    }

    /// Why `swatch` fails the rule, one line per check it breaks; empty when it passes.
    public func problems(_ swatch: LiverySwatch) -> [String] {
        let colour = swatch.oklab
        var problems: [String] = []
        if colour.chroma >= chromaFloor {
            for cue in reserved {
                let distance = OKLab.hueDistance(colour.hue, OKLab(rgb: cue.rgb).hue)
                if distance < minimumHueDistance {
                    problems.append("\(swatch.id) is \(String(format: "%.1f", distance))° of hue from \(cue.name)")
                }
            }
        }
        let fromChevron = colour.distance(to: OKLab(rgb: chevron))
        if fromChevron < minimumChevronDistance {
            problems.append("\(swatch.id) is ΔE \(String(format: "%.3f", fromChevron)) from the chevron's blue")
        }
        if !contrastExceptions.contains(swatch.id) {
            for tone in water {
                let contrast = abs(colour.L - OKLab(rgb: tone).L)
                if contrast < minimumLightnessContrast {
                    problems.append("\(swatch.id) is |ΔL| \(String(format: "%.3f", contrast)) from #\(String(format: "%06X", tone))")
                }
            }
        }
        return problems
    }
}
