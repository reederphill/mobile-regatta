import Foundation
import RegattaCore

/// How a boat is drawn this frame (#117, #22): which side her sail is on and how far it is trimmed out, how hard
/// it flutters, how far she heels, whether a roll tack's cue shows, and whether she is a ghost. The one place a
/// boat's look is derived from her state.
///
/// A pure function of existing sim state: the boat's public fields, her held ease (`BoatInput.ease`, which every
/// client holds for every seat, ADR 0005) and whether she is a ghost (`Race.isGhost(seat:)`). It adds no heel
/// variable, physics or skill, and it never reads her id, colour or whether she is yours: every boat in the same
/// state takes the same pose, whatever her livery or setting (#22). Presentation only: nothing here reaches the
/// race (ADR 0002).
///
/// The base pose, plus #122's pinch/foot sail-shape cue (#219) from her autohelm's offset from the groove: the
/// same for every boat in the same state, as the rest. #127's far tier keeps `heel` and `sailSide` apart from
/// `flutter`.
nonisolated struct BoatPose: Equatable, Sendable {
    /// The cue a roll tack (#222, #263) shows while it lasts.
    enum RollCue: Equatable, Sendable {
        /// A hit: the sail snaps full, no flutter.
        case snap
        /// A miss: the sail flogs hard (`BoatStyle.flogSeconds` from when it is first drawn).
        case flog
    }

    /// The side the boom and sail are on (`Boat.boomSide`): to leeward, except by the lee. It crosses only when
    /// she tacks or gybes, so the sail swings across on a gybe.
    var sailSide: BoomSide
    /// Her leeward side, from the wind off her bow (`BoomSide.leeward(ofRelativeWind:)`): where her heel drops her
    /// and her drop shadow falls. The same as `sailSide` except by the lee, when the boom is to windward.
    var leeSide: BoomSide
    /// How far the sail is let out from the centreline, radians, 0 (sheeted amidships) up to
    /// `BoatStyle.maxTrimDegrees`.
    var sailTrim: Double
    /// How hard the sail flutters, 0 (drawing) to 1 (flapping): eased, head to wind, by the lee or starved of
    /// pressure. A roll miss's flog is `roll`, on top.
    var flutter: Double
    var roll: RollCue?
    /// How far she heels, 0 (upright) to 1 (overpowered): her hull drawn narrower and her drop shadow offset to
    /// leeward (`leeSide`).
    var heel: Double
    var isGhost: Bool
    /// Pinched (#219), 0 to 1: how far her sail's leading edge lifts. 0 on the groove, footing or hand steering.
    var luffLift = 0.0
    /// The sail's belly, 1 for its base shape: flatter pinched, fuller footed (#219). Footed, `sailTrim` is
    /// eased too.
    var sailFullness = 1.0
    /// Wiped out (#429 prototype): hull on her side, sail flat on the water.
    var isWipedOut = false
    /// Spray off her leeward side (#429 prototype), 0 to 1: heel past `BoatStyle.sprayHeel`.
    var spray = 0.0

    /// `boat`'s pose in `boatClass`. `ease` is her held ease; `isGhost` whether she has stopped racing, as the
    /// race shows it (`Race.isGhost(seat:)`); `autohelm` what her autohelm holds (`RenderWorld.autohelm(ofSeat:)`),
    /// nil while her rudder is held, for the sail-shape cue.
    init(_ boat: Boat, ease: Bool, isGhost: Bool, boatClass: BoatClass, style: BoatStyle = .standard,
         autohelm: Autohelm.Reading? = nil) {
        sailSide = boat.boomSide
        leeSide = BoomSide.leeward(ofRelativeWind: boat.relativeWind)
        self.isGhost = isGhost
        guard !isGhost else {
            // Limp, amidships: she isn't sailing any more.
            sailTrim = 0
            flutter = 0
            roll = nil
            heel = 0
            return
        }

        let maxTrim = deg2rad(style.maxTrimDegrees)
        let minTrim = min(deg2rad(style.minTrimDegrees), maxTrim)
        let twa = boat.twa
        // The sail trims to the wind it feels: the apparent wind off the bow, or the sailing wind's before the
        // race has given her one.
        let awa = Self.apparentAngle(boat)
        let headToWind = Self.isHeadToWind(boat, boatClass: boatClass, style: style)

        var flutter = 0.0
        if ease {
            // Sheets out: the sail weathervanes to the wind and flaps.
            sailTrim = awa.clamped(to: minTrim...maxTrim)
            flutter = 1
        } else if headToWind {
            sailTrim = deg2rad(style.headToWindTrimDegrees)
            flutter = 1
        } else if boat.isByTheLee {
            // The wind comes over the boom's side: the sail is out as far as it goes and lifts at the leech.
            sailTrim = maxTrim
            flutter = style.byTheLeeFlutter
        } else {
            sailTrim = (awa * style.trimPerApparentAngle).clamped(to: minTrim...maxTrim)
            // The sail-shape cue (#219), only on a sail that draws: the luff lifts pinched; footed, eased and full.
            let cue = Self.grooveCue(autohelm, style: style)
            luffLift = cue.pinch
            sailTrim = min(sailTrim + deg2rad(style.footEaseDegrees) * cue.foot, maxTrim)
            sailFullness = 1 + style.footFullness * cue.foot - style.pinchFlatten * cue.pinch
        }
        flutter = max(flutter, Self.starved(boat, style: style) * style.starvedFlutter)

        switch boat.roll {
        case .hit:
            roll = .snap
            flutter = 0
        case .missed:
            roll = .flog
        case .pending, nil:
            roll = nil
        }
        self.flutter = flutter.clamped(to: 0...1)

        if boatClass.overpowered != nil {
            // #429 prototype: the sim's heel, eased or not.
            heel = boat.heel
            spray = ((boat.heel - style.sprayHeel) / max(0.01, 1 - style.sprayHeel)).clamped(to: 0...1)
            if ease && boat.heel > 0.05 {
                // Depowering: the luff lifts and shivers while she bleeds off heel.
                luffLift = 1
            }
            if boat.isWipedOut {
                isWipedOut = true
                heel = 1
                spray = 0
                sailTrim = .pi / 2
                self.flutter = 0
                luffLift = 0
                roll = nil
            }
        } else {
            heel = ease || headToWind ? 0 : Self.heel(felt: Self.feltWind(boat), twa: twa, style: style)
        }
    }

    /// The apparent wind off her bow, radians (0...π), as her sail trims to it: the sailing wind's angle before the race
    /// has given her an apparent wind (`SailTrim.apparentAngle`, the sim's).
    static func apparentAngle(_ boat: Boat) -> Double { SailTrim.apparentAngle(boat) }

    /// Head to wind: so close past the class's no-go angle (`BoatStyle.headToWindMarginDegrees`) her sail doesn't draw.
    static func isHeadToWind(_ boat: Boat, boatClass: BoatClass, style: BoatStyle) -> Bool {
        boat.twa < BoatDynamics.noGoAngle(boatClass.polar) + deg2rad(style.headToWindMarginDegrees)
    }

    /// The angle between her drawn sail and her apparent wind, radians, 0 up (#377): how hard the sail she shows turns
    /// the air. 0 head to wind and with her sheets out; otherwise the apparent angle less `sailTrim`. Without her
    /// autohelm's footed ease (#219). At `BoatStyle.standard` it is the sim's `SailTrim.standard.angleOfAttack`, which
    /// sets her ribbons' emission and her backwind (`BoatPoseTests`' parity test).
    static func angleOfAttack(_ boat: Boat, ease: Bool, boatClass: BoatClass, style: BoatStyle = .standard) -> Double {
        guard !isHeadToWind(boat, boatClass: boatClass, style: style) else { return 0 }
        let pose = BoatPose(boat, ease: ease, isGhost: false, boatClass: boatClass, style: style)
        return max(0, apparentAngle(boat) - pose.sailTrim)
    }

    /// How far the autohelm pinches and foots (#219), each 0 to 1: its offset from the groove past
    /// `BoatStyle.grooveCueDeadbandDegrees`, full at `grooveCueFullDegrees`. Nothing while it tacks or gybes her
    /// (`isTapping`), the rudder is held, or it holds an angle out on a reach (`Autohelm.Reading.grooveOffset`).
    static func grooveCue(_ reading: Autohelm.Reading?, style: BoatStyle) -> (pinch: Double, foot: Double) {
        guard let offset = reading?.grooveOffset(style: style).map(rad2deg) else { return (0, 0) }
        let span = max(style.grooveCueFullDegrees - style.grooveCueDeadbandDegrees, 0.001)
        let amount = ((abs(offset) - style.grooveCueDeadbandDegrees) / span).clamped(to: 0...1)
        return offset < 0 ? (amount, 0) : (0, amount)
    }

    /// The pressure her sails feel, m/s: the sailing wind less any wind shadow or backwind (#220).
    ///
    /// Shadowed for every class, speed-loss classes included (`BoatClass.WindShadow.isSpeedLoss`, where the sim takes the
    /// shadow off her speed rather than her wind): the shadow stands for turbulent air, so in it her heel drops and
    /// her sail reads starved. The speed loss is only the gameplay mechanic; what she is drawn feeling is the
    /// turbulence. Don't "fix" this to the unshadowed wind for those classes (owner, 2026-09-30).
    static func feltWind(_ boat: Boat) -> Double {
        boat.sailingWind.speed * boat.shadow
    }

    /// The pressure she feels against her own recent average (#220): `feltWind` over `Boat.averagedWindSpeed`,
    /// above 1 in a puff and below it in a lull, shadow or backwind. 1 for a class with no average, as `starved`.
    static func pressure(_ boat: Boat) -> Double {
        guard let average = boat.averagedWindSpeed, average > 0.01 else { return 1 }
        return feltWind(boat) / average
    }

    /// How starved of pressure she is (#220), 0 to 1: how far the pressure she feels is under her own recent average
    /// (`Boat.averagedWindSpeed`, the class's groove average), past `BoatStyle.starvedDeadband`, as a share of
    /// `starvedFullLoss`. A class with no average reads the wind right now, so never looks starved.
    static func starved(_ boat: Boat, style: BoatStyle) -> Double {
        guard let average = boat.averagedWindSpeed, average > 0.01 else { return 0 }
        let loss = (average - feltWind(boat)) / average
        let span = max(style.starvedFullLoss - style.starvedDeadband, 0.001)
        return ((loss - style.starvedDeadband) / span).clamped(to: 0...1)
    }

    /// Heel for `felt` m/s of pressure at `twa`: nothing below `heelOnsetKnots`, rising to full at `heelFullKnots`
    /// (overpowered), most on a beam reach and least dead downwind, times `heelScale`. Never less in more wind.
    static func heel(felt: Double, twa: Double, style: BoatStyle) -> Double {
        let knots = knots(metresPerSecond: max(felt, 0))
        let span = max(style.heelFullKnots - style.heelOnsetKnots, 0.001)
        let ramp = ((knots - style.heelOnsetKnots) / span).clamped(to: 0...1)
        let angle = max(sin(twa), 0)
        return (ramp * angle * style.heelScale).clamped(to: 0...1)
    }
}

/// Every number boats are drawn with (#117), in one value, the same for every boat: the heel ramp and look, the
/// sail's trim and flutter, the roll cues, your glow and the ghost's fade. The debug tuning panel (#232) puts a
/// slider on the feel values, and `GameScene.boatStyle` takes a new one live. App-side and never logged: nothing
/// here reaches the simulation. Every default is a placeholder until tuned there.
nonisolated struct BoatStyle: Codable, Equatable, Sendable {
    // MARK: Heel

    /// Below this pressure at the boat, knots, she sails upright.
    var heelOnsetKnots = 6.0
    /// At this pressure, knots, she is overpowered: full heel on a beam reach.
    var heelFullKnots = 18.0
    /// A gain on the heel she shows, applied before heel is capped at 1 (overpowered). Above 1 it still acts:
    /// she reaches the cap in less wind, and off a beam reach (close-hauled, broad), where `sin(twa)` keeps her
    /// under it at 1, she heels more. So its tuning slider runs to 2.
    var heelScale = 1.0
    /// How much narrower her hull draws at full heel, a fraction of her beam.
    var heelNarrowing = 0.3 // #429 prototype: was 0.14; the sim's heel is 0 until she is overpowered
    /// How far her drop shadow sits to leeward at full heel, in beams.
    var heelShadowOffset = 0.22
    /// The drop shadow's alpha at full heel; less heel, fainter.
    var heelShadowAlpha = 0.35
    /// #429 prototype: heel from which she throws spray off her leeward side.
    var sprayHeel = 0.6
    /// #429 prototype: the puff tick shows only this far or more from the groove tick, degrees.
    var puffTickMinDegrees = 2.0
    /// #429 prototype: how narrow her hull draws wiped out (on her side), a fraction of her beam.
    var wipeoutHullScale = 0.35

    // MARK: Sail

    /// The sail's trim off the centreline for each radian of apparent wind off the bow. The four trim values default
    /// to the sim's (`SailTrim.standard`, #377), which reads the sail's angle for the ribbons and backwind; a Debug
    /// slider moves the drawing only.
    var trimPerApparentAngle = SailTrim.standard.perApparentAngle
    /// The least and most the sail is let out, degrees.
    var minTrimDegrees = SailTrim.standard.minTrimDegrees
    var maxTrimDegrees = SailTrim.standard.maxTrimDegrees
    /// Head to wind: this close past the class's no-go angle the sail doesn't draw; it lies this far out, degrees.
    var headToWindMarginDegrees = SailTrim.standard.headToWindMarginDegrees
    var headToWindTrimDegrees = 3.0
    /// A flapping sail's swing either side of its trim, degrees.
    var flutterDegrees = 6.0
    /// How hard the sail flutters by the lee, 0 to 1.
    var byTheLeeFlutter = 0.25
    /// Starved of pressure (#220): the share of her recent average she may lose before the sail flutters, and
    /// the share at which it flutters its hardest (`starvedFlutter`).
    var starvedDeadband = 0.05
    var starvedFullLoss = 0.35
    var starvedFlutter = 0.8

    // MARK: Roll tack (#222)

    /// A missed roll's flog: its swing either side, degrees, and how long it lasts, seconds.
    var flogDegrees = 18.0
    var flogSeconds = 1.5
    /// Your roll ring (#222): its alpha, its radius at its widest in hull lengths (where the approach starts), and how
    /// long a hit's or a miss's result shows, race seconds.
    var rollRingAlpha = 0.9
    var rollRingHulls = 1.6
    var rollRingSeconds = 1.3

    // MARK: Your boat, ghosts

    /// Your boat's soft white glow (#15): its alpha. No ring, no halo circle.
    var glowAlpha = 0.55
    /// A ghost (#30) drawn faded: the alpha she draws at, as one flat image (her hull, outline and sail don't
    /// darken where they overlap), and the alpha her wake draws at on top of its own.
    var ghostAlpha = 0.4

    // MARK: Art (#117)

    /// A ghost's limp sail: its belly, a share of a full one.
    var ghostSailBelly = 0.35
    /// The most belly a flapping sail loses, a share of a full one.
    var flapBellyLoss = 0.55
    /// How fast a fluttering sail swings and its belly pumps, radians per race second.
    var flutterSwingRate = 22.0
    var flapBellyRate = 31.0
    /// Each boat's flutter phase, radians a seat on from the last, so a flapping fleet doesn't flap in step.
    var flutterPhaseStep = 2.39
    /// Your glow's blur, points: soft, with no hard edge that would read as a ring (#15). Baked into the textures
    /// when the fleet is built, so the boats built after a change take it.
    var glowBlur = 5.0
    /// Every hull's outline width, points, drawn inside her silhouette. Baked in when the fleet is built.
    var outlineWidth = 1.0

    // MARK: Wake (#15, #220, #222, #121)

    /// At this speed through the water, m/s, and above, her wake is its longest.
    var wakeFullSpeed = 10.0
    /// Her wake's longest, in hull lengths astern of her stern: short, a wake under her stern (#220), not a beam.
    var wakeMaxHulls = 2.0
    /// The V's half-angle at full speed and even pressure, degrees; half of it at a standstill.
    var wakeSpreadDegrees = 16.0
    /// How hard pressure fans the V and the lack of it narrows and fades it (#220): its spread changes by this
    /// share of how far the pressure she feels is off her recent average.
    var wakePressureFan = 1.0
    /// The wake string's alpha at even pressure, `CuePalette.cueWhite`.
    var wakeAlpha = 0.35
    /// The wake string: how many race seconds of her track it holds, and its width, points.
    var wakeTrailSeconds = 3.4
    var wakeTrailWidth = 1.5
    /// Planing (#245, #248): her wake is this much longer, wider and brighter, at least 1 (`WakeShape` holds it
    /// there). A placeholder until #220's look.
    var wakePlaningBoost = 1.2
    /// The centre streak: its length, a share of the V's, its width, metres, and its alpha, a share of the V's.
    var wakeStreakShare = 0.6
    var wakeStreakWidth = 0.18
    var wakeStreakAlpha = 0.5
    /// How fast the wake follows her speed and pressure, per race second.
    var wakeEaseRate = 4.0
    /// A roll hit's flare (#222): how much bigger and brighter her wake starts, fading over this many seconds.
    var wakeFlareGain = 0.6
    var wakeFlareSeconds = 0.8
    /// The short wake tier's (#127) length, a share of the full one's; it has no centre streak.
    var wakeShortShare = 0.5

    // MARK: Wind shadow, backwind (#10, #298)

    /// The wind shadow's alpha at its strongest (white, to read on dark water): faint (#15) but seen. The turbulence
    /// ribbons (#377, `TurbulenceTrailLayer`) draw at it where a ribbon is at its peak, less as its strength fades; the
    /// backwind's is a share of it (`backwindShare`). Named for the cones it drew before #377.
    var coneAlpha = 0.3
    /// The backwind zone's alpha, a share of the cone's (0.5 of full alpha at 0.3): much stronger than the cone's
    /// average, as it is small and sits over the cone's own hatch. Its hatch thins towards its far edge as its loss does (#298); its outline and fill stay.
    var backwindShare = 1.68
    /// How long, seconds, her cone and backwind take to turn after her heading and apparent wind: the air she disturbed
    /// shifts after her, it isn't welded to her (drawn only). 0 draws them rigid.
    var shadowFollowSeconds = 1.2
    /// How far the backwind's edge is softened, points: its hatch and fill fade out over about this far either side of where
    /// core's zone ends, not a hard cut. Baked in when the fleet is built. 0 draws it hard edged.
    var backwindFeather = 3.0
    /// The hatch both are drawn in: its lines' spacing and width, points. Baked in when the fleet is built.
    var hatchSpacing = 5.0
    var hatchLineWidth = 1.25
    // MARK: Cues (#122)

    /// The wind vane's length, in hull lengths (#15: one).
    var vaneLengthHulls = 1.0
    /// The vane locks to the groove tick while the autohelm holds the groove and she sails within this of it,
    /// degrees (#219).
    var vaneLockDegrees = 1.5
    /// The autohelm's offset from the groove under which nothing shows (no arc, no sail cue), degrees, and the
    /// offset at which the sail cue is at its fullest.
    var grooveCueDeadbandDegrees = 1.0
    var grooveCueFullDegrees = 8.0
    /// A held angle further than this from its groove towards the beam (footing upwind, pinching downwind) is a
    /// reach, not the groove sailed off: no sail cue and no arc, degrees.
    var grooveCueReachDegrees = 15.0
    /// Pinched (#219): the sail's leading edge lifts, a small quick flutter at the luff this many degrees either
    /// side at full pinch, and the sail flattens by this share of its belly.
    var pinchLuffDegrees = 3.0
    var pinchFlatten = 0.25
    /// Footed (#219): the sail eased out this many degrees further at full foot, and fuller by this share.
    var footEaseDegrees = 6.0
    var footFullness = 0.2
    /// The laylines' and ladder lines' alpha: very faint (#15), the ladder lines fainter still.
    var laylineAlpha = 0.3
    var ladderLineAlpha = 0.12
    /// The ladder lines' spacing, metres, from the windward mark.
    var ladderSpacingMetres = 100.0
    /// The next-mark edge arrow keeps this far inside the race view's sides, scene points, and this much clear of
    /// the HUD's notice line above and the controls below (`ViewInsets.race`): a mark under them counts as off
    /// screen.
    var edgeArrowInsetSide = 28.0
    var edgeArrowClearance = 12.0

    // MARK: Rule cues (#123)

    /// A boat's right-of-way glow starts to fade in when her centre is this many hull lengths from yours: a debug
    /// slider (fun before realism), its default the core's (`RightOfWayGlyph.defaultRangeHulls`); online the server
    /// sends relations a little further out (#96).
    var glowRangeHulls = RightOfWayGlyph.defaultRangeHulls
    /// The glow is at full strength from this many hull lengths in, and its alpha there.
    var glowFullHulls = 1.5
    var glowMaxAlpha = 0.9
    /// The glow's blur, points. Baked into the textures when the fleet is built, like `glowBlur`.
    var rightOfWayGlowBlur = 9.0
    /// A rule call's dashed line shows this many seconds of race time, fading out over the last
    /// `ruleCallFadeSeconds`.
    var ruleCallLineSeconds = 8.0
    var ruleCallFadeSeconds = 1.5
    /// The penalty arc's radius, hull lengths from your boat's centre, and its width, screen points.
    var penaltyArcRadiusHulls = 0.9
    var penaltyArcWidth = 4.0

    // MARK: Render quality (#127)

    /// A boat this many hull lengths from yours is far: at the serious thermal tier her sail drops its animation detail
    /// (`SailDetail.farReduced`), near again inside `FarBoat.nearShare` of it. A debug slider; placeholder about half
    /// the portrait view at the default zoom.
    var farBoatHulls = 8.0

    /// The shipped placeholders.
    static let standard = BoatStyle()
}

/// Lenient: a field missing from a saved style takes its standard value, so an older tuning keeps the rest.
nonisolated extension BoatStyle {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var style = BoatStyle.standard
        let fields: [(CodingKeys, WritableKeyPath<BoatStyle, Double>)] = [
            (.heelOnsetKnots, \.heelOnsetKnots), (.heelFullKnots, \.heelFullKnots), (.heelScale, \.heelScale),
            (.heelNarrowing, \.heelNarrowing), (.heelShadowOffset, \.heelShadowOffset),
            (.heelShadowAlpha, \.heelShadowAlpha), (.trimPerApparentAngle, \.trimPerApparentAngle),
            (.minTrimDegrees, \.minTrimDegrees), (.maxTrimDegrees, \.maxTrimDegrees),
            (.headToWindMarginDegrees, \.headToWindMarginDegrees), (.headToWindTrimDegrees, \.headToWindTrimDegrees),
            (.flutterDegrees, \.flutterDegrees), (.byTheLeeFlutter, \.byTheLeeFlutter),
            (.starvedDeadband, \.starvedDeadband), (.starvedFullLoss, \.starvedFullLoss),
            (.starvedFlutter, \.starvedFlutter), (.flogDegrees, \.flogDegrees), (.flogSeconds, \.flogSeconds),
            (.glowAlpha, \.glowAlpha), (.ghostAlpha, \.ghostAlpha),
            (.ghostSailBelly, \.ghostSailBelly), (.flapBellyLoss, \.flapBellyLoss),
            (.flutterSwingRate, \.flutterSwingRate), (.flapBellyRate, \.flapBellyRate),
            (.flutterPhaseStep, \.flutterPhaseStep), (.glowBlur, \.glowBlur), (.outlineWidth, \.outlineWidth),
            (.wakeFullSpeed, \.wakeFullSpeed), (.wakeMaxHulls, \.wakeMaxHulls),
            (.wakeSpreadDegrees, \.wakeSpreadDegrees), (.wakePressureFan, \.wakePressureFan),
            (.wakeAlpha, \.wakeAlpha), (.wakePlaningBoost, \.wakePlaningBoost),
            (.wakeTrailSeconds, \.wakeTrailSeconds), (.wakeTrailWidth, \.wakeTrailWidth),
            (.rollRingSeconds, \.rollRingSeconds), (.rollRingAlpha, \.rollRingAlpha),
            (.rollRingHulls, \.rollRingHulls),
            (.wakeStreakShare, \.wakeStreakShare), (.wakeStreakWidth, \.wakeStreakWidth),
            (.wakeStreakAlpha, \.wakeStreakAlpha), (.wakeEaseRate, \.wakeEaseRate),
            (.wakeFlareGain, \.wakeFlareGain), (.wakeFlareSeconds, \.wakeFlareSeconds),
            (.wakeShortShare, \.wakeShortShare), (.coneAlpha, \.coneAlpha), (.backwindShare, \.backwindShare), (.shadowFollowSeconds, \.shadowFollowSeconds), (.backwindFeather, \.backwindFeather),
            (.hatchSpacing, \.hatchSpacing), (.hatchLineWidth, \.hatchLineWidth),
            (.vaneLengthHulls, \.vaneLengthHulls),
            (.vaneLockDegrees, \.vaneLockDegrees), (.grooveCueDeadbandDegrees, \.grooveCueDeadbandDegrees),
            (.grooveCueFullDegrees, \.grooveCueFullDegrees), (.grooveCueReachDegrees, \.grooveCueReachDegrees),
            (.pinchLuffDegrees, \.pinchLuffDegrees),
            (.pinchFlatten, \.pinchFlatten), (.footEaseDegrees, \.footEaseDegrees), (.footFullness, \.footFullness),
            (.laylineAlpha, \.laylineAlpha), (.ladderLineAlpha, \.ladderLineAlpha),
            (.ladderSpacingMetres, \.ladderSpacingMetres), (.edgeArrowInsetSide, \.edgeArrowInsetSide),
            (.edgeArrowClearance, \.edgeArrowClearance),
            (.glowRangeHulls, \.glowRangeHulls), (.glowFullHulls, \.glowFullHulls), (.glowMaxAlpha, \.glowMaxAlpha),
            (.rightOfWayGlowBlur, \.rightOfWayGlowBlur),
            (.ruleCallLineSeconds, \.ruleCallLineSeconds), (.ruleCallFadeSeconds, \.ruleCallFadeSeconds),
            (.penaltyArcRadiusHulls, \.penaltyArcRadiusHulls), (.penaltyArcWidth, \.penaltyArcWidth),
            (.farBoatHulls, \.farBoatHulls),
        ]
        for (key, path) in fields {
            if let value = try c.decodeIfPresent(Double.self, forKey: key) { style[keyPath: path] = value }
        }
        self = style
    }
}

/// A roll miss's flog (#222) as a boat draws it: `BoatStyle.flogSeconds` of race time from when the miss is first
/// drawn, though the race holds the miss until she is close-hauled. Presentation state, one per boat.
nonisolated struct FlogTimer: Equatable, Sendable {
    /// When the current miss's flog began, race seconds, while she has one.
    private(set) var start: Double?

    /// Whether the sail flogs at race time `time` with `roll` showing, for `seconds` from first seen. Time that
    /// runs backwards (an online re-prediction, a fixture drawn again) starts the flog over from `time`, so a
    /// start in the future never counts as flogging for ever.
    mutating func isFlogging(roll: BoatPose.RollCue?, time: Double, seconds: Double) -> Bool {
        guard roll == .flog else {
            start = nil
            return false
        }
        if let start, time >= start {
            return time - start < seconds
        }
        start = time
        return seconds > 0
    }
}

/// A roll hit's wake flare (#222) as a boat draws it: from 1 when the hit is first drawn down to 0 over
/// `BoatStyle.wakeFlareSeconds` of race time, though the race holds the hit until she is close-hauled. Time that
/// runs backwards starts it over, as `FlogTimer`. Presentation state, one per boat.
nonisolated struct FlareTimer: Equatable, Sendable {
    /// When the current hit's flare began, race seconds, while she has one.
    private(set) var start: Double?

    /// How much of the flare is left at race time `time` with `roll` showing, 0 to 1.
    mutating func flare(roll: BoatPose.RollCue?, time: Double, seconds: Double) -> Double {
        guard roll == .snap else {
            start = nil
            return 0
        }
        if let start, time >= start {
            guard seconds > 0 else { return 0 }
            return max(0, 1 - (time - start) / seconds)
        }
        start = time
        return seconds > 0 ? 1 : 0
    }
}
