import Foundation

/// What a notice is about (#114, #15): the HUD's one notice line carries these and nothing else. Today's other race
/// moments (the gun, a rounding, a finish) are felt as haptics, not read; your roll tack's result is read as well as seen
/// (`BoatNode`'s ring), since it is over in a moment.
enum NoticeKind: String, CaseIterable, Codable {
    case ocs, ruleCall, markRoom, roll, penalty, latency, hint
}

/// How each kind of notice behaves in the slot: a data table, so its order is read in one place (#114).
struct NoticeRule: Equatable {
    /// Higher shows first, and a higher one posted replaces a lower one showing.
    let priority: Int
    /// How long it shows.
    let seconds: Double
    /// How long it may wait behind another before it is dropped as stale. The clock stops while a live notice holds
    /// the slot (the Turn notice, for a whole penalty however many turns are stacked) and starts again when it goes.
    let maxWait: Double
    /// Its tone, by shape: no red or green (#5, #15).
    let symbol: String
    /// Hints wait while one of these is showing or waiting (#23).
    let holdsHints: Bool
}

enum NoticeTable {
    static let rows: [NoticeKind: NoticeRule] = [
        .ocs: NoticeRule(priority: 60, seconds: 6, maxWait: 2, symbol: "exclamationmark.triangle.fill", holdsHints: true),
        .ruleCall: NoticeRule(priority: 50, seconds: 6, maxWait: 6, symbol: "flag.fill", holdsHints: true),
        .markRoom: NoticeRule(priority: 40, seconds: 4, maxWait: 2, symbol: "circle.dashed", holdsHints: false),
        // How your roll tack went (#222): a moment, gone before it is stale.
        .roll: NoticeRule(priority: 35, seconds: 1.8, maxWait: 1, symbol: "arrow.triangle.2.circlepath", holdsHints: false),
        .penalty: NoticeRule(priority: 30, seconds: 5, maxWait: 4, symbol: "arrow.clockwise", holdsHints: false),
        .latency: NoticeRule(priority: 20, seconds: 10, maxWait: 30, symbol: "wifi.exclamationmark", holdsHints: false),
        // About 4 s (#23): one short line, read at a glance.
        .hint: NoticeRule(priority: 10, seconds: 4, maxWait: 60, symbol: "lightbulb", holdsHints: false),
    ]

    static func rule(_ kind: NoticeKind) -> NoticeRule {
        // Every kind has a row (`NoticeSlotTests`).
        rows[kind]!
    }
}

/// One short line under the top readouts (#15).
struct Notice: Equatable, Identifiable {
    let id: Int
    let kind: NoticeKind
    // TODO-COPY (#171): `RaceEventPresenter` owns the words (`RuleWords`).
    let text: String
    /// When it was posted, and when it stops showing (set once it shows).
    let posted: Date
    var expires: Date
    /// A live notice (`NoticeSlot.setLive`): its text updates in place, and it never expires or goes stale while set.
    var isLive = false
    /// When its wait for the slot last started, if not `posted`: when a live notice stopped holding the slot.
    var waitStart: Date?
    /// What a hint's thin leader line points at (#23), if it has one.
    var leader: HintTarget? = nil

    var symbol: String { NoticeTable.rule(kind).symbol }
}

/// The HUD's single notice slot (#114): one notice at a time, by `NoticeTable`'s priorities. A higher-priority notice
/// replaces the one showing (a replaced hint waits to show again; anything else is done); an equal or lower one
/// waits its turn, oldest first, until it goes stale. A hint never shows while a rule call or OCS notice is showing
/// or waiting (#23). Time is passed in, so it is deterministic.
struct NoticeSlot: Equatable {
    private(set) var showing: Notice?
    private(set) var waiting: [Notice] = []
    /// The id the next notice posted gets.
    private(set) var nextID = 0

    /// Posts `text` as a `kind` notice at `now`, with a hint's `leader`, and returns what shows.
    @discardableResult mutating func post(_ kind: NoticeKind, _ text: String, at now: Date,
                                          leader: HintTarget? = nil) -> Notice? {
        let notice = Notice(id: nextID, kind: kind, text: text, posted: now, expires: now, leader: leader)
        nextID += 1
        if let current = showing, NoticeTable.rule(kind).priority > NoticeTable.rule(current.kind).priority {
            if current.isLive { restartWaits(at: now) }
            if current.kind == .hint || current.isLive { waiting.insert(current, at: 0) }
            showing = nil
        }
        waiting.append(notice)
        return current(at: now)
    }

    /// Sets the live `kind` notice to `text` at `now`, or takes it down when `text` is nil (#123: the Turn countdown).
    /// A live notice updates its text in place, never expires or goes stale while set, and one a higher-priority
    /// notice replaces waits to show again, as a hint does. Otherwise it takes its turn by `NoticeTable` like any.
    mutating func setLive(_ kind: NoticeKind, text: String?, at now: Date) {
        guard let text else {
            if let shown = showing, shown.isLive, shown.kind == kind {
                showing = nil
                restartWaits(at: now)
            }
            waiting.removeAll { $0.isLive && $0.kind == kind }
            return
        }
        if let shown = showing, shown.isLive, shown.kind == kind {
            if shown.text != text { showing = shown.withText(text) }
            return
        }
        if let i = waiting.firstIndex(where: { $0.isLive && $0.kind == kind }) {
            waiting[i] = waiting[i].withText(text)
            return
        }
        let notice = Notice(id: nextID, kind: kind, text: text, posted: now, expires: .distantFuture, isLive: true)
        nextID += 1
        if let current = showing, NoticeTable.rule(kind).priority > NoticeTable.rule(current.kind).priority {
            if current.isLive { restartWaits(at: now) }
            if current.kind == .hint || current.isLive { waiting.insert(current, at: 0) }
            showing = nil
        }
        waiting.append(notice)
    }

    /// Shows `notice` as it is, expiry included: a render fixture's, which never expires.
    mutating func show(_ notice: Notice) {
        showing = notice
    }

    /// What shows at `now`: the one showing until it expires, then the next waiting.
    mutating func current(at now: Date) -> Notice? {
        if let shown = showing, shown.expires <= now { showing = nil }
        // While a live notice holds the slot, nothing waiting goes stale (#124: the RTT warning outlasts a penalty).
        if showing?.isLive != true {
            waiting.removeAll {
                !$0.isLive && ($0.waitStart ?? $0.posted).addingTimeInterval(NoticeTable.rule($0.kind).maxWait) < now
            }
        }
        if showing == nil, let next = nextEligible() {
            var notice = waiting.remove(at: next)
            notice.expires = notice.isLive ? .distantFuture : now.addingTimeInterval(NoticeTable.rule(notice.kind).seconds)
            showing = notice
        }
        return showing
    }

    /// The race came on screen at `now` (#129): the notice showing gets its full time from here and every wait starts
    /// again, so what was posted as the race was set up (the steering hint) isn't spent before it could be seen.
    mutating func restartClock(at now: Date) {
        if var shown = showing, !shown.isLive {
            shown.expires = now.addingTimeInterval(NoticeTable.rule(shown.kind).seconds)
            showing = shown
        }
        restartWaits(at: now)
    }

    /// A live notice stopped holding the slot at `now`: every wait starts again from there.
    private mutating func restartWaits(at now: Date) {
        for i in waiting.indices { waiting[i].waitStart = now }
    }

    /// The waiting notice to show next: the highest priority, oldest first; a hint only when nothing that holds
    /// hints is waiting (or showing, which the caller has checked).
    private func nextEligible() -> Int? {
        let holding = waiting.contains { NoticeTable.rule($0.kind).holdsHints }
        var best: Int?
        for (i, notice) in waiting.enumerated() {
            if notice.kind == .hint && holding { continue }
            if let b = best, NoticeTable.rule(waiting[b].kind).priority >= NoticeTable.rule(notice.kind).priority { continue }
            best = i
        }
        return best
    }
}

private extension Notice {
    func withText(_ text: String) -> Notice {
        Notice(id: id, kind: kind, text: text, posted: posted, expires: expires, isLive: isLive, waitStart: waitStart,
               leader: leader)
    }
}
