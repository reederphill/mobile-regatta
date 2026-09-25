import Foundation
import Testing
import RegattaBots
import RegattaCore
@testable import Regatta

/// Render fixtures (#62): the committed fixtures load and replay, and a fixture race stands still.
@MainActor @Suite struct RenderFixtureTests {
    /// The UI tests' fixtures folder, read from the host as the app reads it.
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("RegattaUITests/Fixtures")

    @Test func committedFixturesLoadAndReplayToTheirFreezeTick() throws {
        let (fixture, log) = try RenderFixture.load(named: "prestart", in: Self.fixtures)
        #expect(fixture == RenderFixture(log: "prestart.racelog.json", freezeTick: -1500, camera: .boat, vision: .none))
        let driver = try FixtureDriver(log: log, freezeTick: fixture.freezeTick)
        #expect(driver.currentFrame.tick == -1500)
        #expect(driver.currentFrame.boats.count == 8)

        let (moved, _) = try RenderFixture.load(named: "prestart-moved", in: Self.fixtures)
        let later = try FixtureDriver(log: log, freezeTick: moved.freezeTick)
        #expect(later.currentFrame.tick == moved.freezeTick)
        #expect(later.currentFrame.tick > driver.currentFrame.tick)
        // The fleet, your boat included, has moved on: the moved fixture draws a different picture.
        let moves = zip(driver.currentFrame.boats, later.currentFrame.boats).map { ($0.position - $1.position).length }
        #expect(moves[driver.myBoatIndex] > 1, "your boat moved \(moves[driver.myBoatIndex]) m")
        #expect(moves.filter { $0 > 1 }.count >= moves.count / 2, "boats moved \(moves) m")
    }

    /// Freezing at a tick is the same race as replaying the log cut off there.
    @Test func theFreezeTickIsTheLogReplayedToIt() throws {
        let (_, log) = try RenderFixture.load(named: "prestart", in: Self.fixtures)
        var cut = log
        cut.inputs.removeAll { $0.tick > -1600 }
        cut.finalTick = -1600
        let replayed = try Replayer.replay(cut, requireMatchingVersion: false)
        let frozen = try FixtureDriver(log: log, freezeTick: -1600)
        #expect(frozen.currentFrame.boats.map(\.position) == replayed.boats.map(\.position))
    }

    @Test func aFixtureRaceStandsStill() throws {
        let (_, log) = try RenderFixture.load(named: "prestart", in: Self.fixtures)
        let driver = try FixtureDriver(log: log, freezeTick: -1500)
        let before = driver.renderWorld
        #expect(driver.isFrozen)
        #expect(!driver.isPausable)
        #expect(driver.tick(5).isEmpty)
        driver.submit(BoatInput(rudder: 1.0))
        #expect(!driver.tap(.tackGybe))
        #expect(driver.drainEvents().isEmpty)
        let after = driver.renderWorld
        #expect(after.frame.tick == -1500)
        #expect(after.time == before.time)
        #expect(after.boats.map(\.position) == driver.currentFrame.boats.map(\.position))
        #expect(!PracticeDriver(config: RaceDriverTests.config).isFrozen)
    }

    @Test func aFreezeTickOutsideTheLogIsRefused() throws {
        let (_, log) = try RenderFixture.load(named: "prestart", in: Self.fixtures)
        #expect(throws: FixtureDriver.FixtureError.self) { try FixtureDriver(log: log, freezeTick: log.finalTick + 1) }
        #expect(throws: FixtureDriver.FixtureError.self) { try FixtureDriver(log: log, freezeTick: -1801) }
    }

    @Test func loadingNeedsTheFixturesDirectory() {
        #expect(throws: RenderFixture.LoadError.self) { try RenderFixture.load(named: "prestart", environment: [:]) }
        #expect(throws: RenderFixture.LoadError.self) {
            try RenderFixture.load(named: "no-such-fixture", environment: [RenderFixture.directoryVariable: Self.fixtures.path])
        }
        #expect(throws: Never.self) {
            try RenderFixture.load(named: "prestart", environment: [RenderFixture.directoryVariable: Self.fixtures.path])
        }
    }

    @Test func aFixtureSessionSetsTheSceneUp() throws {
        let loaded = try RenderFixture.load(named: "prestart", in: Self.fixtures)
        var fixture = loaded.fixture
        fixture.camera = .course
        fixture.vision = .deuteranopia
        let session = try GameSession(fixture: fixture, log: loaded.log)
        #expect(session.driver.isFrozen)
        #expect(session.scene.cameraMode == .course)
        #expect(session.scene.filter != nil && session.scene.shouldEnableEffects)
        session.scene.vision = .none
        #expect(session.scene.filter == nil && !session.scene.shouldEnableEffects)
    }

    @Test func fixtureFieldsDecodeEveryCameraAndVision() throws {
        for camera in LaunchOptions.CameraMode.allCases {
            for vision in VisionFilter.allCases {
                let json = #"{"log":"x.json","freezeTick":3,"camera":"\#(camera.rawValue)","vision":"\#(vision.rawValue)"}"#
                let fixture = try JSONDecoder().decode(RenderFixture.self, from: Data(json.utf8))
                #expect(fixture == RenderFixture(log: "x.json", freezeTick: 3, camera: camera, vision: vision))
            }
        }
    }
}

@MainActor @Suite struct VisionFilterTests {
    static func close(_ a: [Double], _ b: [Double], within tolerance: Double = 0.002) -> Bool {
        zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
    }

    @Test func noneIsTheIdentity() {
        #expect(VisionFilter.none.apply([0.2, 0.5, 0.9]) == [0.2, 0.5, 0.9])
    }

    /// The dichromacy and greyscale matrices keep white white and black black, so only hue is lost.
    @Test func colourVisionFiltersKeepWhiteAndBlack() {
        for filter in [VisionFilter.deuteranopia, .protanopia, .tritanopia, .greyscale] {
            #expect(Self.close(filter.apply([1, 1, 1]), [1, 1, 1]), "\(filter) moves white")
            #expect(filter.apply([0, 0, 0]) == [0, 0, 0], "\(filter) moves black")
        }
    }

    /// Red and green lose what tells them apart without red or green cones: the red-green opponent signal
    /// (r - g) between them collapses. (Protanopia also darkens red, so lightness still differs.)
    @Test func redAndGreenConvergeForRedGreenDichromacy() {
        let red = [0.8, 0.2, 0.2], green = [0.3, 0.6, 0.2]
        func opponent(_ c: [Double]) -> Double { c[0] - c[1] }
        let before = abs(opponent(red) - opponent(green))
        for filter in [VisionFilter.deuteranopia, .protanopia] {
            let after = abs(opponent(filter.apply(red)) - opponent(filter.apply(green)))
            #expect(after < before / 4, "\(filter): \(after) vs \(before)")
        }
    }

    @Test func greyscaleIsLumaInEveryChannel() {
        let out = VisionFilter.greyscale.apply([1, 0, 0])
        #expect(Self.close(out, [0.2126, 0.2126, 0.2126]))
    }

    @Test func washoutHalvesContrastTowardsWhite() {
        #expect(Self.close(VisionFilter.washout.apply([0, 0, 0]), [0.45, 0.45, 0.45]))
        #expect(Self.close(VisionFilter.washout.apply([1, 1, 1]), [0.95, 0.95, 0.95]))
    }
}
