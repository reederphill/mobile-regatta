import CoreGraphics
import RegattaCore

/// Turns touches on the water into a rudder value, −1 (full port) to 1 (full starboard), in the device's steering
/// scheme (#13, #112). Both schemes give the same value, so the scheme is a client setting the server never sees.
/// Letting go centres the rudder at once in both, and a centred rudder is what engages the autohelm (#230, ADR 0007).
///
/// Ease is a gesture too (#453): a finger on each half held still, or the tiller pulled down (`isEasing`).
///
/// Pure: no UIKit. Touches are any hashable id (the scene passes `ObjectIdentifier(touch)`), points are view points
/// (the 80 pt tiller throw is device points, G5).
nonisolated struct SteeringInterpreter {
    typealias Scheme = DeviceSettings.Steering

    /// Halves: the rudder moves this much a second towards full, so it reaches full in about 0.29 s and short
    /// taps make small corrections.
    static let halvesRampPerSecond = 3.5
    /// Tiller: the sideways slide from touch-down that gives full rudder.
    static let tillerFullOffset: CGFloat = 80

    /// Where the tiller's track and knob draw: the track under `origin`, the knob at `knob` (#112), and the ease
    /// notch `easeLine` points below the origin, where a pull down eases (#453).
    struct TillerKnob: Equatable {
        let origin: CGPoint
        let knob: CGPoint
        var easeLine = CGFloat(EaseGestureTuning.standard.tillerEngagePoints)
        var isEasing = false
    }

    /// Changing it lets go of every touch, so a switch mid-race (#131) never carries a held side across.
    var scheme: Scheme {
        didSet { if scheme != oldValue { reset() } }
    }

    private(set) var rudder = 0.0
    /// The gesture ease (#453): both halves held still past the hold delay, or the tiller pulled down.
    private(set) var isEasing = false
    /// The gesture's thresholds: the debug tuning panel's, live (fun before realism).
    var easeTuning = EaseGestureTuning.standard
    private var portTouches = Set<AnyHashable>()
    private var starboardTouches = Set<AnyHashable>()
    /// Where each halves finger landed, and the ones that have since moved past the slop: those make a pinch-zoom,
    /// not an ease, until they lift.
    private var landings: [AnyHashable: CGPoint] = [:]
    private var movedTouches = Set<AnyHashable>()
    /// Seconds both halves have been held still: an ease once it reaches the hold delay; nil while not.
    private var easeHeld: Double?
    private var tiller: (id: AnyHashable, origin: CGPoint, point: CGPoint)?
    /// Touches held when a pinch-zoom began, or begun during one: never steering, until they lift.
    private var ignored = Set<AnyHashable>()
    private var isPinching = false

    init(scheme: Scheme = .halves) {
        self.scheme = scheme
    }

    /// A finger lands at `point`. `midX` splits the halves: left of it is port.
    mutating func touchBegan(_ id: AnyHashable, at point: CGPoint, midX: CGFloat) {
        if isPinching {
            ignored.insert(id)
            return
        }
        switch scheme {
        case .halves:
            if point.x < midX { portTouches.insert(id) } else { starboardTouches.insert(id) }
            landings[id] = point
        case .tiller:
            // The first finger down steers; any other is ignored.
            guard tiller == nil else { return }
            tiller = (id, point, point)
            rudder = tillerRudder
        }
    }

    /// A finger moves. Halves keep the side a finger landed on, but one moved past the slop holds no ease (a
    /// pinch-zoom moves its fingers, an ease holds them). The tiller follows its sideways slide and eases on a pull
    /// down.
    mutating func touchMoved(_ id: AnyHashable, to point: CGPoint) {
        if let landing = landings[id], !movedTouches.contains(id),
           Double(hypot(point.x - landing.x, point.y - landing.y)) > easeTuning.slopPoints {
            movedTouches.insert(id)
            if !isEasing { easeHeld = nil }
        }
        guard let held = tiller, held.id == id else { return }
        tiller = (held.id, held.origin, point)
        rudder = tillerRudder
        isEasing = tillerEases(dx: point.x - held.origin.x, dy: point.y - held.origin.y)
    }

    /// A finger lifts (or the system cancels it).
    mutating func touchEnded(_ id: AnyHashable) {
        let wasHeld = portTouches.contains(id) || starboardTouches.contains(id)
        portTouches.remove(id)
        starboardTouches.remove(id)
        landings[id] = nil
        movedTouches.remove(id)
        ignored.remove(id)
        if tiller?.id == id {
            tiller = nil
            isEasing = false
        }
        switch scheme {
        case .halves:
            if portTouches.isEmpty && starboardTouches.isEmpty { rudder = 0 }
            // Lifting a finger ends the ease once a side is empty, and starts any waiting one's hold over.
            if portTouches.isEmpty || starboardTouches.isEmpty { isEasing = false }
            if wasHeld && !isEasing { easeHeld = nil }
        case .tiller: rudder = tillerRudder
        }
    }

    /// A pinch-zoom began: nothing held steers any more, nor does anything that lands before it ends (#13: a
    /// pinch-zoom must not count as steering).
    mutating func pinchBegan() {
        isPinching = true
        ignored.formUnion(portTouches)
        ignored.formUnion(starboardTouches)
        if let tiller { ignored.insert(tiller.id) }
        portTouches.removeAll()
        starboardTouches.removeAll()
        tiller = nil
        rudder = 0
        clearEase()
    }

    /// The pinch-zoom ended. Its fingers stay ignored until they lift.
    mutating func pinchEnded() {
        isPinching = false
    }

    /// Lets go of everything: an overlay took the touches, or the scheme changed.
    mutating func reset() {
        portTouches.removeAll()
        starboardTouches.removeAll()
        tiller = nil
        ignored.removeAll()
        isPinching = false
        rudder = 0
        clearEase()
    }

    private mutating func clearEase() {
        landings.removeAll()
        movedTouches.removeAll()
        easeHeld = nil
        isEasing = false
    }

    /// Moves the rudder, and a halves ease's hold, on by `dt` seconds and returns the rudder.
    mutating func advance(by dt: Double) -> Double {
        switch scheme {
        case .halves:
            advanceHalvesEase(by: dt)
            let target = (starboardTouches.isEmpty ? 0.0 : 1.0) - (portTouches.isEmpty ? 0.0 : 1.0)
            if target == 0 {
                rudder = 0
            } else {
                let maxChange = Self.halvesRampPerSecond * dt
                rudder += (target - rudder).clamped(to: -maxChange...maxChange)
            }
        case .tiller:
            rudder = tillerRudder
        }
        return rudder
    }

    /// Halves: both sides held, every held finger still, for the hold delay is an ease. Once eased, only a lift (or
    /// a pinch-zoom) ends it: a held thumb's wobble doesn't.
    private mutating func advanceHalvesEase(by dt: Double) {
        let bothHeld = !portTouches.isEmpty && !starboardTouches.isEmpty
        guard bothHeld else {
            easeHeld = nil
            isEasing = false
            return
        }
        guard !isEasing else { return }
        guard movedTouches.isDisjoint(with: portTouches), movedTouches.isDisjoint(with: starboardTouches) else {
            easeHeld = nil
            return
        }
        let held = (easeHeld ?? 0) + dt
        easeHeld = held
        // A hair under, so frames that sum to the delay in floating point still reach it.
        if held >= easeTuning.holdDelaySeconds - 1e-9 { isEasing = true }
    }

    /// The tiller eases pulled down past the engage line, more down than sideways, and lets go back above the release
    /// line (hysteresis, so a wobble at the edge doesn't flicker). Up is ignored.
    private func tillerEases(dx: CGFloat, dy: CGFloat) -> Bool {
        if isEasing { return dy >= CGFloat(easeTuning.tillerReleasePoints) }
        return dy >= CGFloat(easeTuning.tillerEngagePoints) && dy > abs(dx) * 0.5
    }

    /// The tiller's track and knob while a tiller drag is held; nil otherwise, and always in halves. The knob follows
    /// a pull down as far as the ease line.
    var tillerKnob: TillerKnob? {
        guard scheme == .tiller, let tiller else { return nil }
        let dx = (tiller.point.x - tiller.origin.x).clamped(to: -Self.tillerFullOffset...Self.tillerFullOffset)
        let line = CGFloat(easeTuning.tillerEngagePoints)
        let dy = (tiller.point.y - tiller.origin.y).clamped(to: 0...line)
        return TillerKnob(origin: tiller.origin, knob: CGPoint(x: tiller.origin.x + dx, y: tiller.origin.y + dy),
                          easeLine: line, isEasing: isEasing)
    }

    /// The tiller follows the finger at once: sideways offset over the full throw, vertical ignored.
    private var tillerRudder: Double {
        guard let tiller else { return 0 }
        return Double((tiller.point.x - tiller.origin.x) / Self.tillerFullOffset).clamped(to: -1...1)
    }
}

/// The ease gesture's thresholds (#453): debug tuning sliders (fun before realism), app-side, never logged.
nonisolated struct EaseGestureTuning: Codable, Equatable, Sendable {
    /// Halves: both sides held this long, still, before it eases. A pinch-zoom moves its fingers sooner.
    var holdDelaySeconds = 0.2
    /// Halves: a finger moved further than this from where it landed is a pinch-zoom's, not an ease's.
    var slopPoints = 10.0
    /// Tiller: a pull down this far from touch-down eases...
    var tillerEngagePoints = 44.0
    /// ...and back above this lets go. A steering drag's vertical wander stays under it.
    var tillerReleasePoints = 32.0

    static let standard = EaseGestureTuning()
}
