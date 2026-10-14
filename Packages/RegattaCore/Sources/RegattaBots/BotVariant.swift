import Foundation

// PROTOTYPE (#525, never merged): variant letters read once from REGATTA_BOT_VARIANT, so one binary sails every variant.
//  1 2 3: the hand fixes (traffic term in the gate pick / entitled boats are not keep-clear / tighter tap clearance)
//  H: all three.   P: the look-ahead planner for the gate pick.   t: planner roll-out has others at their turn rate.
public enum BotVariant {
    public static let flags: Set<Character> = Set(ProcessInfo.processInfo.environment["REGATTA_BOT_VARIANT"] ?? "")
    public static func on(_ c: Character) -> Bool { flags.contains(c) }
    /// A hand-fix part: its own digit or H.
    public static func hand(_ c: Character) -> Bool { flags.contains(c) || flags.contains("H") }
    public static func number(_ name: String, _ fallback: Double) -> Double {
        ProcessInfo.processInfo.environment[name].flatMap(Double.init) ?? fallback
    }
    /// A per-decision trace of the gate leg on stderr.
    public static let traces = ProcessInfo.processInfo.environment["REGATTA_GATE_TRACE"] != nil
}
