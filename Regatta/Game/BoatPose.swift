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
/// The base pose only: #122's pinch/foot sail-shape cue layers on `sailTrim`, and #120's sailors and #127's far
/// tier keep `heel` and `sailSide` apart from `flutter`.
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

    /// `boat`'s pose in `boatClass`. `ease` is her held ease; `isGhost` whether she has stopped racing, as the
    /// race shows it (`Race.isGhost(seat:)`).
    init(_ boat: Boat, ease: Bool, isGhost: Bool, boatClass: BoatClass, style: BoatStyle = .standard) {
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
        let awa = boat.apparentWind.speed > 0.01 ? abs(wrapAngle(boat.apparentWind.direction - boat.heading)) : twa
        let headToWind = twa < BoatDynamics.noGoAngle(boatClass.polar) + deg2rad(style.headToWindMarginDegrees)

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

        heel = ease || headToWind ? 0 : Self.heel(felt: Self.feltWind(boat), twa: twa, style: style)
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
    var heelNarrowing = 0.14
    /// How far her drop shadow sits to leeward at full heel, in beams.
    var heelShadowOffset = 0.22
    /// The drop shadow's alpha at full heel; less heel, fainter.
    var heelShadowAlpha = 0.35

    // MARK: Sail

    /// The sail's trim off the centreline for each radian of apparent wind off the bow.
    var trimPerApparentAngle = 0.5
    /// The least and most the sail is let out, degrees.
    var minTrimDegrees = 4.0
    var maxTrimDegrees = 85.0
    /// Head to wind: this close past the class's no-go angle the sail doesn't draw; it lies this far out, degrees.
    var headToWindMarginDegrees = 2.0
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

    // MARK: Your boat, ghosts

    /// Your boat's soft white glow (#15): its alpha. No ring, no halo circle.
    var glowAlpha = 0.55
    /// A ghost (#30) drawn faded: the alpha of everything she draws.
    var ghostAlpha = 0.4

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
