import SpriteKit
import Testing
import RegattaCore
@testable import Regatta

/// The race's pace line for UI tests on a slow CI runner (#361).
@MainActor @Suite struct PaceMeterTests {
    private let start = ContinuousClock.now

    private func at(_ seconds: Double) -> ContinuousClock.Instant { start + .milliseconds(Int(seconds * 1000)) }

    @Test func beforeTheFirstFrameItReportsNothingAndNeverDividesByZero() {
        let meter = PaceMeter()
        #expect(meter.frames == 0 && meter.ticks == 0 && meter.wallSeconds == 0)
        #expect(meter.slowestWindowRate == nil)
        #expect(meter.summary == "pace: 0.0 s wall, 0 ticks (0/s, slowest 10 s window none yet), 0 frames (0.0/s), "
                + "ticks 0.0 ms/frame, render 0.0 ms/frame")
    }

    @Test func totalsTicksFramesAndTimes() {
        var meter = PaceMeter()
        meter.record(ticks: 0, tickTime: .milliseconds(1), renderTime: .milliseconds(2), at: at(0))
        meter.record(ticks: 6, tickTime: .milliseconds(5), renderTime: .milliseconds(1), at: at(1))
        meter.record(ticks: 4, tickTime: .milliseconds(3), renderTime: .milliseconds(3), at: at(2))
        #expect(meter.frames == 3)
        #expect(meter.ticks == 10)
        #expect(meter.tickTime == .milliseconds(9))
        #expect(meter.renderTime == .milliseconds(6))
        #expect(meter.wallSeconds == 2)
        #expect(meter.slowestWindowRate == nil, "no 10 s window has completed")
        #expect(meter.summary == "pace: 2.0 s wall, 10 ticks (5/s, slowest 10 s window none yet), 3 frames (1.5/s), "
                + "ticks 3.0 ms/frame, render 2.0 ms/frame")
    }

    /// Three 10 s windows at 100, 25 and 60 ticks/s, then a slow part-window that doesn't count yet.
    @Test func reportsTheSlowestCompleteWindow() {
        var meter = PaceMeter()
        meter.record(ticks: 0, tickTime: .zero, renderTime: .zero, at: at(0))
        for (window, rate) in [100, 25, 60].enumerated() {
            for second in 1...10 {
                meter.record(ticks: rate, tickTime: .zero, renderTime: .zero, at: at(Double(window * 10 + second)))
            }
        }
        meter.record(ticks: 1, tickTime: .zero, renderTime: .zero, at: at(35))
        #expect(meter.slowestWindowRate == 25)
        #expect(meter.ticks == 1_851)
        #expect(meter.summary.hasPrefix("pace: 35.0 s wall, 1851 ticks (53/s, slowest 10 s window 25/s), 32 frames"))
    }
}

/// `-hideScene` (#361) and the scene's own pace.
@MainActor @Suite struct GameScenePaceTests {
    private static let config = RaceConfig(opponents: 3, prestartSeconds: 60, seed: 1, windSeed: RaceConfig.windSeed(pinnedTo: 1))

    /// The scene holds its session weakly: keep the session.
    private static func presented() -> GameSession {
        let session = GameSession(config: config)
        SKView(frame: CGRect(x: 0, y: 0, width: 402, height: 874)).presentScene(session.scene)
        return session
    }

    /// The world (every layer, the water's included) and the camera (the edge arrow) stop drawing, and come back.
    @Test func paintsWorldHidesTheWorldAndTheCamera() throws {
        let session = Self.presented()
        let scene = session.scene
        let world = try #require(scene.childNode(withName: "//water")?.parent)
        let cam = try #require(scene.camera)
        #expect(scene.children.contains(world) && scene.children.contains(cam))
        #expect(scene.paintsWorld && !world.isHidden && !cam.isHidden, "a normal launch paints")

        scene.paintsWorld = false
        #expect(world.isHidden && cam.isHidden)
        #expect(scene.children.filter { !$0.isHidden }.isEmpty, "nothing in the scene is left to draw")

        scene.paintsWorld = true
        #expect(!world.isHidden && !cam.isHidden)
    }

    /// Each frame that steps the race counts its ticks, and the pace line names the race clock's tick.
    @Test func framesThatStepTheRaceRecordTheirPace() {
        let session = Self.presented()
        let scene = session.scene
        let before = scene.driver.currentFrame.tick
        scene.update(10)
        scene.update(10.1)
        scene.update(10.2)
        #expect(scene.pace.frames == 3)
        #expect(scene.pace.ticks > 0)
        #expect(scene.pace.ticks == scene.driver.currentFrame.tick - before, "every tick the frames ran")
        #expect(scene.paceSummary.hasSuffix(", race tick \(scene.driver.currentFrame.tick)"))
    }
}
