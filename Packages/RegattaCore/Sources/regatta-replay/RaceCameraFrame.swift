// What the app's race camera shows of a race, for the freeze-tick conditions (#474): a row with `"camera": "race"`
// counts the boats and marks on the phone's screen, not in a box of water around your boat.
//
// The app's `CameraRig` (Regatta/Game, not linked here) draws a `"view": "courseUp"` fixture settled: the course axis
// at the top, the centre on your boat plus the heading lead, and the zoom of the shot (close quarters at 1.6, mark
// rounding at 0.9 or wider, open water at 0.7; until the gun the pre-start shot's, the line across the width, handing
// over in the 3 s after it). A north-up box at the follow camera's 0.8 (`FreezeTickRow.view`) is
// neither turned nor zoomed that way: on skiff@8 the HUD row's five boats "in view" were two on screen, the camera in
// close quarters showing a quarter of the box's water. This is that settled frame again, from `CameraStyle.standard`'s
// numbers; `RenderFixtureTests` holds each such fixture's count against the app's own rig, so a camera retune that
// moves a frame fails there.
import Foundation
import RegattaCore

struct RaceCameraFrame {
    /// The render fixtures' screen: iPhone 17, portrait, points.
    static let screen = (width: 402.0, height: 874.0)
    static let pointsPerMetre = 8.0

    // `CameraStyle.standard` (Regatta/Game/CameraStyle.swift).
    static let leadAlong = 0.35, leadAcross = 0.25
    static let openWaterZoom = 0.7, markRoundingZoom = 0.9, closeQuartersZoom = 1.6
    static let closeQuartersOnHullLengths = 4.0
    static let markRoundingZones = 2.0
    static let edgeMargin = 0.9
    static let gunHandOverSeconds = 3.0
    static let preStartBoatHeight = 0.4, preStartBoatWidth = 0.7, preStartFlipLineLengths = 0.25
    static let preStartLeadSpeed = 1.5, preStartLeadShare = 0.5
    static let minZoom = 0.35, maxZoom = 2.2

    /// Scene points a world point spans: the boats' size on screen.
    let zoom: Double
    /// The world point at the screen's centre, metres.
    let centre: Vec2
    /// Screen up and screen right, as world unit vectors.
    let up: Vec2
    let right: Vec2

    /// The frame a fixture frozen on `race`'s tick draws from seat `me` (`CameraRig.advance`, settled).
    init(_ race: Race, me: Int) {
        let boat = race.boats[me]
        let course = race.course
        let hull = race.boatClass.hull.length
        let width = Self.screen.width, height = Self.screen.height, ppm = Self.pointsPerMetre
        let up = Vec2.heading(course.axis), right = up.rightPerp
        // The heading lead, settled: all of it, the way she heads.
        let onScreen = boat.heading - course.axis
        let lead = (across: sin(onScreen) * Self.leadAcross, along: cos(onScreen) * Self.leadAlong)

        // The shot: close quarters over mark rounding over open water.
        let others = race.boats.indices.filter { $0 != me && !race.boats[$0].isGhost }.map { race.boats[$0].position }
        let nearest = others.map { ($0 - boat.position).length }.min() ?? .infinity
        let marks = course.marksOfLeg(course.legSailed(status: boat.status, legIndex: boat.legIndex)).map(\.position)
        let mark = marks.min { ($0 - boat.position).length < ($1 - boat.position).length }
        var zoom = Self.openWaterZoom
        if nearest <= Self.closeQuartersOnHullLengths * hull {
            zoom = Self.closeQuartersZoom
        } else if let mark, (mark - boat.position).length <= Self.markRoundingZones * course.zoneRadius {
            // Widened just enough to keep the mark inside `edgeMargin` of the screen.
            let d = mark - boat.position
            func cap(_ metres: Double, half: Double, lead: Double) -> Double {
                let a = metres * ppm / half
                if a > 1e-12 { return (Self.edgeMargin + lead) / a }
                if a < -1e-12 { return (Self.edgeMargin - lead) / -a }
                return .infinity
            }
            zoom = min(Self.markRoundingZoom, cap(d.dot(right), half: width / 2, lead: lead.across),
                       cap(d.dot(up), half: height / 2, lead: lead.along))
        }
        // The pinch limits: never wider than the whole course.
        var lower = Self.minZoom
        let xs = course.obstacles.map { $0.position.dot(right) }, ys = course.obstacles.map { $0.position.dot(up) }
        if let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() {
            let fit = min(width / ((maxX - minX) * ppm), height / ((maxY - minY) * ppm))
            if fit.isFinite { lower = min(max(lower, fit), Self.maxZoom) }
        }
        zoom = zoom.clamped(to: lower...Self.maxZoom)
        let k = zoom * ppm
        let raced = boat.position + right * (lead.across * width / 2 / k) + up * (lead.along * height / 2 / k)
        self.up = up
        self.right = right
        guard race.time < Self.gunHandOverSeconds else {
            self.zoom = zoom
            centre = raced
            return
        }

        // The pre-start shot (`CameraRig.preStartComposition`): the line's ends across the width, your boat low under
        // the line (high above it) and inside the middle of the width, the heading lead taking over with her speed.
        let pin = course.startLine.pin.position, committee = course.startLine.committee.position
        let middle = (pin + committee) / 2
        let lineLength = max((committee - pin).length, 1)
        let halfSpan = max(abs((pin - middle).dot(right)), abs((committee - middle).dot(right)), 1e-3)
        let preZoom = (Self.edgeMargin * width / 2 / (halfSpan * ppm)).clamped(to: lower...Self.maxZoom)
        let flip = tanh((boat.position - middle).dot(up) / max(Self.preStartFlipLineLengths * lineLength, 1e-3))
        let boatY = (0.5 - Self.preStartBoatHeight) * flip * height
        let half = Self.preStartBoatWidth * width / 2 / (preZoom * ppm)
        let boatX = -(middle - boat.position).dot(right).clamped(to: -half...half) * preZoom * ppm
        let byLead = Self.smoothstep(boat.velocity.length / Self.preStartLeadSpeed)
        let share = Self.preStartLeadShare
        let offsetX = boatX * (1 - byLead) - lead.across * share * width / 2 * byLead
        let offsetY = boatY * (1 - byLead) - lead.along * share * height / 2 * byLead
        let pre = boat.position + right * (-offsetX / (preZoom * ppm)) + up * (-offsetY / (preZoom * ppm))
        let w = race.time < 0 ? 1 : 1 - Self.smoothstep(race.time / Self.gunHandOverSeconds)
        self.zoom = preZoom * w + zoom * (1 - w)
        centre = pre * w + raced * (1 - w)
    }

    static func smoothstep(_ t: Double) -> Double {
        let x = t.clamped(to: 0...1)
        return x * x * (3 - 2 * x)
    }

    /// Where `p` (metres) is drawn: points from the screen's bottom-left corner, y up (`CameraRig.project`).
    func project(_ p: Vec2) -> (x: Double, y: Double) {
        let d = (p - centre) * (zoom * Self.pointsPerMetre)
        return (Self.screen.width / 2 + d.dot(right), Self.screen.height / 2 + d.dot(up))
    }

    /// Whether `p` is drawn on the screen clear of `clear`: points in from its top, bottom and each side.
    func shows(_ p: Vec2, clear: [Double]) -> Bool {
        let q = project(p)
        return q.x > clear[2] && q.x < Self.screen.width - clear[2] && q.y > clear[1] && q.y < Self.screen.height - clear[0]
    }
}
