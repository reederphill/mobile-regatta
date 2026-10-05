import AVFoundation

/// The device's sounds (#126): one `AVAudioEngine`, a player node per one-shot asset and a looping one per ambience
/// layer. Everything runs on the engine's own queue, so nothing on the main thread waits for a sound to load or
/// synthesise. Nothing loads or starts until the first sound plays: with Effects off (`GatedSound`), never.
final class SystemSoundOutput: SoundOutput {
    private let engine = SoundEngine()

    func play(_ cue: SoundCue) {
        engine.play(cue.asset)
    }

    func setAmbience(_ gains: AmbienceGains) {
        engine.setAmbience(gains)
    }
}

/// The audio engine behind `SystemSoundOutput`, confined to `queue`. A failure is logged and swallowed: the game
/// plays on silent. It restarts after an interruption (a call) or a route change.
nonisolated final class SoundEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.phillreeder.regatta.sound", qos: .userInitiated)
    private let library: SoundLibrary
    private let engine = AVAudioEngine()
    private var buffers: [SoundAsset: AVAudioPCMBuffer] = [:]
    private var oneShots: [SoundAsset: AVAudioPlayerNode] = [:]
    private var loops: [AmbienceLayer: AVAudioPlayerNode] = [:]
    /// The ambience's gains as last set: loops play while theirs is above zero.
    private var gains = AmbienceGains.silent
    /// Bumped on every sound, so an idle stop scheduled before it is called off.
    private var generation = 0
    private var observers: [NSObjectProtocol] = []
    /// The engine stops this long after the ambience goes silent with nothing played since.
    static let idleStopSeconds = 5.0

    init(library: SoundLibrary = SoundLibrary()) {
        self.library = library
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                            queue: nil) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init)
            guard type == .ended, let self else { return }
            queue.async { self.restart() }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                            queue: nil) { [weak self] _ in
            guard let self else { return }
            queue.async { self.restart() }
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

    /// Starts the engine if it isn't running; false if it can't.
    private func start() -> Bool {
        guard !engine.isRunning else { return true }
        do {
            engine.prepare()
            try engine.start()
            return true
        } catch {
            SoundSession.log.error("Audio engine: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func load(_ asset: SoundAsset) -> AVAudioPCMBuffer? {
        if let buffer = buffers[asset] { return buffer }
        let buffer = library.buffer(asset)?.buffer
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
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: buffer.format)
        return node
    }

    /// After an interruption or a configuration change the engine is stopped and its nodes have lost their
    /// schedule: start it again and loop each audible layer afresh.
    private func restart() {
        for (layer, node) in loops {
            node.stop()
            if let buffer = buffers[layer.asset] { node.scheduleBuffer(buffer, at: nil, options: .loops) }
        }
        guard !gains.isSilent, start() else { return }
        for (layer, node) in loops where gains[layer] > 0 {
            node.volume = Float(gains[layer])
            node.play()
        }
    }

    /// Stops the engine once the race has been silent a while, so the menus run no audio engine.
    private func scheduleIdleStop() {
        let scheduled = generation
        queue.asyncAfter(deadline: .now() + Self.idleStopSeconds) { [self] in
            guard generation == scheduled, gains.isSilent, engine.isRunning else { return }
            for node in loops.values { node.stop() }
            for (layer, node) in loops {
                if let buffer = buffers[layer.asset] { node.scheduleBuffer(buffer, at: nil, options: .loops) }
            }
            engine.stop()
        }
    }
}
