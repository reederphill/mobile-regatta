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
/// falls from its centre), and along the length each sample's column sits at u = its life left (`1 − age/life`) times its
/// strength (its peak as a share of the ribbon's strongest), so it fades as the model's loss does. Both ends feather out
/// over about a radius past the end samples, narrowing (a quarter circle) and fading to nothing, so even a short
/// backwind ribbon is a soft lozenge with no straight edge; a lone sample draws as a soft disc. Different casters overlap
/// and blend, as they stack in the model. Every sprite shimmers (`shimmer`): the texture's alpha is only the envelope,
/// filled with fine flickering flecks and broken ripples drifting downwind, so it reads as disturbed air, not a lull.
/// Cone ribbons draw at the cone's hatch alpha (`BoatStyle.coneAlpha`) and z, backwind ones at the backwind's share of
/// it (`BoatStyle.backwindShare`) and z, both in the cues' white, as `BoatEffects` draws them. The sprites are pooled:
/// grown on demand, the unused ones hidden. Drawn only; the race never reads the trails.
final class TurbulenceTrailLayer: SKNode {
    /// The soft disc a lone sample draws with, made once.
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

    /// The shimmer every trail sprite draws with, shared (one shader, so the sprites batch). The texture's alpha
    /// (times the node's) is the envelope; inside it a faint base plus sparse flecks, each twinkling at its own rate,
    /// and broken ripples, all in metres of the sprite's own frame (`a_scale`: metres a unit of texture x and y) and
    /// drifting towards its dead end (low x) with time. Many fragments near the base, a few bright.
    static let shimmer: SKShader = {
        let source = """
        float trailHash(vec2 p) {
            p = fract(p * vec2(123.34, 456.21));
            p += dot(p, p + 45.32);
            return fract(p.x * p.y);
        }
        void main() {
            float envelope = texture2D(u_texture, v_tex_coord).a * v_color_mix.a;
            float t = mod(u_time, 600.0);
            vec2 m = vec2(v_tex_coord.x * a_scale.x + t * 0.8, (v_tex_coord.y - 0.5) * a_scale.y);
            vec2 q = m * 2.2;
            vec2 cell = floor(q);
            float h = trailHash(cell);
            vec2 offset = vec2(trailHash(cell + 11.3), trailHash(cell + 27.1)) - 0.5;
            float d = length(fract(q) - 0.5 - offset * 0.5);
            float twinkle = 0.5 + 0.5 * sin(t * (4.0 + 8.0 * h) + h * 40.0);
            float fleck = smoothstep(0.34, 0.04, d) * pow(twinkle, 4.0) * step(0.55, h);
            float wave = sin(m.x * 3.1 + m.y * 1.7 - t * 2.3) * sin(m.y * 4.3 - m.x * 1.1 + t * 1.6);
            float ripple = pow(max(wave, 0.0), 6.0);
            float a = envelope * (0.22 + 1.5 * max(fleck, 0.5 * ripple));
            gl_FragColor = vec4(a, a, a, a);
        }
        """
        let shader = SKShader(source: source)
        shader.attributes = [SKAttribute(name: "a_scale", type: .vectorFloat2)]
        return shader
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
    /// `style`'s alphas: a ribbon a caster and kind, or a disc for a lone sample. A sample past its life, or not yet
    /// born, draws nothing.
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
                let strongest = points.map(\.strength).max() ?? 0
                let alpha = min(1, base * strongest)
                if alpha > 0, points.contains(where: { $0.radius > 0 }) {
                    ribbon(next(z: z), along: points, strongest: strongest, alpha: alpha)
                }
                continue
            }
            guard let lone = points.first, lone.alpha > 0, lone.radius > 0 else { continue }
            let sprite = next(z: z)
            if sprite.texture !== Self.disc { sprite.texture = Self.disc }
            sprite.warpGeometry = nil
            sprite.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            let diameter = CGFloat(2 * lone.radius) * ppm
            sprite.position = CGPoint(x: lone.centre.x * ppm, y: lone.centre.y * ppm)
            sprite.size = CGSize(width: diameter, height: diameter)
            sprite.alpha = CGFloat(lone.alpha)
            let metres = Float(2 * lone.radius)
            sprite.setValue(SKAttributeValue(vectorFloat2: vector_float2(metres, metres)), forAttribute: "a_scale")
        }
        for sprite in sprites[used...] where !sprite.isHidden { sprite.isHidden = true }
    }

    /// The columns a feathered end adds past its end sample, as a share of its radius out: each narrower (a quarter
    /// circle, so the end is round) and fainter, to nothing at the tip.
    static let featherSteps: [Double] = [0.35, 0.7, 1]

    /// Warps `sprite` into the ribbon along `points` (oldest first, at least two), feathered at both ends
    /// (`featherSteps`): sized to its edges' bounding box, anchored at its bottom-left, each column drawn from `strip`
    /// at u = the sample's life left × its strength over `strongest`, its three rows at the centre − normal × radius,
    /// the centre, and the centre + normal × radius, the normal across the local track.
    private func ribbon(_ sprite: SKSpriteNode, along points: [Point], strongest: Double, alpha: Double) {
        func u(_ p: Point) -> Double { strongest > 0 ? min(1, max(0, p.left)) * p.strength / strongest : 0 }
        // The columns: (centre, half width, u, direction along the track for the normal).
        var columns: [(centre: Vec2, radius: Double, u: Double)] = []
        let n = points.count
        func direction(_ from: Vec2, _ to: Vec2) -> Vec2? {
            let d = to - from
            let length = d.length
            return length > 1e-9 ? d * (1 / length) : nil
        }
        let back = direction(points[1].centre, points[0].centre) ?? Vec2(-1, 0)
        let ahead = direction(points[n - 2].centre, points[n - 1].centre) ?? Vec2(1, 0)
        for t in Self.featherSteps.reversed() {
            let p = points[0]
            columns.append((p.centre + back * (p.radius * t), p.radius * (1 - t * t).squareRoot(), u(p) * (1 - t)))
        }
        for p in points { columns.append((p.centre, p.radius, u(p))) }
        for t in Self.featherSteps {
            let p = points[n - 1]
            columns.append((p.centre + ahead * (p.radius * t), p.radius * (1 - t * t).squareRoot(), u(p) * (1 - t)))
        }
        let count = columns.count
        var lower: [Vec2] = [], upper: [Vec2] = []
        lower.reserveCapacity(count); upper.reserveCapacity(count)
        var lastNormal = Vec2(0, 1)
        for i in 0..<count {
            let tangent = columns[min(i + 1, count - 1)].centre - columns[max(i - 1, 0)].centre
            let length = tangent.length
            let normal = length > 1e-9 ? Vec2(-tangent.y / length, tangent.x / length) : lastNormal
            lastNormal = normal
            lower.append(columns[i].centre - normal * columns[i].radius)
            upper.append(columns[i].centre + normal * columns[i].radius)
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
        var source: [vector_float2] = [], destination: [vector_float2] = []
        source.reserveCapacity(3 * count); destination.reserveCapacity(3 * count)
        for (row, v) in [Float(0), 0.5, 1].enumerated() {
            for i in 0..<count {
                source.append(vector_float2(Float(columns[i].u), v))
                switch row {
                case 0: destination.append(normalized(lower[i]))
                case 1: destination.append(normalized(columns[i].centre))
                default: destination.append(normalized(upper[i]))
                }
            }
        }
        if sprite.texture !== Self.strip { sprite.texture = Self.strip }
        sprite.anchorPoint = .zero
        sprite.position = origin
        sprite.size = size
        sprite.warpGeometry = SKWarpGeometryGrid(columns: count - 1, rows: 2, sourcePositions: source,
                                                 destinationPositions: destination)
        sprite.alpha = CGFloat(alpha)
        // The shimmer's frame: metres a unit of life left along the track, and the ribbon's mean width.
        var arc = 0.0
        for i in 1..<n { arc += (points[i].centre - points[i - 1].centre).length }
        let span = max(points[n - 1].left - points[0].left, 0.05)
        let width = 2 * points.map(\.radius).reduce(0, +) / Double(n)
        sprite.setValue(SKAttributeValue(vectorFloat2: vector_float2(Float(arc / span), Float(width))),
                        forAttribute: "a_scale")
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
        sprite.shader = Self.shimmer
        sprite.color = CuePalette.cueWhite.uiColor
        sprite.colorBlendFactor = 1
        sprite.isHidden = true
        sprites.append(sprite)
        addChild(sprite)
    }
}
