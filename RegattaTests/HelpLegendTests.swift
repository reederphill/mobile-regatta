import Foundation
import Testing
import UIKit
@testable import Regatta

/// The Help legend (#135): every on-water symbol, drawn by the race's own renderer (`LegendArt`).
@MainActor @Suite struct HelpLegendTests {
    /// The symbols #23 lists, in the glossary's words (the right-of-way glow, the wind shadow).
    @Test func legendListsEverySymbol() {
        #expect(LegendItem.allCases == [.vane, .pinchFoot, .wake, .puff, .lull, .windShadow, .layline, .ladderLine,
                                        .keepClear, .keepsClearOfYou, .nextMark, .otherMark, .ruleCall, .penaltyArc])
        for item in LegendItem.allCases {
            #expect(!item.title.isEmpty && !item.line.isEmpty, "\(item)")
        }
    }

    /// Every item's picture is drawn, at the legend's size, every pixel opaque, with more on it than the bare water:
    /// a share of its pixels well off the water's colour.
    @Test func everyLegendItemRendersNonEmpty() throws {
        for item in LegendItem.allCases {
            let image = try #require(LegendArt.image(for: item), "\(item): no picture")
            let cg = try #require(image.cgImage)
            #expect(cg.width > 0 && cg.height > 0)
            let pixels = try #require(Self.rgba(cg))
            let opaque = pixels.indices.filter { $0 % 4 == 3 && pixels[$0] > 200 }.count
            let total = cg.width * cg.height
            #expect(opaque > total * 9 / 10, "\(item): \(opaque) of \(total) pixels drawn")
            // Something on the water: pixels well away from the water's own colour.
            let water = ChartPalette.water.uiColor.rgba8
            let marked = stride(from: 0, to: pixels.count, by: 4).filter { i in
                abs(Int(pixels[i]) - water.0) + abs(Int(pixels[i + 1]) - water.1) + abs(Int(pixels[i + 2]) - water.2) > 24
            }.count
            #expect(marked > total / 200, "\(item): \(marked) of \(total) pixels off the water's colour")
            #expect(image.size == LegendArt.size, "\(item): \(image.size)")
        }
    }

    /// `cg` as 8-bit RGBA, premultiplied.
    static func rgba(_ cg: CGImage) -> [UInt8]? {
        var data = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8,
                                          bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            return true
        }
        return drawn ? data : nil
    }

    /// Opening Help over a race lets go of the controls (#135): Ease is let go and the held buttons are told, and
    /// a race that can't pause (online) keeps running.
    @Test func openingHelpReleasesTheControls() throws {
        let session = GameSession(config: RaceConfig(opponents: 1, seed: 1, windSeed: 1))
        session.setEase(true)
        let releases = session.controlReleases
        session.releaseControls()
        #expect(!session.isEasing)
        #expect(!session.isPaused, "Help alone doesn't pause the race")
        #expect(session.controlReleases == releases + 1)

        let (fixture, log) = try RenderFixture.load(named: "prestart", in: RenderFixtureTests.fixtures)
        let frozen = try GameSession(fixture: fixture, log: log)
        frozen.setEase(true)
        frozen.setPaused(true)
        #expect(!frozen.isPaused && !frozen.isEasing, "a race that can't pause runs on, its controls let go")
    }

    /// Help's topics: never one for what the game doesn't have yet (the protest picker, the committee sounds).
    @Test func helpTopicsAreTheBuiltOnes() {
        #expect(HelpTopic.allCases == [.symbols, .steering, .rules, .current])
    }

    /// The Help galleries (#135): its topics, and one topic's page.
    @Test func helpFixturesParse() throws {
        #expect(try RenderFixture.gallery(named: "help", in: RenderFixtureTests.fixtures) == .help(nil))
        #expect(try RenderFixture.gallery(named: "help-symbols", in: RenderFixtureTests.fixtures) == .help(.symbols))
    }
}

private extension UIColor {
    var rgba8: (Int, Int, Int) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Int(r * 255), Int(g * 255), Int(b * 255))
    }
}
