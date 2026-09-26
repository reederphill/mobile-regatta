import Foundation
import RegattaBots
import RegattaCore

/// A render fixture (#62): a race log replayed headless to `freezeTick`, drawn from `camera` through a
/// `vision` filter, and frozen there, so a UI test can diff the screen against a reference image.
///
/// Fixtures live in `RegattaUITests/Fixtures/` as small JSON files naming their log:
///
///     { "log": "prestart.racelog.json", "freezeTick": -1500, "camera": "boat", "vision": "none" }
///
/// The app is launched with `-fixture <name>`, and finds `<name>.json` in the directory the
/// `REGATTA_FIXTURE_DIR` environment variable names (the UI test passes its own `Fixtures` folder).
struct RenderFixture: Codable, Equatable {
    /// The environment variable holding the fixtures directory.
    nonisolated static let directoryVariable = "REGATTA_FIXTURE_DIR"

    /// The race log's file name, next to the fixture.
    var log: String
    /// The tick the scene freezes at. The log is replayed to it, not to its own final tick.
    var freezeTick: Int
    var camera: LaunchOptions.CameraMode
    var vision: VisionFilter

    enum LoadError: Error, CustomStringConvertible {
        case noDirectory
        case unreadable(String, any Error)

        var description: String {
            switch self {
            case .noDirectory: "\(RenderFixture.directoryVariable) isn't set, so the fixture can't be found"
            case .unreadable(let file, let error): "can't read \(file): \(error)"
            }
        }
    }

    /// Loads fixture `name` and its race log from `directory`.
    static func load(named name: String, in directory: URL) throws -> (fixture: RenderFixture, log: RaceLog) {
        let file = directory.appendingPathComponent("\(name).json")
        let fixture: RenderFixture
        do {
            fixture = try JSONDecoder().decode(RenderFixture.self, from: Data(contentsOf: file))
        } catch {
            throw LoadError.unreadable(file.path, error)
        }
        let logFile = directory.appendingPathComponent(fixture.log)
        do {
            return (fixture, try RaceLog(jsonData: Data(contentsOf: logFile)))
        } catch {
            throw LoadError.unreadable(logFile.path, error)
        }
    }

    /// Loads fixture `name` from the directory `environment` names.
    static func load(named name: String, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> (fixture: RenderFixture, log: RaceLog) {
        guard let path = environment[directoryVariable], !path.isEmpty else { throw LoadError.noDirectory }
        return try load(named: name, in: URL(fileURLWithPath: path, isDirectory: true))
    }
}

extension LaunchOptions.CameraMode: Codable {}

/// A colour-vision or viewing-condition filter over the whole scene (#22, #15), so a fixture can check that
/// every tone still reads. Each is a colour matrix on sRGB components, applied with `CIColorMatrix`:
/// `out = matrix · (r, g, b) + bias`.
///
/// - The three dichromacies are Machado, Oliveira and Fernandes (2009), severity 1.0.
/// - `greyscale` is Rec. 709 luma in every channel.
/// - `washout` stands in for sunlight glare: contrast halved and lifted towards white (`0.5 · c + 0.45`).
enum VisionFilter: String, Codable, CaseIterable {
    case none, deuteranopia, protanopia, tritanopia, greyscale, washout

    /// Row-major 3×3: row i gives output channel i from (r, g, b).
    var matrix: [[Double]] {
        switch self {
        case .none:
            [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        case .protanopia:
            [[0.152286, 1.052583, -0.204868],
             [0.114503, 0.786281, 0.099216],
             [-0.003882, -0.048116, 1.051998]]
        case .deuteranopia:
            [[0.367322, 0.860646, -0.227968],
             [0.280085, 0.672501, 0.047413],
             [-0.011820, 0.042940, 0.968881]]
        case .tritanopia:
            [[1.255528, -0.076749, -0.178779],
             [-0.078411, 0.930809, 0.147602],
             [0.004733, 0.691367, 0.303900]]
        case .greyscale:
            Array(repeating: [0.2126, 0.7152, 0.0722], count: 3)
        case .washout:
            [[0.5, 0, 0], [0, 0.5, 0], [0, 0, 0.5]]
        }
    }

    /// Added to each output channel.
    var bias: Double { self == .washout ? 0.45 : 0 }

    /// `rgb` through the filter, clamped to 0…1.
    func apply(_ rgb: [Double]) -> [Double] {
        matrix.map { row in (zip(row, rgb).map(*).reduce(0, +) + bias).clamped(to: 0...1) }
    }
}

/// A race replayed from a log and frozen at one tick (#62): the scene draws the same world every frame,
/// nothing steps, and input is ignored.
///
/// The log is replayed with `requireMatchingVersion: false`: fixtures are fixed test logs that outlive a
/// simulation revision, and the reference images, not the digest, pin what they draw. A revision that
/// moves the boats shows up as a reference diff, and the references are re-recorded.
final class FixtureDriver: RaceDriver {
    enum FixtureError: Error, Equatable {
        case freezeTickOutOfRange(freezeTick: Int, start: Int, finalTick: Int)
    }

    let myBoatIndex: Int
    let course: CourseLayout
    let boatClass: BoatClass
    let isPausable = false
    let isFrozen = true
    let roster: FleetRoster
    let currentFrame: TickFrame
    var previousFrame: TickFrame { currentFrame }
    let alpha = 1.0

    init(log: RaceLog, freezeTick: Int) throws {
        let start = -log.header.setup.startSequenceTicks
        guard (start...log.finalTick).contains(freezeTick) else {
            throw FixtureError.freezeTickOutOfRange(freezeTick: freezeTick, start: start, finalTick: log.finalTick)
        }
        var truncated = log
        truncated.inputs.removeAll { $0.tick > freezeTick }
        truncated.seatEvents.removeAll { $0.tick > freezeTick }
        truncated.finalTick = freezeTick
        let race = try Replayer.replay(truncated, requireMatchingVersion: false)
        let setup = log.header.setup
        myBoatIndex = setup.seats.firstIndex(of: .human) ?? 0
        course = race.course
        boatClass = race.boatClass
        roster = FleetRoster(setup: setup)
        currentFrame = TickFrame(race: race)
    }

    func tick(_ dt: Double) -> [TickFrame] { [] }
    func submit(_ input: BoatInput) {}
    func tap(_ tap: BoatTap) -> Bool { false }
    func drainEvents() -> [RaceEvent] { [] }
}
