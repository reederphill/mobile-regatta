import CoreGraphics
import RegattaCore

/// Turns touches on the water into a rudder value, −1 (full port) to 1 (full starboard), in the device's steering
/// scheme (#13, #112). Both schemes give the same value, so the scheme is a client setting the server never sees.
/// Letting go centres the rudder at once in both, and a centred rudder is what engages the autohelm (#230, ADR 0007).
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

    /// Where the tiller's track and knob draw: the track under `origin`, the knob at `knob` (#112).
    struct TillerKnob: Equatable {
        let origin: CGPoint
        let knob: CGPoint
    }

    /// Changing it lets go of every touch, so a switch mid-race (#131) never carries a held side across.
    var scheme: Scheme {
        didSet { if scheme != oldValue { reset() } }
    }

    private(set) var rudder = 0.0
    private var portTouches = Set<AnyHashable>()
    private var starboardTouches = Set<AnyHashable>()
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
        case .tiller:
            // The first finger down steers; any other is ignored.
            guard tiller == nil else { return }
            tiller = (id, point, point)
            rudder = tillerRudder
        }
    }

    /// A finger moves. Halves keep the side a finger landed on; the tiller follows its sideways slide.
    mutating func touchMoved(_ id: AnyHashable, to point: CGPoint) {
        guard let held = tiller, held.id == id else { return }
        tiller = (held.id, held.origin, point)
        rudder = tillerRudder
    }

    /// A finger lifts (or the system cancels it).
    mutating func touchEnded(_ id: AnyHashable) {
        portTouches.remove(id)
        starboardTouches.remove(id)
        ignored.remove(id)
        if tiller?.id == id { tiller = nil }
        switch scheme {
        case .halves: if portTouches.isEmpty && starboardTouches.isEmpty { rudder = 0 }
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
    }

    /// Moves the rudder on by `dt` seconds and returns it.
    mutating func advance(by dt: Double) -> Double {
        switch scheme {
        case .halves:
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

    /// The tiller's track and knob while a tiller drag is held; nil otherwise, and always in halves.
    var tillerKnob: TillerKnob? {
        guard scheme == .tiller, let tiller else { return nil }
        let dx = (tiller.point.x - tiller.origin.x).clamped(to: -Self.tillerFullOffset...Self.tillerFullOffset)
        return TillerKnob(origin: tiller.origin, knob: CGPoint(x: tiller.origin.x + dx, y: tiller.origin.y))
    }

    /// The tiller follows the finger at once: sideways offset over the full throw, vertical ignored.
    private var tillerRudder: Double {
        guard let tiller else { return 0 }
        return Double((tiller.point.x - tiller.origin.x) / Self.tillerFullOffset).clamped(to: -1...1)
    }
}
