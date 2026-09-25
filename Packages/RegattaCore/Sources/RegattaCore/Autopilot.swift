/// The tack/gybe tap's brief autopilot (#13), the only automated steering in the game: it sails the
/// boat to the same true wind angle with the boom on the other side, then lets go. Any rudder input
/// cancels it (`Race`).
public struct Autopilot: Sendable, Equatable {
    /// Heading to settle on, radians.
    public var heading: Double
    /// The side the boom sails `heading` on. Until the boom has crossed to it, she steers to cross it.
    public var boomSide: BoomSide

    public init(heading: Double, boomSide: BoomSide) {
        self.heading = heading
        self.boomSide = boomSide
    }

    /// The tap: the same true wind angle with the boom on the other side, sailing with the boom to
    /// leeward. Upwind or on a reach that mirrors the heading across the wind. By the lee the wind is
    /// already on that side, so the target is her own heading: she bears away until she gybes, then
    /// comes back to it.
    public static func tackOrGybe(heading: Double, boomSide: BoomSide, windDirection: Double) -> Autopilot {
        let twa = abs(wrapAngle(windDirection - heading))
        let side = boomSide.opposite
        return Autopilot(heading: wrapAngle(windDirection - side.windSign * twa), boomSide: side)
    }

    /// The rudder the autopilot asks for, or nil once she has arrived and it lets go.
    ///
    /// Until the boom crosses to `boomSide` it holds full rudder the way that crosses it: towards the
    /// wind with the wind forward of the beam (a tack), away from it aft of the beam (a gybe). Then it
    /// steers to `heading`, rudder in proportion to the error up to full at 20°, and lets go within 3°.
    public func rudder(heading current: Double, boomSide currentSide: BoomSide, windDirection: Double) -> Double? {
        if currentSide != boomSide {
            let angle = currentSide.sailingAngle(relativeWind: wrapAngle(windDirection - current))
            // Turning to starboard (+) moves the sailing angle by −windSign: towards the wind on
            // starboard tack. A tack closes the angle through 0, a gybe opens it through 180°.
            return abs(angle) < .pi / 2 ? currentSide.windSign : -currentSide.windSign
        }
        let error = wrapAngle(heading - current)
        if abs(error) < deg2rad(3) { return nil }
        return (error / deg2rad(20)).clamped(to: -1...1)
    }
}
