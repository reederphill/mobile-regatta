import Foundation

/// A patch of stronger (gust) or weaker (lull) breeze drifting down the course.
public struct Puff: Sendable {
    public var center: Vec2
    public var radius: Double
    /// Peak change in wind speed as a fraction; negative for a lull.
    public var strength: Double
    public var age: Double
    public var lifetime: Double

    /// Current strength, fading in and out over the puff's life.
    public var intensity: Double {
        strength * sin(.pi * (age / lifetime).clamped(to: 0...1))
    }

    func influence(at p: Vec2) -> Double {
        let d2 = (p - center).lengthSquared / (radius * radius)
        guard d2 < 1 else { return 0 }
        let f = 1 - d2
        return intensity * f * f
    }
}

/// True wind over the race area: oscillating shifts, a left/right bias across the
/// course, and drifting puffs and lulls.
public struct WindField: Sendable {
    /// Compass direction the wind blows *from*, in radians.
    public let baseDirection: Double
    /// Metres per second.
    public let baseSpeed: Double
    public private(set) var puffs: [Puff] = []
    /// Ticks stepped since the field was created.
    public private(set) var tick = 0
    /// Seconds since the field was created, derived from `tick` so it never accumulates rounding.
    public var time: Double { Double(tick) / Double(Race.tickRate) }

    private let areaMin: Vec2
    private let areaMax: Vec2
    private let phases: [Double]
    private let puffCount = 14
    private var rng: SplitMix64

    public init(seed: UInt64, baseDirection: Double = 0, baseSpeed: Double = 6.5, areaMin: Vec2, areaMax: Vec2) {
        var generator = SplitMix64(seed: seed)
        phases = (0..<4).map { _ in generator.range(0, 2 * .pi) }
        rng = generator
        self.baseDirection = baseDirection
        self.baseSpeed = baseSpeed
        self.areaMin = areaMin
        self.areaMax = areaMax
        for _ in 0..<puffCount {
            var puff = makePuff()
            puff.age = rng.range(0, puff.lifetime)
            puffs.append(puff)
        }
    }

    /// Fleet-wide oscillating shift away from the base direction, in radians. Positive = veer (clockwise).
    public var globalShift: Double {
        deg2rad(7) * sin(2 * .pi * time / 90 + phases[0])
            + deg2rad(4) * sin(2 * .pi * time / 37 + phases[1])
    }

    public func direction(at p: Vec2) -> Double {
        let spatial = deg2rad(3) * sin(p.x / 220 + phases[2] + time / 70)
        return wrapAngle(baseDirection + globalShift + spatial)
    }

    public func speed(at p: Vec2) -> Double {
        var factor = 1 + 0.06 * sin(2 * .pi * time / 53 + phases[3])
        for puff in puffs { factor += puff.influence(at: p) }
        return baseSpeed * max(0.4, factor)
    }

    /// Advances one fixed tick of `Race.dt`.
    public mutating func step() {
        let dt = Race.dt
        tick += 1
        let drift = -Vec2.heading(baseDirection + globalShift) * baseSpeed * 0.35
        for i in puffs.indices {
            puffs[i].age += dt
            puffs[i].center += drift * dt
        }
        puffs.removeAll { $0.age >= $0.lifetime }
        while puffs.count < puffCount { puffs.append(makePuff()) }
    }

    private mutating func makePuff() -> Puff {
        let isLull = rng.unit() < 0.3
        return Puff(
            center: Vec2(
                rng.range(areaMin.x, areaMax.x),
                rng.range(areaMin.y, areaMax.y)
            ),
            radius: rng.range(35, 90),
            strength: isLull ? -rng.range(0.12, 0.22) : rng.range(0.15, 0.35),
            age: 0,
            lifetime: rng.range(40, 90)
        )
    }
}
