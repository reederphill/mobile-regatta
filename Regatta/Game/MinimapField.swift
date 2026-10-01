import CoreGraphics
import RegattaCore

/// The minimap's pressure (#289, #114), sampled at most every `interval` ticks and whenever the race comes to hold a
/// different set of wind keys, not at every HUD refresh: the field drifts over seconds, and sampling the whole chart
/// at 15 Hz was most of the HUD's cost (#310). The image is made once per sample. A sample the race can't take yet
/// (online, before it holds the key) keeps the last good image and is tried again at the same cadence, or as soon
/// as the keys change.
final class MinimapField {
    /// Two seconds of race time.
    static let interval = 2 * Race.tickRate

    /// Samples the pressure over `chart` in `world`; nil while the race doesn't hold the key. Injected by tests.
    typealias Sampler = (_ world: RenderWorld, _ chart: MinimapChart) -> PressureTone?

    private let sample: Sampler
    private(set) var chart: MinimapChart?
    private(set) var image: CGImage?
    /// The tick and the keys of the last attempt, kept or not.
    private var triedTick: Int?
    private var triedKeys: WindKeyChain?

    init(sample: @escaping Sampler = { world, chart in world.windSampler.map(chart.pressure) }) {
        self.sample = sample
    }

    /// The pressure image for `world`'s tick: the cached one, or a fresh sample when it is due.
    @discardableResult func refresh(_ world: RenderWorld) -> CGImage? {
        let chart = MinimapChart(course: world.course)
        let tick = world.frame.tick
        // By identity, not count: a key replaced in its window resamples too.
        let keys = world.frame.wind.keys
        let isNewChart = chart != self.chart
        let isDue = isNewChart || keys != triedKeys
            || triedTick.map { abs(tick - $0) >= Self.interval } ?? true
        guard isDue else { return image }
        // Another course's image would draw in the wrong place; the same course's last one is still the field.
        if isNewChart { image = nil }
        self.chart = chart
        triedTick = tick
        triedKeys = keys
        if let tone = sample(world, chart) { image = tone.image(style: .standard) }
        return image
    }
}
