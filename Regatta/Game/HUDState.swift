import Foundation
import RegattaCore

struct MiniBoat: Identifiable {
    let id: Int
    let position: Vec2
    let colorIndex: Int
    let isPlayer: Bool
    let isActive: Bool
}

/// A throttled snapshot of the race for the SwiftUI overlay.
struct HUDState {
    /// Race clock in ticks (`Race.tick`); `clock` is the same in seconds.
    var tick = 0
    var clock = 0.0
    var status: BoatStatus = .prestart
    var speedKnots = 0.0
    var twaDegrees = 0.0
    var tack: Tack = .starboard
    var windKnots = 0.0
    /// Shift from the course axis in degrees; positive = veered (clockwise).
    var windShiftDegrees = 0.0
    /// Compass direction the wind blows from, radians.
    var windDirection = 0.0
    var inShadow = false
    var place = 1
    var fleet = 1
    var legNumber = 1
    var legCount = 1
    var targetName = ""
    var targetDistance = 0.0
    /// Compass bearing to the target, radians.
    var targetBearing = 0.0
    var penaltyTurns = 0
    var penaltyProgress = 0.0
    var boats: [MiniBoat] = []
    var course: Course?

    var isUpwind: Bool { twaDegrees < 90 }

    init() {}

    /// The HUD for `world`'s latest tick, from your seat.
    init(world: RenderWorld) {
        let frame = world.frame
        let me = world.myBoatIndex
        let p = frame.boats[me]
        let course = world.course
        self.course = course
        tick = frame.tick
        clock = frame.time
        status = p.status
        speedKnots = p.speed * 1.943_84
        twaDegrees = rad2deg(p.twa)
        tack = p.tack
        // The wind readouts show the wind over the ground (#15); the wind angle is the one she sails at.
        windKnots = p.windOverGround.speed * p.shadow * 1.943_84
        windShiftDegrees = rad2deg(wrapAngle(p.windOverGround.direction - course.axis))
        windDirection = p.windOverGround.direction
        inShadow = p.shadow < 0.97
        fleet = frame.boats.count
        place = frame.place(of: me)
        legCount = course.legs.count
        legNumber = min(p.legIndex + 1, legCount)
        penaltyTurns = p.penaltyTurnsOwed
        if p.penaltyTurnsOwed > 0 {
            penaltyProgress = abs(p.penaltyProgress) / (2 * .pi * Double(p.penaltyTurnsOwed))
        }

        let target: Vec2
        switch p.status {
        case .prestart where frame.time < 0:
            targetName = "Start line"
            target = course.lineCenter
        case .prestart:
            targetName = "Cross the start line"
            target = course.lineCenter
        case .ocs:
            targetName = "Return below the line"
            target = course.lineCenter - course.upwind * 20
        case .racing:
            let leg = course.legs[p.legIndex]
            targetName = course.name(of: leg).capitalized
            target = course.targetPosition(for: leg)
        case .finished, .dsq, .dnf:
            targetName = "Finished"
            target = p.position
        }
        targetDistance = (target - p.position).length
        targetBearing = (target - p.position).bearing

        boats = frame.boats.map {
            MiniBoat(id: $0.id, position: $0.position, colorIndex: $0.colorIndex, isPlayer: $0.id == me, isActive: $0.isOnCourse)
        }
    }
}
