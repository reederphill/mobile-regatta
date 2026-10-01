import Foundation
import RegattaCore

/// The plain-words text of a rule call (#23): the first time a rule number is called on you, in your favour or
/// against you, the call spells the rule out; after that the line and its badge on the water carry it (#123), with
/// no notice. `RuleSeenStore` keeps which numbers this device has seen.
enum RuleWords {
    /// The rule in a sentence, by number. Every rule that reaches a call today has its own (10, 11, 12, 13, 15, 16.1,
    /// 21.1, 21.2 as `ruleCall`, 31 as `markTouch`); the rest fall back to the rule's title.
    // TODO-COPY (#171): placeholder wording for every sentence here.
    static func plain(_ rule: RacingRule) -> String {
        switch rule {
        case .portStarboard: "A boat on port tack keeps clear of a boat on starboard"
        case .windwardLeeward: "Overlapped on the same tack, the windward boat keeps clear"
        case .clearAstern: "A boat clear astern keeps clear of the boat ahead"
        case .whileTacking: "A boat that is tacking keeps clear until she is on her new course"
        case .acquiringRightOfWay: "A boat that gains right of way first gives the other room to keep clear"
        case .changingCourse: "A right-of-way boat that changes course gives the other room to keep clear"
        case .returningToStart: "A boat returning to start keeps clear of the boats that have started"
        case .takingAPenalty: "A boat taking a penalty turn keeps clear of the others"
        case .touchingMark: "Don't touch a mark of your course"
        case .markRoomApplies, .givingMarkRoom, .tackingInTheZone, .sailingTheCourse, .individualRecall,
             .exoneratedCompelled, .exoneratedEntitledRoom:
            rule.title
        }
    }

    /// The keep-clear rules a shift can carry a boat into while her autohelm holds her wind angle (#228).
    static let keepClearRules: Set<RacingRule> = [.portStarboard, .windwardLeeward, .clearAstern, .whileTacking]

    // TODO-COPY (#171): one penalty turn, never "360" or "720" (#9, CONTEXT.md **Penalty turn**).
    static let penaltyLine = "Sail one full circle to clear it."

    // TODO-COPY (#171): #228's example, for a keep-clear call made while your autohelm was holding.
    static let autohelmKeepClear = "Your boat kept its angle to the wind as it shifted; steer to keep clear"

    /// The first call of `rule` on you, against you or in your favour, with `other` the other boat's label.
    /// `owesTurn` is false for a call that adds no turn (44.1(a), #90). `autohelm` puts #228's words in place of the
    /// rule's.
    // TODO-COPY (#171)
    static func firstCall(_ rule: RacingRule, against: Bool, other: String, owesTurn: Bool,
                          autohelm: Bool = false) -> String {
        let sentence = "\(autohelm ? autohelmKeepClear : plain(rule)) (rule \(rule.rawValue))."
        guard against else { return "\(sentence) \(other) fouled you." }
        return "\(sentence) You fouled \(other)." + (owesTurn ? " \(penaltyLine)" : "")
    }

    /// Touching a mark of your course, the first time (rule 31, #90).
    // TODO-COPY (#171)
    static func firstMarkTouch(_ mark: String) -> String {
        "\(plain(.touchingMark)) (rule 31): you touched the \(mark). \(penaltyLine)"
    }

    /// The OCS notice, under rule 29.1 (never "Rule 22").
    // TODO-COPY (#171)
    static let ocs = "OCS (rule 29.1): you were over at the gun. Dip back below the line, then start."

    /// The RTT warning (#18, #68), once as it starts.
    // TODO-COPY (#171)
    static let lag = "Slow connection: your boat may jump."

    /// The most a mark-room notice may be: one line under the top readouts (#15).
    static let markRoomLimit = 40

    /// A mark-room notice to one of its two boats (#15): yours, or the other boat's to give. Never over
    /// `markRoomLimit` characters: a long name or mark drops out first.
    // TODO-COPY (#171)
    static func markRoom(at mark: String, entitled: Bool, other: String) -> String {
        let candidates = entitled
            ? ["Mark-room at the \(mark) is yours", "Mark-room is yours"]
            : ["Give \(other) room at the \(mark)", "Give mark-room at the \(mark)", "Give mark-room"]
        return candidates.first { $0.count <= markRoomLimit && !$0.contains("\n") } ?? candidates[candidates.count - 1]
    }
}

/// Which rule numbers this device has seen called, for plain words (#23): kept with hint progress under
/// `DeviceSettings.hintKeyPrefix`, so Settings' Reset hints clears it with them. Read through every time, never
/// cached, so a reset takes effect at the next call. In memory (tests, fixtures) unless given defaults.
final class RuleSeenStore {
    static let rulesKey = DeviceSettings.hintKeyPrefix + "rulesSeen"
    /// #228's autohelm keep-clear words, once per device.
    static let autohelmKey = DeviceSettings.hintKeyPrefix + "autohelmKeepClear"

    private let defaults: UserDefaults?
    private var memory: [String: Any] = [:]

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
    }

    func hasSeen(_ rule: RacingRule) -> Bool {
        seenRules.contains(rule.rawValue)
    }

    func markSeen(_ rule: RacingRule) {
        let seen = seenRules
        guard !seen.contains(rule.rawValue) else { return }
        set(seen + [rule.rawValue], forKey: Self.rulesKey)
    }

    var hasSeenAutohelmKeepClear: Bool {
        value(forKey: Self.autohelmKey) as? Bool ?? false
    }

    func markAutohelmKeepClearSeen() {
        set(true, forKey: Self.autohelmKey)
    }

    private var seenRules: [String] {
        value(forKey: Self.rulesKey) as? [String] ?? []
    }

    private func value(forKey key: String) -> Any? {
        if let defaults { return defaults.object(forKey: key) }
        return memory[key]
    }

    private func set(_ value: Any, forKey key: String) {
        if let defaults { defaults.set(value, forKey: key) } else { memory[key] = value }
    }
}
