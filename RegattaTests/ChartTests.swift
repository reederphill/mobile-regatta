import Foundation
import SpriteKit
import Testing
import RegattaCore
@testable import Regatta

/// The chart's marks (#115, #15): orange for the marks of the leg you're sailing, grey for every other mark.
@MainActor @Suite struct ChartMarksTests {
    /// A three-lap course on the default files: W, O, gate twice, then W, O and the finish.
    static let course = PracticeDriver(config: RaceDriverTests.config).course

    /// Every mark: the buoys, the gate's pair included, and the line's ends.
    static var marks: [CourseLayout.Mark] {
        course.elements.flatMap(\.marks) + [course.startLine.pin, course.startLine.committee]
    }

    static var windward: CourseLayout.Mark { course.elements[CourseLayout.windwardIndex].marks[0] }
    static var offset: CourseLayout.Mark { course.elements[CourseLayout.offsetIndex].marks[0] }
    static var gate: [CourseLayout.Mark] { course.elements[CourseLayout.gateIndex].marks }
    static var lineEnds: [CourseLayout.Mark] { [course.startLine.pin, course.startLine.committee] }

    /// The marks drawn orange for a boat with `status` on leg `legIndex`.
    static func orange(_ status: BoatStatus, _ legIndex: Int = 0) -> [CourseLayout.Mark] {
        marks.filter { ChartMarks.tone(of: $0, in: course, status: status, legIndex: legIndex) == CuePalette.orange }
    }

    /// Acceptance: mark styling returns orange only for marks of the boat's current leg, grey otherwise, the gate
    /// and the offset mark included.
    @Test func markStylingIsOrangeOnlyForTheCurrentLeg() throws {
        let course = Self.course
        #expect(course.legs.count == 9, "\(course.legs)")
        #expect(Self.gate.count == 2)

        // Every leg and status: orange is exactly the leg's marks, plus the line's ends while the line is active;
        // every other mark is grey.
        let statuses: [(BoatStatus, [Int])] = [(.prestart, [0]), (.ocs, [0]), (.racing, Array(course.legs.indices)),
                                               (.finished, [course.legs.count - 1]), (.dsq, [3])]
        for (status, legs) in statuses {
            for legIndex in legs {
                let leg = course.legSailed(status: status, legIndex: legIndex)
                let lineActive = ChartMarks.isLineActive(status: status, leg: leg)
                for mark in Self.marks {
                    let expected = course.marksOfLeg(leg).contains(mark) || (lineActive && Self.lineEnds.contains(mark))
                    let tone = ChartMarks.tone(of: mark, in: course, status: status, legIndex: legIndex)
                    #expect(tone == (expected ? CuePalette.orange : CuePalette.inactiveGrey),
                            "\(status) leg \(legIndex): \(mark.name) is \(tone)")
                }
            }
        }

        // In the sequence: the windward mark and the line; the next mark (the offset) stays grey.
        #expect(Self.orange(.prestart) == [Self.windward] + Self.lineEnds)
        #expect(Self.orange(.ocs) == [Self.windward] + Self.lineEnds)
        // Racing to the windward mark: it alone; the line is grey once she's started.
        #expect(Self.orange(.racing, 0) == [Self.windward])
        // The offset mark only on its own leg.
        #expect(Self.orange(.racing, 1) == [Self.offset])
        // The gate leg: both gate marks, nothing else.
        #expect(Self.orange(.racing, 2) == Self.gate)
        #expect(Self.orange(.racing, 5) == Self.gate)
        // The last lap has no gate leg: W, O, then the finish line's ends; the gate stays grey throughout.
        #expect(Self.orange(.racing, 6) == [Self.windward])
        #expect(Self.orange(.racing, 7) == [Self.offset])
        #expect(Self.orange(.racing, 8) == Self.lineEnds)
        #expect(Self.orange(.finished, 8) == Self.lineEnds)
        for legIndex in [0, 1, 3, 4, 6, 7, 8] {
            for mark in Self.gate {
                #expect(ChartMarks.tone(of: mark, in: course, status: .racing, legIndex: legIndex) == CuePalette.inactiveGrey)
            }
        }
    }

    /// The scene draws what the styling says: in the prestart fixture only the windward mark has its zone and arrow,
    /// and the line is active.
    @Test func theSceneDrawsTheActiveLeg() throws {
        let (scene, _) = try DrawOrderTests.scene(fixture: "prestart")
        let course = scene.driver.course
        #expect(scene.chart.activeBuoys == [course.elements[CourseLayout.windwardIndex].marks[0]])
        #expect(scene.chart.lineIsActive)
    }

    /// The dashes scale with the camera like the strokes' widths, so zoomed out they keep their screen length and
    /// don't close up into a solid line; an empty pattern falls back to the default, never solid.
    @Test func dashesScaleWithTheCamera() throws {
        let venue = try VenueFile.bundled(id: "fellmere", version: 1).content
        let chart = ChartLayer(course: Self.course, venue: venue, pointsPerMeter: GameScene.pointsPerMeter)
        chart.install(in: SKNode(), courseLayer: SKNode())
        chart.update(status: .prestart, legIndex: 0, cameraScale: 1)
        let near = chart.dashPattern
        chart.update(status: .prestart, legIndex: 0, cameraScale: 3.8)
        #expect(near == ChartStyle.defaultDashes)
        #expect(chart.dashPattern == near.map { $0 * 3.8 })

        var style = ChartStyle.standard
        style.dashes = []
        #expect(style.dashes(atCameraScale: 2) == ChartStyle.defaultDashes.map { $0 * 2 })
        style.dashes = [0, 0]
        #expect(style.dashes(atCameraScale: 1) == ChartStyle.defaultDashes)
    }

    /// The rounding arrow starts on the side a boat comes from and sweeps the way she rounds: anticlockwise to port,
    /// clockwise to starboard.
    @Test func roundingArrowSweepsTheRoundingSide() {
        let north = Vec2(0, 1)
        let port = RoundingArrow(around: .zero, approach: north, side: .port, radius: 10, sweep: .pi * 5 / 6)
        #expect(abs(port.startAngle - -.pi / 2) < 1e-9, "starts south of the mark, where she comes from")
        #expect(port.sweep > 0)
        // Leaving it to port, she passes east of it (the mark on her left), then turns left round it.
        #expect(abs(port.point(at: 0).x - 10) < 1e-9)
        #expect(port.arc().contains { $0.x > 9.9 && abs($0.y) < 2 })
        #expect(port.endTangent.x < 0, "the head points back west, across the top")

        let starboard = RoundingArrow(around: .zero, approach: north, side: .starboard, radius: 10, sweep: .pi * 5 / 6)
        #expect(starboard.sweep < 0)
        #expect(starboard.arc().contains { $0.x < -9.9 && abs($0.y) < 2 })
        #expect(starboard.endTangent.x > 0)
        for barb in port.barbs(length: 4) {
            #expect(abs((barb - port.point(at: port.endAngle)).length - 4) < 1e-9)
        }
    }

    /// Each buoy's approach is the course's: upwind to the windward mark, from it to the offset mark, downwind to the
    /// gate, whose left mark is rounded to port and right to starboard.
    @Test func buoysApproachAsTheCourseRoundsThem() {
        let course = Self.course
        let buoys = ChartMarks.buoys(of: course)
        #expect(buoys.map(\.mark) == course.elements.flatMap(\.marks))
        #expect(buoys[0].approach == course.upwind)
        #expect((buoys[1].approach - (Self.offset.position - Self.windward.position).normalized).length < 1e-12)
        #expect(buoys[2].approach == -course.upwind && buoys[2].side == .port)
        #expect(buoys[3].approach == -course.upwind && buoys[3].side == .starboard)
        if case .mark(_, let side) = course.elements[CourseLayout.windwardIndex] { #expect(buoys[0].side == side) }
    }
}

/// The chart's shapes (#115).
@MainActor @Suite struct ChartGeometryTests {
    /// The hatch lies in the band outside the race area: no line crosses into it or past the band, and the band is
    /// covered on all four sides.
    @Test func hatchStaysInItsBand() {
        let area = RaceArea(centre: Vec2(100, -50), axis: 0.3, halfWidth: 400, halfLength: 700)
        let segments = ChartGeometry.hatch(around: area, width: 30, spacing: 6)
        #expect(segments.count > 200)
        let up = Vec2.heading(area.axis), right = up.rightPerp
        var sides = Set<Int>()
        for segment in segments {
            for t in stride(from: 0.0, through: 1.0, by: 0.25) {
                let p = segment.a + (segment.b - segment.a) * t
                #expect(area.inset(p) <= 1e-6, "inside the race area")
                #expect(area.inset(p) >= -30 - 1e-6, "past the band")
            }
            let mid = (segment.a + segment.b) / 2 - area.centre
            let u = mid.dot(right), v = mid.dot(up)
            sides.insert(u > area.halfWidth ? 0 : u < -area.halfWidth ? 1 : v > area.halfLength ? 2 : 3)
            // At 45° to the sides.
            let d = (segment.b - segment.a).normalized
            #expect(abs(abs(d.dot(right)) - abs(d.dot(up))) < 1e-9)
        }
        #expect(sides == [0, 1, 2, 3])
    }

    /// Fellmere's four pieces meet along diagonals inland: those aren't coasts, so the relief doesn't draw along them.
    @Test func coastEdgesDropSharedEdges() throws {
        let venue = try VenueFile.bundled(id: "fellmere", version: 1).content
        let polygons = venue.land.map(\.points)
        let all = ChartGeometry.edges(of: polygons)
        let coast = ChartGeometry.coastEdges(of: polygons)
        #expect(polygons.count == 4)
        #expect(all.count - coast.count == 8, "four shared edges, each in two pieces")
        for edge in coast {
            #expect(!(abs(edge.a.x) < 1e-6 && abs(edge.b.x) < 1e-6) && !(abs(edge.a.y) < 1e-6 && abs(edge.b.y) < 1e-6),
                    "the shared edges lie on the axes: \(edge)")
        }
        // A venue whose pieces share nothing keeps every edge.
        let hollin = try VenueFile.bundled(id: "hollin-bay", version: 1).content.land.map(\.points)
        #expect(ChartGeometry.coastEdges(of: hollin).count == ChartGeometry.edges(of: hollin).count)
    }

    /// The relief stays on the land in every bundled venue: no band spills into the water past a corner.
    @Test func reliefStaysOnTheLand() throws {
        let style = ChartStyle.standard
        for key in VenueFile.bundledKeys() {
            let venue = try VenueFile.bundled(id: key.id, version: key.version).content
            let strips = ChartGeometry.relief(of: venue.land.map(\.points), depth: style.reliefDepth,
                                              steps: style.reliefSteps, light: style.lightBearing)
            #expect(venue.land.isEmpty || !strips.isEmpty, "\(key)")
            #expect(strips.contains(where: \.isLit) == strips.contains { !$0.isLit }, "\(key): lit and shaded both")
            for strip in strips {
                let centre = strip.corners.reduce(Vec2.zero, +) / 4
                #expect(venue.isLand(centre), "\(key): a relief band at \(centre) is off the land")
                #expect((0...1).contains(strip.weight))
            }
        }
    }

    @Test func shallowsWeightFadesWithDepth() {
        #expect(ChartGeometry.shallowsWeight(depth: 0, maxDepth: 8, fraction: 0.5) == 1)
        #expect(ChartGeometry.shallowsWeight(depth: -1, maxDepth: 8, fraction: 0.5) == 1)
        #expect(ChartGeometry.shallowsWeight(depth: 2, maxDepth: 8, fraction: 0.5) == 0.5)
        #expect(ChartGeometry.shallowsWeight(depth: 4, maxDepth: 8, fraction: 0.5) == 0)
        #expect(ChartGeometry.shallowsWeight(depth: 8, maxDepth: 8, fraction: 0.5) == 0)
    }
}

/// The shallows tint (#11, #15): hue, never lightness.
@MainActor @Suite struct ShallowsTintTests {
    /// Acceptance: the shallows tint's lightness is within ±2 % (OKLCH L, absolute 0.02) of the water's, at every
    /// depth, as drawn in 8-bit sRGB, and in Saltings Reach's texture texel by texel.
    @Test func shallowsTintKeepsTheWaterLightness() throws {
        let water = ChartPalette.water.oklch.L
        #expect(abs(ChartPalette.shallowsTint.oklch.L - water) <= 0.02)
        for step in 0...20 {
            let rgb = ShallowsTint.colour(weight: Double(step) / 20).rgb8
            let token = PaletteToken("tint", UInt32(rgb[0]) << 16 | UInt32(rgb[1]) << 8 | UInt32(rgb[2]))
            #expect(abs(token.oklch.L - water) <= 0.02, "weight \(Double(step) / 20): \(token) L \(token.oklch.L)")
        }

        let current = try #require(try VenueFile.bundled(id: "saltings-reach", version: 1).content.current)
        let pixels = ChartLayer.shallowsPixels(current)
        #expect(pixels.count == current.grid.nodeCount * 4)
        var tinted = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let token = PaletteToken("texel", UInt32(pixels[i]) << 16 | UInt32(pixels[i + 1]) << 8 | UInt32(pixels[i + 2]))
            #expect(abs(token.oklch.L - water) <= 0.02, "texel \(i / 4): \(token)")
            if token.rgb != ChartPalette.water.rgb { tinted += 1 }
        }
        // The banks are tinted, the channel isn't.
        #expect(tinted > 0 && tinted < current.grid.nodeCount)
    }

    /// The shallows sprite sits on the depth grid: the texel under each node's world position is that node's own
    /// tint, so the image is neither flipped nor rotated nor shifted against the grid.
    @Test func shallowsSpriteLinesUpWithTheGrid() throws {
        let venue = try VenueFile.bundled(id: "saltings-reach", version: 1).content
        let current = try #require(venue.current)
        let grid = current.grid
        let chart = ChartLayer(course: ChartMarksTests.course, venue: venue, pointsPerMeter: GameScene.pointsPerMeter)
        let world = SKNode()
        chart.install(in: world, courseLayer: SKNode())
        let sprite = try #require(chart.shallows.compactMap { $0 as? SKSpriteNode }.first { $0.texture != nil })
        let pixels = ChartLayer.shallowsPixels(current)
        let ppm = GameScene.pointsPerMeter
        var distinct = Set<[UInt8]>()
        for row in 0..<grid.rows {
            for column in 0..<grid.columns {
                let p = grid.position(column: column, row: row)
                let local = sprite.convert(CGPoint(x: CGFloat(p.x) * ppm, y: CGFloat(p.y) * ppm), from: world)
                let u = Int(((local.x / sprite.size.width + 0.5) * CGFloat(grid.columns)).rounded(.down))
                let v = Int(((local.y / sprite.size.height + 0.5) * CGFloat(grid.rows)).rounded(.down))
                #expect((0..<grid.columns).contains(u) && (0..<grid.rows).contains(v), "node (\(column), \(row))")
                guard (0..<grid.columns).contains(u), (0..<grid.rows).contains(v) else { continue }
                // Image rows run top-down; the sprite's local y runs up.
                let i = ((grid.rows - 1 - v) * grid.columns + u) * 4
                let weight = ChartGeometry.shallowsWeight(depth: current.depth(column: column, row: row),
                                                          maxDepth: current.maxDepth, fraction: ChartStyle.standard.shallowFraction)
                let expected = ShallowsTint.colour(weight: weight).rgb8
                #expect(Array(pixels[i..<i + 3]) == expected, "node (\(column), \(row)) drew texel (\(u), \(v))")
                distinct.insert(expected)
            }
        }
        // The grid isn't uniform, so a misplaced texel shows.
        #expect(distinct.count > 1)
    }

    /// The tint is its own colour through tritanopia (the filter #11 names) and the red-green dichromacies, though not
    /// in greyscale: it changes hue only, by spec.
    @Test func shallowsTintReadsUnderColourBlindFilters() {
        func distance(_ filter: VisionFilter) -> Double {
            func lab(_ token: PaletteToken) -> OKLab {
                let c = filter.apply(token.components).map { UInt32(($0 * 255).rounded()) }
                return OKLab(PaletteToken("f", c[0] << 16 | c[1] << 8 | c[2]))
            }
            return lab(ChartPalette.water).distance(to: lab(ChartPalette.shallowsTint))
        }
        for filter in [VisionFilter.none, .tritanopia, .deuteranopia, .protanopia] {
            #expect(distance(filter) > 0.08, "\(filter): ΔE \(distance(filter))")
        }
    }

    /// OKLab round-trips a token through sRGB.
    @Test func okLabRoundTrips() {
        for token in ChartPalette.all + CuePalette.all {
            #expect(OKLab(token).rgb8.map(UInt32.init) == token.components.map { UInt32(($0 * 255).rounded()) }, "\(token)")
        }
    }
}

/// The chart over every venue (#115).
@MainActor @Suite struct ChartVenueTests {
    /// Every bundled venue builds its chart over a course: its land and landmarks, and shallows only with a current.
    @Test func everyBundledVenueBuildsAChart() throws {
        let course = PracticeDriver(config: RaceDriverTests.config).course
        let keys = VenueFile.bundledKeys()
        #expect(keys.contains { $0.id == "saltings-reach" } && keys.contains { $0.id == "fellmere" })
        for key in keys {
            let venue = try VenueFile.bundled(id: key.id, version: key.version).content
            let chart = ChartLayer(course: course, venue: venue, pointsPerMeter: GameScene.pointsPerMeter)
            let world = SKNode(), courseLayer = SKNode()
            chart.install(in: world, courseLayer: courseLayer)
            #expect(chart.land.isEmpty == venue.land.isEmpty, "\(key)")
            #expect(chart.landmarks.count == venue.landmarks.count, "\(key)")
            #expect(chart.shallows.isEmpty == (venue.current == nil), "\(key)")
            #expect(chart.boundary.count == 2, "\(key)")
            #expect(courseLayer.children.count > 4, "\(key)")
        }
    }

    /// Every landmark in every bundled venue has a silhouette of its own; an unknown name draws the generic marker.
    @Test func everyLandmarkHasASilhouette() throws {
        for key in VenueFile.bundledKeys() {
            for landmark in try VenueFile.bundled(id: key.id, version: key.version).content.landmarks {
                #expect(LandmarkSilhouette.table[landmark.asset] != nil, "\(key): \(landmark.asset)")
            }
        }
        #expect(LandmarkSilhouette.named("no-such-landmark") == .generic)
        for silhouette in LandmarkSilhouette.allCases {
            #expect(!silhouette.path(size: 40).isEmpty)
        }
    }

    /// The chart is in world space, under the world node with the water, so the camera's rotation (#113) turns it.
    @Test func chartLayersAreInTheWorld() throws {
        let (scene, _) = try DrawOrderTests.scene(fixture: "chart-saltings-reach")
        let world = try #require(scene.children.first { $0.childNode(withName: "water") != nil })
        for name in [ChartLayer.shallowsName, ChartLayer.boundaryName, ChartLayer.landName, ChartLayer.landmarksName] {
            let nodes = world.children.filter { $0.name == name }
            #expect(!nodes.isEmpty, "\(name)")
        }
        // Nothing of the chart in screen space: the camera holds none.
        #expect(scene.camera?.children.contains { $0.name?.hasPrefix("chart-") == true } != true)
    }

    /// Current is never drawn (#15, ADR 0003): the chart's sources read only the depths, never the flood directions
    /// or the current field.
    @Test func chartNeverReadsTheCurrent() throws {
        for file in ["ChartLayer", "ChartGeometry", "ChartMarks", "ChartStyle", "LandmarkSilhouette"] {
            let source = try String(contentsOf: RaceDriverTests.repoRoot.appending(path: "Regatta/Game/\(file).swift"), encoding: .utf8)
            #expect(!source.contains("floodDirection") && !source.contains("CurrentField"), "\(file)")
        }
    }
}
