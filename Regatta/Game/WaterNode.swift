import RegattaCore
import SpriteKit
import UIKit

/// What the water is drawn from, one frame (#116). `RenderWorld` gives it; tests build their own.
struct WaterWorld {
    /// The ground wind at a point on the water (metres), puffs and their fans included; nil where the race
    /// doesn't hold the key yet (online).
    var wind: (Vec2) -> GroundWind?
    /// The fleet-wide wind: the mean direction turned by the shift, at the course average speed.
    var courseWind: GroundWind?
    /// The puffs and lulls alive, fading in from their keys (`WindField.activePuffs`).
    var puffs: [Puff]
    var conditions: Conditions
    /// Race clock, seconds.
    var time: Double
    /// The tick's wind, for the pressure (#289): `WindSampler.pressureFactor(at:)`, and the pressure field's
    /// state for the tuning overlay. Nil where the race doesn't hold the key yet, or in a test drawing none.
    var sampler: WindSampler? = nil
}

extension WaterWorld {
    /// The ripple samples the wind at every tile, every frame: through one sampler for the frame's tick, which
    /// places the live puffs once, rather than `world.groundWind(at:)`, which places them again at every tile.
    /// The same wind, bit for bit; in a Debug build the per-tile sampling was over half the frame (#232).
    init(_ world: RenderWorld) {
        let sampler = world.windSampler
        self.init(wind: { sampler?.sample($0) }, courseWind: world.courseWind, puffs: world.puffs,
                  conditions: world.conditions, time: world.time, sampler: sampler)
    }
}

/// The #604 probe's water looks (Debug `-water none|a|b|c`): none is today's water; A light on the water (glitter
/// on the ripple, a depth gradient under the shallows); B cat's paws (the ripple follows the wind it lies in);
/// C swell (long low crests rolling downwind under the ripple, foam along them). PROBE: never merged.
nonisolated enum WaterLook: String {
    case none, a, b, c
    static let current: WaterLook = {
        #if DEBUG
        // `LaunchOptions` validates `-water`; read here off the arguments, as the look is wanted off the main actor.
        let arguments = ProcessInfo.processInfo.arguments
        guard let k = arguments.firstIndex(of: "-water"), k + 1 < arguments.count else { return .none }
        return WaterLook(rawValue: arguments[k + 1]) ?? .none
        #else
        return .none
        #endif
    }()
}

/// What the camera shows, in world points.
struct WaterView: Equatable {
    /// The camera's position.
    var center: CGPoint
    /// The scene's size: the visible world area at camera scale 1 (`RaceViewportPolicy`), so the view's edges
    /// are the visible world area's, not the screen's beyond any letterbox.
    var sceneSize: CGSize
    /// The camera's scale: world points per scene point.
    var scale: CGFloat
    /// The camera's rotation (`SKCameraNode.zRotation`, #113): course-up and boat-up turn the view.
    var rotation: CGFloat = 0

    /// The world points the view covers, upright: the bounding box of the turned view rectangle.
    var rect: CGRect {
        let c = abs(cos(rotation)), s = abs(sin(rotation))
        let width = sceneSize.width * scale, height = sceneSize.height * scale
        let size = CGSize(width: width * c + height * s, height: width * s + height * c)
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    /// The camera scale the water spreads its ripple lattice and pressure grid by: `scale`, grown by how much more
    /// area `rect` covers than the upright view, so a turned view (up to 2.3 times the area at 45°) takes no more
    /// tiles or samples than an upright one would at that area. Exactly `scale` upright.
    var spreadScale: Double {
        guard rotation != 0, sceneSize.width > 0, sceneSize.height > 0, scale > 0 else { return Double(scale) }
        let box = rect.size
        let upright = Double(sceneSize.width * scale) * Double(sceneSize.height * scale)
        return Double(scale) * (Double(box.width) * Double(box.height) / upright).squareRoot()
    }
}

/// The water (#116, #22, #289): the pressure as one continuous tone, darker where there is more; over it, puffs
/// darker and lulls lighter than the course average, with a catspaw texture on puffs; a faint ripple of streaks, each lying along the wind where it is (puff fans and the fleet-wide shift
/// included) and all drifting downwind at a speed set by the conditions' mean wind; whitecaps as many as that
/// mean wind makes, wherever they are. Everything it draws is set by `style` (#232 tunes it) and `quality` (#127 lowers it).
final class WaterNode: SKNode {
    /// A ripple streak as last drawn: where it is (metres) and the wind direction it lies along.
    struct Streak: Equatable {
        var position: Vec2
        var windDirection: Double
    }

    var style: WaterStyle {
        didSet {
            if style.catspaw != oldValue.catspaw { puffTexture = Self.puffTexture(for: style) }
            applyDepth()
        }
    }
    var quality = WaterQuality.full {
        didSet { applyDepth() }
    }
    /// How far the ripple has drifted downwind, world points.
    private(set) var drift = CGPoint.zero
    /// The streaks drawn last frame, in draw order.
    private(set) var streaks: [Streak] = []
    /// The tiles carrying a breaking whitecap last frame.
    private(set) var whitecaps: [RippleLattice.Index] = []
    /// The pressure tone drawn last frame and the grid it was sampled on; nil with no wind to sample.
    private(set) var pressure: (grid: PressureGrid, tone: PressureTone)?
    /// The tuning panel's pressure overlay (#289, Debug builds): the tone drawn `PressureOverlay.boost` times as
    /// strong, the pressure lanes' centrelines dotted and the pressure side labelled.
    var showsPressureOverlay = false
    /// Hides the ripple and whitecaps, what the thermal tiers change, for `-cuesOnly`'s UI test (#127, #597).
    /// The pressure and puffs still draw.
    var hidesRipple: Bool {
        get { rippleLayer.isHidden }
        set { rippleLayer.isHidden = newValue }
    }

    /// The pressure tone's sprite's name: the one sprite whose texture is made each frame.
    static let pressureName = "pressure"

    private let pointsPerMeter: Double
    private let puffLayer = SKNode()
    private let pressureSprite = SKSpriteNode()
    private let overlayLines = SKShapeNode()
    private let overlaySide = SKLabelNode()
    private let rippleLayer = SKNode()
    private var puffTexture: SKTexture
    private let lullTexture = WaterNode.sharedLullTexture
    private let streakTextures = WaterNode.sharedStreakTextures
    private let whitecapTexture = WaterNode.sharedWhitecapTexture
    private var puffNodes: [SKSpriteNode] = []
    /// Look C: the swell, one sprite under the puffs, its crests drawn in world coordinates by its shader.
    private let swellSprite = SKSpriteNode()
    /// Look B: each lattice tile's streak scroll, tile heights, so a streak in a puff runs ahead of the lattice.
    private var scrolls: [RippleLattice.Index: Double] = [:]
    private var tileNodes: [Tile] = []

    /// The size a streak tile's texture is drawn for: `style.rippleSpacing` scales it from here.
    private static let tileSize = 96.0

    init(pointsPerMeter: Double, style: WaterStyle = .standard) {
        self.pointsPerMeter = pointsPerMeter
        self.style = style
        puffTexture = Self.puffTexture(for: style)
        super.init()
        applyDepth()
        // The pressure under the puffs; the tuning overlay's marks over everything the water draws.
        pressureSprite.zPosition = -1
        pressureSprite.name = Self.pressureName
        pressureSprite.isHidden = true
        puffLayer.zPosition = 0
        // Named, so a test can tell what the thermal tiers change (the ripple) from the cues (the puffs, #127).
        puffLayer.name = "puffs"
        rippleLayer.name = "ripple"
        rippleLayer.zPosition = 1
        // Clear of the ripple's slots (`DrawOrder`: its tiles and caps reach past 2) and under the next layer's.
        overlayLines.zPosition = 5
        overlayLines.strokeColor = .clear
        overlayLines.fillColor = CuePalette.orange.uiColor
        overlayLines.isHidden = true
        overlaySide.zPosition = 6
        overlaySide.fontName = "Menlo-Bold"
        overlaySide.fontColor = CuePalette.orange.uiColor
        overlaySide.verticalAlignmentMode = .center
        overlaySide.isHidden = true
        addChild(pressureSprite)
        if WaterLook.current == .c {
            swellSprite.zPosition = -0.5
            swellSprite.shader = Self.swellShader
            swellSprite.color = .white
            addChild(swellSprite)
        }
        addChild(puffLayer)
        addChild(rippleLayer)
        addChild(overlayLines)
        addChild(overlaySide)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Draws `world` as seen through `view`, `dt` simulated seconds after the last frame (0 when settled).
    func update(_ world: WaterWorld, view: WaterView, dt: Double) {
        setClock(world.time)
        updatePressure(world, view: view)
        updateRipple(world, view: view, dt: dt)
        updatePuffs(world.puffs)
        updateSwell(world, view: view)
        updateOverlay(world, view: view)
    }

    // MARK: - Pressure (#289)

    /// Samples the pressure on the grid covering the view and stretches it across the grid as one texture, a
    /// pixel a sample, smoothly interpolated. A new texture only when the tone changed.
    private func updatePressure(_ world: WaterWorld, view: WaterView) {
        guard let sampler = world.sampler else {
            pressure = nil
            pressureSprite.isHidden = true
            return
        }
        let grid = PressureGrid.forView(view)
        var pressures: [Double] = []
        pressures.reserveCapacity(grid.columns.count * grid.rows.count)
        for j in grid.rows {
            for i in grid.columns {
                let point = grid.position(i, j)
                pressures.append(sampler.pressureFactor(at: Vec2(Double(point.x), Double(point.y)) / pointsPerMeter) - 1)
            }
        }
        let tone = PressureTone(columns: grid.columns.count, rows: grid.rows.count, pressures: pressures,
                                boost: showsPressureOverlay ? PressureOverlay.boost : 1)
        if tone != pressure?.tone || pressureSprite.texture == nil || style != drawnStyle {
            pressureSprite.texture = tone.image(style: style).map { image in
                let texture = SKTexture(cgImage: image)
                texture.filteringMode = .linear
                return texture
            }
            drawnStyle = style
        }
        pressure = (grid, tone)
        let rect = grid.rect
        pressureSprite.isHidden = pressureSprite.texture == nil
        pressureSprite.size = rect.size
        pressureSprite.position = CGPoint(x: rect.midX, y: rect.midY)
    }

    /// The style the pressure's texture was made with.
    private var drawnStyle: WaterStyle?

    /// The tuning overlay's marks: each pressure lane's centreline, dotted where the field's across-the-wind
    /// coordinate crosses it (for a finite lane, along its length), and the pressure side labelled towards it from
    /// the view's middle.
    private func updateOverlay(_ world: WaterWorld, view: WaterView) {
        guard showsPressureOverlay, let sampler = world.sampler, let reading = sampler.pressureReading else {
            overlayLines.isHidden = true
            overlaySide.isHidden = true
            return
        }
        let rect = view.rect
        let step = Double(rect.width) / 60
        let path = CGMutablePath()
        for y in stride(from: Double(rect.minY), through: Double(rect.maxY), by: step) {
            for x in stride(from: Double(rect.minX), through: Double(rect.maxX), by: step) {
                let point = Vec2(x, y) / pointsPerMeter
                guard let r = sampler.pressureCoordinate(at: point) else { continue }
                let along = sampler.pressureAlong(at: point) ?? 0
                let onLane = reading.lanes.contains { lane in
                    guard abs(r - lane.centre) * pointsPerMeter < step / 2 else { return false }
                    return lane.halfLength.map { abs(along - lane.alongCentre) < $0 } ?? true
                }
                if onLane {
                    path.addEllipse(in: CGRect(x: x - step / 4, y: y - step / 4, width: step / 2, height: step / 2))
                }
            }
        }
        overlayLines.path = path
        overlayLines.isHidden = false

        guard reading.side != 0, let course = world.courseWind else {
            overlaySide.isHidden = true
            return
        }
        // Positive coordinates lie right of the centre line looking downwind.
        let right = (-Vec2.heading(course.direction)).rightPerp * (reading.side > 0 ? 1 : -1)
        let reach = 0.3 * Double(min(rect.width, rect.height))
        overlaySide.text = String(format: "PRESSURE SIDE %+.0f%%", abs(reading.side) * 100)
        overlaySide.fontSize = CGFloat(Double(rect.width) / 22)
        overlaySide.position = CGPoint(x: Double(rect.midX) + right.x * reach, y: Double(rect.midY) + right.y * reach)
        overlaySide.isHidden = false
    }

    // MARK: - Ripple and whitecaps

    private func updateRipple(_ world: WaterWorld, view: WaterView, dt: Double) {
        let course = world.courseWind
        if quality == .full, let course, dt > 0 {
            let speed = style.rippleDrift * Whitecaps.meanWind(of: world.conditions) * pointsPerMeter * dt
            let downwind = -Vec2.heading(course.direction) * speed
            drift = CGPoint(x: drift.x + downwind.x, y: drift.y + downwind.y)
        }

        let (lattice, tileScale) = RippleLattice.forView(style: style, cameraScale: view.spreadScale)
        let (columns, rows) = lattice.indices(covering: view.rect, drift: drift)
        let count = columns.count * rows.count
        while tileNodes.count < count { tileNodes.append(makeTile()) }

        let share = Whitecaps.share(in: world.conditions, style: style, quality: quality)
        let period = max(style.whitecapSeconds, 0.1)
        let scale = CGFloat(tileScale * style.rippleSpacing / Self.tileSize)
        let look = WaterLook.current
        var nextScrolls: [RippleLattice.Index: Double] = [:]
        if look == .b { nextScrolls.reserveCapacity(scrolls.count) }
        streaks.removeAll(keepingCapacity: true)
        whitecaps.removeAll(keepingCapacity: true)
        var n = 0
        for j in rows {
            for i in columns {
                let index = RippleLattice.Index(i: i, j: j)
                let tile = tileNodes[n]
                n += 1
                let position = lattice.position(of: index, drift: drift)
                let metres = Vec2(Double(position.x), Double(position.y)) / pointsPerMeter
                // The full tier samples the wind at every tile: puffs fan it and the venue bends it. The cheap
                // tier lays every streak on the course wind.
                let wind = quality == .full ? (world.wind(metres) ?? course) : course
                tile.streak.isHidden = false
                tile.streak.position = position
                tile.streak.setScale(scale)
                tile.streak.alpha = CGFloat(style.rippleAlpha)
                let variant = Int(WaterHash.unit(i, j, 0, salt: 0x5354_5245) * Double(streakTextures.count))
                let texture = streakTextures[min(variant, streakTextures.count - 1)]
                if tile.streak.texture !== texture { tile.streak.texture = texture }
                if let wind {
                    // The texture's streaks point up; turned to point downwind.
                    tile.streak.zRotation = CGFloat(-(wind.direction + .pi))
                    streaks.append(Streak(position: metres, windDirection: wind.direction))
                }
                var tileShare = share
                switch look {
                case .a:
                    // The light's bearing in the tile's texture: fixed on the water, turned into the tile's frame.
                    let r = -Double(tile.streak.zRotation) + Self.lightBearing
                    tile.streak.setValue(SKAttributeValue(vectorFloat2: SIMD2(Float(cos(r)), Float(sin(r)))), forAttribute: "a_light")
                    tile.streak.setValue(SKAttributeValue(float: Float(WaterHash.unit(i, j, 1, salt: 0x474C_4954) * 97)), forAttribute: "a_seed")
                case .b:
                    let gust = Self.gust(local: wind, course: course)
                    let lull = max(-gust, 0), puff = max(gust, 0)
                    // Sparse in lulls: tiles drop out as the lull deepens.
                    if WaterHash.unit(i, j, 2, salt: 0x5350_4152) < 0.75 * lull { tile.streak.isHidden = true }
                    tile.streak.yScale = scale * CGFloat(1 + 0.6 * puff)
                    // The streaks run with the wind they lie in: faster than the lattice in a puff, slower in a lull.
                    var scroll = scrolls[index] ?? WaterHash.unit(i, j, 3, salt: 0x5343_524C)
                    if let wind, dt > 0 {
                        let extra = 2 * style.rippleDrift * (wind.speed - Whitecaps.meanWind(of: world.conditions))
                            * pointsPerMeter * dt
                        scroll += extra / (Self.tileSize * Double(scale) * (1 + 0.6 * puff))
                    }
                    scroll -= scroll.rounded(.down)
                    nextScrolls[index] = scroll
                    tile.streak.setValue(SKAttributeValue(float: Float(gust)), forAttribute: "a_gust")
                    tile.streak.setValue(SKAttributeValue(float: Float(scroll)), forAttribute: "a_scroll")
                    // Whitecaps bias toward the puffs and leave the lulls.
                    tileShare = min(share * (1 + 2.5 * gust), 0.9)
                    if share == 0, puff > 0.6 { tileShare = 0.15 * (puff - 0.6) / 0.4 }
                case .none, .c:
                    break
                }
                updateWhitecap(tile, at: index, share: max(tileShare, 0), time: world.time, period: period)
            }
        }
        if look == .b { scrolls = nextScrolls }
        for tile in tileNodes[n...] where !tile.streak.isHidden {
            tile.streak.isHidden = true
            tile.cap.isHidden = true
        }
    }

    /// A tile's whitecap breaks at a moment of each cycle of its own, fades over the cycle, and breaks again
    /// somewhere else in the tile, if the tile draws one that cycle. It lies across the tile's streaks.
    private func updateWhitecap(_ tile: Tile, at index: RippleLattice.Index, share: Double, time: Double,
                                period: Double) {
        let phase = time / period + WaterHash.unit(index.i, index.j, 0, salt: 0x5048_4153)
        let cycle = Int(phase.rounded(.down))
        guard share > 0, Whitecaps.breaks(at: index, cycle: cycle, share: share) else {
            tile.cap.isHidden = true
            return
        }
        let age = phase - Double(cycle)
        let half = Self.tileSize / 2
        let offset = CGPoint(x: (WaterHash.unit(index.i, index.j, cycle, salt: 0x4341_5058) - 0.5) * half,
                             y: (WaterHash.unit(index.i, index.j, cycle, salt: 0x4341_5059) - 0.5) * half)
        let streak = tile.streak
        let turned = offset.applying(CGAffineTransform(rotationAngle: streak.zRotation).scaledBy(x: streak.xScale, y: streak.yScale))
        tile.cap.isHidden = false
        tile.cap.alpha = CGFloat(style.whitecapAlpha * (1 - age))
        tile.cap.position = CGPoint(x: streak.position.x + turned.x, y: streak.position.y + turned.y)
        tile.cap.zRotation = streak.zRotation
        tile.cap.setScale(streak.xScale)
        whitecaps.append(index)
    }

    /// A ripple tile: its streaks, and the whitecap it may carry, drawn over the streaks at full alpha.
    private struct Tile {
        let streak: SKSpriteNode
        let cap: SKSpriteNode
    }

    /// The ripple's wave (#596, #597): one shared shader on every streak, so the tiles still batch, swaying each
    /// streak's texture a little; nil at the cheap tier, where the ripple stands still.
    private(set) var rippleShader: SKShader? {
        didSet { if rippleShader !== oldValue { tileNodes.forEach { $0.streak.shader = rippleShader } } }
    }
    /// The wave for `quality` and `style` (#597).
    private func applyDepth() {
        rippleShader = quality == .full ? Self.lookShader : nil
        Self.rippleAlpha.floatValue = Float(style.rippleAlpha)
    }

    /// The wave's clock: race seconds, wrapped at 600 (`setClock`), never SpriteKit's `u_time`, so a frozen render
    /// fixture draws the same water in every frame and a paused race holds still (as `TurbulenceTrailLayer`'s
    /// `u_clock`). Shared, as its shader is. Static, so it assumes one race scene drawing at a time: a second live
    /// scene's water would draw at whichever set it last.
    private static let waveClock = SKUniform(name: "u_clock", float: 0)
    /// Race time as the wave's shader reads it, for tests.
    var shaderClock: Float { Self.waveClock.floatValue }

    private func setClock(_ time: Double) {
        Self.waveClock.floatValue = Float(time - 600 * (time / 600).rounded(.down))
    }

    /// The streaks' tint and strength as the wave shader draws them (`WaterStyle.rippleAlpha`): uniforms, not the
    /// sprite's `v_color_mix`, whose colour comes premultiplied by the sprite's alpha, so reading both darkened the
    /// streaks well past the plain sprite's look (#597, seen in a local preview). Static, as `waveClock` is.
    private static let rippleTint: SKUniform = {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ChartPalette.lull.uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        return SKUniform(name: "u_tint", vectorFloat3: SIMD3(Float(r), Float(g), Float(b)))
    }()
    private static let rippleAlpha = SKUniform(name: "u_ripple_alpha", float: Float(WaterStyle.standard.rippleAlpha))

    /// Shared by every water node: the ripple tiles batch on one shader. Draws what the plain sprite draws (the lull
    /// tint at the texture's coverage, `rippleAlpha` strong, premultiplied) with the texture swaying on the clock.
    private static let waveShader = SKShader(source: """
    void main() {
        vec2 uv = v_tex_coord;
        uv.y += 0.01 * sin(u_clock * 2.0 + uv.x * 12.0);
        float a = texture2D(u_texture, uv).a * u_ripple_alpha;
        gl_FragColor = vec4(u_tint * a, a);
    }
    """, uniforms: [waveClock, rippleTint, rippleAlpha])

    // MARK: - #604 probe looks

    /// Look A's light: the bearing it comes from on the water, radians in the world frame (from the upper left of
    /// a north-up chart, as the land relief's).
    private static let lightBearing = 2.4

    /// Look B: how much more (+) or less (−) wind a tile lies in than the course wind, −1…1 at a quarter's difference.
    private static func gust(local: GroundWind?, course: GroundWind?) -> Double {
        guard let local, let course, course.speed > 0 else { return 0 }
        return ((local.speed / course.speed - 1) / 0.25).clamped(to: -1...1)
    }

    private static let lookShader: SKShader = {
        switch WaterLook.current {
        case .none, .c: return waveShader
        case .a: return glitterShader
        case .b: return catspawShader
        }
    }()

    private static let puffTint: SKUniform = {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ChartPalette.puff.uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        return SKUniform(name: "u_puff_tint", vectorFloat3: SIMD3(Float(r), Float(g), Float(b)))
    }()

    /// Look A: the ripple, its streaks' lit edge brightened toward the light and glitter specks twinkling on them,
    /// both in the tile's texture, so they ride with the water.
    private static let glitterShader: SKShader = {
        let shader = SKShader(source: """
        float h21(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
        void main() {
            vec2 uv = v_tex_coord;
            uv.y += 0.01 * sin(u_clock * 2.0 + uv.x * 12.0);
            float base = texture2D(u_texture, uv).a;
            // Lit edge: alpha falls away toward the light on the side of a streak that faces it.
            vec2 off = a_light * vec2(0.25 * 0.012, 0.012);
            float edge = max(0.0, base - texture2D(u_texture, uv + off).a);
            // Glitter: a speck in a few cells of the streaks, twinkling on race time.
            vec2 cellP = vec2(uv.x * 4.0 * 22.0, uv.y * 22.0);
            vec2 cell = floor(cellP);
            float h = h21(cell + a_seed);
            float tw = 0.5 + 0.5 * sin(u_clock * (1.5 + 3.0 * h) + h * 40.0);
            float d = length(fract(cellP) - 0.5);
            float spark = step(0.9, h) * pow(tw, 5.0) * smoothstep(0.45, 0.05, d) * smoothstep(0.15, 0.6, base);
            float a = base * u_ripple_alpha;
            float g = clamp(0.22 * edge + 0.85 * spark, 0.0, 1.0);
            gl_FragColor = vec4(u_tint * a * (1.0 - g) + vec3(g), a + g - a * g);
        }
        """, uniforms: [waveClock, rippleTint, rippleAlpha])
        shader.attributes = [SKAttribute(name: "a_light", type: .vectorFloat2), SKAttribute(name: "a_seed", type: .float)]
        return shader
    }()

    /// Look B: the ripple following the wind it lies in: in a puff the streaks double up, lengthen and darken to the
    /// puff's tone; in a lull they fade toward glassy. Each streak scrolls along itself by its tile's `a_scroll`.
    private static let catspawShader: SKShader = {
        let shader = SKShader(source: """
        void main() {
            vec2 uv = v_tex_coord;
            uv.y = fract(uv.y - a_scroll);
            uv.y += 0.01 * sin(u_clock * 2.0 + uv.x * 12.0);
            float g = max(a_gust, 0.0);
            float l = max(-a_gust, 0.0);
            float t1 = texture2D(u_texture, uv).a;
            float k = floor(uv.x * 4.0);
            vec2 uv2 = vec2((k + 0.15 + 0.7 * fract(fract(uv.x * 4.0) + 0.5)) / 4.0, fract(uv.y + 0.43));
            float t2 = texture2D(u_texture, uv2).a;
            float cov = max(t1, t2 * g);
            float a = cov * u_ripple_alpha * (1.0 + 0.5 * g - 0.8 * l);
            vec3 tint = mix(u_tint, u_puff_tint, smoothstep(0.1, 0.6, g));
            gl_FragColor = vec4(tint * a, a);
        }
        """, uniforms: [waveClock, rippleTint, rippleAlpha, puffTint])
        shader.attributes = [SKAttribute(name: "a_gust", type: .float), SKAttribute(name: "a_scroll", type: .float)]
        return shader
    }()

    /// Look C's frame: the sprite's centre in its own (downwind-up) axes, its size, and the swell (wavelength and
    /// speed in points, foam 0…1).
    private static let swellOrigin = SKUniform(name: "u_origin", vectorFloat2: .zero)
    private static let swellSize = SKUniform(name: "u_size", vectorFloat2: .zero)
    private static let swellFoam = SKUniform(name: "u_foam", float: 0)

    /// Look C: long low crests across the course wind, rolling downwind (wavelength 18 m, a 6 s period, so the
    /// 600 s clock wraps on a whole number of crests), meandering, broken into lengths by noise; each crest a
    /// faint lift of the lull tone with a faint puff-tone shadow on its lee, foam specks along the tops.
    private static let swellShader = SKShader(source: """
    float h21(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
    float vnoise(vec2 p) {
        vec2 i = floor(p); vec2 f = fract(p); f = f * f * (3.0 - 2.0 * f);
        float a = h21(i), b = h21(i + vec2(1.0, 0.0)), c = h21(i + vec2(0.0, 1.0)), d = h21(i + vec2(1.0, 1.0));
        return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
    }
    void main() {
        float lambda = 144.0;
        float speed = 24.0;
        vec2 p = (v_tex_coord - 0.5) * u_size + u_origin;
        float y = p.y + 0.18 * lambda * sin(p.x / (2.7 * lambda) + u_clock * 0.104720);
        float phase = (y - speed * u_clock) / lambda;
        float c = 0.5 + 0.5 * cos(6.2831853 * phase);
        float crest = pow(c, 5.0);
        float lee = pow(0.5 + 0.5 * cos(6.2831853 * (phase + 0.2)), 6.0);
        float m = smoothstep(0.25, 0.75, vnoise(vec2(p.x / (3.5 * lambda), floor(phase) * 1.7)));
        float lift = 0.22 * crest * m;
        float shade = 0.16 * lee * m;
        vec2 cellP = p / (lambda * 0.07);
        vec2 cell = floor(cellP);
        float h = h21(cell + floor(phase) * 13.0);
        vec2 at = 0.25 + 0.5 * vec2(h21(cell + 3.1), h21(cell + 7.7));
        float d = length(fract(cellP) - at);
        float foam = step(1.0 - 0.2 * u_foam, h) * pow(c, 16.0) * m * smoothstep(0.3, 0.05, d) * 0.75;
        vec3 lullC = vec3(0.235, 0.435, 0.580);
        vec3 puffC = vec3(0.0, 0.176, 0.302);
        vec3 rgb = lullC * lift + puffC * shade;
        float a = lift + shade;
        rgb = rgb * (1.0 - foam) + vec3(0.89, 0.93, 0.95) * foam;
        a = a + foam - a * foam;
        gl_FragColor = vec4(rgb, a);
    }
    """, uniforms: [waveClock, swellOrigin, swellSize, swellFoam])

    /// Look C: the swell sprite covers the view, turned so its up is the course wind's downwind; its shader draws in
    /// world coordinates, so the crests stay on the water as the view moves.
    private func updateSwell(_ world: WaterWorld, view: WaterView) {
        guard WaterLook.current == .c, let course = world.courseWind else { return }
        let rect = view.rect
        let side = hypot(rect.width, rect.height) * 1.2
        let rotation = CGFloat(-(course.direction + .pi))
        swellSprite.size = CGSize(width: side, height: side)
        swellSprite.position = CGPoint(x: rect.midX, y: rect.midY)
        swellSprite.zRotation = rotation
        let c = cos(-rotation), s = sin(-rotation)
        let local = SIMD2(Float(rect.midX * c - rect.midY * s), Float(rect.midX * s + rect.midY * c))
        Self.swellOrigin.vectorFloat2Value = local
        Self.swellSize.vectorFloat2Value = SIMD2(Float(side), Float(side))
        let knots = RegattaCore.knots(metresPerSecond: Whitecaps.meanWind(of: world.conditions))
        Self.swellFoam.floatValue = Float(((knots - 6) / 12).clamped(to: 0...1))
    }

    private func makeTile() -> Tile {
        // A z each, from its slot (`DrawOrder`; a view takes a few hundred): a frame gives the slots out in
        // lattice order, so the same view draws its tiles in the same order whatever the pool held before. The
        // caps all draw over the streaks.
        let z = DrawOrder.z(tileNodes.count)
        let streak = SKSpriteNode(texture: streakTextures[0], size: CGSize(width: Self.tileSize, height: Self.tileSize))
        streak.color = ChartPalette.lull.uiColor
        streak.colorBlendFactor = 1
        streak.zPosition = z
        streak.shader = rippleShader
        let cap = SKSpriteNode(texture: whitecapTexture, size: CGSize(width: 20, height: 20))
        cap.color = ChartPalette.foam.uiColor
        cap.colorBlendFactor = 1
        cap.zPosition = 1 + z
        cap.isHidden = true
        rippleLayer.addChild(streak)
        rippleLayer.addChild(cap)
        return Tile(streak: streak, cap: cap)
    }

    // MARK: - Puffs and lulls

    private func updatePuffs(_ puffs: [Puff]) {
        while puffNodes.count < puffs.count {
            let node = SKSpriteNode(texture: puffTexture)
            node.colorBlendFactor = 1
            // A z each keeps overlapping puffs and lulls in one order (`DrawOrder`).
            node.zPosition = DrawOrder.z(puffNodes.count)
            puffLayer.addChild(node)
            puffNodes.append(node)
        }
        for (i, node) in puffNodes.enumerated() {
            guard i < puffs.count else {
                node.isHidden = true
                continue
            }
            let puff = puffs[i]
            let overlay = WaterTone.puffOverlay(intensity: puff.intensity, style: style)
            node.isHidden = overlay.alpha <= 0
            let texture = puff.intensity >= 0 ? puffTexture : lullTexture
            if node.texture !== texture { node.texture = texture }
            node.color = overlay.token.uiColor
            node.alpha = CGFloat(overlay.alpha)
            node.position = CGPoint(x: puff.center.x * pointsPerMeter, y: puff.center.y * pointsPerMeter)
            let diameter = puff.radius * 2 * pointsPerMeter
            node.size = CGSize(width: diameter, height: diameter)
        }
    }

    // MARK: - Textures

    // Made once and shared by every scene: they only depend on the style's catspaw, and a race (or a test)
    // shouldn't pay for them again.
    private static let sharedLullTexture = lullTexture()
    private static let sharedStreakTextures = streakTextures(variants: 4)
    private static let sharedWhitecapTexture = whitecapTexture()
    private static let standardPuffTexture = puffTexture(catspaw: WaterStyle.standard.catspaw)

    private static func puffTexture(for style: WaterStyle) -> SKTexture {
        style.catspaw == WaterStyle.standard.catspaw ? standardPuffTexture : puffTexture(catspaw: style.catspaw)
    }

    /// The fall-off of a puff's effect from its centre, `(1 − d²)²` (`Puff.effect`), so it shades as it blows.
    private static func profile(_ u: Double, _ v: Double) -> Double {
        let d2 = u * u + v * v
        return d2 < 1 ? (1 - d2) * (1 - d2) : 0
    }

    /// A lull's texture: smooth, glassy water.
    private static func lullTexture() -> SKTexture {
        texture(pixels: 128) { u, v in profile(u, v) }
    }

    /// A puff's texture: the profile, roughened by catspaws, patches of ruffled water where gusts land.
    private static func puffTexture(catspaw: Double) -> SKTexture {
        texture(pixels: 256) { u, v in
            let noise = 0.65 * valueNoise(u * 16, v * 16, salt: 0x4341_5431) + 0.35 * valueNoise(u * 40, v * 40, salt: 0x4341_5432)
            return profile(u, v) * (1 + catspaw * (2 * noise - 1))
        }
    }

    /// A whitecap: a short, ragged fleck of foam lying across the wind, brightest along its downwind front. In a
    /// 64-pixel texture, drawn at 20 points.
    private static func whitecapTexture() -> SKTexture {
        texture(pixels: 64) { u, v in
            // Texture rows run down the image; the streak tiles' up (downwind) is its top, v = −1.
            let ragged = 0.8 + 0.2 * valueNoise(u * 5, 0, salt: 0x4652_4F54)
            let d2 = (u * u) / (ragged * ragged) + (v + 0.05) * (v + 0.05) * 16
            guard d2 < 1 else { return 0 }
            return (1 - d2) * (0.75 + 0.25 * min(1, max(0, -v * 5)))
        }
    }

    /// The ripple tile's `variants`, 192 pixels square each, side by side in one sheet: every streak draws from
    /// the one texture, so the tiles batch into one draw in the z order they're given (`DrawOrder`).
    private static func streakTextures(variants: Int) -> [SKTexture] {
        let alphas = (0..<variants).map(streakAlpha(variant:))
        let sheet = texture(pixels: 192, count: variants) { k, u, v in alphas[k](u, v) }
        let width = 1 / CGFloat(variants)
        return (0..<variants).map { SKTexture(rect: CGRect(x: CGFloat($0) * width, y: 0, width: width, height: 1), in: sheet) }
    }

    /// A ripple tile (#22): one or two long lanes of soft, broken streaks along the wind (up), like the lanes
    /// wind draws on water: long, tapered and gapped, so they don't read as rain. Laid out by `variant`, as the
    /// alpha at u and v in −1…1 across a tile drawn at `tileSize` points.
    private static func streakAlpha(variant: Int) -> (Double, Double) -> Double {
        struct Dash {
            var x: Double, y0: Double, y1: Double, width: Double, strength: Double
        }
        var dashes: [Dash] = []
        let lanes = 1 + Int(WaterHash.unit(variant, 0, 0, salt: 0x4C41_4E45) * 2)
        for lane in 0..<lanes {
            func r(_ k: Int, _ salt: UInt64) -> Double { WaterHash.unit(variant, lane, k, salt: salt) }
            let length = 50 + r(0, 0x4C45_4E) * 36
            let x = 14 + (Double(lane) + r(0, 0x5858)) / Double(lanes) * (tileSize - 28)
            let lean = (r(0, 0x4C45_414E) - 0.5) * 4 / length
            var y = 4 + r(0, 0x5959) * max(tileSize - 8 - length, 0)
            let end = y + length
            var k = 1
            while y < end - 3 {
                let dash = 12 + r(k, 0x4441_5348) * 20
                let top = min(y + dash, end)
                dashes.append(Dash(x: x + (y - end + length / 2) * lean, y0: y, y1: top,
                                   width: 1.8 + r(k, 0x5749_44) * 1.2, strength: 0.6 + r(k, 0x5354_52) * 0.4))
                y = top + 4 + r(k, 0x4741_50) * 8
                k += 1
            }
        }
        return { u, v in
            let px = (u + 1) / 2 * tileSize, py = (v + 1) / 2 * tileSize
            var alpha = 0.0
            for dash in dashes where py > dash.y0 && py < dash.y1 {
                let along = sin(.pi * (py - dash.y0) / (dash.y1 - dash.y0))
                let across = (px - dash.x) / (dash.width / 2)
                alpha = max(alpha, dash.strength * along * exp(-across * across))
            }
            return alpha
        }
    }

    /// A white texture of `pixels` square whose alpha is `alpha(u, v)`, with u and v in −1…1 across it.
    private static func texture(pixels: Int, alpha: (Double, Double) -> Double) -> SKTexture {
        texture(pixels: pixels, count: 1) { _, u, v in alpha(u, v) }
    }

    /// A white texture of `count` squares of `pixels` side by side, the kth's alpha `alpha(k, u, v)` with u and v
    /// in −1…1 across it. In a sheet of more than one, each square's outermost columns are left clear, so
    /// filtering at one's edge never picks up its neighbour.
    private static func texture(pixels: Int, count: Int, alpha: (Int, Double, Double) -> Double) -> SKTexture {
        let width = pixels * count
        var bytes = [UInt8](repeating: 0, count: width * pixels * 4)
        for square in 0..<count {
            for y in 0..<pixels {
                for x in 0..<pixels {
                    if count > 1, x == 0 || x == pixels - 1 { continue }
                    let u = (Double(x) + 0.5) / Double(pixels) * 2 - 1
                    let v = (Double(y) + 0.5) / Double(pixels) * 2 - 1
                    let a = UInt8((alpha(square, u, v).clamped(to: 0...1) * 255).rounded())
                    let k = (y * width + square * pixels + x) * 4
                    // Premultiplied white.
                    bytes[k] = a
                    bytes[k + 1] = a
                    bytes[k + 2] = a
                    bytes[k + 3] = a
                }
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let provider, let image = CGImage(
            width: width, height: pixels, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent
        ) else { preconditionFailure("couldn't make a \(width)×\(pixels)-pixel water texture") }
        return SKTexture(cgImage: image)
    }

    /// Smooth value noise, 0…1, on a unit lattice.
    private static func valueNoise(_ x: Double, _ y: Double, salt: UInt64) -> Double {
        let x0 = x.rounded(.down), y0 = y.rounded(.down)
        let fx = x - x0, fy = y - y0
        let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
        let i = Int(x0), j = Int(y0)
        func at(_ di: Int, _ dj: Int) -> Double { WaterHash.unit(i + di, j + dj, 0, salt: salt) }
        let top = at(0, 0) + (at(1, 0) - at(0, 0)) * sx
        let bottom = at(0, 1) + (at(1, 1) - at(0, 1)) * sx
        return top + (bottom - top) * sy
    }
}
