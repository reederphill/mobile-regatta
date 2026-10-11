import Foundation

// Ratings (#151, ADR 0012): Glickman's Glicko-2 as published ("Example of the Glicko-2 system", 2012 revision: the
// Illinois iteration for the volatility), with three changes: every game carries a weight, the deviation grows by the
// time since the player's last rated race instead of once per rating period, and the results are clamped. Pure:
// Foundation only, no clock, no store. `FleetRating` turns one race into the games.

/// The ratings' parameters (ADR 0012). Server config sets `weightExponent` (`RATING_WEIGHT_EXPONENT`).
public struct RatingConfig: Sendable, Equatable {
    /// A new player's rating, deviation and volatility.
    public var startRating = 1500.0
    public var startDeviation = 350.0
    public var startVolatility = 0.06
    /// Glickman's τ: how fast the volatility may move.
    public var tau = 0.5
    /// The volatility iteration stops within this, and after at most `maxIterations` steps.
    public var epsilon = 1e-6
    public var maxIterations = 200
    public var deviationRange: ClosedRange<Double> = 50...350
    public var volatilityRange: ClosedRange<Double> = 0.01...0.1
    public var ratingRange: ClosedRange<Double> = 100...4000
    /// A game of a race with m opponents weighs m^-weightExponent: 0.5 is 1/√m (a duel is 1). 0 would count the
    /// m games of one ranking as m independent games (the first race of 4 new players then moves the winner 300,
    /// not 229); 1 would make every race worth one duel.
    public var weightExponent = 0.5
    /// A player is established, for good, the first time a rated race leaves her deviation at or under this.
    public var establishedDeviation = 90.0
    /// One rating period, in seconds: the deviation grows by the volatility once per period away.
    public var period: TimeInterval = 86_400
    /// The longest time away that counts, in periods.
    public var maxPeriods = 365.0

    public init() {}
}

public enum RatingError: Error, Equatable, Sendable {
    /// A number that isn't finite came in or out (a corrupt row, a parameter that makes no sense).
    case notFinite(String)
    /// The volatility iteration didn't settle.
    case noConvergence
    /// Fewer than 2 participants, or one named twice.
    case badFleet
}

/// A player's rating on Glicko's own scale: rating, deviation (RD) and volatility.
public struct Glicko2: Sendable, Equatable {
    public var rating: Double
    public var deviation: Double
    public var volatility: Double

    public init(rating: Double, deviation: Double, volatility: Double) {
        self.rating = rating
        self.deviation = deviation
        self.volatility = volatility
    }

    public init(_ config: RatingConfig = RatingConfig()) {
        self.init(rating: config.startRating, deviation: config.startDeviation, volatility: config.startVolatility)
    }

    /// One game: the opponent as she stood before it, the score (1 win, 0.5 draw, 0 loss) and its weight.
    public struct Game: Sendable, Equatable {
        public var opponentRating: Double
        public var opponentDeviation: Double
        public var score: Double
        public var weight: Double

        public init(opponentRating: Double, opponentDeviation: Double, score: Double, weight: Double = 1) {
            self.opponentRating = opponentRating
            self.opponentDeviation = opponentDeviation
            self.score = score
            self.weight = weight
        }
    }

    /// Glickman's scale constant: 400 / ln 10.
    static let scale = 173.7178

    static func g(_ phi: Double) -> Double { 1 / (1 + 3 * phi * phi / (Double.pi * Double.pi)).squareRoot() }

    static func expected(_ mu: Double, _ muJ: Double, _ phiJ: Double) -> Double { 1 / (1 + exp(-g(phiJ) * (mu - muJ))) }

    /// The deviation after `periods` rating periods with no game: √(φ² + t·σ²), never over the range's top.
    public func deviation(after periods: Double, config: RatingConfig = RatingConfig()) -> Double {
        let phi = deviation / Self.scale
        return min(config.deviationRange.upperBound, (phi * phi + max(0, periods) * volatility * volatility).squareRoot() * Self.scale)
    }

    /// The player after `games`, all played at once, `periods` rating periods after her last update (1 is exactly
    /// Glickman's step). With weights of 1 and `periods` 1 this is the published algorithm. Each game's weight
    /// scales what it adds to the information (v⁻¹ = Σ w g² E(1−E)) and to the improvement (Δ = v Σ w g (s−E)).
    /// With no games only the deviation grows. The deviation used for the volatility step is the stored one; the
    /// pre-update deviation is φ* = √(φ² + t·σ′²), so races back to back (t ≈ 0) add no deviation.
    public func updated(_ games: [Game], periods: Double = 1, config: RatingConfig = RatingConfig()) throws(RatingError) -> Glicko2 {
        guard rating.isFinite, deviation.isFinite, volatility.isFinite, deviation > 0, volatility > 0, periods.isFinite,
              config.tau.isFinite, config.tau > 0 else { throw .notFinite("input") }
        let periods = max(0, periods)
        guard !games.isEmpty else {
            return Glicko2(rating: rating, deviation: deviation(after: periods, config: config), volatility: volatility)
        }
        let mu = (rating - 1500) / Self.scale, phi = deviation / Self.scale
        var information = 0.0, sum = 0.0
        for game in games {
            guard game.opponentRating.isFinite, game.opponentDeviation.isFinite, game.score.isFinite, game.weight.isFinite,
                  game.weight > 0 else { throw .notFinite("game") }
            let muJ = (game.opponentRating - 1500) / Self.scale, phiJ = game.opponentDeviation / Self.scale
            let e = Self.expected(mu, muJ, phiJ), gJ = Self.g(phiJ)
            information += game.weight * gJ * gJ * e * (1 - e)
            sum += game.weight * gJ * (game.score - e)
        }
        guard information.isFinite, information > 0 else { throw .notFinite("information") }
        let v = 1 / information, delta = v * sum
        let sigma = try Self.volatility(phi: phi, sigma: volatility, delta: delta, v: v, config: config)
        let phiStar = min((phi * phi + periods * sigma * sigma).squareRoot(), config.deviationRange.upperBound / Self.scale)
        let phiNew = 1 / (1 / (phiStar * phiStar) + 1 / v).squareRoot()
        let muNew = mu + phiNew * phiNew * sum
        let result = Glicko2(rating: muNew * Self.scale + 1500, deviation: phiNew * Self.scale, volatility: sigma)
        guard result.rating.isFinite, result.deviation.isFinite, result.volatility.isFinite else { throw .notFinite("result") }
        return result.clamped(config)
    }

    /// Inside the ranges the store checks.
    public func clamped(_ config: RatingConfig) -> Glicko2 {
        func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double { min(max(value, range.lowerBound), range.upperBound) }
        return Glicko2(rating: clamp(rating, config.ratingRange), deviation: clamp(deviation, config.deviationRange),
                       volatility: clamp(volatility, config.volatilityRange))
    }

    /// Step 5 of the paper: the new volatility, by the Illinois variant of regula falsi.
    static func volatility(phi: Double, sigma: Double, delta: Double, v: Double, config: RatingConfig) throws(RatingError) -> Double {
        let a = log(sigma * sigma), tau = config.tau
        func f(_ x: Double) -> Double {
            let ex = exp(x), d = phi * phi + v + ex
            return ex * (delta * delta - phi * phi - v - ex) / (2 * d * d) - (x - a) / (tau * tau)
        }
        var A = a, B: Double
        if delta * delta > phi * phi + v {
            B = log(delta * delta - phi * phi - v)
        } else {
            var k = 1.0
            while f(a - k * tau) < 0 {
                k += 1
                guard k <= Double(config.maxIterations) else { throw .noConvergence }
            }
            B = a - k * tau
        }
        var fA = f(A), fB = f(B)
        var steps = 0
        while abs(B - A) > config.epsilon {
            steps += 1
            guard steps <= config.maxIterations, fA.isFinite, fB.isFinite else { throw .noConvergence }
            let C = A + (A - B) * fA / (fB - fA), fC = f(C)
            if fC * fB <= 0 {
                A = B
                fA = fB
            } else {
                fA /= 2
            }
            B = C
            fB = fC
        }
        let result = exp(A / 2)
        guard result.isFinite, result > 0 else { throw .notFinite("volatility") }
        return result
    }
}
