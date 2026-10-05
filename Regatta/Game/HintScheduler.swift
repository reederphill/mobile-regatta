import Foundation
import RegattaCore
import RegattaServices

/// Each hint's progress on this device (#23): how many times it has shown, and whether you've learned it. Kept under
/// `DeviceSettings.hintKeyPrefix`, so Settings' Reset hints clears it; read through every call, never cached, so a
/// reset takes effect at once. In memory (tests, fixtures, UI tests) unless given defaults, as `RuleSeenStore`.
final class HintProgressStore {
    static func shownKey(_ id: HintID) -> String { DeviceSettings.hintKeyPrefix + "shown." + id.rawValue }
    static func learnedKey(_ id: HintID) -> String { DeviceSettings.hintKeyPrefix + "learned." + id.rawValue }

    private let defaults: UserDefaults?
    private var memory: [String: Any] = [:]

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
    }

    func timesShown(_ id: HintID) -> Int {
        value(forKey: Self.shownKey(id)) as? Int ?? 0
    }

    /// Counts one more showing, and returns the count.
    @discardableResult func markShown(_ id: HintID) -> Int {
        let count = timesShown(id) + 1
        set(count, forKey: Self.shownKey(id))
        return count
    }

    func isLearned(_ id: HintID) -> Bool {
        value(forKey: Self.learnedKey(id)) as? Bool ?? false
    }

    func markLearned(_ id: HintID) {
        set(true, forKey: Self.learnedKey(id))
    }

    /// The hint shows no more: learned, or shown its two times.
    func isRetired(_ id: HintID) -> Bool {
        isLearned(id) || timesShown(id) >= HintScheduler.showsBeforeRetiring
    }

    private func value(forKey key: String) -> Any? {
        if let defaults { return defaults.object(forKey: key) }
        return memory[key]
    }

    private func set(_ value: Any, forKey key: String) {
        if let defaults { defaults.set(value, forKey: key) } else { memory[key] = value }
    }
}

/// When hints show (#23): one at a time in the notice slot, about 4 s each (`NoticeTable`), at least `gapSeconds`
/// after the last one went, never while a rule call or OCS notice shows or waits, never paused for and never tapped.
/// A hint counts as shown once its notice shows, not if the slot drops it stale; it retires once learned or shown
/// twice. Time and the slot are passed in, so it is deterministic.
struct HintScheduler: Equatable {
    /// Seconds from one hint going to the next showing.
    static let gapSeconds = 3.0
    /// A hint retires once it has shown this many times.
    static let showsBeforeRetiring = 2

    /// The hint posted to the slot and not yet gone: its notice's id, and whether its showing has been counted.
    struct Tracked: Equatable {
        let id: HintID
        let noticeID: Int
        var counted = false
    }

    private(set) var tracked: Tracked?
    /// When the last hint went from the slot (shown out, replaced and gone, or dropped stale).
    private(set) var lastEnded: Date?

    /// The first of `eligible` (catalogue order) to post now, or nil: hints on, no hint in the slot or posted, nothing
    /// that holds hints showing or waiting, the gap since the last one passed, and not retired.
    func pick(_ eligible: [HintID], slot: NoticeSlot, now: Date, hintsOn: Bool, progress: HintProgressStore) -> HintID? {
        guard hintsOn, tracked == nil else { return nil }
        let inSlot = [slot.showing].compactMap { $0 } + slot.waiting
        guard !inSlot.contains(where: { $0.kind == .hint || NoticeTable.rule($0.kind).holdsHints }) else { return nil }
        if let lastEnded, now.timeIntervalSince(lastEnded) < Self.gapSeconds { return nil }
        return eligible.first { !progress.isRetired($0) }
    }

    /// `id` was posted as notice `noticeID`.
    mutating func posted(_ id: HintID, noticeID: Int) {
        tracked = Tracked(id: id, noticeID: noticeID)
    }

    /// Follows the posted hint through `slot` at `now`: counts its first showing, and lets it go once it has left
    /// the slot. Returns the hint if that showing retired it (its second).
    mutating func settle(slot: NoticeSlot, now: Date, progress: HintProgressStore) -> HintID? {
        guard let current = tracked else { return nil }
        if slot.showing?.id == current.noticeID {
            guard !current.counted else { return nil }
            tracked?.counted = true
            let wasRetired = progress.isRetired(current.id)
            let shown = progress.markShown(current.id)
            return !wasRetired && shown >= Self.showsBeforeRetiring ? current.id : nil
        }
        if slot.waiting.contains(where: { $0.id == current.noticeID }) { return nil }
        tracked = nil
        lastEnded = now
        return nil
    }

    /// You've done what `id` teaches: it retires, unless it already has or hints are off (progress stands still).
    /// Returns whether this retired it.
    func learn(_ id: HintID, hintsOn: Bool, progress: HintProgressStore) -> Bool {
        guard hintsOn, !progress.isRetired(id) else { return false }
        progress.markLearned(id)
        return true
    }
}

/// One race's hints (#129): what it has seen of your boat, the scheduler, and the device's progress. `GameSession`
/// asks it at each HUD refresh which hint to post, and feeds it the race's events; it reads only the driver's frames
/// and drained events (online, the prediction and the server's events), never the race.
final class HintEngine {
    let progress: HintProgressStore
    /// The triggers' thresholds: the debug tuning panel's when it's open (ruling 3).
    var thresholds: HintTuning
    /// Told once per hint as it retires (#128's `hint_retired`). Never on Reset hints.
    var onRetired: ((HintID, HintRetirement) -> Void)?
    /// The triggers are worked out at most this often, seconds of wall-clock time: puffs and laylines cost.
    static let evaluateInterval = 0.25

    private(set) var scheduler = HintScheduler()
    private(set) var observations = HintObservations()
    private var lastEvaluated: Date?

    init(progress: HintProgressStore, thresholds: HintTuning = .standard) {
        self.progress = progress
        self.thresholds = thresholds
    }

    /// One HUD refresh at `now`: settles the posted hint with `slot`, takes `world`'s tick, retires what you've
    /// learned, and returns the hint to post now, if any, with its leader.
    func refresh(world: RenderWorld, slot: NoticeSlot, now: Date, hintsOn: Bool, showsLaylines: Bool,
                 isFirstRace: Bool) -> (hint: Hint, leader: HintTarget?)? {
        if let retired = scheduler.settle(slot: slot, now: now, progress: progress) { onRetired?(retired, .shownTwice) }
        guard hintsOn else { return nil }
        observations.observe(world, tuning: thresholds)
        if observations.steeredBothWays(thresholds) { learn(.steeredBothWays, hintsOn: hintsOn) }
        if observations.hasLetGo { learn(.autohelmHeld, hintsOn: hintsOn) }

        guard scheduler.pick(HintCatalogue.engine.map(\.id), slot: slot, now: now, hintsOn: hintsOn,
                             progress: progress) != nil else { return nil }
        if let lastEvaluated, now.timeIntervalSince(lastEvaluated) < Self.evaluateInterval { return nil }
        lastEvaluated = now
        let snapshot = HintSnapshot(world: world, observations: observations, showsLaylines: showsLaylines,
                                    isFirstRace: isFirstRace, lettingGoRetired: progress.isRetired(.lettingGo),
                                    tuning: thresholds)
        var firings: [HintID: HintFiring] = [:]
        let eligible = HintCatalogue.engine.compactMap { hint -> HintID? in
            guard !progress.isRetired(hint.id), let firing = hint.trigger(snapshot, thresholds) else { return nil }
            firings[hint.id] = firing
            return hint.id
        }
        guard let id = scheduler.pick(eligible, slot: slot, now: now, hintsOn: hintsOn, progress: progress) else {
            return nil
        }
        return (HintCatalogue.hint(id), firings[id]?.leader)
    }

    /// The hint `id` was posted as notice `noticeID`.
    func posted(_ id: HintID, noticeID: Int) {
        scheduler.posted(id, noticeID: noticeID)
    }

    /// The race's events: what you did that a hint teaches (tacked, rounded, the autohelm snapped to the groove).
    func consume(_ events: [RaceEvent], me: Int, hintsOn: Bool) {
        for event in events {
            switch event.kind {
            case .tacked(me): learn(.tacked, hintsOn: hintsOn)
            case .rounded(me, _): learn(.rounded, hintsOn: hintsOn)
            case .grooveSnap(me):
                if hintsOn { observations.noteGrooveSnap() }
                learn(.autohelmHeld, hintsOn: hintsOn)
            default: break
            }
        }
    }

    private func learn(_ learning: HintLearning, hintsOn: Bool) {
        for hint in HintCatalogue.engine where hint.learning == learning {
            if scheduler.learn(hint.id, hintsOn: hintsOn, progress: progress) { onRetired?(hint.id, .learned) }
        }
    }
}
