import CoreGraphics
import Foundation
import RegattaCore

/// The pressure as a tone (#289, ADR 0008): the wind the venue's geography and the pressure field make, before
/// puffs, sampled on a grid and drawn as one continuous field, smoothly stretched between its samples: darker
/// (`ChartPalette.puff`) where there is more pressure, lighter (`ChartPalette.lull`) where less. The water draws
/// it under the puffs, on a grid following the camera; the minimap draws it over the whole chart. Both sample
/// the model's own field (`WindSampler.pressureFactor(at:)`), so they always agree.
nonisolated struct PressureTone: Equatable, Sendable {
    /// Samples across.
    var columns: Int
    /// Samples up.
    var rows: Int
    /// Row by row from the bottom (south) row, west to east in each: each sample's pressure, as a fraction of the
    /// course average above (positive) or below (negative) it (`WindSampler.pressureFactor(at:)` − 1).
    var pressures: [Double]
    /// How strongly it draws: 1 on the water and the minimap; the tuning panel's overlay draws it stronger.
    var boost = 1.0

    /// Sample `column`, `row`'s pressure.
    func pressure(column: Int, row: Int) -> Double {
        pressures[row * columns + column]
    }

    /// The tone's pixels, a pixel a sample: premultiplied sRGB RGBA, the top (north) row first, as a `CGImage`
    /// lays them out. Each is its sample's `WaterTone.pressureOverlay`, its token at its alpha.
    func pixels(style: WaterStyle) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: columns * rows * 4)
        for row in 0..<rows {
            for column in 0..<columns {
                let overlay = WaterTone.pressureOverlay(pressure(column: column, row: row), style: style, boost: boost)
                let k = ((rows - 1 - row) * columns + column) * 4
                let rgb = overlay.token.components
                for c in 0..<3 {
                    bytes[k + c] = UInt8((rgb[c] * overlay.alpha * 255).rounded())
                }
                bytes[k + 3] = UInt8((overlay.alpha * 255).rounded())
            }
        }
        return bytes
    }

    /// The tone as an image, a pixel a sample (`pixels(style:)`), smoothly interpolated when stretched.
    func image(style: WaterStyle) -> CGImage? {
        guard columns > 0, rows > 0 else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(pixels(style: style)) as CFData) else { return nil }
        return CGImage(width: columns, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: columns * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

nonisolated extension WaterTone {
    /// What pressure `pressure` (a fraction of the course average above or below it) draws with: its token and
    /// alpha, `ChartPalette.puff` darker for more and `ChartPalette.lull` lighter for less, at full tone at
    /// `WaterStyle.fullTonePressureGain` or `fullTonePressureLoss`. `boost` strengthens it (the tuning overlay).
    static func pressureOverlay(_ pressure: Double, style: WaterStyle, boost: Double = 1) -> (token: PaletteToken, alpha: Double) {
        if pressure >= 0 {
            let gain = style.fullTonePressureGain
            return (ChartPalette.puff, gain > 0 ? (pressure * boost / gain).clamped(to: 0...1) : 0)
        }
        let loss = style.fullTonePressureLoss
        return (ChartPalette.lull, loss > 0 ? (-pressure * boost / loss).clamped(to: 0...1) : 0)
    }

    /// The lightness change pressure `pressure` makes on the water.
    static func pressureDelta(_ pressure: Double, style: WaterStyle) -> Double {
        let overlay = pressureOverlay(pressure, style: style)
        return lightnessDelta(overlay.token, alpha: overlay.alpha)
    }

    /// The faintest pressure difference `conditions` makes at its peak: its weakest pressure lane's. Nil for
    /// conditions with no pressure field.
    static func faintestPressureDelta(of conditions: Conditions, style: WaterStyle) -> Double? {
        guard let field = conditions.pressureField else { return nil }
        return abs(pressureDelta(field.lanes.strength.lowerBound, style: style))
    }
}

/// Where the water samples the pressure (#289): a square grid fixed to the water, so the tone doesn't swim as
/// the camera moves, covering the view with a sample to spare all round. Spread out with the camera's zoom as
/// the ripple's lattice is (`RippleLattice.step`), so a view takes about the same number of samples at any
/// zoom, the same in every water tier: the tone is a race cue, so the thermal ladder (#127) never coarsens it.
nonisolated struct PressureGrid: Equatable, Sendable {
    /// Points between samples at the default zoom.
    static let fullSpacing = 96.0

    /// Points between samples.
    var spacing: Double
    var columns: ClosedRange<Int>
    var rows: ClosedRange<Int>

    /// The grid covering `view`. Every water tier samples it alike: a few hundred samples, so halving them saves
    /// next to nothing, and the cue must draw pixel for pixel the same at every thermal tier (#127).
    @MainActor static func forView(_ view: WaterView) -> PressureGrid {
        let spacing = fullSpacing * RippleLattice.step(cameraScale: view.spreadScale)
        let rect = view.rect
        return PressureGrid(spacing: spacing,
                            columns: Int((rect.minX / spacing).rounded(.down)) - 1...Int((rect.maxX / spacing).rounded(.up)) + 1,
                            rows: Int((rect.minY / spacing).rounded(.down)) - 1...Int((rect.maxY / spacing).rounded(.up)) + 1)
    }

    /// Sample `i`, `j` on the water, world points.
    func position(_ i: Int, _ j: Int) -> CGPoint {
        CGPoint(x: Double(i) * spacing, y: Double(j) * spacing)
    }

    /// The rectangle the tone's texture covers, world points: its pixels' centres on the samples.
    var rect: CGRect {
        CGRect(x: (Double(columns.lowerBound) - 0.5) * spacing, y: (Double(rows.lowerBound) - 0.5) * spacing,
               width: Double(columns.count) * spacing, height: Double(rows.count) * spacing)
    }
}

/// The minimap's chart (#282, #289, #114): the race area with a small margin, metres, fitted into the minimap's size
/// course-up, whatever the camera: the course axis at the top. Points on it are in course coordinates, `u` across
/// the axis (to the right looking upwind) and `v` up it, from the race area's centre. The HUD samples the pressure
/// over it and the minimap draws the samples across it, so the map's tone is the model's at its pixels.
nonisolated struct MinimapChart: Equatable, Sendable {
    /// The race area's centre, metres, and the course axis, radians.
    var centre: Vec2
    var axis: Double
    /// The chart's edges in course coordinates, metres.
    var minU: Double
    var maxU: Double
    var minV: Double
    var maxV: Double

    /// Samples across the chart: its pressure tone is `pressureColumns` wide, and as many rows as keep them square.
    static let pressureColumns = 48
    /// The margin round the race area, a fraction of its longer half side.
    static let margin = 0.04

    init(course: CourseLayout) {
        let area = course.raceArea
        centre = area.centre
        axis = area.axis
        let margin = Self.margin * max(area.halfWidth, area.halfLength)
        minU = -area.halfWidth - margin
        maxU = area.halfWidth + margin
        minV = -area.halfLength - margin
        maxV = area.halfLength + margin
    }

    var upwind: Vec2 { .heading(axis) }
    var right: Vec2 { upwind.rightPerp }

    /// `p` (metres) in course coordinates.
    func courseCoordinates(_ p: Vec2) -> (u: Double, v: Double) {
        let offset = p - centre
        return (offset.dot(right), offset.dot(upwind))
    }

    /// The water at course coordinates `u`, `v`, metres.
    func position(u: Double, v: Double) -> Vec2 {
        centre + right * u + upwind * v
    }

    /// Metres a pressure sample covers across.
    var pressureCell: Double { (maxU - minU) / Double(Self.pressureColumns) }
    var pressureRows: Int { max(1, Int(((maxV - minV) / pressureCell).rounded())) }

    /// The middle of pressure sample `column`, `row` on the water, metres: its cells tile the chart, columns across
    /// the axis from the left, rows up it from the bottom.
    func pressurePoint(column: Int, row: Int) -> Vec2 {
        position(u: minU + (Double(column) + 0.5) * pressureCell,
                 v: minV + (Double(row) + 0.5) * (maxV - minV) / Double(pressureRows))
    }

    /// The pressure over the chart, from the tick's sampler.
    func pressure(_ sampler: WindSampler) -> PressureTone {
        let rows = pressureRows, columns = Self.pressureColumns
        var pressures: [Double] = []
        pressures.reserveCapacity(rows * columns)
        for row in 0..<rows {
            for column in 0..<columns {
                pressures.append(sampler.pressureFactor(at: pressurePoint(column: column, row: row)) - 1)
            }
        }
        return PressureTone(columns: columns, rows: rows, pressures: pressures)
    }

    /// Metres to minimap points, and the chart's offset, fitting it into `size`.
    private func fit(_ size: CGSize) -> (scale: Double, x: Double, y: Double) {
        let scale = min(size.width / (maxU - minU), size.height / (maxV - minV))
        return (scale, (size.width - (maxU - minU) * scale) / 2, (size.height - (maxV - minV) * scale) / 2)
    }

    /// Where `p` (metres) draws in a minimap of `size`, kept on the chart: the axis up.
    func point(_ p: Vec2, in size: CGSize) -> CGPoint {
        let fit = fit(size)
        let (u, v) = courseCoordinates(p)
        return CGPoint(x: fit.x + (u.clamped(to: minU...maxU) - minU) * fit.scale,
                       y: size.height - fit.y - (v.clamped(to: minV...maxV) - minV) * fit.scale)
    }

    /// Where the whole chart draws in a minimap of `size`: the pressure tone's rectangle.
    func rect(in size: CGSize) -> CGRect {
        let fit = fit(size)
        return CGRect(x: fit.x, y: fit.y, width: (maxU - minU) * fit.scale, height: (maxV - minV) * fit.scale)
    }
}

/// The tuning panel's pressure overlay (#289): Debug builds only, never in a race's look.
nonisolated enum PressureOverlay {
    /// How many times as strong the overlay draws the pressure tone.
    static let boost = 3.0
}
