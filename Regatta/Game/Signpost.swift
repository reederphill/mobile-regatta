import os

/// `os_signpost` intervals on Instruments' Points of Interest track, to measure the frame against the
/// #27 budgets (sim + prediction < 3 ms, bots < 2 ms). `-perf` launches a 16-boat race to profile.
nonisolated enum Signpost {
    /// One fixed simulation tick, `Race.step()`, bot brains included.
    case simStep
    /// The bot brains inside one tick.
    case botBrains
    /// Moving the SpriteKit nodes and camera for one frame.
    case renderUpdate
    /// Taking the SwiftUI HUD snapshot.
    case hudRefresh

    private static let signposter = OSSignposter(subsystem: "com.phillreeder.regatta", category: .pointsOfInterest)

    private var name: StaticString {
        switch self {
        case .simStep: "Sim step"
        case .botBrains: "Bot brains"
        case .renderUpdate: "Render update"
        case .hudRefresh: "HUD refresh"
        }
    }

    /// Runs `body` inside this interval.
    func measure<T>(_ body: () throws -> T) rethrows -> T {
        try Self.signposter.withIntervalSignpost(name, around: body)
    }
}
