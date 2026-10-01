import CoreGraphics
import RegattaCore

/// The minimap's pressure (#289, #114), sampled at most every `interval` ticks and whenever the race comes to hold a
/// different set of wind keys, not at every HUD refresh: the field drifts over seconds, and sampling the whole chart
/// at 15 Hz was most of the HUD's cost (#310). The image is made once per sample. A sample the race can't take yet
/// (online, before it holds the key) isn't kept, so the next refresh tries again.
final class MinimapField {
    /// Two seconds of race time.
    static let interval = 2 * Race.tickRate

    /// Samples the pressure over `chart` in `world`; nil while the race doesn't hold the key. Injected by tests.
    typealias Sampler = (_ world: RenderWorld, _ chart: MinimapChart) -> PressureTone?

    private let sample: Sampler
    private(set) var chart: MinimapChart?
    private(set) var image: CGImage?
    private var sampledTick: Int?
    private var sampledKeys = 0

    init(sample: @escaping Sampler = { world, chart in world.windSampler.map(chart.pressure) }) {
        self.sample = sample
    }

    /// The pressure image for `world`'s tick: the cached one, or a fresh sample when it is due.
    @discardableResult func refresh(_ world: RenderWorld) -> CGImage? {
        let chart = MinimapChart(course: world.course)
        let tick = world.frame.tick
        let keys = world.frame.wind.keys.keys.count
        let isDue = chart != self.chart || keys != sampledKeys
            || sampledTick.map { abs(tick - $0) >= Self.interval } ?? true
        guard isDue else { return image }
        self.chart = chart
        if let tone = sample(world, chart) {
            image = tone.image(style: .standard)
            sampledTick = tick
            sampledKeys = keys
        } else {
            image = nil
            sampledTick = nil
        }
        return image
    }
}
