import RegattaCore

/// What a bot's skill costs her (#19, #102): one skill value from 0 to 1 drives every weakness together, each
/// a continuous function of it. A tier is a skill band (`BotTier`), so tiers differ only by the skills their bands
/// put into these functions, never by a per-tier case; and a bot is never a slower boat: nothing here touches her
/// boat, only what she chooses to send (`BotTierTests.allTiersShareBoatPhysics`). The curves are placeholders
/// for #105 to tune; each weakness is its own value here, so #103 can add to the set without touching the others.
///
/// A live bot sails with her skill's weaknesses; a bot-suite profile (`BotProfile`) sails with none, since its
/// numbers measure the autohelm's skill gap (#231), not a tier.
public struct BotWeaknesses: Hashable, Sendable {
    /// How much of her start risk (`BotStyle.timingSlack`) shows in her time at the line: her start timing error.
    /// One mapping of skill (#99's review: it used to be scaled by skill twice, in the draw and in use).
    public var startTiming: Double
    /// Radians, at most, by which she misreads the start line's bias, times her style's draw (`BotStyle.lineBiasDraw`):
    /// she reckons one end favoured when it isn't, and sets up towards it (`BotBrain.startPoint`).
    public var lineBiasMisread: Double
    /// Seconds late she reads the wind's direction at her boat (the observation delay line, `Senses.windHistory`):
    /// she reacts to shifts this much after they reach her.
    public var reactionDelay: Double
    /// Radians, at most, by which she misjudges a layline, drawn afresh for each leg: past it she overstands,
    /// short of it she understands and has to tack again.
    public var laylineMisjudge: Double
    /// The share of her groove choices that miss (#219, #231): she pinches or foots off the groove, past the
    /// autohelm's snap to it, instead of letting it snap her in.
    public var angleMissRate: Double
    /// Radians past the snap width by which a missed groove choice is off, at most.
    public var angleMissSize: Double
    /// Metres ahead she notices puffs and lulls on the water (#19: "they only notice nearby puffs"); 0 notices none.
    public var puffPerception: Double
    /// How much of the current she allows for, 0…1 (#19): 0 at Club, which sails by the wind alone, laylines
    /// included (#100); 1 at National, which plays the set and the turn of the tide from the forecast.
    public var currentSense: Double
    /// The share of her roll tacks that hit (#222, #263): none below `rollSkillFloor`. #263's roll mechanic sends
    /// the input; this is only the rate.
    public var rollHitRate: Double
    /// How well she times her cover and lee-bow, 0…1 (#223): the knob fleet tactics (#234) read.
    public var tacticalQuality: Double
    /// Seconds ahead she looks for a collision she must keep clear of (#103): further, the more skilled she is. She
    /// projects the other boat on in a straight line at its velocity now, refreshed every decision, so a boat whose
    /// autohelm follows a shift is predicted on its new course as soon as it turns.
    public var keepClearLookahead: Double
    /// The chance, each time she meets a boat she must keep clear of racing under a rule in `misjudgeScope`, that she
    /// misjudges the encounter (#19, #103: "they foul only by misjudging"): she believes she holds her rights and sails
    /// on, so fails to keep clear. Drawn once an encounter, never a turn towards the other boat; none from National's
    /// band up.
    public var ruleMisjudgeRate: Double

    public init(startTiming: Double, lineBiasMisread: Double, reactionDelay: Double, laylineMisjudge: Double,
                angleMissRate: Double, angleMissSize: Double, puffPerception: Double, currentSense: Double,
                rollHitRate: Double, tacticalQuality: Double, keepClearLookahead: Double = 4.5,
                ruleMisjudgeRate: Double = 0) {
        self.startTiming = startTiming
        self.lineBiasMisread = lineBiasMisread
        self.reactionDelay = reactionDelay
        self.laylineMisjudge = laylineMisjudge
        self.angleMissRate = angleMissRate
        self.angleMissSize = angleMissSize
        self.puffPerception = puffPerception
        self.currentSense = currentSense
        self.rollHitRate = rollHitRate
        self.tacticalQuality = tacticalQuality
        self.keepClearLookahead = keepClearLookahead
        self.ruleMisjudgeRate = ruleMisjudgeRate
    }

    /// No weaknesses: a bot-suite profile's (#231). Her start timing and keep-clear lookahead are her style's as
    /// before #102 and #103; she misjudges no rule.
    public static func none(skill: Double) -> BotWeaknesses {
        let own = BotWeaknesses(skill: skill)
        return BotWeaknesses(startTiming: own.startTiming, lineBiasMisread: 0, reactionDelay: 0,
                             laylineMisjudge: 0, angleMissRate: 0, angleMissSize: 0, puffPerception: fullPuffPerception,
                             currentSense: 0, rollHitRate: 1, tacticalQuality: 1,
                             keepClearLookahead: own.keepClearLookahead, ruleMisjudgeRate: 0)
    }

    /// The weaknesses of a bot of `skill`, 0…1. Placeholders (#102), landing on the Build's named endpoints at
    /// the bot-tier file's band centres (Club ~0.48, Regional 0.7, National 0.9): current sense none at Club and
    /// the forecast at National; roll-tack hit rate ~30 % at Club and ~80 % at National.
    public init(skill: Double) {
        let s = min(max(skill, 0), 1)
        let deficit = 1 - s
        startTiming = (1.3 - s) * deficit
        lineBiasMisread = Self.lineBiasMisread(skill: s)
        reactionDelay = 8 * deficit
        laylineMisjudge = deg2rad(20) * deficit
        angleMissRate = min(1, 1.8 * deficit)
        angleMissSize = deg2rad(3 + 30 * deficit)
        puffPerception = Self.fullPuffPerception * Self.ramp(s, from: 0.5, to: 0.9)
        currentSense = Self.currentSense(skill: s)
        rollHitRate = Self.rollHitRate(skill: s)
        tacticalQuality = Self.ramp(s, from: 0.35, to: 0.9)
        keepClearLookahead = Self.keepClearLookahead(skill: s)
        ruleMisjudgeRate = Self.ruleMisjudgeRate(skill: s)
    }

    /// Metres ahead a bot that notices every puff looks: the far end of `BotBrain.puffLookAhead`.
    public static let fullPuffPerception = 150.0
    /// The skill below which she never rolls a tack (#263).
    public static let rollSkillFloor = 0.4

    /// Radians, at most, by which a bot of `skill` misreads the start line's bias: growing with the square of her
    /// deficit, and none from National's band (0.8) up, which reads the line (#102's fix loop: a misread spot, however
    /// small, moved #99's pin-style Nationals out of the pin third).
    public static func lineBiasMisread(skill: Double) -> Double {
        let deficit = 1 - skill
        return deg2rad(8) * deficit * deficit * (1 - ramp(skill, from: 0.7, to: 0.8))
    }

    /// 0 at Club and below (skill 0.6), 1 from National's centre (0.9) up, in proportion between.
    public static func currentSense(skill: Double) -> Double { ramp(skill, from: 0.6, to: 0.9) }

    /// ~30 % at Club's centre, ~80 % at National's, along a line through them; none below `rollSkillFloor`.
    public static func rollHitRate(skill: Double) -> Double {
        guard skill >= rollSkillFloor else { return 0 }
        let rate = 0.3 + (skill - 0.475) * (0.8 - 0.3) / (0.9 - 0.475)
        return min(max(rate, 0), 0.95)
    }

    /// Seconds ahead a bot of `skill` looks for a collision she must keep clear of: 2.5 s at skill 0 to 4.5 s at 1,
    /// #99's and #101's tuned lookahead, now a weakness of its own (#103, placeholder).
    public static func keepClearLookahead(skill: Double) -> Double { 2.5 + 2 * skill }

    /// The rules whose encounters she can misjudge (#103): the give-way rules racing, rules 10, 11 and 12, and the
    /// mark-room she owes (18.2). Not rule 13 (a tacking boat finishes her tack whatever she believes), rule 21 (her
    /// penalty turns and her return from OCS keep clear of every boat) or her conduct before her start (#99, #280).
    public static let misjudgeScope: Set<RacingRule> = [.portStarboard, .windwardLeeward, .clearAstern, .givingMarkRoom]

    /// How fast her misjudging grows with her skill deficit (#103, placeholder): her chance is this times the square of
    /// her deficit, at most 1.
    public static let ruleMisjudgeScale = 1.8

    /// The chance a bot of `skill` misjudges an encounter in `misjudgeScope`: growing with the square of her deficit
    /// (`ruleMisjudgeScale`), and none from National's band (0.8) up, as `lineBiasMisread` fades (#103: the
    /// all-National fleet conduct gate must not get worse). Placeholders: ~50 % at Club's centre, ~29 % where Club
    /// meets Regional (0.6), ~16 % at Regional's centre, fading to none at National's bottom (0.8). Most encounters need nobody to give way, so most misjudgements
    /// cost nothing; a crossing or a converging overlap is where one fouls.
    public static func ruleMisjudgeRate(skill: Double) -> Double {
        let deficit = 1 - skill
        return min(1, ruleMisjudgeScale * deficit * deficit) * (1 - ramp(skill, from: 0.7, to: 0.8))
    }

    /// 0 at `a` and below, 1 at `b` and above, linear between.
    static func ramp(_ x: Double, from a: Double, to b: Double) -> Double {
        min(max((x - a) / (b - a), 0), 1)
    }
}
