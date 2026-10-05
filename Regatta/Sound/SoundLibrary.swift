import AVFoundation

/// Where each sound comes from (#53, #126): the bundled file by its manifest name, flat in the bundle or under
/// `Audio/`, once #169 adds it; until then a placeholder generated in code (`PlaceholderSound`). #169's test is
/// `SoundAsset.allCases.allSatisfy { !library.isPlaceholder($0) }`.
nonisolated struct SoundLibrary: Sendable {
    let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    /// The bundled file of `asset`, if there is one.
    func bundledURL(_ asset: SoundAsset) -> URL? {
        bundle.url(forResource: asset.rawValue, withExtension: asset.fileExtension)
            ?? bundle.url(forResource: asset.rawValue, withExtension: asset.fileExtension, subdirectory: "Audio")
    }

    /// `asset` has no bundled file and plays a generated placeholder.
    func isPlaceholder(_ asset: SoundAsset) -> Bool { bundledURL(asset) == nil }

    /// A one-shot's or loop's samples: the bundled file's, or the placeholder's. Slow the first time (it decodes or
    /// synthesises): call it off the main thread.
    func buffer(_ asset: SoundAsset) -> (buffer: AVAudioPCMBuffer, isPlaceholder: Bool)? {
        if let url = bundledURL(asset), let buffer = Self.read(url) { return (buffer, false) }
        return PlaceholderSound.buffer(asset).map { ($0, true) }
    }

    /// The music's file: the bundled one, or the placeholder, written to the temporary directory. A file already
    /// there is reused only if it's whole (the placeholder's format and length); otherwise it's written afresh, to a
    /// scratch file first and then moved into place, so a write cut short never leaves a broken file to reuse.
    func musicURL(directory: URL = FileManager.default.temporaryDirectory) -> URL? {
        if let url = bundledURL(.menuMusic) { return url }
        let url = directory.appending(path: Self.placeholderMusicName)
        if Self.isWholePlaceholderMusic(url) { return url }
        guard let buffer = PlaceholderSound.buffer(.menuMusic) else { return nil }
        let scratch = directory.appending(path: "\(UUID().uuidString).caf")
        do {
            do {
                let file = try AVAudioFile(forWriting: scratch, settings: buffer.format.settings)
                try file.write(from: buffer)
            }  // The file closes here, before it's checked and moved.
            guard Self.isWholePlaceholderMusic(scratch) else {
                try? FileManager.default.removeItem(at: scratch)
                SoundSession.log.error("Placeholder music: the written file is incomplete")
                return nil
            }
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: scratch)
            } else {
                try FileManager.default.moveItem(at: scratch, to: url)
            }
            return url
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            SoundSession.log.error("Placeholder music: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// The placeholder music's file name: versioned, so a change to the placeholder never reuses an old file.
    static let placeholderMusicName = "menu-music-placeholder-2.caf"

    /// Whether `url` holds the whole placeholder music: its sample rate, channels and length.
    static func isWholePlaceholderMusic(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let file = try? AVAudioFile(forReading: url) else { return false }
        let format = file.fileFormat
        return format.sampleRate == PlaceholderSound.sampleRate && format.channelCount == 1
            && file.length == AVAudioFramePosition(PlaceholderSound.musicFrameCount)
    }

    private static func read(_ url: URL) -> AVAudioPCMBuffer? {
        do {
            let file = try AVAudioFile(forReading: url)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
            try file.read(into: buffer)
            return buffer
        } catch {
            SoundSession.log.error("Sound \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

/// Placeholder sounds generated in code until #54's recordings arrive (#169 deletes this): a few formulas, short
/// loops, no tuning. Deterministic, so every run sounds the same.
nonisolated enum PlaceholderSound {
    static let sampleRate = 44_100.0

    static func buffer(_ asset: SoundAsset) -> AVAudioPCMBuffer? {
        let samples = self.samples(asset)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (i, sample) in samples.enumerated() { channel[i] = sample }
        return buffer
    }

    static func samples(_ asset: SoundAsset) -> [Float] {
        var noise = Noise(seed: UInt64(asset.rawValue.unicodeScalars.reduce(7) { $0 &* 31 &+ UInt64($1.value) }))
        switch asset {
        case .horn:
            // A low blast with a harmonic.
            return tone(seconds: 1.4, attack: 0.05, release: 0.2) { (t: Double) -> Double in
                0.5 * sine(233, t) + 0.25 * sine(466, t) + 0.1 * sine(699, t)
            }
        case .gun:
            // A noise burst, decaying fast.
            return (0..<frames(0.7)).map { (i: Int) -> Float in
                let decay: Double = exp(-Double(i) / sampleRate * 9)
                return Float(noise.next() * decay * 0.9)
            }
        case .beep:
            return tone(seconds: 0.15, attack: 0.005, release: 0.02) { (t: Double) -> Double in 0.5 * sine(880, t) }
        case .whistle:
            // A pea whistle's warble.
            return tone(seconds: 0.6, attack: 0.02, release: 0.08) { (t: Double) -> Double in
                let warble: Double = 4 * sine(28, t)
                return 0.4 * sin(2 * Double.pi * (2800 * t + warble))
            }
        case .bell:
            return (0..<frames(1.6)).map { (i: Int) -> Float in
                let t = Double(i) / sampleRate
                let ring: Double = 0.35 * sine(1046, t) + 0.12 * sine(2793, t)
                return Float(ring * exp(-t * 2.5))
            }
        case .windLight: return loop(seconds: 4, noise: &noise, smoothing: 0.02, level: 0.5, flutter: 0.3)
        case .windMedium: return loop(seconds: 4, noise: &noise, smoothing: 0.06, level: 0.45, flutter: 0.4)
        case .windStrong: return loop(seconds: 4, noise: &noise, smoothing: 0.15, level: 0.4, flutter: 0.5)
        case .waterSlow: return loop(seconds: 4, noise: &noise, smoothing: 0.04, level: 0.5, flutter: 0.6)
        case .waterFast: return loop(seconds: 4, noise: &noise, smoothing: 0.25, level: 0.35, flutter: 0.3)
        case .sailFlog:
            // Noise gated into flaps, ~6 a second.
            let raw = (0..<frames(2)).map { i -> Double in
                let t = Double(i) / sampleRate
                let flap: Double = max(0, sine(6, t))
                return noise.next() * pow(flap, 3) * 0.6
            }
            return seamless(raw)
        case .menuMusic:
            // A slow pad: an A minor chord, breathing.
            let notes = [220.0, 261.63, 329.63, 440.0]
            let raw = (0..<frames(musicSeconds)).map { i -> Double in
                let t = Double(i) / sampleRate
                let swell: Double = 0.6 + 0.4 * sine(1.0 / musicSeconds, t)
                let chord: Double = notes.reduce(0) { $0 + sine($1, t) }
                return chord * 0.06 * swell
            }
            // The chord's notes don't complete whole cycles in the loop: crossfade its end into its start.
            return seamless(raw)
        }
    }

    /// The placeholder music's length before its loop crossfade.
    static let musicSeconds = 8.0
    /// The placeholder music's frames: `musicSeconds` less its loop crossfade (`seamless`).
    static var musicFrameCount: Int { frames(musicSeconds) - min(frames(loopFadeSeconds), frames(musicSeconds) / 2) }
    /// How much of a loop's end `seamless` crossfades into its start.
    static let loopFadeSeconds = 0.25

    private static func frames(_ seconds: Double) -> Int { Int(seconds * sampleRate) }

    /// A sine of `frequency` Hz at `t` seconds.
    private static func sine(_ frequency: Double, _ t: Double) -> Double { sin(2 * Double.pi * frequency * t) }

    private static func tone(seconds: Double, attack: Double, release: Double, _ wave: (Double) -> Double) -> [Float] {
        (0..<frames(seconds)).map { i in
            let t = Double(i) / sampleRate
            let envelope = min(1, t / attack, (seconds - t) / release)
            return Float(wave(t) * max(0, envelope))
        }
    }

    /// Low-passed noise (`smoothing` the one-pole filter's coefficient: smaller is darker), slowly swelling.
    private static func loop(seconds: Double, noise: inout Noise, smoothing: Double, level: Double,
                             flutter: Double) -> [Float] {
        var y = 0.0
        let raw = (0..<frames(seconds)).map { i -> Double in
            y += smoothing * (noise.next() - y)
            let t = Double(i) / sampleRate
            let swell: Double = 1 - flutter * 0.5 * (1 + sine(2 / seconds, t))
            return y * swell
        }
        let peak = raw.map(abs).max() ?? 1
        return seamless(raw.map { $0 / max(peak, 1e-6) * level })
    }

    /// `raw` with its last quarter second crossfaded into its start, so it loops without a click.
    private static func seamless(_ raw: [Double]) -> [Float] {
        let fade = min(frames(loopFadeSeconds), raw.count / 2)
        let count = raw.count - fade
        return (0..<count).map { i in
            guard i < fade else { return Float(raw[i]) }
            let t = Double(i) / Double(fade)
            return Float(raw[i] * t + raw[count + i] * (1 - t))
        }
    }

    /// A small deterministic noise source, −1…1.
    struct Noise {
        var state: UInt64
        init(seed: UInt64) { state = seed | 1 }
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let bits = Int64(bitPattern: (state >> 11) << 11)
            return Double(bits) / Double(Int64.max)
        }
    }
}
