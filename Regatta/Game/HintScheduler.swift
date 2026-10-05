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

    /// The first of `eligible` (catalogue order) to post now, or nil: `canPick`, and not retired.
    func pick(_ eligible: [HintID], slot: NoticeSlot, now: Date, hintsOn: Bool, progress: HintProgressStore) -> HintID? {
        guard canPick(slot: slot, now: now, hintsOn: hintsOn) else { return nil }
        return eligible.first { !progress.isRetired($0) }
    }

    /// Whether a hint may post now: hints on, no hint in the slot or posted, nothing that holds hints showing or
    /// waiting, and the gap since the last one passed.
    func canPick(slot: NoticeSlot, now: Date, hintsOn: Bool) -> Bool {
        guard hintsOn, tracked == nil else { return false }
        if let showing = slot.showing, Self.blocks(showing) { return false }
        guard !slot.waiting.contains(where: Self.blocks) else { return false }
        if let lastEnded, now.timeIntervalSince(lastEnded) < Self.gapSeconds { return false }
        return true
    }

    private static func blocks(_ notice: Notice) -> Bool {
        notice.kind == .hint || NoticeTable.rule(notice.kind).holdsHints
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
/// and drained events (online, the prediction and the server's events), never the race. One per race: the app makes
/// a fresh one for each session.
final class HintEngine {
    let progress: HintProgressStore
    /// The triggers' thresholds: the debug tuning panel's when it's open (ruling 3).
    var thresholds: HintTuning
    /// Told once per hint as it retires (#128's `hint_retired`). Never on Reset hints.
    var onRetired: ((HintID, HintRetirement) -> Void)?
    /// The triggers are worked out at most this often, seconds of wall-clock time: puffs and laylines cost.
    static let evaluateInterval = 0.25
    /// Hints that show once a race, however long their situation lasts: the steering hint, up from the first frame.
    static let oncePerRace: Set<HintID> = [.raceStart]

    private(set) var scheduler = HintScheduler()
    private(set) var observations = HintObservations()
    private var lastEvaluated: Date?
    /// Hints posted this episode of their situation (#129): not posted again until their trigger has been off for
    /// `HintTuning.rearmSeconds`, so a situation that lasts shows its hint once, not every gap.
    private(set) var spent: Set<HintID> = []
    /// Since when each spent hint's trigger has been off.
    private var offSince: [HintID: Date] = [:]
    /// The once-a-race hints posted this race.
    private var postedThisRace: Set<HintID> = []
    /// The held steering hint's notice (owner ruling 2026-10-05): in the first race it stays up until you first steer.
    private(set) var heldNoticeID: Int?
    /// A held notice the session is to take down: you've steered, or hints went off.
    private var pendingTakeDown: Int?

    /// The rows it schedules, in priority order: the catalogue's engine rows (tests pass their own).
    let catalogue: [Hint]

    /// This race is the device's first: the steering hint has never shown on it. The app's engines say so (`AppModel`),
    /// until #134's first race sets `GameSession.isFirstRace`; tests' don't unless they ask.
    let isFirstRaceOnDevice: Bool

    init(progress: HintProgressStore, thresholds: HintTuning = .standard, catalogue: [Hint] = HintCatalogue.engine,
         isFirstRaceOnDevice: Bool = false) {
        self.progress = progress
        self.thresholds = thresholds
        self.catalogue = catalogue
        self.isFirstRaceOnDevice = isFirstRaceOnDevice
    }

    /// Whether `progress` is a device's before its first race: the steering hint has never shown.
    static func isFirstRace(_ progress: HintProgressStore) -> Bool {
        progress.timesShown(.raceStart) == 0
    }

    /// Whether the steering hint, posted now, is held up until you steer (owner ruling 2026-10-05): in the first
    /// race, the one `isFirstRace` marks or the device's first (`isFirstRaceOnDevice`). It still gives way to rule
    /// calls and OCS and comes back after them. Later races show it for its usual time, until you've steered both
    /// ways or it has shown twice.
    func holdsSteeringHint(isFirstRace: Bool) -> Bool {
        isFirstRace || isFirstRaceOnDevice
    }

    /// One HUD refresh at `now`: settles the posted hint with `slot`, takes `world`'s tick, retires what you've
    /// learned, and returns the hint to post now, if any, with its leader and whether it is held (shown until it is
    /// learned, `takeDownDue`). With hints off it only settles: nothing is observed, learned or picked.
    func refresh(world: RenderWorld, slot: NoticeSlot, now: Date, hintsOn: Bool, showsLaylines: Bool,
                 isFirstRace: Bool) -> (hint: Hint, leader: HintTarget?, held: Bool)? {
        if let retired = scheduler.settle(slot: slot, now: now, progress: progress) { onRetired?(retired, .shownTwice) }
        guard hintsOn else {
            observations.pause()
            releaseHeld()
            return nil
        }
        observations.observe(world, tuning: thresholds)
        // The held steering hint goes on your first steer, and retires as learned.
        if heldNoticeID != nil, observations.hasSteered {
            if scheduler.learn(.raceStart, hintsOn: hintsOn, progress: progress) { onRetired?(.raceStart, .learned) }
            releaseHeld()
        }
        if observations.steeredBothWays(thresholds) { learn(.steeredBothWays, hintsOn: hintsOn) }
        if observations.hasLetGo { learn(.autohelmHeld, hintsOn: hintsOn) }

        if let lastEvaluated, now.timeIntervalSince(lastEvaluated) < Self.evaluateInterval { return nil }
        let canPick = scheduler.canPick(slot: slot, now: now, hintsOn: hintsOn)
        // Spent hints are watched to re-arm them even while none can post.
        guard canPick || !spent.isEmpty else { return nil }
        lastEvaluated = now
        let snapshot = HintSnapshot(world: world, observations: observations, showsLaylines: showsLaylines,
                                    isFirstRace: isFirstRace, lettingGoRetired: progress.isRetired(.lettingGo),
                                    tuning: thresholds)
        var chosen: (hint: Hint, leader: HintTarget?, held: Bool)?
        for hint in catalogue {
            let id = hint.id
            if progress.isRetired(id) {
                spent.remove(id)
                offSince[id] = nil
                continue
            }
            if Self.oncePerRace.contains(id) && postedThisRace.contains(id) { continue }
            let firing = hint.trigger(snapshot, thresholds)
            if spent.contains(id) {
                rearm(id, firing: firing != nil, now: now)
                continue
            }
            if canPick, chosen == nil, let firing {
                chosen = (hint, firing.leader, id == .raceStart && holdsSteeringHint(isFirstRace: isFirstRace))
            }
        }
        return chosen
    }

    /// The held notice to take down now, once: you've steered, or hints went off.
    func takeDownDue() -> Int? {
        defer { pendingTakeDown = nil }
        return pendingTakeDown
    }

    private func releaseHeld() {
        guard let held = heldNoticeID else { return }
        pendingTakeDown = held
        heldNoticeID = nil
    }

    /// A spent hint whose trigger has been off `rearmSeconds` may post again.
    private func rearm(_ id: HintID, firing: Bool, now: Date) {
        guard !firing else {
            offSince[id] = nil
            return
        }
        guard let since = offSince[id] else {
            offSince[id] = now
            return
        }
        if now.timeIntervalSince(since) >= thresholds.rearmSeconds {
            spent.remove(id)
            offSince[id] = nil
        }
    }

    /// The hint `id` was posted as notice `noticeID`, `held` as `refresh` said.
    func posted(_ id: HintID, noticeID: Int, held: Bool = false) {
        scheduler.posted(id, noticeID: noticeID)
        if held { heldNoticeID = noticeID }
        if Self.oncePerRace.contains(id) {
            postedThisRace.insert(id)
        } else {
            spent.insert(id)
            offSince[id] = nil
        }
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
        for hint in catalogue where hint.learning == learning {
            if scheduler.learn(hint.id, hintsOn: hintsOn, progress: progress) { onRetired?(hint.id, .learned) }
        }
    }
}
