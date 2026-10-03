import Foundation
import RegattaCore

// #376: the ribbon model of the wind shadow lives in RegattaCore (`TurbulenceRibbons`, WakeRibbons.swift), since
// follow-on B lets the sim read it behind a Debug setting (`ShadowSettings`). The scene steps its own instance from the
// `TickFrame`s it draws (`GameScene.stepTrails`, every build: it holds no `Race`, and online its frames come from the
// server), so there is one copy of the model and two instances of its state. Here: the Debug sliders that build its
// parameters.

extension BoatStyle {
    /// The sliders `TurbulenceRibbons.Parameters(style:shadow:)` reads: a change rebuilds the parameters.
    var trailTuning: [Double] {
        [trailFullAngleDegrees, trimPerApparentAngle, minTrimDegrees, maxTrimDegrees, headToWindMarginDegrees,
         trailEmitSeconds, trailLifeScale, trailStartWidth, trailEndWidth, trailPeak, trailLengthCap, trailStoppedSpeed,
         trailExtraTurnDegrees, trailBuildSeconds]
    }
}

extension TurbulenceRibbons.Parameters {
    /// The Debug sliders' (`BoatStyle.trail…`, all tuning, not measured) for `shadow`'s class, and the sail's trim the
    /// boats are drawn with (the emission multiplier's target reads the sail as drawn, `BoatPose.angleOfAttack`).
    /// `BoatStyle.standard`'s are the prototype's defaults with its 2 s build-up (`TurbulenceRibbons.Parameters.game`):
    /// each width, the peak and the life a multiple of 1 of the class's.
    init(style: BoatStyle, shadow: BoatClass.WindShadow) {
        self.init()
        emitSeconds = max(style.trailEmitSeconds, Race.dt)
        lifeScale = max(style.trailLifeScale, 0.01)
        startScale = style.trailStartWidth * shadow.coneWidthAtBoat / 2
        endScale = style.trailEndWidth * shadow.coneWidthAtEnd / 2
        peak = style.trailPeak * shadow.lossCloseIn
        lengthCap = style.trailLengthCap
        stoppedSpeed = style.trailStoppedSpeed
        extraTurnDegrees = style.trailExtraTurnDegrees
        buildSeconds = style.trailBuildSeconds
        fullAngleDegrees = style.trailFullAngleDegrees
        trimPerApparentAngle = style.trimPerApparentAngle
        minTrimDegrees = style.minTrimDegrees
        maxTrimDegrees = style.maxTrimDegrees
        headToWindMarginDegrees = style.headToWindMarginDegrees
    }
}
