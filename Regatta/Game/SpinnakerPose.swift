import Foundation
import RegattaCore

/// How a boat's spinnaker is drawn this frame (#311): a pure read of her public state, part of `BoatPose`, so a
/// boat's look is still derived in one place (#117). Every state is the sim's own (`Boat.spinnaker`,
/// `Boat.isSpinnakerCollapsed(in:)`, #248): the drawing keeps no timing and no threshold of its own.
///
/// No id, colour or livery input: two boats in the same state take the same kite. Presentation only (ADR 0002).
nonisolated struct SpinnakerPose: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        /// Down, on a ghost, or on a class without a spinnaker: nothing drawn.
        case hidden
        case hoisting, up, dropping
        /// Up but collapsed by the lee (`Boat.isSpinnakerCollapsed(in:)`): it draws nothing and she sails at
        /// two-sail speed.
        case collapsed
    }

    var phase: Phase
    /// How far up, 0...1: 1 up or collapsed; `1 − remaining/T` hoisting; `remaining/T` dropping; 0 hidden. A turn back
    /// mid-way keeps it (`Spinnaker.next` reverses with the time run).
    var hoisted: Double
    /// The side it flies on: the boom's (`Boat.boomSide`), so by the lee it is to windward.
    var side: BoomSide
    /// Its angle, radians, from her centreline aft out to `side` (its luff runs aft from the pole's tip): from the
    /// apparent wind, and swung forward of that collapsed.
    var trim: Double
    /// Its depth (the belly), 0...1 of the deepest the art is drawn, the target the drawing eases to. Full depth
    /// grows with her true wind angle (`BoatStyle.kiteReachDepth` on the tightest reach the class flies it, its
    /// `dropBelowTWA`, to `kiteRunDepth` on a dead run); the soft kite (`kiteSoftFill`) and a collapse
    /// (`kiteCollapsedFill`) take a share of it, a hoist or drop its progress. Never below `kiteDepthFloor` (#311 gate round 4: never a sliver).
    var fill: Double
    /// How hard it flogs, 0...1: collapsed, hoisting or dropping, or starved of pressure (the shadowed felt wind).
    var flutter: Double

    static let hidden = SpinnakerPose(phase: .hidden, hoisted: 0, side: .port, trim: 0, fill: 0, flutter: 0)

    init(phase: Phase, hoisted: Double, side: BoomSide, trim: Double, fill: Double, flutter: Double) {
        self.phase = phase
        self.hoisted = hoisted
        self.side = side
        self.trim = trim
        self.fill = fill
        self.flutter = flutter
    }

    /// `boat`'s kite in `boatClass`. A ghost, and a class without a spinnaker, show none.
    init(_ boat: Boat, isGhost: Bool, boatClass: BoatClass, style: BoatStyle = .standard) {
        guard !isGhost, let tuning = boatClass.spinnaker else {
            self = .hidden
            return
        }
        let duration = tuning.transitionTime
        func progress(_ seconds: Double) -> Double { duration > 0 ? (seconds / duration).clamped(to: 0...1) : 1 }
        switch boat.spinnaker {
        case .down:
            self = .hidden
            return
        case .hoisting(let remaining):
            phase = .hoisting
            hoisted = 1 - progress(remaining)
        case .dropping(let remaining):
            phase = .dropping
            hoisted = duration > 0 ? progress(remaining) : 1
        case .up:
            phase = boat.isSpinnakerCollapsed(in: boatClass) ? .collapsed : .up
            hoisted = 1
        }
        side = boat.boomSide

        let maxTrim = deg2rad(style.kiteMaxTrimDegrees)
        let minTrim = min(deg2rad(style.kiteMinTrimDegrees), maxTrim)
        trim = (BoatPose.apparentAngle(boat) * style.kiteTrimPerApparentAngle).clamped(to: minTrim...maxTrim)
        // The soft kite: full at a comfortable plane margin, at its softest on the edge of the plane and off it.
        let margin = PlaneMargin.of(boat, boatClass: boatClass, style: style).clamped(to: 0...1)
        let soft = style.kiteSoftFill.clamped(to: 0...1)
        // Full depth by her true wind angle, the sim's: shallow but full on the tightest reach the class flies it
        // (`dropBelowTWA`), deepest on a dead run.
        let reachTWA = min(tuning.dropBelowTWA, .pi * 0.99)
        let downwind = ((boat.twa - reachTWA) / (.pi - reachTWA)).clamped(to: 0...1)
        let depth = style.kiteReachDepth + (style.kiteRunDepth - style.kiteReachDepth) * downwind
        let drawing = depth * (soft + (1 - soft) * margin)

        var flutter = 0.0
        var fill: Double
        switch phase {
        case .up:
            fill = drawing
        case .collapsed:
            fill = depth * style.kiteCollapsedFill.clamped(to: 0...1)
            // Flat and swung forward on its own side (#311 gate rounds 2 and 4): it flags out ahead of abeam off the
            // pole's tip, never back towards the centreline where it would lie across the main.
            trim = min(trim + deg2rad(max(style.kiteCollapseSwingDegrees, 0)), .pi * 0.9)
            flutter = 1
        case .hoisting, .dropping:
            fill = drawing * hoisted
            flutter = style.kiteHoistFlog * (1 - hoisted)
            // Going up or coming down past the sim's collapse angle by the lee: it can't fill (T6).
            if let angle = boat.byTheLeeAngle, let collapse = boatClass.byTheLee?.spinnakerCollapse, angle > collapse {
                flutter = max(flutter, style.kiteHoistFlog)
            }
        case .hidden:
            fill = 0
        }
        self.fill = max(fill, style.kiteDepthFloor).clamped(to: 0...1)
        flutter = max(flutter, BoatPose.starved(boat, style: style) * style.starvedFlutter)
        self.flutter = flutter.clamped(to: 0...1)
    }
}
