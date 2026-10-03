import SpriteKit
import UIKit
import RegattaCore

/// How the wind shadow is drawn (#376 follow-on A): the cones and backwinds of today (`BoatEffects`), the
/// turbulence-trail ribbons (`TurbulenceRibbons`, `TurbulenceTrailLayer`), or both over each other. A Debug look
/// (the tuning panel's, and `-shadowDrawing`); Release always draws the cones.
enum ShadowDrawing: String, Codable, CaseIterable {
    case cones, trails, both

    var drawsCones: Bool { self != .trails }
    var drawsTrails: Bool { self != .cones }
}

/// What fills the turbulence ribbons (#376 follow-on A): curling wisps of domain-warped noise (`swirl`), little
/// spiral whirls carried down the wind (`eddies`), a fast heat-haze web (`shimmer`), or the first look's twinkling
/// flecks (`flecks`), for comparing. A Debug look (the tuning panel's, and `-trailLook`).
enum TrailLook: String, Codable, CaseIterable {
    case flecks, swirl, eddies, shimmer

    /// The look a tuning without one, and a launch without `-trailLook`, draws.
    static let standard = TrailLook.flecks
}

/// The turbulence ribbons drawn (#376 follow-on A): each unbroken run of a caster's points (`TurbulenceRibbons`'s
/// `ribbons(of:time:)`) is one sprite (`strip`) warped along it (`SKWarpGeometryGrid`, three rows: one edge, the
/// centreline, the other edge), so it has no seams. Its columns are the run's points plus `subColumns` between each two,
/// position, strength and scale linear between them as the model's loss interpolates them; each sits its scale either
/// side of the centre across the local track. The texture carries both falloffs: across the width white along the
/// middle, clear at the edges (as the loss falls from the centreline), and along x alpha = u, each column drawn from
/// u = its strength over the model's peak, so a column's alpha is its strength's share. An end that already tapers to
/// nothing (the oldest end fading out, a run building back in after an ease) stops there; any other end gets a round
/// feathered cap (`featherSteps`). A lone point draws as a soft disc. Different casters overlap and blend, as they stack
/// in the model. Every sprite is filled by its look's shader (`look`, `shader(for:)`): the texture's alpha is only the
/// envelope, filled with a pattern fixed in the water (`setView`; a pattern sliding with the wind reads as rain), so it reads as
/// disturbed air, not a lull. Drawn at the cone's hatch alpha (`BoatStyle.coneAlpha`) and z in the cues' white, as
/// `BoatEffects` draws the cones. The sprites are pooled: grown on demand, the unused ones hidden. Drawn only; the race
/// never reads the trails.
final class TurbulenceTrailLayer: SKNode {
    /// The soft disc a lone point draws with, made once.
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

    /// The texture a ribbon is warped from, made once: along x alpha = u (the column's strength share); across y
    /// (v) clear to white to clear, 1 − |2v − 1|, as the loss falls from the centreline.
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

    /// The fill's world frame (`setView`), one set per look's shader: a pixel's world metres are
    /// `u_origin + u_dx · x + u_dy · y` for its `gl_FragCoord` (pixels from the drawable's bottom left: SpriteKit keeps
    /// GL's y-up on Metal, `TurbulenceTrailsTests`), wrapped (`setView`); `u_mpp` metres a
    /// pixel; `u_phase` the flecks' ripples' pulse phases (radians, wrapped).
    private struct Frame {
        let origin = SKUniform(name: "u_origin", vectorFloat2: .zero)
        let dx = SKUniform(name: "u_dx", vectorFloat2: vector_float2(1, 0))
        let dy = SKUniform(name: "u_dy", vectorFloat2: vector_float2(0, 1))
        let metresPerPixel = SKUniform(name: "u_mpp", float: 1)
        let phase = SKUniform(name: "u_phase", vectorFloat2: .zero)

        var all: [SKUniform] { [origin, dx, dy, metresPerPixel, phase] }
    }

    /// The period, metres, every look repeats over in the water: 264 fleck cells of 1/2.2 m, a whole number of every
    /// ripple's and wave's wavelengths, of every noise lattice's cells (4, 2 and 1 m) and the eddies' (3 m), so the frame
    /// wraps by it with no seam. Every look's time is `u_time` wrapped at 600 s, and everything that moves with it
    /// (the noise fields' slides, the waves' and whirls' turns) comes back to where it started after 600 s, so that wrap
    /// is seamless too.
    static let period = 120.0

    /// Shared by every look: Hoskins' `hash12`; a gradient noise (quintic fade, about −0.7 … 0.7) whose lattice repeats
    /// every `period` cells (its inputs are wrapped before the hash, so no lattice shows and the 120 m wrap is seamless).
    /// Each `main` works out its pixel's world point itself: SpriteKit hands the uniforms and `gl_FragCoord` to `main`
    /// only, not to these.
    private static let prelude = """
    float trailHash(vec2 p) {
        vec3 p3 = fract(vec3(p.xyx) * 0.1031);
        p3 += dot(p3, p3.yzx + 33.33);
        return fract((p3.x + p3.y) * p3.z);
    }
    float trailGrad(vec2 cell, vec2 f, float period) {
        float h = trailHash(mod(cell, period)) * 6.2831853;
        return dot(vec2(cos(h), sin(h)), f);
    }
    float trailNoise(vec2 x, float period) {
        vec2 i = floor(x);
        vec2 f = x - i;
        vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
        float a = trailGrad(i, f, period);
        float b = trailGrad(i + vec2(1.0, 0.0), f - vec2(1.0, 0.0), period);
        float c = trailGrad(i + vec2(0.0, 1.0), f - vec2(0.0, 1.0), period);
        float d = trailGrad(i + vec2(1.0, 1.0), f - vec2(1.0, 1.0), period);
        return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
    }

    """

    /// Each look's `main`. The texture's alpha (times the node's) is the envelope; inside it a faint base and the look's
    /// pattern, in metres of the water, fixed in it (`setView`).
    private static func body(_ look: TrailLook) -> String {
        switch look {
        // Sparse flecks, each twinkling at its own rate, and broken ripples (#376 A's first look). A fleck sits jittered
        // in its cell and is round on screen: its distance is in pixels. Cell indices wrap (264) before the hash.
        case .flecks: """
            void main() {
                float envelope = texture2D(u_texture, v_tex_coord).a * v_color_mix.a;
                float t = mod(u_time, 600.0);
                vec2 m = u_origin + u_dx * gl_FragCoord.x + u_dy * gl_FragCoord.y;
                vec2 q = m * 2.2;
                vec2 cell = mod(floor(q), 264.0);
                float h = trailHash(cell);
                vec2 centre = 0.5 + 0.5 * (vec2(trailHash(cell + vec2(17.0, 3.0)), trailHash(cell + vec2(5.0, 29.0))) - 0.5);
                // It circles in place (no drift: a steady slide reads as rain), at its own rate and way round.
                float spin = (trailHash(cell + vec2(11.0, 7.0)) - 0.5) * 6.0;
                float turn = t * spin + h * 40.0;
                centre += 0.14 * vec2(cos(turn), sin(turn));
                float d = length(fract(q) - centre) / (2.2 * u_mpp);
                float twinkle = 0.5 + 0.5 * sin(t * (4.0 + 8.0 * h) + h * 40.0);
                float fleck = smoothstep(4.0, 1.0, d) * pow(twinkle, 4.0) * step(0.55, h);
                vec2 k = m * 0.0523598776;
                // Standing, not travelling: it pulses where it is.
                float wave = sin(k.x * 59.0 + k.y * 32.0) * sin(k.y * 82.0 - k.x * 21.0) * sin(u_phase.x);
                float ripple = pow(max(wave, 0.0), 6.0);
                float a = envelope * (0.22 + 1.5 * max(fleck, 0.5 * ripple));
                gl_FragColor = vec4(a, a, a, a);
            }
            """
        // Domain warping (Quilez): a two-octave warp field of 4 m and 2 m noise, its layers sliding against each other
        // (0.2 and 0.4 m/s, so 600 s is a whole number of lattice periods) so the curls turn over, bends the 2 m and
        // 1 m filament noise; its zero lines are the filaments, about 2 px wide at every zoom (the line's width in noise
        // units scales with `u_mpp`), with a soft halo in metres that fades as the features grow past ~40 px, broken into
        // wisps by the warp field itself.
        case .swirl: """
            void main() {
                float envelope = texture2D(u_texture, v_tex_coord).a * v_color_mix.a;
                float t = mod(u_time, 600.0);
                vec2 m = u_origin + u_dx * gl_FragCoord.x + u_dy * gl_FragCoord.y;
                vec2 q = vec2(trailNoise(m * 0.25 + vec2(0.05, 0.0) * t, 30.0)
                              + 0.5 * trailNoise(m * 0.5 + vec2(3.1, 0.0) - vec2(0.1, 0.0) * t, 60.0),
                              trailNoise(m * 0.25 + vec2(13.0, 7.0) - vec2(0.0, 0.05) * t, 30.0)
                              + 0.5 * trailNoise(m * 0.5 + vec2(9.7, 2.3) + vec2(0.0, 0.1) * t, 60.0));
                vec2 r = m + 3.0 * q;
                float fine = smoothstep(2.0, 4.0, 1.0 / u_mpp);
                float n = trailNoise(r * 0.5, 60.0) + 0.2 * fine * trailNoise(r + vec2(5.3, 1.1), 120.0);
                float w = clamp(1.6 * u_mpp, 0.015, 0.3);
                float line = 1.0 - smoothstep(0.0, w, abs(n));
                float big = smoothstep(40.0, 160.0, 2.0 / u_mpp);
                float glow = pow(max(0.0, 1.0 - abs(n) * 2.5), 5.0) * (1.0 - 0.7 * big);
                float wisps = smoothstep(-0.3, 0.4, q.x - 0.6 * q.y);
                float pattern = (0.8 * line + 0.35 * glow) * wisps;
                float a = envelope * min(1.0, 0.15 + 0.9 * pattern);
                gl_FragColor = vec4(a, a, a, a);
            }
            """
        // A jittered grid of 3 m cells (40 to the period), three in five holding a whirl: a two-armed logarithmic
        // spiral band (2·angle + k·log r) turning at its own rate and sense (a whole number of turns in 600 s), fading
        // to nothing at its radius (inside the neighbouring cells' reach, so the 3 × 3 sum shows no cell edge) and
        // hollow at its core where the arms would crowd under a few pixels.
        case .eddies: """
            void main() {
                float envelope = texture2D(u_texture, v_tex_coord).a * v_color_mix.a;
                float t = mod(u_time, 600.0);
                vec2 m = u_origin + u_dx * gl_FragCoord.x + u_dy * gl_FragCoord.y;
                vec2 g = m / 3.0;
                vec2 base = floor(g);
                float cellPx = 3.0 / u_mpp;
                float core = 5.0 / cellPx;
                float sum = 0.0;
                for (int j = -1; j <= 1; j++) {
                    for (int i = -1; i <= 1; i++) {
                        vec2 cell = base + vec2(float(i), float(j));
                        vec2 id = mod(cell, 40.0);
                        float h = trailHash(id);
                        float h2 = trailHash(id + vec2(17.0, 3.0));
                        float h3 = trailHash(id + vec2(5.0, 29.0));
                        vec2 centre = cell + 0.5 + 0.6 * (vec2(h2, h3) - 0.5);
                        vec2 d = g - centre;
                        float r = max(length(d), 1e-4);
                        float radius = 0.45 + 0.3 * h3;
                        float sense = h2 > 0.5 ? 1.0 : -1.0;
                        float omega = sense * 6.2831853 * floor(15.0 + 30.0 * h) / 600.0;
                        float s = sin(2.0 * (atan(d.y, d.x) - omega * t) + sense * 5.0 * log(r));
                        float band = pow(0.5 + 0.5 * s, 3.0);
                        float fade = smoothstep(radius, 0.35 * radius, r) * smoothstep(core, 3.0 * core, r);
                        sum += band * fade * (0.55 + 0.45 * h) * step(0.4, h);
                    }
                }
                float big = smoothstep(60.0, 240.0, cellPx);
                float pattern = min(sum, 1.0) * (1.0 - 0.4 * big);
                float a = envelope * min(1.0, 0.15 + 0.85 * pattern);
                gl_FragColor = vec4(a, a, a, a);
            }
            """
        // Heat haze: three crossed waves (~1.9 m, whole numbers of wavelengths in the period) on water warped by a 2 m
        // noise sliding at 1 m/s, each turning fast (a whole number of cycles in 600 s); the bright lines are where their
        // sum crosses zero, a caustic web about 2 px wide at every zoom, flickering with the first two waves' product.
        case .shimmer: """
            void main() {
                float envelope = texture2D(u_texture, v_tex_coord).a * v_color_mix.a;
                float t = mod(u_time, 600.0);
                vec2 m = u_origin + u_dx * gl_FragCoord.x + u_dy * gl_FragCoord.y;
                vec2 warp = 0.5 * vec2(trailNoise(m * 0.5 + vec2(0.5, 0.0) * t, 60.0),
                                       trailNoise(m * 0.5 + vec2(4.3, 8.1) - vec2(0.0, 0.5) * t, 60.0));
                vec2 p = (m + warp) * 0.0523598776;
                float s1 = sin(dot(p, vec2(60.0, 21.0)) + t * 2.6179939);
                float s2 = sin(dot(p, vec2(-25.0, 58.0)) - t * 3.4557519);
                float s3 = sin(dot(p, vec2(-41.0, -47.0)) + t * 4.1887902);
                float v = abs(s1 + s2 + s3);
                float w = clamp(6.0 * u_mpp, 0.05, 0.9);
                float line = 1.0 - smoothstep(0.0, w, v);
                float flicker = 0.4 + 0.6 * (0.5 + 0.5 * s1 * s2);
                float big = smoothstep(40.0, 160.0, 1.9 / u_mpp);
                float pattern = line * flicker * (1.0 - 0.4 * big);
                float a = envelope * min(1.0, 0.15 + 0.85 * pattern);
                gl_FragColor = vec4(a, a, a, a);
            }
            """
        }
    }

    private static let frames: [TrailLook: Frame] = Dictionary(uniqueKeysWithValues: TrailLook.allCases.map { ($0, Frame()) })

    /// Each look's shader, shared by every trail sprite (one shader, so the sprites batch), its own frame's uniforms.
    private static let shaders: [TrailLook: SKShader] = Dictionary(uniqueKeysWithValues: TrailLook.allCases.map { look in
        (look, SKShader(source: prelude + body(look), uniforms: frames[look]!.all))
    })

    /// The shader the sprites fill with for `look`.
    static func shader(for look: TrailLook) -> SKShader { shaders[look]! }

    /// Points every look's world frame for this frame, shared by every strip: `pixel(x, y)` is the world point
    /// (metres) the drawable's pixel (x, y) from its bottom left shows, at race time `time` (seconds). The pattern is
    /// fixed in the water: a steady slide down the wind reads as falling rain (owner, #376 A); the flecks circle in
    /// place instead. The origin is wrapped by `period` and the phases by 2π, so the floats stay small.
    static func setView(pixel: (Double, Double) -> Vec2, time: Double) {
        let o = pixel(0, 0), ex = pixel(1, 0) - o, ey = pixel(0, 1) - o
        func wrap(_ x: Double) -> Double { x - period * (x / period).rounded(.down) }
        let twoPi = 2 * Double.pi
        let origin = vector_float2(Float(wrap(o.x)), Float(wrap(o.y)))
        let dx = vector_float2(Float(ex.x), Float(ex.y)), dy = vector_float2(Float(ey.x), Float(ey.y))
        let mpp = Float(max(ex.length, 1e-6))
        let phase = vector_float2(Float((time * 2.3).truncatingRemainder(dividingBy: twoPi)),
                                  Float((time * 1.6).truncatingRemainder(dividingBy: twoPi)))
        for frame in frames.values {
            frame.origin.vectorFloat2Value = origin
            frame.dx.vectorFloat2Value = dx
            frame.dy.vectorFloat2Value = dy
            frame.metresPerPixel.floatValue = mpp
            frame.phase.vectorFloat2Value = phase
        }
    }

    /// The look the sprites fill with (`TrailLook`): swapping it swaps every sprite's shader.
    var look = TrailLook.standard {
        didSet {
            guard look != oldValue else { return }
            let shader = Self.shader(for: look)
            for sprite in sprites { sprite.shader = shader }
        }
    }

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

    /// Columns added between each two points of a run.
    static let subColumns = 3
    /// An end whose strength is under this share of the peak, or whose scale is under this share of its run's widest,
    /// already tapers to nothing: no cap.
    static let taperShare = 0.05

    /// Draws `runs` (each a caster's unbroken run of live points, oldest first), alpha = strength / `peak` × the
    /// style's cone alpha. A run of one is a disc; one with no strength or scale draws nothing.
    func update(runs: [[TurbulenceRibbons.Live]], peak: Double, style: BoatStyle) {
        var used = 0
        func next() -> SKSpriteNode {
            if used == sprites.count { grow() }
            let sprite = sprites[used]
            used += 1
            sprite.zPosition = BoatEffects.Layer.cones
            sprite.isHidden = false
            return sprite
        }
        let base = min(1, style.coneAlpha)
        for run in runs {
            if run.count >= 2 {
                guard run.contains(where: { $0.strength > 0 && $0.scale > 0 }) else { continue }
                ribbon(next(), along: run, peak: peak, alpha: base)
                continue
            }
            guard let lone = run.first, lone.strength > 0, lone.scale > 0, peak > 0 else { continue }
            let sprite = next()
            if sprite.texture !== Self.disc { sprite.texture = Self.disc }
            sprite.warpGeometry = nil
            sprite.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            let diameter = CGFloat(2 * lone.scale) * ppm
            sprite.position = CGPoint(x: lone.position.x * ppm, y: lone.position.y * ppm)
            sprite.size = CGSize(width: diameter, height: diameter)
            sprite.alpha = CGFloat(base * min(1, lone.strength / peak))
        }
        for sprite in sprites[used...] where !sprite.isHidden { sprite.isHidden = true }
    }

    /// The columns a feathered end adds past its end point, as a share of its scale out: each narrower (a quarter
    /// circle, so the end is round) and fainter, to nothing at the tip.
    static let featherSteps: [Double] = [0.35, 0.7, 1]

    /// A strip's columns: centre and half width (metres) and u (alpha share).
    struct Column {
        var centre: Vec2
        var halfWidth: Double
        var u: Double
    }

    /// The columns of `run` (oldest first, at least two): each point and `subColumns` linear ones between each two,
    /// u = strength / `peak`; a round feathered cap past each end that doesn't already taper (`taperShare`).
    static func columns(along run: [TurbulenceRibbons.Live], peak: Double) -> [Column] {
        func u(_ l: TurbulenceRibbons.Live) -> Double { peak > 0 ? min(1, max(0, l.strength / peak)) : 0 }
        var body: [Column] = []
        let steps = subColumns + 1
        for i in 0..<(run.count - 1) {
            for k in 0..<steps {
                let l = TurbulenceRibbons.lerp(run[i], run[i + 1], Double(k) / Double(steps))
                body.append(Column(centre: l.position, halfWidth: l.scale, u: u(l)))
            }
        }
        let last = run[run.count - 1]
        body.append(Column(centre: last.position, halfWidth: last.scale, u: u(last)))
        let widest = run.map(\.scale).max() ?? 0
        func tapers(_ c: Column) -> Bool { c.u < taperShare || c.halfWidth < taperShare * widest }
        func direction(_ from: Vec2, _ to: Vec2, _ fallback: Vec2) -> Vec2 {
            let d = to - from
            let length = d.length
            return length > 1e-9 ? d * (1 / length) : fallback
        }
        var columns: [Column] = []
        let first = body[0], end = body[body.count - 1]
        if !tapers(first) {
            let back = direction(body[1].centre, first.centre, Vec2(-1, 0))
            for t in featherSteps.reversed() {
                columns.append(Column(centre: first.centre + back * (first.halfWidth * t),
                                      halfWidth: first.halfWidth * (1 - t * t).squareRoot(), u: first.u * (1 - t)))
            }
        }
        columns += body
        if !tapers(end) {
            let ahead = direction(body[body.count - 2].centre, end.centre, Vec2(1, 0))
            for t in featherSteps {
                columns.append(Column(centre: end.centre + ahead * (end.halfWidth * t),
                                      halfWidth: end.halfWidth * (1 - t * t).squareRoot(), u: end.u * (1 - t)))
            }
        }
        return columns
    }

    /// The track's direction at column `i`: across the columns at least its half width either side of it (or the
    /// ends), so points bunched closer than the strip is wide (a slow boat, a tight turn) don't swing its normal about
    /// and fan its edges out into a starburst.
    static func tangent(_ columns: [Column], at i: Int) -> Vec2 {
        let c = columns[i].centre, reach = columns[i].halfWidth
        var j = max(i - 1, 0), k = min(i + 1, columns.count - 1)
        while j > 0, (columns[j].centre - c).length < reach { j -= 1 }
        while k < columns.count - 1, (columns[k].centre - c).length < reach { k += 1 }
        return columns[k].centre - columns[j].centre
    }

    /// Warps `sprite` into the strip along `run` (`columns(along:peak:)`): sized to its edges' bounding box, anchored
    /// at its bottom-left, each column's three rows at the centre − normal × half width, the centre, and the centre +
    /// normal × half width, the normal across the local track, drawn from `strip` at u = the column's alpha share.
    private func ribbon(_ sprite: SKSpriteNode, along run: [TurbulenceRibbons.Live], peak: Double, alpha: Double) {
        let columns = Self.columns(along: run, peak: peak)
        let count = columns.count
        var lower: [Vec2] = [], upper: [Vec2] = []
        lower.reserveCapacity(count); upper.reserveCapacity(count)
        var lastNormal = Vec2(0, 1)
        for i in 0..<count {
            let tangent = Self.tangent(columns, at: i)
            let length = tangent.length
            let normal = length > 1e-9 ? Vec2(-tangent.y / length, tangent.x / length) : lastNormal
            lastNormal = normal
            lower.append(columns[i].centre - normal * columns[i].halfWidth)
            upper.append(columns[i].centre + normal * columns[i].halfWidth)
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
    }

    /// Hides every sprite.
    func clear() {
        for sprite in sprites where !sprite.isHidden { sprite.isHidden = true }
    }

    private func grow() {
        let sprite = SKSpriteNode(texture: Self.disc)
        sprite.shader = Self.shader(for: look)
        sprite.color = CuePalette.cueWhite.uiColor
        sprite.colorBlendFactor = 1
        sprite.isHidden = true
        sprites.append(sprite)
        addChild(sprite)
    }
}
