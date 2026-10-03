import SpriteKit
import UIKit
import RegattaCore

/// How the wind shadow is drawn (#376 follow-on A): the cones and backwinds of today (`BoatEffects`), the
/// turbulence-trail prototype (`TurbulenceTrails`, `TurbulenceTrailLayer`), or both over each other. A Debug look
/// (the tuning panel's, and `-shadowDrawing`); Release always draws the cones.
enum ShadowDrawing: String, Codable, CaseIterable {
    case cones, trails, both

    var drawsCones: Bool { self != .trails }
    var drawsTrails: Bool { self != .cones }
}

/// The turbulence trails drawn (#376 follow-on A): one soft ribbon a caster and kind (cone or backwind), along her live
/// samples' drifted centres from oldest to newest. A ribbon is one sprite (`strip`) warped along the track
/// (`SKWarpGeometryGrid`, a column a sample, three rows: one edge, the centreline, the other edge), so it has no seams.
/// Its texture carries both falloffs: across the width white along the middle, clear at the edges (as a sample's loss
/// falls from its centre), and along the length each sample's column sits at its life left (`1 − age/life`), so it fades
/// as the model's loss does. The newest end is capped with a soft disc at half its alpha so the ribbon doesn't start
/// square at the boat; a lone sample draws as the disc. Different casters overlap and blend, as they stack in the model.
/// Cone ribbons draw at the cone's hatch alpha (`BoatStyle.coneAlpha`) and z, backwind ones at the backwind's share of
/// it (`BoatStyle.backwindShare`) and z, both in the cues' white, as `BoatEffects` draws them. The sprites are pooled:
/// grown on demand, the unused ones hidden. Drawn only; the race never reads the trails.
final class TurbulenceTrailLayer: SKNode {
    /// The disc a lone sample, or a ribbon's newest end, draws with, made once.
    static let disc: SKTexture = {
        let side: CGFloat = 64
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            let colors = [UIColor.white.cgColor, UIColor.white.withAlphaComponent(0).cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors,
                                            locations: [0, 1]) else { return }
            let centre = CGPoint(x: side / 2, y: side / 2)
            context.cgContext.drawRadialGradient(gradient, startCenter: centre, startRadius: 0, endCenter: centre,
                                                 endRadius: side / 2, options: [])
        }
        return SKTexture(image: image)
    }()

    /// The texture a ribbon is warped from, made once: along its length (u, x) alpha = u, clear at the dead end to
    /// white at the newest; across its width (v, y) clear to white to clear, linearly, as a sample's loss falls.
    static let strip: SKTexture = {
        let width = 64, height = 32
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let v = (Double(y) + 0.5) / Double(height)
            let across = max(0, 1 - abs(2 * v - 1))
            for x in 0..<width {
                let u = Double(x) / Double(width - 1)
                // Premultiplied white.
                let a = UInt8((u * across * 255).rounded())
                let i = (y * width + x) * 4
                pixels[i] = a; pixels[i + 1] = a; pixels[i + 2] = a; pixels[i + 3] = a
            }
        }
        let texture = pixels.withUnsafeBytes { bytes in
            SKTexture(data: Data(bytes), size: CGSize(width: width, height: height))
        }
        texture.filteringMode = .linear
        return texture
    }()

    private let ppm: CGFloat
    private(set) var sprites: [SKSpriteNode] = []

    /// The sprites drawing now.
    var visibleCount: Int { sprites.filter { !$0.isHidden }.count }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    init(pointsPerMeter ppm: CGFloat) {
        self.ppm = ppm
        super.init()
        name = "turbulenceTrails"
    }

    /// A live sample where it is now: its drifted centre and grown radius (metres), the life it has left (0...1), its
    /// strength (its peak as a share of its kind's strongest) and its alpha.
    private struct Point {
        var centre: Vec2
        var radius: Double
        var left: Double
        var strength: Double
        var alpha: Double
    }

    /// Draws `samples` at race time `time` (seconds; between ticks, so they drift smoothly), in `shadow`'s class and
    /// `style`'s alphas: a ribbon a caster and kind and its cap. A sample past its life, or not yet born, draws nothing.
    func update(samples: [TurbulenceTrails.Sample], time: Double, shadow: BoatClass.WindShadow, style: BoatStyle) {
        struct Key: Hashable, Comparable {
            var caster: Int
            var isBackwind: Bool
            static func < (a: Key, b: Key) -> Bool {
                (a.caster, a.isBackwind ? 1 : 0) < (b.caster, b.isBackwind ? 1 : 0)
            }
        }
        var ribbons: [Key: [(born: Int, point: Point)]] = [:]
        for sample in samples {
            let age = max(0, time - Double(sample.born) * Race.dt)
            guard age < sample.life else { continue }
            let strongest = sample.isBackwind ? shadow.backwindLoss : shadow.lossCloseIn
            let point = Point(centre: sample.position + sample.drift * age, radius: sample.radius + sample.growth * age,
                              left: 1 - age / sample.life, strength: strongest > 0 ? sample.peak / strongest : 0,
                              alpha: Self.alpha(of: sample, age: age, shadow: shadow, style: style))
            ribbons[Key(caster: sample.caster, isBackwind: sample.isBackwind), default: []].append((sample.born, point))
        }
        var used = 0
        func next(z: CGFloat) -> SKSpriteNode {
            if used == sprites.count { grow() }
            let sprite = sprites[used]
            used += 1
            sprite.zPosition = z
            sprite.isHidden = false
            return sprite
        }
        for key in ribbons.keys.sorted() {
            // Oldest to newest; samples born on one tick keep their order.
            let points = ribbons[key]!.enumerated().sorted { ($0.element.born, $0.offset) < ($1.element.born, $1.offset) }
                .map(\.element.point)
            let z = key.isBackwind ? BoatEffects.Layer.backwind : BoatEffects.Layer.cones
            if points.count >= 2 {
                let base = key.isBackwind ? style.coneAlpha * style.backwindShare : style.coneAlpha
                let strength = points.map(\.strength).reduce(0, +) / Double(points.count)
                let alpha = min(1, base * strength)
                if alpha > 0 { ribbon(next(z: z), along: points, alpha: alpha) }
            }
            guard let newest = points.last else { continue }
            let alpha = points.count == 1 ? newest.alpha : newest.alpha / 2
            guard alpha > 0 else { continue }
            let sprite = next(z: z)
            if sprite.texture !== Self.disc { sprite.texture = Self.disc }
            sprite.warpGeometry = nil
            sprite.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            let diameter = CGFloat(2 * newest.radius) * ppm
            sprite.position = CGPoint(x: newest.centre.x * ppm, y: newest.centre.y * ppm)
            sprite.size = CGSize(width: diameter, height: diameter)
            sprite.alpha = CGFloat(alpha)
        }
        for sprite in sprites[used...] where !sprite.isHidden { sprite.isHidden = true }
    }

    /// Warps `sprite` into the ribbon along `points` (oldest first, at least two): sized to their edges' bounding box,
    /// anchored at its bottom-left, column i drawn from `strip` at u = the sample's life left, its three rows at the
    /// centre − normal × radius, the centre, and the centre + normal × radius, the normal across the local track.
    private func ribbon(_ sprite: SKSpriteNode, along points: [Point], alpha: Double) {
        let n = points.count
        var lower: [Vec2] = [], upper: [Vec2] = []
        lower.reserveCapacity(n); upper.reserveCapacity(n)
        var lastNormal = Vec2(0, 1)
        for i in 0..<n {
            let tangent = points[min(i + 1, n - 1)].centre - points[max(i - 1, 0)].centre
            let length = tangent.length
            let normal = length > 1e-9 ? Vec2(-tangent.y / length, tangent.x / length) : lastNormal
            lastNormal = normal
            lower.append(points[i].centre - normal * points[i].radius)
            upper.append(points[i].centre + normal * points[i].radius)
        }
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for p in lower + upper {
            minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let origin = CGPoint(x: minX * ppm, y: minY * ppm)
        let size = CGSize(width: max(1, (maxX - minX) * ppm), height: max(1, (maxY - minY) * ppm))
        func normalized(_ p: Vec2) -> vector_float2 {
            vector_float2(Float((p.x * ppm - origin.x) / size.width), Float((p.y * ppm - origin.y) / size.height))
        }
        // Source u rising oldest to newest (lives differ a little sample to sample, so nudge a tie or a dip).
        var u = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let left = Float(min(1, max(0, points[i].left)))
            u[i] = i == 0 ? left : max(left, u[i - 1] + 1e-4)
        }
        var source: [vector_float2] = [], destination: [vector_float2] = []
        source.reserveCapacity(3 * n); destination.reserveCapacity(3 * n)
        for (row, v) in [Float(0), 0.5, 1].enumerated() {
            for i in 0..<n {
                source.append(vector_float2(u[i], v))
                switch row {
                case 0: destination.append(normalized(lower[i]))
                case 1: destination.append(normalized(points[i].centre))
                default: destination.append(normalized(upper[i]))
                }
            }
        }
        if sprite.texture !== Self.strip { sprite.texture = Self.strip }
        sprite.anchorPoint = .zero
        sprite.position = origin
        sprite.size = size
        sprite.warpGeometry = SKWarpGeometryGrid(columns: n - 1, rows: 2, sourcePositions: source,
                                                 destinationPositions: destination)
        sprite.alpha = CGFloat(alpha)
    }

    /// Hides every sprite.
    func clear() {
        for sprite in sprites where !sprite.isHidden { sprite.isHidden = true }
    }

    /// A sample's alpha at `age`: its loss now as a share of its kind's strongest (the class's `lossCloseIn` for a cone
    /// sample, `backwindLoss` for a backwind one), at the cone's hatch alpha, and the backwind's share of it, as
    /// `BoatEffects` draws them.
    static func alpha(of sample: TurbulenceTrails.Sample, age: Double, shadow: BoatClass.WindShadow,
                      style: BoatStyle) -> Double {
        let strongest = sample.isBackwind ? shadow.backwindLoss : shadow.lossCloseIn
        guard strongest > 0, sample.life > 0 else { return 0 }
        let share = (sample.peak / strongest) * max(0, 1 - age / sample.life)
        let base = sample.isBackwind ? style.coneAlpha * style.backwindShare : style.coneAlpha
        return min(1, base * share)
    }

    private func grow() {
        let sprite = SKSpriteNode(texture: Self.disc)
        sprite.color = CuePalette.cueWhite.uiColor
        sprite.colorBlendFactor = 1
        sprite.isHidden = true
        sprites.append(sprite)
        addChild(sprite)
    }
}
