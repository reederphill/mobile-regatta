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
    // Tunables (sliders), read once.
    /// H3: hull lengths a gybe may pass a boat that owes her room.
    static let h3Lengths = number("REGATTA_H3_LENGTHS", 0.6)
    /// H1: metres from the line to a mark's point within which a boat ahead blocks it, and the metres it costs at zero offset.
    static let h1Near = number("REGATTA_H1_NEAR", 25)
    static let h1BoatMetres = number("REGATTA_H1_BOAT_M", 30)
    /// H1: weight of the metres lost to other boats' wake on the way to a point.
    static let h1ShadowWeight = number("REGATTA_H1_SHADOW_W", 1.5)
    /// H1: least distance to her point at which she gybes out of shadow on the rounding gybe, metres.
    static let h1GybeMin = number("REGATTA_H1_GYBE_MIN", 45)
    /// A per-decision trace of the gate leg on stderr.
    public static let traces = ProcessInfo.processInfo.environment["REGATTA_GATE_TRACE"] != nil
}
