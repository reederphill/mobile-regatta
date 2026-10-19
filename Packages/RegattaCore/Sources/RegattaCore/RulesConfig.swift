import Foundation

/// A length written as a multiple of the race's boat class hull length ("L"). Rules sizes are in hull
/// lengths so one rules file fits every class; `metres(hullLength:)` gives the length for a class.
public struct HullLengths: Sendable, Equatable {
    public var value: Double

    public init(_ value: Double) { self.value = value }

    /// Metres, for a class whose hull is `hullLength` metres long (`BoatClass.Hull.length`).
    public func metres(hullLength: Double) -> Double { value * hullLength }
}

/// The rules configuration: every tunable the rules and the race format use, loaded from its immutable,
/// versioned data file (ADR 0004, #73). Each race log records its ref (`RaceSetup.rulesConfiguration`),
/// so retuning a value ships a new version and never changes how an old race replays. Nothing here is
/// folded into the simulation version.
///
/// Files use seconds, degrees, ticks, hull lengths, line lengths and fractions of the beat; angles are
/// converted to radians at load, and every duration must be a whole number of ticks (`ticks(_:)`).
/// Schema: `docs/rules-file.md`. Load one with `RulesConfigFile.bundled(id:version:)`.
public struct RulesConfig: DataFileContent {
    public static let kind = "rules configuration"
    public static let bundleDirectory = "rules"
    /// Schema 2 (#85) adds the start row's spacing floor (`StartRow.minimumSpacing`). A schema-1 file has none
    /// (nil): a squeezed start row narrows its spread with its depth, as #82 squeezed its placement.
    /// Schema 3 (#89) adds how stacked penalty turns take their deadlines (`Penalty.stackedPenaltyDeadlines`);
    /// a schema-1 or -2 file means `fromCall`.
    /// Schema 4 (#92) adds the escape simulation's "changes course" test (`Escape.changesCourse`); a schema-1 to
    /// -3 file has none (nil), and its races run no escape simulation: rules 15 and 16.1 are never called.
    /// Schema 5 (#345) adds rule 17's limits (`Incidents.properCourse`); a schema-1 to -4 file has none (nil), and
    /// its races never call rule 17.
    /// Schema 6 (#487) adds what a penalty turn is (`Penalty.turn`, absent `fullCircle`); a `tackAndGybe` file has
    /// no start deadline (`startSeconds`) and no started turn (`startedTurnDegrees`). A schema-1 to -5 file means
    /// `fullCircle`.
    /// Schema 7 (#517) adds how far back the 16.1 test looks for the right-of-way boat's turn in a rule 21.2 incident
    /// (`Escape.penaltyLookBack`); a schema-1 to -6 file has none (nil), and such an incident looks `Escape.horizon`
    /// back, like any other.
    /// Schema 8 (#477) replaces the start row with the opening (`RaceFormat.opening`): two rows, starboard and port, eased
    /// at a trim before the gun (`easeSpeedFraction(boatClass:beforeGun:)`), and adds the race area's least depth below
    /// the line (`RaceAreaFactors.belowLineMinimum`). A schema-8 file has no `startRow`; a schema-1 to -7 file has no
    /// opening (nil) and no least depth: its boats start in the row, eased at the class's fraction.
    public static let supportedSchemaVersions = [1, 2, 3, 4, 5, 6, 7, 8]

    public var incidents: Incidents
    /// The rule 18 zone.
    public var zone: Zone
    /// The test of whether mark-room was given (rule 18.2). A builder value.
    public var markRoomGiven: MarkRoomGiven
    /// The test of whether a boat is on a beat to windward (rule 18.1(a)). A builder value.
    public var onABeat: OnABeat
    public var raceFormat: RaceFormat
    /// JSON Pointers to the values in the file the spec leaves to the builder (documented as such).
    public let builderValues: [String]

    public struct Incidents: Sendable, Equatable {
        public var nearMissSweep: NearMissSweep
        public var escape: Escape
        /// Contacts between the same two boats closer together than this are one incident.
        public var separation: HullLengths
        /// A change in overlap or zone state counts only once it has held this long (#18), seconds.
        public var lastPointOfCertainty: Double
        /// Rule 17's limits (schema 5, #345). Nil in a schema-1 to -4 file: the umpire keeps no rule 17 records and
        /// never calls rule 17.
        public var properCourse: ProperCourseLimits?
    }

    /// Rule 17 (#345): a boat that becomes overlapped to leeward from clear astern within `distance` of the other
    /// shall not sail above her proper course (`ProperCourse`) while they stay overlapped on the same tack within
    /// it. "Above" is closer to the wind than proper course less the leg's tolerance.
    public struct ProperCourseLimits: Sendable, Equatable {
        /// The hull gap within which the overlap begins and holds (the RRS's two hull lengths).
        public var distance: HullLengths
        /// Radians closer to the wind than proper course a boat may sail on a beat: the pinch allowance.
        public var beatTolerance: Double
        /// Radians closer to the wind than proper course a boat may sail on a reach or a run.
        public var reachRunTolerance: Double
        /// Seconds: a boat above proper course that, both boats projected on at their velocities, ends clear
        /// astern of the other within this is promptly sailing astern of her (rule 17's exception).
        public var promptlyAstern: Double

        public init(distance: HullLengths, beatTolerance: Double, reachRunTolerance: Double, promptlyAstern: Double) {
            self.distance = distance
            self.beatTolerance = beatTolerance
            self.reachRunTolerance = reachRunTolerance
            self.promptlyAstern = promptlyAstern
        }

        /// The tolerance for a proper course of `kind`, radians.
        public func tolerance(_ kind: ProperCourse.Kind) -> Double {
            kind == .beat ? beatTolerance : reachRunTolerance
        }
    }

    /// Would the right-of-way boat have hit the keep-clear boat had she held her course? The sweep turns
    /// her heading up to `heading` either way and sails her on for `seconds`.
    public struct NearMissSweep: Sendable, Equatable {
        /// Radians either side of her heading (the spec's ±10°).
        public var heading: Double
        /// Seconds she is sailed on for (the spec's 0.5 s).
        public var seconds: Double
        /// Headings tried across the sweep, evenly spaced, both ends and straight on included. Odd. Builder value.
        public var headingSamples: Int
        /// Ticks between the positions checked along each heading. Builder value.
        public var stepTicks: Int
        /// Hulls closer than this count as a hit. Builder value.
        public var clearance: HullLengths

        /// The heading offsets tried, radians, from −`heading` to +`heading` in array order.
        public var headingOffsets: [Double] {
            (0..<headingSamples).map { k in
                -heading + 2 * heading * Double(k) / Double(headingSamples - 1)
            }
        }
    }

    /// Could the keep-clear boat have kept clear? Each candidate input is simulated from the start tick
    /// for the horizon.
    public struct Escape: Sendable, Equatable {
        /// Seconds the escape simulation looks ahead (the spec's 2 s).
        public var horizon: Double
        /// The inputs tried, in order: every rudder with every ease, rudder outermost. Builder value.
        public var candidates: [BoatInput]
        /// Ticks after the obligation began (its last point of certainty) that the simulation starts. Builder value.
        public var startTickOffset: Int
        /// Seconds after a boat acquires right of way during which she must initially give the other
        /// room to keep clear (rules 15 and 16.1). Builder value.
        public var initially: Double
        /// The right-of-way boat changes course (rule 16.1) on a tick her heading turns faster than this,
        /// radians a second (schema 4, #92): above the autohelm following shifts and puffs, below a luff.
        /// Builder value. Nil in a schema-1 to -3 file: no escape simulation runs, so rules 15 and 16.1 are
        /// never called (`EscapeSimulation`).
        public var changesCourse: Double?
        /// Seconds back from an incident whose obligation is rule 21.2 that the 16.1 test looks for where the
        /// right-of-way boat's turn began (schema 7, #517; `EscapeSimulation`). Builder value. Nil in a schema-1 to
        /// -6 file: such an incident looks `horizon` back, like any other.
        public var penaltyLookBack: Double?

        /// Ticks of each pair's track every call but rule 21.2's look-back is judged on (`UmpireState.track`): enough
        /// for a simulation from the tick after the first it looks back to, a course change `horizon` and
        /// `startTickOffset` before the incident or right of way acquired `initially` before it, and the tick before
        /// that to compare.
        public var windowTicks: Int {
            max(RulesConfig.ticks(horizon) + startTickOffset + 1, RulesConfig.ticks(initially) + 2)
        }

        /// Ticks the umpire records each boat for (`UmpireState`): `windowTicks`, and with a look-back (schema 7,
        /// #517) enough to hold it too, with the tick before its first to compare and to hold her course from.
        public var recordedTicks: Int {
            guard let penaltyLookBack else { return windowTicks }
            return max(windowTicks, RulesConfig.ticks(penaltyLookBack) + 2)
        }
    }

    public struct Zone: Sendable, Equatable {
        /// The zone's radius (the spec's 3 L).
        public var radius: HullLengths
    }

    /// Mark-room was given when the boat entitled to it could pass the mark within `roundingDistance`
    /// of it with at least `clearance` between hulls.
    public struct MarkRoomGiven: Sendable, Equatable {
        public var roundingDistance: HullLengths
        public var clearance: HullLengths
    }

    /// A boat is on a beat when her true wind angle is at most `maxTrueWindAngle` and, if
    /// `windwardLegOnly`, her leg ends at a windward mark.
    public struct OnABeat: Sendable, Equatable {
        /// Radians.
        public var maxTrueWindAngle: Double
        public var windwardLegOnly: Bool
    }

    /// The race format: sequence, penalties, windows and limits, and the sizes the course is laid out
    /// with. Replay-affecting, so it lives in this versioned file rather than in code.
    public struct RaceFormat: Sendable, Equatable {
        /// Seconds from the start of the sequence to the gun.
        public var startSequence: Double
        public var penalty: Penalty
        /// Seconds after an incident during which a protest can be lodged.
        public var protestWindow: Double
        /// Seconds after the first finish during which the rest can finish.
        public var finishWindow: Double
        /// Seconds after the gun at which the race ends whatever happens.
        public var timeLimit: Double
        public var startLine: StartLine
        public var leewardGate: LeewardGate
        public var offsetMark: OffsetMark
        public var raceArea: RaceAreaFactors
        /// Where boats are at the start of the sequence before schema 8 (#35): nil in a schema-8 file, which has
        /// `opening` instead. Implicitly unwrapped: every reader of the row reads a file that has one.
        public var startRow: StartRow!
        /// Where boats are at the start of the sequence, and their trim before the gun, from schema 8 (#477): nil before.
        public var opening: Opening?
        /// Fraction of her speed along the edge a boat keeps on meeting land or the boundary. Placeholder.
        public var edgeSpeedRetention: Double
        public var beatSizing: BeatSizing

        public var startSequenceTicks: Int { RulesConfig.ticks(startSequence) }
    }

    /// A penalty turn's deadlines (#9, #89): each owed turn has a clock, and must be started (turned
    /// `startedTurn`) `start` seconds after it and completed `complete` seconds after it, or she is
    /// disqualified. When the clock starts is `stackedPenaltyDeadlines`'s. What a turn is is `turn`'s (#487): under
    /// `tackAndGybe` there is no start deadline, so `start` is `complete` and `startedTurn` 0 (neither is read).
    public struct Penalty: Sendable, Equatable {
        /// Seconds after the turn's clock starts by which it must be started.
        public var start: Double
        /// Seconds after the turn's clock starts by which it must be completed.
        public var complete: Double
        /// Radians a boat must have turned for her penalty to count as started.
        public var startedTurn: Double
        /// When each owed turn's clock starts (schema 3; a schema-1 or -2 file means `fromCall`).
        public var stackedPenaltyDeadlines: StackedPenaltyDeadlines
        /// What serves a turn (schema 6, #487; a schema-1 to -5 file means `fullCircle`).
        public var turn: PenaltyTurn = .fullCircle
    }

    /// What a penalty turn is (#487).
    public enum PenaltyTurn: String, Sendable, Equatable, CaseIterable {
        /// 360° of heading one way, counted from her heading tick by tick (#9, #89, #219): every file before schema 6.
        case fullCircle
        /// One tack and one gybe made turning the same way, in either order (RRS 44.2): counted at the boom's
        /// crossings, the heading turned between them free (`Race`'s `crossPenalty`). One limit, `complete`, from the
        /// turn's clock; no start deadline and no started turn.
        case tackAndGybe
    }

    /// When an owed penalty turn's clock starts, for a boat owing more than one (G4, #89). Owed turns are
    /// served in order either way; a turn's clock is fixed when it becomes the current one.
    public enum StackedPenaltyDeadlines: String, Sendable, Equatable, CaseIterable {
        /// At its own call or when the turn before it is completed, whichever is later (G4, the default):
        /// a turn queued behind another gets its full start and complete windows once that one is done.
        case sequential
        /// At its own call, however many turns are owed ahead of it: what a rules file before schema 3 meant,
        /// the option G4 turned down.
        case fromCall
    }

    /// The start line is `perBoat` × fleet size long, and at least `minimumMetres`.
    public struct StartLine: Sendable, Equatable {
        public var perBoat: HullLengths
        public var minimumMetres: Double

        /// Metres, for `fleetSize` boats of a class with hull `hullLength` metres.
        public func length(fleetSize: Int, hullLength: Double) -> Double {
            max(minimumMetres, perBoat.metres(hullLength: hullLength) * Double(fleetSize))
        }
    }

    /// The gate's midpoint is `1 / aboveLineBeatDivisor` of the beat above the line; it is `width` wide.
    public struct LeewardGate: Sendable, Equatable {
        public var aboveLineBeatDivisor: Double
        public var width: HullLengths
    }

    /// The offset mark is `toPort` to port of the windward mark, square to the axis.
    public struct OffsetMark: Sendable, Equatable {
        public var toPort: HullLengths
    }

    /// The race area: `acrossAxisBeatFraction` × beat either side of the axis, `belowLineLineLengths`
    /// line lengths below the line and `aboveWindwardBeatFraction` × beat above the windward mark.
    /// From schema 8 (#477) the race area reaches below the line the greater of `belowLineLineLengths` line lengths and
    /// `belowLineMinimum` (nil before: line lengths only).
    public struct RaceAreaFactors: Sendable, Equatable {
        public var acrossAxisBeatFraction: Double
        public var belowLineLineLengths: Double
        public var aboveWindwardBeatFraction: Double
        public var belowLineMinimum: HullLengths? = nil

        /// Metres below the line, for a line `lineLength` metres long and a class whose hull is `hullLength` metres.
        public func belowLine(lineLength: Double, hullLength: Double) -> Double {
            let lines = belowLineLineLengths * lineLength
            guard let minimum = belowLineMinimum else { return lines }
            return max(lines, minimum.metres(hullLength: hullLength))
        }
    }

    /// The opening (schema 8, #477): where boats are at the start of the sequence, and how an ease trims them before the
    /// gun. Two rows below the line, starboard tack at `rowDepths[0]` and port at `rowDepths[1]`, spread over
    /// `spreadLineLengths` line lengths; slots alternate the tacks in the seeded order (`CourseLayout.opening`), port's
    /// staggered half a slot towards the committee end, each jittered within `jitter` and no two closer than
    /// `minimumSpacing`, centre to centre. Starboard reaches towards the pin and port towards the committee end, both
    /// `trueWindAngle` off the axis, eased: before the gun an ease sails `easeSpeedFraction` of her target (every seat's,
    /// the human's too), and from the gun the class's (`BoatClass.ease.speedFraction`).
    public struct Opening: Sendable, Equatable {
        /// Starboard's row, then port's.
        public var rowDepths: [HullLengths]
        public var spreadLineLengths: Double
        /// Radians.
        public var trueWindAngle: Double
        public var easeSpeedFraction: Double
        public var minimumSpacing: HullLengths
        /// The cap on each slot's jitter radius; the drawn radius keeps `minimumSpacing` (`CourseLayout.openingSlots`).
        public var jitter: HullLengths
    }

    /// The fraction of her target speed an ease sails (`BoatDynamics.Control.easeSpeedFraction`): the opening's trim
    /// before the gun under a rules file with one (schema 8, #477), otherwise `boatClass`'s. The only reader of the trim.
    public func easeSpeedFraction(boatClass: BoatClass, beforeGun: Bool) -> Double {
        if beforeGun, let opening = raceFormat.opening { return opening.easeSpeedFraction }
        return boatClass.ease.speedFraction
    }

    /// Where boats are at the start of the sequence (#35): one row `depthLineLengths` below the line,
    /// spread over `spreadLineLengths` line lengths, on starboard at `trueWindAngle` and
    /// `polarSpeedFraction` of polar speed.
    public struct StartRow: Sendable, Equatable {
        public var depthLineLengths: Double
        public var spreadLineLengths: Double
        /// Radians.
        public var trueWindAngle: Double
        public var polarSpeedFraction: Double
        /// The closest a squeeze of the row (`CourseLayout.startRowSlots`) brings neighbours, centre to centre
        /// (schema 2, #85): clear ahead and clear astern (#35) with room between. Nil in a schema-1 file: no
        /// floor.
        public var minimumSpacing: HullLengths?
    }

    /// The beat is sized so the leader sails the race in about `leaderSeconds`, at most `maxMetres`,
    /// scaled by `calibrationFactor` (a placeholder, calibrated with the bot suite, #105).
    public struct BeatSizing: Sendable, Equatable {
        public var leaderSeconds: Double
        public var maxMetres: Double
        public var calibrationFactor: Double
    }

    /// A duration in whole ticks. Every duration in a file is checked, at load, to be a whole number of ticks.
    public static func ticks(_ seconds: Double) -> Int {
        Int((seconds * Double(Race.tickRate)).rounded())
    }

    /// The rule 18 zone's radius, metres, for a class with hull `hullLength` metres.
    public func zoneRadius(hullLength: Double) -> Double { zone.radius.metres(hullLength: hullLength) }

    public init(fileData: Data, header: DataFileHeader) throws {
        switch header.schemaVersion {
        case 1, 2, 3, 4, 5, 6, 7, 8:
            // Duplicate keys were already refused by `DataFile`, so every parse below reads the same file.
            let document = try JSONDecoder().decode(RulesConfigSchema.self, from: fileData)
            try document.rejectUnknownFields(in: fileData)
            self = try document.rulesConfig(id: header.id, schemaVersion: header.schemaVersion, fileData: fileData)
        default:
            throw DataFileError.unsupportedSchemaVersion(
                kind: Self.kind, found: header.schemaVersion, supported: Self.supportedSchemaVersions)
        }
    }

    fileprivate init(incidents: Incidents, zone: Zone, markRoomGiven: MarkRoomGiven, onABeat: OnABeat,
                     raceFormat: RaceFormat, builderValues: [String]) {
        self.incidents = incidents
        self.zone = zone
        self.markRoomGiven = markRoomGiven
        self.onABeat = onABeat
        self.raceFormat = raceFormat
        self.builderValues = builderValues
    }
}

public typealias RulesConfigFile = DataFile<RulesConfig>

// MARK: - Schemas 1 to 7

/// The rules configuration file, schema versions 1 to 7, as written. Documented in `docs/rules-file.md`.
/// Schema 2 is schema 1 plus `raceFormat.startRow.minimumSpacingHullLengths` (#85): required in schema 2
/// and later, refused in schema 1. Schema 3 is schema 2 plus `raceFormat.penalty.stackedPenaltyDeadlines`
/// (#89): required in schema 3 and later, refused before it. Schema 4 is schema 3 plus
/// `incidents.escape.changesCourseDegreesPerSecond` (#92): required in schema 4 and later, refused before it.
/// Schema 5 is schema 4 plus `incidents.properCourse` (#345): required in schema 5, refused before it.
/// Schema 6 is schema 5 plus `raceFormat.penalty.turn` (#487): optional (absent `fullCircle`), refused before it; a
/// `tackAndGybe` penalty drops `startSeconds` and `startedTurnDegrees`, which every other penalty requires.
/// Schema 7 is schema 6 plus `incidents.escape.penaltyLookBackSeconds` (#517): required in schema 7, refused before it.
struct RulesConfigSchema: Decodable {
    let schemaVersion: Int
    let id: String
    let version: Int
    let placeholders: [String]?
    let builderValues: [String]
    let notes: [String]?
    let incidents: Incidents
    let zone: Zone
    let markRoomGiven: MarkRoomGiven
    let onABeat: OnABeat
    let raceFormat: RaceFormat

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, id, version, placeholders, builderValues, notes, incidents, zone, markRoomGiven, onABeat, raceFormat
    }

    struct Incidents: Decodable {
        let nearMissSweep: NearMissSweep
        let escape: Escape
        let separationHullLengths: Double
        let lastPointOfCertaintySeconds: Double
        /// Schema 5.
        let properCourse: ProperCourse?

        enum CodingKeys: String, CodingKey, CaseIterable {
            case nearMissSweep, escape, separationHullLengths, lastPointOfCertaintySeconds, properCourse
        }
    }

    struct ProperCourse: Decodable {
        let distanceHullLengths: Double
        let beatToleranceDegrees: Double
        let reachRunToleranceDegrees: Double
        let promptlyAsternSeconds: Double

        enum CodingKeys: String, CodingKey, CaseIterable {
            case distanceHullLengths, beatToleranceDegrees, reachRunToleranceDegrees, promptlyAsternSeconds
        }
    }

    struct NearMissSweep: Decodable {
        let headingDegrees: Double
        let seconds: Double
        let headingSamples: Int
        let stepTicks: Int
        let clearanceHullLengths: Double

        enum CodingKeys: String, CodingKey, CaseIterable {
            case headingDegrees, seconds, headingSamples, stepTicks, clearanceHullLengths
        }
    }

    struct Escape: Decodable {
        struct Candidates: Decodable {
            let rudder: [Double]
            let ease: [Bool]

            enum CodingKeys: String, CodingKey, CaseIterable { case rudder, ease }
        }

        let horizonSeconds: Double
        let candidates: Candidates
        let startTickOffset: Int
        let initiallySeconds: Double
        /// Schema 4.
        let changesCourseDegreesPerSecond: Double?
        /// Schema 7.
        let penaltyLookBackSeconds: Double?

        enum CodingKeys: String, CodingKey, CaseIterable {
            case horizonSeconds, candidates, startTickOffset, initiallySeconds, changesCourseDegreesPerSecond
            case penaltyLookBackSeconds
        }
    }

    struct Zone: Decodable {
        let radiusHullLengths: Double

        enum CodingKeys: String, CodingKey, CaseIterable { case radiusHullLengths }
    }

    struct MarkRoomGiven: Decodable {
        let roundingDistanceHullLengths: Double
        let clearanceHullLengths: Double

        enum CodingKeys: String, CodingKey, CaseIterable { case roundingDistanceHullLengths, clearanceHullLengths }
    }

    struct OnABeat: Decodable {
        let maxTrueWindAngleDegrees: Double
        let windwardLegOnly: Bool

        enum CodingKeys: String, CodingKey, CaseIterable { case maxTrueWindAngleDegrees, windwardLegOnly }
    }

    struct RaceFormat: Decodable {
        struct Penalty: Decodable {
            /// Every schema; refused under schema 6's `tackAndGybe`.
            let startSeconds: Double?
            let completeSeconds: Double
            /// Every schema; refused under schema 6's `tackAndGybe`.
            let startedTurnDegrees: Double?
            /// Schema 3.
            let stackedPenaltyDeadlines: String?
            /// Schema 6.
            let turn: String?

            enum CodingKeys: String, CodingKey, CaseIterable {
                case startSeconds, completeSeconds, startedTurnDegrees, stackedPenaltyDeadlines, turn
            }
        }

        struct StartLine: Decodable {
            let hullLengthsPerBoat: Double
            let minimumMetres: Double

            enum CodingKeys: String, CodingKey, CaseIterable { case hullLengthsPerBoat, minimumMetres }
        }

        struct LeewardGate: Decodable {
            let aboveLineBeatDivisor: Double
            let widthHullLengths: Double

            enum CodingKeys: String, CodingKey, CaseIterable { case aboveLineBeatDivisor, widthHullLengths }
        }

        struct OffsetMark: Decodable {
            let toPortHullLengths: Double

            enum CodingKeys: String, CodingKey, CaseIterable { case toPortHullLengths }
        }

        struct RaceArea: Decodable {
            let acrossAxisBeatFraction: Double
            let belowLineLineLengths: Double
            let aboveWindwardBeatFraction: Double
            /// Schema 8.
            let belowLineMinimumHullLengths: Double?

            enum CodingKeys: String, CodingKey, CaseIterable {
                case acrossAxisBeatFraction, belowLineLineLengths, aboveWindwardBeatFraction, belowLineMinimumHullLengths
            }
        }

        /// Schema 8.
        struct Opening: Decodable {
            let rowDepthsHullLengths: [Double]
            let spreadLineLengths: Double
            let trueWindAngleDegrees: Double
            let easeSpeedFraction: Double
            let minimumSpacingHullLengths: Double
            let jitterHullLengths: Double

            enum CodingKeys: String, CodingKey, CaseIterable {
                case rowDepthsHullLengths, spreadLineLengths, trueWindAngleDegrees, easeSpeedFraction
                case minimumSpacingHullLengths, jitterHullLengths
            }
        }

        struct StartRow: Decodable {
            let depthLineLengths: Double
            let spreadLineLengths: Double
            let trueWindAngleDegrees: Double
            let polarSpeedFraction: Double
            /// Schema 2.
            let minimumSpacingHullLengths: Double?

            enum CodingKeys: String, CodingKey, CaseIterable {
                case depthLineLengths, spreadLineLengths, trueWindAngleDegrees, polarSpeedFraction, minimumSpacingHullLengths
            }
        }

        struct BeatSizing: Decodable {
            let leaderSeconds: Double
            let maxMetres: Double
            let calibrationFactor: Double

            enum CodingKeys: String, CodingKey, CaseIterable { case leaderSeconds, maxMetres, calibrationFactor }
        }

        let startSequenceSeconds: Double
        let penalty: Penalty
        let protestWindowSeconds: Double
        let finishWindowSeconds: Double
        let timeLimitSeconds: Double
        let startLine: StartLine
        let leewardGate: LeewardGate
        let offsetMark: OffsetMark
        let raceArea: RaceArea
        /// Every schema but 8.
        let startRow: StartRow?
        /// Schema 8.
        let opening: Opening?
        let edgeSpeedRetention: Double
        let beatSizing: BeatSizing

        enum CodingKeys: String, CodingKey, CaseIterable {
            case startSequenceSeconds, penalty, protestWindowSeconds, finishWindowSeconds, timeLimitSeconds, startLine
            case leewardGate, offsetMark, raceArea, startRow, opening, edgeSpeedRetention, beatSizing
        }
    }

    /// Throws `malformed` naming the first field no schema has, or that is `null`: a released file can't
    /// be fixed, so it mustn't ship with a field nothing reads. (`rulesConfig` refuses a later schema's field
    /// in an earlier schema's file.)
    func rejectUnknownFields(in data: Data) throws {
        let document = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        if let pointer = Self.fields.firstUnknownField(in: document, at: "") {
            throw DataFileError.malformed(
                kind: RulesConfig.kind, reason: "unknown or null field \(pointer): a rules configuration has only its schema's fields")
        }
    }

    /// Every field schemas 1 to 8 have, from each type's `CodingKeys`, so it can't drift from the decoder.
    static let fields: FieldTree = .object(CodingKeys.self, [
        .incidents: .object(Incidents.CodingKeys.self, [
            .nearMissSweep: .object(NearMissSweep.CodingKeys.self),
            .escape: .object(Escape.CodingKeys.self, [.candidates: .object(Escape.Candidates.CodingKeys.self)]),
            .properCourse: .object(ProperCourse.CodingKeys.self),
        ]),
        .zone: .object(Zone.CodingKeys.self),
        .markRoomGiven: .object(MarkRoomGiven.CodingKeys.self),
        .onABeat: .object(OnABeat.CodingKeys.self),
        .raceFormat: .object(RaceFormat.CodingKeys.self, [
            .penalty: .object(RaceFormat.Penalty.CodingKeys.self),
            .startLine: .object(RaceFormat.StartLine.CodingKeys.self),
            .leewardGate: .object(RaceFormat.LeewardGate.CodingKeys.self),
            .offsetMark: .object(RaceFormat.OffsetMark.CodingKeys.self),
            .raceArea: .object(RaceFormat.RaceArea.CodingKeys.self),
            .startRow: .object(RaceFormat.StartRow.CodingKeys.self),
            .opening: .object(RaceFormat.Opening.CodingKeys.self),
            .beatSizing: .object(RaceFormat.BeatSizing.CodingKeys.self),
        ]),
    ])

    /// Validates the file and converts it to code units. Throws `DataFileError.invalidContent`, or `malformed`
    /// for a schema-2 to -8 file without a field its schema requires.
    func rulesConfig(id: String, schemaVersion: Int, fileData: Data) throws -> RulesConfig {
        func check(_ condition: Bool, _ reason: @autoclosure () -> String) throws {
            if !condition { throw DataFileError.invalidContent(kind: RulesConfig.kind, id: id, reason: reason()) }
        }
        func positive(_ value: Double, _ name: String) throws {
            try check(value.isFinite && value > 0, "\(name) must be positive")
        }
        func nonNegative(_ value: Double, _ name: String) throws {
            try check(value.isFinite && value >= 0, "\(name) must not be negative")
        }
        func fraction(_ value: Double, _ name: String) throws {
            try check(value.isFinite && value >= 0 && value <= 1, "\(name) must be in [0, 1]")
        }
        /// A positive duration that is a whole number of ticks, so every tick count derived from it is exact.
        func duration(_ seconds: Double, _ name: String) throws {
            try positive(seconds, name)
            let ticks = seconds * Double(Race.tickRate)
            try check(ticks == ticks.rounded(), "\(name) must be a whole number of ticks (1/\(Race.tickRate) s)")
        }
        func angle(_ degrees: Double, _ name: String, max: Double) throws -> Double {
            try check(degrees.isFinite && degrees > 0 && degrees <= max, "\(name) must be in (0, \(Int(max))] degrees")
            return deg2rad(degrees)
        }

        // builderValues: like placeholders, each must point at something in the file.
        let document = try JSONSerialization.jsonObject(with: fileData, options: [.fragmentsAllowed])
        for pointer in builderValues {
            try check(JSONPointer.resolve(pointer, in: document) != nil, "builder value \(pointer) points at nothing")
        }

        let sweep = incidents.nearMissSweep
        let sweepHeading = try angle(sweep.headingDegrees, "incidents.nearMissSweep.headingDegrees", max: 90)
        try duration(sweep.seconds, "incidents.nearMissSweep.seconds")
        try check(sweep.headingSamples >= 3 && sweep.headingSamples % 2 == 1,
                  "incidents.nearMissSweep.headingSamples must be odd and at least 3, so straight on is tried")
        try check(sweep.stepTicks >= 1, "incidents.nearMissSweep.stepTicks must be at least 1")
        try nonNegative(sweep.clearanceHullLengths, "incidents.nearMissSweep.clearanceHullLengths")

        let escape = incidents.escape
        try duration(escape.horizonSeconds, "incidents.escape.horizonSeconds")
        try check(!escape.candidates.rudder.isEmpty && escape.candidates.rudder.allSatisfy { $0.isFinite && abs($0) <= 1 },
                  "incidents.escape.candidates.rudder must list rudders in [-1, 1]")
        try check(!escape.candidates.ease.isEmpty, "incidents.escape.candidates.ease is empty")
        try check(escape.startTickOffset >= 0, "incidents.escape.startTickOffset must not be negative")
        try duration(escape.initiallySeconds, "incidents.escape.initiallySeconds")
        let candidates = escape.candidates.rudder.flatMap { rudder in
            escape.candidates.ease.map { ease in BoatInput(rudder: rudder, ease: ease) }
        }

        try positive(incidents.separationHullLengths, "incidents.separationHullLengths")
        try duration(incidents.lastPointOfCertaintySeconds, "incidents.lastPointOfCertaintySeconds")
        // Schema 5's rule 17 limits: required in schema 5, refused before it, where rule 17 is never called.
        var properCourse: RulesConfig.ProperCourseLimits?
        if schemaVersion >= 5 {
            guard let limits = incidents.properCourse else {
                throw DataFileError.malformed(kind: RulesConfig.kind, reason: "schema \(schemaVersion) needs incidents.properCourse")
            }
            try positive(limits.distanceHullLengths, "incidents.properCourse.distanceHullLengths")
            let beat = try angle(limits.beatToleranceDegrees, "incidents.properCourse.beatToleranceDegrees", max: 45)
            let reachRun = try angle(limits.reachRunToleranceDegrees, "incidents.properCourse.reachRunToleranceDegrees", max: 45)
            try duration(limits.promptlyAsternSeconds, "incidents.properCourse.promptlyAsternSeconds")
            properCourse = .init(distance: HullLengths(limits.distanceHullLengths), beatTolerance: beat,
                                 reachRunTolerance: reachRun, promptlyAstern: limits.promptlyAsternSeconds)
        } else {
            try check(incidents.properCourse == nil, "incidents.properCourse needs schema 5")
        }
        try positive(zone.radiusHullLengths, "zone.radiusHullLengths")
        try positive(markRoomGiven.roundingDistanceHullLengths, "markRoomGiven.roundingDistanceHullLengths")
        try nonNegative(markRoomGiven.clearanceHullLengths, "markRoomGiven.clearanceHullLengths")
        let beatAngle = try angle(onABeat.maxTrueWindAngleDegrees, "onABeat.maxTrueWindAngleDegrees", max: 180)

        let format = raceFormat
        try duration(format.startSequenceSeconds, "raceFormat.startSequenceSeconds")
        // Schema 6's penalty turn: optional there (absent `fullCircle`), refused before it. A `tackAndGybe` turn has no
        // start deadline and no started turn: its file has neither, and every other file needs both.
        var turn = RulesConfig.PenaltyTurn.fullCircle
        if let value = format.penalty.turn {
            try check(schemaVersion >= 6, "raceFormat.penalty.turn needs schema 6")
            guard let parsed = RulesConfig.PenaltyTurn(rawValue: value) else {
                throw DataFileError.invalidContent(
                    kind: RulesConfig.kind, id: id, reason: "raceFormat.penalty.turn must be one of "
                        + RulesConfig.PenaltyTurn.allCases.map(\.rawValue).joined(separator: ", "))
            }
            turn = parsed
        }
        try duration(format.penalty.completeSeconds, "raceFormat.penalty.completeSeconds")
        let start: Double, startedTurn: Double
        switch turn {
        case .fullCircle:
            guard let startSeconds = format.penalty.startSeconds else {
                throw DataFileError.malformed(kind: RulesConfig.kind, reason: "a fullCircle penalty needs raceFormat.penalty.startSeconds")
            }
            guard let startedTurnDegrees = format.penalty.startedTurnDegrees else {
                throw DataFileError.malformed(
                    kind: RulesConfig.kind, reason: "a fullCircle penalty needs raceFormat.penalty.startedTurnDegrees")
            }
            try duration(startSeconds, "raceFormat.penalty.startSeconds")
            try check(format.penalty.completeSeconds >= startSeconds,
                      "raceFormat.penalty.completeSeconds must not be before startSeconds")
            start = startSeconds
            startedTurn = try angle(startedTurnDegrees, "raceFormat.penalty.startedTurnDegrees", max: 360)
        case .tackAndGybe:
            try check(format.penalty.startSeconds == nil, "a tackAndGybe penalty has no raceFormat.penalty.startSeconds")
            try check(format.penalty.startedTurnDegrees == nil,
                      "a tackAndGybe penalty has no raceFormat.penalty.startedTurnDegrees")
            start = format.penalty.completeSeconds
            startedTurn = 0
        }
        // Schema 4's "changes course" test: required in schema 4, refused before it, where there is none.
        var changesCourse: Double?
        if schemaVersion >= 4 {
            guard let rate = escape.changesCourseDegreesPerSecond else {
                throw DataFileError.malformed(
                    kind: RulesConfig.kind, reason: "schema \(schemaVersion) needs incidents.escape.changesCourseDegreesPerSecond")
            }
            try positive(rate, "incidents.escape.changesCourseDegreesPerSecond")
            changesCourse = deg2rad(rate)
        } else {
            try check(escape.changesCourseDegreesPerSecond == nil, "incidents.escape.changesCourseDegreesPerSecond needs schema 4")
        }
        // Schema 7's look-back towards a boat taking a penalty: required in schema 7, refused before it, where a rule
        // 21.2 incident looks the horizon back like any other.
        if schemaVersion >= 7 {
            guard let lookBack = escape.penaltyLookBackSeconds else {
                throw DataFileError.malformed(
                    kind: RulesConfig.kind, reason: "schema \(schemaVersion) needs incidents.escape.penaltyLookBackSeconds")
            }
            try duration(lookBack, "incidents.escape.penaltyLookBackSeconds")
        } else {
            try check(escape.penaltyLookBackSeconds == nil, "incidents.escape.penaltyLookBackSeconds needs schema 7")
        }

        // Schema 3's stacking of penalty deadlines: required in schema 3 and later, refused before it, where it
        // is `fromCall`.
        var stacking = RulesConfig.StackedPenaltyDeadlines.fromCall
        if schemaVersion >= 3 {
            guard let value = format.penalty.stackedPenaltyDeadlines else {
                throw DataFileError.malformed(
                    kind: RulesConfig.kind, reason: "schema \(schemaVersion) needs raceFormat.penalty.stackedPenaltyDeadlines")
            }
            guard let parsed = RulesConfig.StackedPenaltyDeadlines(rawValue: value) else {
                throw DataFileError.invalidContent(
                    kind: RulesConfig.kind, id: id, reason: "raceFormat.penalty.stackedPenaltyDeadlines must be one of "
                        + RulesConfig.StackedPenaltyDeadlines.allCases.map(\.rawValue).joined(separator: ", "))
            }
            stacking = parsed
        } else {
            try check(format.penalty.stackedPenaltyDeadlines == nil, "raceFormat.penalty.stackedPenaltyDeadlines needs schema 3")
        }
        try duration(format.protestWindowSeconds, "raceFormat.protestWindowSeconds")
        try duration(format.finishWindowSeconds, "raceFormat.finishWindowSeconds")
        try duration(format.timeLimitSeconds, "raceFormat.timeLimitSeconds")
        try positive(format.startLine.hullLengthsPerBoat, "raceFormat.startLine.hullLengthsPerBoat")
        try positive(format.startLine.minimumMetres, "raceFormat.startLine.minimumMetres")
        try check(format.leewardGate.aboveLineBeatDivisor.isFinite && format.leewardGate.aboveLineBeatDivisor > 1,
                  "raceFormat.leewardGate.aboveLineBeatDivisor must be greater than 1")
        try positive(format.leewardGate.widthHullLengths, "raceFormat.leewardGate.widthHullLengths")
        try positive(format.offsetMark.toPortHullLengths, "raceFormat.offsetMark.toPortHullLengths")
        try positive(format.raceArea.acrossAxisBeatFraction, "raceFormat.raceArea.acrossAxisBeatFraction")
        try positive(format.raceArea.belowLineLineLengths, "raceFormat.raceArea.belowLineLineLengths")
        try positive(format.raceArea.aboveWindwardBeatFraction, "raceFormat.raceArea.aboveWindwardBeatFraction")
        // Schema 8's opening and the race area's least depth below the line: required in schema 8, which has no start
        // row, and refused before it, where the start row is required.
        var belowLineMinimum: HullLengths?
        var startRow: RulesConfig.StartRow?
        var opening: RulesConfig.Opening?
        if schemaVersion >= 8 {
            try check(format.startRow == nil, "raceFormat.startRow is gone from schema 8: the opening replaces it")
            guard let minimum = format.raceArea.belowLineMinimumHullLengths else {
                throw DataFileError.malformed(
                    kind: RulesConfig.kind, reason: "schema \(schemaVersion) needs raceFormat.raceArea.belowLineMinimumHullLengths")
            }
            try positive(minimum, "raceFormat.raceArea.belowLineMinimumHullLengths")
            belowLineMinimum = HullLengths(minimum)
            guard let file = format.opening else {
                throw DataFileError.malformed(kind: RulesConfig.kind, reason: "schema \(schemaVersion) needs raceFormat.opening")
            }
            try check(file.rowDepthsHullLengths.count == 2 && file.rowDepthsHullLengths.allSatisfy { $0.isFinite && $0 > 0 }
                      && file.rowDepthsHullLengths[0] < file.rowDepthsHullLengths[1],
                      "raceFormat.opening.rowDepthsHullLengths must be two positive depths, starboard's shallower")
            try positive(file.spreadLineLengths, "raceFormat.opening.spreadLineLengths")
            let openingAngle = try angle(file.trueWindAngleDegrees, "raceFormat.opening.trueWindAngleDegrees", max: 180)
            try check(file.easeSpeedFraction.isFinite && file.easeSpeedFraction > 0 && file.easeSpeedFraction <= 1,
                      "raceFormat.opening.easeSpeedFraction must be in (0, 1]")
            try positive(file.minimumSpacingHullLengths, "raceFormat.opening.minimumSpacingHullLengths")
            try nonNegative(file.jitterHullLengths, "raceFormat.opening.jitterHullLengths")
            opening = .init(rowDepths: file.rowDepthsHullLengths.map(HullLengths.init), spreadLineLengths: file.spreadLineLengths,
                            trueWindAngle: openingAngle, easeSpeedFraction: file.easeSpeedFraction,
                            minimumSpacing: HullLengths(file.minimumSpacingHullLengths),
                            jitter: HullLengths(file.jitterHullLengths))
        } else {
            try check(format.opening == nil, "raceFormat.opening needs schema 8")
            try check(format.raceArea.belowLineMinimumHullLengths == nil,
                      "raceFormat.raceArea.belowLineMinimumHullLengths needs schema 8")
            guard let row = format.startRow else {
                throw DataFileError.malformed(kind: RulesConfig.kind, reason: "schema \(schemaVersion) needs raceFormat.startRow")
            }
            try positive(row.depthLineLengths, "raceFormat.startRow.depthLineLengths")
            try positive(row.spreadLineLengths, "raceFormat.startRow.spreadLineLengths")
            let rowAngle = try angle(row.trueWindAngleDegrees, "raceFormat.startRow.trueWindAngleDegrees", max: 180)
            try check(row.polarSpeedFraction.isFinite && row.polarSpeedFraction > 0
                      && row.polarSpeedFraction <= 1, "raceFormat.startRow.polarSpeedFraction must be in (0, 1]")
            // Schema 2's start-row spacing floor: required in schema 2, refused in schema 1.
            var rowSpacing: HullLengths?
            if schemaVersion >= 2 {
                guard let spacing = row.minimumSpacingHullLengths else {
                    throw DataFileError.malformed(
                        kind: RulesConfig.kind, reason: "schema \(schemaVersion) needs raceFormat.startRow.minimumSpacingHullLengths")
                }
                try positive(spacing, "raceFormat.startRow.minimumSpacingHullLengths")
                rowSpacing = HullLengths(spacing)
            } else {
                try check(row.minimumSpacingHullLengths == nil,
                          "raceFormat.startRow.minimumSpacingHullLengths needs schema 2")
            }
            startRow = .init(depthLineLengths: row.depthLineLengths, spreadLineLengths: row.spreadLineLengths,
                             trueWindAngle: rowAngle, polarSpeedFraction: row.polarSpeedFraction, minimumSpacing: rowSpacing)
        }
        try fraction(format.edgeSpeedRetention, "raceFormat.edgeSpeedRetention")
        try positive(format.beatSizing.leaderSeconds, "raceFormat.beatSizing.leaderSeconds")
        try positive(format.beatSizing.maxMetres, "raceFormat.beatSizing.maxMetres")
        try positive(format.beatSizing.calibrationFactor, "raceFormat.beatSizing.calibrationFactor")

        return RulesConfig(
            incidents: .init(
                nearMissSweep: .init(heading: sweepHeading, seconds: sweep.seconds, headingSamples: sweep.headingSamples,
                                     stepTicks: sweep.stepTicks, clearance: HullLengths(sweep.clearanceHullLengths)),
                escape: .init(horizon: escape.horizonSeconds, candidates: candidates,
                              startTickOffset: escape.startTickOffset, initially: escape.initiallySeconds,
                              changesCourse: changesCourse, penaltyLookBack: escape.penaltyLookBackSeconds),
                separation: HullLengths(incidents.separationHullLengths),
                lastPointOfCertainty: incidents.lastPointOfCertaintySeconds,
                properCourse: properCourse),
            zone: .init(radius: HullLengths(zone.radiusHullLengths)),
            markRoomGiven: .init(roundingDistance: HullLengths(markRoomGiven.roundingDistanceHullLengths),
                                 clearance: HullLengths(markRoomGiven.clearanceHullLengths)),
            onABeat: .init(maxTrueWindAngle: beatAngle, windwardLegOnly: onABeat.windwardLegOnly),
            raceFormat: .init(
                startSequence: format.startSequenceSeconds,
                penalty: .init(start: start, complete: format.penalty.completeSeconds,
                               startedTurn: startedTurn, stackedPenaltyDeadlines: stacking, turn: turn),
                protestWindow: format.protestWindowSeconds,
                finishWindow: format.finishWindowSeconds,
                timeLimit: format.timeLimitSeconds,
                startLine: .init(perBoat: HullLengths(format.startLine.hullLengthsPerBoat),
                                 minimumMetres: format.startLine.minimumMetres),
                leewardGate: .init(aboveLineBeatDivisor: format.leewardGate.aboveLineBeatDivisor,
                                   width: HullLengths(format.leewardGate.widthHullLengths)),
                offsetMark: .init(toPort: HullLengths(format.offsetMark.toPortHullLengths)),
                raceArea: .init(acrossAxisBeatFraction: format.raceArea.acrossAxisBeatFraction,
                                belowLineLineLengths: format.raceArea.belowLineLineLengths,
                                aboveWindwardBeatFraction: format.raceArea.aboveWindwardBeatFraction,
                                belowLineMinimum: belowLineMinimum),
                startRow: startRow,
                opening: opening,
                edgeSpeedRetention: format.edgeSpeedRetention,
                beatSizing: .init(leaderSeconds: format.beatSizing.leaderSeconds, maxMetres: format.beatSizing.maxMetres,
                                  calibrationFactor: format.beatSizing.calibrationFactor)),
            builderValues: builderValues)
    }
}
