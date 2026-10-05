import Foundation

/// The committee's start sequence on the race clock (#22): a horn at 60 s and 30 s, beeps at 5-4-3-2-1, the gun at 0.
/// Race time is negative before the gun. Stepped by `cues(at:)` each time the race ticks, so a paused race (no
/// ticks) fires nothing and `-timescale` keeps it in step with the HUD clock. Online it runs on the client's race
/// clock too, so the gun sounds as the clock shows 0, not a round trip later with the server's gun event.
struct SoundSchedule {
    struct Mark: Equatable {
        /// Race seconds, negative before the gun.
        let time: Double
        let cue: SoundCue
    }

    /// A first call fires only the marks this close before it: a late joiner at −45 s never hears the 60 s horn,
    /// and a race that starts its clock exactly on a mark hears it.
    static let firstCallWindow = 0.5

    /// In time order.
    let marks: [Mark]
    /// The latest race time stepped to: marks after it and up to the next time fire.
    private var lastTime: Double?

    /// The marks of a sequence `sequenceSeconds` long: a shorter one has no horns before it starts.
    init(sequenceSeconds: Double = 60) {
        let all = [Mark(time: -60, cue: .sequenceHorn), Mark(time: -30, cue: .sequenceHorn)]
            + (1...5).reversed().map { Mark(time: -Double($0), cue: .beep) }
            + [Mark(time: 0, cue: .gun)]
        marks = all.filter { -$0.time <= sequenceSeconds }
    }

    /// The cues of the marks after `from`, up to and including `to`.
    func cues(after from: Double, through to: Double) -> [SoundCue] {
        marks.filter { $0.time > from && $0.time <= to }.map(\.cue)
    }

    /// The cues due as the race clock reaches `time`. A clock set back (an online correction) never fires a mark
    /// twice.
    mutating func cues(at time: Double) -> [SoundCue] {
        let from = lastTime ?? time - Self.firstCallWindow
        lastTime = max(from, time)
        return cues(after: from, through: time)
    }
}
