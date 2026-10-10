import Foundation

/// A boat class: a boat design's hull, polar and handling, loaded from its immutable, versioned
/// data file (ADR 0004). Load one with `DataFile<BoatClass>(data:)` or `BoatClassFile.bundled(id:version:)`.
///
/// Files use knots, degrees, seconds and hull lengths; everything here is converted once at load
/// to m/s, radians, seconds and metres.
///
/// Values are checked once, at load. The scalars are `var` so a test or a tuning tool can edit a copy;
/// a race sails the file as loaded.
public struct BoatClass: DataFileContent, Equatable {
    public static let kind = "boat class"
    public static let bundleDirectory = "boat-classes"
    /// Schema 2 added the autohelm's steering values (#230). Schema 3 (#248, the skiff) adds planing, the
    /// automatic spinnaker, a graded by-the-lee penalty and the autohelm's averaged groove wind; a schema-2
    /// class has none of them (`planing`, `spinnaker` and `byTheLee` are nil, and its grooves read the wind
    /// at the boat right now), so it sails exactly as #230 sailed it. This build sails no schema-1 class:
    /// RegattaCore holds no boat constants (ADR 0004), so it has nothing to fill the autohelm's values with.
    /// Logs sailed on one replay on the simulation version that sailed them (ADR 0002).
    /// Schema 4 (#434, ADR 0011) is schema 3 with two optional autohelm values: whether a centred rudder hands her to
    /// the autohelm (`AutohelmTuning.holdsWhenCentred`, absent true) and how close to the new groove a tap lets go
    /// (`AutohelmTuning.handBack`). #458 adds three more optional values to schema 4: the rudder drag's exponent
    /// (`Steering.rudderDragExponent`), irons recovery (`Steering.headToWindFallOffCentredRate`) and whether the tap
    /// sails the turn (`AutohelmTuning.sailsTap`). A schema-2 or -3 class, or a schema-4 one without them, sails exactly as before.
    public static let supportedSchemaVersions = [2, 3, 4]

    /// Name shown to players.
    public var name: String
    public var hull: Hull
    public var polar: PolarTable
    public var momentum: Momentum
    public var steering: Steering
    public var windShadow: WindShadow
    public var contact: Contact
    public var ease: Ease
    /// How she gets on and off the plane (schema 3), or nil for a class that never planes: she sails the
    /// polar as is.
    public var planing: PlaningTuning?
    /// Her automatic spinnaker (schema 3), or nil for a class without one: the polar is all she sails.
    public var spinnaker: SpinnakerTuning?
    /// The graded by-the-lee penalty and where the spinnaker collapses (schema 3), or nil: only the
    /// polar's flat `byTheLeePenalty`.
    public var byTheLee: ByTheLeeTuning?
    /// The roll tack (#222, #263; schema 3, optional), or nil for a class without one: a second tack/gybe tap
    /// during a tack is an ordinary tap, as before.
    public var rollTack: RollTackTuning?

    public struct Hull: Sendable, Equatable {
        /// Metres.
        public var length: Double
        public var beam: Double
        /// Convex collision outline in metres, in the boat's frame: x to starboard, y towards the bow.
        public var outline: [Vec2]
    }

    /// Time constants of the approach to polar speed.
    public struct Momentum: Sendable, Equatable {
        /// Seconds, when the polar target is above the boat's speed.
        public var speedingUp: Double
        /// Seconds, when the target is below it with the sail drawing (lulls, shadow).
        public var slowingDown: Double
        /// Seconds, inside the no-go zone.
        public var noGo: Double
    }

    public struct Steering: Sendable, Equatable {
        /// Full-rudder turn rate at full speed, radians per second.
        public var topTurnRate: Double
        /// Full-rudder turn rate however slow the boat is, radians per second.
        public var minTurnRate: Double
        /// Fraction of `topTurnRate` by speed through the water: speeds in m/s, ascending, and the
        /// fraction at each. Linear between points, flat beyond them.
        public let turnRateCurveSpeeds: [Double]
        public let turnRateCurveFractions: [Double]
        /// How fast a boat head to wind falls off towards close-hauled on her own, radians per second.
        public var headToWindFallOffRate: Double
        /// Fraction of speed lost per second at full rudder.
        public var rudderDrag: Double
        /// How fast the rudder moves, in full rudder (1.0) per second.
        public var rudderSlew: Double
        /// How the autohelm steers (ADR 0007).
        public var autohelm: AutohelmTuning
        /// The power of the rudder in the rudder drag (schema 4's `rudderDragExponent`, #458; 1, linear, when the file
        /// leaves it out): she loses `rudderDrag × |rudder|^rudderDragExponent` of her speed per second. At 2 half rudder
        /// costs a quarter of full rudder's drag, so a smooth turn pays less than a slam. At least 1.
        public var rudderDragExponent = 1.0
        /// Irons recovery (schema 4's `headToWindFallOffCentredDegreesPerSecond`, #458), radians per second, or nil when
        /// the file leaves it out: with the rudder centred inside the no-go she falls off at the greater of this and
        /// `headToWindFallOffRate`, scaled by how little steerage she has, so a boat let go in irons gets away. A held
        /// rudder never triggers it. Nil sails `headToWindFallOffRate` alone, as every class before skiff@8.
        public var headToWindFallOffCentredRate: Double?

        /// The fall-off rate with the rudder centred inside the no-go: `headToWindFallOffCentredRate`, or
        /// `headToWindFallOffRate` for a class without it.
        public var ironsFallOffRate: Double { headToWindFallOffCentredRate ?? headToWindFallOffRate }

        /// Full-rudder turn rate at speed through the water `speed` (m/s), radians per second.
        public func turnRate(speed: Double) -> Double {
            let fraction: Double
            if turnRateCurveSpeeds.count == 1 {
                fraction = turnRateCurveFractions[0]
            } else {
                let (i, t) = axisSegment(turnRateCurveSpeeds, speed)
                fraction = PolarTable.lerp(turnRateCurveFractions[i - 1], turnRateCurveFractions[i], t)
            }
            return max(minTurnRate, topTurnRate * fraction)
        }
    }

    /// The autohelm's steering values (`Autohelm`, ADR 0007): tuning values, live-tunable as debug sliders
    /// before they're written into a class file.
    public struct AutohelmTuning: Sendable, Equatable {
        /// Let go within this of the upwind groove, the autohelm takes the groove. Radians.
        public var upwindSnap: Double
        /// The same for the downwind groove. Radians.
        public var downwindSnap: Double
        /// Rudder (−1 … 1) it asks for per radian between the angle she sails and the one it holds.
        public var gain: Double
        /// How far short of dead downwind it sails a groove at 180° (the dead-run rule). Radians.
        public var deadRunMargin: Double
        /// How far short of the by-the-lee limit it holds an angle by the lee. Radians.
        public var byTheLeeMargin: Double
        /// The time constant, seconds, of the average of the wind strength at the boat that the grooves
        /// follow (`Boat.averagedWindSpeed`, #245): a puff shorter than this barely moves the groove, a
        /// build longer than it does. 0 (every schema-2 class) is no average: the grooves read the wind at
        /// the boat right now.
        public var grooveWindAverage: Double
        /// Whether a centred rudder hands her to the autohelm (schema 4, #434, ADR 0011), on every seat, bots
        /// included. True (every class before schema 4, and a schema-4 one that leaves it out): it engages on the
        /// tick the rudder centres and holds her angle to the wind (ADR 0007). False: a centred rudder is a
        /// centred rudder, she holds her heading through the shifts, and the autohelm only sails the tack/gybe tap,
        /// letting go within `handBack` of the new groove.
        public var holdsWhenCentred = true
        /// With `holdsWhenCentred` false, how close to its aim the tap's autohelm brings her past the boom before
        /// it lets go and centres the rudder, radians (schema 4's `handBackDegrees`; 3° when the file leaves it out).
        public var handBack = deg2rad(3)
        /// Whether the tack/gybe tap sails the turn (schema 4's `sailsTap`, #458, ADR 0011; true when the file leaves it
        /// out). False: the tap is logged and does nothing else (no autohelm turn, no roll tack): she tacks and gybes by
        /// hand (skiff@8).
        public var sailsTap = true
    }

    /// How the boat gets on and off the plane (schema 3, #248). Downwind and reaching only: forward of
    /// `fromTWA` she sails the polar as is. The polar is the on-plane speed; off the plane, from `fromTWA`
    /// on, the target is `offPlaneSpeed(twa:tws:polar:)`. The thresholds overlap, so the same heading can
    /// hold two speeds (#244 §4.4): knocked off the plane she heads up to get back on it.
    public struct PlaningTuning: Sendable, Equatable {
        /// She gets on the plane only at or past this true wind angle, radians.
        public var fromTWA: Double
        /// She drops off it forward of this true wind angle, radians (≤ `fromTWA`).
        public var offBelowTWA: Double
        /// She gets on the plane at this speed through the water or more, m/s...
        public var onSpeed: Double
        /// ...with the apparent wind no further aft than this, radians: the sails fed from forward.
        public var onMaxAWA: Double
        /// She drops off it below this speed through the water, m/s (≤ `onSpeed`).
        public var offSpeed: Double
        /// Off the plane she sails the polar's speeds at this true wind speed, m/s...
        public var offPlaneReferenceTWS: Double
        /// ...scaled by 1 + this × (TWS − `offPlaneReferenceTWS`), per m/s, and never faster than the polar.
        public var offPlaneGain: Double

        /// The off-the-plane speed at `twa` (radians) in `tws` (m/s): the reference column's speed at
        /// `twa`, scaled by the wind strength, capped at the polar's (on-plane) speed.
        public func offPlaneSpeed(twa: Double, tws: Double, polar: PolarTable) -> Double {
            let scaled = polar.speed(twa: twa, tws: offPlaneReferenceTWS) * (1 + offPlaneGain * (tws - offPlaneReferenceTWS))
            return min(polar.speed(twa: twa, tws: tws), max(0, scaled))
        }
    }

    /// The automatic spinnaker (schema 3, #248): it goes up when she bears away past `hoistAboveTWA` and
    /// comes down when she heads up past `dropBelowTWA`, taking `transitionTime` each way, during which
    /// she sails at two-sail speed. The polar's rows from `twoSailFullTWA` aft assume it is up.
    public struct SpinnakerTuning: Sendable, Equatable {
        /// True wind angles, radians: hoisted past `hoistAboveTWA`, dropped forward of `dropBelowTWA`.
        public var hoistAboveTWA: Double
        public var dropBelowTWA: Double
        /// Seconds a hoist or a drop takes.
        public var transitionTime: Double
        /// Without the spinnaker drawing she sails the polar × this from `twoSailFullTWA` aft...
        public var twoSailSpeedFactor: Double
        /// ...and the polar as is forward of `twoSailFromTWA` (radians), linear between.
        public var twoSailFromTWA: Double
        public var twoSailFullTWA: Double

        /// The two-sail speed factor at `twa` (radians, 0...π).
        public func twoSailFactor(twa: Double) -> Double {
            if twa <= twoSailFromTWA { return 1 }
            if twa >= twoSailFullTWA { return twoSailSpeedFactor }
            return PolarTable.lerp(1, twoSailSpeedFactor, (twa - twoSailFromTWA) / (twoSailFullTWA - twoSailFromTWA))
        }
    }

    /// Sailing by the lee (schema 3, #248), on top of the polar's flat `byTheLeePenalty`.
    public struct ByTheLeeTuning: Sendable, Equatable {
        /// Fraction of speed lost per radian by the lee (never below nothing).
        public var speedLossPerRadian: Double
        /// A hoisted spinnaker collapses more than this far by the lee, radians: it stops drawing.
        public var spinnakerCollapse: Double

        /// The speed factor `angle` radians by the lee.
        public func speedFactor(byTheLee angle: Double) -> Double { max(0, 1 - speedLossPerRadian * angle) }
    }

    /// The disturbed air behind a boat's sails, and the backwind just to windward of them.
    public struct WindShadow: Sendable, Equatable {
        /// Length of the shadow cone downwind of the boat, metres.
        public var coneLength: Double
        /// Full width of the cone at the boat and at its downwind end, metres.
        public var coneWidthAtBoat: Double
        public var coneWidthAtEnd: Double
        /// Fraction of wind speed lost right behind the boat (0.25 = 25 %).
        public var lossCloseIn: Double
        /// Lowest wind multiplier from stacked shadows (0.6 = never below 60 % of the wind).
        public var stackingFloor: Double

        /// The backwind zone, metres, and the fraction of wind speed (or, for a speed-loss class, of speed) a boat
        /// inside it loses at its strongest. With `backwindInnerLength` (#298) it is a right trapezoid on the caster's
        /// windward quarter from her windward stern corner (`sternCorner`): `backwindWidth` out along her stern,
        /// `backwindLength` astern on its outer edge and `backwindInnerLength` on its inner one (`ShadowCone`).
        /// Without it (every class before #298), #79's band: `backwindLength` up her apparent wind, `backwindWidth` wide.
        public var backwindLength: Double
        public var backwindWidth: Double
        public var backwindLoss: Double
        /// Metres astern of the stern the trapezoid's inner edge reaches (#298; optional, `innerLengthHullLengths`),
        /// or nil for #79's band.
        public var backwindInnerLength: Double?
        /// Which edge of the trapezoid slants (optional, `slantedAtStern`; false when absent, #298's shape): false, its
        /// far edge, `backwindInnerLength` astern on the hull side to `backwindLength` outboard; true, its stern edge,
        /// level with her stern on the hull side to `backwindLength - backwindInnerLength` astern outboard, with the far
        /// edge flat `backwindLength` astern (`backwindSpan(out:)`).
        public var backwindSternSlant = false
        /// The true wind angle, radians, from which she is running and casts no backwind (optional,
        /// `runningFromDegrees`): nil, she casts it on every point of sail (`ShadowCone`).
        public var backwindRunningAngle: Double?
        /// How far before `backwindRunningAngle` the backwind starts to fade, radians (optional,
        /// `runningFadeDegrees`; 0 when absent, so it is switched off at the running angle with no fade): its loss falls
        /// straight from full that far forward of it to nothing at it, so she loses it gradually bearing away
        /// across a reach and gains it back coming up (`ShadowCone.backwindPresence`).
        public var backwindRunningFade = 0.0
        /// The speed, m/s, at which the backwind trapezoid is its full size (optional, `speedScale.referenceKnots`), and
        /// the most it grows to (`speedScale.maxScale`, 1.5 when absent): the trapezoid's length astern scales with her
        /// speed through the water, in proportion, from nothing when stopped (`backwindScale(speed:)`). Nil: it is
        /// the same size at every speed.
        public var backwindScaleSpeed: Double?
        public var backwindMaxScale = 1.5
        /// Whether the cone starts from her bow and stern (optional, `coneFromBowAndStern`; false when absent): its near
        /// edge is the line from her bow to her stern, so it follows her heading across the wind, and its sides run from
        /// those two points to the far end's corners. False: a line across her centre, square to the wind
        /// (`coneWidthAtBoat` wide), as every class before skiff@5 (`ShadowCone`).
        public var coneFromHull = false
        /// How far the cone's axis is swung from straight downwind her apparent wind towards straight astern of her, a
        /// share 0...1 of the angle between them (optional, `coneSwingAsternShare`; 0 when absent: along her apparent wind,
        /// as every class before skiff@5). Close-hauled the wind is nearly over the bow and the cone already falls
        /// astern; across a reach it would fall well to leeward, and the swing opens it behind her (`ShadowCone`).
        public var coneSwing = 0.0
        /// The hull outline's forwardmost point on the centreline in the boat's frame, metres (y forward of the centre):
        /// where the cone starts at her bow. Not a file value: read off the hull outline at load.
        public var bowY: Double
        /// The hull's starboard stern corner in the boat's frame, metres (x out from the centreline, y aft of the
        /// centre, negative): where the backwind trapezoid starts, mirrored to her windward side. Not a file value:
        /// read off the hull outline at load (its aftmost points, widest of them; outlines are symmetric).
        public var sternCorner: Vec2
        /// Seconds: the time constant a shadowed boat slows down at (#220, #263; schema 3, optional). With it the
        /// shadow is a speed loss: her polar reads the clean wind and her target speed is the polar's × the shadow's
        /// multiplier (`Boat.shadow`), approached at this. Nil (every class before skiff@3): the shadow slows the
        /// wind her polar reads (`Boat.polarWindSpeed(in:)`), as #10 built it.
        public var slowingDown: Double?
        /// The wind shadow as a ribbon wake (#377, `TurbulenceRibbons`): every boat's shadow is the ribbons, not a cone.
        /// From the file's `ribbons` block (optional, skiff@6 and ilca-dinghy@5 on); a file without one (every class
        /// before them) seeds it from its cone (`Ribbons.seeded(coneWidthAtBoat:coneWidthAtEnd:lossCloseIn:)`).
        public var ribbons: Ribbons
        /// The backwind as a header (#377; optional `header` block): a boat in another's backwind trapezoid has her wind
        /// turned towards her bow, and the backwind needs a working sail. Nil (every class before skiff@6 and
        /// ilca-dinghy@5): the backwind is #298's loss (or #79's band), as before.
        public var header: Header?
        /// Seconds the backwind fades out over when her sail stops working or her side changes (#377; optional
        /// `backwind.fadeSeconds`, 0 when absent: at once). Read only with a `header`.
        public var backwindFadeSeconds = 0.0
        /// The speed through the water, m/s, below which she casts no backwind (#377; optional `backwind.floorKnots`),
        /// building in straight over `backwindFloorSpan` above it (`backwind.floorBuildKnots`, 0 when absent). Nil: no
        /// floor, the trapezoid's length scale fading it from rest as before (`backwindScale(speed:)`).
        public var backwindFloorSpeed: Double?
        public var backwindFloorSpan = 0.0
        /// The backwind zone as the upwash beside her sail (#377, the owner's renders review; optional `backwind`
        /// fields `mastStationFromBow`, `upwashWidthAtMastHullLengths`, `upwashWidthAftHullLengths`,
        /// `upwashEndFadeHullLengths`, all four or none, with a `header` only, and optionally `upwashAftHullLengths` with them, its length astern of her stern): it replaces
        /// the trapezoid as a header class's envelope (`upwashShare(out:along:)`). Nil: a
        /// header class sails the trapezoid as its envelope; a class without a header never reads it.
        public var backwindUpwash: Upwash?

        /// The ribbon wake's sizes (#377, `TurbulenceRibbons`), in code units. Every value is tuning, not measured
        /// (docs/research/yacht-wake-and-backwind-aerodynamics.md gives the wake's direction and little else).
        public struct Ribbons: Sendable, Equatable {
            /// Seconds between a boat's points.
            public var emitSeconds: Double
            /// A point's life, a multiple of `coneLength` over the caster's apparent wind at emission: 1, the time her
            /// apparent wind takes to carry air one cone length astern.
            public var lifeScale: Double
            /// Full width at the boat and at the end of a point's life, metres (a point's scale is half of it).
            public var startWidth: Double
            public var endWidth: Double
            /// Loss at emission, a fraction of her speed (or wind), at the full emission level.
            public var peak: Double
            /// Neighbouring points further apart than this, metres, aren't joined.
            public var lengthCap: Double
            /// Below this speed through the water, m/s, a boat sheds nothing.
            public var stoppedSpeed: Double
            /// Seconds the emission level (and the backwind, with a `header`) takes to build from nothing to full.
            public var buildSeconds: Double
            /// The sail's angle to her apparent wind, radians, at which she sheds her full turbulence (and casts her
            /// full backwind); less, less, in proportion (`SailTrim.workingScale`).
            public var fullAngle: Double

            public init(emitSeconds: Double, lifeScale: Double, startWidth: Double, endWidth: Double, peak: Double,
                        lengthCap: Double, stoppedSpeed: Double, buildSeconds: Double, fullAngle: Double) {
                self.emitSeconds = emitSeconds
                self.lifeScale = lifeScale
                self.startWidth = startWidth
                self.endWidth = endWidth
                self.peak = peak
                self.lengthCap = lengthCap
                self.stoppedSpeed = stoppedSpeed
                self.buildSeconds = buildSeconds
                self.fullAngle = fullAngle
            }

            /// A class without a `ribbons` block (#377): #376's prototype values, its widths and loss its cone's, so a
            /// steady boat's ribbon is about as long, wide and strong as her cone was.
            public static func seeded(coneWidthAtBoat: Double, coneWidthAtEnd: Double, lossCloseIn: Double) -> Ribbons {
                Ribbons(emitSeconds: 0.5, lifeScale: 1, startWidth: coneWidthAtBoat, endWidth: coneWidthAtEnd,
                        peak: lossCloseIn, lengthCap: 2 * metresPerSecond(knots: 10) * 0.5, stoppedSpeed: 0.3,
                        buildSeconds: 2, fullAngle: deg2rad(12.5))
            }

            /// A point's life, seconds, shed with `apparent` m/s of apparent wind by a class with cone length `coneLength`.
            public func life(apparent: Double, coneLength: Double) -> Double { lifeScale * coneLength / apparent }
        }

        /// The backwind as a header (#377), in code units. Tuning, not measured.
        public struct Header: Sendable, Equatable {
            /// Her wind is turned this far towards her bow at the full backwind envelope, radians; several casters'
            /// headers add, up to `cap`.
            public var angle: Double
            public var cap: Double
            /// The backwind's loss of speed (or wind) at the full envelope, as well as the header: 0, a pure shift.
            public var lull: Double
            /// Seconds: her header follows the envelope she sits in through a first-order lag of this time constant.
            public var lagSeconds: Double

            public init(angle: Double, cap: Double, lull: Double, lagSeconds: Double) {
                self.angle = angle
                self.cap = cap
                self.lull = lull
                self.lagSeconds = lagSeconds
            }
        }

        /// The backwind as the upwash off her sail (#377; docs/research/yacht-wake-and-backwind-aerodynamics.md §2: the
        /// header on a boat to windward is a bound field off the leeward boat's sail, negligible by about 1 L out): on
        /// her windward side, along her hull from her mast back to her stern, and `astern` on past it when set (the
        /// owner's lengthening, so a boat lee-bowed from 2.5-3 L ahead is headed). A fan (the owner's renders review 2):
        /// `widthAtMast` out from her side at her mast, widening straight to `widthAft` out at its aft end; with
        /// `widthAtMast` 0 a wedge from a point at her mast (renders review 3, the placeholder).
        /// In code units; tuning, not measured.
        public struct Upwash: Sendable, Equatable {
            /// Metres from her bow (`bowY`) back to her mast, the zone's forward end.
            public var mastFromBow: Double
            /// Metres out to windward from her side (`sternCorner.x`) at which the zone has faded to nothing, at her
            /// mast (its forward end; 0: the zone starts as a point on her side line) and at its aft end (> 0); straight
            /// between them.
            public var widthAtMast: Double
            public var widthAft: Double
            /// Metres over which it fades in from nothing at its mast end, inside it; and at its stern end too when it
            /// ends at her stern (`astern` nil).
            public var endFade: Double
            /// Metres it runs on astern of her stern, fading straight from full at her stern to nothing at its aft end
            /// (`upwashAftHullLengths`). Nil: it ends at her stern, fading in over `endFade` there.
            public var astern: Double?

            public init(mastFromBow: Double, widthAtMast: Double, widthAft: Double, endFade: Double, astern: Double? = nil) {
                self.mastFromBow = mastFromBow
                self.widthAtMast = widthAtMast
                self.widthAft = widthAft
                self.endFade = endFade
                self.astern = astern
            }
        }

        /// The upwash zone's extent in her frame, metres: from `out` (her side, `sternCorner.x`) out to windward,
        /// `widthAtMast` beyond it at `fore` widening straight to `widthAft` beyond it at `aft` (`upwashWidth(along:)`),
        /// and from `aft` (its aft end: `astern` past her stern, or her stern) through `stern` (her stern,
        /// `sternCorner.y`) forward to `fore` (her mast). Nil without `backwindUpwash`, and for a class it doesn't shape:
        /// one without a `header` and the trapezoid's inner length (the envelope's class,
        /// `ShadowCone.backwindEnvelope(at:)`). The drawn zone is this fan, a quad (`ShadowShapes`), a triangle with no width at her mast.
        public var upwashExtent: (out: Double, widthAtMast: Double, widthAft: Double, aft: Double, stern: Double, fore: Double)? {
            guard let u = backwindUpwash, header != nil, backwindInnerLength != nil else { return nil }
            return (sternCorner.x, u.widthAtMast, u.widthAft, sternCorner.y - (u.astern ?? 0), sternCorner.y, bowY - u.mastFromBow)
        }

        /// The upwash fan's width out from her side at `along` metres forward of her centre (#377): `widthAtMast` at her
        /// mast, straight to `widthAft` at its aft end (and on along the same line beyond them). 0 without `upwashExtent`.
        public func upwashWidth(along: Double) -> Double {
            guard let zone = upwashExtent else { return 0 }
            let length = zone.fore - zone.aft
            guard length > 0 else { return zone.widthAtMast }
            return zone.widthAtMast + (zone.widthAft - zone.widthAtMast) * (zone.fore - along) / length
        }

        /// How much of the upwash reaches a point `out` metres out to windward of her side and `along` metres forward of
        /// her centre, 0...1 (#377): full at her side, falling straight to nothing at the fan's width there
        /// (`upwashWidth(along:)`, a share of the local width); between her stern and
        /// her mast, fading in over `endFade` from nothing at her mast; astern of her stern, falling straight from full
        /// at it to nothing `astern` behind it (or, ending at her stern, fading in over `endFade` there too); 0
        /// elsewhere, and without `upwashExtent`. A point apex (`widthAtMast` 0) is well defined: the width is > 0 strictly
        /// aft of her mast, and a point at her mast or on her side line gets 0, never a division by a zero width.
        /// Before her presence, floor and sail (`ShadowCone.backwindEnvelope(at:)`).
        public func upwashShare(out: Double, along: Double) -> Double {
            guard let zone = upwashExtent, let u = backwindUpwash else { return 0 }
            guard out > 0, along > zone.aft, along < zone.fore else { return 0 }
            let width = upwashWidth(along: along)
            guard width > 0, out < width else { return 0 }
            let fore = u.endFade > 0 ? min(1, (zone.fore - along) / u.endFade) : 1
            let aft: Double
            if let astern = u.astern {
                aft = along >= zone.stern ? 1 : (along - zone.aft) / astern
            } else {
                aft = u.endFade > 0 ? min(1, (along - zone.aft) / u.endFade) : 1
            }
            return (1 - out / width) * min(fore, aft)
        }

        /// Whether the shadow slows the boat rather than the wind her polar reads (`slowingDown`).
        public var isSpeedLoss: Bool { slowingDown != nil }

        /// The factor her backwind trapezoid is scaled by astern at `speed`, m/s through the water: 1 when the class has no
        /// speed scale or her speed isn't known, else `speed / backwindScaleSpeed` on 0...`backwindMaxScale`. With a floor
        /// speed (#377) it never shrinks below its size at the end of the floor's build-in: the floor
        /// (`backwindFloorFactor(speed:)`) fades a slow boat's backwind out, not the trapezoid's length.
        public func backwindScale(speed: Double?) -> Double {
            guard let reference = backwindScaleSpeed, let speed else { return 1 }
            let sized = backwindFloorSpeed.map { max(speed, $0 + backwindFloorSpan) } ?? speed
            return (sized / reference).clamped(to: 0...backwindMaxScale)
        }

        /// How much of her backwind she casts at `speed`, m/s through the water (#377): none at or below
        /// `backwindFloorSpeed`, building straight to all of it `backwindFloorSpan` above it; 1 without a floor or when
        /// her speed isn't known.
        public func backwindFloorFactor(speed: Double?) -> Double {
            guard let floor = backwindFloorSpeed, let speed else { return 1 }
            guard speed > floor else { return 0 }
            guard backwindFloorSpan > 0 else { return 1 }
            return min(1, (speed - floor) / backwindFloorSpan)
        }

        /// The backwind trapezoid's extent astern of her stern line `out` metres out along it from the stern corner
        /// (0 on the hull side, `backwindWidth` outboard): where it starts and where it ends, metres astern. Nil for a
        /// class with #79's band. The slanted edge is the far one (`start` 0) or the stern one (`end` the full length).
        public func backwindSpan(out: Double) -> (start: Double, end: Double)? {
            guard let inner = backwindInnerLength else { return nil }
            // `out` is on 0...backwindWidth (a class with an inner length has a positive width). The far-edge shape's
            // operations are #298's exactly, so the classes sailed before this one replay bit for bit.
            if backwindSternSlant { return ((backwindLength - inner) * out / backwindWidth, backwindLength) }
            return (0, inner + (backwindLength - inner) * out / backwindWidth)
        }
    }

    /// The roll tack (#222, #263): a second tack/gybe tap during a tack, timed on the boom crossing. A hit, within
    /// `window` of the crossing either way, keeps `hitLossFraction` of each tick's speed loss from the tap (or the
    /// crossing, for a tap before it) until she is close-hauled: no floor and no jump, so a rolled tack never beats
    /// not tacking. A miss, outside it, multiplies her speed by `missSpeedFactor` once. One roll a tack.
    public struct RollTackTuning: Sendable, Equatable {
        /// Seconds either side of the boom crossing that a roll tap hits.
        public var window: Double
        /// The fraction of each tick's speed loss a hit still takes (0.5: she loses half as much).
        public var hitLossFraction: Double
        /// Her speed is multiplied by this on a miss.
        public var missSpeedFactor: Double

        /// `window` in whole ticks at `Race.tickRate`: a tap `window` ticks or fewer from the crossing hits.
        public var windowTicks: Int { Int((window * Double(Race.tickRate) + 1e-9).rounded(.down)) }
    }

    /// Speed multipliers on contact.
    public struct Contact: Sendable, Equatable {
        /// Hitting another boat.
        public var boat: Double
        /// Hitting a mark.
        public var mark: Double
    }

    /// Letting the sheets go so the boat slows.
    public struct Ease: Sendable, Equatable {
        /// Fraction of polar speed the boat slows to while eased.
        public var speedFraction: Double
        /// Time constant of slowing down when eased, seconds.
        public var timeConstant: Double
    }

    public init(fileData: Data, header: DataFileHeader) throws {
        switch header.schemaVersion {
        case 2:
            self = try JSONDecoder().decode(BoatClassSchema2.self, from: fileData).boatClass(id: header.id)
        case 3, 4:
            // Schema 3 is schema 2's fields with its additions, and schema 4 schema 3's with its own: all read the
            // same file.
            var boatClass = try JSONDecoder().decode(BoatClassSchema2.self, from: fileData).boatClass(id: header.id)
            try JSONDecoder().decode(BoatClassSchema3Additions.self, from: fileData).apply(to: &boatClass, id: header.id)
            if header.schemaVersion == 4 {
                try JSONDecoder().decode(BoatClassSchema4Additions.self, from: fileData).apply(to: &boatClass, id: header.id)
            }
            self = boatClass
        default:
            throw DataFileError.unsupportedSchemaVersion(
                kind: Self.kind, found: header.schemaVersion, supported: Self.supportedSchemaVersions)
        }
    }

    fileprivate init(
        name: String, hull: Hull, polar: PolarTable, momentum: Momentum, steering: Steering,
        windShadow: WindShadow, contact: Contact, ease: Ease
    ) {
        self.name = name
        self.hull = hull
        self.polar = polar
        self.momentum = momentum
        self.steering = steering
        self.windShadow = windShadow
        self.contact = contact
        self.ease = ease
    }
}

public typealias BoatClassFile = DataFile<BoatClass>

// MARK: - Schema 2

/// The boat class file, schema version 2, as written: knots, degrees, seconds, hull lengths. Schema 1 without
/// `steering.autohelm`.
private struct BoatClassSchema2: Decodable {
    struct Hull: Decodable {
        let lengthMetres: Double
        let beamMetres: Double
        /// [x, y] points, metres: x to starboard, y towards the bow.
        let outlineMetres: [[Double]]
    }

    struct Polar: Decodable {
        struct Column: Decodable {
            let twsKnots: Double
            /// One per row of `twaDegrees`.
            let speedKnots: [Double]
        }

        struct ByTheLeeLimit: Decodable {
            let twsKnots: Double
            let degrees: Double
        }

        let twaDegrees: [Double]
        let columns: [Column]
        let byTheLeeLimit: [ByTheLeeLimit]
        let byTheLeePenalty: Double
    }

    struct Momentum: Decodable {
        let speedingUpSeconds: Double
        let slowingDownSeconds: Double
        let noGoSeconds: Double
    }

    struct Steering: Decodable {
        struct CurvePoint: Decodable {
            let speedKnots: Double
            let fraction: Double
        }

        /// Schema 2 (#230).
        struct Autohelm: Decodable {
            let upwindSnapDegrees: Double
            let downwindSnapDegrees: Double
            /// Rudder (−1 … 1) per degree of error.
            let gainRudderPerDegree: Double
            let deadRunMarginDegrees: Double
            let byTheLeeMarginDegrees: Double
        }

        let topTurnRateDegreesPerSecond: Double
        let minTurnRateDegreesPerSecond: Double
        let turnRateCurve: [CurvePoint]
        let headToWindFallOffDegreesPerSecond: Double
        let rudderDragPerSecond: Double
        let rudderSlewPerSecond: Double
        let autohelm: Autohelm
    }

    struct WindShadow: Decodable {
        struct Backwind: Decodable {
            let lengthHullLengths: Double
            let widthHullLengths: Double
            let loss: Double
            /// #298: the trapezoid's inner length (`BoatClass.WindShadow.backwindInnerLength`). Optional: a file
            /// without it (every one before #298) casts #79's band.
            let innerLengthHullLengths: Double?
            /// The trapezoid's stern edge slants, not its far one (`BoatClass.WindShadow.backwindSternSlant`). Optional.
            let slantedAtStern: Bool?
            /// The true wind angle from which she is running and casts none (`backwindRunningAngle`). Optional.
            let runningFromDegrees: Double?
            /// The backwind fades out over this many degrees before the running angle (`backwindRunningFade`). Optional.
            let runningFadeDegrees: Double?
            /// The trapezoid grows with her speed (`backwindScaleSpeed`, `backwindMaxScale`). Optional.
            struct SpeedScale: Decodable {
                let referenceKnots: Double
                let maxScale: Double?
            }
            let speedScale: SpeedScale?
            /// #377: the backwind fades out over this when her sail stops working (`backwindFadeSeconds`). Optional.
            let fadeSeconds: Double?
            /// #377: the floor speed below which she casts none, and the speed span it builds in over
            /// (`backwindFloorSpeed`, `backwindFloorSpan`). Optional.
            let floorKnots: Double?
            let floorBuildKnots: Double?
            /// #377: the header's zone as the upwash beside her sail (`BoatClass.WindShadow.Upwash`): her mast's
            /// station back from her bow, a share of her length; how far out it reaches at her mast and at its aft end
            /// (a fan, the owner's renders review 2; 0 at her mast: a wedge from a point there, review 3) and its end fade, hull lengths. Optional, all four or none, with a
            /// header only.
            let mastStationFromBow: Double?
            let upwashWidthAtMastHullLengths: Double?
            let upwashWidthAftHullLengths: Double?
            let upwashEndFadeHullLengths: Double?
            /// #377 (the owner's lengthening): how far the upwash runs on astern of her stern, hull lengths, fading to
            /// nothing at its end. Optional, with the upwash only; without it the zone ends at her stern.
            let upwashAftHullLengths: Double?
        }

        /// #377: the ribbon wake (`BoatClass.WindShadow.Ribbons`). Optional: without it, seeded from the cone.
        struct Ribbons: Decodable {
            let emitSeconds: Double
            let lifeConeLengths: Double
            let startWidthHullLengths: Double
            let endWidthHullLengths: Double
            let peakLoss: Double
            let joinCapHullLengths: Double
            let stoppedKnots: Double
            let buildSeconds: Double
            let fullAngleDegrees: Double
        }

        /// #377: the backwind as a header (`BoatClass.WindShadow.Header`). Optional: without it, the backwind is a loss.
        struct Header: Decodable {
            let degrees: Double
            let capDegrees: Double
            let lullLoss: Double
            let lagSeconds: Double
        }

        let coneLengthHullLengths: Double
        let coneWidthAtBoatHullLengths: Double
        let coneWidthAtEndHullLengths: Double
        let lossCloseIn: Double
        let stackingFloor: Double
        /// The cone starts from her bow and stern (`BoatClass.WindShadow.coneFromHull`). Optional.
        let coneFromBowAndStern: Bool?
        /// The cone's axis swings this share of the way from downwind to astern (`BoatClass.WindShadow.coneSwing`). Optional.
        let coneSwingAsternShare: Double?
        let backwind: Backwind
        let ribbons: Ribbons?
        let header: Header?
    }

    struct Contact: Decodable {
        let boatSpeedFactor: Double
        let markSpeedFactor: Double
    }

    struct Ease: Decodable {
        let speedFraction: Double
        let timeConstantSeconds: Double
    }

    let name: String
    let hull: Hull
    let polar: Polar
    let momentum: Momentum
    let steering: Steering
    let windShadow: WindShadow
    let contact: Contact
    let ease: Ease

    func boatClass(id: String) throws -> BoatClass {
        func invalid(_ reason: String) -> DataFileError {
            DataFileError.invalidContent(kind: BoatClass.kind, id: id, reason: reason)
        }
        func check(_ condition: Bool, _ reason: @autoclosure () -> String) throws {
            if !condition { throw invalid(reason()) }
        }
        func positive(_ value: Double) -> Bool { value.isFinite && value > 0 }
        func fraction(_ value: Double) -> Bool { value >= 0 && value <= 1 }

        try check(!name.isEmpty, "name is empty")
        try check(positive(hull.lengthMetres) && positive(hull.beamMetres), "hull length and beam must be positive")
        try check(hull.outlineMetres.count >= 3 && hull.outlineMetres.allSatisfy { $0.count == 2 && $0.allSatisfy(\.isFinite) },
                  "hull outline needs at least three [x, y] points")
        let outline = hull.outlineMetres.map { Vec2($0[0], $0[1]) }
        try check(Self.isConvexClockwise(outline),
                  "hull outline must be convex and run clockwise (bow, starboard side, stern, port side), as Boat.hull(outline:) does")
        try check(polar.twaDegrees.first == 0 && polar.twaDegrees.last == 180, "polar TWA rows must run from 0° to 180°")

        let table: PolarTable
        do {
            table = try PolarTable(
                twaAxis: polar.twaDegrees.map(deg2rad),
                twsAxis: polar.columns.map { metresPerSecond(knots: $0.twsKnots) },
                speeds: polar.columns.map { $0.speedKnots.map { metresPerSecond(knots: $0) } },
                byTheLeeLimitTWS: polar.byTheLeeLimit.map { metresPerSecond(knots: $0.twsKnots) },
                byTheLeeLimits: polar.byTheLeeLimit.map { deg2rad($0.degrees) },
                byTheLeePenalty: polar.byTheLeePenalty
            )
        } catch let error as PolarTable.TableError {
            throw invalid("polar: \(error)")
        }

        try check(positive(momentum.speedingUpSeconds) && positive(momentum.slowingDownSeconds) && positive(momentum.noGoSeconds),
                  "momentum time constants must be positive")

        let curveSpeeds = steering.turnRateCurve.map { metresPerSecond(knots: $0.speedKnots) }
        try check(!curveSpeeds.isEmpty && zip(curveSpeeds, curveSpeeds.dropFirst()).allSatisfy { $0 < $1 },
                  "turn rate curve needs points in ascending speed")
        try check(steering.turnRateCurve.allSatisfy { fraction($0.fraction) }, "turn rate curve fractions must be 0...1")
        try check(positive(steering.topTurnRateDegreesPerSecond) && positive(steering.minTurnRateDegreesPerSecond)
                  && steering.minTurnRateDegreesPerSecond <= steering.topTurnRateDegreesPerSecond,
                  "turn rates must be positive, with min ≤ top")
        try check(steering.headToWindFallOffDegreesPerSecond >= 0 && steering.rudderDragPerSecond >= 0
                  && positive(steering.rudderSlewPerSecond), "steering rates must not be negative")
        let helm = steering.autohelm
        try check([helm.upwindSnapDegrees, helm.downwindSnapDegrees, helm.deadRunMarginDegrees, helm.byTheLeeMarginDegrees]
                    .allSatisfy { $0 >= 0 && $0 < 90 }, "autohelm snap widths and margins must be 0..<90°")
        try check(positive(helm.gainRudderPerDegree), "autohelm gain must be positive")

        try check(positive(windShadow.coneLengthHullLengths) && positive(windShadow.coneWidthAtBoatHullLengths)
                  && positive(windShadow.coneWidthAtEndHullLengths), "shadow cone sizes must be positive")
        try check(fraction(windShadow.lossCloseIn) && fraction(windShadow.stackingFloor) && fraction(windShadow.backwind.loss),
                  "shadow losses and floor must be 0...1")
        try check(windShadow.backwind.lengthHullLengths >= 0 && windShadow.backwind.widthHullLengths >= 0,
                  "backwind size must not be negative")
        if let inner = windShadow.backwind.innerLengthHullLengths {
            try check(positive(windShadow.backwind.lengthHullLengths) && positive(windShadow.backwind.widthHullLengths)
                      && positive(inner) && inner <= windShadow.backwind.lengthHullLengths,
                      "backwind trapezoid needs a positive length and width, and an inner length in 0 exclusive ... its length")
        }
        try check(windShadow.backwind.slantedAtStern != true || windShadow.backwind.innerLengthHullLengths != nil,
                  "a backwind slanted at the stern needs an inner length")
        if let running = windShadow.backwind.runningFromDegrees {
            try check(running > 0 && running <= 180, "backwind running angle must be above 0 and at most 180°")
            try check((windShadow.backwind.runningFadeDegrees ?? 0) >= 0 && (windShadow.backwind.runningFadeDegrees ?? 0) <= running,
                      "backwind running fade must be 0 up to the running angle")
        }
        try check(windShadow.backwind.runningFadeDegrees == nil || windShadow.backwind.runningFromDegrees != nil,
                  "a backwind running fade needs a running angle")
        if let scale = windShadow.backwind.speedScale {
            try check(windShadow.backwind.innerLengthHullLengths != nil && positive(scale.referenceKnots)
                      && (scale.maxScale ?? 1.5) >= 1, "a backwind speed scale needs an inner length, a positive reference speed and a max scale of 1 or more")
        }
        try check(fraction(windShadow.coneSwingAsternShare ?? 0), "the cone's swing astern must be a share, 0...1")
        try check(windShadow.coneFromBowAndStern != true || windShadow.backwind.innerLengthHullLengths != nil,
                  "a cone from the bow and stern needs a backwind inner length (the trapezoid class)")
        if let r = windShadow.ribbons {
            try check(positive(r.emitSeconds) && positive(r.lifeConeLengths), "ribbon emission interval and life must be positive")
            try check(positive(r.startWidthHullLengths) && positive(r.endWidthHullLengths) && positive(r.joinCapHullLengths),
                      "ribbon widths and join cap must be positive")
            try check(fraction(r.peakLoss), "ribbon peak loss must be 0...1")
            try check(r.stoppedKnots.isFinite && r.stoppedKnots >= 0 && r.buildSeconds.isFinite && r.buildSeconds >= 0,
                      "ribbon stopped speed and build time must not be negative")
            try check(r.fullAngleDegrees > 0 && r.fullAngleDegrees < 90, "ribbon full sail angle must be in 0 exclusive ..<90°")
        }
        if let h = windShadow.header {
            try check(windShadow.backwind.innerLengthHullLengths != nil, "a backwind header needs a backwind inner length (the trapezoid class)")
            try check(h.degrees >= 0 && h.degrees < 90 && h.capDegrees >= 0 && h.capDegrees < 90,
                      "backwind header and its cap must be 0..<90°")
            try check(fraction(h.lullLoss) && h.lagSeconds.isFinite && h.lagSeconds >= 0,
                      "backwind header lull must be 0...1 and its lag not negative")
        }
        let upwash = [windShadow.backwind.mastStationFromBow, windShadow.backwind.upwashWidthAtMastHullLengths,
                      windShadow.backwind.upwashWidthAftHullLengths, windShadow.backwind.upwashEndFadeHullLengths]
        try check(upwash.allSatisfy { $0 == nil } || upwash.allSatisfy { $0 != nil },
                  "a backwind upwash needs its mast station, widths and end fade together")
        if let station = upwash[0], let atMast = upwash[1], let aftWidth = upwash[2], let fade = upwash[3] {
            try check(windShadow.header != nil, "a backwind upwash needs a header")
            try check(station >= 0 && station < 1 && fade.isFinite && fade >= 0,
                      "backwind upwash mast station must be 0..<1 of her length and its end fade not negative")
            try check(atMast.isFinite && atMast >= 0 && positive(aftWidth) && aftWidth >= atMast,
                      "backwind upwash width at the mast must not be negative, its aft width positive and no less than at the mast")
        }
        if let aft = windShadow.backwind.upwashAftHullLengths {
            try check(upwash[0] != nil, "a backwind upwash aft length needs the upwash")
            try check(positive(aft), "backwind upwash aft length must be positive")
        }
        try check(windShadow.backwind.fadeSeconds == nil || windShadow.header != nil, "a backwind fade needs a header")
        try check((windShadow.backwind.fadeSeconds ?? 0).isFinite && (windShadow.backwind.fadeSeconds ?? 0) >= 0,
                  "backwind fade must not be negative")
        try check((windShadow.backwind.floorKnots ?? 0).isFinite && (windShadow.backwind.floorKnots ?? 0) >= 0
                  && (windShadow.backwind.floorBuildKnots ?? 0).isFinite && (windShadow.backwind.floorBuildKnots ?? 0) >= 0,
                  "backwind floor speed and build span must not be negative")
        try check(windShadow.backwind.floorBuildKnots == nil || windShadow.backwind.floorKnots != nil,
                  "a backwind floor build span needs a floor speed")
        try check(fraction(contact.boatSpeedFactor) && fraction(contact.markSpeedFactor), "contact factors must be 0...1")
        try check(fraction(ease.speedFraction) && positive(ease.timeConstantSeconds), "ease needs a 0...1 fraction and a positive time")

        let length = hull.lengthMetres
        return BoatClass(
            name: name,
            hull: .init(length: length, beam: hull.beamMetres, outline: outline),
            polar: table,
            momentum: .init(speedingUp: momentum.speedingUpSeconds, slowingDown: momentum.slowingDownSeconds,
                            noGo: momentum.noGoSeconds),
            steering: .init(
                topTurnRate: deg2rad(steering.topTurnRateDegreesPerSecond),
                minTurnRate: deg2rad(steering.minTurnRateDegreesPerSecond),
                turnRateCurveSpeeds: curveSpeeds,
                turnRateCurveFractions: steering.turnRateCurve.map(\.fraction),
                headToWindFallOffRate: deg2rad(steering.headToWindFallOffDegreesPerSecond),
                rudderDrag: steering.rudderDragPerSecond,
                rudderSlew: steering.rudderSlewPerSecond,
                autohelm: .init(
                    upwindSnap: deg2rad(helm.upwindSnapDegrees),
                    downwindSnap: deg2rad(helm.downwindSnapDegrees),
                    gain: helm.gainRudderPerDegree * 180 / .pi,
                    deadRunMargin: deg2rad(helm.deadRunMarginDegrees),
                    byTheLeeMargin: deg2rad(helm.byTheLeeMarginDegrees),
                    grooveWindAverage: 0
                )
            ),
            windShadow: .init(
                coneLength: windShadow.coneLengthHullLengths * length,
                coneWidthAtBoat: windShadow.coneWidthAtBoatHullLengths * length,
                coneWidthAtEnd: windShadow.coneWidthAtEndHullLengths * length,
                lossCloseIn: windShadow.lossCloseIn,
                stackingFloor: windShadow.stackingFloor,
                backwindLength: windShadow.backwind.lengthHullLengths * length,
                backwindWidth: windShadow.backwind.widthHullLengths * length,
                backwindLoss: windShadow.backwind.loss,
                backwindInnerLength: windShadow.backwind.innerLengthHullLengths.map { $0 * length },
                backwindSternSlant: windShadow.backwind.slantedAtStern ?? false,
                backwindRunningAngle: windShadow.backwind.runningFromDegrees.map(deg2rad),
                backwindRunningFade: deg2rad(windShadow.backwind.runningFadeDegrees ?? 0),
                backwindScaleSpeed: windShadow.backwind.speedScale.map { metresPerSecond(knots: $0.referenceKnots) },
                backwindMaxScale: windShadow.backwind.speedScale?.maxScale ?? 1.5,
                coneFromHull: windShadow.coneFromBowAndStern ?? false,
                coneSwing: windShadow.coneSwingAsternShare ?? 0,
                bowY: outline.map(\.y).max() ?? 0,
                sternCorner: Self.sternCorner(of: outline),
                slowingDown: nil,
                ribbons: windShadow.ribbons.map { r in
                    .init(emitSeconds: r.emitSeconds, lifeScale: r.lifeConeLengths,
                          startWidth: r.startWidthHullLengths * length, endWidth: r.endWidthHullLengths * length,
                          peak: r.peakLoss, lengthCap: r.joinCapHullLengths * length,
                          stoppedSpeed: metresPerSecond(knots: r.stoppedKnots), buildSeconds: r.buildSeconds,
                          fullAngle: deg2rad(r.fullAngleDegrees))
                } ?? .seeded(coneWidthAtBoat: windShadow.coneWidthAtBoatHullLengths * length,
                             coneWidthAtEnd: windShadow.coneWidthAtEndHullLengths * length,
                             lossCloseIn: windShadow.lossCloseIn),
                header: windShadow.header.map {
                    .init(angle: deg2rad($0.degrees), cap: deg2rad($0.capDegrees), lull: $0.lullLoss, lagSeconds: $0.lagSeconds)
                },
                backwindFadeSeconds: windShadow.backwind.fadeSeconds ?? 0,
                backwindFloorSpeed: windShadow.backwind.floorKnots.map { metresPerSecond(knots: $0) },
                backwindFloorSpan: metresPerSecond(knots: windShadow.backwind.floorBuildKnots ?? 0),
                backwindUpwash: windShadow.backwind.mastStationFromBow.flatMap { station in
                    windShadow.backwind.upwashWidthAtMastHullLengths.flatMap { atMast in
                        windShadow.backwind.upwashWidthAftHullLengths.flatMap { aftWidth in
                            windShadow.backwind.upwashEndFadeHullLengths.map { fade in
                                .init(mastFromBow: station * length, widthAtMast: atMast * length,
                                      widthAft: aftWidth * length, endFade: fade * length,
                                      astern: windShadow.backwind.upwashAftHullLengths.map { $0 * length })
                            }
                        }
                    }
                }
            ),
            contact: .init(boat: contact.boatSpeedFactor, mark: contact.markSpeedFactor),
            ease: .init(speedFraction: ease.speedFraction, timeConstant: ease.timeConstantSeconds)
        )
    }

    /// The outline's starboard stern corner: of its aftmost points, the one furthest out, x as a distance out.
    static func sternCorner(of outline: [Vec2]) -> Vec2 {
        let aft = outline.map(\.y).min() ?? 0
        let out = outline.filter { $0.y == aft }.map { abs($0.x) }.max() ?? 0
        return Vec2(out, aft)
    }

    /// A simple convex polygon wound clockwise in the boat's frame (x to starboard, y towards the bow):
    /// every corner turns right, and the turns add up to exactly one full turn (a star turns twice).
    /// Separating-axis collision needs convex hulls.
    static func isConvexClockwise(_ points: [Vec2]) -> Bool {
        var turning = 0.0
        for k in points.indices {
            let a = points[k], b = points[(k + 1) % points.count], c = points[(k + 2) % points.count]
            let e1 = b - a, e2 = c - b
            let turn = e1.cross(e2)
            guard turn < 0 else { return false }
            turning += atan2(turn, e1.dot(e2))
        }
        return abs(turning + 2 * .pi) < 1e-6
    }
}

// MARK: - Schema 3

/// What the boat class file's schema 3 adds to schema 2 (#248, the skiff), as written: knots and degrees.
/// Every field is required: RegattaCore holds no boat constants to default one to (ADR 0004).
private struct BoatClassSchema3Additions: Decodable {
    struct Steering: Decodable {
        struct Autohelm: Decodable {
            let grooveWindAverageSeconds: Double
        }

        let autohelm: Autohelm
    }

    struct Planing: Decodable {
        struct OffPlane: Decodable {
            let referenceTWSKnots: Double
            /// Fraction of the reference column's speed gained per knot of true wind above its own.
            let gainPerKnot: Double
        }

        let fromTWADegrees: Double
        let offBelowTWADegrees: Double
        let onSpeedKnots: Double
        let onMaxAWADegrees: Double
        let offSpeedKnots: Double
        let offPlane: OffPlane
    }

    struct Spinnaker: Decodable {
        struct TwoSail: Decodable {
            let speedFactor: Double
            let fromTWADegrees: Double
            let fullTWADegrees: Double
        }

        let hoistAboveTWADegrees: Double
        let dropBelowTWADegrees: Double
        let transitionSeconds: Double
        let twoSail: TwoSail
    }

    struct ByTheLee: Decodable {
        /// Fraction of speed lost per degree by the lee.
        let speedLossPerDegree: Double
        let spinnakerCollapseDegrees: Double
    }

    /// #263: the shadow's own slow-down (`BoatClass.WindShadow.slowingDown`). Optional: a schema-3 class without
    /// it (skiff@1, skiff@2) keeps the shadow a wind loss.
    struct WindShadow: Decodable {
        let slowingDownSeconds: Double?
    }

    /// #263: the roll tack (`BoatClass.RollTackTuning`). Optional: a class without it has none.
    struct RollTack: Decodable {
        let windowSeconds: Double
        let hitLossFraction: Double
        let missSpeedFactor: Double
    }

    let steering: Steering
    let planing: Planing
    let spinnaker: Spinnaker
    let byTheLee: ByTheLee
    let windShadow: WindShadow?
    let rollTack: RollTack?

    /// The longest hoist or drop the wire snapshot carries (`RegattaProtocol`: a byte of ticks).
    static let maxTransitionSeconds = 8.0

    func apply(to boatClass: inout BoatClass, id: String) throws {
        func check(_ condition: Bool, _ reason: @autoclosure () -> String) throws {
            if !condition { throw DataFileError.invalidContent(kind: BoatClass.kind, id: id, reason: reason()) }
        }
        func positive(_ value: Double) -> Bool { value.isFinite && value > 0 }
        func angle(_ degrees: Double) -> Bool { degrees >= 0 && degrees <= 180 }

        let average = steering.autohelm.grooveWindAverageSeconds
        try check(average.isFinite && average >= 0, "autohelm groove wind average must not be negative")

        let p = planing
        try check(angle(p.fromTWADegrees) && angle(p.offBelowTWADegrees) && p.offBelowTWADegrees <= p.fromTWADegrees,
                  "planing angles must be 0...180°, dropping off the plane no further aft than it gets on")
        try check(positive(p.onSpeedKnots) && positive(p.offSpeedKnots) && p.offSpeedKnots <= p.onSpeedKnots,
                  "planing speeds must be positive, dropping off at no more than it gets on")
        try check(p.onMaxAWADegrees > 0 && p.onMaxAWADegrees <= 180, "planing apparent wind angle must be in 0 exclusive ...180°")
        try check(positive(p.offPlane.referenceTWSKnots) && p.offPlane.gainPerKnot.isFinite && p.offPlane.gainPerKnot >= 0,
                  "off-plane reference wind must be positive and its gain not negative")

        let k = spinnaker
        try check(angle(k.hoistAboveTWADegrees) && angle(k.dropBelowTWADegrees) && k.dropBelowTWADegrees <= k.hoistAboveTWADegrees,
                  "spinnaker angles must be 0...180°, dropping it no further aft than it goes up")
        try check(positive(k.transitionSeconds) && k.transitionSeconds <= Self.maxTransitionSeconds,
                  "spinnaker transition must be positive and at most \(Self.maxTransitionSeconds) s")
        try check(k.twoSail.speedFactor >= 0 && k.twoSail.speedFactor <= 1, "two-sail speed factor must be 0...1")
        try check(angle(k.twoSail.fromTWADegrees) && angle(k.twoSail.fullTWADegrees)
                  && k.twoSail.fromTWADegrees < k.twoSail.fullTWADegrees,
                  "two-sail angles must be 0...180°, the ramp's start forward of its end")

        try check(byTheLee.speedLossPerDegree >= 0 && byTheLee.speedLossPerDegree <= 1, "by-the-lee speed loss must be 0...1 per degree")
        try check(byTheLee.spinnakerCollapseDegrees >= 0 && byTheLee.spinnakerCollapseDegrees <= 90,
                  "spinnaker collapse must be 0...90° by the lee")

        if let seconds = windShadow?.slowingDownSeconds {
            try check(positive(seconds), "shadow slow-down time must be positive")
            boatClass.windShadow.slowingDown = seconds
        }
        if let roll = rollTack {
            try check(roll.windowSeconds.isFinite && roll.windowSeconds >= 0, "roll tack window must not be negative")
            try check(roll.hitLossFraction >= 0 && roll.hitLossFraction <= 1 && roll.missSpeedFactor >= 0 && roll.missSpeedFactor <= 1,
                      "roll tack hit loss and miss factor must be 0...1")
            boatClass.rollTack = .init(window: roll.windowSeconds, hitLossFraction: roll.hitLossFraction,
                                       missSpeedFactor: roll.missSpeedFactor)
        }
        boatClass.steering.autohelm.grooveWindAverage = average
        boatClass.planing = .init(
            fromTWA: deg2rad(p.fromTWADegrees),
            offBelowTWA: deg2rad(p.offBelowTWADegrees),
            onSpeed: metresPerSecond(knots: p.onSpeedKnots),
            onMaxAWA: deg2rad(p.onMaxAWADegrees),
            offSpeed: metresPerSecond(knots: p.offSpeedKnots),
            offPlaneReferenceTWS: metresPerSecond(knots: p.offPlane.referenceTWSKnots),
            offPlaneGain: p.offPlane.gainPerKnot / metresPerSecond(knots: 1)
        )
        boatClass.spinnaker = .init(
            hoistAboveTWA: deg2rad(k.hoistAboveTWADegrees),
            dropBelowTWA: deg2rad(k.dropBelowTWADegrees),
            transitionTime: k.transitionSeconds,
            twoSailSpeedFactor: k.twoSail.speedFactor,
            twoSailFromTWA: deg2rad(k.twoSail.fromTWADegrees),
            twoSailFullTWA: deg2rad(k.twoSail.fullTWADegrees)
        )
        boatClass.byTheLee = .init(
            speedLossPerRadian: byTheLee.speedLossPerDegree * 180 / .pi,
            spinnakerCollapse: deg2rad(byTheLee.spinnakerCollapseDegrees)
        )
    }
}

// MARK: - Schema 4

/// What the boat class file's schema 4 adds to schema 3 (#434, ADR 0011): optional autohelm values, and from #458 the
/// rudder drag's exponent, irons recovery and whether the tap sails the turn. Left out, the class sails as a schema-3
/// one: the autohelm holds a centred rudder, a tap lets go 3° from the groove and sails the turn, the drag is linear in
/// the rudder and she falls off head to wind at `headToWindFallOffDegreesPerSecond` alone.
private struct BoatClassSchema4Additions: Decodable {
    struct Steering: Decodable {
        struct Autohelm: Decodable {
            /// A JSON bool, or the number 0 or 1: a tuned copy (`TunedCopy`) writes numbers only.
            let holdsWhenCentred: FlagValue?
            let handBackDegrees: Double?
            /// #458: a JSON bool, or the number 0 or 1, as `holdsWhenCentred`.
            let sailsTap: FlagValue?
        }

        let autohelm: Autohelm?
        /// #458: M1, the power of the rudder in the rudder drag. Absent: 1.
        let rudderDragExponent: Double?
        /// #458: irons recovery. Absent: the class falls off at `headToWindFallOffDegreesPerSecond` alone.
        let headToWindFallOffCentredDegreesPerSecond: Double?
    }

    /// A flag as a JSON bool or a number.
    enum FlagValue: Decodable {
        case bool(Bool)
        case number(Double)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let flag = try? container.decode(Bool.self) {
                self = .bool(flag)
            } else {
                self = .number(try container.decode(Double.self))
            }
        }
    }

    let steering: Steering?

    func apply(to boatClass: inout BoatClass, id: String) throws {
        func check(_ condition: Bool, _ reason: @autoclosure () -> String) throws {
            if !condition { throw DataFileError.invalidContent(kind: BoatClass.kind, id: id, reason: reason()) }
        }
        func flag(_ value: FlagValue?, _ name: String) throws -> Bool? {
            switch value {
            case .bool(let flag): return flag
            case .number(let number):
                try check(number == 0 || number == 1, "autohelm \(name) must be true, false, 0 or 1")
                return number == 1
            case nil: return nil
            }
        }
        if let exponent = steering?.rudderDragExponent {
            try check(exponent.isFinite && exponent >= 1, "rudder drag exponent must be 1 or more")
            boatClass.steering.rudderDragExponent = exponent
        }
        if let centred = steering?.headToWindFallOffCentredDegreesPerSecond {
            try check(centred.isFinite && centred >= 0, "centred head-to-wind fall-off must not be negative")
            boatClass.steering.headToWindFallOffCentredRate = deg2rad(centred)
        }
        guard let helm = steering?.autohelm else { return }
        if let holds = try flag(helm.holdsWhenCentred, "holdsWhenCentred") {
            boatClass.steering.autohelm.holdsWhenCentred = holds
        }
        if let degrees = helm.handBackDegrees {
            try check(degrees.isFinite && degrees > 0 && degrees < 90, "autohelm hand-back must be in 0 exclusive ..<90°")
            boatClass.steering.autohelm.handBack = deg2rad(degrees)
        }
        if let sails = try flag(helm.sailsTap, "sailsTap") {
            boatClass.steering.autohelm.sailsTap = sails
        }
    }
}
