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
    /// The chance, each time she meets a boat she must keep clear of under a rule in `misjudgeScope`, that she
    /// misjudges the encounter (#19, #103: "they foul only by misjudging"): she believes she holds her rights and sails
    /// on, so fails to keep clear. Drawn once an encounter, never a turn towards the other boat; none from National's
    /// band up.
    public var ruleMisjudgeRate: Double
    /// Hand steering (#435), felt only in a class whose autohelm doesn't hold a centred rudder (`BotHelm`): seconds she
    /// sails her old heading after a shift or puff reaches her before she re-aims to the new wind (`HandSteering`).
    public var shiftLag: Double
    /// Hand steering (#435): radians, at most, of her slow drift around her aim, seeded per boat (further running,
    /// `HandSteeringTable.downwindWander`).
    public var wander: Double
    /// Hand steering (#435): radians past the new wind when she re-aims to a shift, decaying back to her aim.
    public var overshoot: Double

    public init(startTiming: Double, lineBiasMisread: Double, reactionDelay: Double, laylineMisjudge: Double,
                angleMissRate: Double, angleMissSize: Double, puffPerception: Double, currentSense: Double,
                rollHitRate: Double, tacticalQuality: Double, keepClearLookahead: Double = 4.5,
                ruleMisjudgeRate: Double = 0, shiftLag: Double = 0, wander: Double = 0, overshoot: Double = 0) {
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
        self.shiftLag = shiftLag
        self.wander = wander
        self.overshoot = overshoot
    }

    /// No weaknesses: a bot-suite profile's (#231). Her start timing and keep-clear lookahead are her style's as
    /// before #102 and #103; she misjudges no rule, and steers by hand perfectly (#435).
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
        shiftLag = HandSteeringTable.shiftLagScale * deficit
        wander = HandSteeringTable.wanderScale * deficit
        overshoot = HandSteeringTable.overshootScale * deficit
    }

    /// These weaknesses with `other`'s hand steering (#435): e.g. a stand-in's Club hand steering on her own tactics.
    public func steering(like other: BotWeaknesses) -> BotWeaknesses {
        var weaknesses = self
        weaknesses.shiftLag = other.shiftLag
        weaknesses.wander = other.wander
        weaknesses.overshoot = other.overshoot
        return weaknesses
    }

    /// Club hand steering (#435): the hand-steering weaknesses at the centre of Club's band, on none of anything else.
    public static var clubHandSteering: BotWeaknesses {
        let skill = BotTier.club.skill(at: 0.5)
        return none(skill: skill).steering(like: BotWeaknesses(skill: skill))
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

    /// The rules whose encounters she can misjudge (#103): the give-way rules, rules 10, 11 and 12, racing and before
    /// her start (#280), and the mark-room she owes (18.2). Not rule 13 (a tacking boat finishes her tack whatever she
    /// believes) or rule 21 (her penalty turns and her return from OCS keep clear of every boat). Not rule 17 either,
    /// deliberately (#346): a bot held to her proper course sails within it by construction (`properCourseLimited`),
    /// so never breaches it; add it here should weaker bots become catchable sailing above it.
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

/// Hand steering's placeholder values (#435, #426 Q7), one table for the owner to tune: each scales with her skill
/// deficit (1 − skill), as `reactionDelay` does, so none at skill 1. Club's centre (deficit ≈ 0.53): lag ≈ 2.1 s, wander
/// ≈ 7.4° (≈ 12° running), overshoot ≈ 5.3°; National's (0.1): ≈ 0.4 s, 1.4°, 1°. Tuned towards #426's T1 placeholders
/// (Club ≈ 6 s a beat and ≈ 4 s a run behind a perfect hand, the handling mix). Wander and overshoot carry the cost: the
/// skiff gains speed in 2.5 s and loses it over 10 s, so a short swing off her aim, as the lag gives, nearly pays for
/// itself. Read by `BotWeaknesses(skill:)` and `HandSteering`.
public enum HandSteeringTable {
    /// Seconds of shift lag at skill 0.
    public static let shiftLagScale = 4.0
    /// Radians of wander amplitude at skill 0.
    public static let wanderScale = deg2rad(14)
    /// Her wander abaft the beam, as a share of her wander forward of it: running, she wanders further.
    public static let downwindWander = 1.6
    /// Seconds a wander cycle lasts, drawn per boat from her seed inside this range.
    public static let wanderPeriod = 20.0...40.0
    /// Radians of overshoot at skill 0: past the new wind on every re-aim to a shift.
    public static let overshootScale = deg2rad(10)
    /// Seconds an overshoot takes to decay back to her aim, linearly.
    public static let overshootDecay = 2.0
    /// Radians the wind at her must swing from the wind she steers by before she notices a shift.
    public static let shiftNoticed = deg2rad(1)
    /// The share the wind speed at her must change from the speed she steers by before she notices a puff or lull.
    public static let puffNoticed = 0.1
}
