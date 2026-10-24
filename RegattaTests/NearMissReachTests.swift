import SpriteKit
import Testing
import RegattaCore
@testable import Regatta

/// The near-miss reach (#344): a debug overlay on each right-of-way boat, off by default.
@MainActor @Suite struct NearMissReachTests {
    /// Off (the default) it adds no node to the scene or the standing fleet (0 extra); on, it draws one shape on each
    /// boat holding right of way in a relation with yours in glow range, and none on the keep-clear boat; off again, its
    /// shapes go.
    @Test func drawsOnTheRightOfWayBoatAlone() throws {
        let (scene, session) = try GameSceneTests.scene(fixture: "rules-call")
        let fleet = try #require(scene.standingFleet)
        #expect(!scene.showsNearMissReach)
        scene.update(0)
        let sprites = GameSceneTests.nodeCount(scene), standing = fleet.sceneNodeCount
        #expect(scene.nearMissReachSeats.isEmpty)
        #expect(scene["//nearMissReach"].isEmpty)

        let world = session.driver.renderWorld
        let me = world.myBoatIndex
        let relations = try #require(world.frame.keepClear)
        let hull = world.boatClass.hull.length
        let pairs = relations.indices.compactMap { seat -> (rightOfWay: Int, keepClear: Int)? in
            guard seat != me, let relation = relations[seat],
                  RightOfWayGlyph.isInRange(world.me.position, world.boats[seat].position,
                                            rangeHulls: scene.boatStyle.glowRangeHulls, hullLength: hull) else { return nil }
            return relation.keepClear == me ? (seat, me) : (me, seat)
        }
        try #require(!pairs.isEmpty, "the fixture has no right-of-way relation in range")
        let rightOfWay = Set(pairs.map(\.rightOfWay))
        let keepClear = Set(pairs.map(\.keepClear)).subtracting(rightOfWay)
        try #require(!keepClear.isEmpty)

        scene.showsNearMissReach = true
        scene.update(0)
        #expect(scene.nearMissReachSeats == rightOfWay.sorted())
        #expect(keepClear.isDisjoint(with: scene.nearMissReachSeats))
        #expect(scene["//nearMissReach"].count == rightOfWay.count)
        #expect(GameSceneTests.nodeCount(scene) == sprites + rightOfWay.count)
        #expect(fleet.sceneNodeCount == standing)

        scene.showsNearMissReach = false
        scene.update(0)
        #expect(scene.nearMissReachSeats.isEmpty)
        #expect(GameSceneTests.nodeCount(scene) == sprites)
    }

    /// The seats it picks: the other boat where you keep clear, you where she does; none out of range or as a ghost.
    @Test func picksTheRightOfWaySeats() {
        let positions = [Vec2(0, 0), Vec2(5, 0), Vec2(0, 6), Vec2(500, 0)]
        let relations: [RightOfWay?] = [nil, RightOfWay(keepClear: 0, rule: .portStarboard),
                                        RightOfWay(keepClear: 2, rule: .windwardLeeward),
                                        RightOfWay(keepClear: 0, rule: .portStarboard)]
        func seats(ghost: Set<Int> = []) -> Set<Int> {
            NearMissReach.rightOfWaySeats(keepClear: relations, positions: positions, me: 0, isGhost: { ghost.contains($0) },
                                          rangeHulls: 6, hullLength: 4)
        }
        #expect(seats() == [0, 1])
        #expect(seats(ghost: [1]) == [0])
        #expect(seats(ghost: [0]).isEmpty)
        #expect(NearMissReach.rightOfWaySeats(keepClear: nil, positions: positions, me: 0, isGhost: { _ in false },
                                              rangeHulls: 6, hullLength: 4).isEmpty)
    }
}
