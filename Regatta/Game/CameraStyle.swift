import Foundation

/// How the race camera frames the race, in one value (#113, #224): the boat-up lag, auto framing's distances,
/// times and ease, the pinch-zoom limits and hold, and the follow camera's look-ahead, rate and zoom with auto
/// framing off. The debug tuning panel (#232) puts a slider on each, and `GameScene.cameraStyle` takes a new one
/// live. App-side and never logged: nothing here reaches the simulation. Every default is a placeholder until
/// tuned there.
nonisolated struct CameraStyle: Codable, Equatable, Sendable {
    /// Seconds of your boat's velocity the follow camera (auto framing off) centres ahead of her.
    var lookAheadSeconds = 2.0
    /// How fast the camera's centre closes on its target: the share of the gap it closes in a second is
    /// 1 − e^−rate.
    var followRate = 3.0
    /// The follow camera's zoom (auto framing off) until you pinch-zoom: 1 is a point per point, larger is closer.
    var defaultZoom = 0.8
    /// The north-up course camera's view over the whole course (render fixtures), as a multiple of its extent.
    var courseMargin = 1.2

    // MARK: View heading (#13)

    /// Boat-up's lag behind your heading, seconds: the time constant τ of its ease, so a step in heading is 63 %
    /// turned after τ. A change of camera turns the same way.
    var boatUpLagSeconds = 1.0

    // MARK: Auto framing (#224)

    /// Boats within this many hull lengths of yours are framed with her. Ghosts (finished, DSQ) never are.
    var framingHullLengths = 6.0
    /// Seconds of wind upwind of your boat kept in view: that many seconds at the ground wind's speed at her
    /// (ADR 0001's 30 s, the reveal lead).
    var framingUpwindSeconds = 30.0
    /// The start line stays framed from the start sequence until this many seconds after the gun.
    var lineFramingSecondsAfterGun = 10.0
    /// The view around the framed box, as a multiple of its extent.
    var framingMargin = 1.25
    /// How fast the zoom closes on auto framing's: the share of the gap it closes in a second is 1 − e^−rate.
    var framingEaseRate = 1.0

    // MARK: Pinch-zoom

    /// The widest the camera zooms out: 1 is a point per point. Raised to the zoom that fits the whole course
    /// when that is closer, so the widest view is never wider than the course.
    var minZoom = 0.45
    /// The closest the camera zooms in.
    var maxZoom = 2.2
    /// Seconds a pinch-zoom holds after the fingers lift before easing back to auto framing.
    var pinchHoldSeconds = 5.0

    /// The shipped placeholders.
    static let standard = CameraStyle()
}

/// Lenient: a field missing from a saved style (one saved before the field existed, like auto framing's before
/// #113) takes its standard value, so an older tuning keeps the rest of its camera.
nonisolated extension CameraStyle {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let standard = CameraStyle.standard
        func value(_ key: CodingKeys, _ fallback: Double) throws -> Double {
            try c.decodeIfPresent(Double.self, forKey: key) ?? fallback
        }
        self.init(lookAheadSeconds: try value(.lookAheadSeconds, standard.lookAheadSeconds),
                  followRate: try value(.followRate, standard.followRate),
                  defaultZoom: try value(.defaultZoom, standard.defaultZoom),
                  courseMargin: try value(.courseMargin, standard.courseMargin),
                  boatUpLagSeconds: try value(.boatUpLagSeconds, standard.boatUpLagSeconds),
                  framingHullLengths: try value(.framingHullLengths, standard.framingHullLengths),
                  framingUpwindSeconds: try value(.framingUpwindSeconds, standard.framingUpwindSeconds),
                  lineFramingSecondsAfterGun: try value(.lineFramingSecondsAfterGun, standard.lineFramingSecondsAfterGun),
                  framingMargin: try value(.framingMargin, standard.framingMargin),
                  framingEaseRate: try value(.framingEaseRate, standard.framingEaseRate),
                  minZoom: try value(.minZoom, standard.minZoom),
                  maxZoom: try value(.maxZoom, standard.maxZoom),
                  pinchHoldSeconds: try value(.pinchHoldSeconds, standard.pinchHoldSeconds))
    }
}
