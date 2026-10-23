import RegattaCore

/// The speeds a boat of the class can hold in one true wind speed (#583), by true wind angle: the polar's (on-plane,
/// spinnaker up where it goes up) where she stays on the plane at that speed, else her off-plane speed. On skiff@9 she
/// can't hold the plane sailed deep (the apparent wind falls away), so the polar's own best downwind angle is one she
/// can't sail at its speed. The oracle's grooves and estimate, the ledger's ideal (`BotSuite`) and the planner's estimate
/// (`BotPlanner`) read this.
public struct SteadyPolar: Sendable {
    /// Metres a second by whole degree of true wind angle, 0…180.
    public let speeds: [Double]
    /// The best VMG upwind and downwind: the angle and the speed there.
    public let up: (twa: Double, speed: Double)
    public let down: (twa: Double, speed: Double)

    public init(boatClass: BoatClass, tws: Double) {
        let polar = boatClass.polar
        speeds = (0...180).map { degree in
            let twa = deg2rad(Double(degree))
            guard twa >= BoatDynamics.noGoAngle(polar) else { return 0 }
            let kite: Spinnaker = boatClass.spinnaker.map { twa >= $0.hoistAboveTWA ? .up : .down } ?? .down
            let on = BoatDynamics.polarTarget(relativeWind: twa, boomSide: .port, tws: tws, isPlaning: true, spinnaker: kite,
                                              boatClass: boatClass)
            if let planing = boatClass.planing,
               !planing.isPlaning(was: true, twa: twa, speed: on, tws: tws, rudder: 0, polar: polar) {
                return BoatDynamics.polarTarget(relativeWind: twa, boomSide: .port, tws: tws, isPlaning: false, spinnaker: kite,
                                                boatClass: boatClass)
            }
            return on
        }
        var up = (twa: Double.pi / 4, speed: 0.0, vmg: 0.0)
        var down = (twa: Double.pi * 3 / 4, speed: 0.0, vmg: 0.0)
        for (degree, speed) in speeds.enumerated() {
            let twa = deg2rad(Double(degree))
            let vmg = speed * Vec2.heading(twa).y
            if vmg > up.vmg { up = (twa, speed, vmg) }
            if -vmg > down.vmg { down = (twa, speed, -vmg) }
        }
        self.up = (up.twa, up.speed)
        self.down = (down.twa, down.speed)
    }

    /// The speed at `twa`, radians, between whole degrees.
    public func speed(twa: Double) -> Double {
        let degrees = min(max(rad2deg(abs(twa)), 0), 180)
        let low = Int(degrees.rounded(.down))
        guard low < 180 else { return speeds[180] }
        let share = degrees - Double(low)
        return speeds[low] * (1 - share) + speeds[low + 1] * share
    }
}

/// Steady polars by wind speed (#583 stage 3): each worked out once a tenth of a metre a second of wind and kept, for a
/// bot's planner, whose every plan would otherwise work out two. Read by key only, never iterated.
public struct SteadyPolars: Sendable {
    private var byTenth: [Int: SteadyPolar] = [:]

    public init() {}

    /// The polar at `tws`, to the nearest tenth of a metre a second.
    public mutating func polar(tws: Double, boatClass: BoatClass) -> SteadyPolar {
        let key = Int((tws * 10).rounded())
        if let known = byTenth[key] { return known }
        let polar = SteadyPolar(boatClass: boatClass, tws: Double(key) / 10)
        byTenth[key] = polar
        return polar
    }
}
