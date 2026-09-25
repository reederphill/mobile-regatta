/// How a human seat stopped counting as there (G3, #66).
public enum GoneKind: Hashable, Sendable, CaseIterable {
    /// Its inputs stopped for longer than the input hold, and it hasn't rejoined.
    case dropped
    /// It left, before or after the gun.
    case left
}

/// When the host calls the race's humans all gone (G3, #66). Server config: the defaults are G3's.
public struct AllGoneConfig: Hashable, Sendable {
    /// Which ways of going count. A human seat gone some other way keeps the race going.
    public var goneKinds: Set<GoneKind> = [.dropped, .left]
    /// Ticks between the last human going and the trigger (G3: 30 s). A rejoin in between cancels it.
    public var graceTicks = 900
    /// At least 2 humans all dropping within this many ticks, and none leaving, is a mass drop (G3: 2 s).
    public var massDropWindowTicks = 60

    public init() {}
}

/// The all-gone trigger (G3): every human seat gone, and the grace over. The host doesn't close the race
/// itself; its `onAllGone` hook does (#148): a normal close, or a cancel for a mass drop.
public struct AllGone: Hashable, Sendable {
    /// The tick the grace ran out: the last simulated tick when the hook fired.
    public var tick: Int
    /// The human seats in the order they went, first gone first (G3: the RET order).
    public var leaveOrder: [Int]
    /// At least 2 humans, all dropped within `massDropWindowTicks` of each other, none left (G3).
    public var isMassDrop: Bool

    public init(tick: Int, leaveOrder: [Int], isMassDrop: Bool) {
        self.tick = tick
        self.leaveOrder = leaveOrder
        self.isMassDrop = isMassDrop
    }
}
