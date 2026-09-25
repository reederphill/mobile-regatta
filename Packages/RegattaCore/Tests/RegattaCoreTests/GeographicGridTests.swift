import Foundation
import Testing
@testable import RegattaCore

/// Sampling a pairing's geographic grid (#77): bilinear between nodes, neutral outside. The test venue's
/// grids are small and hand-checkable: pairing 0 is 5 × 5 at 250 m, unrotated; pairing 1 is 3 × 4 at 300 m,
/// rotated 30°.
@Suite struct GeographicGridTests {
    static func grids() throws -> [Venue.GeographicGrid] {
        try VenueFixtures.testVenue().pairings.map(\.geographicGrid)
    }

    /// #77 acceptance: at every node, rotated grid included, the sample is the node's values exactly.
    @Test func nodeValuesAreReproducedExactly() throws {
        let grids = try Self.grids()
        #expect(grids.map(\.grid.orientation) == [0, deg2rad(30)])
        for geo in grids {
            let g = geo.grid
            for row in 0..<g.rows {
                for column in 0..<g.columns {
                    let shift = geo.sample(g.position(column: column, row: row))
                    #expect(shift.directionDelta == geo.directionDelta(column: column, row: row), "node (\(column), \(row))")
                    #expect(shift.speedFactor == geo.speedFactor(column: column, row: row), "node (\(column), \(row))")
                }
            }
        }
    }

    /// #77 acceptance: a cell's midpoint samples the average of its four corners.
    @Test func cellMidpointIsTheAverageOfItsCorners() throws {
        for geo in try Self.grids() {
            let g = geo.grid
            for row in 0..<(g.rows - 1) {
                for column in 0..<(g.columns - 1) {
                    let midpoint = g.origin + g.columnAxis * ((Double(column) + 0.5) * g.cellSize)
                        + g.rowAxis * ((Double(row) + 0.5) * g.cellSize)
                    let corners = [(column, row), (column + 1, row), (column, row + 1), (column + 1, row + 1)]
                    let delta = corners.map { geo.directionDelta(column: $0.0, row: $0.1) }.reduce(0, +) / 4
                    let factor = corners.map { geo.speedFactor(column: $0.0, row: $0.1) }.reduce(0, +) / 4
                    let shift = geo.sample(midpoint)
                    #expect(abs(shift.directionDelta - delta) < 1e-12, "cell (\(column), \(row))")
                    #expect(abs(shift.speedFactor - factor) < 1e-12, "cell (\(column), \(row))")
                }
            }
        }
        // By hand: pairing 0's first cell has corners 4°, 2°, 3°, 1.5° and 0.8, 0.9, 0.85, 0.95.
        let shift = try Self.grids()[0].sample(Vec2(-375, -175))
        #expect(abs(rad2deg(shift.directionDelta) - 2.625) < 1e-12)
        #expect(abs(shift.speedFactor - 0.875) < 1e-12)
    }

    /// Between nodes the sample is bilinear: linear along each axis, so a quarter of the way along an edge
    /// is a quarter of the way between its nodes.
    @Test func sampleIsLinearAlongAnEdge() throws {
        let geo = try Self.grids()[0]
        // Row 0 from node (1, 0) at 2° / 0.9 to node (2, 0) at 0° / 1.0.
        let shift = geo.sample(Vec2(-250 + 62.5, -300))
        #expect(abs(rad2deg(shift.directionDelta) - 1.5) < 1e-12)
        #expect(abs(shift.speedFactor - 0.925) < 1e-12)
    }

    /// #77 acceptance: beyond the outer nodes, on every side and far away, there is no shift; a point on
    /// the edge is still inside.
    @Test func outsideTheGridIsNeutral() throws {
        #expect(Venue.GeographicShift.neutral == Venue.GeographicShift(directionDelta: 0, speedFactor: 1))
        for geo in try Self.grids() {
            let g = geo.grid
            let (lastColumn, lastRow) = (g.columns - 1, g.rows - 1)
            // Each edge's first span, as (node, neighbouring node along the edge, outward direction).
            let edges: [((Int, Int), (Int, Int), Vec2)] = [
                ((0, 0), (1, 0), -g.rowAxis),
                ((0, lastRow), (1, lastRow), g.rowAxis),
                ((0, 0), (0, 1), -g.columnAxis),
                ((lastColumn, 0), (lastColumn, 1), g.columnAxis),
            ]
            for (a, b, outward) in edges {
                let onEdge = (g.position(column: a.0, row: a.1) + g.position(column: b.0, row: b.1)) / 2
                let inside = geo.sample(onEdge)
                let delta = (geo.directionDelta(column: a.0, row: a.1) + geo.directionDelta(column: b.0, row: b.1)) / 2
                let factor = (geo.speedFactor(column: a.0, row: a.1) + geo.speedFactor(column: b.0, row: b.1)) / 2
                #expect(abs(inside.directionDelta - delta) < 1e-12 && abs(inside.speedFactor - factor) < 1e-12)
                #expect(geo.sample(onEdge + outward) == .neutral, "1 m beyond the edge at \(a)-\(b)")
                #expect(geo.sample(onEdge + outward * 10_000) == .neutral)
            }
            let farCorner = g.position(column: lastColumn, row: lastRow)
            #expect(geo.sample(farCorner + (g.rowAxis + g.columnAxis) * 0.5) == .neutral)
            #expect(geo.sample(g.origin - (g.rowAxis + g.columnAxis) * 0.5) == .neutral)
            #expect(geo.sample(Vec2(1e9, -1e9)) == .neutral)
            #expect(geo.sample(Vec2(.nan, 0)) == .neutral)
        }
    }

    /// A point's cell has its lower corner in 0...n − 2 on each axis, so the far edges fall in the last
    /// cell at fraction 1 rather than outside.
    @Test func farNodesFallInTheLastCell() throws {
        for geo in try Self.grids() {
            let g = geo.grid
            let cell = try #require(g.cell(containing: g.position(column: g.columns - 1, row: g.rows - 1)))
            #expect(cell == Venue.Grid.Cell(column: g.columns - 2, row: g.rows - 2, columnFraction: 1, rowFraction: 1))
            let origin = try #require(g.cell(containing: g.origin))
            #expect(origin == Venue.Grid.Cell(column: 0, row: 0, columnFraction: 0, rowFraction: 0))
        }
    }

    /// The bundled dev venue's grids sample to their placeholder shore effect: nearly neutral at the start
    /// line, 3° of bend and 12 % shadow at the western shore nodes.
    @Test func devVenueGridSamplesItsShoreEffect() throws {
        let geo = Race.defaultPairing.geographicGrid
        let start = geo.sample(Race.defaultPairing.startLineCentre)
        #expect(start.directionDelta == 0 && start.speedFactor == 0.99)
        let west = geo.sample(Vec2(-1000, 0))
        #expect(abs(rad2deg(west.directionDelta) - 3) < 1e-12 && west.speedFactor == 0.88)
        #expect(geo.sample(Vec2(-1001, 0)) == .neutral)
    }
}
