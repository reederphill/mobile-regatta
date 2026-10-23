import Foundation
import RegattaCore

/// The bot's tunable constants (#583 stage 2): the thresholds, weights and angles her tactics read, gathered in one
/// value so a search can set them (`regatta-timetrial --tune`) and the tuned set can ship as data. Read from the
/// versioned `bot-tunables@<version>.json` (`bundled`); as the other data files (ADR 0004), a released version never
/// changes: a retune ships the next one. Angles are degrees and times seconds in the file, radians and seconds here.
///
/// What each sets, by where it is read:
/// - The tactician's tactics (`Tactics(profile: .tactician)`), which a live bot ramps to through the National band
///   (#366): `tacticianHeaderThreshold`, `tacticianTackInterval`, `tacticianAnticipation`, `tacticianCorridor`,
///   `tacticianDownwindShift`.
/// - A live bot's own tactics below the ramp (`Tactics(profile: nil)`): `liveHeaderThresholdDegrees` (her threshold at full
///   willingness and skill, in degrees here too: it is summed in degrees, as it always was) and `liveTackInterval` (her tack interval at middling willingness).
/// - The weights the tactics put on what they read (`BotBrain+Tactics.swift`), in radians of shift they're worth:
///   `puffWeight`, `pressureWeight`, `spotPressureWeight`, `dirtyAirWeight`, `downwindShadowWeight`, and
///   `laneEdgePressure`, the pressure gain at which a lane's bend counts in full.
/// - Her sailing of the groove: `lullHeatUp` (above the groove in a lull, to stay on the plane), `pinchRange` and
///   `pinchAngle` (pinching to fetch), `laylineLead` (metres down the starboard layline), `tackingSpeed` (the share of
///   her close-hauled speed she tacks at), `replaneStep` and `luffStep` (turning up to plane, a decision).
/// - Her planner (#583 stage 3, `BotPlanner`): `plannerHorizon` (seconds she plans ahead at the top of the National
///   band; 0, no bot plans), `plannerStartHorizon` (at the skill planning starts), `plannerStart` (where through the
///   Regional band it starts), `plannerMargin` (the seconds a turn her heuristics don't call must gain),
///   `plannerVetoMargin` (the seconds a turn they do call may lose and still go), `plannerShiftReversion` (seconds over which she expects her
///   shift off the course's axis to fade; 0, never).
public struct BotTunables: Codable, Hashable, Sendable {
    public var tacticianHeaderThreshold: Double
    public var tacticianTackInterval: Double
    public var tacticianAnticipation: Double
    public var tacticianCorridor: Double
    public var tacticianDownwindShift: Double
    public var liveHeaderThresholdDegrees: Double
    public var liveTackInterval: Double
    public var puffWeight: Double
    public var pressureWeight: Double
    public var spotPressureWeight: Double
    public var dirtyAirWeight: Double
    public var downwindShadowWeight: Double
    public var laneEdgePressure: Double
    public var lullHeatUp: Double
    public var pinchRange: Double
    public var pinchAngle: Double
    public var laylineLead: Double
    public var tackingSpeed: Double
    public var replaneStep: Double
    public var luffStep: Double
    public var plannerHorizon: Double
    public var plannerStartHorizon: Double
    public var plannerStart: Double
    public var plannerMargin: Double
    public var plannerVetoMargin: Double
    public var plannerShiftReversion: Double

    /// The constants as they were before #583 made them data: `bot-tunables@1.json`.
    public static let original = BotTunables(
        tacticianHeaderThreshold: deg2rad(4), tacticianTackInterval: 15, tacticianAnticipation: 6, tacticianCorridor: 0.5,
        tacticianDownwindShift: deg2rad(5), liveHeaderThresholdDegrees: 3, liveTackInterval: 15, puffWeight: deg2rad(14),
        pressureWeight: deg2rad(14), spotPressureWeight: deg2rad(30), dirtyAirWeight: deg2rad(2),
        downwindShadowWeight: deg2rad(4), laneEdgePressure: 0.1, lullHeatUp: deg2rad(12), pinchRange: 60,
        pinchAngle: deg2rad(38), laylineLead: 15, tackingSpeed: 0.75, replaneStep: deg2rad(9), luffStep: deg2rad(6),
        plannerHorizon: 0, plannerStartHorizon: 8, plannerStart: 0.5, plannerMargin: 1, plannerVetoMargin: 1,
        plannerShiftReversion: 0)

    public init(tacticianHeaderThreshold: Double, tacticianTackInterval: Double, tacticianAnticipation: Double,
                tacticianCorridor: Double, tacticianDownwindShift: Double, liveHeaderThresholdDegrees: Double,
                liveTackInterval: Double, puffWeight: Double, pressureWeight: Double, spotPressureWeight: Double,
                dirtyAirWeight: Double, downwindShadowWeight: Double, laneEdgePressure: Double, lullHeatUp: Double,
                pinchRange: Double, pinchAngle: Double, laylineLead: Double, tackingSpeed: Double, replaneStep: Double,
                luffStep: Double, plannerHorizon: Double, plannerStartHorizon: Double, plannerStart: Double,
                plannerMargin: Double, plannerVetoMargin: Double, plannerShiftReversion: Double) {
        self.tacticianHeaderThreshold = tacticianHeaderThreshold
        self.tacticianTackInterval = tacticianTackInterval
        self.tacticianAnticipation = tacticianAnticipation
        self.tacticianCorridor = tacticianCorridor
        self.tacticianDownwindShift = tacticianDownwindShift
        self.liveHeaderThresholdDegrees = liveHeaderThresholdDegrees
        self.liveTackInterval = liveTackInterval
        self.puffWeight = puffWeight
        self.pressureWeight = pressureWeight
        self.spotPressureWeight = spotPressureWeight
        self.dirtyAirWeight = dirtyAirWeight
        self.downwindShadowWeight = downwindShadowWeight
        self.laneEdgePressure = laneEdgePressure
        self.lullHeatUp = lullHeatUp
        self.pinchRange = pinchRange
        self.pinchAngle = pinchAngle
        self.laylineLead = laylineLead
        self.tackingSpeed = tackingSpeed
        self.replaneStep = replaneStep
        self.luffStep = luffStep
        self.plannerHorizon = plannerHorizon
        self.plannerStartHorizon = plannerStartHorizon
        self.plannerStart = plannerStart
        self.plannerMargin = plannerMargin
        self.plannerVetoMargin = plannerVetoMargin
        self.plannerShiftReversion = plannerShiftReversion
    }

    /// One tunable: its key in the file and in `--tune`, whether the file writes it in degrees, the range a search keeps
    /// it in (the file's units), and its path here. Sendable by hand: a key path to a stored property of a value type is
    /// immutable.
    public struct Parameter: @unchecked Sendable {
        public let name: String
        public let degrees: Bool
        public let range: ClosedRange<Double>
        public let keyPath: WritableKeyPath<BotTunables, Double>

        /// Its value in the file's units.
        public func value(in tunables: BotTunables) -> Double {
            degrees ? rad2deg(tunables[keyPath: keyPath]) : tunables[keyPath: keyPath]
        }

        /// `tunables` with it set to `value`, in the file's units, kept in `range`.
        public func set(_ value: Double, in tunables: BotTunables) -> BotTunables {
            var copy = tunables
            let clamped = min(max(value, range.lowerBound), range.upperBound)
            copy[keyPath: keyPath] = degrees ? deg2rad(clamped) : clamped
            return copy
        }
    }

    /// Every tunable, in the file's order.
    public static let parameters: [Parameter] = [
        .init(name: "tacticianHeaderThresholdDegrees", degrees: true, range: 1...12, keyPath: \.tacticianHeaderThreshold),
        .init(name: "tacticianTackIntervalSeconds", degrees: false, range: 4...40, keyPath: \.tacticianTackInterval),
        .init(name: "tacticianAnticipationSeconds", degrees: false, range: 0...20, keyPath: \.tacticianAnticipation),
        .init(name: "tacticianCorridor", degrees: false, range: 0.1...1.2, keyPath: \.tacticianCorridor),
        .init(name: "tacticianDownwindShiftDegrees", degrees: true, range: 1...20, keyPath: \.tacticianDownwindShift),
        .init(name: "liveHeaderThresholdDegrees", degrees: false, range: 1...12, keyPath: \.liveHeaderThresholdDegrees),
        .init(name: "liveTackIntervalSeconds", degrees: false, range: 4...40, keyPath: \.liveTackInterval),
        .init(name: "puffWeightDegrees", degrees: true, range: 0...40, keyPath: \.puffWeight),
        .init(name: "pressureWeightDegrees", degrees: true, range: 0...40, keyPath: \.pressureWeight),
        .init(name: "spotPressureWeightDegrees", degrees: true, range: 0...60, keyPath: \.spotPressureWeight),
        .init(name: "dirtyAirWeightDegrees", degrees: true, range: 0...10, keyPath: \.dirtyAirWeight),
        .init(name: "downwindShadowWeightDegrees", degrees: true, range: 0...15, keyPath: \.downwindShadowWeight),
        .init(name: "laneEdgePressure", degrees: false, range: 0.02...0.5, keyPath: \.laneEdgePressure),
        .init(name: "lullHeatUpDegrees", degrees: true, range: 0...30, keyPath: \.lullHeatUp),
        .init(name: "pinchRangeMetres", degrees: false, range: 0...150, keyPath: \.pinchRange),
        .init(name: "pinchAngleDegrees", degrees: true, range: 32...45, keyPath: \.pinchAngle),
        .init(name: "laylineLeadMetres", degrees: false, range: 0...40, keyPath: \.laylineLead),
        .init(name: "tackingSpeed", degrees: false, range: 0.4...0.95, keyPath: \.tackingSpeed),
        .init(name: "replaneStepDegrees", degrees: true, range: 2...20, keyPath: \.replaneStep),
        .init(name: "luffStepDegrees", degrees: true, range: 2...15, keyPath: \.luffStep),
        .init(name: "plannerHorizonSeconds", degrees: false, range: 0...40, keyPath: \.plannerHorizon),
        .init(name: "plannerStartHorizonSeconds", degrees: false, range: 2...40, keyPath: \.plannerStartHorizon),
        .init(name: "plannerStart", degrees: false, range: 0...1, keyPath: \.plannerStart),
        .init(name: "plannerMarginSeconds", degrees: false, range: -2...6, keyPath: \.plannerMargin),
        .init(name: "plannerVetoMarginSeconds", degrees: false, range: -6...20, keyPath: \.plannerVetoMargin),
        .init(name: "plannerShiftReversionSeconds", degrees: false, range: 0...240, keyPath: \.plannerShiftReversion),
    ]

    // MARK: - The file

    /// The file bots sail by: version 2, #583 stage 2's tuned set (no planning); version 1, the constants as they were.
    public static let currentVersion = 2

    /// The bundled `bot-tunables@<currentVersion>.json`.
    public static let bundled: BotTunables = {
        do {
            return try load(version: currentVersion)
        } catch {
            preconditionFailure("bot-tunables@\(currentVersion).json: \(error)")
        }
    }()

    /// The bundled `bot-tunables@<version>.json`.
    public static func load(version: Int) throws -> BotTunables {
        guard let url = Bundle.module.url(forResource: "bot-tunables@\(version)", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try decode(Data(contentsOf: url), version: version)
    }

    /// A tunables file's bytes: `{"id": "bot-tunables", "version": n, "values": {name: number, …}}`, every parameter
    /// named once, in the file's units. `version` nil takes any.
    public static func decode(_ data: Data, version: Int? = nil) throws -> BotTunables {
        let file = try JSONDecoder().decode(File.self, from: data)
        guard file.id == "bot-tunables", version.map({ $0 == file.version }) ?? true,
              file.byName.count == parameters.count, parameters.allSatisfy({ file.byName[$0.name] != nil }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return parameters.reduce(original) { tunables, parameter in
            parameter.set(file.byName[parameter.name] ?? 0, in: tunables)
        }
    }

    /// This set as a tunables file of `version`, keys sorted, values in the file's units rounded to 4 decimals.
    public func encoded(version: Int, notes: String) throws -> Data {
        var byName: [String: Double] = [:]
        for parameter in Self.parameters {
            byName[parameter.name] = (parameter.value(in: self) * 10_000).rounded() / 10_000
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(File(id: "bot-tunables", version: version, notes: notes, byName: byName))
    }

    /// The file's form: its tunables by name, under "values". Read by name only, never iterated: a dictionary's order
    /// changes with the process's hash seed (`DeterminismTests.noSetOrDictionaryIterationInSources`).
    private struct File: Codable {
        var id: String
        var version: Int
        var notes: String?
        var byName: [String: Double]

        enum CodingKeys: String, CodingKey {
            case id, version, notes
            case byName = "values"
        }
    }
}
