import RegattaCore

/// PROBE (#464, prototype branch only, never merged): what the brain decided and why, for the rounding probe to read
/// after each decision. Written by `BotBrain.navigate`, `waypoint` and `sail`; read through `BotDriver.probe`.
public struct BotProbeTrace: Sendable, Equatable {
    /// The `navigate` branch taken: "up-corridor", "up-layline-P", "up-layline-S", "up-fleet", "up-hold", "down-corridor",
    /// "down-layline-P", "down-layline-S", "down-fleet", "down-hold", "reach", "finish", "penalty", "none".
    public var branch = "none"
    /// The target `navigate` was given (the waypoint less the current allowance).
    public var target = Vec2.zero
    /// Which waypoint `waypoint` chose: "W-fetch", "W-lead", "W-above-right", "W-above-left", "W-stage1", "O-direct",
    /// "O-via", "O-stage1", "gate-centre", "gate-stage1", "finish".
    public var waypoint = ""
    /// What steered her off her plan this decision: "", "keepClear", "avoidMarks", "edge", "shoot".
    public var evasion = ""
    /// The rule she kept clear under, when `evasion` is "keepClear".
    public var keepClearRule = ""
    /// Whether her hand is turning a tack or gybe this decision, and whether that turn is a flubbed one.
    public var handTurning = false
    public var handTurnFlubbed = false
    /// The aim's angle (degrees) and tack, and whether it is a pinch off the groove (`upwindAim`).
    public var aimAngleDeg = 0.0
    public var aimTack = Tack.starboard
    public var pinching = false
    /// Her layline misjudgement this leg, degrees (`laylineOverstand` less the rules' own overstand).
    public var laylineErrorDeg = 0.0
    /// The target's bearing from the wind, degrees (to the right positive), and her lateral offset from the corridor's
    /// centre against its half width, metres.
    public var relativeDeg = 0.0
    public var lateral = 0.0
    public var corridor = 0.0
    /// Whether the plan wants the other tack but she can't tap or turn yet (`canTap` false), and why.
    public var wantsOtherTack = false
    public var cantTapWhy = ""

    public init() {}
}
