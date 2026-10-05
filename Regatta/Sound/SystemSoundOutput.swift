import AVFoundation
import UIKit

/// The device's sounds (#126): one `AVAudioEngine`, a player node per one-shot asset and a looping one per ambience
/// layer. Everything runs on the engine's own queue, so nothing on the main thread waits for a sound to load or
/// synthesise. Nothing is made until the first sound plays: no queue, observers or `AVAudioEngine` before, and with
/// Effects off (`GatedSound` passes nothing on), never.
final class SystemSoundOutput: SoundOutput {
    private var engine: SoundEngine?

    func play(_ cue: SoundCue) {
        soundEngine().play(cue.asset)
    }

    func setAmbience(_ gains: AmbienceGains) {
        // A silence before any sound needs no engine.
        guard engine != nil || !gains.isSilent else { return }
        soundEngine().setAmbience(gains)
    }

    private func soundEngine() -> SoundEngine {
        if let engine { return engine }
        let engine = SoundEngine(foreground: UIApplication.didBecomeActiveNotification)
        self.engine = engine
        return engine
    }
}

/// The audio engine behind `SystemSoundOutput`, confined to `queue`. A failure is logged once and swallowed: the
/// game plays on silent. It restarts after an interruption (a call) ends, on a route or configuration change and on
/// returning to the foreground (`foreground`, the app's became-active notification). An engine that won't start isn't
/// asked again until one of those.
nonisolated final class SoundEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.phillreeder.regatta.sound", qos: .userInitiated)
    private let library: SoundLibrary
    /// Made with the first node.
    private var engine: AVAudioEngine?
    private var buffers: [SoundAsset: AVAudioPCMBuffer] = [:]
    /// Assets that couldn't load or synthesise: silent from then on, not retried on every play.
    private var failed: Set<SoundAsset> = []
    private var oneShots: [SoundAsset: AVAudioPlayerNode] = [:]
    private var loops: [AmbienceLayer: AVAudioPlayerNode] = [:]
    /// The ambience's gains as last set: loops play while theirs is above zero.
    private var gains = AmbienceGains.silent
    /// The engine failed to start: `start()` doesn't try again until an interruption ends, the route changes or the
    /// app returns to the foreground.
    private var startBlocked = false
    /// Bumped on every sound, so an idle stop scheduled before it is called off.
    private var generation = 0
    private var observers: [NSObjectProtocol] = []
    /// The engine stops this long after the ambience goes silent with nothing played since.
    static let idleStopSeconds = 5.0

    init(library: SoundLibrary = SoundLibrary(), foreground: Notification.Name) {
        self.library = library
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                            queue: nil) { [weak self] note in
            guard SoundSession.interruptionEnded(note), let self else { return }
            queue.async { self.interruptionEnded() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil,
                                            queue: nil) { [weak self] _ in
            guard let self else { return }
            queue.async { self.retry() }
        })
        observers.append(center.addObserver(forName: foreground, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            queue.async { self.retry() }
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func play(_ asset: SoundAsset) {
        queue.async { [self] in
            generation += 1
            guard let node = oneShot(asset), let buffer = buffers[asset], start() else { return }
            node.scheduleBuffer(buffer, at: nil, options: .interrupts)
            node.play()
        }
    }

    func setAmbience(_ new: AmbienceGains) {
        queue.async { [self] in
            gains = new
            for layer in AmbienceLayer.allCases {
                let gain = new[layer]
                if gain > 0 {
                    generation += 1
                    guard let node = loop(layer), start() else { continue }
                    node.volume = Float(gain)
                    if !node.isPlaying { node.play() }
                } else if let node = loops[layer], node.isPlaying {
                    node.volume = 0
                }
            }
            if new.isSilent { scheduleIdleStop() }
        }
    }

    // MARK: - On the queue

    /// The engine, made the first time a node needs it.
    private func audioEngine() -> AVAudioEngine {
        if let engine { return engine }
        let engine = AVAudioEngine()
        self.engine = engine
        observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                object: engine, queue: nil) { [weak self] _ in
            guard let self else { return }
            queue.async { self.restart() }
        })
        return engine
    }

    /// Starts the engine if it isn't running; false if it can't (logged once until the next retry).
    private func start() -> Bool {
        guard !startBlocked else { return false }
        let engine = audioEngine()
        guard !engine.isRunning else { return true }
        do {
            engine.prepare()
            try engine.start()
            return true
        } catch {
            startBlocked = true
            SoundSession.log.error("Audio engine: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func load(_ asset: SoundAsset) -> AVAudioPCMBuffer? {
        if let buffer = buffers[asset] { return buffer }
        guard !failed.contains(asset) else { return nil }
        guard let buffer = library.buffer(asset)?.buffer else {
            failed.insert(asset)
            SoundSession.log.error("Sound \(asset.rawValue, privacy: .public): couldn't load; it stays silent")
            return nil
        }
        buffers[asset] = buffer
        return buffer
    }

    private func oneShot(_ asset: SoundAsset) -> AVAudioPlayerNode? {
        if let node = oneShots[asset] { return node }
        guard let buffer = load(asset) else { return nil }
        let node = attach(buffer)
        oneShots[asset] = node
        return node
    }

    /// The layer's node, attached with its loop scheduled the first time.
    private func loop(_ layer: AmbienceLayer) -> AVAudioPlayerNode? {
        if let node = loops[layer] { return node }
        guard let buffer = load(layer.asset) else { return nil }
        let node = attach(buffer)
        node.volume = 0
        node.scheduleBuffer(buffer, at: nil, options: .loops)
        loops[layer] = node
        return node
    }

    private func attach(_ buffer: AVAudioPCMBuffer) -> AVAudioPlayerNode {
        let engine = audioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: buffer.format)
        return node
    }

    /// An interruption ended: the system deactivated the session, so reactivate it before the engine starts again.
    private func interruptionEnded() {
        guard engine != nil else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            SoundSession.log.error("Audio session: \(String(describing: error), privacy: .public)")
        }
        startBlocked = false
        restart()
    }

    /// The route changed or the app came back: an engine that couldn't start may now, and one the system stopped
    /// plays the audible ambience again.
    private func retry() {
        startBlocked = false
        guard let engine, !engine.isRunning, !gains.isSilent else { return }
        restart()
    }

    /// After an interruption or a configuration change the engine is stopped and its nodes have lost their
    /// schedule: start it again and loop each audible layer afresh.
    private func restart() {
        guard engine != nil else { return }
        rescheduleLoops()
        guard !gains.isSilent, start() else { return }
        for (layer, node) in loops where gains[layer] > 0 {
            node.volume = Float(gains[layer])
            node.play()
        }
    }

    /// Stops every loop and schedules it afresh, ready to play from its start.
    private func rescheduleLoops() {
        for (layer, node) in loops {
            node.stop()
            if let buffer = buffers[layer.asset] { node.scheduleBuffer(buffer, at: nil, options: .loops) }
        }
    }

    /// Stops the engine once the race has been silent a while, so the menus run no audio engine.
    private func scheduleIdleStop() {
        let scheduled = generation
        queue.asyncAfter(deadline: .now() + Self.idleStopSeconds) { [self] in
            guard generation == scheduled, gains.isSilent, let engine, engine.isRunning else { return }
            rescheduleLoops()
            engine.stop()
        }
    }
}
