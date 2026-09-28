import CoreGraphics
import Foundation
import RegattaCore

/// The wind the minimap shows (#224): the puffs' and lulls' summed effect on the wind speed over the chart, as one
/// field, the way the race sums them. Where puffs overlap they merge; where a puff and a lull overlap they cancel,
/// rather than one disc drawn over another. The sampling is pushed about by slow noise fixed to the water, so a
/// patch's outline is ragged, like catspaws, and changes as it drifts through.
nonisolated enum MinimapWind {
    /// How far the noise pushes the sampling, metres, along each axis.
    static let warp = 30.0
    /// Metres across one cell of the noise.
    static let warpScale = 90.0
    /// The field's tone alpha is raised to this power: under 1, it lifts a patch's faint fringe, so it shows at
    /// nearer its full size on a chart this small.
    static let lift = 0.6

    /// The summed change in wind speed at `p` (metres), as a fraction of the course average: each puff's or lull's
    /// `intensity · (1 − d²)²` (`Puff.effect`), sampled at `p` pushed about by the noise.
    static func speedChange(at p: Vec2, puffs: [MiniPuff]) -> Double {
        let q = p + Vec2(noise(p, salt: 0x4D57_4E01), noise(p, salt: 0x4D57_4E02)) * warp
        var sum = 0.0
        for puff in puffs {
            let d2 = (q - puff.center).lengthSquared / (puff.radius * puff.radius)
            guard d2 < 1 else { continue }
            let f = 1 - d2
            sum += puff.intensity * f * f
        }
        return sum
    }

    /// The field as `width` × `height` premultiplied RGBA pixels over `world` (metres, the top row at its top
    /// edge): each in the puff or lull tone of its change, clear where there is none.
    static func pixels(puffs: [MiniPuff], world: CGRect, width: Int, height: Int, style: WaterStyle) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard !puffs.isEmpty else { return bytes }
        for row in 0..<height {
            for column in 0..<width {
                let p = Vec2(Double(world.minX) + (Double(column) + 0.5) / Double(width) * Double(world.width),
                             Double(world.maxY) - (Double(row) + 0.5) / Double(height) * Double(world.height))
                let overlay = WaterTone.puffOverlay(intensity: speedChange(at: p, puffs: puffs), style: style)
                guard overlay.alpha > 0 else { continue }
                let alpha = pow(overlay.alpha, lift)
                let rgb = overlay.token.rgb
                let k = (row * width + column) * 4
                bytes[k] = UInt8((Double((rgb >> 16) & 0xFF) * alpha).rounded())
                bytes[k + 1] = UInt8((Double((rgb >> 8) & 0xFF) * alpha).rounded())
                bytes[k + 2] = UInt8((Double(rgb & 0xFF) * alpha).rounded())
                bytes[k + 3] = UInt8((255 * alpha).rounded())
            }
        }
        return bytes
    }

    /// `pixels` as an image, to draw stretched over the chart (smoothly: it is coarser than the screen).
    static func image(puffs: [MiniPuff], world: CGRect, width: Int, height: Int, style: WaterStyle) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let bytes = pixels(puffs: puffs, world: world, width: width, height: height, style: style)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// −1…1 noise at `p`, fixed to the water.
    private static func noise(_ p: Vec2, salt: UInt64) -> Double {
        2 * WaterHash.valueNoise(p.x / warpScale, p.y / warpScale, salt: salt) - 1
    }
}
