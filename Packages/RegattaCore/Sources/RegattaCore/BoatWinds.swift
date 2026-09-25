/// A wind as a boat meets it: where it blows from and how hard.
public struct Wind: Hashable, Sendable {
    /// Compass direction the wind blows from, radians in [−π, π).
    public var direction: Double
    /// Metres per second.
    public var speed: Double

    public static let calm = Wind(direction: 0, speed: 0)

    public init(direction: Double, speed: Double) {
        self.direction = direction
        self.speed = speed
    }

    public init(_ ground: GroundWind) {
        self.init(direction: ground.direction, speed: ground.speed)
    }

    /// The air's velocity, m/s: the way it moves, towards where the wind blows to.
    public var velocity: Vec2 { -Vec2.heading(direction) * speed }

    /// The wind of air moving at `velocity`. A still air keeps `calmDirection`: it has no direction of its own.
    init(velocity: Vec2, calmDirection: Double) {
        let speed = velocity.length
        self.init(direction: speed > 0 ? wrapAngle((-velocity).bearing) : calmDirection, speed: speed)
    }
}

/// The three winds at a boat (#11, #14, #15), from the wind over the ground, the current and her
/// velocity through the water:
///
/// - `overGround`: the wind a flag on a buoy shows. What readouts show (#15).
/// - `sailing`: the wind over the water, ground less current. What the polar, her wind angle and her
///   tack read (#14): a boat sails in the water, and the water moves.
/// - `apparent`: the sailing wind less her velocity through the water, the wind her sails feel. Only
///   her wind shadow and the sail drawing use it (#10, #14).
///
/// Pure: the vector sums on the air's and water's velocities, converted back to direction and speed.
public struct BoatWinds: Hashable, Sendable {
    public var overGround: Wind
    public var sailing: Wind
    public var apparent: Wind

    public init(overGround: Wind, sailing: Wind, apparent: Wind) {
        self.overGround = overGround
        self.sailing = sailing
        self.apparent = apparent
    }

    /// The winds of a boat moving through the water at `velocityThroughWater` (m/s) in `current` (m/s,
    /// the way the water moves) under `ground`. Without current the sailing wind is the ground wind
    /// exactly. A wind that comes out still keeps the direction of the one it was made from.
    public static func resolve(ground: Wind, current: Vec2, velocityThroughWater: Vec2) -> BoatWinds {
        let sailing = current == .zero
            ? ground
            : Wind(velocity: ground.velocity - current, calmDirection: ground.direction)
        let apparent = velocityThroughWater == .zero
            ? sailing
            : Wind(velocity: sailing.velocity - velocityThroughWater, calmDirection: sailing.direction)
        return BoatWinds(overGround: ground, sailing: sailing, apparent: apparent)
    }
}
