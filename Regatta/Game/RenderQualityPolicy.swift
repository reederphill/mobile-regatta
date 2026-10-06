import Foundation

/// What the race draws at, from the device's heat, Low Power Mode and screen (#127, #27's degradation ladder): the
/// frame rate and a tier for each effect that has a cheaper one. Automatic: there is no graphics-quality setting.
///
/// - The frame rate is 60 on every screen, ProMotion included, while the thermal state is nominal, fair or serious, Low
///   Power Mode or not, and 30 at critical. The sim ticks at 30 Hz, so frames past 60 only interpolate, and an
///   unconditional 120 was the biggest heat cost on ProMotion phones (#405). 120 is a Debug launch flag at most
///   (`-fps120`, `init(thermalState:lowPower:maxFPS:fps120:)`); a Release build can't draw it.
/// - The effects step down by thermal state only, each tier keeping the last one's cuts: serious freezes the ripple and
///   thins the whitecaps (`WaterQuality.cheap`) and drops the sail animation detail on boats far from yours
///   (`SailDetail.farReduced`; heel and the boom stay); critical also shortens the wakes (`WakeQuality.short`, still
///   speed-scaled). Low Power Mode changes nothing yet: it caps the frame rate at 60, which every tier already is.
///
/// Purely visual: nothing here reaches the race (ADR 0002), and nothing may remove a cue that carries race information.
/// The cue layer, the chart's marks and boundary, the puff shading and pressure tone, the rule cues and the HUD (minimap
/// included) have no tier, so they draw the same at every one by construction.
nonisolated struct RenderQualityPolicy: Equatable, Sendable {
    /// The frame rate every cool or warm screen draws at.
    static let standardFPS = 60

    var fps: Int
    var water: WaterQuality
    var wake: WakeQuality
    var sail: SailDetail

    /// `maxFPS` is the screen's top frame rate (`UIScreen.maximumFramesPerSecond`): no tier draws faster than it.
    init(thermalState: ProcessInfo.ThermalState, lowPower: Bool, maxFPS: Int) {
        let tier = Tier(thermalState)
        let fps = tier >= .critical ? 30 : Self.standardFPS
        self.fps = min(fps, max(maxFPS, 30))
        water = tier >= .serious ? .cheap : .full
        sail = tier >= .serious ? .farReduced : .full
        wake = tier >= .critical ? .short : .full
    }

    #if DEBUG
    /// The policy with `-fps120` (Debug builds only): 120 on a ProMotion screen while it is cool (nominal or fair) and
    /// not in Low Power Mode, for comparing smoothness on a device; otherwise the shipped policy.
    init(thermalState: ProcessInfo.ThermalState, lowPower: Bool, maxFPS: Int, fps120: Bool) {
        self.init(thermalState: thermalState, lowPower: lowPower, maxFPS: maxFPS)
        if fps120, !lowPower, Tier(thermalState) == .cool { fps = min(120, max(maxFPS, fps)) }
    }
    #endif

    /// The thermal states in order of heat; one the SDK adds later counts as fair.
    private enum Tier: Int, Comparable {
        case cool, serious, critical

        init(_ state: ProcessInfo.ThermalState) {
            switch state {
            case .nominal, .fair: self = .cool
            case .serious: self = .serious
            case .critical: self = .critical
            @unknown default: self = .cool
            }
        }

        static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
    }
}

/// How much of a boat's sail animation draws (#127): all of it, or none of the flutter, luff shiver, belly pump or flog
/// swing on boats far from yours (`BoatStyle.farBoatHulls`). Her heel, her sail's trim and side (the boom) and a roll
/// miss killing her wake draw in either; your own boat and ghosts always draw in full. (#120's sailors, post-1.0, would
/// drop here too.)
nonisolated enum SailDetail: Sendable {
    case full, farReduced
}

/// Whether a boat counts as far from yours (#127), with a dead band so one sailing along the edge doesn't flicker:
/// far beyond `hulls` hull lengths, near again only inside `nearShare` of that.
nonisolated enum FarBoat {
    static let nearShare = 0.8

    static func isFar(hullsFromYou distance: Double, wasFar: Bool, hulls: Double) -> Bool {
        wasFar ? distance > hulls * nearShare : distance > hulls
    }
}
