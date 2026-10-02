import RegattaCore
import UIKit

// Livery art (#119, #21): how a livery design is drawn. Every part is a path in boat space (points, x to starboard,
// y to the bow, the hull's origin at the centre, as `BoatNode`'s sprites are anchored), so the large render and the
// on-water boat (#372) can draw the same shapes: the render fills each path with its slot's colour; the water can
// fill them white as masks and tint the sprites.
//
// Placeholder art until the designs are drawn (#22, #169): only the free starter designs' patterns and sail graphics
// are drawn, and any other name falls back to plain.

extension LiveryCatalogue {
    /// The bundled livery catalogue (#118), which RegattaCore always ships: loaded once.
    nonisolated static let bundled: LiveryCatalogue = {
        do {
            return try LiveryCatalogueFile.bundled(id: "livery-catalogue", version: 1).content
        } catch {
            preconditionFailure("the bundled livery catalogue failed to load: \(error)")
        }
    }()
}

enum LiveryArt {
    /// What a slot with no colour (an unknown swatch or design) draws: the catalogue's pale grey.
    static let fallbackRGB: UInt32 = 0xC8CCD0

    /// A design's deck pattern, in the accent colour. Names are the catalogue's (`LiveryDesign.pattern`).
    enum Pattern: String, CaseIterable {
        case plain
        /// A stripe down the centreline, bow to transom, under the cockpit.
        case stripe
        /// A band round the deck's edge, inside the hull outline.
        case sheerLine = "sheer-line"
        /// The foredeck, forward of the mast.
        case splitDeck = "split-deck"

        /// The drawn pattern by catalogue name; a name with no art yet (#169) draws plain.
        init(named name: String) { self = Pattern(rawValue: name) ?? .plain }
    }

    /// A design's sail graphic. Names are the catalogue's (`LiveryDesign.sailGraphic`).
    enum SailGraphic: String, CaseIterable {
        case plain
        /// A panel in the accent colour behind the sail number.
        case numbersPanel = "numbers-panel"

        /// The drawn graphic by catalogue name; a name with no art yet (#169) draws plain.
        init(named name: String) { self = SailGraphic(rawValue: name) ?? .plain }
    }

    /// The pattern and graphic names that have art; every other catalogue name falls back to plain.
    static var drawnPatterns: Set<String> { Set(Pattern.allCases.map(\.rawValue)) }
    static var drawnSailGraphics: Set<String> { Set(SailGraphic.allCases.map(\.rawValue)) }

    /// A swatch's colour; an id the catalogue doesn't know draws `fallbackRGB`, so a stale livery still draws.
    static func rgb(_ id: SwatchID, in catalogue: LiveryCatalogue = .bundled) -> UInt32 {
        catalogue.swatch(id)?.rgb ?? fallbackRGB
    }

    /// A livery resolved for drawing: its design's pattern and graphic, and its colours by slot. A two-slot design
    /// has no accent.
    struct Look: Hashable {
        var pattern: Pattern
        var sailGraphic: SailGraphic
        var deck: UInt32
        var accent: UInt32?
        var sail: UInt32
        var sailNumber: Int

        init(pattern: Pattern, sailGraphic: SailGraphic, deck: UInt32, accent: UInt32?, sail: UInt32, sailNumber: Int) {
            self.pattern = pattern
            self.sailGraphic = sailGraphic
            self.deck = deck
            self.accent = accent
            self.sail = sail
            self.sailNumber = sailNumber
        }

        /// `livery` from `catalogue`. An unknown design draws plain, its first two colours as deck and sail.
        init(_ livery: Livery, catalogue: LiveryCatalogue = .bundled) {
            let design = catalogue.design(livery.design)
            func colour(_ slot: LiverySlot) -> UInt32? {
                let id: SwatchID?
                if let design {
                    id = livery.colour(slot, in: design)
                } else {
                    let index = slot == .deck ? 0 : slot == .sail ? 1 : nil
                    id = index.flatMap { livery.colours.indices.contains($0) ? livery.colours[$0] : nil }
                }
                return id.map { LiveryArt.rgb($0, in: catalogue) }
            }
            self.init(pattern: Pattern(named: design?.pattern ?? Pattern.plain.rawValue),
                      sailGraphic: SailGraphic(named: design?.sailGraphic ?? SailGraphic.plain.rawValue),
                      deck: colour(.deck) ?? LiveryArt.fallbackRGB, accent: colour(.accent),
                      sail: colour(.sail) ?? LiveryArt.fallbackRGB, sailNumber: livery.sailNumber)
        }

        /// What the sail number sits on: the accent panel, or the sail.
        var numberGround: UInt32 { sailGraphic == .numbersPanel ? (accent ?? sail) : sail }

        /// The sail number's ink: charcoal or white, whichever has more OKLCH lightness contrast with its ground.
        var numberInk: UInt32 {
            let L = OKLab(rgb: numberGround).L
            let charcoal = LiveryArt.numberInks.dark, white = LiveryArt.numberInks.light
            return abs(L - OKLab(rgb: charcoal).L) >= abs(L - OKLab(rgb: white).L) ? charcoal : white
        }
    }

    /// The sail number's two inks: the safe palette's charcoal and white (`livery-catalogue@1`).
    static let numberInks = (dark: UInt32(0x33383D), light: UInt32(0xF5F5F2))

    /// A design's shapes for one hull at one scale, in boat space (points; x to starboard, y to the bow).
    struct Geometry {
        let length: CGFloat
        let beam: CGFloat
        let hull: CGPath
        let cockpit: CGPath
        /// The mast, where the sail hinges: as on the water (`BoatNode`), 0.16 of her length forward of centre.
        let mast: CGPoint
        /// The sail in sail space (the mast at the origin, the boom along -y), bellied towards +x: deeper than on
        /// the water, so the number has room.
        let sail: CGPath
        let sailLength: CGFloat
        let sailBelly: CGFloat

        init(hull: BoatClass.Hull, pointsPerMeter ppm: CGFloat) {
            length = CGFloat(hull.length) * ppm
            beam = CGFloat(hull.beam) * ppm
            self.hull = BoatArt.hullPath(hull, ppm: ppm)
            // Where the water's hull mask draws its cockpit.
            cockpit = CGPath(roundedRect: CGRect(x: -beam * 0.26, y: -length * 0.42, width: beam * 0.52, height: length * 0.36),
                             cornerWidth: beam * 0.2, cornerHeight: beam * 0.2, transform: nil)
            mast = CGPoint(x: 0, y: length * 0.16)
            sailLength = length * 0.62
            sailBelly = beam * 0.55
            let sail = CGMutablePath()
            sail.move(to: .zero)
            sail.addQuadCurve(to: CGPoint(x: 0, y: -sailLength), control: CGPoint(x: sailBelly * 2, y: -sailLength * 0.45))
            sail.closeSubpath()
            self.sail = sail
        }
    }

    /// The pattern's accent region in boat space, for clipping to the hull; nil for plain.
    static func patternPath(_ pattern: Pattern, _ g: Geometry) -> CGPath? {
        switch pattern {
        case .plain:
            nil
        case .stripe:
            CGPath(rect: CGRect(x: -g.beam * 0.1, y: -g.length, width: g.beam * 0.2, height: g.length * 2), transform: nil)
        case .sheerLine:
            g.hull.copy(strokingWithWidth: g.beam * 0.24, lineCap: .round, lineJoin: .round, miterLimit: 1)
        case .splitDeck:
            CGPath(rect: CGRect(x: -g.beam, y: g.mast.y, width: g.beam * 2, height: g.length), transform: nil)
        }
    }

    /// The sail graphic's region in sail space, for clipping to the sail; nil for plain.
    static func sailGraphicPath(_ graphic: SailGraphic, _ g: Geometry) -> CGPath? {
        switch graphic {
        case .plain:
            nil
        case .numbersPanel:
            CGPath(rect: numberFrame(g).insetBy(dx: -g.sailBelly * 0.08, dy: -g.sailLength * 0.05), transform: nil)
        }
    }

    /// Where the sail number sits, in sail space: the belly's deepest part, its long side along the boom.
    static func numberFrame(_ g: Geometry) -> CGRect {
        CGRect(x: g.sailBelly * 0.14, y: -g.sailLength * 0.72, width: g.sailBelly * 0.58, height: g.sailLength * 0.5)
    }

    /// Draws `look` on `g` into `cg`, whose user space is boat space: deck, pattern, cockpit and outline, then the
    /// sail swung `sailAngle` radians to starboard with its graphic and number. `outlineWidth` is the hull outline's,
    /// points. The number is drawn to read with the bow to the right of the screen (`LiveryRenderView`).
    static func draw(_ look: Look, _ g: Geometry, sailAngle: CGFloat, outlineWidth: CGFloat, in cg: CGContext) {
        let deck = UIColor(rgb: look.deck)
        cg.saveGState()
        cg.addPath(g.hull)
        cg.clip()
        cg.setFillColor(deck.cgColor)
        cg.addPath(g.hull)
        cg.fillPath()
        if let accent = look.accent, let pattern = patternPath(look.pattern, g) {
            cg.setFillColor(UIColor(rgb: accent).cgColor)
            cg.addPath(pattern)
            cg.fillPath()
        }
        // The cockpit: the deck colour darkened as the water's 0.7 grey mask darkens it.
        var (r, gr, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        deck.getRed(&r, green: &gr, blue: &b, alpha: &a)
        cg.setFillColor(UIColor(red: r * 0.7, green: gr * 0.7, blue: b * 0.7, alpha: 1).cgColor)
        cg.addPath(g.cockpit)
        cg.fillPath()
        // Every hull's thin outline, inside the silhouette, as on the water (#21).
        cg.addPath(g.hull)
        cg.setStrokeColor(CuePalette.hullOutline.uiColor.cgColor)
        cg.setLineWidth(outlineWidth * 2)
        cg.strokePath()
        cg.restoreGState()

        // The sail, hinged at the mast and swung to starboard: rotating sail space by +angle turns its -y boom
        // towards +x.
        cg.saveGState()
        cg.translateBy(x: g.mast.x, y: g.mast.y)
        cg.rotate(by: sailAngle)
        cg.saveGState()
        cg.addPath(g.sail)
        cg.clip()
        cg.setFillColor(UIColor(rgb: look.sail).cgColor)
        cg.addPath(g.sail)
        cg.fillPath()
        if let panel = sailGraphicPath(look.sailGraphic, g) {
            cg.setFillColor(UIColor(rgb: look.accent ?? look.sail).cgColor)
            cg.addPath(panel)
            cg.fillPath()
        }
        drawNumber(look.sailNumber, in: numberFrame(g), ink: UIColor(rgb: look.numberInk), cg: cg)
        cg.restoreGState()
        // A dark hairline round the sail, so a sail in the deck's colour doesn't merge into the hull.
        let edge = ChartPalette.markEdge.uiColor.cgColor
        cg.addPath(g.sail)
        cg.setStrokeColor(edge)
        cg.setLineWidth(max(1, g.beam * 0.02))
        cg.setLineJoin(.round)
        cg.strokePath()
        let mastRadius = max(1.5, g.beam * 0.07)
        cg.setFillColor(edge)
        cg.fillEllipse(in: CGRect(x: -mastRadius, y: -mastRadius, width: mastRadius * 2, height: mastRadius * 2))
        cg.restoreGState()
    }

    /// The sail number's digits centred in `frame` (sail space) and fitted to it, running along the boom.
    ///
    /// Text space (x along the line, y down the glyphs) maps to sail space as x → +y (forward) and y → +x
    /// (starboard), so under the render's bow-right, starboard-down mapping the digits read left to right, upright.
    private static func drawNumber(_ number: Int, in frame: CGRect, ink: UIColor, cg: CGContext) {
        let text = String(number) as NSString
        let along = frame.height, across = frame.width
        var font = UIFont.monospacedDigitSystemFont(ofSize: across * 0.8, weight: .heavy)
        var size = text.size(withAttributes: [.font: font])
        if size.width > along * 0.9 {
            font = UIFont.monospacedDigitSystemFont(ofSize: font.pointSize * along * 0.9 / size.width, weight: .heavy)
            size = text.size(withAttributes: [.font: font])
        }
        cg.saveGState()
        cg.translateBy(x: frame.midX, y: frame.midY)
        cg.concatenate(CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0))
        UIGraphicsPushContext(cg)
        text.draw(at: CGPoint(x: -size.width / 2, y: -size.height / 2), withAttributes: [.font: font, .foregroundColor: ink])
        UIGraphicsPopContext()
        cg.restoreGState()
    }
}
