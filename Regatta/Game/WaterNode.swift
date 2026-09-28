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
}

extension WaterWorld {
    /// The ripple samples the wind at every tile, every frame: through one sampler for the frame's tick, which
    /// places the live puffs once, rather than `world.groundWind(at:)`, which places them again at every tile.
    /// The same wind, bit for bit; in a Debug build the per-tile sampling was over half the frame (#232).
    init(_ world: RenderWorld) {
        let sampler = world.windSampler
        self.init(wind: { sampler?.sample($0) }, courseWind: world.courseWind, puffs: world.puffs,
                  conditions: world.conditions, time: world.time)
    }
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

    var rect: CGRect {
        let size = CGSize(width: sceneSize.width * scale, height: sceneSize.height * scale)
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }
}

/// The water (#116, #22): puffs darker and lulls lighter than the course average, with a catspaw texture on
/// puffs; a faint ripple of streaks, each lying along the wind where it is (puff fans and the fleet-wide shift
/// included) and all drifting downwind at a speed set by the conditions' mean wind; whitecaps as many as that
/// mean wind makes, wherever they are. Everything it draws is set by `style` (#232 tunes it) and `quality` (#127 lowers it).
final class WaterNode: SKNode {
    /// A ripple streak as last drawn: where it is (metres) and the wind direction it lies along.
    struct Streak: Equatable {
        var position: Vec2
        var windDirection: Double
    }

    var style: WaterStyle {
        didSet { if style.catspaw != oldValue.catspaw { puffTexture = Self.puffTexture(for: style) } }
    }
    var quality = WaterQuality.full

    /// How far the ripple has drifted downwind, world points.
    private(set) var drift = CGPoint.zero
    /// The streaks drawn last frame, in draw order.
    private(set) var streaks: [Streak] = []
    /// The tiles carrying a breaking whitecap last frame.
    private(set) var whitecaps: [RippleLattice.Index] = []

    private let pointsPerMeter: Double
    private let puffLayer = SKNode()
    private let rippleLayer = SKNode()
    private var puffTexture: SKTexture
    private let lullTexture = WaterNode.sharedLullTexture
    private let streakTextures = WaterNode.sharedStreakTextures
    private let whitecapTexture = WaterNode.sharedWhitecapTexture
    private var puffNodes: [SKSpriteNode] = []
    private var tileNodes: [Tile] = []

    /// The size a streak tile's texture is drawn for: `style.rippleSpacing` scales it from here.
    private static let tileSize = 96.0

    init(pointsPerMeter: Double, style: WaterStyle = .standard) {
        self.pointsPerMeter = pointsPerMeter
        self.style = style
        puffTexture = Self.puffTexture(for: style)
        super.init()
        puffLayer.zPosition = 0
        rippleLayer.zPosition = 1
        addChild(puffLayer)
        addChild(rippleLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Draws `world` as seen through `view`, `dt` simulated seconds after the last frame (0 when settled).
    func update(_ world: WaterWorld, view: WaterView, dt: Double) {
        updateRipple(world, view: view, dt: dt)
        updatePuffs(world.puffs)
    }

    // MARK: - Ripple and whitecaps

    private func updateRipple(_ world: WaterWorld, view: WaterView, dt: Double) {
        let course = world.courseWind
        if quality == .full, let course, dt > 0 {
            let speed = style.rippleDrift * Whitecaps.meanWind(of: world.conditions) * pointsPerMeter * dt
            let downwind = -Vec2.heading(course.direction) * speed
            drift = CGPoint(x: drift.x + downwind.x, y: drift.y + downwind.y)
        }

        let (lattice, tileScale) = RippleLattice.forView(style: style, cameraScale: Double(view.scale))
        let (columns, rows) = lattice.indices(covering: view.rect, drift: drift)
        let count = columns.count * rows.count
        while tileNodes.count < count { tileNodes.append(makeTile()) }

        let share = Whitecaps.share(in: world.conditions, style: style, quality: quality)
        let period = max(style.whitecapSeconds, 0.1)
        let scale = CGFloat(tileScale * style.rippleSpacing / Self.tileSize)
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
                updateWhitecap(tile, at: index, share: share, time: world.time, period: period)
            }
        }
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

    private func makeTile() -> Tile {
        // A z each, from its slot (`DrawOrder`; a view takes a few hundred): a frame gives the slots out in
        // lattice order, so the same view draws its tiles in the same order whatever the pool held before. The
        // caps all draw over the streaks.
        let z = DrawOrder.z(tileNodes.count)
        let streak = SKSpriteNode(texture: streakTextures[0], size: CGSize(width: Self.tileSize, height: Self.tileSize))
        streak.color = ChartPalette.lull.uiColor
        streak.colorBlendFactor = 1
        streak.zPosition = z
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
