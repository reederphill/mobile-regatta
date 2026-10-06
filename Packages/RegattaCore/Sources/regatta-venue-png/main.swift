import Foundation
import RegattaCore

// regatta-venue-png: an overview PNG per venue × conditions pairing (#83), for the human review (#84) and the chart
// layer (#115). Offline tooling, not shipped code.
//
//     swift run --package-path Packages/RegattaCore regatta-venue-png [output-dir] [venue@version ...]
//
// Defaults: the repository's docs/venues (found from this source file, wherever the command runs) and the three real
// venues. Each pairing's course is VenueCheck's (largest fleet, longest
// beat): land, depth tint, the race area at the seeded mean's −10° (orange), authored (grey) and +10° (purple)
// rotations with their marks and start lines, the anchor, and landmarks, under a title naming both files. The
// check's findings and the sailability margins are printed.

var arguments = Array(CommandLine.arguments.dropFirst())
/// The repository's docs/venues: this file is Packages/RegattaCore/Sources/regatta-venue-png/main.swift (#316).
let defaultOutputDirectory = (0..<5).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
    .appendingPathComponent("docs/venues").path
let outputDirectory = arguments.isEmpty ? defaultOutputDirectory : arguments.removeFirst()
let venueNames = arguments.isEmpty ? ["hollin-bay@1", "saltings-reach@1", "fellmere@1"] : arguments

/// Metres per pixel.
let scale = 2.0
/// Metres drawn beyond the race areas.
let margin = 250.0

enum Colour: UInt8, CaseIterable {
    case water, depth1, depth2, depth3, depth4, depth5, land, areaMinus, areaZero, areaPlus, mark, line, anchor,
         landmark, text, band
    var rgb: (UInt8, UInt8, UInt8) {
        switch self {
        case .water: (214, 234, 248)
        case .depth1: (190, 221, 243)
        case .depth2: (160, 204, 236)
        case .depth3: (126, 183, 226)
        case .depth4: (92, 160, 214)
        case .depth5: (60, 134, 198)
        case .land: (204, 214, 170)
        case .areaMinus: (230, 126, 34)
        case .areaZero: (90, 90, 90)
        case .areaPlus: (142, 68, 173)
        case .mark: (200, 30, 30)
        case .line: (20, 20, 20)
        case .anchor: (0, 0, 0)
        case .landmark: (39, 100, 50)
        case .text: (20, 20, 20)
        case .band: (255, 255, 255)
        }
    }
}

struct Canvas {
    let width: Int, height: Int
    let minX: Double, maxY: Double
    static let titleHeight = 24
    var pixels: [UInt8]

    init(minX: Double, maxX: Double, minY: Double, maxY: Double) {
        width = Int(((maxX - minX) / scale).rounded(.up))
        height = Int(((maxY - minY) / scale).rounded(.up)) + Self.titleHeight
        self.minX = minX
        self.maxY = maxY
        pixels = Array(repeating: Colour.water.rawValue, count: width * height)
    }

    /// The venue point at the centre of pixel (x, y).
    func world(_ x: Int, _ y: Int) -> Vec2 {
        Vec2(minX + (Double(x) + 0.5) * scale, maxY - (Double(y - Self.titleHeight) + 0.5) * scale)
    }

    func pixel(_ p: Vec2) -> (Int, Int) {
        (Int(((p.x - minX) / scale).rounded(.down)), Int(((maxY - p.y) / scale).rounded(.down)) + Self.titleHeight)
    }

    mutating func set(_ x: Int, _ y: Int, _ c: Colour) {
        guard x >= 0, x < width, y >= Self.titleHeight, y < height else { return }
        pixels[y * width + x] = c.rawValue
    }

    mutating func fill(_ c: Colour, where inside: (Vec2) -> Bool) {
        for y in Self.titleHeight..<height {
            for x in 0..<width where inside(world(x, y)) { pixels[y * width + x] = c.rawValue }
        }
    }

    mutating func disc(_ p: Vec2, radius: Int, _ c: Colour) {
        let (cx, cy) = pixel(p)
        for dy in -radius...radius {
            for dx in -radius...radius where dx * dx + dy * dy <= radius * radius { set(cx + dx, cy + dy, c) }
        }
    }

    mutating func line(_ a: Vec2, _ b: Vec2, _ c: Colour, width w: Int = 1, dash: Int = 0) {
        let (x0, y0) = pixel(a), (x1, y1) = pixel(b)
        let steps = max(abs(x1 - x0), abs(y1 - y0), 1)
        for i in 0...steps {
            if dash > 0 && (i / dash) % 2 == 1 { continue }
            let x = x0 + (x1 - x0) * i / steps, y = y0 + (y1 - y0) * i / steps
            for dy in 0..<w { for dx in 0..<w { set(x + dx, y + dy, c) } }
        }
    }

    mutating func text(_ string: String, x: Int, y: Int, size: Int) {
        var cx = x
        for ch in string.uppercased() {
            let rows = Font.glyphs[ch] ?? Font.glyphs["?"]!
            for (r, row) in rows.enumerated() {
                for (col, bit) in row.enumerated() where bit == "#" {
                    for dy in 0..<size { for dx in 0..<size {
                        let px = cx + col * size + dx, py = y + r * size + dy
                        if px >= 0 && px < width && py >= 0 && py < height { pixels[py * width + px] = Colour.text.rawValue }
                    } }
                }
            }
            cx += 6 * size
        }
    }
}

/// A 5 × 7 bitmap font: the characters venue and conditions ids use.
enum Font {
    static let glyphs: [Character: [String]] = [
        "A": [".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
        "B": ["####.", "#...#", "#...#", "####.", "#...#", "#...#", "####."],
        "C": [".###.", "#...#", "#....", "#....", "#....", "#...#", ".###."],
        "D": ["####.", "#...#", "#...#", "#...#", "#...#", "#...#", "####."],
        "E": ["#####", "#....", "#....", "####.", "#....", "#....", "#####"],
        "F": ["#####", "#....", "#....", "####.", "#....", "#....", "#...."],
        "G": [".###.", "#...#", "#....", "#.###", "#...#", "#...#", ".####"],
        "H": ["#...#", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
        "I": [".###.", "..#..", "..#..", "..#..", "..#..", "..#..", ".###."],
        "J": ["..###", "...#.", "...#.", "...#.", "...#.", "#..#.", ".##.."],
        "K": ["#...#", "#..#.", "#.#..", "##...", "#.#..", "#..#.", "#...#"],
        "L": ["#....", "#....", "#....", "#....", "#....", "#....", "#####"],
        "M": ["#...#", "##.##", "#.#.#", "#.#.#", "#...#", "#...#", "#...#"],
        "N": ["#...#", "#...#", "##..#", "#.#.#", "#..##", "#...#", "#...#"],
        "O": [".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
        "P": ["####.", "#...#", "#...#", "####.", "#....", "#....", "#...."],
        "Q": [".###.", "#...#", "#...#", "#...#", "#.#.#", "#..#.", ".##.#"],
        "R": ["####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#"],
        "S": [".####", "#....", "#....", ".###.", "....#", "....#", "####."],
        "T": ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.."],
        "U": ["#...#", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
        "V": ["#...#", "#...#", "#...#", "#...#", "#...#", ".#.#.", "..#.."],
        "W": ["#...#", "#...#", "#...#", "#.#.#", "#.#.#", "#.#.#", ".#.#."],
        "X": ["#...#", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "#...#"],
        "Y": ["#...#", "#...#", ".#.#.", "..#..", "..#..", "..#..", "..#.."],
        "Z": ["#####", "....#", "...#.", "..#..", ".#...", "#....", "#####"],
        "0": [".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###."],
        "1": ["..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."],
        "2": [".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"],
        "3": ["#####", "...#.", "..#..", "...#.", "....#", "#...#", ".###."],
        "4": ["...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."],
        "5": ["#####", "#....", "####.", "....#", "....#", "#...#", ".###."],
        "6": ["..##.", ".#...", "#....", "####.", "#...#", "#...#", ".###."],
        "7": ["#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..."],
        "8": [".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."],
        "9": [".###.", "#...#", "#...#", ".####", "....#", "...#.", ".##.."],
        "@": [".###.", "#...#", "#.###", "#.#.#", "#.###", "#....", ".###."],
        "-": [".....", ".....", ".....", "#####", ".....", ".....", "....."],
        "/": [".....", "....#", "...#.", "..#..", ".#...", "#....", "....."],
        ".": [".....", ".....", ".....", ".....", ".....", ".##..", ".##.."],
        " ": [".....", ".....", ".....", ".....", ".....", ".....", "....."],
        "?": [".###.", "#...#", "....#", "...#.", "..#..", ".....", "..#.."],
    ]
}

func draw(venue file: VenueFile, pairing: Venue.Pairing, conditions: ConditionsFile) -> Data {
    let venue = file.content
    let defaults = RaceFiles.defaults
    let layouts = VenueCheck.layouts(venue: venue, pairing: pairing, conditions: conditions,
                                     boatClass: defaults.boatClass.content, rules: defaults.rulesConfiguration.content)
    let corners = layouts.flatMap { $0.layout.raceArea.corners }
    var canvas = Canvas(minX: corners.map(\.x).min()! - margin, maxX: corners.map(\.x).max()! + margin,
                        minY: corners.map(\.y).min()! - margin, maxY: corners.map(\.y).max()! + margin)

    if let current = venue.current {
        let field = CurrentField(current: current, tideStateAtGun: 0)
        let tints: [Colour] = [.depth1, .depth2, .depth3, .depth4, .depth5]
        for y in Canvas.titleHeight..<canvas.height {
            for x in 0..<canvas.width {
                let depth = field.depth(at: canvas.world(x, y))
                guard depth > 0 else { continue }
                let level = min(tints.count - 1, Int(depth / current.maxDepth * Double(tints.count)))
                canvas.set(x, y, tints[level])
            }
        }
    }
    canvas.fill(.land, where: venue.isLand)

    // The authored rotation, then both extremes over it.
    let shown = [(layouts[layouts.count / 2].layout, Colour.areaZero, 6), (layouts[0].layout, .areaMinus, 0),
                 (layouts[layouts.count - 1].layout, .areaPlus, 0)]
    for (layout, colour, dash) in shown {
        let c = layout.raceArea.corners
        for i in c.indices { canvas.line(c[i], c[(i + 1) % c.count], colour, width: 2, dash: dash) }
        canvas.line(layout.startLine.pin.position, layout.startLine.committee.position, .line, width: 2)
        for mark in layout.elements.flatMap(\.marks) { canvas.disc(mark.position, radius: 3, .mark) }
    }
    canvas.disc(pairing.startLineCentre, radius: 4, .anchor)
    for landmark in venue.landmarks {
        let (x, y) = canvas.pixel(landmark.position)
        for dy in -5...5 { for dx in -5...5 where abs(dx) == 5 || abs(dy) == 5 || (abs(dx) < 3 && abs(dy) < 3) {
            canvas.set(x + dx, y + dy, .landmark)
        } }
    }

    for y in 0..<Canvas.titleHeight { for x in 0..<canvas.width { canvas.pixels[y * canvas.width + x] = Colour.band.rawValue } }
    let title = "\(file.id)@\(file.version) / \(conditions.id)@\(conditions.version)"
    canvas.text(title, x: 6, y: 5, size: 2)
    return PNG.encode(width: canvas.width, height: canvas.height, pixels: canvas.pixels,
                      palette: Colour.allCases.map(\.rgb), title: "\(venue.displayName): \(title)")
}

do {
    try FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
    var failed = false
    for name in venueNames {
        let parts = name.split(separator: "@")
        guard parts.count == 2, let version = Int(parts[1]) else {
            FileHandle.standardError.write(Data("regatta-venue-png: \(name) isn't id@version\n".utf8))
            exit(2)
        }
        let file = try VenueFile.bundled(id: String(parts[0]), version: version)
        for finding in VenueCheck.check(file.content) {
            print("check  \(name) \(finding)")
            failed = true
        }
        for result in VenueSailability.check(file.content) {
            print("sail   \(name) \(result)\(result.passes ? "" : " FAILS")")
            failed = failed || !result.passes
        }
        for pairing in file.content.pairings {
            let conditions = try ConditionsFile.bundled(id: pairing.conditions.id, version: pairing.conditions.version)
            let path = "\(outputDirectory)/\(file.id)@\(file.version)__\(conditions.id)@\(conditions.version).png"
            let data = draw(venue: file, pairing: pairing, conditions: conditions)
            try data.write(to: URL(fileURLWithPath: path))
            print("wrote  \(path) (\(data.count) bytes)")
        }
    }
    exit(failed ? 1 : 0)
} catch {
    FileHandle.standardError.write(Data("regatta-venue-png: \(error)\n".utf8))
    exit(2)
}
