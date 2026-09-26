import Foundation
import RegattaCore

/// An overview map of a venue × conditions pairing (#83, for the venue art in #84): north up, the land,
/// the water tinted by depth at a venue with current, the longest course's race area at the authored mean
/// direction and at the widest seeded rotations (±`WindSetup.meanDirectionSpread`), its marks and start
/// line, and the landmarks. `regatta-venue-png` writes one per shipped pairing into `docs/venues/`.
public enum VenueOverview {
    /// Metres per pixel.
    public static let metresPerPixel = 2.5
    /// Metres of venue shown beyond the race areas on every side.
    public static let margin = 250.0

    /// Palette indices.
    enum Ink: UInt8 {
        case water, depth1, depth2, depth3, depth4, depth5, land, landmark, areaRotated, area, markRotated, mark,
             startLine, anchor
    }

    static let palette: [IndexedImage.Colour] = [
        .init(166, 208, 228),  // water, no current
        .init(196, 228, 238), .init(166, 210, 230), .init(130, 186, 218), .init(96, 160, 204), .init(64, 130, 186),
        .init(200, 208, 164),  // land
        .init(96, 64, 40),  // landmark
        .init(120, 128, 140),  // race area at ±10°
        .init(28, 32, 40),  // race area at the mean direction
        .init(244, 176, 120),  // marks at ±10°
        .init(226, 96, 24),  // marks at the mean direction
        .init(20, 20, 20),  // start line
        .init(200, 30, 60),  // start-line centre, the pairing's anchor
    ]

    /// "hollin-bay@1-classic-oscillating@2.png".
    public static func fileName(_ pairingCase: VenuePairingCase) -> String {
        "\(pairingCase.venue.ref.key)-\(pairingCase.conditions.ref.key).png"
    }

    public static func image(_ pairingCase: VenuePairingCase) -> IndexedImage {
        let spread = WindSetup.meanDirectionSpread
        let rotated = [-spread, spread].map(pairingCase.longestCourse(rotation:))
        let course = pairingCase.longestCourse(rotation: 0)
        let venue = pairingCase.venue.content
        let frame = Frame(around: ([course] + rotated).flatMap(\.raceArea.corners) + venue.landmarks.map(\.position))
        var image = IndexedImage(width: frame.width, height: frame.height, palette: palette, fill: Ink.water.rawValue)

        if let current = venue.current {
            let field = CurrentField(current: current, tideStateAtGun: 0)
            for y in 0..<image.height {
                for x in 0..<image.width {
                    let depth = field.depth(at: frame.world(x, y))
                    let band = min(4, Int(5 * depth / current.maxDepth))
                    image[x, y] = Ink.depth1.rawValue + UInt8(band)
                }
            }
        }
        for polygon in venue.land { fill(polygon.points, frame: frame, ink: .land, in: &image) }
        for area in rotated.map(\.raceArea) { outline(area.corners, frame: frame, ink: .areaRotated, width: 1, in: &image) }
        outline(course.raceArea.corners, frame: frame, ink: .area, width: 2, in: &image)
        for layout in rotated {
            for mark in layout.obstacles { disc(frame.pixel(mark.position), radius: 2, ink: .markRotated, in: &image) }
        }
        line(frame.pixel(course.startLine.pin.position), frame.pixel(course.startLine.committee.position),
             ink: .startLine, width: 1, in: &image)
        for mark in course.obstacles { disc(frame.pixel(mark.position), radius: 3, ink: .mark, in: &image) }
        disc(frame.pixel(pairingCase.pairing.startLineCentre), radius: 1, ink: .anchor, in: &image)
        for landmark in venue.landmarks {
            let (x, y) = frame.pixel(landmark.position)
            for dy in -3...3 { for dx in -3...3 { image.plot(Int(x.rounded()) + dx, Int(y.rounded()) + dy, Ink.landmark.rawValue) } }
        }
        return image
    }

    /// The window shown: the bounding box of the race areas and the landmarks, and `margin`, snapped out
    /// to whole 50 m.
    struct Frame {
        let minX: Double, maxY: Double
        let width: Int, height: Int

        init(around corners: [Vec2]) {
            let snap = 50.0
            minX = ((corners.map(\.x).min()! - margin) / snap).rounded(.down) * snap
            let maxX = ((corners.map(\.x).max()! + margin) / snap).rounded(.up) * snap
            let minY = ((corners.map(\.y).min()! - margin) / snap).rounded(.down) * snap
            maxY = ((corners.map(\.y).max()! + margin) / snap).rounded(.up) * snap
            width = Int(((maxX - minX) / metresPerPixel).rounded())
            height = Int(((maxY - minY) / metresPerPixel).rounded())
        }

        /// The venue point at the centre of pixel (`x`, `y`).
        func world(_ x: Int, _ y: Int) -> Vec2 {
            Vec2(minX + (Double(x) + 0.5) * metresPerPixel, maxY - (Double(y) + 0.5) * metresPerPixel)
        }

        /// Pixel coordinates of `p`, fractional, with pixel centres at half-integers.
        func pixel(_ p: Vec2) -> (x: Double, y: Double) {
            ((p.x - minX) / metresPerPixel, (maxY - p.y) / metresPerPixel)
        }
    }

    /// Fills `polygon` by scanlines through pixel centres, even-odd.
    static func fill(_ polygon: [Vec2], frame: Frame, ink: Ink, in image: inout IndexedImage) {
        for y in 0..<image.height {
            let worldY = frame.world(0, y).y
            var crossings: [Double] = []
            for i in polygon.indices {
                let a = polygon[i], b = polygon[(i + 1) % polygon.count]
                guard (a.y > worldY) != (b.y > worldY) else { continue }
                crossings.append(a.x + (worldY - a.y) * (b.x - a.x) / (b.y - a.y))
            }
            crossings.sort()
            for pair in stride(from: 0, to: crossings.count - 1, by: 2) {
                let from = max(0, Int(((crossings[pair] - frame.minX) / metresPerPixel - 0.5).rounded(.up)))
                let to = min(image.width - 1, Int(((crossings[pair + 1] - frame.minX) / metresPerPixel - 0.5).rounded(.down)))
                if from <= to { for x in from...to { image[x, y] = ink.rawValue } }
            }
        }
    }

    static func outline(_ corners: [Vec2], frame: Frame, ink: Ink, width: Int, in image: inout IndexedImage) {
        for i in corners.indices {
            line(frame.pixel(corners[i]), frame.pixel(corners[(i + 1) % corners.count]), ink: ink, width: width, in: &image)
        }
    }

    static func line(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double), ink: Ink, width: Int, in image: inout IndexedImage) {
        let steps = max(1, Int((max(abs(b.x - a.x), abs(b.y - a.y)) * 2).rounded(.up)))
        for s in 0...steps {
            let t = Double(s) / Double(steps)
            let x = Int((a.x + (b.x - a.x) * t).rounded(.down)), y = Int((a.y + (b.y - a.y) * t).rounded(.down))
            for dy in 0..<width { for dx in 0..<width { image.plot(x + dx, y + dy, ink.rawValue) } }
        }
    }

    static func disc(_ centre: (x: Double, y: Double), radius: Int, ink: Ink, in image: inout IndexedImage) {
        let cx = Int(centre.x.rounded(.down)), cy = Int(centre.y.rounded(.down))
        for dy in -radius...radius {
            for dx in -radius...radius where dx * dx + dy * dy <= radius * radius {
                image.plot(cx + dx, cy + dy, ink.rawValue)
            }
        }
    }
}

/// `regatta-venue-png [<directory>]`: writes `VenueOverview`'s PNG of every shipped pairing
/// (`ShippedVenues`) into the directory (default `docs/venues`, from the repository root), creating it if
/// needed, and prints each file's path.
public enum VenuePNGCommand {
    public static let usage = "usage: regatta-venue-png [<directory>]  (default docs/venues)"

    public static func main(arguments: [String]) -> Int32 {
        guard arguments.count <= 1, !arguments.contains(where: { $0.hasPrefix("-") }) else {
            FileHandle.standardError.write(Data((usage + "\n").utf8))
            return 2
        }
        let directory = URL(fileURLWithPath: arguments.first ?? "docs/venues", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for pairingCase in try ShippedVenues.pairings() {
                let url = directory.appendingPathComponent(VenueOverview.fileName(pairingCase))
                try VenueOverview.image(pairingCase).png.write(to: url)
                print(url.path)
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("regatta-venue-png: \(error)\n".utf8))
            return 1
        }
    }
}
