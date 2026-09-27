import Foundation
import Testing
import UIKit
@testable import Regatta

/// The race scene's and HUD's palette (#111): the reserved-colour hue rule (#22, G7) and the values in
/// `docs/palette.md`.
@MainActor @Suite struct PaletteTests {
    /// The acceptance check: every colour the rule holds the app to (G7: the race scene and HUD, not the menus)
    /// is at least 20° of OKLCH hue from each reserved cue hue, or too grey to have one.
    @Test func everyValidatedTokenIsTwentyDegreesFromEveryReservedHue() {
        let rule = HueRule.reservedCues
        #expect(rule.minimumHueDistance == 20)
        #expect(rule.reserved.map(\.name) == ["vermillion", "orange", "yellow", "chevronBlue"])
        #expect(PaletteValidation.raceSceneAndHUD.count == ChartPalette.all.count + Palette.boats.count)
        let violations = rule.violations(in: PaletteValidation.raceSceneAndHUD)
        #expect(violations.isEmpty, "\(violations)")
        for token in PaletteValidation.raceSceneAndHUD where !rule.isExempt(token) {
            for cue in rule.reserved {
                #expect(OKLCH.hueDistance(token.oklch.h, cue.oklch.h) >= 20, "\(token) vs \(cue)")
            }
        }
    }

    /// The cues are told apart by hue too: each reserved hue is at least the rule's distance from every other
    /// (vermillion–orange 29°, orange–yellow 28°, `docs/palette.md`).
    @Test func reservedCueHuesAreApartFromEachOther() {
        let rule = HueRule.reservedCues
        for (i, a) in rule.reserved.enumerated() {
            for b in rule.reserved[(i + 1)...] {
                let distance = OKLCH.hueDistance(a.oklch.h, b.oklch.h)
                #expect(distance >= rule.minimumHueDistance, "\(a) and \(b) are \(distance)° apart")
            }
        }
    }

    /// `docs/palette.md` is the source of the values: every `CuePalette` and `ChartPalette` row there is a token
    /// here with the same hex, and this OKLCH conversion reproduces the lightness, chroma and hue it lists.
    @Test func tokensAreDocsPaletteValues() throws {
        let rows = try Self.documentedTokens()
        let tokens = CuePalette.all + ChartPalette.all
        #expect(Set(rows.keys) == Set(tokens.map(\.name)))
        for token in tokens {
            let row = try #require(rows[token.name], "\(token.name) isn't in docs/palette.md")
            #expect(token.rgb == row.rgb, "\(token) vs the doc's #\(String(format: "%06X", row.rgb))")
            let oklch = token.oklch
            #expect(abs(oklch.L - row.L) <= 0.006, "\(token) L \(oklch.L) vs \(row.L)")
            #expect(abs(oklch.C - row.C) <= 0.001, "\(token) C \(oklch.C) vs \(row.C)")
            if let h = row.h {
                #expect(OKLCH.hueDistance(oklch.h, h) <= 0.6, "\(token) h \(oklch.h) vs \(h)")
            }
        }
    }

    /// Puffs and lulls are the water's tone moved by the same lightness either way (the delta is the spec).
    @Test func puffAndLullAreTheWaterToneDelta() {
        let water = ChartPalette.water.oklch.L
        #expect(abs(ChartPalette.puff.oklch.L - (water - ChartPalette.toneDelta)) < 0.01)
        #expect(abs(ChartPalette.lull.oklch.L - (water + ChartPalette.toneDelta)) < 0.01)
    }

    /// Truer oranges than the cue's fall within 20° of vermillion (`docs/palette.md`), as did the prototype's
    /// mark colour; the rule flags each.
    @Test func theRuleFlagsColoursNearACue() {
        let rule = HueRule.reservedCues
        let prototypeMark = PaletteToken("prototype mark", 0xFF7A1A)
        let trueOrange = PaletteToken("true orange", 0xF28C28)
        let iosOrange = PaletteToken("iOS orange", 0xFF9500)
        for token in [prototypeMark, trueOrange, iosOrange] {
            let violations = rule.violations(in: [token])
            #expect(violations.contains { $0.reserved == CuePalette.vermillion }, "\(token): \(violations)")
        }
        let nearVermillion = rule.violations(in: [trueOrange]).first { $0.reserved == CuePalette.vermillion }
        #expect(abs((nearVermillion?.distance ?? 0) - 11) < 1, "#F28C28 is 11° from vermillion in the doc")
    }

    /// Near-neutrals have no hue to speak of, so the rule passes them below the chroma floor (C < 0.06) whatever
    /// their nominal hue: white, the inactive grey, land and shallows.
    @Test func theRuleExemptsNearNeutrals() {
        let rule = HueRule.reservedCues
        #expect(rule.chromaFloor == 0.06)
        for token in [CuePalette.cueWhite, CuePalette.inactiveGrey, ChartPalette.land, ChartPalette.shallows] {
            #expect(rule.isExempt(token), "\(token) C \(token.oklch.C)")
        }
        // A greyed orange sits on orange's hue but under the floor; the full orange doesn't.
        let greyedOrange = PaletteToken("greyed orange", 0xA89C88)
        #expect(OKLCH.hueDistance(greyedOrange.oklch.h, CuePalette.orange.oklch.h) < 20)
        #expect(rule.violations(in: [greyedOrange]).isEmpty)
        #expect(!rule.violations(in: [PaletteToken("orange again", 0xE69F00)]).isEmpty)
    }

    /// The rule takes any token set, reserved set and tunings (G7: the caller picks what's validated; #118's
    /// livery swatches bring theirs).
    @Test func theRuleIsConfigurable() {
        // Water is 29° from the chevron: it passes at 20°, not at 30°.
        let chevronOnly = HueRule(reserved: [CuePalette.chevronBlue])
        #expect(chevronOnly.violations(in: [ChartPalette.water]).isEmpty)
        var stricter = chevronOnly
        stricter.minimumHueDistance = 30
        #expect(stricter.violations(in: [ChartPalette.water]).map(\.token) == [ChartPalette.water])
        // Raising the chroma floor above the water's (0.081) exempts it.
        stricter.chromaFloor = 0.09
        #expect(stricter.violations(in: [ChartPalette.water]).isEmpty)
    }

    @Test func hueDistanceIsTheShorterWayRound() {
        #expect(OKLCH.hueDistance(350, 10) == 20)
        #expect(OKLCH.hueDistance(10, 350) == 20)
        #expect(OKLCH.hueDistance(0, 180) == 180)
        #expect(OKLCH.hueDistance(90, 90) == 0)
    }

    /// The interim boat colours (#119 replaces them) keep index 0 for the player and wrap past the end.
    @Test func boatColoursWrapAround() {
        #expect(Palette.boat(0) == Palette.boats[0].uiColor)
        #expect(Palette.boat(Palette.boats.count) == Palette.boat(0))
    }

    /// `docs/palette.md`'s `CuePalette` and `ChartPalette` rows: name, hex and OKLCH (`L / C / h`, h `—` for none).
    static func documentedTokens() throws -> [String: (rgb: UInt32, L: Double, C: Double, h: Double?)] {
        let doc = try String(contentsOf: RaceDriverTests.repoRoot.appending(path: "docs/palette.md"), encoding: .utf8)
        let row = /^\| `(\w+)` \| `#([0-9A-Fa-f]{6})` \| ([0-9.]+) \/ ([0-9.]+) \/ ([0-9.]+|—) \|/
        var rows: [String: (rgb: UInt32, L: Double, C: Double, h: Double?)] = [:]
        for line in doc.split(separator: "\n") {
            guard let match = try row.firstMatch(in: String(line)),
                  let rgb = UInt32(match.2, radix: 16), let L = Double(match.3), let C = Double(match.4) else { continue }
            rows[String(match.1)] = (rgb, L, C, Double(match.5))
        }
        return rows
    }
}

/// Nothing in the app depends on red or green (#5, #15), and neither colour is a cue (#22): the app's sources
/// never name them (#111).
@MainActor @Suite struct ForbiddenColourSourceTests {
    /// Reads the app's sources from the checkout on the host, as `GameSceneSourceTests` does.
    @Test func noSourceNamesRedOrGreen() throws {
        let app = RaceDriverTests.repoRoot.appending(path: "Regatta")
        let files = try #require(FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        #expect(files.count > 30, "found \(files.count) Swift files under \(app.path)")
        #expect(files.contains { $0.lastPathComponent == "HUDView.swift" })

        // `UIColor.red`, `Color.green` and the like, and the implicit members (`.foregroundStyle(.red)`), with
        // `systemRed` and `systemGreen`. Simple word boundaries: Unicode ones don't break `Color.red.opacity`
        // after `red`.
        let named = /\b(UI)?Color\.(red|green|systemRed|systemGreen)\b/.wordBoundaryKind(.simple)
        let implicit = /(^|[^\w.])\.(red|green|systemRed|systemGreen)\b/.wordBoundaryKind(.simple)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let text = String(line)
                if try named.firstMatch(in: text) != nil || implicit.firstMatch(in: text) != nil {
                    Issue.record("\(file.lastPathComponent):\(number + 1): \(text.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
    }
}
