import SpriteKit
import UIKit
import RegattaCore

/// The wind shadow drawn (#376 follow-on A, #377): the sim's turbulence ribbons (`Race.wake`, carried on each
/// `TickFrame`). Each unbroken run of a caster's points (`TurbulenceRibbons`'s `ribbons(of:time:)`) is one sprite
/// (`strip`) warped along it (`SKWarpGeometryGrid`, three rows: one edge, the centreline, the other edge), so it has no
/// seams. Its columns are the run's points plus `subColumns` between each two,
/// position, strength and scale linear between them as the model's loss interpolates them; each sits its scale either
/// side of the centre across the local track. The texture carries both falloffs: across the width white along the
/// middle, clear at the edges (as the loss falls from the centreline), and along x alpha = u, each column drawn from
/// u = its strength over the model's peak, so a column's alpha is its strength's share. An end that already tapers to
/// nothing (the oldest end fading out, a run building back in after an ease) stops there; any other end gets a round
/// feathered cap (`featherSteps`). A lone point draws as a soft disc. Different casters overlap and blend, as they stack
/// in the model. Every sprite shimmers (`shimmer`): the texture's alpha is only the envelope, filled with sparse
/// twinkling flecks and broken ripples fixed in the water (`setView`), so it reads as
/// disturbed air, not a lull. Drawn at the shadow's hatch alpha (`BoatStyle.coneAlpha`) and z
/// (`BoatEffects.Layer.ribbons`, under every boat's effects, a slot each) in the cues' white. The sprites are pooled: grown on demand, the unused ones hidden. Drawn only: the race
/// sails its own ribbons, which these draw.
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

    /// The shimmer's world frame (`setView`): a pixel's world metres are `u_origin + u_dx · x + u_dy · y` for its
    /// `gl_FragCoord` (pixels from the drawable's top left: Metal's, `TurbulenceTrailsTests`), wrapped (`setView`).
    private static let origin = SKUniform(name: "u_origin", vectorFloat2: .zero)
    private static let dx = SKUniform(name: "u_dx", vectorFloat2: vector_float2(1, 0))
    private static let dy = SKUniform(name: "u_dy", vectorFloat2: vector_float2(0, 1))
    /// Metres a pixel, and the ripples' pulse phase (radians, wrapped).
    private static let metresPerPixel = SKUniform(name: "u_mpp", float: 1)
    private static let phase = SKUniform(name: "u_phase", vectorFloat2: .zero)
    /// The flecks' twinkle clock: race seconds, wrapped at 600 (`setView`), never SpriteKit's `u_time`, so a frozen
    /// render fixture draws the same shimmer in every frame and a paused race holds still.
    private static let clock = SKUniform(name: "u_clock", float: 0)
    /// Every frame uniform (`setView`), for another shader in the same frame (the tests').
    static var frameUniforms: [SKUniform] { [origin, dx, dy, metresPerPixel, phase, clock] }

    /// The period, metres, the shimmer repeats over in the water: 264 fleck cells of 1/2.2 m, and a whole number of
    /// every ripple's wavelengths, so the frame wraps by it with no seam.
    static let period = 120.0

    /// The shimmer every trail sprite draws with, shared (one shader, so the sprites batch). The texture's alpha
    /// (times the node's) is the envelope; inside it a faint base plus sparse flecks, each twinkling at its own rate,
    /// and broken ripples, all in metres of the water (`setView`) and fixed in it: a pattern sliding down the wind reads
    /// as falling rain (owner, #376 A), so each fleck circles in place at its own rate and way round, and the ripples
    /// pulse where they are. Many fragments near the base, a few bright. A fleck sits jittered in its cell and is round
    /// on screen: its distance is in pixels
    /// (the frame is conformal, `u_mpp` metres a pixel). Each caster's sprites carry their own seed (`seed`): it
    /// shifts her fleck lattice, their hashes and her ripples' phase, so where boats' ribbons overlap their flecks are
    /// independent, not one pattern twinkling in step (owner, #376 A). Cell indices wrap (264) before an arithmetic hash
    /// (Hoskins' `hash12`), so no lattice shows far from the origin; the twinkle's time is race time (`u_clock`), wrapped
    /// at 600 s.
    static let shimmer: SKShader = {
        let source = """
        float trailHash(vec2 p) {
            vec3 p3 = fract(vec3(p.xyx) * 0.1031);
            p3 += dot(p3, p3.yzx + 33.33);
            return fract((p3.x + p3.y) * p3.z);
        }
        void main() {
            // The sprite's colour carries its alpha (red) and its caster's seed (green × 255, over the inherited
            // alpha): see `paint`.
            float envelope = texture2D(u_texture, v_tex_coord).a * v_color_mix.r;
            float seed = floor(v_color_mix.g / max(v_color_mix.a, 0.001) * 255.0 + 0.5);
            float t = u_clock;
            vec2 m = u_origin + u_dx * gl_FragCoord.x + u_dy * gl_FragCoord.y;
            vec2 q = m * 2.2 + fract(seed * vec2(0.618034, 0.754878));
            vec2 cell = mod(floor(q), 264.0) + seed * vec2(113.0, 71.0);
            float h = trailHash(cell);
            vec2 centre = 0.5 + 0.5 * (vec2(trailHash(cell + vec2(17.0, 3.0)), trailHash(cell + vec2(5.0, 29.0))) - 0.5);
            float turn = t * (trailHash(cell + vec2(11.0, 7.0)) - 0.5) * 6.0 + h * 40.0;
            centre += 0.14 * vec2(cos(turn), sin(turn));
            float d = length(fract(q) - centre) / (2.2 * u_mpp);
            float twinkle = 0.5 + 0.5 * sin(t * (4.0 + 8.0 * h) + h * 40.0);
            float fleck = smoothstep(4.0, 1.0, d) * pow(twinkle, 4.0) * step(0.55, h);
            vec2 k = m * 0.0523598776;
            float wave = sin(k.x * 59.0 + k.y * 32.0 + seed * 2.4) * sin(k.y * 82.0 - k.x * 21.0 + seed * 1.3)
                * sin(u_phase.x + seed * 0.9);
            float ripple = pow(max(wave, 0.0), 6.0);
            float a = envelope * (0.22 + 1.5 * max(fleck, 0.5 * ripple));
            gl_FragColor = vec4(a, a, a, a);
        }
        """
        return SKShader(source: source, uniforms: frameUniforms)
    }()

    /// Seeds wrap at this: the colour's 8 bits.
    static let seeds = 256

    /// Sets a sprite's alpha and its caster's fleck seed, both on its colour (the node's own alpha stays 1): red is the
    /// alpha, green the seed / 255. Not a shader attribute: the app crashed in a race in SpriteKit's batching, copying
    /// the warped strips' per-sprite attribute (#377's first CI run, `fleetRibbonsRenderThroughMetal`). Nor a uniform:
    /// a shader per caster draws a pass each (#354).
    static func paint(_ sprite: SKSpriteNode, alpha: Double, seed: Int) {
        let green = CGFloat(((seed % seeds) + seeds) % seeds) / 255
        sprite.color = UIColor(red: CGFloat(min(1, max(0, alpha))), green: green, blue: 0, alpha: 1)
    }

    /// A sprite's alpha and seed (`paint`).
    static func paint(of sprite: SKSpriteNode) -> (alpha: Double, seed: Int) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        sprite.color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (Double(red), Int((green * 255).rounded()))
    }

    /// The world point (metres: `layer`'s points × `metresPerPoint`) a drawable pixel (x, y) from its top left
    /// shows, through `camera`: the drawable is `viewSize` points × `pixelScale`, the scene (`sceneSize`) fitted
    /// in it (aspect-fit, centred) with the camera at its centre. Only the camera's and the nodes' transforms, read
    /// when called, so it holds the frame they are set for.
    static func pixelFrame(viewSize: CGSize, pixelScale: CGFloat, sceneSize: CGSize, camera: SKNode, layer: SKNode,
                           metresPerPoint: Double) -> (Double, Double) -> Vec2 {
        let fit = min(viewSize.width / sceneSize.width, viewSize.height / sceneSize.height)
        let perPixel = 1 / (Double(pixelScale) * Double(fit))
        let halfWidth = Double(viewSize.width * pixelScale) / 2, halfHeight = Double(viewSize.height * pixelScale) / 2
        // The camera's own points to the layer's: affine, so three points give it.
        let o = layer.convert(CGPoint.zero, from: camera)
        let ex = layer.convert(CGPoint(x: 1, y: 0), from: camera), ey = layer.convert(CGPoint(x: 0, y: 1), from: camera)
        let ax = Vec2(Double(ex.x - o.x), Double(ex.y - o.y)), ay = Vec2(Double(ey.x - o.x), Double(ey.y - o.y))
        let origin = Vec2(Double(o.x), Double(o.y))
        return { x, y in
            // Camera points: x right, y up from the centre.
            let cx = (x - halfWidth) * perPixel, cy = (halfHeight - y) * perPixel
            return (origin + ax * cx + ay * cy) * metresPerPoint
        }
    }

    /// Points the shimmer's world frame for this frame, shared by every strip: `pixel(x, y)` is the world point
    /// (metres) the drawable's pixel (x, y) from its top left shows (`pixelFrame`), at race time `time` (seconds).
    /// Everything is wrapped by `period`, so the floats stay small.
    static func setView(pixel: (Double, Double) -> Vec2, time: Double) {
        let o = pixel(0, 0), ex = pixel(1, 0) - o, ey = pixel(0, 1) - o
        func wrap(_ x: Double) -> Double { x - period * (x / period).rounded(.down) }
        origin.vectorFloat2Value = vector_float2(Float(wrap(o.x)), Float(wrap(o.y)))
        dx.vectorFloat2Value = vector_float2(Float(ex.x), Float(ex.y))
        dy.vectorFloat2Value = vector_float2(Float(ey.x), Float(ey.y))
        metresPerPixel.floatValue = Float(max(ex.length, 1e-6))
        let twoPi = 2 * Double.pi
        clock.floatValue = Float(time - 600 * (time / 600).rounded(.down))
        phase.vectorFloat2Value = vector_float2(Float((time * 2.3).truncatingRemainder(dividingBy: twoPi)),
                                                Float((time * 1.6).truncatingRemainder(dividingBy: twoPi)))
    }

    private let ppm: CGFloat
    /// Two pools, each sprite on one texture for good (`strip` or `disc`), so a frame never swaps a texture; they
    /// grow, never shrink (unused ones hide), and `reserve` sizes them for the fleet up front, so the layer's nodes
    /// stay the same from the first frame (`WakeTests`).
    private var strips: [SKSpriteNode] = [], discs: [SKSpriteNode] = []
    /// Every sprite: the strips, then the discs.
    var sprites: [SKSpriteNode] { strips + discs }

    /// The sprites drawing now.
    var visibleCount: Int { (strips + discs).filter { !$0.isHidden }.count }

    /// Sprites for a fleet of `boats`: a few strips and discs a boat (a run breaks where her sail stops working or she
    /// stops, so a tack, an ease or a luff before the gun starts another while the last lives; 16 boats before the
    /// gun drew up to 43 discs at once, `WakeTests`). More grow if a race ever needs them.
    static func reserve(boats: Int) -> (strips: Int, discs: Int) { (4 * boats, 4 * boats) }

    /// Grows the pools to at least `strips` and `discs` sprites, hidden.
    func reserve(strips: Int, discs: Int) {
        while self.strips.count < strips { self.strips.append(grow(texture: Self.strip)) }
        while self.discs.count < discs { self.discs.append(grow(texture: Self.disc)) }
    }

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

    /// Draws every caster's ribbons in `wake` at race time `time` (seconds, between ticks: `ribbons(of:time:)`), each
    /// run seeded by its caster. Nil draws none.
    func update(wake: TurbulenceRibbons?, time: Double, style: BoatStyle) {
        guard let wake else { return clear() }
        var runs: [[TurbulenceRibbons.Live]] = [], casters: [Int] = []
        for seat in wake.points.indices {
            let own = wake.ribbons(of: seat, time: time)
            runs += own
            casters += Array(repeating: seat, count: own.count)
        }
        update(runs: runs, casters: casters, peak: wake.peak, style: style)
    }

    /// Draws `runs` (each a caster's unbroken run of live points, oldest first), alpha = strength / `peak` × the
    /// style's cone alpha. A run of one is a disc; one with no strength or scale draws nothing. `casters` (one per
    /// run; nil = all 0) seeds each run's flecks, so different boats' flecks don't move in step where they overlap.
    func update(runs: [[TurbulenceRibbons.Live]], casters: [Int]? = nil, peak: Double, style: BoatStyle) {
        var usedStrips = 0, usedDiscs = 0
        func next(disc: Bool) -> SKSpriteNode {
            reserve(strips: usedStrips + (disc ? 0 : 1), discs: usedDiscs + (disc ? 1 : 0))
            let sprite = disc ? discs[usedDiscs] : strips[usedStrips]
            if disc { usedDiscs += 1 } else { usedStrips += 1 }
            sprite.isHidden = false
            return sprite
        }
        let base = min(1, style.coneAlpha)
        for (index, run) in runs.enumerated() {
            let seed = casters.map { index < $0.count ? $0[index] : 0 } ?? 0
            if run.count >= 2 {
                guard run.contains(where: { $0.strength > 0 && $0.scale > 0 }) else { continue }
                let sprite = next(disc: false)
                ribbon(sprite, along: run, peak: peak)
                Self.paint(sprite, alpha: base, seed: seed)
                continue
            }
            guard let lone = run.first, lone.strength > 0, lone.scale > 0, peak > 0 else { continue }
            let sprite = next(disc: true)
            let diameter = CGFloat(2 * lone.scale) * ppm
            sprite.position = CGPoint(x: lone.position.x * ppm, y: lone.position.y * ppm)
            sprite.size = CGSize(width: diameter, height: diameter)
            Self.paint(sprite, alpha: base * min(1, lone.strength / peak), seed: seed)
        }
        for sprite in strips[usedStrips...] where !sprite.isHidden { sprite.isHidden = true }
        for sprite in discs[usedDiscs...] where !sprite.isHidden { sprite.isHidden = true }
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
    private func ribbon(_ sprite: SKSpriteNode, along run: [TurbulenceRibbons.Live], peak: Double) {
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
        sprite.anchorPoint = .zero
        sprite.position = origin
        sprite.size = size
        sprite.warpGeometry = SKWarpGeometryGrid(columns: count - 1, rows: 2, sourcePositions: source,
                                                 destinationPositions: destination)
    }

    /// Hides every sprite.
    func clear() {
        for sprite in strips + discs where !sprite.isHidden { sprite.isHidden = true }
    }

    private func grow(texture: SKTexture) -> SKSpriteNode {
        let sprite = SKSpriteNode(texture: texture)
        if texture === Self.disc { sprite.anchorPoint = CGPoint(x: 0.5, y: 0.5) }
        sprite.shader = Self.shimmer
        Self.paint(sprite, alpha: 0, seed: 0)
        sprite.colorBlendFactor = 1
        sprite.isHidden = true
        // Each sprite its own z, in pool order, all under every boat's effects (`BoatEffects.Layer`): overlapping
        // ribbons blend in the same order every launch (#62, `DrawOrderTests`).
        sprite.zPosition = BoatEffects.Layer.ribbons + DrawOrder.z(strips.count + discs.count)
        addChild(sprite)
        return sprite
    }
}
